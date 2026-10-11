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
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = nodes; }
  addEventListener(name, handler) { this.handlers[name] = handler; }
  setAttribute() {}
  removeAttribute() {}
  scrollIntoView() {}
  querySelectorAll(selector) {
    const matches = node => selector.startsWith('.')
      ? (node.className || '').split(' ').includes(selector.slice(1))
      : node.tagName.toLowerCase() === selector;
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
    URL, console, setTimeout, clearTimeout,
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
    if (route === '/api/words?due=1') return due.promise;
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
