'use strict';
const $ = (id) => document.getElementById(id);
const state = { view: 'search', busy: false, daily: null, words: [], queue: [], proverbs: [], reviewed: 0, total: 0, revealed: false, grading: false, reviewRequest: 0 };
const sourceNames = { all: 'All dictionaries', local: 'Local dictionary', 'dict.cn': 'dict.cn · 海词', youdao: 'Youdao · 有道', iciba: 'Iciba · 词霸', 'merriam-webster': 'Merriam-Webster (archived)' };
const dictionarySources = ['local', 'dict.cn', 'youdao', 'iciba'];
function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function button(text, action, className = 'secondary', kbd = null) {
  const node = element('button', text, className);
  node.type = 'button';
  if (kbd) {
    const badge = element('span', kbd, 'kbd-badge');
    node.append(badge);
  }
  node.addEventListener('click', action);
  return node;
}
function pronounceWord(text) {
  if (!('speechSynthesis' in window) || !text) return;
  const speech = new SpeechSynthesisUtterance(text);
  speech.lang = /[\u3400-\u9fff]/.test(text) ? 'zh-CN' : 'en-US';
  window.speechSynthesis.cancel();
  window.speechSynthesis.speak(speech);
}
function playProverbAudio(url, fallbackText) {
  if (url) {
    let secureUrl = url;
    if (secureUrl.startsWith('http://')) {
      secureUrl = 'https://' + secureUrl.slice(7);
    }
    const audio = new Audio(secureUrl);
    const promise = audio.play();
    if (promise !== undefined) {
      promise.catch(() => {
        pronounceWord(fallbackText);
      });
      return;
    }
  }
  pronounceWord(fallbackText);
}
async function api(path, payload) {
  const response = await fetch(path, payload === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload)
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'The request could not be completed.');
  return data;
}
function report(error) { $('app-message').textContent = error.message || String(error); }
function formatTime(stamp) { return new Date(stamp * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }); }
function selectedSource() { return document.querySelector('input[name="source"]:checked').value; }
function definitions(entry, target) {
  if (!entry) return;
  if (entry.phonetic) target.append(element('p', entry.phonetic, 'phonetic'));
  const list = element('ol', undefined, 'definitions');
  for (const text of entry.definitions || []) list.append(element('li', text));
  target.append(list);
  const syns = Array.isArray(entry.synonyms)
    ? entry.synonyms
    : (typeof entry.syn === 'string' ? entry.syn.split(/[,;]/).map(s => s.trim()).filter(Boolean) : []);
  if (syns.length) {
    const wrap = element('div', undefined, 'synonyms-wrap');
    wrap.append(element('span', 'Synonyms:', 'synonyms-label'));
    for (const syn of syns.slice(0, 8)) {
      const chip = button(syn, () => searchWord(syn), 'synonym-chip');
      chip.setAttribute('aria-label', `Look up synonym ${syn}`);
      wrap.append(chip);
    }
    target.append(wrap);
  }
  if (entry.examples?.length) {
    const examples = element('div', undefined, 'examples');
    for (const item of entry.examples) {
      const isObj = typeof item === 'object' && item !== null;
      const text = isObj ? item.text : String(item);
      const enText = isObj ? (item.en || text.split(' / ')[0]) : text.split(' / ')[0];
      const audioUrl = isObj ? item.audio_url : null;
      const row = element('div', undefined, 'example-row');
      row.append(element('p', text));
      const listenBtn = button('🔊 Listen', () => playProverbAudio(audioUrl, enText), 'example-audio-btn');
      listenBtn.setAttribute('aria-label', `Listen to sentence: ${enText}`);
      row.append(listenBtn);
      examples.append(row);
    }
    target.append(examples);
  }
}
function sourceLink(url) {
  const link = element('a', 'Open source ↗');
  // Source URLs are server-generated, but allow only known HTTPS providers.
  const parsed = new URL(url);
  if (parsed.protocol === 'https:' && ['dict.cn', 'www.youdao.com', 'www.iciba.com'].includes(parsed.hostname)) link.href = url;
  link.target = '_blank'; link.rel = 'noopener noreferrer';
  return link;
}
function buildResultCard(data) {
  const card = element('article', undefined, 'result-card');
  const top = element('div', undefined, 'result-top');
  top.append(element('h2', data.word), element('span', sourceNames[data.source], 'source-tag'));
  card.append(top);
  if (data.entry?.via === 'public-page') card.append(element('p', 'Public-page lookup', 'source-tag'));
  if ('speechSynthesis' in window) {
    card.append(button('Listen to this word ♫', () => pronounceWord(data.word), 'text-button speak'));
  }
  if (data.error) card.append(element('p', data.error, 'error'));
  if (data.stale) card.append(element('p', 'Showing an earlier saved definition.', 'source-tag'));
  definitions(data.entry || data.stale, card);
  if (!data.id) {
    const bottom = element('div', undefined, 'result-bottom');
    bottom.append(element('span', data.stale ? 'Lookup not saved · Existing history unchanged' : 'Not saved — no definition found'));
    if (data.source_url) bottom.append(sourceLink(data.source_url));
    card.append(bottom);
    return card;
  }
  if (data.source === 'youdao') card.append(element('p', 'Youdao definitions are available for this lookup only. Add your own note to review later.', 'source-tag'));
  const noteId = `study-note-${data.source}-${data.collection || 'web'}-${data.id}`;
  const label = element('label', 'Your study note', 'note-label');
  label.htmlFor = noteId;
  const note = element('textarea', undefined, 'study-note');
  note.id = noteId; note.value = data.note || ''; note.maxLength = 4000;
  note.placeholder = 'Write a meaning in your own words, a memory cue, or an example…';
  const noteActions = element('div', undefined, 'note-actions');
  const noteStatus = element('span', '', 'source-tag'); noteStatus.setAttribute('role', 'status');
  const save = button('Save note', async () => {
    save.disabled = true; noteStatus.textContent = 'Saving…';
    try { await api('/api/note', { id: data.id, collection: data.collection, note: note.value }); noteStatus.textContent = data.collection === 'tui' ? 'Note saved · shared with TUI' : 'Note saved'; }
    catch (error) { noteStatus.textContent = error.message; }
    finally { save.disabled = false; }
  });
  noteActions.append(save, noteStatus); card.append(label, note, noteActions);
  const bottom = element('div', undefined, 'result-bottom');
  bottom.append(element('span', `✓ In your journal · ${data.lookup_count} lookup${data.lookup_count === 1 ? '' : 's'}${data.cached ? ' · Saved definition' : ''}${data.collection === 'tui' ? ' · Shared with TUI' : ''}`));
  if (data.source_url) bottom.append(sourceLink(data.source_url));
  card.append(bottom);
  return card;
}
function renderResult(data) {
  const results = data.results || [data];
  $('result').replaceChildren(...results.map(buildResultCard)); $('result').hidden = false;
}
async function searchAll(word) {
  const slots = dictionarySources.map(source => {
    const card = element('article', undefined, 'result-card');
    card.append(element('span', sourceNames[source], 'source-tag'), element('p', 'Looking up this word…'));
    return card;
  });
  $('result').replaceChildren(...slots); $('result').hidden = false;
  let completed = 0;
  const results = await Promise.all(dictionarySources.map(async (source, index) => {
    let data;
    try {
      data = await api('/api/search', { word, source });
      slots[index].replaceWith(buildResultCard(data));
    } catch (error) {
      data = {source, error: error.message};
      slots[index].replaceChildren(element('span', sourceNames[source], 'source-tag'), element('p', error.message, 'error'));
    }
    completed++;
    $('search-status').textContent = `${completed} of ${dictionarySources.length} dictionaries checked…`;
    return data;
  }));
  const found = results.filter(data => data.entry).length;
  const saved = results.filter(data => data.saved).length;
  $('search-status').textContent = `${found} of ${dictionarySources.length} dictionaries returned definitions. ${saved ? 'Successful lookups saved; failed lookups were not added.' : 'No new history saved.'}`;
}
async function searchWord(word, source = selectedSource()) {
  if (state.busy || state.grading) return;
  if (source !== 'all' && !dictionarySources.includes(source)) source = 'all';
  state.busy = true;
  $('query').value = word;
  const sourceInput = [...document.querySelectorAll('input[name="source"]')].find(input => input.value === source);
  if (sourceInput) sourceInput.checked = true;
  await showView('search');
  $('search-button').disabled = true;
  $('query').readOnly = true;
  document.querySelectorAll('input[name="source"]').forEach(input => { input.disabled = true; });
  $('search-status').textContent = `Looking up “${word}” with ${sourceNames[source]}…`;
  $('app-message').textContent = '';
  try {
    if (source === 'all') {
      await searchAll(word);
    } else {
      const data = await api('/api/search', { word, source });
      renderResult(data);
      $('search-status').textContent = data.saved ? 'A new discovery, safely saved.' : 'Lookup failed. No new history saved.';
    }
    await refreshCounts();
  } catch (error) { $('search-status').textContent = error.message; }
  finally {
    state.busy = false; $('search-button').disabled = false; $('query').readOnly = false;
    document.querySelectorAll('input[name="source"]').forEach(input => { input.disabled = false; });
  }
}
async function refreshCounts() {
  const [data, proverbsData] = await Promise.all([api('/api/words'), api('/api/proverbs')]);
  state.words = data.words;
  state.proverbs = proverbsData.proverbs || [];
  $('word-count').textContent = String(data.words.length);
  $('due-count').textContent = String(data.words.filter(word => word.due_at <= Date.now() / 1000).length);
  if ($('proverbs-count')) $('proverbs-count').textContent = String(state.proverbs.length);
  if (state.view === 'words') renderWords();
  if (state.view === 'proverbs') renderProverbs();
}
function renderProverbs() {
  const filter = ($('proverb-filter')?.value || '').trim().toLocaleLowerCase();
  const proverbs = state.proverbs.filter(p => (p.text && p.text.toLocaleLowerCase().includes(filter)) || (p.chinese && p.chinese.toLocaleLowerCase().includes(filter)));
  if ($('proverbs-status')) $('proverbs-status').textContent = `${proverbs.length} saved proverb${proverbs.length === 1 ? '' : 's'}`;
  const fragment = document.createDocumentFragment();
  for (const p of proverbs) {
    const row = element('article', undefined, 'word-row');
    const copy = element('div');
    copy.append(element('h2', `“${p.text}”`), element('p', p.chinese, 'chinese'));
    if (p.explanation) copy.append(element('p', p.explanation));
    copy.append(element('p', `${p.date || 'Saved'} · Collected Wisdom`, 'word-meta'));
    const actions = element('div', undefined, 'word-actions');
    const listen = button('🔊 Listen', () => playProverbAudio(p.audio_url, p.text), 'secondary');
    listen.setAttribute('aria-label', `Listen to proverb: ${p.text}`);
    actions.append(listen);
    row.append(copy, actions);
    fragment.append(row);
  }
  if (!proverbs.length) {
    fragment.append(empty(filter ? 'No matching proverbs.' : 'No proverbs saved yet.', filter ? 'Try a different keyword.' : 'Proverbs are saved automatically when fetched.', false));
  }
  if ($('proverb-list')) $('proverb-list').replaceChildren(fragment);
}
async function fetchNextProverb(trigger) {
  if (trigger) trigger.disabled = true;
  $('app-message').textContent = '';
  try {
    const res = await api('/api/proverb/random');
    if (res.proverb) {
      if (state.daily) state.daily.proverb = res.proverb;
      $('daily-proverb').textContent = `“${res.proverb.text}”`;
      $('daily-chinese').textContent = res.proverb.chinese;
      $('daily-explanation').textContent = res.proverb.explanation || '';
      const audioBtn = $('daily-proverb-audio');
      if (audioBtn) audioBtn.hidden = false;
      await refreshCounts();
    }
  } catch (err) {
    report(err);
  } finally {
    if (trigger) trigger.disabled = false;
  }
}
function empty(title, subtitle, action) {
  const container = element('div', undefined, 'empty');
  container.append(element('h2', title), element('p', subtitle));
  if (action) container.append(button('Discover a word ↗', () => showView('search'), 'primary'));
  return container;
}
async function deleteWord(word, trigger) {
  const scope = word.collection === 'tui'
    ? 'This removes the word, notes, review history, and matching web history from both the web app and TUI. Imported dictionary definitions remain.'
    : 'This removes this saved entry, its notes, and review progress.';
  if (!window.confirm(`Delete “${word.word}”?\n\n${scope}`)) return;
  trigger.disabled = true;
  $('app-message').textContent = '';
  try {
    await api('/api/delete', { id: word.id, collection: word.collection });
    state.queue = state.queue.filter(item => word.collection === 'tui'
      ? item.word.toLocaleLowerCase() !== word.word.toLocaleLowerCase()
      : !(item.id === word.id && item.collection === word.collection));
    state.total = state.reviewed + state.queue.length;
    $('result').replaceChildren(); $('result').hidden = true;
    await refreshCounts();
    $('words-status').textContent += ` · Deleted “${word.word}”`;
    // Reload the daily selection if removing a shared word changed the TUI deck.
    if (word.collection === 'tui') await loadDaily();
  } catch (error) { report(error); }
  finally { trigger.disabled = false; }
}
function renderWords() {
  const filter = $('word-filter').value.trim().toLocaleLowerCase();
  const words = state.words.filter(word => word.word.toLocaleLowerCase().includes(filter));
  $('words-status').textContent = `${words.length} saved entr${words.length === 1 ? 'y' : 'ies'}`;
  const fragment = document.createDocumentFragment();
  for (const word of words) {
    const row = element('article', undefined, 'word-row');
    const copy = element('div');
    copy.append(element('h2', word.word), element('p', word.note || word.entry?.definitions?.[0] || 'Add your own study note when you look up this word.'));
    const history = word.collection === 'tui' ? 'Shared with TUI' : `${word.lookup_count} lookup${word.lookup_count === 1 ? '' : 's'}`;
    copy.append(element('p', `${sourceNames[word.source]} · ${history} · Last seen ${formatTime(word.last_seen)} · ${word.due_at <= Date.now() / 1000 ? 'Ready for review' : 'Next review ' + formatTime(word.due_at)}`, 'word-meta'));
    const actions = element('div', undefined, 'word-actions');
    const remove = button('Delete', () => deleteWord(word, remove), 'secondary delete-button');
    remove.setAttribute('aria-label', `Delete ${word.word}`);
    actions.append(button('Look up ↗', () => searchWord(word.word, word.source)), remove);
    row.append(copy, actions);
    fragment.append(row);
  }
  if (!words.length) fragment.append(empty(filter ? 'No matching words.' : 'Your first word is waiting.', filter ? 'Try a different filter.' : 'Look up something new. It will appear here automatically.', !filter));
  $('word-list').replaceChildren(fragment);
}
async function gradeWord(word, remembered, gradeValue) {
  if (state.grading) return;
  state.grading = true;
  const actions = document.querySelector('.review-actions');
  if (actions) actions.querySelectorAll('button').forEach(node => { node.disabled = true; });
  try {
    await api('/api/review', { id: word.id, collection: word.collection, remembered, grade: gradeValue });
    state.queue.shift();
    state.reviewed++;
    state.revealed = false;
    renderReview();
    await refreshCounts();
  } catch (error) {
    report(error);
  } finally {
    state.grading = false;
    if (actions) actions.querySelectorAll('button').forEach(node => { node.disabled = false; });
  }
}

