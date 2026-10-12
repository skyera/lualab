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
    this.classList = { toggle(name, value) { const enabled = value ?? !classes.has(name); if (enabled) classes.add(name); else classes.delete(name); return enabled; }, remove: name => classes.delete(name), contains: name => classes.has(name) };
  }
  append(...nodes) { this.children.push(...nodes); }
  contains(node) { return this === node || this.children.some(child => child.contains?.(node)); }
  replaceChildren(...nodes) { this.children = nodes; this.textContent = ''; }
  addEventListener(name, run) { this.handlers[name] = run; }
  setAttribute() {}
  focus() { this.focused = true; }
  select() {}
  scrollIntoView() {}
  showModal() { this.open = true; }
  close() { this.open = false; }
  setRangeText(text, start, end) { this.value = this.value.slice(0, start) + text + this.value.slice(end); this.selectionStart = this.selectionEnd = start + text.length; }
  querySelectorAll(tag) { return this.children.flatMap(n => [...(n.tagName?.toLowerCase() === tag ? [n] : []), ...(n.querySelectorAll?.(tag) || [])]); }
  querySelector() { return this.querySelectorAll('button')[0] || new Node('button'); }
}
const texts = node => [node.textContent, ...node.children.map(texts)].join('');
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
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
  const context = { URLSearchParams, TextEncoder, console, innerWidth: 1200,
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
  context.refresh = async () => {};
  return { context, state, get, events, stored, markdown, timers };
}
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
