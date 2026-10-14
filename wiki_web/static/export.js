/* Standalone, script-free HTML export with embedded local notebook images. */
'use strict';
const WikiExport = (() => {
  const MAX_BYTES = 64 * 1024 * 1024;
  function cancelled(signal) { if (signal?.aborted) throw new Error('Export cancelled.'); }
  async function get(path, signal) {
    const response = await fetch(path, { signal });
    if (!response.ok) {
      let error; try { error = (await response.json()).error; } catch (_) {}
      throw new Error(error || 'An export file could not be read.');
    }
    return response;
  }
  function escape(text) {
    return text.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
  }
  async function generate(scope, current, signal, progress = () => {}) {
    if (scope !== 'page' && scope !== 'notebook') throw new Error('Choose a valid export scope.');
    const state = await (await get('/api/state', signal)).json();
    const pages = scope === 'page' ? state.pages.filter(page => page.id === current) : state.pages;
    if (!pages.length) throw new Error('There are no saved pages to export.');
    const anchors = new Map(pages.map((page, index) => [page.id, 'page-' + index]));
    const included = new Set(anchors.keys()), assets = new Map();
    const root = document.createElement('main'), nav = document.createElement('nav');
    const title = scope === 'page' ? pages[0].id : 'Leaf Wiki notebook';
    const heading = document.createElement('h1'); heading.textContent = title; root.append(heading, nav);
    let bytes = 0;
    for (let index = 0; index < pages.length; index++) {
      cancelled(signal); progress('Exporting ' + (index + 1) + ' of ' + pages.length + ': ' + pages[index].id);
      const page = await (await get('/api/page?id=' + encodeURIComponent(pages[index].id), signal)).json();
      if (page.revision !== pages[index].revision) throw new Error('A page changed during export. Please try again.');
      bytes += new TextEncoder().encode(page.content).length;
      if (bytes > MAX_BYTES) throw new Error('Export exceeds 64 MiB. Export individual pages instead.');
      const entry = document.createElement('a'); entry.textContent = page.id; entry.href = '#' + anchors.get(page.id); nav.append(entry);
      const article = document.createElement('article'); article.id = anchors.get(page.id);
      const label = document.createElement('h2'); label.textContent = page.id; article.append(label);
      article.append(WikiMarkdown.render(page.content, page.id, included, () => {}));
      for (const node of article.querySelectorAll('[id]')) node.id = article.id + '-' + node.id;
      for (const link of article.querySelectorAll('a[data-wiki-page]')) {
        const target = anchors.get(link.dataset.wikiPage);
        if (target) link.href = '#' + target + (link.dataset.wikiAnchor ? '-' + link.dataset.wikiAnchor : '');
        else { link.removeAttribute('href'); link.title = 'Page not included in this export'; }
        delete link.dataset.wikiPage; delete link.dataset.wikiAnchor;
      }
      for (const image of article.querySelectorAll('img')) {
        const params = new URLSearchParams(image.getAttribute('src').split('?')[1]);
        const key = page.id + '/' + params.get('file');
        if (!assets.has(key)) {
          const response = await get('/api/attachment?' + params, signal);
          const mime = response.headers.get('content-type');
          if (!/^image\/(png|jpeg|gif|webp)$/.test(mime)) throw new Error('Unsupported export image.');
          const data = new Uint8Array(await response.arrayBuffer());
          bytes += Math.ceil(data.length / 3) * 4;
          if (data.length > 5 * 1024 * 1024 || bytes > MAX_BYTES) throw new Error('Export exceeds its image or 64 MiB size limit.');
          let binary = '';
          for (let offset = 0; offset < data.length; offset += 8192) binary += String.fromCharCode(...data.subarray(offset, offset + 8192));
          assets.set(key, 'data:' + mime + ';base64,' + btoa(binary));
        }
        image.src = assets.get(key); image.removeAttribute('loading');
      }
      root.append(article);
    }
    cancelled(signal);
    const html = '<!doctype html><html lang="en"><head><meta charset="utf-8">'
      + '<meta name="viewport" content="width=device-width,initial-scale=1">'
      + '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'">'
      + '<title>' + escape(title) + '</title><style>'
      + 'body{font:16px/1.65 system-ui,sans-serif;color:#25382e;margin:0;background:#f8f7f3}'
      + 'main{max-width:960px;margin:auto;padding:24px}nav{display:flex;flex-direction:column;gap:6px}'
      + 'article{margin-top:32px;padding-top:20px;border-top:1px solid #ddd;overflow-wrap:anywhere}'
      + 'img{max-width:100%;height:auto}pre{padding:16px;background:#eee;overflow:auto}'
      + 'a{color:#32634c}a:not([href]){color:#777}blockquote{border-left:3px solid #aaa;padding-left:16px}'
      + '.markdown-table{max-width:100%;overflow-x:auto;margin:16px 0}table{border-collapse:collapse;min-width:100%}'
      + 'th,td{border:1px solid #ddd;padding:8px 12px;vertical-align:top}th{background:#eee}'
      + '.align-left{text-align:left}.align-center{text-align:center}.align-right{text-align:right}'
      + '@media print{article{break-before:page}nav{display:none}}</style></head><body>' + root.outerHTML + '</body></html>';
    if (new TextEncoder().encode(html).length > MAX_BYTES) throw new Error('Export exceeds 64 MiB. Export individual pages instead.');
    return html;
  }
  function download(html, filename, type = 'text/html;charset=utf-8') {
    const url = URL.createObjectURL(new Blob([html], { type }));
    const link = document.createElement('a'); link.href = url; link.download = filename;
    document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  return { generate, download };
})();