function renderReview() {
  const target = $('review-card'); target.replaceChildren();
  $('review-progress').textContent = `${state.reviewed} of ${state.total} reviewed this session`;
  if (!state.queue.length) {
    target.append(empty(state.total ? 'A little wiser already.' : 'You’re all caught up.', state.total ? 'Your next reviews are scheduled. Come back for another small step.' : 'New words appear here as soon as you look them up.', true));
    return;
  }
  const word = state.queue[0];
  target.append(element('p', sourceNames[word.source], 'eyebrow'), element('h2', word.word));
  if (!state.revealed) {
    target.append(element('p', 'What does this word mean?', 'study-answer'), button('Reveal meaning', () => { state.revealed = true; renderReview(); }, 'primary', 'Space'));
    target.append(element('p', 'Shortcuts: [Space] reveal · [P] pronounce', 'review-shortcuts-hint'));
    return;
  }
  if (word.note) target.append(element('p', word.note, 'study-answer'));
  definitions(word.entry, target);
  if (!word.note && !word.entry) {
    target.append(element('p', 'This word has no saved meaning. Look it up and add a study note.', 'study-answer'), button('Look up & add note ↗', () => searchWord(word.word, word.source)));
  }
  const actions = element('div', undefined, 'review-actions');
  const grades = word.collection === 'tui'
    ? [['Again · 10 min', false, 'secondary', 0, '1'], ['Hard', true, 'secondary', 1, '2'], ['Good', true, 'primary', 2, '3'], ['Easy', true, 'secondary', 3, '4']]
    : [['Again · 10 min', false, 'secondary', undefined, '1'], ['Remembered ✓', true, 'primary', undefined, '2']];
  for (const [label, remembered, style, gradeValue, kbd] of grades) {
    const grade = button(label, () => gradeWord(word, remembered, gradeValue), style, kbd);
    actions.append(grade);
  }
  target.append(actions);
  target.append(element('p', `Shortcuts: [1–${grades.length}] grade · [Space] confirm · [P] pronounce`, 'review-shortcuts-hint'));
}
async function showView(view) {
  if (state.grading) return;
  const reviewRequest = ++state.reviewRequest;
  state.view = view;
  $('app-message').textContent = '';
  for (const name of ['search', 'words', 'review', 'proverbs']) {
    const section = $(name + '-view');
    if (section) section.hidden = name !== view;
  }
  document.querySelectorAll('.nav-button').forEach(node => {
    node.classList.toggle('active', node.dataset.view === view);
    if (node.dataset.view === view) node.setAttribute('aria-current', 'page');
    else node.removeAttribute('aria-current');
  });
  try {
    if (view === 'words') { renderWords(); await refreshCounts(); }
    if (view === 'proverbs') { renderProverbs(); await refreshCounts(); }
    if (view === 'review') {
      $('review-progress').textContent = 'Preparing your words…';
      const data = await api('/api/words?due=1');
      if (state.view !== 'review' || reviewRequest !== state.reviewRequest) return;
      $('due-count').textContent = String(data.words.length);
      state.queue = data.words; state.reviewed = 0; state.total = data.words.length; state.revealed = false;
      renderReview();
    }
  } catch (error) { report(error); }
}
async function loadDaily() {
  const data = await api('/api/daily'); state.daily = data;
  $('daily-date').textContent = new Date(data.date + 'T12:00:00Z').toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
  $('daily-word').textContent = data.word.word; $('daily-meaning').textContent = data.word.meaning;
  $('daily-label').textContent = data.word.source === 'local' ? '01 / FROM YOUR LOCAL VOCABULARY' : '01 / WORD OF THE DAY';
  $('daily-example').textContent = data.word.example ? `“${data.word.example}”` : '';
  const exampleAudioBtn = $('daily-example-audio');
  if (exampleAudioBtn) {
    exampleAudioBtn.hidden = !data.word.example;
  }
  $('daily-proverb').textContent = `“${data.proverb.text}”`; $('daily-chinese').textContent = data.proverb.chinese;
  $('daily-explanation').textContent = data.proverb.explanation || '';
  const audioBtn = $('daily-proverb-audio');
  if (audioBtn) {
    audioBtn.hidden = false;
  }
}

