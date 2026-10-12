/* Leaf Wiki editor: revision-aware autosave, draft recovery and pasted images. */
'use strict';
const $ = id => document.getElementById(id);
const state = { pages: [], trash: [], root: '', page: null, dirty: false, saving: null, blocked: false,
  loading: false, uploading: false, request: 0, searchRequest: 0, mode: 'split', prompt: null,
  journalMonth: new Date(new Date().getFullYear(), new Date().getMonth(), 1), journalDate: '' };
let saveTimer, searchTimer;
async function api(path, payload) {
  const response = await fetch(path, payload === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload)
  });
  const data = await response.json();
  if (!response.ok) { const error = new Error(data.error || 'Request failed'); error.status = response.status; throw error; }
  return data;
}
function message(text = '') { $('message').textContent = text; }
function status(text, failed = false) { $('save-status').textContent = text; $('save-status').classList.toggle('failed', failed); }
function draftKey(id) { return 'leaf-draft:' + state.root + ':' + id; }
function rememberDraft() {
  if (!state.page) return;
  try { localStorage.setItem(draftKey(state.page.id), JSON.stringify({ content: $('editor').value, revision: state.page.revision })); }
  catch (_) { /* Save state remains visible even when browser storage is unavailable. */ }
}
function clearDraft(id) { try { localStorage.removeItem(draftKey(id)); } catch (_) {} }
function preview() {
  if (!state.page) return;
  $('preview').replaceChildren(WikiMarkdown.render($('editor').value, state.page.id,
    new Set(state.pages.map(page => page.id)), openPage));
  const words = $('editor').value.trim().split(/\s+/).filter(Boolean).length;
  $('word-count').textContent = words + (words === 1 ? ' word' : ' words');
}
function button(text, action, className) {
  const node = document.createElement('button'); node.textContent = text;
  if (className) node.className = className;
  node.addEventListener('click', action); return node;
}
function renderTree(pages = state.pages) {
  const nodes = [], groups = new Set();
  for (const page of pages) {
    const parts = page.id.split('/');
    for (let index = 1; index < parts.length; index++) {
      const group = parts.slice(0, index).join('/');
      if (!groups.has(group) && !pages.some(p => p.id === group)) {
        groups.add(group); const node = document.createElement('div'); node.className = 'tree-group';
        node.textContent = '\u00a0\u00a0'.repeat(index - 1) + parts[index - 1]; nodes.push(node);
      }
    }
    const node = button('\u00a0\u00a0'.repeat(parts.length - 1) + page.title, () => openPage(page.id), 'tree-page');
    node.title = page.id; node.classList.toggle('active', state.page?.id === page.id);
    if (state.page?.id === page.id) node.setAttribute('aria-current', 'page');
    if (page.snippet) node.title += '\n' + page.snippet;
    nodes.push(node);
  }
  if (!nodes.length) { const node = document.createElement('p'); node.textContent = $('search').value ? 'No matching pages.' : 'No pages yet.'; nodes.push(node); }
  $('tree').replaceChildren(...nodes); $('page-count').textContent = state.pages.length;
}
function backlinks(rows) {
  $('backlink-count').textContent = rows.length;
  $('backlinks').replaceChildren(...rows.map(row => button(row.id.replaceAll('/', ' › '), () => openPage(row.id))));
  if (!rows.length) $('backlinks').textContent = 'No incoming links yet.';
}
function dateKey(date) {
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'),
    String(date.getDate()).padStart(2, '0')].join('-');
}
function journalPageId(date) {
  return 'Journal/' + date.slice(0, 4) + '/' + date.slice(5, 7) + '/' + date;
}
function journalHeading(date) {
  const [year, month, day] = date.split('-').map(Number);
  const weekday = new Date(year, month - 1, day).toLocaleDateString('en-US', { weekday: 'long' });
  return '# ' + date + ' (' + weekday + ')';
}
function renderJournal() {
  const month = state.journalMonth;
  const year = month.getFullYear(), monthIndex = month.getMonth();
  const first = new Date(year, monthIndex, 1);
  const today = dateKey(new Date());
  $('journal-month-name').textContent = first.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  const existing = new Set(state.pages.map(page => page.id));
  const days = [];
  const date = new Date(year, monthIndex, 1 - first.getDay());
  for (let index = 0; index < 42; index++) {
    const key = dateKey(date), id = journalPageId(key);
    const node = button(String(date.getDate()), () => openJournalDate(key), 'journal-day');
    node.dataset.date = key;
    node.setAttribute('aria-label', key);
    node.classList.toggle('outside-month', date.getMonth() !== monthIndex);
    node.classList.toggle('today', key === today);
    node.classList.toggle('selected', key === state.journalDate);
    node.classList.toggle('has-entry', existing.has(id));
    days.push(node);
    date.setDate(date.getDate() + 1);
  }
  $('journal-days').replaceChildren(...days);
}
async function openJournalDate(key) {
  const match = key.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return false;
  const year = Number(match[1]), month = Number(match[2]), day = Number(match[3]);
  const check = new Date(year, month - 1, day);
  if (month < 1 || month > 12 || dateKey(check) !== key) return false;
  if (!(await ensureSaved())) return false;
  state.journalDate = key; state.journalMonth = new Date(year, month - 1, 1); renderJournal();
  const id = journalPageId(key);
  const exists = state.pages.some(page => page.id === id);
  try {
    if (!exists) {
      try { await api('/api/page', { id, content: journalHeading(key) + '\n\n', revision: '' }); }
      catch (error) { if (error.status !== 409) throw error; }
      await refresh();
    } else {
      const page = await api('/api/page?id=' + encodeURIComponent(id));
      const oldHeading = '# ' + key;
      if (page.content.split(/\r?\n/, 1)[0] === oldHeading) {
        await api('/api/page', {
          id, content: journalHeading(key) + page.content.slice(oldHeading.length), revision: page.revision
        });
        await refresh();
      }
    }
  } catch (error) { message(error.message); return false; }
  return openPage(id);
}
async function refresh() {
  const data = await api('/api/state'); state.pages = data.pages; state.trash = data.trash; state.root = data.data_dir;
  $('data-path').textContent = state.root; renderTree(); renderJournal(); preview(); return data;
}
async function save() {
  clearTimeout(saveTimer);
  if (!state.page || !state.dirty || state.blocked) return !state.blocked;
  if (state.saving) return state.saving;
  const page = state.page, content = $('editor').value;
  status('Saving…');
  state.saving = (async () => {
    try {
      const saved = await api('/api/page', { id: page.id, content, revision: page.revision });
      if (state.page !== page) return false;
      page.revision = saved.revision; page.content = content;
      state.dirty = $('editor').value !== content;
      if (state.dirty) { rememberDraft(); status('Unsaved edits'); saveTimer = setTimeout(save, 500); }
      else { clearDraft(page.id); status('✓ Saved'); }
      const indexed = state.pages.find(item => item.id === page.id); if (indexed) indexed.revision = saved.revision;
      return true;
    } catch (error) {
      status(error.status === 409 ? 'Conflict · Draft kept' : 'Save failed · Draft kept', true);
      state.blocked = error.status === 409; $('conflict').hidden = !state.blocked;
      message(error.message); rememberDraft(); return false;
    } finally { state.saving = null; }
  })();
  return state.saving;
}
async function ensureSaved() {
  if (state.uploading || state.loading) { message('Finish the current operation before switching pages.'); return false; }
  if (state.blocked) { message('Resolve the changed-file conflict before leaving this draft.'); return false; }
  for (let count = 0; state.dirty && count < 5; count++) if (!(await save())) return false;
  return !state.dirty;
}
function setMode(mode) {
  if (innerWidth <= 950 && mode === 'split') mode = 'edit';
  state.mode = mode; $('panes').className = mode;
  document.querySelectorAll('[data-mode]').forEach(node => node.classList.toggle('selected', node.dataset.mode === mode));
}
function ask(kind, value = '') {
  state.prompt = kind;
  $('prompt-title').textContent = kind === 'rename' ? 'Rename this page' : 'Create a page';
  $('prompt-value').value = value; $('prompt-error').textContent = '';
  $('prompt-dialog').showModal(); $('prompt-value').focus();
}
async function openPage(id, anchor) {
  if (!(await ensureSaved())) return false;
  if (state.uploading) return false;
  if (!state.pages.some(page => page.id === id)) { ask('create', id); return false; }
  const request = ++state.request; state.loading = true; $('editor').readOnly = true;
  try {
    const page = await api('/api/page?id=' + encodeURIComponent(id));
    if (request !== state.request) return false;
    state.page = page; state.dirty = false; state.blocked = false;
    $('editor').value = page.content;
    try {
      const draft = JSON.parse(localStorage.getItem(draftKey(id)) || 'null');
      if (draft && typeof draft.content === 'string' && draft.content !== page.content) {
        $('editor').value = draft.content; state.dirty = true;
        state.blocked = draft.revision !== page.revision;
        message(state.blocked ? 'Recovered draft conflicts with the saved file. Copy it before reloading.' : 'Recovered an unsaved draft.');
      } else message();
    } catch (_) { message(); }
    $('title').textContent = page.title; $('breadcrumb').textContent = page.id.replaceAll('/', ' › ');
    $('welcome').hidden = true; $('page').hidden = false; $('conflict').hidden = !state.blocked;
    status(state.blocked ? 'Conflict · Draft kept' : state.dirty ? 'Recovered draft' : '✓ Saved', state.blocked);
    renderTree(); preview(); backlinks(page.backlinks || []);
    history.replaceState(null, '', '#page=' + encodeURIComponent(page.id));
    document.querySelector('.workspace').classList.remove('menu-open'); $('menu').setAttribute('aria-expanded', 'false');
    if (anchor) { setMode('preview'); document.getElementById(anchor)?.scrollIntoView(); }
    if (state.dirty && !state.blocked) saveTimer = setTimeout(save, 500);
    return true;
  } catch (error) { message(error.message); return false; }
  finally { if (request === state.request) { state.loading = false; $('editor').readOnly = false; } }
}
async function uploadImages(files) {
  if (!state.page || state.blocked || state.uploading || !(await ensureSaved())) return;
  state.uploading = true; status('Attaching image…');
  const id = state.page.id;
  try {
    for (const file of files) {
      if (!/^image\/(png|jpeg|gif|webp)$/.test(file.type)) throw new Error('Use a PNG, JPEG, GIF or WebP image.');
      if (file.size > 5 * 1024 * 1024) throw new Error('Images are limited to 5 MiB.');
      const response = await fetch('/api/image?page=' + encodeURIComponent(id), { method: 'POST', headers: { 'Content-Type': file.type }, body: file });
      const data = await response.json(); if (!response.ok) throw new Error(data.error || 'Image upload failed');
      if (state.page?.id !== id) throw new Error('The page changed during image upload.');
      const editor = $('editor'); const start = editor.selectionStart, end = editor.selectionEnd;
      const insertion = '\n' + data.markdown + '\n';
      editor.setRangeText(insertion, start, end, 'end');
      state.dirty = true; rememberDraft(); preview();
    }
    await save();
  } catch (error) { message(error.message); status('Attachment failed', true); }
  finally { state.uploading = false; }
}
$('editor').addEventListener('input', () => {
  if (!state.page) return;
  state.dirty = true; rememberDraft(); preview();
  if (!state.blocked) { status('Unsaved edits'); clearTimeout(saveTimer); saveTimer = setTimeout(save, 650); }
});
$('editor').addEventListener('paste', event => {
  const files = [...(event.clipboardData?.items || [])].filter(item => item.kind === 'file' && item.type.startsWith('image/')).map(item => item.getAsFile()).filter(Boolean);
  if (files.length) { event.preventDefault(); uploadImages(files); }
});
$('editor').addEventListener('dragover', event => { if (event.dataTransfer?.types.includes('Files')) event.preventDefault(); });
$('editor').addEventListener('drop', event => {
  const files = [...(event.dataTransfer?.files || [])];
  if (files.length) { event.preventDefault(); uploadImages(files); }
});
$('save').addEventListener('click', save);
$('journal-today').addEventListener('click', () => openJournalDate(dateKey(new Date())));
$('journal-prev').addEventListener('click', () => {
  state.journalMonth = new Date(state.journalMonth.getFullYear(), state.journalMonth.getMonth() - 1, 1);
  renderJournal();
});
$('journal-next').addEventListener('click', () => {
  state.journalMonth = new Date(state.journalMonth.getFullYear(), state.journalMonth.getMonth() + 1, 1);
  renderJournal();
});
$('new-page').addEventListener('click', async () => { if (await ensureSaved()) ask('create'); });
$('first-page').addEventListener('click', () => ask('create', 'Home'));
$('rename').addEventListener('click', async () => { if (state.page && await ensureSaved()) ask('rename', state.page.id); });
$('prompt-cancel').addEventListener('click', () => $('prompt-dialog').close());
$('prompt-form').addEventListener('submit', async event => {
  event.preventDefault();
  const id = $('prompt-value').value.trim().replaceAll(':', '/');
  const resolved = WikiMarkdown.resolve('', id);
  if (!resolved || resolved.id !== id) { $('prompt-error').textContent = 'Use a valid page name, with / between folders.'; return; }
  const button = $('prompt-form').querySelector('button[type="submit"]'); button.disabled = true;
  try {
    if (!(await ensureSaved())) throw new Error('Save your current draft first.');
    if (state.prompt === 'rename') {
      const old = state.page.id;
      await api('/api/rename', { id: old, destination: id, revision: state.page.revision }); clearDraft(old);
    } else await api('/api/page', { id, content: '# ' + id.split('/').at(-1) + '\n\n', revision: '' });
    $('prompt-dialog').close(); await refresh(); await openPage(id);
  } catch (error) { $('prompt-error').textContent = error.message; }
  finally { button.disabled = false; }
});
$('delete').addEventListener('click', async () => {
  if (!state.page || !(await ensureSaved())) return;
  if (!confirm('Move this page to trash? Child pages remain in the notebook.')) return;
  try {
    await api('/api/trash', { id: state.page.id, revision: state.page.revision }); clearDraft(state.page.id);
    state.page = null; state.dirty = false; $('page').hidden = true; $('welcome').hidden = false;
    history.replaceState(null, '', location.pathname); await refresh(); message();
  } catch (error) { message(error.message); }
});
$('trash-list').addEventListener('click', async () => {
  try {
    await refresh();
    $('trashed-pages').replaceChildren(...state.trash.map(entry => {
      const row = document.createElement('div'); row.className = 'trash-row';
      const label = document.createElement('span'); label.textContent = entry.id;
      row.append(label, button('Restore', async () => {
        if (!(await ensureSaved())) return;
        try { const page = await api('/api/restore', { token: entry.token }); $('trash-dialog').close(); await refresh(); await openPage(page.id); }
        catch (error) { message(error.message); }
      })); return row;
    }));
    if (!state.trash.length) $('trashed-pages').textContent = 'Trash is empty.';
    $('trash-dialog').showModal();
  } catch (error) { message(error.message); }
});
$('trash-close').addEventListener('click', () => $('trash-dialog').close());
$('copy-draft').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('editor').value); message('Draft copied.'); }
  catch (_) { $('editor').focus(); $('editor').select(); message('Select and copy your draft from the editor.'); }
});
$('reload-page').addEventListener('click', async () => {
  if (!state.page || !confirm('Discard this editor draft and load the file? Copy your draft first.')) return;
  clearDraft(state.page.id); state.dirty = false; state.blocked = false; await openPage(state.page.id);
});
$('search').addEventListener('input', () => {
  clearTimeout(searchTimer); const request = ++state.searchRequest, query = $('search').value;
  searchTimer = setTimeout(async () => {
    try {
      const result = await api('/api/state?q=' + encodeURIComponent(query));
      if (request === state.searchRequest && query === $('search').value) renderTree(result.pages);
    } catch (error) { if (request === state.searchRequest) message(error.message); }
  }, 120);
});
$('menu').addEventListener('click', () => {
  const open = document.querySelector('.workspace').classList.toggle('menu-open'); $('menu').setAttribute('aria-expanded', String(open));
});
document.querySelectorAll('[data-mode]').forEach(node => node.addEventListener('click', () => setMode(node.dataset.mode)));
window.addEventListener('keydown', event => {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') { event.preventDefault(); save(); }
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); $('search').focus(); $('search').select(); }
});
window.addEventListener('beforeunload', event => {
  if (state.dirty || state.uploading) { rememberDraft(); event.preventDefault(); event.returnValue = ''; }
});
window.addEventListener('resize', () => { if (innerWidth <= 950 && state.mode === 'split') setMode('edit'); });
async function checkExternal() {
  if (state.loading || state.uploading || state.saving || $('search').value || $('prompt-dialog').open) return;
  const page = state.page, revision = page?.revision;
  try {
    await refresh();
    if (state.saving || state.loading || state.uploading || state.page !== page || page?.revision !== revision) return;
    const indexed = state.page && state.pages.find(page => page.id === state.page.id);
    if (state.page && (!indexed || indexed.revision !== state.page.revision)) {
      state.blocked = true; $('conflict').hidden = false; status('File changed · Reload needed', true);
      message('This page changed outside Leaf Wiki. Your editor content is preserved.');
    }
  } catch (error) { message(error.message); }
}
async function start() {
  setMode('split');
  try {
    await refresh();
    const id = new URLSearchParams(location.hash.slice(1)).get('page');
    if (id) await openPage(id);
    else if (state.pages.length) await openPage(state.pages.find(p => p.id === 'Home')?.id || state.pages[0].id);
  } catch (error) { message(error.message); }
}
start();
setInterval(checkExternal, 5000);
