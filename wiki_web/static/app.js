/* Leaf Wiki editor: revision-aware autosave, draft recovery and pasted images. */
'use strict';
const $ = id => document.getElementById(id);
const state = { pages: [], trash: [], root: '', page: null, dirty: false, saving: null, blocked: false,
  loading: false, uploading: false, request: 0, searchRequest: 0, mode: 'split', prompt: null,
  journalMonth: new Date(new Date().getFullYear(), new Date().getMonth(), 1), journalDate: '' };
let saveTimer, searchTimer;
let selectedTag = '', treePages = null;
const exportState = { controller: null };
const captureState = { date: '', busy: false };
const navigationState = { root: null, pinned: [], recent: [], writable: true, error: '' };
function navigationKey() { return 'leaf-navigation:' + state.root; }
function loadNavigation() {
  if (navigationState.root === state.root) return;
  Object.assign(navigationState, { root: state.root, pinned: [], recent: [], writable: true, error: '' });
  try {
    const raw = localStorage.getItem(navigationKey());
    if (raw === null || raw === undefined) return;
    const data = JSON.parse(raw);
    if (!data || !Array.isArray(data.pinned) || !Array.isArray(data.recent)
        || [...data.pinned, ...data.recent].some(id => typeof id !== 'string' || WikiMarkdown.resolve('', id)?.id !== id)) {
      throw new Error('Invalid pinned/recent page data');
    }
    navigationState.pinned = [...new Set(data.pinned)];
    navigationState.recent = [...new Set(data.recent)].slice(0, 10);
  } catch (error) {
    navigationState.writable = false;
    navigationState.error = 'Could not load page shortcuts from browser storage (' + navigationKey() + '): '
      + error.message + '. Shortcuts work for this session only. Repair or remove this storage entry and reload to retry.';
  }
}
function saveNavigation() {
  if (!navigationState.writable) return;
  try {
    const text = JSON.stringify({ pinned: navigationState.pinned, recent: navigationState.recent });
    localStorage.setItem(navigationKey(), text);
    if (localStorage.getItem(navigationKey()) !== text) throw new Error('Saved shortcuts failed read-back verification');
    navigationState.error = '';
  } catch (error) {
    navigationState.error = 'Could not save page shortcuts to browser storage (' + navigationKey() + '): '
      + error.message + '. Changes remain in this session; enable browser storage or free space, then pin or open a page to retry.';
  }
}
function renderNavigation() {
  const pages = new Map(state.pages.map(page => [page.id, page]));
  for (const [key, target, empty] of [['pinned', 'pinned-pages', 'No pinned pages.'], ['recent', 'recent-pages', 'No recent pages.']]) {
    const nodes = navigationState[key].filter(id => pages.has(id)).map(id => {
      const node = document.createElement('button'); node.type = 'button';
      node.className = 'tree-page' + (state.page?.id === id ? ' active' : '');
      node.textContent = (key === 'pinned' ? '★ ' : '') + id; node.title = pages.get(id).title || id;
      if (state.page?.id === id) node.setAttribute('aria-current', 'page');
      node.addEventListener('click', () => openPage(id)); return node;
    });
    if (!nodes.length) {
      const node = document.createElement('p'); node.className = 'empty-shortcuts'; node.textContent = empty; nodes.push(node);
    }
    $(target).replaceChildren(...nodes);
  }
  const pinned = Boolean(state.page && navigationState.pinned.includes(state.page.id));
  $('pin-page').textContent = pinned ? '★ Unpin page' : '☆ Pin page';
  $('pin-page').setAttribute('aria-pressed', String(pinned));
  $('pin-page').disabled = !state.page || state.loading;
  $('shortcuts-status').textContent = navigationState.error;
}
function renameNavigation(old, id) {
  for (const key of ['pinned', 'recent']) navigationState[key] = [...new Set(navigationState[key].map(value => value === old ? id : value))];
  saveNavigation();
}
$('pin-page').addEventListener('click', () => {
  if (!state.page || state.loading) return;
  loadNavigation();
  const id = state.page.id;
  navigationState.pinned = navigationState.pinned.includes(id)
    ? navigationState.pinned.filter(value => value !== id) : [...navigationState.pinned, id];
  saveNavigation(); renderNavigation();
});
const MODAL_DIALOGS = ['prompt', 'trash', 'history', 'switcher', 'export', 'tasks', 'capture', 'verse', 'journal-overview', 'saved-search', 'attachments', 'backup', 'folder', 'image-options', 'dashboard'];
function anyDialogOpen() { return MODAL_DIALOGS.some(id => $(id + '-dialog').open); }

const dashboardState = { request: 0, busy: false, pages: null, tasks: null, images: null, errors: [] };
function closeDashboard() {
  if (dashboardState.busy) return;
  ++dashboardState.request; $('dashboard-dialog').close(); $('dashboard-open').focus();
}
function dashboardControls() {
  for (const id of ['dashboard-refresh', 'dashboard-close', 'dashboard-today', 'dashboard-capture', 'dashboard-new', 'dashboard-all-tasks']) $(id).disabled = dashboardState.busy;
}
function dashboardPlaceholder(target, text) {
  const node = document.createElement('p'); node.className = 'dashboard-help'; node.textContent = text;
  $(target).replaceChildren(node);
}
async function dashboardNavigate(id, task) {
  if (dashboardState.busy) return;
  dashboardState.busy = true; ++dashboardState.request; dashboardControls(); $('dashboard-error').textContent = '';
  try {
    await refresh();
    if (!(await openPage(id))) throw new Error($('message').textContent || 'Could not open ' + id);
    if (task && (state.page.revision !== task.revision || state.dirty)) {
      throw new Error('The task page or recovered draft changed. Go back to the editor to inspect it, or Refresh before jumping to its line.');
    }
    dashboardState.busy = false; closeDashboard();
    if (task) selectTaskLine(task);
  } catch (error) { $('dashboard-error').textContent = error.message; }
  finally { dashboardState.busy = false; dashboardControls(); }
}
function renderDashboard() {
  const pages = dashboardState.pages, tasks = dashboardState.tasks;
  $('dashboard-pages-count').textContent = pages ? pages.length.toLocaleString() : '—';
  $('dashboard-images-count').textContent = dashboardState.images
    ? dashboardState.images.filter(row => !row.missing).length.toLocaleString() : '—';
  $('dashboard-tasks-count').textContent = tasks ? tasks.filter(task => !task.done).length.toLocaleString() : '—';
  for (const [key, target] of [['pinned', 'dashboard-pinned'], ['recent', 'dashboard-recent']]) {
    const existing = new Set((pages || []).map(page => page.id));
    const ids = navigationState[key].filter(id => existing.has(id)).slice(0, 10);
    if (!pages) dashboardPlaceholder(target, 'Page list unavailable. Refresh to retry.');
    else if (!ids.length) dashboardPlaceholder(target, key === 'pinned' ? 'No pinned pages yet.' : 'No recent pages yet.');
    else $(target).replaceChildren(...ids.map(id => button(id, () => dashboardNavigate(id))));
  }
  if (!tasks) dashboardPlaceholder('dashboard-upcoming', 'Tasks unavailable. Refresh to retry.');
  else {
    const today = dateKey(new Date());
    const upcoming = tasks.filter(task => !task.done && task.due).sort((a, b) => a.due.localeCompare(b.due)
      || a.id.localeCompare(b.id) || a.line - b.line).slice(0, 10);
    if (!upcoming.length) dashboardPlaceholder('dashboard-upcoming', 'No open tasks with a due date.');
    else $('dashboard-upcoming').replaceChildren(...upcoming.map(task => {
      const label = (task.due < today ? 'Overdue · ' : task.due === today ? 'Today · ' : '')
        + task.due + ' · ' + task.text + ' · ' + task.id + ':' + task.line;
      return button(label, () => dashboardNavigate(task.id, task), 'dashboard-due-task');
    }));
  }
  if (!pages) dashboardPlaceholder('dashboard-tags', 'Tags unavailable. Refresh to retry.');
  else {
    const counts = new Map();
    for (const page of pages) for (const tag of new Set(page.tags || [])) counts.set(tag, (counts.get(tag) || 0) + 1);
    const tags = [...counts].sort(([a, countA], [b, countB]) => countB - countA || a.localeCompare(b)).slice(0, 10);
    if (!tags.length) dashboardPlaceholder('dashboard-tags', 'No tags yet.');
    else $('dashboard-tags').replaceChildren(...tags.map(([tag, count]) => button('#' + tag + ' (' + count + ')', () => {
      if (dashboardState.busy) return;
      clearTimeout(searchTimer); ++state.searchRequest; $('search').value = ''; selectedTag = tag;
      renderTagFilter(); renderTree(state.pages); renderSavedSearches(); closeDashboard();
    })));
  }
  $('dashboard-error').textContent = dashboardState.errors.join('\n');
}
async function loadDashboard() {
  if (dashboardState.busy || !$('dashboard-dialog').open) return;
  const request = ++dashboardState.request;
  Object.assign(dashboardState, { pages: null, tasks: null, images: null, errors: [] }); renderDashboard();
  $('dashboard-status').textContent = 'Loading notebook pages, images, and tasks…';
  const results = await Promise.allSettled([api('/api/state'), api('/api/attachments'), api('/api/tasks')]);
  if (request !== dashboardState.request || !$('dashboard-dialog').open) return;
  for (const [index, key] of ['pages', 'images', 'tasks'].entries()) {
    const result = results[index];
    try {
      if (result.status === 'rejected') throw result.reason;
      const rows = key === 'images' ? result.value.attachments : result.value[key];
      if (!Array.isArray(rows)) throw new Error('Invalid ' + key + ' response');
      if (key === 'pages' && rows.some(row => !row || typeof row.id !== 'string'
          || (row.tags !== undefined && (!Array.isArray(row.tags) || row.tags.some(tag => typeof tag !== 'string'))))) {
        throw new Error('Invalid page data');
      }
      if (key === 'tasks' && rows.some(row => !row || typeof row.id !== 'string' || typeof row.text !== 'string'
          || typeof row.done !== 'boolean' || typeof row.due !== 'string' || typeof row.revision !== 'string'
          || !Number.isInteger(row.line) || row.line < 1)) throw new Error('Invalid task data');
      if (key === 'images' && rows.some(row => !row || typeof row.page !== 'string'
          || typeof row.file !== 'string' || typeof row.missing !== 'boolean')) throw new Error('Invalid image data');
      dashboardState[key] = rows;
      if (key === 'pages') {
        if (typeof result.value.data_dir !== 'string') throw new Error('Notebook path is missing');
        state.pages = rows; state.root = result.value.data_dir; state.trash = result.value.trash || [];
        loadNavigation(); renderNavigation(); loadSavedSearches(); renderSavedSearches();
        renderTagFilter();
        if (!$('search').value.trim()) renderTree();
        renderJournal();
      }
    } catch (error) { dashboardState[key] = null; dashboardState.errors.push('Could not load ' + key + ': ' + error.message + '. Use Refresh to retry.'); }
  }
  if (navigationState.error) dashboardState.errors.push(navigationState.error);
  renderDashboard();
  $('dashboard-status').textContent = dashboardState.errors.length ? 'Overview loaded with errors.' : 'Notebook overview ready.';
}
$('dashboard-open').addEventListener('click', async () => {
  if (anyDialogOpen() || !(await ensureSaved()) || anyDialogOpen()) return;
  $('dashboard-dialog').showModal(); await loadDashboard();
});
$('dashboard-close').addEventListener('click', closeDashboard);
$('dashboard-dialog').addEventListener('cancel', event => { event.preventDefault(); closeDashboard(); });
$('dashboard-refresh').addEventListener('click', loadDashboard);
$('dashboard-today').addEventListener('click', async () => {
  if (dashboardState.busy) return;
  dashboardState.busy = true; ++dashboardState.request; dashboardControls(); $('dashboard-error').textContent = '';
  try {
    if (!(await openJournalDate(dateKey(new Date())))) throw new Error($('message').textContent || 'Could not open today’s journal.');
    dashboardState.busy = false; closeDashboard();
  } catch (error) { $('dashboard-error').textContent = error.message; }
  finally { dashboardState.busy = false; dashboardControls(); }
});
for (const [id, action] of [['dashboard-capture', openCapture], ['dashboard-all-tasks', openTasks], ['dashboard-new', () => ask('create')]]) {
  $(id).addEventListener('click', () => { if (!dashboardState.busy) { closeDashboard(); return action(); } });
}