let suggestTimer = null;
state.suggestIndex = -1;
state.suggestions = [];

function hideSuggestions() {
  const box = $('search-suggest');
  if (box) {
    box.hidden = true;
    box.replaceChildren();
  }
  state.suggestIndex = -1;
  state.suggestions = [];
}

function updateSuggestHighlight() {
  const box = $('search-suggest');
  if (!box) return;
  const items = box.querySelectorAll('.suggest-item');
  items.forEach((item, index) => {
    item.classList.toggle('active', index === state.suggestIndex);
    if (index === state.suggestIndex) item.scrollIntoView({ block: 'nearest' });
  });
}

function renderSuggestions(list) {
  const box = $('search-suggest');
  if (!box) return;
  state.suggestions = list;
  state.suggestIndex = -1;
  if (!list.length) {
    hideSuggestions();
    return;
  }
  const fragment = document.createDocumentFragment();
  list.forEach((item, index) => {
    const row = element('div', undefined, 'suggest-item');
    row.dataset.index = String(index);
    row.append(element('span', item.word, 'suggest-word'));
    if (item.snippet) row.append(element('span', item.snippet, 'suggest-snippet'));
    row.addEventListener('click', () => {
      hideSuggestions();
      searchWord(item.word);
    });
    fragment.append(row);
  });
  box.replaceChildren(fragment);
  box.hidden = false;
}

