// Execute the actual editor handlers and Markdown renderer with controlled responses.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
class Node {
  constructor(tag = 'div', text = '') {
    this.tagName = tag.toUpperCase(); this.textContent = text; this.children = []; this.handlers = {};
    this.value = ''; this.hidden = false; this.dataset = {}; this.className = ''; this.open = false;
    const classes = new Set();
    this.classList = { toggle(name, value) { const enabled = value ?? !classes.has(name); if (enabled) classes.add(name); else classes.delete(name); return enabled; }, add: name => classes.add(name), remove: name => classes.delete(name), contains: name => classes.has(name) };
  }
  append(...nodes) { this.children.push(...nodes); }
  contains(node) { return this === node || this.children.some(child => child.contains?.(node)); }
  replaceChildren(...nodes) { this.children = nodes; this.textContent = ''; }
  addEventListener(name, run) { this.handlers[name] = run; }
  setAttribute() {}
  focus() { this.focused = true; }
  select() {}
  setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  scrollIntoView() {}
  showModal() { this.open = true; }
  close() { this.open = false; }
  setRangeText(text, start, end) { this.value = this.value.slice(0, start) + text + this.value.slice(end); this.selectionStart = this.selectionEnd = start + text.length; }
  querySelectorAll(tag) { return this.children.flatMap(n => [...(n.tagName?.toLowerCase() === tag ? [n] : []), ...(n.querySelectorAll?.(tag) || [])]); }
  querySelector() { return this.querySelectorAll('button')[0] || new Node('button'); }
}
const texts = node => [node.textContent, ...node.children.map(texts)].join('');
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
test('quick capture shortcut appends a task without navigating or changing an unrelated draft', async () => {
  const { context, state, get, events } = harness();
  state.dirty = true; get('editor').value = 'Unrelated unsaved text';
  let prevented = false;
  events.keydown({ ctrlKey: true, shiftKey: true, key: 'J', preventDefault() { prevented = true; } });
  assert.equal(prevented, true); assert.equal(get('capture-dialog').open, true);
  const date = vm.runInContext('captureState.date', context);
  assert.match(get('capture-target').textContent, new RegExp(date));
  get('capture-kind').value = 'task';
  get('capture-text').setRangeText('Remember ', 0, 0);
  get('capture-text').setRangeText('学习', 9, 9);
  let payload;
  context.api = async (route, body) => {
    if (route.startsWith('/api/page?')) { const error = new Error('Missing'); error.status = 404; throw error; }
    assert.equal(route, '/api/capture'); payload = body;
    return { id: `Journal/${date.slice(0, 4)}/${date.slice(5, 7)}/${date}`, revision: 'saved', content: '- [ ] Remember 学习' };
  };
  await get('capture-text').handlers.keydown({ ctrlKey: true, key: 'Enter', preventDefault() {} });
  assert.equal(payload.text, 'Remember 学习'); assert.equal(payload.kind, 'task'); assert.equal(payload.revision, '');
  assert.equal(payload.date, date); assert.equal(state.page.id, 'Home');
  assert.equal(get('editor').value, 'Unrelated unsaved text'); assert.equal(state.dirty, true);
  assert.equal(get('capture-text').value, ''); assert.match(get('capture-status').textContent, /Added to/);
});
test('capture saves the open journal draft before appending and updates its editor revision', async () => {
  const { context, state, get } = harness();
  get('capture-open').handlers.click();
  const date = vm.runInContext('captureState.date', context);
  const id = `Journal/${date.slice(0, 4)}/${date.slice(5, 7)}/${date}`;
  state.page = { id, title: date, content: 'Old', revision: 'r1' }; state.pages = [state.page];
  state.dirty = true; get('editor').value = 'Draft'; get('capture-text').value = 'New note'; get('capture-kind').value = 'note';
  const routes = [];
  context.api = async (route, body) => {
    routes.push(route);
    if (route === '/api/page') { assert.equal(body.content, 'Draft'); return { id, revision: 'r2', content: 'Draft' }; }
    assert.equal(body.revision, 'r2'); return { id, revision: 'r3', content: 'Draft\n\nNew note\n' };
  };
  await get('capture-form').handlers.submit({ preventDefault() {} });
  assert.deepEqual(routes, ['/api/page', '/api/capture']);
  assert.equal(state.page.revision, 'r3'); assert.equal(get('editor').value, 'Draft\n\nNew note\n');
  assert.equal(state.dirty, false); assert.equal(get('editor').readOnly, false);
  state.blocked = true; get('capture-text').value = 'Keep this';
  await get('capture-form').handlers.submit({ preventDefault() {} });
  assert.equal(routes.length, 2); assert.equal(get('capture-text').value, 'Keep this');
  assert.match(get('capture-error').textContent, /draft first/);
});
test('capture failures retain input, cancel retains it, and empty input never submits', async () => {
  const { context, get, events } = harness(); let calls = 0;
  get('capture-open').handlers.click();
  context.api = async () => { calls++; throw new Error('Read failed'); };
  get('capture-text').value = '  \n'; await get('capture-form').handlers.submit({ preventDefault() {} });
  assert.equal(calls, 0); assert.match(get('capture-error').textContent, /Enter a thought/);
  get('capture-text').value = 'Keep <script> literal'; get('capture-kind').value = 'note';
  await get('capture-form').handlers.submit({ preventDefault() {} });
  assert.equal(calls, 1); assert.match(get('capture-error').textContent, /Read failed/);
  assert.equal(get('capture-text').value, 'Keep <script> literal');
  context.api = async route => {
    if (route.startsWith('/api/page?')) return { revision: 'r1' };
    const error = new Error('Journal changed'); error.status = 409; throw error;
  };
  await get('capture-form').handlers.submit({ preventDefault() {} });
  assert.match(get('capture-error').textContent, /Journal changed/);
  get('capture-dialog').handlers.cancel({ preventDefault() {} });
  assert.equal(get('capture-dialog').open, false); get('capture-open').handlers.click();
  assert.equal(get('capture-text').value, 'Keep <script> literal');
  let warned = false; events.beforeunload({ preventDefault() { warned = true; } }); assert.equal(warned, true);
});
test('capture blocks duplicate submits and dismissal during save, then distinguishes uncertain saves', async () => {
  const { context, get, events } = harness(); const pending = deferred(); let writes = 0;
  get('capture-open').handlers.click(); get('capture-text').value = 'Capture'; get('capture-kind').value = 'note';
  context.api = async route => {
    if (route.startsWith('/api/page?')) return { revision: 'r1' };
    writes++; return pending.promise;
  };
  const saving = get('capture-form').handlers.submit({ preventDefault() {} });
  await Promise.resolve(); await Promise.resolve();
  await get('capture-text').handlers.keydown({ metaKey: true, key: 'Enter', preventDefault() {} });
  get('capture-dialog').handlers.cancel({ preventDefault() {} });
  assert.equal(writes, 1); assert.equal(get('capture-dialog').open, true);
  events.keydown({ ctrlKey: true, key: 'p', preventDefault() {} }); assert.equal(get('switcher-dialog').open, false);
  pending.reject(new Error('Connection lost')); await saving;
  assert.equal(get('capture-text').value, 'Capture'); assert.match(get('capture-error').textContent, /may have completed/);
  assert.equal(get('capture-save').disabled, false);
  context.api = async route => route.startsWith('/api/page?') ? { revision: 'r1' } : { id: 'Journal/test', revision: 'r2' };
  context.refresh = async () => { throw new Error('Scan failed'); };
  await get('capture-form').handlers.submit({ preventDefault() {} });
  assert.equal(get('capture-text').value, ''); assert.match(get('capture-status').textContent, /Added/);
  assert.match(get('capture-error').textContent, /Capture saved.*Scan failed/);
});
test('capture shortcut respects existing dialogs and IME composition', () => {
  const { get, events } = harness();
  get('tasks-dialog').open = true;
  events.keydown({ ctrlKey: true, shiftKey: true, key: 'J', preventDefault() {} });
  assert.equal(get('capture-dialog').open, false);
  get('tasks-dialog').open = false;
  events.keydown({ ctrlKey: true, shiftKey: true, isComposing: true, key: 'J', preventDefault() {} });
  assert.equal(get('capture-dialog').open, false);
  get('capture-open').handlers.click();
  assert.equal(get('capture-dialog').open, true);
  get('tasks-open').handlers.click();
  assert.equal(get('tasks-dialog').open, false);
  get('export-open').handlers.click();
  assert.equal(get('export-dialog').open, false);
  get('switcher-open').handlers.click();
  assert.equal(get('switcher-dialog').open, false);
});
test('capture conflict on the open journal blocks its editor and keeps both drafts', async () => {
  const { context, state, get } = harness();
  get('capture-open').handlers.click();
  const date = vm.runInContext('captureState.date', context);
  state.page.id = `Journal/${date.slice(0, 4)}/${date.slice(5, 7)}/${date}`;
  get('capture-text').value = 'New thought'; get('capture-kind').value = 'note';
  context.api = async () => { const error = new Error('Journal changed'); error.status = 409; throw error; };
  await get('capture-form').handlers.submit({ preventDefault() {} });
  assert.equal(state.blocked, true); assert.equal(get('conflict').hidden, false);
  assert.equal(get('editor').value, 'Initial'); assert.equal(get('capture-text').value, 'New thought');
  assert.match(get('message').textContent, /Close Capture/);
});
test('task dashboard filters, safely renders long text and paginates without losing filters', async () => {
  const { context, get } = harness();
  const today = vm.runInContext('dateKey(new Date())', context);
  const rows = [
    { id: 'Work/学习', line: 2, text: '<img onerror=bad> ' + '长'.repeat(500), due: today, done: false, tags: ['work'] },
    { id: 'Home', line: 3, text: 'Later', due: '9999-01-01', done: true, tags: [] },
    { id: 'Work/Old', line: 1, text: 'Overdue', due: '2000-01-01', done: false, tags: ['work'] },
    ...Array.from({ length: 105 }, (_, i) => ({ id: 'Notes/' + i, line: 1, text: 'No date', due: '', done: false, tags: [] }))
  ];
  context.api = async () => ({ tasks: rows }); get('tasks-state').value = 'open';
  await get('tasks-open').handlers.click();
  assert.equal(get('tasks-dialog').open, true);
  assert.equal(get('tasks-results').children.length, 100);
  await get('tasks-more').handlers.click(); assert.equal(get('tasks-results').children.length, 107);
  get('tasks-folder').value = 'Work'; get('tasks-tag').value = 'work'; get('tasks-due').value = 'today';
  get('tasks-due').handlers.change();
  assert.equal(get('tasks-results').children.length, 1);
  assert.match(texts(get('tasks-results')), /<img onerror=bad>/);
  assert.equal(get('tasks-results').querySelectorAll('img').length, 0);
  get('tasks-query').value = 'missing'; get('tasks-query').handlers.input();
  assert.match(get('tasks-status').textContent, /No matching/);
  get('tasks-query').value = ''; get('tasks-due').value = 'overdue'; get('tasks-due').handlers.change();
  assert.match(texts(get('tasks-results')), /Overdue/);
  get('tasks-folder').value = ''; get('tasks-tag').value = ''; get('tasks-state').value = 'done';
  get('tasks-due').value = 'upcoming'; get('tasks-state').handlers.change();
  assert.match(texts(get('tasks-results')), /Later/);
  get('tasks-state').value = 'open'; get('tasks-due').value = 'none'; get('tasks-due').handlers.change();
  assert.equal(get('tasks-results').children.length, 100);
});
test('task loading errors and stale responses preserve filters and allow retry', async () => {
  const { context, get } = harness(); const pending = deferred();
  context.api = () => pending.promise;
  const loading = get('tasks-open').handlers.click(); await Promise.resolve(); await Promise.resolve();
  get('tasks-query').value = 'keep';
  get('tasks-dialog').handlers.cancel({ preventDefault() {} });
  pending.resolve({ tasks: [{ id: 'Stale', line: 1, text: 'Old', done: false }] }); await loading;
  assert.equal(get('tasks-dialog').open, false);
  assert.equal(vm.runInContext('taskState.items.length', context), 0);
  context.api = async () => { throw new Error('disk unreadable'); };
  await get('tasks-open').handlers.click();
  assert.match(get('tasks-error').textContent, /disk unreadable/);
  assert.equal(get('tasks-query').value, 'keep');
  context.api = async () => ({ tasks: [] }); await get('tasks-refresh').handlers.click();
  assert.equal(get('tasks-error').textContent, '');
  assert.match(get('tasks-status').textContent, /No matching/);
});
test('task checkboxes preserve failed edits and synchronize successful saves with the editor', async () => {
  const { context, state, get } = harness();
  const row = { id: 'Home', line: 1, text: 'Same', done: false, revision: 'r1', tags: [], due: '' };
  context.api = async () => ({ tasks: [row] }); get('tasks-state').value = 'all';
  await get('tasks-open').handlers.click();
  context.api = async () => { throw new Error('Task page changed. Refresh the task list.'); };
  let check = get('tasks-results').querySelectorAll('input')[0]; check.checked = true;
  await check.handlers.change(); assert.equal(row.done, false);
  assert.equal(get('editor').value, 'Initial'); assert.match(get('tasks-error').textContent, /changed/);
  let payload;
  context.api = async (route, body) => { payload = body; return { id: 'Home', revision: 'r3', content: '- [x] Same' }; };
  check = get('tasks-results').querySelectorAll('input')[0]; check.checked = true; await check.handlers.change();
  assert.equal(payload.revision, 'r1'); assert.equal(payload.line, 1); assert.equal(payload.done, true);
  assert.equal(state.page.revision, 'r3'); assert.equal(get('editor').value, '- [x] Same');
  assert.equal(row.done, true); assert.equal(state.loading, false);
  state.blocked = true; get('editor').value = 'Unsaved draft';
  check = get('tasks-results').querySelectorAll('input')[0]; check.checked = false; await check.handlers.change();
  assert.equal(get('editor').value, 'Unsaved draft'); assert.equal(row.done, true);
  assert.match(get('tasks-error').textContent, /draft/);
});
test('task source navigation selects the correct Unicode line and keeps failures visible', async () => {
  const { context, get } = harness();
  const row = { id: 'Home', line: 2, text: '学习', done: false, revision: 'r1', tags: [], due: '' };
  context.api = async route => route === '/api/tasks' ? { tasks: [row] }
    : { id: 'Home', title: 'Home', revision: 'r1', content: '# 中文\n- [ ] 学习\n' };
  await get('tasks-open').handlers.click();
  await get('tasks-results').querySelectorAll('button')[0].handlers.click();
  assert.equal(get('tasks-dialog').open, false);
  assert.equal(get('editor').selectionStart, '# 中文\n'.length);
  assert.equal(get('editor').selectionEnd, '# 中文\n- [ ] 学习'.length);
  await get('tasks-open').handlers.click();
  context.api = async () => { throw new Error('Page unreadable'); };
  await get('tasks-results').querySelectorAll('button')[0].handlers.click();
  assert.equal(get('tasks-dialog').open, true);
  assert.match(get('tasks-error').textContent, /Could not open/);
});
test('pending task saves block repeated changes, close and global shortcuts', async () => {
  const { context, get, events } = harness();
  const row = { id: 'Other', line: 1, text: 'Task', revision: 'r2', done: false };
  context.api = async () => ({ tasks: [row] });
  await get('tasks-open').handlers.click();
  const pending = deferred(); let calls = 0;
  context.api = () => { calls++; return pending.promise; };
  const check = get('tasks-results').querySelectorAll('input')[0]; check.checked = true;
  const saving = check.handlers.change(); await Promise.resolve(); await Promise.resolve();
  get('tasks-dialog').handlers.cancel({ preventDefault() {} });
  assert.equal(get('tasks-dialog').open, true); assert.equal(get('tasks-close').disabled, true);
  await check.handlers.change(); assert.equal(calls, 1);
  await events.keydown({ ctrlKey: true, key: 'p', preventDefault() {} });
  assert.equal(get('switcher-dialog').open, false);
  pending.resolve({ id: 'Other', revision: 'r3', content: '- [x] Task' }); await saving;
  assert.equal(get('tasks-close').disabled, false);
  get('tasks-close').handlers.click(); assert.equal(get('tasks-dialog').open, false);
});
test('export generator rejects empty scopes, changed revisions, missing files and oversized content', async () => {
  const { context } = harness();
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../static/export.js'), 'utf8'), context);
  const exporter = vm.runInContext('WikiExport', context);
  const controller = new AbortController();
  await assert.rejects(exporter.generate('invalid', 'Home', controller.signal), /valid export scope/);
  context.fetch = async () => ({ ok: true, json: async () => ({ pages: [] }) });
  await assert.rejects(exporter.generate('notebook', '', controller.signal), /no saved pages/);
  const row = { id: 'Home', revision: 'expected' };
  context.fetch = async route => ({ ok: true, json: async () => route === '/api/state' ? { pages: [row] }
    : { id: 'Home', revision: 'changed', content: 'Text' } });
  await assert.rejects(exporter.generate('page', 'Home', controller.signal), /changed during export/);
  context.fetch = async route => route === '/api/state' ? { ok: true, json: async () => ({ pages: [row] }) }
    : { ok: false, json: async () => ({ error: 'Page missing' }) };
  await assert.rejects(exporter.generate('page', 'Home', controller.signal), /Page missing/);
  context.fetch = async route => ({ ok: true, json: async () => route === '/api/state' ? { pages: [row] }
    : { id: 'Home', revision: 'expected', content: 'x'.repeat(64 * 1024 * 1024 + 1) } });
  await assert.rejects(exporter.generate('page', 'Home', controller.signal), /64 MiB/);
});
test('HTML export uses saved content, downloads the requested scope and restores editor state', async () => {
  const { context, state, get } = harness();
  let args, downloaded;
  context.WikiExport = { generate: async (...values) => { args = values; return '<!doctype html>'; },
    download: (...values) => { downloaded = values; } };
  get('export-open').handlers.click();
  assert.equal(get('export-scope').value, 'page');
  await get('export-start').handlers.click();
  assert.equal(args[0], 'page'); assert.equal(args[1], 'Home');
  assert.equal(downloaded[1], 'Home.html'); assert.equal(get('editor').readOnly, false); assert.equal(state.loading, false);
  get('export-scope').value = 'notebook'; await get('export-start').handlers.click();
  assert.equal(downloaded[1], 'LeafWiki.html');
});