const imageOptionsState = { page: null, before: '', items: [] };
function populateImageOptions() {
  const item = imageOptionsState.items[Number($('image-options-image').value)];
  if (!item) { $('image-options-error').textContent = 'Choose an available image.'; return; }
  $('image-options-path').textContent = item.target;
  $('image-options-caption').value = item.options.caption;
  $('image-options-width').value = item.options.width;
  $('image-options-error').textContent = item.options.error
    ? item.options.error + '. Repair the image options in Markdown before applying changes.' : '';
}
$('image-options-open').addEventListener('click', () => {
  const editor = $('editor');
  if (!state.page || state.loading || state.uploading || editor.readOnly || anyDialogOpen()) return;
  const items = WikiMarkdown.images(editor.value, state.page.id);
  if (!items.length) { message('No supported local images in this page. Paste or drop an image into the editor first.'); return; }
  imageOptionsState.page = state.page.id; imageOptionsState.before = editor.value; imageOptionsState.items = items;
  $('image-options-image').replaceChildren(...items.map((item, index) => {
    const option = document.createElement('option'); option.value = String(index);
    option.textContent = (index + 1) + '. ' + (item.alt || item.file); return option;
  }));
  const selected = items.findIndex(item => editor.selectionStart >= item.start && editor.selectionStart <= item.end);
  $('image-options-image').value = String(selected < 0 ? 0 : selected);
  populateImageOptions(); $('image-options-dialog').showModal(); $('image-options-caption').focus();
});
$('image-options-image').addEventListener('change', populateImageOptions);
$('image-options-cancel').addEventListener('click', () => { $('image-options-dialog').close(); $('editor').focus(); });
$('image-options-dialog').addEventListener('cancel', event => {
  event.preventDefault(); $('image-options-dialog').close(); $('editor').focus();
});
$('image-options-form').addEventListener('submit', event => {
  event.preventDefault(); const editor = $('editor');
  const item = imageOptionsState.items[Number($('image-options-image').value)];
  const width = $('image-options-width').value, caption = $('image-options-caption').value;
  if (!item || !['small', 'medium', 'full'].includes(width) || caption.length > 500) {
    $('image-options-error').textContent = 'Choose an image and width, with a caption of at most 500 characters.'; return;
  }
  if (item.options.error) { $('image-options-error').textContent = 'Repair invalid image options in Markdown before applying changes.'; return; }
  if (state.page?.id !== imageOptionsState.page || editor.value !== imageOptionsState.before) {
    $('image-options-error').textContent = 'The editor changed. Cancel and reopen Image options to avoid replacing newer text.'; return;
  }
  if (state.loading || state.uploading || editor.readOnly) {
    $('image-options-error').textContent = 'Finish the current operation before editing image options.'; return;
  }
  const encodedCaption = JSON.stringify(caption).replace(/[|\[\]`#]/g,
    character => '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0'));
  const replacement = item.base + '{width=' + width + (caption ? ' caption=' + encodedCaption : '') + '}';
  const start = editor.selectionStart, end = editor.selectionEnd;
  $('image-options-dialog').close();
  let insertion;
  try { insertion = replaceEditorRange(item.start, item.end, replacement); }
  catch (error) {
    editor.value = imageOptionsState.before;
    $('image-options-dialog').showModal(); $('image-options-error').textContent = 'Could not apply image options: ' + error.message + '. Draft preserved.'; return;
  }
  editor.setSelectionRange(item.start + replacement.length, item.start + replacement.length);
  formatState.undo = { page: state.page.id, before: imageOptionsState.before, after: editor.value, start, end };
  $('format-undo').disabled = false;
  $('format-status').textContent = insertion.error + 'Image options applied. Use Undo format to revert.';
  editorChanged();
});

const folderState = { busy: false, plan: null };
function folderControls() {
  for (const id of ['folder-source', 'folder-destination', 'folder-preview', 'folder-close']) $(id).disabled = folderState.busy;
  $('folder-move').disabled = folderState.busy || !folderState.plan;
}
function folderNames() {
  const source = $('folder-source').value.trim().replaceAll(':', '/');
  const destination = $('folder-destination').value.trim().replaceAll(':', '/');
  if (WikiMarkdown.resolve('', source)?.id !== source || WikiMarkdown.resolve('', destination)?.id !== destination) {
    throw new Error('Use valid folder names with / between components.');
  }
  return { source, destination };
}
function closeFolder() { if (!folderState.busy) $('folder-dialog').close(); }
$('folder-open').addEventListener('click', () => {
  if (anyDialogOpen() || state.loading || state.uploading) return;
  folderState.plan = null;
  $('folder-source').value = state.page?.id.split('/').slice(0, -1).join('/') || '';
  $('folder-destination').value = ''; $('folder-status').textContent = ''; $('folder-error').textContent = '';
  folderControls(); $('folder-dialog').showModal(); $('folder-source').focus();
});
$('folder-close').addEventListener('click', closeFolder);
$('folder-dialog').addEventListener('cancel', event => { event.preventDefault(); closeFolder(); });
for (const id of ['folder-source', 'folder-destination']) $(id).addEventListener('input', () => {
  folderState.plan = null; $('folder-status').textContent = 'Preview the updated move.'; folderControls();
});
$('folder-preview').addEventListener('click', async () => {
  if (folderState.busy) return;
  folderState.busy = true; folderState.plan = null; folderControls(); $('folder-error').textContent = '';
  $('folder-status').textContent = 'Saving draft and checking folder move…';
  try {
    if (!(await ensureSaved())) throw new Error($('message').textContent || 'Save or resolve the current draft first.');
    const names = folderNames(), plan = await api('/api/folder/preview', names);
    folderState.plan = { ...names, ...plan };
    $('folder-status').textContent = plan.pages + ' pages · ' + plan.images + ' images · ' + plan.linked_pages + ' linked pages will update';
  } catch (error) { $('folder-status').textContent = 'Move preview failed.'; $('folder-error').textContent = error.message; }
  finally { folderState.busy = false; folderControls(); }
});
$('folder-move').addEventListener('click', async () => {
  if (folderState.busy || !folderState.plan) return;
  const plan = folderState.plan;
  if (!confirm('Move ' + plan.pages + ' pages from “' + plan.source + '” to “' + plan.destination + '”?')) return;
  folderState.busy = true; folderControls(); $('folder-error').textContent = '';
  $('folder-status').textContent = 'Moving pages, attachments, and history…';
  let completed = false;
  try {
    if (!(await ensureSaved())) throw new Error($('message').textContent || 'Save or resolve the current draft first.');
    const current = state.page?.id;
    const result = await api('/api/folder/move', { source: plan.source, destination: plan.destination, revision: plan.revision });
    completed = true; folderState.plan = null;
    for (const key of ['pinned', 'recent']) navigationState[key] = [...new Set(navigationState[key].map(id => result.mapping[id] || id))];
    saveNavigation();
    if (current && result.mapping[current]) clearDraft(current);
    await refresh();
    if (current && !(await openPage(result.mapping[current] || current))) throw new Error($('message').textContent || 'Could not reopen the current page.');
    $('folder-status').textContent = result.moved + ' pages moved and verified.';
  } catch (error) {
    folderState.plan = null;
    $('folder-status').textContent = completed ? 'Folder move completed; the editor could not refresh.' : 'Folder move failed.';
    $('folder-error').textContent = error.message + (completed ? ' Reload the browser to open the moved pages.' : ' Preview again before retrying.');
  } finally { folderState.busy = false; folderControls(); }
});

const backupState = { busy: false, bundle: null, file: null };
function backupControls() {
  for (const id of ['backup-download', 'backup-validate', 'backup-close', 'backup-file', 'backup-name']) $(id).disabled = backupState.busy;
  $('backup-restore').disabled = backupState.busy || !backupState.bundle;
}
function closeBackup() { if (!backupState.busy) $('backup-dialog').close(); }
$('backup-open').addEventListener('click', async () => {
  if (anyDialogOpen() || !(await ensureSaved()) || anyDialogOpen()) return;
  backupControls(); $('backup-dialog').showModal();
});
$('backup-close').addEventListener('click', closeBackup);
$('backup-dialog').addEventListener('cancel', event => { event.preventDefault(); closeBackup(); });
$('backup-file').addEventListener('change', () => {
  backupState.bundle = null; backupState.file = null;
  $('backup-status').textContent = ''; $('backup-error').textContent = ''; backupControls();
});
$('backup-download').addEventListener('click', async () => {
  if (backupState.busy) return;
  backupState.busy = true; backupControls(); $('backup-error').textContent = '';
  $('backup-status').textContent = 'Saving draft and building a verified notebook backup…';
  try {
    if (!(await ensureSaved())) throw new Error($('message').textContent || 'Save the current draft first.');
    const response = await fetch('/api/backup');
    if (!response.ok) throw new Error((await response.json()).error || 'Backup failed');
    const text = await response.text();
    // Reuse the existing Blob download lifecycle; the bundle is JSON, not executable HTML.
    WikiExport.download(text, 'LeafWiki-backup.json', 'application/json;charset=utf-8');
    $('backup-status').textContent = 'Verified notebook backup download started.';
  } catch (error) { $('backup-status').textContent = 'Backup failed.'; $('backup-error').textContent = error.message; }
  finally { backupState.busy = false; backupControls(); }
});
$('backup-validate').addEventListener('click', async () => {
  if (backupState.busy) return;
  backupState.busy = true; backupState.bundle = null; backupState.file = null; backupControls();
  $('backup-error').textContent = ''; $('backup-status').textContent = 'Reading and validating backup…';
  try {
    const file = $('backup-file').files?.[0];
    if (!file) throw new Error('Choose a Leaf Wiki JSON backup file.');
    if (file.size > 63 * 1024 * 1024) throw new Error('Backup file exceeds 63 MiB. Copy the notebook folder directly.');
    const bundle = JSON.parse(await file.text());
    const summary = await api('/api/backup/validate', { backup: bundle });
    backupState.bundle = bundle; backupState.file = file;
    $('backup-status').textContent = summary.files + ' files validated · ' + (summary.bytes / 1024 / 1024).toFixed(2) + ' MiB';
  } catch (error) { $('backup-status').textContent = 'Validation failed.'; $('backup-error').textContent = error.message; }
  finally { backupState.busy = false; backupControls(); }
});
$('backup-restore').addEventListener('click', async () => {
  if (backupState.busy || !backupState.bundle) return;
  if ($('backup-file').files?.[0] !== backupState.file) {
    backupState.bundle = null; backupControls(); $('backup-error').textContent = 'The selected backup changed. Validate it again.'; return;
  }
  const name = $('backup-name').value.trim();
  if (!name) { $('backup-error').textContent = 'Enter a new sibling folder name.'; return; }
  if (!confirm('Restore into the new sibling folder “' + name + '”? Existing folders are never overwritten.')) return;
  backupState.busy = true; backupControls(); $('backup-error').textContent = '';
  $('backup-status').textContent = 'Restoring and verifying files… See the server console for progress.';
  try {
    const result = await api('/api/backup/restore', { backup: backupState.bundle, name });
    $('backup-status').textContent = result.files + ' files restored and verified at ' + result.path
      + '. To open it, restart Leaf Wiki with --data-dir pointing to this folder.';
  } catch (error) { $('backup-status').textContent = 'Restore failed.'; $('backup-error').textContent = error.message; }
  finally { backupState.busy = false; backupControls(); }
});

const attachmentState = { rows: [], limit: 40, request: 0, opening: false };
function renderAttachments() {
  const nodes = attachmentState.rows.slice(0, attachmentState.limit).map(row => {
    const node = document.createElement('section'); node.className = 'attachment-row';
    const info = document.createElement('div'); info.className = 'attachment-info';
    const name = document.createElement('p'); name.className = 'attachment-name'; name.textContent = row.file;
    const owner = button(row.page, async () => {
      if (attachmentState.opening) return;
      attachmentState.opening = true; ++attachmentState.request;
      try {
        if (await openPage(row.page)) $('attachments-dialog').close();
        else $('attachments-error').textContent = $('message').textContent || 'Could not open ' + row.page + '. Refresh and retry.';
      } finally { attachmentState.opening = false; }
    });
    const details = document.createElement('p'); details.className = 'attachment-details';
    details.textContent = (row.referenced ? 'Referenced in current page' : 'No current reference · history not checked')
      + ' · ' + (row.missing ? 'Size unavailable' : row.bytes < 1024 ? row.bytes + ' B' : (row.bytes / 1024).toFixed(1) + ' KiB');
    const diagnostic = document.createElement('p'); diagnostic.className = 'attachment-error';
    const path = row.page + '.attachments/' + row.file;
    if (row.missing) diagnostic.textContent = 'Missing or excluded image: ' + path + '. Inspect the notebook folder or restore the image, then Refresh.';
    else if (row.error) diagnostic.textContent = path + ': ' + row.error;
    else {
      const image = document.createElement('img'); image.alt = row.file; image.loading = 'lazy';
      image.src = '/api/attachment?' + new URLSearchParams({ page: row.page, file: row.file });
      image.addEventListener('error', () => {
        image.hidden = true;
        diagnostic.textContent = 'Could not preview ' + path + '. The image may be missing, unreadable, or invalid. Inspect the file and Refresh.';
      });
      node.append(image);
    }
    info.append(name, owner, details, diagnostic); node.append(info); return node;
  });
  if (!nodes.length) { const node = document.createElement('p'); node.textContent = 'No attachments in active pages.'; nodes.push(node); }
  $('attachments-results').replaceChildren(...nodes);
  $('attachments-more').hidden = attachmentState.limit >= attachmentState.rows.length;
  $('attachments-status').textContent = Math.min(attachmentState.limit, attachmentState.rows.length)
    + ' of ' + attachmentState.rows.length + ' images · read-only';
}
async function loadAttachments() {
  if (attachmentState.opening || !$('attachments-dialog').open) return;
  const request = ++attachmentState.request;
  $('attachments-status').textContent = 'Scanning active page attachment folders…'; $('attachments-error').textContent = '';
  try {
    await refresh();
    if (request !== attachmentState.request || !$('attachments-dialog').open) return;
    const result = await api('/api/attachments');
    if (request !== attachmentState.request || !$('attachments-dialog').open) return;
    if (!Array.isArray(result.attachments)) throw new Error('Invalid attachment listing');
    attachmentState.rows = result.attachments; attachmentState.limit = 40; renderAttachments();
  } catch (error) {
    if (request !== attachmentState.request || !$('attachments-dialog').open) return;
    $('attachments-status').textContent = 'Attachment scan failed; any previous results may be outdated.';
    $('attachments-error').textContent = 'Could not list attachments: ' + error.message + '. Inspect the reported path and use Refresh to retry.';
  }
}
function closeAttachments() {
  if (attachmentState.opening) return;
  ++attachmentState.request; $('attachments-dialog').close();
}
$('attachments-open').addEventListener('click', async () => {
  if (anyDialogOpen() || !(await ensureSaved()) || anyDialogOpen()) return;
  $('attachments-dialog').showModal(); await loadAttachments();
});
$('attachments-refresh').addEventListener('click', loadAttachments);
$('attachments-close').addEventListener('click', closeAttachments);
$('attachments-dialog').addEventListener('cancel', event => { event.preventDefault(); closeAttachments(); });
$('attachments-more').addEventListener('click', () => { attachmentState.limit += 40; renderAttachments(); });

const savedSearchState = { root: null, rows: [], writable: true, error: '', query: '' };
function savedSearchKey() { return 'leaf-searches:' + state.root; }
function loadSavedSearches() {
  if (savedSearchState.root === state.root) return;
  Object.assign(savedSearchState, { root: state.root, rows: [], writable: true, error: '' });
  try {
    const raw = localStorage.getItem(savedSearchKey());
    if (raw === null || raw === undefined) return;
    const rows = JSON.parse(raw);
    if (!Array.isArray(rows) || rows.length > 100 || rows.some(row => !row
        || typeof row.name !== 'string' || !row.name.trim() || row.name.length > 120
        || typeof row.query !== 'string' || !row.query.trim() || row.query.length > 4096)
        || new Set(rows.map(row => row.query)).size !== rows.length
        || new Set(rows.map(row => row.name.trim().toLowerCase())).size !== rows.length) {
      throw new Error('Invalid saved search data');
    }
    savedSearchState.rows = rows.map(row => ({ name: row.name.trim(), query: row.query }));
  } catch (error) {
    savedSearchState.writable = false;
    savedSearchState.error = 'Could not load saved searches from browser storage (' + savedSearchKey() + '): '
      + error.message + '. Searches work for this session only. Repair or remove this storage entry and reload to retry.';
  }
}
function saveSavedSearches() {
  if (!savedSearchState.writable) return false;
  try {
    const text = JSON.stringify(savedSearchState.rows);
    localStorage.setItem(savedSearchKey(), text);
    if (localStorage.getItem(savedSearchKey()) !== text) throw new Error('Saved searches failed read-back verification');
    savedSearchState.error = ''; return true;
  } catch (error) {
    savedSearchState.error = 'Could not save searches to browser storage (' + savedSearchKey() + '): '
      + error.message + '. Changes remain in this session. Enable storage or free space, then save again to retry.';
    return false;
  }
}
function renderSavedSearches() {
  $('save-search').disabled = !state.root || !$('search').value.trim();
  const nodes = savedSearchState.rows.map(row => {
    const node = document.createElement('div'); node.className = 'saved-search-row';
    const open = button(row.name, () => restoreSavedSearch(row.query), 'tree-page'); open.title = row.query;
    const query = document.createElement('p'); query.className = 'saved-search-query'; query.textContent = row.query;
    const actions = document.createElement('div'); actions.className = 'saved-search-actions';
    const rename = button('Rename', () => editSavedSearch(row.query, row.name));
    rename.setAttribute('aria-label', 'Rename saved search ' + row.name);
    const remove = button('Delete', () => {
      if (!confirm('Delete saved search “' + row.name + '”?')) return;
      savedSearchState.rows = savedSearchState.rows.filter(item => item.query !== row.query);
      saveSavedSearches(); renderSavedSearches();
    });
    remove.setAttribute('aria-label', 'Delete saved search ' + row.name);
    actions.append(rename, remove); node.append(open, query, actions); return node;
  });
  if (!nodes.length) { const node = document.createElement('p'); node.textContent = 'No saved searches.'; node.className = 'saved-search-query'; nodes.push(node); }
  $('saved-search-list').replaceChildren(...nodes); $('saved-search-status').textContent = savedSearchState.error;
}
function editSavedSearch(query, name) {
  if (anyDialogOpen() || !state.root || !query.trim()) return;
  loadSavedSearches();
  const existing = savedSearchState.rows.find(row => row.query === query);
  savedSearchState.query = query;
  $('saved-search-title').textContent = existing ? 'Rename saved search' : 'Save search';
  $('saved-search-name').value = name ?? existing?.name ?? query.trim().slice(0, 120);
  $('saved-search-query').textContent = query; $('saved-search-error').textContent = '';
  $('saved-search-dialog').showModal(); $('saved-search-name').focus();
}
async function restoreSavedSearch(query) {
  if (anyDialogOpen()) return;
  selectedTag = ''; $('tag-filter').value = ''; $('search').value = query;
  renderSavedSearches(); return searchPages(0);
}
$('save-search').addEventListener('click', () => editSavedSearch($('search').value));
$('saved-search-cancel').addEventListener('click', () => $('saved-search-dialog').close());
$('saved-search-dialog').addEventListener('cancel', event => { event.preventDefault(); $('saved-search-dialog').close(); });
$('saved-search-form').addEventListener('submit', event => {
  event.preventDefault();
  const name = $('saved-search-name').value.trim(), query = savedSearchState.query;
  const existing = savedSearchState.rows.find(row => row.query === query);
  if (!name || name.length > 120 || !query.trim() || query.length > 4096) {
    $('saved-search-error').textContent = 'Use a name of 1–120 characters and a query of 1–4,096 characters.'; return;
  }
  if (savedSearchState.rows.some(row => row !== existing && row.name.toLowerCase() === name.toLowerCase())) {
    $('saved-search-error').textContent = 'A saved search already uses that name. Choose another name.'; return;
  }
  if (!existing && savedSearchState.rows.length >= 100) {
    $('saved-search-error').textContent = 'Up to 100 searches can be saved. Delete one before adding another.'; return;
  }
  if (existing) existing.name = name; else savedSearchState.rows.push({ name, query });
  const saved = saveSavedSearches(); renderSavedSearches();
  if (!saved && savedSearchState.writable) { $('saved-search-error').textContent = savedSearchState.error; return; }
  $('saved-search-dialog').close();
});

function openCapture() {
  if (state.loading || state.uploading || anyDialogOpen()) return;
  captureState.date = dateKey(new Date());
  $('capture-target').textContent = 'Today’s journal · ' + captureState.date;
  $('capture-status').textContent = ''; $('capture-error').textContent = '';
  $('capture-dialog').showModal(); $('capture-text').focus();
}
function closeCapture() {
  if (captureState.busy) return;
  $('capture-dialog').close(); $('capture-open').focus();
}
async function submitCapture() {
  if (captureState.busy) return;
  const text = $('capture-text').value, kind = $('capture-kind').value, date = captureState.date;
  $('capture-error').textContent = ''; $('capture-status').textContent = '';
  if (!text.trim()) { $('capture-error').textContent = 'Enter a thought or task first.'; return; }
  const id = journalPageId(date);
  captureState.busy = true;
  $('capture-save').disabled = true; $('capture-close').disabled = true;
  $('capture-text').readOnly = true; $('capture-kind').disabled = true;
  let locked = false, submitted = false, saved = false;
  try {
    if (state.loading || state.uploading) throw new Error('Finish the current operation before capturing.');
    if (state.page?.id === id && !(await ensureSaved())) {
      throw new Error('Save or resolve today’s journal draft first. Your capture text is kept here.');
    }
    state.loading = true; locked = true; $('editor').readOnly = true;
    $('capture-status').textContent = 'Adding to journal…';
    let revision = '';
    if (state.page?.id === id) revision = state.page.revision;
    else {
      try { revision = (await api('/api/page?id=' + encodeURIComponent(id))).revision; }
      catch (error) { if (error.status !== 404) throw error; }
    }
    submitted = true;
    const page = await api('/api/capture', { date, text, kind, revision });
    saved = true; $('capture-text').value = '';
    if (state.page?.id === id) {
      state.page = { ...state.page, ...page }; $('editor').value = page.content;
      state.dirty = false; clearDraft(id); preview(); status('✓ Saved');
    }
    $('capture-status').textContent = 'Added to ' + date + ' journal.';
    await refresh();
  } catch (error) {
    if (saved) $('capture-error').textContent = 'Capture saved, but the notebook list could not refresh: ' + error.message;
    else {
      $('capture-status').textContent = '';
      if (error.status === 409 && state.page?.id === id) {
        state.blocked = true; $('conflict').hidden = false; status('Conflict · Draft kept', true);
        message('Today’s journal changed. Close Capture and resolve the editor conflict before retrying.');
      }
      $('capture-error').textContent = error.message + (submitted && error.status !== 409
        ? ' Text kept. Check the journal before retrying; the save may have completed.' : ' Text kept.');
    }
  } finally {
    if (locked) { state.loading = false; $('editor').readOnly = false; }
    captureState.busy = false; $('capture-save').disabled = false; $('capture-close').disabled = false;
    $('capture-text').readOnly = false; $('capture-kind').disabled = false; $('capture-text').focus();
  }
}

const taskState = { items: [], request: 0, busy: false, action: false, limit: 100 };

function taskOptions(id, values, label) {
  const selected = $(id).value;
  if (selected) values.add(selected);
  const option = value => {
    const node = document.createElement('option'); node.value = value; node.textContent = value || label; return node;
  };
  $(id).replaceChildren(option(''), ...Array.from(values).sort().map(option)); $(id).value = selected;
}
function renderTasks() {
  const today = dateKey(new Date()), query = $('tasks-query').value.trim().toLowerCase();
  const folder = $('tasks-folder').value, tag = $('tasks-tag').value, due = $('tasks-due').value;
  const items = taskState.items.filter(task => {
    if ($('tasks-state').value === 'open' && task.done) return false;
    if ($('tasks-state').value === 'done' && !task.done) return false;
    if (folder && !task.id.startsWith(folder + '/')) return false;
    if (tag && !(task.tags || []).includes(tag)) return false;
    if (query && !(task.text + ' ' + task.id).toLowerCase().includes(query)) return false;
    if (due === 'none') return !task.due;
    if (due === 'today') return task.due === today;
    if (due === 'overdue') return task.due && task.due < today;
    if (due === 'upcoming') return task.due && task.due > today;
    return true;
  }).sort((a, b) => (a.due || '9999-99-99').localeCompare(b.due || '9999-99-99')
    || a.id.localeCompare(b.id) || a.line - b.line);
  $('tasks-results').replaceChildren(...items.slice(0, taskState.limit).map(task => {
    const row = document.createElement('div'); row.className = 'dashboard-task';
    const label = document.createElement('label'), check = document.createElement('input');
    check.type = 'checkbox'; check.checked = task.done; check.disabled = taskState.busy;
    check.addEventListener('change', () => changeTask(task, check.checked));
    const text = document.createElement('span'); text.textContent = task.text || '(Empty task)';
    label.append(check, text);
    const source = button(task.id + ' · line ' + task.line, () => openTask(task)); source.disabled = taskState.busy;
    row.append(label, source); return row;
  }));
  $('tasks-status').textContent = taskState.busy ? 'Working…'
    : items.length ? Math.min(items.length, taskState.limit) + ' of ' + items.length + ' tasks' : 'No matching tasks.';
  $('tasks-more').hidden = items.length <= taskState.limit;
  $('tasks-more').disabled = taskState.busy; $('tasks-refresh').disabled = taskState.busy;
  $('tasks-close').disabled = taskState.action;
}
async function loadTasks() {
  const request = ++taskState.request;
  taskState.busy = true; $('tasks-error').textContent = ''; renderTasks();
  try {
    const result = await api('/api/tasks');
    if (request !== taskState.request || !$('tasks-dialog').open) return;
    taskState.items = result.tasks || []; taskState.limit = 100;
    const folders = new Set(), tags = new Set();
    for (const task of taskState.items) {
      const parts = task.id.split('/'); parts.pop();
      for (let i = 1; i <= parts.length; i++) folders.add(parts.slice(0, i).join('/'));
      for (const tag of task.tags || []) tags.add(tag);
    }
    taskOptions('tasks-folder', folders, 'All folders'); taskOptions('tasks-tag', tags, 'All tags');
  } catch (error) {
    if (request === taskState.request) $('tasks-error').textContent = 'Could not load tasks: ' + error.message;
  } finally {
    if (request === taskState.request) { taskState.busy = false; renderTasks(); }
  }
}
async function openTasks() {
  if (state.loading || state.uploading || anyDialogOpen()) return;
  if (!(await ensureSaved())) return;
  $('tasks-dialog').showModal(); $('tasks-query').focus(); await loadTasks();
}
function closeTasks() {
  if (taskState.action) return;
  ++taskState.request; taskState.busy = false;
  $('tasks-dialog').close(); $('tasks-open').focus();
}
async function changeTask(task, done) {
  if (taskState.busy) return;
  taskState.busy = true; taskState.action = true; renderTasks(); $('tasks-error').textContent = '';
  let locked = false;
  try {
    if (!(await ensureSaved())) throw new Error('Save or resolve your current draft before changing a task.');
    state.loading = true; locked = true; $('editor').readOnly = true;
    const page = await api('/api/task', { id: task.id, line: task.line, done, revision: task.revision });
    task.done = done;
    for (const item of taskState.items) if (item.id === page.id) item.revision = page.revision;
    if (state.page?.id === page.id) {
      state.page = { ...state.page, ...page }; $('editor').value = page.content;
      clearDraft(page.id); preview(); status('✓ Saved');
    }
    await refresh();
  } catch (error) { $('tasks-error').textContent = error.message; }
  finally {
    if (locked) { state.loading = false; $('editor').readOnly = false; }
    taskState.busy = false; taskState.action = false; renderTasks();
  }
}
async function openTask(task) {
  if (taskState.busy) return;
  taskState.busy = true; taskState.action = true; renderTasks();
  try {
    await refresh();
    if (!(await openPage(task.id))) throw new Error('Could not open the task page. Check the editor message.');
    if (state.page.revision !== task.revision || state.dirty) {
      throw new Error('The page or recovered draft changed. Close Tasks to inspect it, or refresh the task list.');
    }
    taskState.action = false; closeTasks(); selectTaskLine(task);
  } catch (error) { $('tasks-error').textContent = error.message; }
  finally { taskState.busy = false; taskState.action = false; renderTasks(); }
}

function selectTaskLine(task) {
  const lines = $('editor').value.split('\n');
  const start = lines.slice(0, task.line - 1).reduce((sum, line) => sum + line.length + 1, 0);
  setMode('edit'); $('editor').focus();
  $('editor').setSelectionRange(start, start + (lines[task.line - 1] || '').length);
  $('editor').scrollTop = Math.max(0, (task.line - 3) * 25);
}

function openExport() {
  if (anyDialogOpen()) return;
  $('export-page-option').disabled = !state.page;
  $('export-scope').value = state.page ? 'page' : 'notebook';
  $('export-status').textContent = ''; $('export-dialog').showModal();
}
function closeExport() {
  if (exportState.controller) { exportState.controller.abort(); $('export-status').textContent = 'Cancelling…'; }
  else { $('export-dialog').close(); $('export-open').focus(); }
}
async function runExport() {
  if (exportState.controller) return;
  const controller = new AbortController(); exportState.controller = controller;
  $('export-start').disabled = true; $('export-scope').disabled = true;
  let loading = false;
  try {
    if (!(await ensureSaved())) throw new Error('Save your draft successfully before exporting.');
    if (controller.signal.aborted) throw new Error('Export cancelled.');
    state.loading = true; loading = true; $('editor').readOnly = true;
    const scope = $('export-scope').value;
    const html = await WikiExport.generate(scope, state.page?.id, controller.signal,
      text => { $('export-status').textContent = text; });
    if (controller.signal.aborted) throw new Error('Export cancelled.');
    const filename = scope === 'notebook' ? 'LeafWiki.html'
      : (state.page.title.replace(/[<>:"/\\|?*\x00-\x1f]/g, '_') || 'Page') + '.html';
    WikiExport.download(html, filename); $('export-status').textContent = 'HTML download ready.';
  } catch (error) { $('export-status').textContent = controller.signal.aborted ? 'Export cancelled.' : error.message; }
  finally {
    exportState.controller = null; $('export-start').disabled = false; $('export-scope').disabled = false;
    if (loading) { state.loading = false; $('editor').readOnly = false; }
    if (controller.signal.aborted) closeExport();
  }
}
function renderTagFilter() {
  const counts = new Map();
  for (const page of state.pages) for (const tag of page.tags || []) counts.set(tag, (counts.get(tag) || 0) + 1);
  if (selectedTag && !counts.has(selectedTag)) counts.set(selectedTag, 0);
  const all = document.createElement('option'); all.value = ''; all.textContent = 'All tags';
  $('tag-filter').replaceChildren(all, ...Array.from(counts).sort(([a], [b]) => a.localeCompare(b)).map(([tag, count]) => {
    const option = document.createElement('option'); option.value = tag; option.textContent = '#' + tag + ' (' + count + ')'; return option;
  }));
  $('tag-filter').value = selectedTag;
}
const dictionaryState = { selection: '', request: 0 };
const PAGE_TEMPLATES = {
  blank: { name: 'Blank', text: '# {{title}}\n\n' },
  journal: { name: 'Journal', text: '# {{title}}\n\n{{date}} · {{weekday}}\n\n## Highlights\n\n## Notes\n\n## Tomorrow\n\n' },
  study: { name: 'Study notes', text: '# {{title}}\n\n## Topic\n\n## Key ideas\n\n## Examples\n\n## Questions\n\n## Summary\n\n' },
  meeting: { name: 'Meeting notes', text: '# {{title}}\n\nDate: {{date}}\n\n## Attendees\n\n## Agenda\n\n## Decisions\n\n## Action items\n\n- [ ] \n' }
};
const templateState = { request: 0, source: PAGE_TEMPLATES.blank.text, loading: false, error: '' };

function templateText(source, id) {
  let date = new Date();
  const journal = id.match(/^Journal\/(\d{4})\/(\d{2})\/(\d{4}-\d{2}-\d{2})$/);
  if (journal && journal[3].startsWith(journal[1] + '-' + journal[2] + '-')) {
    const [year, month, day] = journal[3].split('-').map(Number);
    const candidate = new Date(year, month - 1, day);
    if (dateKey(candidate) === journal[3]) date = candidate;
  }
  const values = { title: id.split('/').at(-1), path: id, date: dateKey(date),
    weekday: date.toLocaleDateString('en-US', { weekday: 'long' }) };
  return source.replace(/\{\{(title|path|date|weekday)\}\}/g, (_, key) => values[key]);
}

function previewTemplate() {
  if (state.prompt !== 'create') return;
  const id = $('prompt-value').value.trim().replaceAll(':', '/') || 'Untitled';
  $('template-preview').textContent = templateState.loading ? 'Loading template…'
    : templateState.error ? '' : templateText(templateState.source, id);
}

function setupTemplates() {
  ++templateState.request; templateState.loading = false; templateState.error = '';
  templateState.source = PAGE_TEMPLATES.blank.text;
  const options = Object.entries(PAGE_TEMPLATES).map(([value, template]) => {
    const node = document.createElement('option'); node.value = value; node.textContent = template.name; return node;
  });
  for (const page of state.pages.filter(page => page.id.startsWith('Templates/'))) {
    const node = document.createElement('option'); node.value = 'page:' + page.id;
    node.textContent = 'Custom · ' + page.id.slice('Templates/'.length); options.push(node);
  }
  $('page-template').replaceChildren(...options); $('page-template').value = 'blank';
  previewTemplate();
}

async function loadTemplate() {
  const value = $('page-template').value, request = ++templateState.request;
  templateState.loading = true; templateState.error = ''; $('prompt-error').textContent = ''; previewTemplate();
  try {
    let source;
    if (PAGE_TEMPLATES[value]) source = PAGE_TEMPLATES[value].text;
    else {
      const id = value.startsWith('page:') ? value.slice(5) : '';
      if (!id.startsWith('Templates/') || !state.pages.some(page => page.id === id)) throw new Error('Select an available template.');
      source = (await api('/api/page?id=' + encodeURIComponent(id))).content;
    }
    if (typeof source !== 'string') throw new Error('This template has no Markdown text.');
    if (request !== templateState.request || state.prompt !== 'create' || !$('prompt-dialog').open) return;
    templateState.source = source;
  } catch (error) {
    if (request !== templateState.request) return;
    templateState.error = error.message; $('prompt-error').textContent = error.message;
  } finally {
    if (request === templateState.request) { templateState.loading = false; previewTemplate(); }
  }
}
const switcherState = { matches: [], selected: 0, busy: false, focus: null };

function renderSwitcher(preserveSelection = false) {
  const query = $('switcher-query').value.trim().replaceAll(':', '/').normalize('NFC').toLowerCase();
  const tokens = query.split(/\s+/).filter(Boolean);
  const previous = preserveSelection && switcherState.matches[switcherState.selected]?.id;
  const matches = state.pages.map(page => {
    const path = page.id.normalize('NFC').toLowerCase(), title = page.title.normalize('NFC').toLowerCase();
    const rank = path === query ? 0 : title === query ? 1 : title.startsWith(query) ? 2
      : path.startsWith(query) ? 3 : title.includes(query) ? 4 : 5;
    return { page, path, rank };
  }).filter(item => tokens.every(token => item.path.includes(token)))
    .sort((a, b) => a.rank - b.rank || a.page.id.localeCompare(b.page.id));
  switcherState.matches = matches.slice(0, 50).map(item => item.page);
  switcherState.selected = Math.max(0, switcherState.matches.findIndex(page => page.id === previous));
  $('switcher-results').replaceChildren(...switcherState.matches.map((page, index) => {
    const node = button(page.id.replaceAll('/', ' / '), () => activateSwitcher(index), 'switcher-option');
    node.id = 'switcher-option-' + index; node.type = 'button'; node.tabIndex = -1;
    node.setAttribute('role', 'option'); node.title = page.id;
    if (page.id === state.page?.id) node.textContent += ' · Current';
    return node;
  }));
  $('switcher-status').textContent = !state.pages.length ? 'No pages yet. Create your first page to get started.'
    : !matches.length ? 'No matching pages.' : matches.length > 50
      ? 'Showing 50 of ' + matches.length + ' pages. Type to narrow the list.'
      : matches.length + (matches.length === 1 ? ' page' : ' pages');
  updateSwitcherSelection();
}

function updateSwitcherSelection() {
  const nodes = $('switcher-results').children;
  Array.from(nodes).forEach((node, index) => {
    const selected = index === switcherState.selected;
    node.classList.toggle('selected', selected); node.setAttribute('aria-selected', String(selected));
  });
  const selected = nodes[switcherState.selected];
  $('switcher-query').setAttribute('aria-activedescendant', selected?.id || '');
  selected?.scrollIntoView({ block: 'nearest' });
}

function openSwitcher() {
  if (anyDialogOpen()) return;
  if (!$('switcher-dialog').open) {
    switcherState.focus = document.activeElement;
    $('switcher-query').value = ''; $('switcher-dialog').showModal(); renderSwitcher();
  }
  $('switcher-query').setAttribute('aria-expanded', 'true'); $('switcher-query').focus();
}

function closeSwitcher() {
  if (switcherState.busy) return;
  $('switcher-dialog').close(); $('switcher-query').setAttribute('aria-expanded', 'false');
  (switcherState.focus || $('switcher-open')).focus();
}

async function activateSwitcher(index = switcherState.selected) {
  const page = switcherState.matches[index];
  if (!page || switcherState.busy) return;
  switcherState.busy = true; $('switcher-query').disabled = true; $('switcher-close').disabled = true;
  $('switcher-status').textContent = 'Saving edits and opening page…';
  try {
    const opened = await openPage(page.id);
    if (opened) {
      switcherState.busy = false; closeSwitcher();
      if (state.mode === 'preview') $('switcher-open').focus(); else $('editor').focus();
    } else $('switcher-status').textContent = $('message').textContent || 'Page could not be opened. Your draft is preserved.';
  } catch (error) { $('switcher-status').textContent = error.message; }
  finally { switcherState.busy = false; $('switcher-query').disabled = false; $('switcher-close').disabled = false; }
}
const historyState = { id: '', revision: '', selected: null, request: 0, restoring: false, stale: false };

function closeHistory() {
  if (historyState.restoring) return;
  ++historyState.request; historyState.selected = null;
  $('history-dialog').close(); $('page-history').focus();
}

async function selectHistoryVersion(entry) {
  const request = ++historyState.request;
  historyState.selected = null; $('history-restore').disabled = true;
  $('history-preview').textContent = ''; $('history-status').textContent = 'Loading version…';
  try {
    const version = await api('/api/version?' + new URLSearchParams({ id: historyState.id, revision: entry.revision }));
    if (request !== historyState.request || !$('history-dialog').open) return;
    historyState.selected = version;
    $('history-preview').textContent = version.content;
    $('history-status').textContent = historyState.stale ? 'The page changed. Close history and load the saved file first.'
      : version.revision === historyState.revision
      ? 'This version matches the current page.' : 'Restore saves your current text in history first.';
    $('history-restore').disabled = historyState.stale || version.revision === historyState.revision;
  } catch (error) { if (request === historyState.request) $('history-status').textContent = error.message; }
}

async function openHistory() {
  if (!state.page || !(await ensureSaved())) return;
  historyState.id = state.page.id; historyState.selected = null;
  historyState.revision = state.page.revision; historyState.stale = false;
  const request = ++historyState.request;
  $('history-list').replaceChildren(); $('history-preview').textContent = '';
  $('history-restore').disabled = true; $('history-status').textContent = 'Loading history…';
  $('history-dialog').showModal();
  try {
    const result = await api('/api/history?id=' + encodeURIComponent(historyState.id));
    if (request !== historyState.request || !$('history-dialog').open) return;
    historyState.stale = result.current_revision !== historyState.revision;
    $('history-list').replaceChildren(...result.versions.map(entry => {
      const label = new Date(entry.saved_at * 1000).toLocaleString() + ' · ' + entry.bytes + ' bytes · ' + entry.revision.slice(0, 8);
      return button(label, () => selectHistoryVersion(entry), 'history-entry');
    }));
    $('history-status').textContent = historyState.stale ? 'The page changed. Close history and load the saved file first.'
      : result.versions.length ? 'Choose a version to preview.'
      : 'No earlier versions yet. History appears after you change and save this page.';
  } catch (error) { if (request === historyState.request) $('history-status').textContent = error.message; }
}

async function restoreHistoryVersion() {
  const selected = historyState.selected, page = state.page;
  if (!selected || historyState.restoring || historyState.stale || page?.id !== historyState.id) return;
  if (!confirm('Restore this version? Your current saved text will remain in history.')) return;
  historyState.restoring = true; $('editor').readOnly = true;
  $('history-restore').disabled = true; $('history-close').disabled = true;
  let loading = false;
  try {
    if (!(await ensureSaved())) throw new Error('Save your draft before restoring a version.');
    state.loading = true; loading = true;
    const restored = await api('/api/history/restore', { id: historyState.id,
      selected: selected.revision, revision: historyState.revision });
    page.revision = restored.revision; page.content = restored.content;
    $('editor').value = restored.content; state.dirty = false; state.blocked = false;
    clearDraft(page.id); status('✓ Restored'); $('conflict').hidden = true;
    historyState.restoring = false; closeHistory();
    preview(); await refresh(); message('Version restored. Your previous text remains in History.');
  } catch (error) { $('history-status').textContent = error.message; }
  finally {
    historyState.restoring = false; $('editor').readOnly = false;
    if (loading) state.loading = false;
    $('history-close').disabled = false;
    $('history-restore').disabled = !historyState.selected || selected.revision === historyState.revision;
  }
}

function captureDictionarySelection() {
  const editor = $('editor');
  if (document.activeElement === editor) {
    dictionaryState.selection = editor.value.slice(editor.selectionStart, editor.selectionEnd).trim();
    return;
  }
  const selection = window.getSelection?.();
  if (selection && $('preview').contains(selection.anchorNode) && $('preview').contains(selection.focusNode)) {
    dictionaryState.selection = selection.toString().trim();
  }
}

function closeDictionary() {
  ++dictionaryState.request;
  $('dictionary-panel').hidden = true;
  $('page').classList.remove('dictionary-visible');
  $('dictionary-open').setAttribute('aria-expanded', 'false');
  $('dictionary-open').focus();
}

async function lookupDictionary() {
  const word = $('dictionary-word').value.trim();
  const request = ++dictionaryState.request;
  $('dictionary-results').replaceChildren();
  if (!word) { $('dictionary-status').textContent = 'Enter a word to look up.'; return; }
  if (new TextEncoder().encode(word).length > 240 || /[\x00-\x1f\x7f]/.test(word)) {
    $('dictionary-status').textContent = 'Enter a word or short phrase up to 240 UTF-8 bytes.'; return;
  }
  $('dictionary-status').textContent = 'Looking up ' + word + '…';
  try {
    const result = await api('/api/dictionary?word=' + encodeURIComponent(word));
    if (request !== dictionaryState.request || $('dictionary-panel').hidden) return;
    $('dictionary-status').textContent = result.senses.length ? result.word + ' · Local dictionary'
      : result.message || 'No definition found in the local dictionary.';
    const nodes = result.senses.map(sense => {
      const node = document.createElement('section'); node.className = 'dictionary-sense';
      const definition = document.createElement('p');
      definition.textContent = (sense.pos ? sense.pos + ' · ' : '') + sense.definition;
      node.append(definition);
      for (const [key, label] of [['example', 'Example'], ['syn', 'Synonyms'], ['ant', 'Antonyms']]) {
        if (!sense[key]) continue;
        const text = document.createElement('p'); text.className = 'dictionary-detail';
        text.textContent = label + ': ' + sense[key]; node.append(text);
      }
      return node;
    });
    $('dictionary-results').replaceChildren(...nodes);
  } catch (error) {
    if (request === dictionaryState.request && !$('dictionary-panel').hidden) {
      $('dictionary-status').textContent = error.message;
    }
  }
}

const outlineState = { activeId: '' };

function closeOutline() {
  $('outline-panel').hidden = true;
  $('page').classList.remove('outline-visible');
  $('outline-toggle').setAttribute('aria-expanded', 'false');
  $('outline-toggle').focus();
}

function openOutline() {
  if (!state.page) return;
  if (!$('dictionary-panel').hidden) closeDictionary();
  $('outline-panel').hidden = false;
  $('page').classList.add('outline-visible');
  $('outline-toggle').setAttribute('aria-expanded', 'true');
  renderOutline();
}

function toggleOutline() {
  if ($('outline-panel').hidden) openOutline();
  else closeOutline();
}

function jumpToHeading(item) {
  outlineState.activeId = item.id;
  renderOutline();
  if (state.mode === 'preview') {
    const target = document.getElementById(item.id);
    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return;
  }
  const lines = $('editor').value.split('\n');
  const targetLine = Math.min(lines.length, Math.max(1, item.line));
  const start = lines.slice(0, targetLine - 1).reduce((sum, line) => sum + line.length + 1, 0);
  const end = start + (lines[targetLine - 1] || '').length;
  $('editor').focus();
  $('editor').setSelectionRange(start, end);
  $('editor').scrollTop = Math.max(0, (targetLine - 3) * 25);
  if (state.mode === 'split') {
    const target = document.getElementById(item.id);
    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
}

function renderOutline() {
  if ($('outline-panel').hidden || !state.page) return;
  const headings = WikiMarkdown.headings($('editor').value);
  if (!headings.length) {
    $('outline-status').textContent = 'No headings in this note. Use # Heading to structure your note.';
    $('outline-list').replaceChildren();
    return;
  }
  $('outline-status').textContent = headings.length + (headings.length === 1 ? ' heading' : ' headings');
  const items = headings.map(item => {
    const node = document.createElement('button');
    node.type = 'button';
    node.className = 'outline-item outline-level-' + item.level + (outlineState.activeId === item.id ? ' active' : '');
    node.textContent = item.text;
    node.title = item.text + ' (H' + item.level + ', line ' + item.line + ')';
    node.addEventListener('click', () => jumpToHeading(item));
    return node;
  });
  $('outline-list').replaceChildren(...items);
}

const verseState = { current: null, controller: null, loading: false };

function closeVerse() {
  if (verseState.controller) { verseState.controller.abort(); verseState.controller = null; }
  $('verse-dialog').close();
  $('verse-open').focus();
}

async function fetchVerse() {
  if (verseState.controller) verseState.controller.abort();
  const controller = new AbortController();
  verseState.controller = controller;
  verseState.loading = true;
  verseState.current = null;
  $('verse-refresh').disabled = true;
  $('verse-translation').disabled = true;
  $('verse-insert').disabled = true;
  $('verse-text').textContent = 'Fetching verse…';
  $('verse-ref').textContent = '';
  $('verse-status').textContent = 'Contacting bible-api.com…';
  const trans = $('verse-translation').value || 'web';
  try {
    const url = 'https://bible-api.com/data/' + encodeURIComponent(trans) + '/random';
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error('Bible API returned HTTP ' + response.status);
    const data = await response.json();
    if (controller.signal.aborted) return;
    const item = data.random_verse;
    if (!item || !item.text) throw new Error('Malformed verse response received.');
    const ref = (item.book || '') + ' ' + (item.chapter || '') + ':' + (item.verse || '') + ' (' + (data.translation?.identifier || trans).toUpperCase() + ')';
    const text = item.text.trim();
    verseState.current = { text, ref, translation: data.translation?.identifier || trans };
    $('verse-text').textContent = '“' + text + '”';
    $('verse-ref').textContent = '— ' + ref;
    $('verse-status').textContent = data.translation?.name ? data.translation.name + ' · Public Domain' : 'Public Domain';
    $('verse-insert').disabled = false;
  } catch (error) {
    if (controller.signal.aborted) return;
    $('verse-text').textContent = 'Could not load verse.';
    $('verse-ref').textContent = '';
    $('verse-status').textContent = error.message || 'Network error fetching verse.';
  } finally {
    if (verseState.controller === controller) {
      verseState.controller = null;
      verseState.loading = false;
      $('verse-refresh').disabled = false;
      $('verse-translation').disabled = false;
    }
  }
}

function openVerse() {
  if (state.loading || state.uploading || anyDialogOpen()) return;
  if (!state.page) return;
  $('verse-status').textContent = '';
  $('verse-dialog').showModal();
  $('verse-refresh').focus();
  fetchVerse();
}

function insertVerse() {
  if (!verseState.current || !state.page) return;
  const quote = verseState.current.text;
  const ref = verseState.current.ref;
  const quoteLines = quote.split('\n').map(l => '> ' + l).join('\n');
  const markdown = '\n' + quoteLines + '\n> — **' + ref + '**\n\n';
  const editor = $('editor');
  const start = editor.selectionStart, end = editor.selectionEnd;
  editor.setRangeText(markdown, start, end, 'end');
  state.dirty = true;
  rememberDraft();
  preview();
  renderOutline();
  status('Unsaved edits');
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 650);
  closeVerse();
  editor.focus();
}

function openDictionary() {
  if (!state.page) return;
  $('dictionary-panel').hidden = false;
  $('page').classList.toggle('dictionary-visible', true);
  $('dictionary-open').setAttribute('aria-expanded', 'true');
  if (dictionaryState.selection) $('dictionary-word').value = dictionaryState.selection;
  $('dictionary-word').focus();
  if ($('dictionary-word').value.trim()) return lookupDictionary();
  $('dictionary-status').textContent = 'Select a word in your page or type one above.';
}
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
let pageStatistics = null;
function renderStatistics() {
  const counts = state.page && pageStatistics || { words: 0, characters: 0, readingMinutes: 0, headings: 0, outgoing: 0, images: 0 };
  for (const key of ['words', 'characters', 'headings', 'outgoing', 'images']) $('statistics-' + key).textContent = counts[key].toLocaleString();
  $('statistics-reading').textContent = counts.readingMinutes
    ? '~' + counts.readingMinutes + (counts.readingMinutes === 1 ? ' minute' : ' minutes') : '0 minutes';
  $('statistics-backlinks').textContent = new Set((state.page?.backlinks || []).map(row => row.id)).size.toLocaleString();
}
function closeStatistics() {
  $('statistics-panel').hidden = true; $('statistics-toggle').setAttribute('aria-expanded', 'false'); $('statistics-toggle').focus();
}
$('statistics-toggle').addEventListener('click', () => {
  if (!state.page) return;
  if (!$('statistics-panel').hidden) { closeStatistics(); return; }
  $('statistics-panel').hidden = false; $('statistics-toggle').setAttribute('aria-expanded', 'true'); renderStatistics();
});
$('statistics-close').addEventListener('click', closeStatistics);
function preview() {
  if (formatState.undo && (state.page?.id !== formatState.undo.page || $('editor').value !== formatState.undo.after)) resetFormat();
  if (!state.page) { pageStatistics = null; renderStatistics(); return; }
  $('preview').replaceChildren(WikiMarkdown.render($('editor').value, state.page.id,
    new Set(state.pages.map(page => page.id)), openPage));
  pageStatistics = WikiMarkdown.statistics($('editor').value, state.page.id, $('preview'));
  const words = pageStatistics.words;
  $('word-count').textContent = words + (words === 1 ? ' word' : ' words');
  renderStatistics();
}
function button(text, action, className) {
  const node = document.createElement('button'); node.textContent = text;
  if (className) node.className = className;
  node.addEventListener('click', action); return node;
}
function highlightTerms(text, terms) {
  const span = document.createElement('span');
  if (!text) return span;
  if (!terms || !terms.length) { span.textContent = text; return span; }
  const escaped = terms.filter(Boolean)
    .map(t => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .sort((a, b) => b.length - a.length);
  if (!escaped.length) { span.textContent = text; return span; }
  const regex = new RegExp('(' + escaped.join('|') + ')', 'gi');
  let last = 0, match;
  while ((match = regex.exec(text)) !== null) {
    if (match.index > last) {
      span.append(document.createTextNode(text.slice(last, match.index)));
    }
    const mark = document.createElement('mark');
    mark.className = 'search-highlight';
    mark.textContent = match[0];
    span.append(mark);
    last = regex.lastIndex;
  }
  if (last < text.length) {
    span.append(document.createTextNode(text.slice(last)));
  }
  return span;
}

function renderTree(pages = state.pages, terms = []) {
  treePages = pages;
  if (selectedTag) pages = pages.filter(page => (page.tags || []).includes(selectedTag));
  const isSearch = Boolean($('search').value.trim());
  const nodes = [], groups = new Set();
  if (isSearch) {
    for (const page of pages) {
      const node = document.createElement('button');
      node.type = 'button';
      node.className = 'tree-search-item' + (state.page?.id === page.id ? ' active' : '');
      node.title = page.id + (page.snippet ? '\n' + page.snippet : '');
      if (state.page?.id === page.id) node.setAttribute('aria-current', 'page');
      node.addEventListener('click', () => openPage(page.id));

      const titleNode = document.createElement('span');
      titleNode.className = 'tree-search-title';
      titleNode.append(highlightTerms(page.title, terms));

      const pathNode = document.createElement('span');
      pathNode.className = 'tree-search-path';
      pathNode.append(highlightTerms(page.id.replaceAll('/', ' / '), terms));

      node.append(titleNode);
      node.append(pathNode);

      if (page.snippet) {
        const snippetNode = document.createElement('span');
        snippetNode.className = 'tree-search-snippet';
        snippetNode.append(highlightTerms(page.snippet, terms));
        node.append(snippetNode);
      }
      nodes.push(node);
    }
  } else {
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
  }
  if (!nodes.length) {
    const node = document.createElement('p');
    node.textContent = selectedTag
      ? 'No matching pages tagged #' + selectedTag + '.' : $('search').value ? 'No matching pages.' : 'No pages yet.';
    nodes.push(node);
  }
  $('tree').replaceChildren(...nodes);
  $('page-count').textContent = pages.length;
}
function backlinks(rows) {
  if (state.page) state.page.backlinks = rows;
  renderStatistics();
  $('backlink-count').textContent = rows.length;
  $('backlinks').replaceChildren(...rows.map(row => button(row.id.replaceAll('/', ' › '), () => openPage(row.id))));
  if (!rows.length) $('backlinks').textContent = 'No incoming links yet.';
}
const journalOverviewState = { date: new Date(), mode: 'week', request: 0, opening: false };
function journalPeriod(date, mode) {
  const start = new Date(date.getFullYear(), date.getMonth(), mode === 'month' ? 1 : date.getDate());
  if (mode === 'week') start.setDate(start.getDate() - (start.getDay() + 6) % 7);
  const end = new Date(start);
  if (mode === 'month') end.setMonth(end.getMonth() + 1);
  else end.setDate(end.getDate() + 7);
  const days = [];
  for (const cursor = new Date(start); cursor < end; cursor.setDate(cursor.getDate() + 1)) days.push(dateKey(cursor));
  return days;
}
function closeJournalOverview() {
  if (journalOverviewState.opening) return;
  ++journalOverviewState.request; $('journal-overview-dialog').close();
}
async function openOverviewDate(key) {
  if (journalOverviewState.opening) return false;
  journalOverviewState.opening = true; ++journalOverviewState.request;
  $('journal-overview-error').textContent = '';
  try {
    const opened = await openJournalDate(key);
    if (opened) $('journal-overview-dialog').close();
    else $('journal-overview-error').textContent = $('message').textContent || 'Could not open the journal entry. Your editor is preserved.';
    return opened;
  } finally { journalOverviewState.opening = false; }
}
function renderJournalOverview(days, existing) {
  const cards = new Map();
  $('journal-overview-entries').replaceChildren(...days.map(key => {
    const card = document.createElement('section'); card.className = 'journal-entry';
    const heading = document.createElement('h3');
    const label = journalHeading(key).slice(2);
    heading.append(button(label, () => openOverviewDate(key)));
    const content = document.createElement('div'); content.className = 'journal-entry-content';
    content.textContent = existing.has(journalPageId(key)) ? 'Loading entry…' : 'No entry yet — click the date to create one.';
    card.append(heading, content); cards.set(key, { card, content }); return card;
  }));
  return cards;
}
async function loadJournalOverview() {
  if (journalOverviewState.opening || !$('journal-overview-dialog').open) return;
  const request = ++journalOverviewState.request;
  const active = () => request === journalOverviewState.request && $('journal-overview-dialog').open;
  const days = journalPeriod(journalOverviewState.date, journalOverviewState.mode);
  $('journal-overview-range').textContent = days[0] + ' – ' + days.at(-1)
    + (journalOverviewState.mode === 'week' ? ' · Monday–Sunday' : '');
  $('journal-overview-error').textContent = '';
  $('journal-overview-status').textContent = 'Refreshing notebook…';
  $('journal-overview-entries').replaceChildren();
  try {
    await refresh(); if (!active()) return;
    const existing = new Set(state.pages.map(page => page.id));
    const cards = renderJournalOverview(days, existing);
    const entries = days.filter(key => existing.has(journalPageId(key)));
    let failures = 0;
    for (let index = 0; index < entries.length; index++) {
      if (!active()) return;
      const key = entries[index], id = journalPageId(key), { card, content } = cards.get(key);
      $('journal-overview-status').textContent = 'Loading entry ' + (index + 1) + ' of ' + entries.length + '…';
      try {
        const page = await api('/api/page?id=' + encodeURIComponent(id)); if (!active()) return;
        if (typeof page.content !== 'string') throw new Error('Entry has no Markdown text');
        content.replaceChildren(WikiMarkdown.render(page.content.slice(0, 4000), id, existing, async (target, anchor) => {
          if (journalOverviewState.opening) return;
          if (!state.pages.some(item => item.id === target)) {
            $('journal-overview-error').textContent = 'Missing page: ' + target + '. Close the overview to create it.'; return;
          }
          journalOverviewState.opening = true; ++journalOverviewState.request;
          try {
            if (await openPage(target, anchor)) $('journal-overview-dialog').close();
            else $('journal-overview-error').textContent = $('message').textContent || 'Could not open this link. Close the overview to create a missing page.';
          } finally { journalOverviewState.opening = false; }
        }));
        if (page.content.length > 4000) {
          const note = document.createElement('p'); note.className = 'journal-entry-note';
          note.textContent = 'First 4,000 characters shown. Click the date to read the full entry.'; card.append(note);
        }
      } catch (error) {
        if (!active()) return;
        failures++; content.className = 'journal-entry-error';
        content.textContent = 'Could not load ' + id + ': ' + error.message + '. Use Refresh to retry.';
      }
    }
    if (active()) $('journal-overview-status').textContent = entries.length + ' entries · ' + (days.length - entries.length)
      + ' empty days' + (failures ? ' · ' + failures + ' failed to load' : '');
  } catch (error) {
    if (active()) {
      $('journal-overview-status').textContent = 'Overview unavailable.';
      $('journal-overview-error').textContent = 'Could not load journal overview: ' + error.message + '. Use Refresh to retry.';
    }
  }
}
async function openJournalOverview() {
  if (anyDialogOpen() || !(await ensureSaved())) return;
  if (anyDialogOpen()) return;
  journalOverviewState.date = state.journalDate ? new Date(state.journalDate + 'T12:00:00') : new Date();
  $('journal-overview-mode').value = journalOverviewState.mode;
  $('journal-overview-dialog').showModal(); await loadJournalOverview();
}
$('journal-overview-open').addEventListener('click', openJournalOverview);
$('journal-overview-close').addEventListener('click', closeJournalOverview);
$('journal-overview-dialog').addEventListener('cancel', event => { event.preventDefault(); closeJournalOverview(); });
$('journal-overview-refresh').addEventListener('click', loadJournalOverview);
$('journal-overview-mode').addEventListener('change', () => {
  if (journalOverviewState.opening) return;
  journalOverviewState.mode = $('journal-overview-mode').value === 'month' ? 'month' : 'week'; return loadJournalOverview();
});
for (const [id, direction] of [['prev', -1], ['next', 1]]) $('journal-overview-' + id).addEventListener('click', () => {
  if (journalOverviewState.opening) return;
  const date = journalOverviewState.date;
  if (journalOverviewState.mode === 'month') journalOverviewState.date = new Date(date.getFullYear(), date.getMonth() + direction, 1);
  else date.setDate(date.getDate() + direction * 7);
  return loadJournalOverview();
});
$('journal-overview-today').addEventListener('click', () => {
  if (journalOverviewState.opening) return;
  journalOverviewState.date = new Date(); return loadJournalOverview();
});
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
  return '# ' + date + ' ' + weekday;
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
  loadNavigation(); renderNavigation();
  loadSavedSearches(); renderSavedSearches();
  $('data-path').textContent = state.root; renderTagFilter(); renderTree(); renderJournal(); preview();
  if ($('switcher-dialog').open && !switcherState.busy) renderSwitcher(true);
  return data;
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
      page.tags = saved.tags || [];
      for (const item of [...state.pages, ...(treePages || [])]) if (item.id === page.id) item.tags = page.tags;
      renderTagFilter(); renderTree(treePages || state.pages);
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
  ++templateState.request;
  state.prompt = kind;
  $('prompt-title').textContent = kind === 'rename' ? 'Rename this page' : 'Create a page';
  $('prompt-value').value = value; $('prompt-error').textContent = '';
  $('template-fields').hidden = kind !== 'create';
  if (kind === 'create') setupTemplates();
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
    resetFormat();
    state.page = page; state.dirty = false; state.blocked = false;
    dictionaryState.selection = '';
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
    renderTree(); preview(); renderOutline(); backlinks(page.backlinks || []);
    history.replaceState(null, '', '#page=' + encodeURIComponent(page.id));
    document.querySelector('.workspace').classList.remove('menu-open'); $('menu').setAttribute('aria-expanded', 'false');
    if (anchor) { setMode('preview'); document.getElementById(anchor)?.scrollIntoView(); }
    if (state.dirty && !state.blocked) saveTimer = setTimeout(save, 500);
    loadNavigation();
    navigationState.recent = [id, ...navigationState.recent.filter(value => value !== id)].slice(0, 10);
    saveNavigation(); renderNavigation();
    return true;
  } catch (error) { message(error.message); return false; }
  finally { if (request === state.request) { state.loading = false; $('editor').readOnly = false; renderNavigation(); } }
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
const formatState = { undo: null, applying: false };
function resetFormat() { formatState.undo = null; $('format-undo').disabled = true; $('format-status').textContent = ''; }
function codeFence(text, minimum) {
  let length = minimum;
  for (const run of text.matchAll(/`+/g)) length = Math.max(length, run[0].length + 1);
  return '`'.repeat(length);
}
function editorChanged() {
  if (!state.page) return;
  state.dirty = true; rememberDraft(); preview(); renderOutline();
  if (!state.blocked) { status('Unsaved edits'); clearTimeout(saveTimer); saveTimer = setTimeout(save, 650); }
}
function formatEdit(kind, text, start, end) {
  const selected = text.slice(start, end);
  if (kind === 'heading' || kind === 'task') {
    const first = start === 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    const boundary = end > start && text[end - 1] === '\n' ? end - 1 : end;
    let last = text.indexOf('\n', boundary); if (last < 0) last = text.length;
    const lines = text.slice(first, last).split('\n');
    const replacement = lines.map(line => {
      if (!line.trim()) return lines.length > 1 ? line : kind === 'heading' ? '# Heading' : '- [ ] Task';
      if (kind === 'heading') return '# ' + (line.replace(/^#{1,6}\s+/, '') || 'Heading');
      if (/^\s*[-*]\s+\[[ xX]\]\s*/.test(line)) return line;
      return '- [ ] ' + (line.replace(/^\s*(?:[-*]|\d+\.)\s+/, '') || 'Task');
    }).join('\n');
    const placeholder = lines.length === 1 && !lines[0].trim();
    return { start: first, end: last, replacement,
      selectStart: first + (placeholder ? kind === 'heading' ? 2 : 6 : 0), selectEnd: first + replacement.length };
  }
  if (kind === 'table') {
    // Insert beside the selection; inserting a template must not discard a draft.
    const prefix = start && text[start - 1] !== '\n' ? '\n\n' : '';
    const table = '| Column 1 | Column 2 |\n| --- | --- |\n| Value A | Value B |\n| Value C | Value D |';
    const suffix = start < text.length ? '\n\n' : '\n';
    return { start, end: start, replacement: prefix + table + suffix,
      selectStart: start + prefix.length + 2, selectEnd: start + prefix.length + 10 };
  }
  if (kind === 'code' && (selected.includes('\n') || selected.startsWith('`') || selected.endsWith('`'))) {
    const fence = codeFence(selected, 3);
    const prefix = (start && text[start - 1] !== '\n' ? '\n' : '') + fence + '\n';
    const body = selected.endsWith('\n') ? selected : selected + '\n';
    const replacement = prefix + body + fence + (end < text.length && text[end] !== '\n' ? '\n' : '');
    return { start, end, replacement, selectStart: start + prefix.length,
      selectEnd: start + prefix.length + selected.replace(/\n$/, '').length };
  }
  const body = selected || ({ bold: 'bold text', italic: 'italic text', link: 'Page', code: 'code' })[kind];
  let prefix = ({ bold: '**', italic: '*', link: '[[', code: '`' })[kind];
  if (kind === 'code') {
    prefix = codeFence(body, 1);
  }
  const suffix = kind === 'link' ? ']]' : prefix;
  return { start, end, replacement: prefix + body + suffix,
    selectStart: start + prefix.length, selectEnd: start + prefix.length + body.length };
}
function replaceEditorRange(start, end, replacement) {
  const editor = $('editor'); editor.focus(); editor.setSelectionRange(start, end);
  const before = editor.value, expected = before.slice(0, start) + replacement + before.slice(end);
  let native = false, error = '';
  formatState.applying = true;
  try {
    if (typeof document.execCommand === 'function') {
      try { native = document.execCommand('insertText', false, replacement); }
      catch (failure) { error = 'Browser insertion unavailable: ' + failure.message + '. '; }
    }
    if (editor.value !== expected) {
      if (editor.value !== before) {
        editor.value = before;
        error += 'Browser insertion produced unexpected text; the draft was restored. ';
      }
      editor.setRangeText(replacement, start, end, 'end'); native = false;
    }
    if (editor.value !== expected) throw new Error('Editor insertion failed verification');
  } finally { formatState.applying = false; }
  return { native, error };
}
function applyFormat(kind) {
  const editor = $('editor');
  if (!state.page || state.loading || state.uploading || editor.readOnly || anyDialogOpen()) {
    $('format-status').textContent = 'Finish the current operation before formatting.'; return;
  }
  const before = editor.value, start = editor.selectionStart, end = editor.selectionEnd;
  if (kind === 'link' && start !== end && !WikiMarkdown.resolve(state.page.id, before.slice(start, end).split('|')[0])) {
    $('format-status').textContent = 'Select a valid wiki page name, or insert a link at the cursor.'; return;
  }
  const edit = formatEdit(kind, before, start, end);
  const expected = before.slice(0, edit.start) + edit.replacement + before.slice(edit.end);
  if (expected === before) { $('format-status').textContent = 'Selected lines already have this format.'; return; }
  let insertion;
  try { insertion = replaceEditorRange(edit.start, edit.end, edit.replacement); }
  catch (error) { editor.value = before; $('format-status').textContent = 'Could not format ' + state.page.id + ': ' + error.message + '. Draft preserved.'; return; }
  editor.setSelectionRange(edit.selectStart, edit.selectEnd);
  formatState.undo = { page: state.page.id, before, after: editor.value, start, end };
  $('format-undo').disabled = false;
  $('format-status').textContent = insertion.error + (insertion.native
    ? 'Formatting applied. Use Undo format or your browser’s Undo to revert.'
    : 'Formatting applied. Use Undo format to revert this change.');
  editorChanged();
}
for (const kind of ['bold', 'italic', 'heading', 'link', 'code', 'task', 'table']) {
  $('format-' + kind).addEventListener('pointerdown', event => { event.preventDefault(); });
  $('format-' + kind).addEventListener('click', () => applyFormat(kind));
}
$('format-undo').addEventListener('click', () => {
  const undo = formatState.undo, editor = $('editor');
  if (!undo || state.loading || state.uploading || editor.readOnly || anyDialogOpen()) return;
  if (state.page?.id !== undo.page || editor.value !== undo.after) {
    formatState.undo = null; $('format-undo').disabled = true;
    $('format-status').textContent = 'The editor changed. Undo format cannot overwrite newer text.'; return;
  }
  let insertion;
  try { insertion = replaceEditorRange(0, editor.value.length, undo.before); }
  catch (error) { editor.value = undo.after; $('format-status').textContent = 'Could not undo formatting: ' + error.message + '. Text preserved.'; return; }
  editor.setSelectionRange(undo.start, undo.end); formatState.undo = null;
  $('format-undo').disabled = true; $('format-status').textContent = insertion.error + 'Last formatting change undone.'; editorChanged();
});
$('editor').addEventListener('input', () => {
  if (formatState.applying) return;
  resetFormat();
  editorChanged();
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
$('export-open').addEventListener('click', openExport);
$('tasks-open').addEventListener('click', openTasks);
$('capture-open').addEventListener('click', openCapture);
$('capture-close').addEventListener('click', closeCapture);
$('capture-dialog').addEventListener('cancel', event => { event.preventDefault(); closeCapture(); });
$('capture-form').addEventListener('submit', event => { event.preventDefault(); return submitCapture(); });
$('capture-text').addEventListener('keydown', event => {
  if (!event.isComposing && (event.ctrlKey || event.metaKey) && event.key === 'Enter') {
    event.preventDefault(); return submitCapture();
  }
});
$('tasks-close').addEventListener('click', closeTasks);
$('tasks-dialog').addEventListener('cancel', event => { event.preventDefault(); closeTasks(); });
$('tasks-refresh').addEventListener('click', () => { if (!taskState.busy) return loadTasks(); });
$('tasks-query').addEventListener('input', () => { taskState.limit = 100; renderTasks(); });
for (const id of ['tasks-state', 'tasks-folder', 'tasks-tag', 'tasks-due']) {
  $(id).addEventListener('change', () => { taskState.limit = 100; renderTasks(); });
}
$('tasks-more').addEventListener('click', () => { taskState.limit += 100; renderTasks(); });
$('export-start').addEventListener('click', runExport);
$('export-cancel').addEventListener('click', closeExport);
$('export-dialog').addEventListener('cancel', event => { event.preventDefault(); closeExport(); });
$('tag-filter').addEventListener('change', () => { selectedTag = $('tag-filter').value; renderTree(treePages || state.pages); });
$('page-history').addEventListener('click', openHistory);
$('history-close').addEventListener('click', closeHistory);
$('history-restore').addEventListener('click', restoreHistoryVersion);
$('history-dialog').addEventListener('cancel', event => { event.preventDefault(); closeHistory(); });
$('switcher-open').addEventListener('click', openSwitcher);
$('switcher-close').addEventListener('click', closeSwitcher);
$('switcher-dialog').addEventListener('cancel', event => { event.preventDefault(); closeSwitcher(); });
$('switcher-query').addEventListener('input', () => { if (!switcherState.busy) renderSwitcher(); });
$('switcher-query').addEventListener('keydown', event => {
  if (event.isComposing || switcherState.busy) return;
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    switcherState.selected = Math.max(0, Math.min(switcherState.matches.length - 1,
      switcherState.selected + (event.key === 'ArrowDown' ? 1 : -1)));
    updateSwitcherSelection();
  } else if (event.key === 'Enter') { event.preventDefault(); return activateSwitcher(); }
  else if (event.key === 'Escape') { event.preventDefault(); closeSwitcher(); }
});
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
$('page-template').addEventListener('change', loadTemplate);
$('prompt-value').addEventListener('input', previewTemplate);
$('prompt-form').addEventListener('submit', async event => {
  event.preventDefault();
  const id = $('prompt-value').value.trim().replaceAll(':', '/');
  const resolved = WikiMarkdown.resolve('', id);
  if (!resolved || resolved.id !== id) { $('prompt-error').textContent = 'Use a valid page name, with / between folders.'; return; }
  const button = $('prompt-form').querySelector('button[type="submit"]'); button.disabled = true;
  $('prompt-value').disabled = true; $('page-template').disabled = true; $('prompt-cancel').disabled = true;
  try {
    if (state.prompt === 'create' && (templateState.loading || templateState.error)) {
      throw new Error(templateState.loading ? 'Wait for the template to finish loading.' : templateState.error);
    }
    const content = state.prompt === 'create' ? templateText(templateState.source, id) : null;
    if (!(await ensureSaved())) throw new Error('Save your current draft first.');
    if (state.prompt === 'rename') {
      const old = state.page.id;
      await api('/api/rename', { id: old, destination: id, revision: state.page.revision }); clearDraft(old);
      renameNavigation(old, id);
    } else await api('/api/page', { id, content, revision: '' });
    $('prompt-dialog').close(); await refresh(); await openPage(id);
  } catch (error) { $('prompt-error').textContent = error.message; }
  finally {
    button.disabled = false; $('prompt-value').disabled = false;
    $('page-template').disabled = false; $('prompt-cancel').disabled = false;
  }
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
function searchPages(delay = 120) {
  clearTimeout(searchTimer); const request = ++state.searchRequest, query = $('search').value;
  const run = async () => {
    try {
      const result = await api('/api/state?q=' + encodeURIComponent(query));
      if (request === state.searchRequest && query === $('search').value) renderTree(result.pages, result.terms || []);
    } catch (error) { if (request === state.searchRequest) message(error.message); }
  };
  if (delay === 0) return run();
  searchTimer = setTimeout(run, delay);
}
$('search').addEventListener('input', () => { renderSavedSearches(); searchPages(); });
$('menu').addEventListener('click', () => {
  const open = document.querySelector('.workspace').classList.toggle('menu-open'); $('menu').setAttribute('aria-expanded', String(open));
});
document.querySelectorAll('[data-mode]').forEach(node => node.addEventListener('click', () => setMode(node.dataset.mode)));
$('outline-toggle').addEventListener('click', toggleOutline);
$('outline-close').addEventListener('click', closeOutline);
$('verse-open').addEventListener('click', openVerse);
$('verse-close').addEventListener('click', closeVerse);
$('verse-cancel').addEventListener('click', closeVerse);
$('verse-refresh').addEventListener('click', fetchVerse);
$('verse-translation').addEventListener('change', fetchVerse);
$('verse-insert').addEventListener('click', insertVerse);
$('verse-dialog').addEventListener('cancel', event => { event.preventDefault(); closeVerse(); });
document.addEventListener('selectionchange', captureDictionarySelection);
$('editor').addEventListener('select', captureDictionarySelection);
$('dictionary-open').addEventListener('pointerdown', captureDictionarySelection);
$('dictionary-open').addEventListener('click', openDictionary);
$('dictionary-close').addEventListener('click', closeDictionary);
$('dictionary-form').addEventListener('submit', event => { event.preventDefault(); return lookupDictionary(); });
$('dictionary-word').addEventListener('input', () => {
  ++dictionaryState.request;
  $('dictionary-results').replaceChildren();
  $('dictionary-status').textContent = 'Press Find to look up this word.';
});
$('dictionary-word').addEventListener('keydown', event => { if (event.key === 'Escape') closeDictionary(); });
window.addEventListener('keydown', event => {
  if ($('capture-dialog').open) return;
  if (!event.isComposing && (event.ctrlKey || event.metaKey) && event.shiftKey && event.key.toLowerCase() === 'j') {
    event.preventDefault(); openCapture(); return;
  }
  if ($('tasks-dialog').open) return;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'p') {
    if (!anyDialogOpen()) {
      event.preventDefault(); openSwitcher();
    }
  }
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') { event.preventDefault(); save(); }
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); $('search').focus(); $('search').select(); }
});
window.addEventListener('beforeunload', event => {
  if (state.dirty || state.uploading || captureState.busy || backupState.busy || folderState.busy || $('capture-text').value.trim()) {
    rememberDraft(); event.preventDefault(); event.returnValue = '';
  }
});
window.addEventListener('resize', () => { if (innerWidth <= 950 && state.mode === 'split') setMode('edit'); });
async function checkExternal() {
  if (state.loading || state.uploading || state.saving || $('search').value || anyDialogOpen()) return;
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