async function fetchSuggestions(query) {
  query = query.trim();
  if (!query) {
    hideSuggestions();
    return;
  }
  try {
    const data = await api('/api/suggest?q=' + encodeURIComponent(query));
    renderSuggestions(data.suggestions || []);
  } catch (_) {
    hideSuggestions();
  }
}

$('query').addEventListener('input', () => {
  clearTimeout(suggestTimer);
  suggestTimer = setTimeout(() => fetchSuggestions($('query').value), 120);
});

$('query').addEventListener('keydown', (event) => {
  const box = $('search-suggest');
  if (box && !box.hidden && state.suggestions.length) {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      state.suggestIndex = (state.suggestIndex + 1) % state.suggestions.length;
      updateSuggestHighlight();
      return;
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault();
      state.suggestIndex = (state.suggestIndex - 1 + state.suggestions.length) % state.suggestions.length;
      updateSuggestHighlight();
      return;
    }
    if (event.key === 'Enter' && state.suggestIndex >= 0) {
      event.preventDefault();
      const chosen = state.suggestions[state.suggestIndex].word;
      hideSuggestions();
      searchWord(chosen);
      return;
    }
    if (event.key === 'Escape') {
      event.preventDefault();
      hideSuggestions();
      return;
    }
  }
});

document.addEventListener('click', (event) => {
  if (!event.target.closest('#search-form')) {
    hideSuggestions();
  }
});