test('export cancellation, failures and unsaved conflicts never download partial data', async () => {
  const { context, state, get } = harness(); let downloads = 0;
  const pending = deferred();
  context.WikiExport = { generate: () => pending.promise, download() { downloads++; } };
  get('export-open').handlers.click(); const running = get('export-start').handlers.click();
  await Promise.resolve(); await Promise.resolve();
  get('export-cancel').handlers.click(); pending.resolve('Partial'); await running;
  assert.equal(downloads, 0); assert.equal(get('export-dialog').open, false);
  assert.equal(get('editor').readOnly, false); assert.equal(state.loading, false);
  get('export-open').handlers.click();
  context.WikiExport.generate = async () => { throw new Error('A page changed during export'); };
  await get('export-start').handlers.click(); assert.match(get('export-status').textContent, /page changed/);
  state.dirty = true; get('editor').value = 'Draft'; context.api = async () => { throw new Error('Conflict'); };
  await get('export-start').handlers.click(); assert.equal(downloads, 0); assert.equal(get('editor').value, 'Draft');
});
test('tag filters group pages across folders and preserve search matches', () => {
  const { context, state, get } = harness();
  state.pages = [{ id: 'A/One', title: 'One', tags: ['work', '学习'] }, { id: 'B/Two', title: 'Two', tags: ['work'] },
    { id: 'C/Other', title: 'Other', tags: [] }];
  context.renderTagFilter(); context.renderTree();
  assert.match(texts(get('tag-filter')), /#work \(2\)/);
  get('tag-filter').value = 'work'; get('tag-filter').handlers.change();
  assert.equal(get('tree').querySelectorAll('button').length, 2);
  context.renderTree([state.pages[0]]);
  get('tag-filter').value = '学习'; get('tag-filter').handlers.change();
  assert.equal(get('tree').querySelectorAll('button').length, 1);
  get('tag-filter').value = 'missing'; get('tag-filter').handlers.change();
  assert.match(texts(get('tree')), /No matching pages tagged/);
});
test('built-in templates preview and create Markdown through actual form handlers', async () => {
  const { context, get } = harness();
  const expected = { blank: '# 设计\n\n', study: '## Key ideas', meeting: '## Action items', journal: '## Highlights' };
  for (const [template, text] of Object.entries(expected)) {
    context.ask('create', 'Projects/设计');
    get('page-template').value = template; await get('page-template').handlers.change();
    assert.ok(get('template-preview').textContent.includes(text));
    let saved;
    context.api = async (route, payload) => { saved = payload; return {}; };
    context.openPage = async () => true;
    await get('prompt-form').handlers.submit({ preventDefault() {} });
    assert.equal(saved.id, 'Projects/设计'); assert.equal(saved.revision, '');
    assert.equal(saved.content, get('template-preview').textContent);
    assert.equal(get('prompt-dialog').open, false);
  }
  const expanded = context.templateText('{{title}} {{path}} {{date}} {{weekday}} {{unknown}}', 'Journal/2024/02/2024-02-29');
  assert.equal(expanded, '2024-02-29 Journal/2024/02/2024-02-29 2024-02-29 Thursday {{unknown}}');
  context.ask('rename', 'Home'); assert.equal(get('template-fields').hidden, true);
});

test('custom templates load safely, expand once and ignore stale responses', async () => {
  const { context, state, get } = harness();
  state.pages.push({ id: 'Templates/学习', title: '学习' });
  context.ask('create', 'Notes/$&{{date}}');
  assert.equal(get('page-template').children.length, 5);
  const pending = deferred(); context.api = () => pending.promise;
  get('page-template').value = 'page:Templates/学习';
  const loading = get('page-template').handlers.change();
  assert.match(get('template-preview').textContent, /Loading/);
  await get('prompt-form').handlers.submit({ preventDefault() {} });
  assert.match(get('prompt-error').textContent, /finish loading/);
  get('page-template').value = 'study'; await get('page-template').handlers.change();
  pending.resolve({ content: 'Stale template' }); await loading;
  assert.match(get('template-preview').textContent, /Key ideas/);
  context.api = async () => ({ content: '# {{title}}\n{{path}}\n<script>unsafe</script>\n{{date}}' });
  get('page-template').value = 'page:Templates/学习'; await get('page-template').handlers.change();
  assert.match(get('template-preview').textContent, /# \$&\{\{date\}\}/);
  assert.equal(get('template-preview').children.length, 0);
  get('prompt-value').value = 'New/Name'; get('prompt-value').handlers.input();
  assert.match(get('template-preview').textContent, /# Name\nNew\/Name/);
});

test('template load failures and creation conflicts preserve the dialog and never overwrite a page', async () => {
  const { context, state, get } = harness();
  state.pages.push({ id: 'Templates/Bad', title: 'Bad' });
  context.ask('create', 'Home');
  context.api = async () => { throw new Error('Template missing'); };
  get('page-template').value = 'page:Templates/Bad'; await get('page-template').handlers.change();
  assert.match(get('prompt-error').textContent, /missing/);
  let calls = 0; context.api = async () => { calls++; return {}; };
  await get('prompt-form').handlers.submit({ preventDefault() {} }); assert.equal(calls, 0);
  get('page-template').value = 'blank'; await get('page-template').handlers.change();
  context.api = async (route, payload) => {
    assert.equal(payload.revision, ''); throw new Error('This page already exists');
  };
  await get('prompt-form').handlers.submit({ preventDefault() {} });
  assert.equal(get('prompt-dialog').open, true); assert.match(get('prompt-error').textContent, /already exists/);
  assert.equal(get('editor').value, 'Initial'); assert.equal(get('page-template').disabled, false);
});
test('page switcher filters locally, ranks names and handles keyboard boundary tokens', async () => {
  const { context, state, get, events } = harness();
  state.pages = [state.page, { id: 'Projects/Design', title: 'Design' },
    { id: 'Notes/Design ideas', title: 'Design ideas' }, { id: '学习/笔记', title: '笔记' }];
  context.document.activeElement = get('editor');
  context.api = async () => { throw new Error('Typing must not request the network'); };
  let prevented = false;
  events.keydown({ ctrlKey: true, key: 'p', preventDefault() { prevented = true; } });
  assert.equal(prevented, true); assert.equal(get('switcher-dialog').open, true);
  get('switcher-query').value = 'design'; get('switcher-query').handlers.input();
  assert.equal(get('switcher-results').children.length, 2);
  assert.match(texts(get('switcher-results').children[0]), /Projects \/ Design/);
  const key = value => get('switcher-query').handlers.keydown({ key: value, preventDefault() {} });
  key('ArrowUp'); assert.equal(get('switcher-results').children[0].classList.contains('selected'), true);
  key('ArrowDown'); key('ArrowDown'); assert.equal(get('switcher-results').children[1].classList.contains('selected'), true);
  let opened;
  context.openPage = async id => { opened = id; return true; };
  await key('Enter'); assert.equal(opened, 'Notes/Design ideas'); assert.equal(get('switcher-dialog').open, false);
  get('switcher-open').handlers.click();
  get('switcher-query').value = '学习:笔记'; get('switcher-query').handlers.input();
  assert.equal(get('switcher-results').children.length, 1);
  key('Escape'); assert.equal(get('switcher-dialog').open, false); assert.equal(get('editor').focused, true);
});

test('page switcher renders empty, long and hostile names and preserves unsaved drafts on failure', async () => {
  const { context, state, get } = harness();
  state.pages = []; get('switcher-open').handlers.click();
  assert.match(get('switcher-status').textContent, /No pages yet/);
  await get('switcher-query').handlers.keydown({ key: 'Enter', preventDefault() {} });
  state.pages = Array.from({ length: 80 }, (_, i) => ({ id: 'Folder/Page' + i, title: 'Page' + i }));
  state.pages.push({ id: '学习/<img src=x>/' + 'x'.repeat(150), title: '<img src=x>' });
  context.renderSwitcher(); assert.equal(get('switcher-results').children.length, 50);
  assert.match(get('switcher-status').textContent, /50 of 81/);
  get('switcher-query').value = '<img'; get('switcher-query').handlers.input();
  assert.equal(get('switcher-results').querySelectorAll('img').length, 0);
  assert.match(texts(get('switcher-results')), /<img src=x>/);
  get('switcher-query').value = 'missing'; get('switcher-query').handlers.input();
  assert.match(get('switcher-status').textContent, /No matching/);
  get('switcher-query').value = 'Page1'; get('switcher-query').handlers.input();
  state.dirty = true; get('editor').value = 'Unsaved draft';
  context.api = async () => { throw new Error('Injected save failure'); };
  await get('switcher-results').children[0].handlers.click();
  assert.equal(get('switcher-dialog').open, true); assert.equal(get('editor').value, 'Unsaved draft');
  assert.equal(state.page.id, 'Home'); assert.equal(state.dirty, true);
  assert.match(get('switcher-status').textContent, /save failure/);
  assert.equal(get('switcher-query').disabled, false);
});

test('page switcher preserves selection on refresh, avoids other modals and ignores IME Enter', async () => {
  const { context, get, events } = harness();
  get('history-dialog').open = true; get('switcher-open').handlers.click();
  assert.equal(get('switcher-dialog').open, false);
  get('history-dialog').open = false;
  events.keydown({ metaKey: true, key: 'p', preventDefault() {} });
  get('switcher-query').handlers.keydown({ key: 'ArrowDown', preventDefault() {} });
  context.renderSwitcher(true);
  assert.equal(get('switcher-results').children[1].classList.contains('selected'), true);
  let calls = 0; context.openPage = async () => { calls++; return true; };
  await get('switcher-query').handlers.keydown({ key: 'Enter', isComposing: true, preventDefault() {} });
  assert.equal(calls, 0);
  get('switcher-dialog').handlers.cancel({ preventDefault() {} });
  assert.equal(get('switcher-dialog').open, false);
});
test('history lists empty and populated versions, previews safe text and restores through handlers', async () => {
  const { context, state, get } = harness();
  const old = 'a'.repeat(64); let payload;
  context.api = async (route, data) => {
    if (route.startsWith('/api/history?')) return { current_revision: 'r1', versions: [] };
    throw new Error('Unexpected route');
  };
  await get('page-history').handlers.click();
  assert.match(get('history-status').textContent, /No earlier versions/);
  get('history-close').handlers.click();
  context.api = async (route, data) => {
    if (route.startsWith('/api/history?')) return { current_revision: 'r1', versions: [{ revision: old, saved_at: 1, bytes: 100 }] };
    if (route.startsWith('/api/version?')) return { revision: old, content: '<script>学习</script>' };
    if (route === '/api/history/restore') { payload = data; return { revision: old, content: '<script>学习</script>' }; }
    throw new Error('Unexpected route');
  };
  await get('page-history').handlers.click();
  await get('history-list').children[0].handlers.click();
  assert.equal(get('history-preview').textContent, '<script>学习</script>');
  assert.equal(get('history-preview').children.length, 0);
  await get('history-restore').handlers.click();
  assert.equal(payload.selected, old); assert.equal(payload.revision, 'r1');
  assert.equal(get('editor').value, '<script>学习</script>');
  assert.equal(state.dirty, false); assert.equal(get('editor').readOnly, false);
  assert.equal(get('history-dialog').open, false);
});

test('history ignores stale previews and closed-dialog responses; restore conflicts keep the current text', async () => {
  const { context, state, get } = harness();
  const first = deferred(), second = deferred(); let calls = 0;
  context.api = async route => route.startsWith('/api/history?')
    ? { current_revision: 'r1', versions: [{ revision: 'a', saved_at: 1, bytes: 0 }, { revision: 'b', saved_at: 2, bytes: 999999 }] }
    : (++calls === 1 ? first.promise : second.promise);
  await get('page-history').handlers.click();
  const one = get('history-list').children[0].handlers.click();
  const two = get('history-list').children[1].handlers.click();
  second.resolve({ revision: 'b', content: 'Newest preview' }); await two;
  first.resolve({ revision: 'a', content: 'Stale' }); await one;
  assert.equal(get('history-preview').textContent, 'Newest preview');
  context.api = async () => { throw new Error('Page changed. Reload history before restoring.'); };
  await get('history-restore').handlers.click();
  assert.match(get('history-status').textContent, /Page changed/);
  assert.equal(get('editor').value, 'Initial'); assert.equal(state.page.revision, 'r1');
  assert.equal(get('editor').readOnly, false);
  const pending = deferred(); context.api = () => pending.promise;
  const opening = get('page-history').handlers.click();
  await Promise.resolve(); await Promise.resolve();
  get('history-dialog').handlers.cancel({ preventDefault() {} });
  pending.resolve({ current_revision: 'r1', versions: [{ revision: 'late', saved_at: 1, bytes: 1 }] });
  await opening; assert.equal(get('history-dialog').open, false);
  assert.equal(get('history-list').children.length, 0);
});

test('history detects edits made before opening and protects drafts when saving fails', async () => {
  const { context, state, get } = harness();
  const old = 'a'.repeat(64);
  context.api = async route => route.startsWith('/api/history?')
    ? { current_revision: 'external', versions: [{ revision: old, saved_at: 1, bytes: 1024 * 1024 }] }
    : { revision: old, content: '学习<script>'.repeat(20000) };
  await get('page-history').handlers.click();
  await get('history-list').children[0].handlers.click();
  assert.match(get('history-status').textContent, /page changed/i);
  assert.equal(get('history-restore').disabled, true);
  assert.equal(get('history-preview').textContent.length, '学习<script>'.repeat(20000).length);
  await get('history-restore').handlers.click();
  assert.equal(get('editor').value, 'Initial');
  get('history-close').handlers.click();
  state.dirty = true; get('editor').value = 'Unsaved draft';
  context.api = async () => { throw new Error('Injected save failure'); };
  await get('page-history').handlers.click();
  assert.equal(get('history-dialog').open, false);
  assert.equal(get('editor').value, 'Unsaved draft'); assert.equal(state.dirty, true);
});
test('dictionary captures editor selection and renders definitions as safe text without editing the draft', async () => {
  const { context, state, get } = harness();
  get('editor').value = 'An ephemeral bloom'; get('editor').selectionStart = 3; get('editor').selectionEnd = 12;
  context.document.activeElement = get('editor'); state.dirty = true;
  get('editor').handlers.select();
  let route;
  context.api = async url => { route = url; return { word: 'ephemeral', senses: [{
    pos: 'adj.', definition: '<img src=x onerror=alert(1)>', example: 'An ephemeral bloom.', syn: 'temporary', ant: 'lasting'
  }] }; };
  get('dictionary-open').handlers.pointerdown();
  await get('dictionary-open').handlers.click();
  assert.equal(route, '/api/dictionary?word=ephemeral');
  assert.equal(get('dictionary-panel').hidden, false);
  assert.match(texts(get('dictionary-results')), /<img src=x onerror=alert\(1\)>/);
  assert.match(texts(get('dictionary-results')), /Synonyms: temporary/);
  assert.match(texts(get('dictionary-results')), /Antonyms: lasting/);
  assert.equal(get('dictionary-results').querySelectorAll('img').length, 0);
  assert.equal(get('editor').value, 'An ephemeral bloom'); assert.equal(state.dirty, true);
  get('dictionary-close').handlers.click(); assert.equal(get('dictionary-panel').hidden, true);
});

test('dictionary preview selection, empty input and stale responses use actual event handlers', async () => {
  const { context, get, events } = harness();
  const text = new Node('#text', '学习'); get('preview').append(text);
  context.window.getSelection = () => ({ anchorNode: text, focusNode: text, toString: () => '学习' });
  events['document:selectionchange']();
  const first = deferred(), second = deferred(); let calls = 0;
  context.api = () => (++calls === 1 ? first.promise : second.promise);
  const pending = get('dictionary-open').handlers.click();
  assert.equal(get('dictionary-word').value, '学习');
  get('dictionary-word').value = 'new'; get('dictionary-word').handlers.input();
  const latest = get('dictionary-form').handlers.submit({ preventDefault() {} });
  second.resolve({ word: 'new', senses: [{ definition: 'Newest' }] }); await latest;
  first.resolve({ word: '学习', senses: [{ definition: 'Old' }] }); await pending;
  assert.equal(texts(get('dictionary-results')), 'Newest');
  get('dictionary-word').value = ''; await get('dictionary-form').handlers.submit({ preventDefault() {} });
  assert.match(get('dictionary-status').textContent, /Enter a word/); assert.equal(calls, 2);
  get('dictionary-word').value = '学习'.repeat(81);
  await get('dictionary-form').handlers.submit({ preventDefault() {} });
  assert.match(get('dictionary-status').textContent, /240 UTF-8/); assert.equal(calls, 2);
});

test('dictionary errors, missing words and close during lookup keep the editor usable', async () => {
  const { context, get } = harness();
  get('dictionary-word').value = 'missing';
  context.api = async () => ({ word: 'missing', senses: [], message: 'No definition found.' });
  await get('dictionary-open').handlers.click(); assert.match(get('dictionary-status').textContent, /No definition/);
  context.api = async () => { throw new Error('Local dictionary unavailable'); };
  await get('dictionary-form').handlers.submit({ preventDefault() {} });
  assert.match(get('dictionary-status').textContent, /unavailable/);
  const response = deferred(); context.api = () => response.promise;
  const pending = get('dictionary-form').handlers.submit({ preventDefault() {} });
  get('dictionary-word').handlers.keydown({ key: 'Escape' });
  response.resolve({ word: 'late', senses: [{ definition: 'Late' }] }); await pending;
  assert.equal(get('dictionary-panel').hidden, true);
  assert.equal(get('dictionary-results').children.length, 0);
  assert.equal(get('editor').value, 'Initial');
});
function harness() {
  const nodes = new Map(), events = {}, stored = new Map(); let serial = 0;
  const timers = new Map();
  const get = id => { if (!nodes.has(id)) nodes.set(id, new Node()); return nodes.get(id); };
  const context = { URLSearchParams, TextEncoder, AbortController, console, innerWidth: 1200,
    setTimeout: fn => { timers.set(++serial, fn); return serial; }, clearTimeout: id => timers.delete(id),
    document: { addEventListener: (name, fn) => { events['document:' + name] = fn; },
      getElementById: get, createElement: tag => new Node(tag), createTextNode: text => new Node('#text', text),
      createDocumentFragment: () => new Node('fragment'), querySelectorAll: () => [], querySelector: () => get('workspace') },
    window: { addEventListener: (name, fn) => { events[name] = fn; } },
    localStorage: { getItem: key => stored.get(key), setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) },
    history: { replaceState() {} }, location: { hash: '', pathname: '/' }, navigator: { clipboard: { writeText: async () => {} } }, confirm: () => true,
  };
  vm.createContext(context);
  for (const file of ['markdown.js', 'app.js']) {
    let source = fs.readFileSync(path.join(__dirname, '../static', file), 'utf8');
    if (file === 'app.js') source = source.slice(0, source.lastIndexOf('start();'));
    vm.runInContext(source, context);
  }
  const state = vm.runInContext('state', context), markdown = vm.runInContext('WikiMarkdown', context);
  state.root = '/notebook'; state.page = { id: 'Home', title: 'Home', content: 'Initial', revision: 'r1' };
  state.pages = [state.page, { id: 'Other', title: 'Other', revision: 'r2' }]; get('editor').value = 'Initial';
  get('outline-panel').hidden = true; get('dictionary-panel').hidden = true;
  context.refresh = async () => {};
  return { context, state, get, events, stored, markdown, timers };
}
test('pinned pages persist, unpin, reload, and remain isolated by notebook', () => {
  const { context, state, get, stored } = harness();
  context.loadNavigation(); context.renderNavigation();
  assert.match(texts(get('pinned-pages')), /No pinned pages/);
  assert.match(texts(get('recent-pages')), /No recent pages/);
  get('pin-page').handlers.click();
  assert.equal(get('pin-page').textContent, '★ Unpin page');
  assert.equal(texts(get('pinned-pages')), '★ Home');
  assert.deepEqual(JSON.parse(stored.get('leaf-navigation:/notebook')).pinned, ['Home']);
  const reload = harness();
  reload.stored.set('leaf-navigation:/notebook', stored.get('leaf-navigation:/notebook'));
  reload.context.loadNavigation(); reload.context.renderNavigation();
  assert.equal(texts(reload.get('pinned-pages')), '★ Home');
  state.root = '/另一个 notebook'; context.loadNavigation(); context.renderNavigation();
  assert.match(texts(get('pinned-pages')), /No pinned pages/);
  get('pin-page').handlers.click();
  assert.ok(stored.has('leaf-navigation:/另一个 notebook'));
  state.root = '/notebook'; context.loadNavigation(); get('pin-page').handlers.click();
  assert.deepEqual(JSON.parse(stored.get('leaf-navigation:/notebook')).pinned, []);
  assert.equal(get('pin-page').textContent, '☆ Pin page');
});

test('recent pages record successful opens only, deduplicate, cap at ten, and navigate through save guards', async () => {
  const { context, state, get, stored } = harness();
  state.pages = Array.from({ length: 12 }, (_, index) => ({ id: 'Page' + index, title: 'Page' + index, revision: 'r1' }));
  context.api = async route => ({ id: decodeURIComponent(route.split('=')[1]), title: 'Page', content: 'Text', revision: 'r1' });
  for (const page of state.pages) assert.equal(await context.openPage(page.id), true);
  let recent = JSON.parse(stored.get('leaf-navigation:/notebook')).recent;
  assert.equal(recent.length, 10); assert.equal(recent[0], 'Page11'); assert.equal(recent[9], 'Page2');
  await context.openPage('Page5');
  recent = JSON.parse(stored.get('leaf-navigation:/notebook')).recent;
  assert.equal(recent[0], 'Page5'); assert.equal(new Set(recent).size, 10);
  const reload = harness();
  reload.state.pages = state.pages;
  reload.stored.set('leaf-navigation:/notebook', stored.get('leaf-navigation:/notebook'));
  reload.context.loadNavigation(); reload.context.renderNavigation();
  assert.equal(reload.get('recent-pages').querySelectorAll('button').length, 10);
  assert.equal(reload.get('recent-pages').children[0].textContent, 'Page5');
  state.dirty = true; get('editor').value = 'Keep this draft';
  context.api = async () => { throw new Error('Save failed'); };
  await get('recent-pages').children[1].handlers.click();
  assert.equal(state.page.id, 'Page5'); assert.equal(get('editor').value, 'Keep this draft');
  assert.deepEqual(JSON.parse(stored.get('leaf-navigation:/notebook')).recent, recent);
  state.dirty = false;
  assert.equal(await context.openPage('Page3'), false);
  assert.deepEqual(JSON.parse(stored.get('leaf-navigation:/notebook')).recent, recent);
});

test('page shortcuts preserve renames, hide trashed pages, restore them, and safely render long Unicode names', async () => {
  const { context, state, get, stored } = harness();
  get('pin-page').handlers.click();
  context.ask('rename', 'Home'); get('prompt-value').value = 'Notes/学习';
  context.api = async (route, body) => {
    if (route === '/api/rename') {
      assert.equal(body.id, 'Home'); state.pages[0] = { ...state.pages[0], id: body.destination }; return {};
    }
    return { id: 'Notes/学习', title: '学习', content: 'Initial', revision: 'r2' };
  };
  await get('prompt-form').handlers.submit({ preventDefault() {} });
  assert.deepEqual(JSON.parse(stored.get('leaf-navigation:/notebook')).pinned, ['Notes/学习']);
  assert.equal(texts(get('pinned-pages')), '★ Notes/学习');
  const page = state.pages.shift(); context.renderNavigation();
  assert.match(texts(get('pinned-pages')), /No pinned pages/);
  state.pages.unshift(page); context.renderNavigation();
  assert.equal(texts(get('pinned-pages')), '★ Notes/学习');
  state.page = { id: '学习'.repeat(60) + '<img>', title: '<script>bad</script>' };
  state.pages.push(state.page); get('pin-page').handlers.click();
  assert.match(texts(get('pinned-pages')), /<img>/);
  assert.equal(get('pinned-pages').querySelectorAll('img').length, 0);
  get('search').value = 'unrelated'; context.renderTree([]); context.renderNavigation();
  assert.equal(get('pinned-pages').querySelectorAll('button').length, 2);
  state.page = null; context.renderNavigation(); assert.equal(get('pin-page').disabled, true);
});

test('pinned shortcuts open through the actual navigation handler and saved duplicate lists normalize', async () => {
  const { context, state, get, stored } = harness();
  stored.set('leaf-navigation:/notebook', JSON.stringify({ pinned: ['Other', 'Other'], recent: ['Home', 'Home'] }));
  context.loadNavigation(); context.renderNavigation();
  assert.equal(get('pinned-pages').querySelectorAll('button').length, 1);
  assert.equal(get('recent-pages').querySelectorAll('button').length, 1);
  context.api = async () => ({ id: 'Other', title: 'Other', content: 'Opened', revision: 'r2' });
  await get('pinned-pages').children[0].handlers.click();
  assert.equal(state.page.id, 'Other'); assert.equal(get('editor').value, 'Opened');
  assert.equal(get('pin-page').textContent, '★ Unpin page');
  assert.deepEqual(JSON.parse(stored.get('leaf-navigation:/notebook')).recent, ['Other', 'Home']);
});

test('shortcut storage failures are visible, preserve malformed data, and verify writes before success', () => {
  for (const raw of ['{broken', '{"pinned":null,"recent":[]}', '{"pinned":[12],"recent":[]}', '{"pinned":["../bad"],"recent":[]}']) {
    const { context, get, stored } = harness();
    stored.set('leaf-navigation:/notebook', raw);
    context.loadNavigation(); get('pin-page').handlers.click();
    assert.match(get('shortcuts-status').textContent, /Could not load.*leaf-navigation:\/notebook/);
    assert.equal(stored.get('leaf-navigation:/notebook'), raw);
    assert.equal(texts(get('pinned-pages')), '★ Home');
  }
  const { context, get, stored } = harness(); context.loadNavigation();
  context.localStorage.setItem = () => { throw new Error('Quota exceeded'); };
  get('pin-page').handlers.click();
  assert.match(get('shortcuts-status').textContent, /Could not save.*Quota exceeded/);
  context.localStorage.setItem = () => {};
  get('pin-page').handlers.click();
  assert.match(get('shortcuts-status').textContent, /read-back verification/);
  context.localStorage.setItem = (key, value) => stored.set(key, value);
  get('pin-page').handlers.click(); assert.equal(get('shortcuts-status').textContent, '');
  const unavailable = harness();
  unavailable.context.localStorage.getItem = () => { throw new Error('Storage disabled'); };
  unavailable.context.loadNavigation(); unavailable.context.renderNavigation();
  assert.match(unavailable.get('shortcuts-status').textContent, /Storage disabled/);
});

test('safe preview renders empty, Unicode, code, tasks, links, images and hostile markup', () => {
  const { markdown } = harness();
  const pages = new Set(['Home', 'Other']); const navigation = [];
  const source = '# 学习\n<script>alert(1)</script>\n\n- [ ] A task\n- [x] Done\n\n[[Other|Go]] [[Missing]]\n'
    + '![image](Home.attachments/test.png)\n[evil](javascript:alert) **bold** *italic* `[[Literal]]`\n\n````js\n[[Code]]\n```\n[[Still code]]\n````';
  const frame = markdown.render(source, 'Home', pages, (...args) => navigation.push(args));
  assert.equal(frame.querySelectorAll('script').length, 0);
  assert.match(texts(frame), /<script>alert\(1\)<\/script>/);
  assert.equal(frame.querySelectorAll('img')[0].src, '/api/attachment?page=Home&file=test.png');
  const anchors = frame.querySelectorAll('a'); assert.equal(anchors.length, 2);
  anchors[0].handlers.click({ preventDefault() {} }); assert.equal(navigation[0][0], 'Other');
  assert.equal(anchors[1].className, 'missing');
  assert.equal(frame.querySelectorAll('input').length, 2);
  assert.equal(frame.querySelectorAll('pre').length, 1);
  assert.equal(markdown.render('', 'Home', pages, () => {}).children.length, 0);
  assert.equal(markdown.resolve('Projects/Design', './Tasks').id, 'Projects/Tasks');
  assert.equal(markdown.resolve('Home', '../escape'), null);
});
test('Markdown tables render alignment, inline formatting, links, and safe Unicode cells', () => {
  const { markdown } = harness(); const navigation = [];
  const source = '| Name | Center | Count |\r\n| :--- | :---: | ---: |\r\n'
    + '| **学习** | [[Other|Go]] | 123 |\r\n'
    + '| <script>bad</script> | [bad](javascript:alert) | *fine* |\r\n\r\nAfter';
  const frame = markdown.render(source, 'Home', new Set(['Other']), (...args) => navigation.push(args));
  assert.equal(frame.querySelectorAll('table').length, 1);
  assert.equal(frame.querySelectorAll('thead').length, 1);
  assert.equal(frame.querySelectorAll('tbody').length, 1);
  const headers = frame.querySelectorAll('th');
  assert.deepEqual(headers.map(node => node.className), ['align-left', 'align-center', 'align-right']);
  assert.ok(headers.every(node => node.scope === 'col'));
  assert.equal(frame.querySelectorAll('td').length, 6);
  assert.equal(frame.querySelectorAll('strong')[0].textContent, '学习');
  frame.querySelectorAll('a')[0].handlers.click({ preventDefault() {} });
  assert.equal(navigation[0][0], 'Other');
  assert.equal(frame.querySelectorAll('script').length, 0);
  assert.match(texts(frame), /<script>bad<\/script>/);
  assert.equal(frame.querySelectorAll('a').length, 1);
  assert.equal(frame.querySelectorAll('p').at(-1).children.at(-1).textContent, 'After');
});

test('Markdown table rows handle optional borders, escaped pipes, code spans, and uneven widths', () => {
  const { markdown } = harness();
  const source = 'A | B | C\n--- | --- | ---\n'
    + 'a\\|b | `x|y` | ``x`|y``\n'
    + '| short | |\n| one | two | three | ignored |\n\n| Only |\n| --- |';
  const frame = markdown.render(source, 'Home', new Set(), () => {});
  assert.equal(frame.querySelectorAll('table').length, 2);
  const cells = frame.querySelectorAll('td');
  assert.equal(texts(cells[0]), 'a|b');
  assert.equal(frame.querySelectorAll('code')[0].textContent, 'x|y');
  assert.equal(frame.querySelectorAll('code')[1].textContent, 'x`|y');
  assert.equal(cells.length, 9);
  assert.equal(texts(cells[4]), ''); assert.equal(texts(cells[5]), '');
  assert.doesNotMatch(texts(frame), /ignored/);
});

test('HTML export renders tables through the shared renderer and includes alignment and overflow styles', async () => {
  const { context } = harness(); let root;
  const create = context.document.createElement;
  context.document.createElement = tag => {
    const node = create(tag); if (tag === 'main') root = node; return node;
  };
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../static/export.js'), 'utf8'), context);
  const exporter = vm.runInContext('WikiExport', context);
  const page = { id: 'Home', revision: 'r1', content: '| Name | Count |\n| :--- | ---: |\n| 学习 | 123 |' };
  context.fetch = async route => ({ ok: true, json: async () => route === '/api/state' ? { pages: [page] } : page });
  const html = await exporter.generate('page', 'Home', new AbortController().signal);
  assert.equal(root.querySelectorAll('table').length, 1);
  assert.deepEqual(root.querySelectorAll('td').map(texts), ['学习', '123']);
  assert.match(html, /\.align-right\{text-align:right\}/);
  assert.match(html, /\.markdown-table\{[^}]*overflow-x:auto/);
});

test('Markdown table recognition rejects malformed dividers and preserves code and block boundaries', () => {
  const { markdown } = harness();
  for (const source of ['A | B\n-- | ---', 'A | B\n--- | --- | ---', 'A | B\n--- | nope', '', 'plain']) {
    assert.equal(markdown.render(source, 'Home', new Set(), () => {}).querySelectorAll('table').length, 0);
  }
  const frame = markdown.render('```\nA | B\n--- | ---\n```\n\n    A | B\n    --- | ---\n\n'
    + 'A | B\n--- | ---\n# Heading | text\n- List | item\n> Quote | text', 'Home', new Set(), () => {});
  assert.equal(frame.querySelectorAll('table').length, 1);
  assert.equal(frame.querySelectorAll('pre').length, 2);
  assert.equal(frame.querySelectorAll('h1').length, 1);
  assert.equal(frame.querySelectorAll('li').length, 1);
  assert.equal(frame.querySelectorAll('blockquote').length, 1);
});

test('journal calendar marks existing dates and navigates across month boundaries', () => {
  const { context, state, get } = harness();
  state.journalMonth = new Date(2026, 9, 1);
  state.journalDate = '2026-10-11';
  state.pages.push({ id: 'Journal/2026/10/2026-10-03', title: '2026-10-03' });
  context.renderJournal();
  assert.equal(get('journal-month-name').textContent, 'October 2026');
  assert.equal(get('journal-days').children.length, 42);
  const entry = get('journal-days').children.find(node => node.dataset.date === '2026-10-03');
  assert.equal(entry.classList.contains('has-entry'), true);
  assert.equal(get('journal-days').children.find(node => node.dataset.date === '2026-10-11')
    .classList.contains('selected'), true);
  get('journal-prev').handlers.click();
  assert.equal(get('journal-month-name').textContent, 'September 2026');
  get('journal-prev').handlers.click();
  assert.equal(get('journal-month-name').textContent, 'August 2026');
  get('journal-next').handlers.click(); get('journal-next').handlers.click();
  assert.equal(get('journal-month-name').textContent, 'October 2026');
});
test('selecting an empty journal date creates and opens a Markdown page', async () => {
  const { context, state, get } = harness();
  const id = 'Journal/2026/10/2026-10-11'; let created;
  state.journalMonth = new Date(2026, 9, 1);
  context.renderJournal();
  context.api = async (route, payload) => {
    if (route === '/api/page' && payload) { created = payload; return { id, revision: 'r2' }; }
    if (route.startsWith('/api/page?id=')) return { id, title: '2026-10-11', content: '# 2026-10-11\n\n', revision: 'r2', backlinks: [] };
    throw new Error('Unexpected request: ' + route);
  };
  context.refresh = async () => { state.pages.push({ id, title: '2026-10-11', revision: 'r2' }); };
  const day = get('journal-days').children.find(node => node.dataset.date === '2026-10-11');
  assert.equal(await day.handlers.click(), true);
  assert.equal(created.id, id); assert.equal(created.content, '# 2026-10-11 Sunday\n\n');
  assert.equal(state.page.id, id); assert.equal(get('title').textContent, '2026-10-11');
  assert.equal(await context.openJournalDate('2026-02-30'), false);
});
test('opening an older default journal heading adds weekday and keeps its entry', async () => {
  const { context, state } = harness();
  const id = 'Journal/2026/10/2026-10-11';
  let content = '# 2026-10-11\n\nMeeting notes\n', revision = 'r1', saved;
  state.pages.push({ id, title: '2026-10-11', revision });
  context.api = async (route, payload) => {
    if (route === '/api/page' && payload) {
      saved = payload.content; content = saved; revision = 'r2'; return { id, revision };
    }
    if (route.startsWith('/api/page?id=')) {
      return { id, title: '2026-10-11', content, revision, backlinks: [] };
    }
    throw new Error('Unexpected request: ' + route);
  };
  context.refresh = async () => {};
  assert.equal(await context.openJournalDate('2026-10-11'), true);
  assert.equal(saved, '# 2026-10-11 Sunday\n\nMeeting notes\n');
  assert.equal(state.page.content, saved);
});
test('actual input and Ctrl S handlers preserve edits typed while a save is pending', async () => {
  const { context, state, get, events } = harness();
  const pending = deferred(), writes = [];
  context.api = async (route, payload) => { writes.push(payload); return pending.promise; };
  get('editor').value = 'Submitted'; get('editor').handlers.input();
  let prevented = false;
  events.keydown({ ctrlKey: true, key: 's', preventDefault() { prevented = true; } });
  assert.equal(prevented, true); assert.equal(writes[0].revision, 'r1');
  get('editor').value = 'Newer edits'; get('editor').handlers.input();
  pending.resolve({ revision: 'r3' }); await state.saving;
  assert.equal(state.page.revision, 'r3'); assert.equal(state.page.content, 'Submitted');
  assert.equal(get('editor').value, 'Newer edits'); assert.equal(state.dirty, true);
  context.api = async () => ({ revision: 'r4' }); await context.save();
  assert.equal(state.dirty, false); assert.equal(get('save-status').textContent, '✓ Saved');
});
test('failed saves and revision conflicts preserve drafts and block navigation', async () => {
  const { context, state, get, stored } = harness();
  get('editor').value = 'My draft'; get('editor').handlers.input();
  context.api = async () => { throw new Error('Disk failure'); };
  assert.equal(await context.save(), false); assert.equal(state.dirty, true);
  assert.ok(stored.size); assert.equal(get('editor').value, 'My draft');
  context.api = async () => { const error = new Error('External change'); error.status = 409; throw error; };
  await context.save(); assert.equal(state.blocked, true); assert.equal(get('conflict').hidden, false);
  assert.equal(await context.openPage('Other'), false); assert.equal(state.page.id, 'Home');
});
test('page transitions restore drafts and render editor, preview, tree and backlinks', async () => {
  const { context, state, get, stored } = harness();
  context.api = async () => ({ id: 'Other', title: 'Other', content: '# Other', revision: 'r2', backlinks: [{ id: 'Home' }] });
  stored.set('leaf-draft:/notebook:Other', JSON.stringify({ content: 'Recovered draft', revision: 'r2' }));
  assert.equal(await context.openPage('Other'), true);
  assert.equal(get('editor').value, 'Recovered draft'); assert.equal(state.dirty, true);
  assert.equal(get('backlink-count').textContent, 1); assert.match(texts(get('backlinks')), /Home/);
  context.setMode('preview'); assert.equal(get('panes').className, 'preview');
  context.innerWidth = 320; context.setMode('split'); assert.equal(get('panes').className, 'edit');
  context.renderTree([]); assert.match(texts(get('tree')), /No pages/);
  state.dirty = false; context.ask('create', 'Missing'); assert.equal(get('prompt-dialog').open, true);
  context.ask('rename', 'Other'); assert.equal(get('prompt-title').textContent, 'Rename this page');
});
test('actual paste event uploads a clipboard file and saves the inserted image Markdown', async () => {
  const { context, state, get } = harness();
  const file = { type: 'image/png', size: 30 };
  const writes = [];
  context.fetch = async (route, options) => { assert.equal(options.body, file); return { ok: true, json: async () => ({ markdown: '![Image](Home.attachments/image.png)' }) }; };
  context.api = async (_, payload) => { writes.push(payload); return { revision: 'r5' }; };
  get('editor').selectionStart = get('editor').selectionEnd = 7;
  let prevented = false, uploading;
  const original = context.uploadImages;
  context.uploadImages = files => { uploading = original(files); return uploading; };
  get('editor').handlers.paste({ preventDefault() { prevented = true; }, clipboardData: { items: [{ kind: 'file', type: 'image/png', getAsFile: () => file }] } });
  await uploading;
  assert.equal(prevented, true); assert.equal(writes.length, 1);
  assert.match(writes[0].content, /Home.attachments\/image.png/); assert.equal(state.dirty, false);
  assert.equal(state.uploading, false);
});

test('trash dialogs, missing-page prompts and long tree names render through actual handlers', async () => {
  const { context, state, get, events } = harness();
  state.trash = [];
  await get('trash-list').handlers.click();
  assert.equal(get('trash-dialog').open, true); assert.equal(get('trashed-pages').textContent, 'Trash is empty.');
  get('trash-close').handlers.click(); assert.equal(get('trash-dialog').open, false);
  state.trash = [{ id: '学习/'.repeat(12) + 'Long page', token: 'abc' }];
  await get('trash-list').handlers.click(); assert.equal(get('trashed-pages').children.length, 1);
  await context.openPage('Missing'); assert.equal(get('prompt-value').value, 'Missing');
  get('prompt-cancel').handlers.click(); assert.equal(get('prompt-dialog').open, false);
  context.renderTree([{ id: 'Folder/' + '长'.repeat(70), title: '长'.repeat(70) }]);
  assert.match(texts(get('tree')), /长/);
  events.keydown({ ctrlKey: true, key: 'k', preventDefault() {} }); assert.equal(get('search').focused, true);
});

test('external revisions preserve editor text and stale search results cannot replace newer matches', async () => {
  const { context, state, get, timers } = harness();
  context.refresh = async () => { state.pages[0] = { ...state.pages[0], revision: 'external' }; };
  await context.checkExternal();
  assert.equal(state.blocked, true); assert.equal(get('editor').value, 'Initial');
  const first = deferred(), second = deferred(); let requests = 0;
  context.api = async () => (++requests === 1 ? first : second).promise;
  get('search').value = 'old'; get('search').handlers.input();
  const oldLoad = [...timers.values()].at(-1)();
  get('search').value = 'new'; get('search').handlers.input();
  const newLoad = [...timers.values()].at(-1)();
  second.resolve({ pages: [{ id: 'New', title: 'New' }] }); await newLoad;
  first.resolve({ pages: [{ id: 'Old', title: 'Old' }] }); await oldLoad;
  assert.match(texts(get('tree')), /New/); assert.doesNotMatch(texts(get('tree')), /Old/);
});

test('an external-change poll cannot flag a save that completed while the poll was pending', async () => {
  const { context, state, get } = harness();
  const pending = deferred();
  context.refresh = async () => pending.promise;
  get('conflict').hidden = true;
  const polling = context.checkExternal();
  get('editor').value = 'New content'; get('editor').handlers.input();
  context.api = async () => ({ revision: 'new-save' });
  await context.save();
  state.pages[0] = { id: 'Home', title: 'Home', revision: 'r1' };
  pending.resolve(); await polling;
  assert.equal(state.blocked, false); assert.equal(get('conflict').hidden, true);
  assert.equal(get('save-status').textContent, '✓ Saved');
});

test('search renders matching snippets and highlights query terms', async () => {
  const { context, get, timers } = harness();
  let requestedRoute;
  context.api = async route => {
    requestedRoute = route;
    return {
      pages: [{ id: 'Projects/Roadmap', title: 'Roadmap', snippet: '… quarterly budget allocations …' }],
      terms: ['budget']
    };
  };
  get('search').value = 'tag:work path:Projects budget';
  get('search').handlers.input();
  const searchPromise = [...timers.values()].at(-1)();
  await searchPromise;
  assert.equal(requestedRoute, '/api/state?q=' + encodeURIComponent('tag:work path:Projects budget'));
  const results = get('tree').children;
  assert.equal(results.length, 1);
  assert.equal(results[0].className.includes('tree-search-item'), true);
  assert.match(texts(results[0]), /Roadmap/);
  assert.match(texts(results[0]), /Projects \/ Roadmap/);
  assert.match(texts(results[0]), /quarterly budget allocations/);
  const marks = results[0].querySelectorAll('mark');
  assert.equal(marks.length >= 1, true);
  assert.equal(marks[0].textContent, 'budget');
});

test('page outline extracts headings, navigates editor lines and updates on live input', async () => {
  const { context, state, get, markdown } = harness();
  const sample = '# Project Title\n\nIntro text\n\n```js\n# Not a heading\n```\n\n## Architecture\n\nDesign notes\n\n### Data Flow\n\nFlow details\n\n## Deployment';
  const headings = markdown.headings(sample);
  assert.equal(headings.length, 4);
  assert.equal(headings[0].text, 'Project Title');
  assert.equal(headings[0].level, 1);
  assert.equal(headings[0].line, 1);
  assert.equal(headings[0].id, 'project-title');
  assert.equal(headings[1].text, 'Architecture');
  assert.equal(headings[1].level, 2);
  assert.equal(headings[1].line, 9);
  assert.equal(headings[2].text, 'Data Flow');
  assert.equal(headings[2].level, 3);
  assert.equal(headings[2].line, 13);
  assert.equal(headings[3].text, 'Deployment');
  assert.equal(headings[3].level, 2);
  assert.equal(headings[3].line, 17);

  // Test UI interactions
  state.page = { id: 'Doc', title: 'Doc', content: sample, revision: 'r1' };
  get('editor').value = sample;
  assert.equal(get('outline-panel').hidden, true);

  // Toggle outline open
  get('outline-toggle').handlers.click();
  assert.equal(get('outline-panel').hidden, false);
  assert.equal(get('page').classList.contains('outline-visible'), true);
  assert.match(get('outline-status').textContent, /4 headings/);
  const items = get('outline-list').children;
  assert.equal(items.length, 4);
  assert.equal(items[1].textContent, 'Architecture');
  assert.equal(items[1].className.includes('outline-level-2'), true);

  // Jump to heading "Architecture" (line 9)
  items[1].handlers.click();
  const updatedItems = get('outline-list').children;
  assert.equal(updatedItems[1].className.includes('active'), true);
  assert.equal(get('editor').focused, true);
  const lines = sample.split('\n');
  const expectedStart = lines.slice(0, 8).reduce((sum, line) => sum + line.length + 1, 0);
  assert.equal(get('editor').selectionStart, expectedStart);
  assert.equal(get('editor').selectionEnd, expectedStart + '## Architecture'.length);

  // Live input updates outline
  get('editor').value = '# Solitary Heading\n\nBody only';
  get('editor').handlers.input();
  assert.match(get('outline-status').textContent, /1 heading/);
  assert.equal(get('outline-list').children.length, 1);
  assert.equal(get('outline-list').children[0].textContent, 'Solitary Heading');

  // Empty headings fallback
  get('editor').value = 'Just plain paragraphs without headings';
  get('editor').handlers.input();
  assert.match(get('outline-status').textContent, /No headings/);
  assert.equal(get('outline-list').children.length, 0);

  // Toggle outline close
  get('outline-close').handlers.click();
  assert.equal(get('outline-panel').hidden, true);
  assert.equal(get('page').classList.contains('outline-visible'), false);
});

test('random Bible verse dialog fetches verse, handles errors, and inserts formatted Markdown blockquote', async () => {
  const { context, state, get } = harness();
  let requestedUrl = '';
  context.fetch = async url => {
    requestedUrl = url;
    return {
      ok: true,
      json: async () => ({
        translation: { identifier: 'web', name: 'World English Bible' },
        random_verse: { book: 'John', chapter: 3, verse: 16, text: 'For God so loved the world...' }
      })
    };
  };

  state.page = { id: 'Home', title: 'Home', content: 'Pre-existing text.', revision: 'r1' };
  get('editor').value = 'Pre-existing text.';
  get('editor').selectionStart = get('editor').value.length;
  get('editor').selectionEnd = get('editor').value.length;

  // Open Verse dialog
  get('verse-open').handlers.click();
  assert.equal(get('verse-dialog').open, true);
  await context.fetchVerse();
  assert.equal(requestedUrl, 'https://bible-api.com/data/web/random');
  assert.match(get('verse-text').textContent, /For God so loved the world/);
  assert.match(get('verse-ref').textContent, /John 3:16 \(WEB\)/);

  // Insert verse into note
  get('verse-insert').handlers.click();
  assert.equal(get('verse-dialog').open, false);
  assert.equal(state.dirty, true);
  assert.match(get('editor').value, /> For God so loved the world\.\.\./);
  assert.match(get('editor').value, /> — \*\*John 3:16 \(WEB\)\*\*/);

  // Error handling test
  context.fetch = async () => { throw new Error('Network unreachable'); };
  get('verse-open').handlers.click();
  await context.fetchVerse();
  assert.match(get('verse-text').textContent, /Could not load verse/);
  assert.match(get('verse-status').textContent, /Network unreachable/);
  assert.equal(get('verse-insert').disabled, true);
  get('verse-close').handlers.click();
  assert.equal(get('verse-dialog').open, false);
});
