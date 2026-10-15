/* Safe Markdown subset: construct DOM nodes; never interpret raw HTML. */
'use strict';
const WikiMarkdown = (() => {
  function resolve(source, raw) {
    let [name, ...anchors] = raw.split('#');
    name = name.replaceAll(':', '/').replace(/^\//, '');
    if (!name && anchors.length) return { id: source, anchor: anchors.join('#') };
    if (name.startsWith('./') || name.startsWith('../')) {
      const parts = source.split('/').slice(0, -1);
      for (const part of name.split('/')) {
        if (part === '..') { if (!parts.length) return null; parts.pop(); }
        else if (part && part !== '.') parts.push(part);
      }
      name = parts.join('/');
    }
    const parts = name.split('/');
    if (!name || parts.length > 16 || parts.some(p => !p || p.startsWith('.') || p.trim() !== p || p.endsWith('.attachments'))
        || /[\x00-\x1f\x7f\\:#\[\]|]/.test(name) || new TextEncoder().encode(name).length > 240) return null;
    return { id: name, anchor: anchors.join('#') };
  }
  function element(tag, text) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function inlinePattern() {
    return /(`+)([\s\S]*?)\1|!\[([^\]]*)\]\(([^)\s]+)\)|\[\[([^\]]+)\]\]|\[([^\]]+)\]\(([^)\s]+)\)|~~([^~]+)~~|\*\*([^*]+)\*\*|\*([^*]+)\*/g;
  }
  function imageFile(page, target) {
    const folder = page.split('/').at(-1) + '.attachments/';
    const file = target.startsWith(folder) ? target.slice(folder.length) : '';
    return /^[\w-]+\.(png|jpg|gif|webp)$/.test(file) ? file : null;
  }
  function imageOptions(text) {
    const match = text.match(/^\{width=(small|medium|full)(?: caption=("(?:\\.|[^"\\])*"))?\}/);
    if (!match) return { length: 0, width: 'full', caption: '',
      error: text.startsWith('{width=') ? 'Unrecognized or malformed image options' : undefined };
    try {
      const caption = match[2] ? JSON.parse(match[2]) : '';
      if (caption.length > 500) throw new Error('Caption exceeds 500 characters');
      return { length: match[0].length, width: match[1], caption };
    } catch (error) { return { length: 0, width: 'full', caption: '', error: error.message }; }
  }
  function images(text, page) {
    const items = []; let offset = 0, fence = null, chunk = '', chunkStart = 0;
    function flush() {
      const pattern = inlinePattern(); let match;
      while ((match = pattern.exec(chunk))) {
        if (match[3] === undefined || !imageFile(page, match[4])) continue;
        const options = imageOptions(chunk.slice(pattern.lastIndex));
        items.push({ start: chunkStart + match.index, end: chunkStart + pattern.lastIndex + options.length,
          base: match[0], alt: match[3], target: match[4], file: imageFile(page, match[4]), options });
        pattern.lastIndex += options.length;
      }
      chunk = '';
    }
    for (const raw of text.split('\n')) {
      const line = raw.replace(/\r$/, '');
      const marker = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
      if (marker) {
        flush();
        if (!fence) fence = marker[1];
        else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = null;
      } else if (fence || /^( {4}|\t)/.test(line) || !line.trim()) flush();
      else {
        const block = /^(#{1,6}\s+|\s*(?:[-*]|\d+\.)\s+| {0,3}>)/.test(line);
        if (block) flush();
        if (!chunk) chunkStart = offset;
        chunk += raw + '\n';
        if (block) flush();
      }
      offset += raw.length + 1;
    }
    flush(); return items;
  }
  function inline(text, target, page, pages, navigate) {
    const pattern = inlinePattern();
    let start = 0, match;
    while ((match = pattern.exec(text))) {
      target.append(document.createTextNode(text.slice(start, match.index)));
      let node;
      if (match[1]) node = element('code', match[2]);
      else if (match[3] !== undefined) {
        const file = imageFile(page, match[4]);
        if (file) {
          node = element('img'); node.alt = match[3]; node.loading = 'lazy';
          node.src = '/api/attachment?' + new URLSearchParams({ page, file });
          const options = imageOptions(text.slice(pattern.lastIndex));
          if (options.length) {
            const wrapper = element('span'); wrapper.className = 'wiki-image image-' + options.width;
            wrapper.setAttribute('role', 'figure'); wrapper.append(node);
            if (options.caption) {
              const caption = element('span', options.caption); caption.className = 'image-caption'; wrapper.append(caption);
              wrapper.setAttribute('aria-label', options.caption);
            }
            node = wrapper; pattern.lastIndex += options.length;
          } else if (options.error) node.title = 'Invalid image options: ' + options.error;
        } else node = element('span', '[Unsupported image path: ' + match[4] + ']');
      } else if (match[5]) {
        const separator = match[5].indexOf('|');
        const address = separator < 0 ? match[5] : match[5].slice(0, separator);
        const label = separator < 0 ? address : match[5].slice(separator + 1);
        const resolved = resolve(page, address);
        if (resolved) {
          node = element('a', label); node.href = '#page=' + encodeURIComponent(resolved.id);
          node.dataset.wikiPage = resolved.id; node.dataset.wikiAnchor = resolved.anchor || '';
          if (!pages.has(resolved.id)) { node.className = 'missing'; node.title = 'Create this page'; }
          node.addEventListener('click', event => { event.preventDefault(); navigate(resolved.id, resolved.anchor); });
        } else node = element('span', match[0]);
      } else if (match[6] !== undefined) {
        node = element('a', match[6]);
        if (/^(https?:\/\/|mailto:)/i.test(match[7])) {
          node.href = match[7]; node.target = '_blank'; node.rel = 'noopener noreferrer';
        } else node = element('span', match[6]);
      } else if (match[8] !== undefined) {
        node = element('del', match[8]);
      } else node = element(match[9] ? 'strong' : 'em', match[9] || match[10]);
      target.append(node); start = pattern.lastIndex;
    }
    target.append(document.createTextNode(text.slice(start)));
  }
  // Keep pipes in escapes, code spans, and wiki-link labels inside their cell.
  function table_row(line) {
    if (!line.includes('|')) return null;
    const cells = []; let cell = '', separators = 0;
    const text = line.trim();
    for (let index = 0; index < text.length; index++) {
      if (text[index] === '\\' && index + 1 < text.length) {
        const next = text[++index]; cell += next === '|' ? next : '\\' + next;
      } else if (text[index] === '`') {
        const run = text.slice(index).match(/^`+/)[0];
        let end = index + run.length;
        while ((end = text.indexOf(run, end)) !== -1) {
          if (text[end - 1] !== '`' && text[end + run.length] !== '`') break;
          end += run.length;
        }
        if (end !== -1) { cell += text.slice(index, end + run.length); index = end + run.length - 1; }
        else { cell += run; index += run.length - 1; }
      } else if (text.startsWith('[[', index) && text.indexOf(']]', index + 2) !== -1) {
        const end = text.indexOf(']]', index + 2);
        cell += text.slice(index, end + 2); index = end + 1;
      } else if (text[index] === '|') {
        cells.push(cell.trim()); cell = ''; separators++;
      } else cell += text[index];
    }
    cells.push(cell.trim());
    if (!separators) return null;
    if (text.startsWith('|')) cells.shift();
    if (text.endsWith('|') && cells.at(-1) === '') cells.pop();
    return cells;
  }
  function render(text, page, pages, navigate, onTaskToggle) {
    const root = document.createDocumentFragment();
    const lines = text.split(/\r?\n/);
    let paragraph = [], list = null;
    function flush() {
      if (paragraph.length) {
        const node = element('p'); inline(paragraph.join('\n'), node, page, pages, navigate); root.append(node); paragraph = [];
      }
      list = null;
    }
    function codeBlock(bodyText) {
      const container = element('div');
      container.className = 'code-block';
      const pre = element('pre');
      pre.append(element('code', bodyText));
      const copyBtn = element('button', 'Copy');
      copyBtn.type = 'button';
      copyBtn.className = 'code-copy-btn';
      copyBtn.setAttribute('aria-label', 'Copy code to clipboard');
      copyBtn.title = 'Copy code';
      copyBtn.addEventListener('click', () => {
        const reset = () => {
          setTimeout(() => {
            copyBtn.textContent = 'Copy';
            copyBtn.classList.remove('copied');
          }, 2000);
        };
        if (typeof navigator !== 'undefined' && navigator?.clipboard?.writeText) {
          navigator.clipboard.writeText(bodyText).then(() => {
            copyBtn.textContent = 'Copied!';
            copyBtn.classList.add('copied');
            reset();
          }).catch(() => {
            copyBtn.textContent = 'Error';
            reset();
          });
        } else {
          copyBtn.textContent = 'Copied!';
          copyBtn.classList.add('copied');
          reset();
        }
      });
      container.append(pre, copyBtn);
      return container;
    }
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      const fence = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
      if (fence) {
        flush(); const body = [];
        while (++index < lines.length) {
          const ending = lines[index].match(/^ {0,3}(`{3,}|~{3,})\s*$/);
          if (ending && ending[1][0] === fence[1][0] && ending[1].length >= fence[1].length) break;
          body.push(lines[index]);
        }
        root.append(codeBlock(body.join('\n'))); continue;
      }
      if (/^( {4}|\t)/.test(line)) {
        flush(); const body = [line.replace(/^( {4}|\t)/, '')];
        while (index + 1 < lines.length && /^( {4}|\t)/.test(lines[index + 1])) body.push(lines[++index].replace(/^( {4}|\t)/, ''));
        root.append(codeBlock(body.join('\n'))); continue;
      }
      const headers = table_row(line);
      const divider = index + 1 < lines.length ? table_row(lines[index + 1]) : null;
      if (headers?.length && divider?.length === headers.length
          && divider.every(cell => /^:?-{3,}:?$/.test(cell))) {
        flush();
        const wrapper = element('div'); wrapper.className = 'markdown-table';
        const table = element('table'), head = element('thead'), body = element('tbody');
        const alignments = divider.map(cell => cell.startsWith(':')
          ? (cell.endsWith(':') ? 'center' : 'left') : (cell.endsWith(':') ? 'right' : 'left'));
        function add_row(cells, target, tag) {
          const row = element('tr');
          headers.forEach((_, column) => {
            const node = element(tag); node.className = 'align-' + alignments[column];
            if (tag === 'th') node.scope = 'col';
            inline(cells[column] || '', node, page, pages, navigate); row.append(node);
          });
          target.append(row);
        }
        add_row(headers, head, 'th'); index++;
        while (index + 1 < lines.length) {
          const next = lines[index + 1];
          if (/^(\s*$| {4}|\t| {0,3}(?:#{1,6}\s|>|`{3,}|~{3,}|[-*+]\s|\d+\.\s))/.test(next)) break;
          const cells = table_row(next); if (!cells) break;
          add_row(cells, body, 'td'); index++;
        }
        table.append(head, body); wrapper.append(table); root.append(wrapper); continue;
      }
      const heading = line.match(/^(#{1,6})\s+(.+)$/);
      const item = line.match(/^\s*([-*+]|\d+\.)\s+(.+)$/);
      if (heading) {
        flush(); const node = element('h' + heading[1].length);
        node.id = heading[2].toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '');
        inline(heading[2], node, page, pages, navigate); root.append(node);
      } else if (item) {
        if (paragraph.length) flush();
        const type = /\d/.test(item[1]) ? 'ol' : 'ul';
        if (!list || list.tagName.toLowerCase() !== type) { list = element(type); root.append(list); }
        const li = element('li');
        const task = item[2].match(/^\[([ xX])\]\s*(.*)$/);
        if (task) {
          li.className = 'task-item'; const check = element('input'); check.type = 'checkbox'; check.checked = task[1] !== ' ';
          if (onTaskToggle) {
            const lineIndex = index;
            check.addEventListener('change', () => onTaskToggle(lineIndex, check.checked));
          } else {
            check.disabled = true;
          }
          li.append(check, document.createTextNode(' ')); inline(task[2], li, page, pages, navigate);
        } else inline(item[2], li, page, pages, navigate);
        list.append(li);
      } else if (/^ {0,3}> ?/.test(line)) {
        const bqMatch = line.match(/^ {0,3}> ?(.*)$/);
        flush();
        const bqLines = [bqMatch[1]];
        while (index + 1 < lines.length) {
          const nextBq = lines[index + 1].match(/^ {0,3}> ?(.*)$/);
          if (!nextBq) break;
          bqLines.push(nextBq[1]);
          index++;
        }
        const alertMatch = bqLines[0].match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\s*(.*))?$/i);
        if (alertMatch) {
          const kind = alertMatch[1].toLowerCase();
          const defaultTitles = {
            note: 'Note',
            tip: 'Tip',
            important: 'Important',
            warning: 'Warning',
            caution: 'Caution'
          };
          const customTitle = alertMatch[2]?.trim();
          let title = customTitle || defaultTitles[kind] || 'Note';
          const bodyLines = bqLines.slice(1);
          if (customTitle && bodyLines.length === 0) {
            title = defaultTitles[kind] || 'Note';
            bodyLines.push(customTitle);
          }
          const alertNode = element('div');
          alertNode.className = 'markdown-alert markdown-alert-' + kind;
          alertNode.setAttribute('role', 'region');
          alertNode.setAttribute('aria-label', title);

          const titleP = element('p');
          titleP.className = 'markdown-alert-title';
          const icon = element('span');
          icon.className = 'markdown-alert-icon';
          icon.setAttribute('aria-hidden', 'true');
          titleP.append(icon, document.createTextNode(title));
          alertNode.append(titleP);

          let currentParagraph = [];
          for (const bodyLine of bodyLines) {
            if (!bodyLine.trim()) {
              if (currentParagraph.length) {
                const p = element('p');
                inline(currentParagraph.join('\n'), p, page, pages, navigate);
                alertNode.append(p);
                currentParagraph = [];
              }
            } else {
              currentParagraph.push(bodyLine);
            }
          }
          if (currentParagraph.length) {
            const p = element('p');
            inline(currentParagraph.join('\n'), p, page, pages, navigate);
            alertNode.append(p);
          }
          root.append(alertNode);
        } else {
          const node = element('blockquote');
          let currentParagraph = [];
          for (const bqLine of bqLines) {
            if (!bqLine.trim()) {
              if (currentParagraph.length) {
                const p = element('p');
                inline(currentParagraph.join('\n'), p, page, pages, navigate);
                node.append(p);
                currentParagraph = [];
              }
            } else {
              currentParagraph.push(bqLine);
            }
          }
          if (currentParagraph.length) {
            if (node.children.length === 0 && currentParagraph.length === 1) {
              inline(currentParagraph[0], node, page, pages, navigate);
            } else {
              const p = element('p');
              inline(currentParagraph.join('\n'), p, page, pages, navigate);
              node.append(p);
            }
          }
          root.append(node);
        }
      } else if (/^\s*---+\s*$/.test(line)) { flush(); root.append(element('hr')); }
      else if (!line.trim()) flush();
      else { if (list) list = null; paragraph.push(line); }
    }
    flush(); return root;
  }
  function headings(text) {
    const list = [];
    if (typeof text !== 'string') return list;
    const lines = text.split(/\r?\n/);
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      const fence = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
      if (fence) {
        while (++index < lines.length) {
          const ending = lines[index].match(/^ {0,3}(`{3,}|~{3,})\s*$/);
          if (ending && ending[1][0] === fence[1][0] && ending[1].length >= fence[1].length) break;
        }
        continue;
      }
      if (/^( {4}|\t)/.test(line)) {
        while (index + 1 < lines.length && /^( {4}|\t)/.test(lines[index + 1])) index++;
        continue;
      }
      const heading = line.match(/^(#{1,6})\s+(.+)$/);
      if (heading) {
        const title = heading[2].trim();
        const id = title.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '');
        list.push({ level: heading[1].length, text: title, line: index + 1, id });
      }
    }
    return list;
  }
  function statistics(text, page, frame) {
    let words = 0, characters = 0;
    for (const match of text.matchAll(/[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)*/gu)) words++;
    for (const character of text) characters++;
    const targets = new Set();
    for (const link of frame.querySelectorAll('a')) {
      if (link.dataset.wikiPage && link.dataset.wikiPage !== page) targets.add(link.dataset.wikiPage);
    }
    let headingCount = 0;
    for (let level = 1; level <= 6; level++) headingCount += frame.querySelectorAll('h' + level).length;
    return { words, characters, readingMinutes: words ? Math.ceil(words / 200) : 0,
      headings: headingCount, outgoing: targets.size, images: frame.querySelectorAll('img').length };
  }
  return { render, resolve, headings, statistics, images, imageOptions };
})();