window.addEventListener('keydown', (event) => {
  if (['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)) return;
  if (state.view !== 'review' || !state.queue.length || state.grading) return;
  const word = state.queue[0];
  if (event.key === 'p' || event.key === 'P' || event.key === 'l' || event.key === 'L') {
    event.preventDefault();
    pronounceWord(word.word);
    return;
  }
  if (!state.revealed) {
    if (event.key === ' ' || event.key === 'Enter') {
      event.preventDefault();
      state.revealed = true;
      renderReview();
    }
    return;
  }
  const isTui = word.collection === 'tui';
  if (event.key === '1' || event.key === 'a' || event.key === 'A') {
    event.preventDefault();
    gradeWord(word, false, isTui ? 0 : undefined);
  } else if (event.key === '2') {
    event.preventDefault();
    gradeWord(word, true, isTui ? 1 : undefined);
  } else if (event.key === '3' && isTui) {
    event.preventDefault();
    gradeWord(word, true, 2);
  } else if (event.key === '4' && isTui) {
    event.preventDefault();
    gradeWord(word, true, 3);
  } else if (event.key === ' ' || event.key === 'Enter') {
    event.preventDefault();
    gradeWord(word, true, isTui ? 2 : undefined);
  }
});

$('search-form').addEventListener('submit', event => {
  event.preventDefault();
  hideSuggestions();
  searchWord($('query').value);
});
$('word-filter').addEventListener('input', renderWords);
$('daily-lookup').addEventListener('click', () => { if (state.daily) searchWord(state.daily.word.word, state.daily.word.source || selectedSource()); });
$('daily-example-audio')?.addEventListener('click', () => {
  if (state.daily?.word?.example) {
    pronounceWord(state.daily.word.example);
  }
});
$('daily-proverb-audio')?.addEventListener('click', () => {
  if (state.daily?.proverb) {
    playProverbAudio(state.daily.proverb.audio_url, state.daily.proverb.text);
  }
});
$('daily-proverb-next')?.addEventListener('click', (e) => {
  fetchNextProverb(e.currentTarget);
});
$('proverb-filter')?.addEventListener('input', renderProverbs);
document.querySelectorAll('.nav-button').forEach(node => node.addEventListener('click', () => showView(node.dataset.view)));
Promise.all([loadDaily(), refreshCounts()]).catch(report);
setInterval(() => {
  if (!document.hidden && state.daily?.date !== new Date().toISOString().slice(0, 10)) loadDaily().catch(report);
}, 60000);
