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
  function inline(text, target, page, pages, navigate) {
    const pattern = /(`+)([\s\S]*?)\1|!\[([^\]]*)\]\(([^)\s]+)\)|\[\[([^\]]+)\]\]|\[([^\]]+)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*|\*([^*]+)\*/g;
    let start = 0, match;
    while ((match = pattern.exec(text))) {
      target.append(document.createTextNode(text.slice(start, match.index)));
      let node;
      if (match[1]) node = element('code', match[2]);
      else if (match[3] !== undefined) {
        const folder = page.split('/').at(-1) + '.attachments/';
        const file = match[4].startsWith(folder) ? match[4].slice(folder.length) : '';
        if (/^[\w-]+\.(png|jpg|gif|webp)$/.test(file)) {
          node = element('img'); node.alt = match[3]; node.loading = 'lazy';
          node.src = '/api/attachment?' + new URLSearchParams({ page, file });
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
      } else node = element(match[8] ? 'strong' : 'em', match[8] || match[9]);
      target.append(node); start = pattern.lastIndex;
    }
    target.append(document.createTextNode(text.slice(start)));
  }
  function render(text, page, pages, navigate) {
    const root = document.createDocumentFragment();
    const lines = text.split(/\r?\n/);
    let paragraph = [], list = null;
    function flush() {
      if (paragraph.length) {
        const node = element('p'); inline(paragraph.join('\n'), node, page, pages, navigate); root.append(node); paragraph = [];
      }
      list = null;
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
        const pre = element('pre'); pre.append(element('code', body.join('\n'))); root.append(pre); continue;
      }
      if (/^( {4}|\t)/.test(line)) {
        flush(); const body = [line.replace(/^( {4}|\t)/, '')];
        while (index + 1 < lines.length && /^( {4}|\t)/.test(lines[index + 1])) body.push(lines[++index].replace(/^( {4}|\t)/, ''));
        const pre = element('pre'); pre.append(element('code', body.join('\n'))); root.append(pre); continue;
      }
      const heading = line.match(/^(#{1,6})\s+(.+)$/);
      const item = line.match(/^\s*([-*]|\d+\.)\s+(.+)$/);
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
          li.className = 'task-item'; const check = element('input'); check.type = 'checkbox'; check.checked = task[1] !== ' '; check.disabled = true;
          li.append(check, document.createTextNode(' ')); inline(task[2], li, page, pages, navigate);
        } else inline(item[2], li, page, pages, navigate);
        list.append(li);
      } else if (line.startsWith('> ')) {
        flush(); const node = element('blockquote'); inline(line.slice(2), node, page, pages, navigate); root.append(node);
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
  return { render, resolve, headings };
})();
