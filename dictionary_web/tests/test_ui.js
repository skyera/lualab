// Execute the real browser event handlers with controlled DOM and API responses.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Node {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.textContent = '';
    this.value = '';
    this.hidden = false;
    this.children = [];
    this.dataset = {};
    this.handlers = {};
    const classes = new Set();
    this.classList = { toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name) };
  }
  append(...nodes) {
    for (const node of nodes) { node.parent = this; this.children.push(node); }
  }
  replaceChildren(...nodes) {
    for (const node of this.children) node.parent = null;
    this.children = [];
    this.append(...nodes);
  }
  replaceWith(node) {
    const index = this.parent.children.indexOf(this);
    this.parent.children[index] = node;
    node.parent = this.parent;
    this.parent = null;
  }
  addEventListener(name, handler) { this.handlers[name] = handler; }
  setAttribute() {}
  removeAttribute() {}
  scrollIntoView() {}
  querySelectorAll(selector) {
    const matches = node => selector.split(',').some(part => part.startsWith('.')
      ? (node.className || '').split(' ').includes(part.slice(1))
      : node.tagName.toLowerCase() === part);
    return this.children.flatMap(node => [...(matches(node) ? [node] : []), ...node.querySelectorAll(selector)]);
  }
}
function harness() {
  const nodes = new Map();
  const get = id => {
    if (!nodes.has(id)) nodes.set(id, new Node());
    return nodes.get(id);
  };
  const handlers = {};
  const context = {
    URL, URLSearchParams, console, setTimeout, clearTimeout,
    document: {
      activeElement: { tagName: 'BODY' },
      getElementById: get,
      createElement: tag => new Node(tag),
      createDocumentFragment: () => new Node('fragment'),
      querySelectorAll: () => [],
      querySelector: selector => selector === '.review-actions'
        ? get('review-card').querySelectorAll('.review-actions')[0] || null : { value: 'all' },
      addEventListener: (name, handler) => { handlers['document:' + name] = handler; },
    },
    window: { addEventListener: (name, handler) => { handlers[name] = handler; } },
    localStorage: { getItem: () => null, setItem() {} },
  };
  vm.createContext(context);
  const source = fs.readFileSync(path.join(__dirname, '..', 'static', 'app.js'), 'utf8');
  // Skip startup network traffic, retaining all functions and actual event listeners.
  vm.runInContext(source.slice(0, source.indexOf('Promise.all([loadDaily(), refreshCounts()])')), context);
  context.refreshCounts = async () => {};
  const state = vm.runInContext('state', context);
  const key = (key, input = false) => {
    const event = { key, preventDefault() {} };
    (input ? get('query').handlers.keydown : handlers.keydown)(event);
  };
  return { context, state, get, key };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const card = (id, collection = 'web') => ({ id, collection, source: 'local', word: 'word-' + id,
  entry: { definitions: ['Meaning ' + id], examples: [] }, note: '' });

test('review loading blocks mouse and keyboard grading; new queue remains intact', async () => {
  const { context, state, get, key } = harness();
  const due = deferred();
  const reviewed = [];
  context.api = async (route, payload) => {
    if (route.startsWith('/api/session?')) return due.promise;
    reviewed.push(payload.id);
    return {};
  };
  const old = card(1);
  state.queue = [old]; state.revealed = true;
  const entering = context.showView('review');
  assert.equal(state.reviewLoading, true);
  assert.equal(get('review-card').querySelectorAll('button').length, 0);
  await context.gradeWord(old, true);
  for (const token of [' ', 'ENTER', 'Enter', '1', '2', '3', '4']) key(token);
  assert.deepEqual(reviewed, []);
  due.resolve({ words: [card(2), old] });
  await entering;
  assert.equal(state.reviewLoading, false);
  await context.gradeWord(old, true); // A detached old-card callback must also be ignored.
  assert.deepEqual(reviewed, []);
  key(' '); // Reveal through the real key handler.
  assert.equal(state.revealed, true);
  key('2');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(reviewed, [2]);
  assert.deepEqual(Array.from(state.queue, word => word.id), [1]);
  assert.equal(state.reviewed, 1);
});

test('grading removes by ID and collection even if the queue changes during the request', async () => {
  const { context, state } = harness();
  const grade = deferred();
  context.api = () => grade.promise;
  state.view = 'review';
  const word = card(1, 'tui');
  state.queue = [word];
  const grading = context.gradeWord(word, true, 2);
  state.queue = [card(1, 'web'), word, card(2)];
  grade.resolve({});
  await grading;
  assert.deepEqual(Array.from(state.queue, item => [item.id, item.collection]), [[1, 'web'], [2, 'web']]);
});

test('review load failure and leaving a pending review restore usable state', async () => {
  const { context, state, get } = harness();
  state.queue = [card(1)];
  context.api = async () => { throw new Error('offline'); };
  await context.showView('review');
  assert.equal(state.reviewLoading, false);
  assert.equal(get('app-message').textContent, 'offline');
  assert.equal(get('review-card').querySelectorAll('button').length, 1);
  const due = deferred();
  context.api = () => due.promise;
  const pending = context.showView('review');
  await context.showView('search');
  due.resolve({ words: [card(2)] });
  await pending;
  assert.equal(state.view, 'search');
  assert.equal(state.reviewLoading, false);
  assert.equal(state.queue[0].id, 1);
});

test('suggestions ignore reversed responses, clears, Escape, errors and view changes', async () => {
  const { context, state, get, key } = harness();
  const requests = [];
  context.api = () => { const next = deferred(); requests.push(next); return next.promise; };
  get('query').value = 'a';
  const first = context.fetchSuggestions('a');
  get('query').value = 'ab';
  const second = context.fetchSuggestions('ab');
  requests[1].resolve({ suggestions: [{ word: 'about' }] });
  await second;
  requests[0].resolve({ suggestions: [{ word: 'apple' }] });
  await first;
  assert.equal(state.suggestions[0].word, 'about');
  key('ArrowDown', true);
  assert.equal(state.suggestIndex, 0);
  key('Escape', true);
  assert.equal(get('search-suggest').hidden, true);

  for (const action of ['clear', 'escape', 'view', 'input']) {
    state.view = 'search'; get('query').value = 'old';
    const pending = context.fetchSuggestions('old');
    if (action === 'clear') { get('query').value = ''; context.hideSuggestions(); }
    if (action === 'escape') key('Escape', true);
    if (action === 'view') await context.showView('words');
    if (action === 'input') { get('query').value = 'new'; get('query').handlers.input(); context.hideSuggestions(); }
    requests.at(-1).resolve({ suggestions: [{ word: 'old' }] });
    await pending;
    assert.equal(get('search-suggest').hidden, true, action);
  }
  state.view = 'search'; get('query').value = 'a';
  const failed = context.fetchSuggestions('a');
  get('query').value = 'ab';
  const current = context.fetchSuggestions('ab');
  requests.at(-1).resolve({ suggestions: [{ word: 'about' }] }); await current;
  requests.at(-2).reject(new Error('old request failed')); await failed;
  assert.equal(get('search-suggest').hidden, false);
  assert.equal(state.suggestions[0].word, 'about');
});

test('provider playback uses allowed HTTPS media and retains speech fallback', async () => {
  const { context } = harness();
  for (const url of ['https://audio.dict.cn/a.mp3', 'https://dict.youdao.com/dictvoice?audio=hello',
    'http://res.iciba.com/a.mp3', 'https://tts.iciba.com/a.mp3']) {
    assert.ok(context.providerAudioUrl(url).startsWith('https://'));
  }
  for (const url of ['javascript:alert(1)', 'https://evil.example/a.mp3', 'https://iciba.com.evil.example/a.mp3',
    'https://user:pass@audio.dict.cn/a.mp3', 'https://audio.dict.cn:8443/a.mp3', '/local.mp3', null]) {
    assert.equal(context.providerAudioUrl(url), null);
  }
  const audio = [], spoken = [];
  context.pronounceWord = text => spoken.push(text);
  context.Audio = class { constructor(url) { audio.push(url); } play() { return Promise.resolve(); } };
  context.playProverbAudio('http://res.iciba.com/a.mp3', 'hello');
  await Promise.resolve();
  assert.deepEqual(audio, ['https://res.iciba.com/a.mp3']);
  assert.deepEqual(spoken, []);
  context.Audio = class { play() { return Promise.reject(new Error('unavailable')); } };
  context.playProverbAudio('https://audio.dict.cn/a.mp3', 'fallback');
  await Promise.resolve();
  context.playProverbAudio('https://evil.example/a.mp3', 'blocked');
  assert.deepEqual(spoken, ['fallback', 'blocked']);
});

test('review renderers handle empty, web, shared, Unicode and long notes', () => {
  const { context, state, get } = harness();
  context.renderReview();
  assert.ok(get('review-card').children.length);
  for (const collection of ['web', 'tui']) {
    const word = card(1, collection); word.note = '学习 <script>text</script> '.repeat(100);
    state.queue = [word]; state.total = 1;
    state.revealed = false; context.renderReview();
    assert.equal(get('review-card').querySelectorAll('button').length, 1);
    state.revealed = true; context.renderReview();
    assert.equal(get('review-card').querySelectorAll('button').length, collection === 'tui' ? 4 : 2);
  }
});

test('All dictionaries keeps Iciba first when results finish out of order or fail', async () => {
  for (const failure of [false, true]) {
    const { context, get } = harness();
    const requests = new Map();
    context.api = (_, payload) => {
      const pending = deferred();
      requests.set(payload.source, pending);
      return pending.promise;
    };
    const searching = context.searchAll('hello');
    assert.equal([...requests.keys()][0], 'local');
    const names = () => get('result').children.map(row => row.querySelectorAll('.source-tag')[0].textContent);
    const expected = ['Iciba · 词霸', 'Local dictionary', 'dict.cn · 海词', 'Youdao · 有道'];
    assert.deepEqual(names(), expected);
    for (const source of ['youdao', 'local', 'dict.cn', 'iciba']) {
      if (source === 'iciba' && failure) requests.get(source).reject(new Error('unavailable'));
      else requests.get(source).resolve({ word: 'hello', source, entry: { definitions: ['Meaning'] } });
      await new Promise(resolve => setImmediate(resolve));
      assert.deepEqual(names(), expected);
    }
    await searching;
  }
});

test('organization filters and editors retain word identity and safely render labels', async () => {
  const { context, state, get } = harness();
  state.view = 'words';
  state.words = [
    { ...card(1, 'tui'), folder: 'Books', tags: ['Travel', '<tag>'] },
    { ...card(2), folder: 'Work', tags: ['verbs'] }
  ];
  context.refreshOrganizationFilters();
  assert.equal(get('word-folder').children.length, 3);
  get('word-folder').value = 'books'; context.refreshOrganizationFilters();
  assert.equal(get('word-folder').value, 'Books');
  get('word-tag').value = 'travel'; context.renderWords();
  assert.equal(get('word-list').children.length, 1);
  const editor = context.organizationForm(state.words[0]);
  const inputs = editor.querySelectorAll('input');
  inputs[0].value = 'Exam'; inputs[1].value = 'verbs, 学习';
  let saved;
  context.api = async (route, payload) => { saved = { route, payload }; return { saved: true }; };
  await editor.handlers.submit({ preventDefault() {} });
  assert.equal(saved.route, '/api/organize');
  assert.equal(saved.payload.id, 1); assert.equal(saved.payload.collection, 'tui');
  assert.equal(saved.payload.folder, 'Exam');
  assert.deepEqual(Array.from(saved.payload.tags), ['verbs', '学习']);
  get('word-tag').value = 'missing'; context.renderWords();
  assert.equal(get('words-status').textContent, '0 saved entries');
  assert.notEqual(context.organizationKey('École'), context.organizationKey('école'));
  assert.equal(context.organizationKey('Books'), context.organizationKey('books'));
});

test('review options generate the filtered session URL and lock during loading', async () => {
  const { context, state, get } = harness();
  for (const [id, value] of [['review-mode', 'overdue'], ['review-limit', '5'],
    ['review-folder', 'Books & study'], ['review-tag', '学习']]) {
    get(id).value = value;
    get(id).tagName = id === 'review-limit' ? 'INPUT' : 'SELECT';
    get('review-options').append(get(id));
  }
  const pending = deferred();
  let requested;
  context.api = route => { requested = route; return pending.promise; };
  const entering = context.showView('review');
  assert.ok(get('review-options').children.every(node => node.disabled));
  const query = new URL('http://local' + requested).searchParams;
  assert.equal(query.get('limit'), '5'); assert.equal(query.get('mode'), 'overdue');
  assert.equal(query.get('folder'), 'Books & study'); assert.equal(query.get('tag'), '学习');
  pending.resolve({ words: [card(1)], total_matching: 12 }); await entering;
  assert.equal(state.total, 1); assert.equal(state.sessionMatching, 12);
  assert.match(get('review-progress').textContent, /12 matching words/);
  assert.ok(get('review-options').children.every(node => !node.disabled));
});

test('restore requires confirmation, rejects invalid files and clears stale review/result IDs', async () => {
  const { context, state, get } = harness();
  const payload = { format: 'wordbook', version: 1, web: { words: [], proverbs: [], word_organization: [] } };
  const file = { size: 100, text: async () => JSON.stringify(payload) };
  let calls = 0;
  context.api = async () => { calls++; return { restored: true, web_words: 2, shared_words: 0 }; };
  context.window.confirm = () => false;
  await context.restoreBackup(file); assert.equal(calls, 0);
  await context.restoreBackup({ size: 16777217 }); assert.match(get('backup-status').textContent, /16 MB/);
  await context.restoreBackup({ size: 1, text: async () => '{bad' }); assert.equal(calls, 0);
  context.window.confirm = () => true;
  state.queue = [card(1)]; state.total = 1; state.revealed = true;
  await context.restoreBackup(file);
  assert.equal(calls, 1); assert.equal(state.queue.length, 0); assert.equal(state.revealed, false);
  assert.equal(get('result').hidden, true); assert.equal(state.restoring, false);
  assert.match(get('backup-status').textContent, /Restored 2/);
});

test('a pending restore blocks grading and navigation and recovers after failure', async () => {
  const { context, state, get } = harness();
  context.window.confirm = () => true;
  const pending = deferred(); context.api = () => pending.promise;
  const restoring = context.restoreBackup({ size: 50, text: async () => '{"format":"wordbook","version":1}' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(state.restoring, true); assert.equal(get('restore-button').disabled, true);
  const view = state.view;
  await context.showView('review'); assert.equal(state.view, view);
  pending.reject(new Error('Invalid backup')); await restoring;
  assert.equal(state.restoring, false); assert.equal(get('restore-button').disabled, false);
  assert.equal(get('backup-status').textContent, 'Invalid backup');
});
