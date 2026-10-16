// =============================================================================
// app.js
// Wordbook Frontend: Vocabulary Journal, Search, Audio & SRS Review
// =============================================================================

'use strict';

// -----------------------------------------------------------------------------
// State & Global Selectors
// -----------------------------------------------------------------------------

const $ = id => document.getElementById(id);

const state = {
  view: 'search',
  busy: false,
  daily: null,
  words: [],
  queue: [],
  proverbs: [],
  reviewed: 0,
  total: 0,
  revealed: false,
  grading: false,
  reviewLoading: false,
  reviewRequest: 0,
  restoring: false,
  sessionMatching: 0,
  statistics: null
};

const sourceNames = {
  all: 'All dictionaries',
  local: 'Local dictionary',
  'dict.cn': 'dict.cn · 海词',
  youdao: 'Youdao · 有道',
  iciba: 'Iciba · 词霸',
  'merriam-webster': 'Merriam-Webster (archived)'
};

const dictionarySources = ['iciba', 'local', 'dict.cn', 'youdao'];

// -----------------------------------------------------------------------------
// DOM Element Builders
// -----------------------------------------------------------------------------

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) {
    node.textContent = text;
  }
  if (className) {
    node.className = className;
  }
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

function empty(title, subtitle, action) {
  const container = element('div', undefined, 'empty');
  container.append(element('h2', title), element('p', subtitle));
  if (action) {
    container.append(button('Discover a word ↗', () => showView('search'), 'primary'));
  }
  return container;
}

// -----------------------------------------------------------------------------
// Text-to-Speech & Audio Playback
// -----------------------------------------------------------------------------

function findVoiceByGender(langPrefix, gender) {
  if (!('speechSynthesis' in window)) {
    return null;
  }
  const voices = window.speechSynthesis.getVoices().filter(v => (
    v.lang.toLowerCase().startsWith(langPrefix.toLowerCase())
  ));
  if (!voices.length) {
    return null;
  }
  const femaleNames = [
    'female', 'woman', 'zira', 'samantha', 'victoria', 'karen', 'susan',
    'cathy', 'tingting', 'huihui', 'yaoyao', 'xiaoxiao', 'xiaoyi', 'mei-jia', 'sin-ji'
  ];
  const maleNames = [
    'male', 'man', 'david', 'alex', 'daniel', 'george', 'fred',
    'kangkang', 'yunxi', 'yunjian', 'danny'
  ];
  const targets = gender === 'female' ? femaleNames : maleNames;
  const matched = voices.find(v => targets.some(name => v.name.toLowerCase().includes(name)));
  return matched || null;
}

function pronounceWord(text) {
  if (!('speechSynthesis' in window) || !text) {
    return;
  }
  const speech = new SpeechSynthesisUtterance(text);
  const isChinese = /[\u3400-\u9fff]/.test(text);
  const langPrefix = isChinese ? 'zh' : 'en';
  speech.lang = isChinese ? 'zh-CN' : 'en-US';

  const selectedGender = $('voice-select')?.value || localStorage.getItem('wordbook_voice') || 'auto';
  if (selectedGender === 'female') {
    const voice = findVoiceByGender(langPrefix, 'female');
    if (voice) {
      speech.voice = voice;
    } else {
      speech.pitch = 1.25;
    }
  } else if (selectedGender === 'male') {
    const voice = findVoiceByGender(langPrefix, 'male');
    if (voice) {
      speech.voice = voice;
    } else {
      speech.pitch = 0.82;
    }
  }
  window.speechSynthesis.cancel();
  window.speechSynthesis.speak(speech);
}

function providerAudioUrl(url) {
  try {
    const parsed = new URL(url);
    const allowed = ['audio.dict.cn', 'dict.youdao.com', 'iciba.com'].includes(parsed.hostname)
      || parsed.hostname.endsWith('.iciba.com');
    if (
      !allowed
      || !['http:', 'https:'].includes(parsed.protocol)
      || parsed.username
      || parsed.password
      || (parsed.port && parsed.port !== '443')
    ) {
      return null;
    }
    parsed.protocol = 'https:';
    return parsed.href;
  } catch (_) {
    return null;
  }
}

function playProverbAudio(url, fallbackText) {
  const secureUrl = providerAudioUrl(url);
  if (secureUrl) {
    try {
      const audio = new Audio(secureUrl);
      const promise = audio.play();
      if (promise !== undefined) {
        promise.catch(() => pronounceWord(fallbackText));
        return;
      }
    } catch (_) {
      /* Fall back when browser audio is unavailable. */
    }
  }
  pronounceWord(fallbackText);
}

// -----------------------------------------------------------------------------
// API Network Client & Format Helpers
// -----------------------------------------------------------------------------

async function api(path, payload) {
  const response = await fetch(path, payload === undefined ? {} : {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.error || 'The request could not be completed.');
  }
  return data;
}

function report(error) {
  $('app-message').textContent = error.message || String(error);
}

function formatTime(stamp) {
  return new Date(stamp * 1000).toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric'
  });
}

function selectedSource() {
  return document.querySelector('input[name="source"]:checked').value;
}

// -----------------------------------------------------------------------------
// Result Card & Definition Rendering
// -----------------------------------------------------------------------------

function definitions(entry, target) {
  if (!entry) {
    return;
  }
  if (entry.phonetic) {
    target.append(element('p', entry.phonetic, 'phonetic'));
  }
  const list = element('ol', undefined, 'definitions');
  for (const text of entry.definitions || []) {
    list.append(element('li', text));
  }
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
  if (
    parsed.protocol === 'https:'
    && ['dict.cn', 'www.youdao.com', 'www.iciba.com'].includes(parsed.hostname)
  ) {
    link.href = url;
  }
  link.target = '_blank';
  link.rel = 'noopener noreferrer';
  return link;
}

function buildResultCard(data) {
  const card = element('article', undefined, 'result-card');
  const top = element('div', undefined, 'result-top');
  top.append(element('h2', data.word), element('span', sourceNames[data.source], 'source-tag'));
  card.append(top);

  if (data.entry?.via === 'public-page') {
    card.append(element('p', 'Public-page lookup', 'source-tag'));
  }
  const wordAudioUrl = data.entry?.audio_url || data.stale?.audio_url;
  card.append(button('Listen to this word ♫', () => playProverbAudio(wordAudioUrl, data.word), 'text-button speak'));

  if (data.error) {
    card.append(element('p', data.error, 'error'));
  }
  if (data.stale) {
    card.append(element('p', 'Showing an earlier saved definition.', 'source-tag'));
  }
  definitions(data.entry || data.stale, card);

  if (!data.id) {
    const bottom = element('div', undefined, 'result-bottom');
    bottom.append(element(
      'span',
      data.stale ? 'Lookup not saved · Existing history unchanged' : 'Not saved — no definition found'
    ));
    if (data.source_url) {
      bottom.append(sourceLink(data.source_url));
    }
    card.append(bottom);
    return card;
  }

  if (data.source === 'youdao') {
    card.append(element(
      'p',
      'Youdao definitions are available for this lookup only. Add your own meaning or note to review later.',
      'source-tag'
    ));
  }
  card.append(meaningForm(data), exampleForm(data));

  const noteId = `study-note-${data.source}-${data.collection || 'web'}-${data.id}`;
  const label = element('label', 'Your study note', 'note-label');
  label.htmlFor = noteId;

  const note = element('textarea', undefined, 'study-note');
  note.id = noteId;
  note.value = data.note || '';
  note.maxLength = 4000;
  note.placeholder = 'Write a meaning in your own words, a memory cue, or an example…';

  const noteActions = element('div', undefined, 'note-actions');
  const noteStatus = element('span', '', 'source-tag');
  noteStatus.setAttribute('role', 'status');

  const save = button('Save note', async () => {
    save.disabled = true;
    noteStatus.textContent = 'Saving…';
    try {
      await api('/api/note', { id: data.id, collection: data.collection, note: note.value });
      noteStatus.textContent = data.collection === 'tui' ? 'Note saved · shared with TUI' : 'Note saved';
    } catch (error) {
      noteStatus.textContent = error.message;
    } finally {
      save.disabled = false;
    }
  });

  noteActions.append(save, noteStatus);
  card.append(label, note, noteActions);

  const bottom = element('div', undefined, 'result-bottom');
  const countSuffix = data.lookup_count === 1 ? '' : 's';
  const cachedSuffix = data.cached ? ' · Saved definition' : '';
  const sharedSuffix = data.collection === 'tui' ? ' · Shared with TUI' : '';
  const journalLabel = `✓ In your journal · ${data.lookup_count} lookup${countSuffix}${cachedSuffix}${sharedSuffix}`;
  bottom.append(element('span', journalLabel));
  if (data.source_url) {
    bottom.append(sourceLink(data.source_url));
  }
  card.append(bottom);
  return card;
}

function renderResult(data) {
  const results = data.results || [data];
  $('result').replaceChildren(...results.map(buildResultCard));
  $('result').hidden = false;
}

// -----------------------------------------------------------------------------
// Search Operations
// -----------------------------------------------------------------------------

async function searchAll(word) {
  const slots = dictionarySources.map(source => {
    const card = element('article', undefined, 'result-card');
    card.append(element('span', sourceNames[source], 'source-tag'), element('p', 'Looking up this word…'));
    return card;
  });
  $('result').replaceChildren(...slots);
  $('result').hidden = false;

  let completed = 0;
  const requests = ['local', ...dictionarySources.filter(source => source !== 'local')];
  const results = await Promise.all(requests.map(async source => {
    const index = dictionarySources.indexOf(source);
    let data;
    try {
      data = await api('/api/search', { word, source });
      slots[index].replaceWith(buildResultCard(data));
    } catch (error) {
      data = { source, error: error.message };
      slots[index].replaceChildren(
        element('span', sourceNames[source], 'source-tag'),
        element('p', error.message, 'error')
      );
    }
    completed++;
    $('search-status').textContent = `${completed} of ${dictionarySources.length} dictionaries checked…`;
    return data;
  }));

  const found = results.filter(data => data.entry).length;
  const saved = results.filter(data => data.saved).length;
  $('search-status').textContent = `${found} of ${dictionarySources.length} dictionaries returned definitions. ` +
    (saved ? 'Successful lookups saved; failed lookups were not added.' : 'No new history saved.');
}

async function searchWord(word, source) {
  if (state.busy || state.grading || state.restoring) {
    return;
  }
  source = source || selectedSource();
  if (source !== 'all' && !dictionarySources.includes(source)) {
    source = 'all';
  }
  state.busy = true;
  hideSuggestions();
  $('query').value = word;

  const sourceInput = [...document.querySelectorAll('input[name="source"]')].find(input => input.value === source);
  if (sourceInput) {
    sourceInput.checked = true;
  }

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
      $('search-status').textContent = data.saved
        ? 'A new discovery, safely saved.'
        : 'Lookup failed. No new history saved.';
    }
    await refreshCounts();
    // Refresh the Word of the Day and Wisdom/Proverb on each new search
    fetchNextWord();
    fetchNextProverb();
  } catch (error) {
    $('search-status').textContent = error.message;
  } finally {
    state.busy = false;
    $('search-button').disabled = false;
    $('query').readOnly = false;
    document.querySelectorAll('input[name="source"]').forEach(input => { input.disabled = false; });
  }
}

async function refreshCounts() {
  const [data, proverbsData] = await Promise.all([api('/api/words'), api('/api/proverbs')]);
  state.words = data.words;
  state.proverbs = proverbsData.proverbs || [];
  $('word-count').textContent = String(data.words.length);
  $('due-count').textContent = String(data.words.filter(word => word.due_at <= Date.now() / 1000).length);
  if ($('proverbs-count')) {
    $('proverbs-count').textContent = String(state.proverbs.length);
  }
  refreshOrganizationFilters();
  if (state.view === 'words') {
    renderWords();
  }
  if (state.view === 'proverbs') {
    renderProverbs();
  }
}

// -----------------------------------------------------------------------------
// Proverbs & Daily Content
// -----------------------------------------------------------------------------

function renderProverbs() {
  const filter = ($('proverb-filter')?.value || '').trim().toLocaleLowerCase();
  const proverbs = state.proverbs.filter(p => (
    (p.text && p.text.toLocaleLowerCase().includes(filter))
    || (p.chinese && p.chinese.toLocaleLowerCase().includes(filter))
  ));

  if ($('proverbs-status')) {
    $('proverbs-status').textContent = `${proverbs.length} saved proverb${proverbs.length === 1 ? '' : 's'}`;
  }
  const fragment = document.createDocumentFragment();
  for (const p of proverbs) {
    const row = element('article', undefined, 'word-row');
    const copy = element('div');
    copy.append(element('h2', `“${p.text}”`), element('p', p.chinese, 'chinese'));
    if (p.explanation) {
      copy.append(element('p', p.explanation));
    }
    copy.append(element('p', `${p.date || 'Saved'} · Collected Wisdom`, 'word-meta'));

    const actions = element('div', undefined, 'word-actions');
    const listen = button('🔊 Listen', () => playProverbAudio(p.audio_url, p.text), 'secondary');
    listen.setAttribute('aria-label', `Listen to proverb: ${p.text}`);
    actions.append(listen);
    row.append(copy, actions);
    fragment.append(row);
  }

  if (!proverbs.length) {
    fragment.append(empty(
      filter ? 'No matching proverbs.' : 'No proverbs saved yet.',
      filter ? 'Try a different keyword.' : 'Proverbs are saved automatically when fetched.',
      false
    ));
  }
  if ($('proverb-list')) {
    $('proverb-list').replaceChildren(fragment);
  }
}

async function fetchNextProverb(trigger) {
  if (trigger) {
    trigger.disabled = true;
  }
  $('app-message').textContent = '';
  try {
    const src = $('daily-proverb-source')?.value || 'all';
    const res = await api('/api/proverb/random?source=' + encodeURIComponent(src));
    if (res.proverb) {
      if (state.daily) {
        state.daily.proverb = res.proverb;
      }
      $('daily-proverb').textContent = `“${res.proverb.text}”`;
      $('daily-chinese').textContent = res.proverb.chinese;
      $('daily-explanation').textContent = res.proverb.explanation || '';
      const audioBtn = $('daily-proverb-audio');
      if (audioBtn) {
        audioBtn.hidden = false;
      }
      await refreshCounts();
    }
  } catch (err) {
    report(err);
  } finally {
    if (trigger) {
      trigger.disabled = false;
    }
  }
}

async function fetchNextWord(trigger) {
  if (trigger) {
    trigger.disabled = true;
  }
  $('app-message').textContent = '';
  try {
    const res = await api('/api/word/random');
    if (res.word) {
      if (state.daily) {
        state.daily.word = res.word;
      }
      $('daily-word').textContent = res.word.word;
      $('daily-meaning').textContent = res.word.meaning;
      $('daily-label').textContent = res.word.source === 'local'
        ? '01 / FROM YOUR LOCAL VOCABULARY'
        : '01 / WORD OF THE DAY';
      $('daily-example').textContent = res.word.example ? `“${res.word.example}”` : '';
      const exampleAudioBtn = $('daily-example-audio');
      if (exampleAudioBtn) {
        exampleAudioBtn.hidden = !res.word.example;
      }
    }
  } catch (err) {
    report(err);
  } finally {
    if (trigger) {
      trigger.disabled = false;
    }
  }
}

async function deleteWord(word, trigger) {
  if (state.restoring) {
    return;
  }
  const scope = word.collection === 'tui'
    ? 'This removes the word, notes, review history, and matching web history from both the web app and TUI. '
      + 'Imported dictionary definitions remain.'
    : 'This removes this saved entry, its notes, and review progress.';
  if (!window.confirm(`Delete “${word.word}”?\n\n${scope}`)) {
    return;
  }
  trigger.disabled = true;
  $('app-message').textContent = '';
  try {
    await api('/api/delete', { id: word.id, collection: word.collection });
    state.queue = state.queue.filter(item => (word.collection === 'tui'
      ? item.word.toLocaleLowerCase() !== word.word.toLocaleLowerCase()
      : !(item.id === word.id && item.collection === word.collection)));
    state.total = state.reviewed + state.queue.length;
    $('result').replaceChildren();
    $('result').hidden = true;
    await refreshCounts();
    $('words-status').textContent += ` · Deleted “${word.word}”`;
    // Reload the daily selection if removing a shared word changed the TUI deck.
    if (word.collection === 'tui') {
      await loadDaily();
    }
  } catch (error) {
    report(error);
  } finally {
    trigger.disabled = false;
  }
}

// -----------------------------------------------------------------------------
// Organization & Filter Management
// -----------------------------------------------------------------------------

function organizationKey(value) {
  // Match SQLite/Lua's ASCII folding while preserving non-ASCII label identity.
  return value.replace(/[A-Z]/g, character => character.toLowerCase());
}

function refreshOrganizationFilters() {
  const folders = new Map();
  const tags = new Map();
  for (const word of state.words) {
    if (word.folder) {
      folders.set(organizationKey(word.folder), word.folder);
    }
    for (const tag of word.tags || []) {
      tags.set(organizationKey(tag), tag);
    }
  }
  for (const [ids, values, label] of [
    [['word-folder', 'review-folder'], folders, 'All collections'],
    [['word-tag', 'review-tag'], tags, 'All tags']
  ]) {
    const names = [...values.values()].sort((a, b) => a.localeCompare(b));
    for (const id of ids) {
      const select = $(id);
      if (!select) {
        continue;
      }
      const selected = select.value;
      const options = [element('option', label)];
      options[0].value = '';
      for (const name of names) {
        const option = element('option', name);
        option.value = name;
        options.push(option);
      }
      select.replaceChildren(...options);
      select.value = names.find(name => organizationKey(name) === organizationKey(selected)) || '';
    }
  }
}

function organizationForm(word) {
  const form = element('form', undefined, 'organization-form');
  const folderLabel = element('label', 'Collection');
  const folder = element('input');
  folder.value = word.folder || '';
  folder.maxLength = 64;
  folder.placeholder = 'Books, Exam, Work…';
  folderLabel.append(folder);

  const tagLabel = element('label', 'Tags, separated by commas');
  const tags = element('input');
  tags.value = (word.tags || []).join(', ');
  tags.maxLength = 526;
  tags.placeholder = 'travel, verbs';
  tagLabel.append(tags);

  const status = element('span', '', 'tool-status');
  status.setAttribute('role', 'status');

  const save = element('button', 'Save organization', 'primary');
  save.type = 'submit';

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (state.restoring) {
      return;
    }
    save.disabled = true;
    status.textContent = 'Saving…';
    try {
      await api('/api/organize', {
        id: word.id,
        collection: word.collection,
        folder: folder.value,
        tags: tags.value.split(',').map(tag => tag.trim()).filter(Boolean)
      });
      await refreshCounts();
    } catch (error) {
      status.textContent = error.message;
    } finally {
      save.disabled = false;
    }
  });

  form.append(folderLabel, tagLabel, save, status);
  return form;
}

function reviewSessionUrl() {
  const params = new URLSearchParams({
    mode: $('review-mode')?.value || 'due',
    limit: $('review-limit')?.value || '20'
  });
  if ($('review-folder')?.value) {
    params.set('folder', $('review-folder').value);
  }
  if ($('review-tag')?.value) {
    params.set('tag', $('review-tag').value);
  }
  return '/api/session?' + params.toString();
}

function lockSessionControls(locked) {
  $('review-options')?.querySelectorAll('input,select,button').forEach(node => {
    node.disabled = locked;
  });
}

// -----------------------------------------------------------------------------
// Backup & Restore
// -----------------------------------------------------------------------------

async function restoreBackup(file) {
  if (!file || state.grading || state.reviewLoading || state.restoring) {
    return;
  }
  const status = $('backup-status');
  if (file.size > 16 * 1024 * 1024) {
    status.textContent = 'Choose a backup smaller than 16 MB.';
    return;
  }
  let backup;
  try {
    backup = JSON.parse(await file.text());
  } catch (_) {
    status.textContent = 'Choose a valid JSON backup.';
    return;
  }
  if (state.grading || state.reviewLoading || state.restoring) {
    return;
  }
  if (backup?.format !== 'wordbook' || ![1, 2, 3].includes(backup?.version)) {
    status.textContent = 'Choose a Wordbook version 1, 2 or 3 JSON backup.';
    return;
  }
  if (!window.confirm(
    'Restore this backup? This replaces your saved journal, notes, collections, and review progress. ' +
    (backup.shared ? 'It also replaces the saved TUI deck and study plan. ' : '') +
    'Imported dictionary definitions stay available. Download a backup first if you want to keep the current data.'
  )) {
    return;
  }
  state.restoring = true;
  const restoreBtn = $('restore-button');
  restoreBtn.disabled = true;
  status.textContent = 'Restoring…';
  try {
    const result = await api('/api/restore', backup);
    state.reviewRequest++;
    state.queue = [];
    state.reviewed = 0;
    state.total = 0;
    state.sessionMatching = 0;
    state.revealed = false;
    $('result').replaceChildren();
    $('result').hidden = true;
    await refreshCounts();
    renderReview();
    status.textContent = `Restored ${result.web_words} journal entries and ${result.shared_words} shared words.`;
  } catch (error) {
    status.textContent = error.message;
  } finally {
    state.restoring = false;
    restoreBtn.disabled = false;
  }
}

// -----------------------------------------------------------------------------
// Study Forms (Meaning & Example)
// -----------------------------------------------------------------------------

function meaningForm(word) {
  return studyTextForm(word, 'meaning');
}

function exampleForm(word) {
  return studyTextForm(word, 'example');
}

function studyTextForm(word, kind) {
  const isExample = kind === 'example';
  const field = 'study_' + kind;
  const form = element('form', undefined, kind + '-form');
  const label = element(
    'label',
    isExample ? 'Your example sentence — saved for review' : 'Your meaning — saved for review',
    'note-label'
  );
  const input = element('textarea', undefined, 'study-note');
  input.id = `${kind}-${word.collection || 'web'}-${word.id}-${word.source || 'local'}`;
  label.htmlFor = input.id;
  input.value = word[field] || '';
  input.maxLength = 4000;
  input.placeholder = isExample ? 'Write a sentence using this word…' : 'Explain the word in your own words…';

  const status = element('span', '', 'source-tag');
  status.setAttribute('role', 'status');
  const save = element('button', isExample ? 'Save example' : 'Save meaning', 'secondary');
  save.type = 'submit';

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (state.restoring || state.grading) {
      return;
    }
    const value = input.value;
    save.disabled = true;
    status.textContent = 'Saving…';
    try {
      await api('/api/' + kind, { id: word.id, collection: word.collection, [kind]: value });
      word[field] = value;
      status.textContent = input.value !== value
        ? 'Saved previous text. Save again for your latest edits.'
        : isExample ? 'Example saved' : 'Meaning saved';
      await refreshCounts();
      if (state.view === 'review') {
        renderReview();
      }
    } catch (error) {
      status.textContent = error.message;
    } finally {
      save.disabled = false;
    }
  });

  const actions = element('div', undefined, 'note-actions');
  actions.append(save, status);
  form.append(label, input, actions);
  return form;
}

// -----------------------------------------------------------------------------
// Statistics & Word List Rendering
// -----------------------------------------------------------------------------

function renderStatistics(data) {
  state.statistics = data;
  $('stats-status').textContent = `${data.period_reviews} recorded reviews in the last 30 days · ` +
    `${data.lifetime_reviews} saved reviews in total`;

  const tiles = [
    ['Saved words', data.saved_words],
    ['Due cards', data.due_cards],
    ['Reviews today', data.today_reviews],
    ['Review streak', data.streak + ' days'],
    ['Recall rate', data.recall_rate == null ? '—' : data.recall_rate.toFixed(0) + '%']
  ].map(([label, value]) => {
    const tile = element('article', undefined, 'stat-tile');
    tile.append(element('strong', String(value)), element('span', label));
    return tile;
  });
  $('stats-summary').replaceChildren(...tiles);

  if ($('stats-mastery') && data.mastery) {
    const masteryTiles = [
      ['New', data.mastery.new || 0],
      ['Learning', data.mastery.learning || 0],
      ['Reviewing', data.mastery.reviewing || 0],
      ['Mastered', data.mastery.mastered || 0]
    ].map(([label, value]) => {
      const tile = element('article', undefined, 'stat-tile');
      tile.append(element('strong', String(value)), element('span', label));
      return tile;
    });
    $('stats-mastery').replaceChildren(...masteryTiles);
  }

  if ($('stats-forecast') && Array.isArray(data.forecast)) {
    const forecastTiles = data.forecast.map((day, idx) => {
      const tile = element('div', undefined, 'activity-day' + (day.due ? ' active' : ''));
      const label = element('time', idx === 0 ? 'Today' : day.date.slice(5));
      label.dateTime = day.date;
      tile.title = `${day.date}: ${day.due} card${day.due === 1 ? '' : 's'} due`;
      tile.append(label, element('strong', String(day.due)));
      return tile;
    });
    $('stats-forecast').replaceChildren(...forecastTiles);
  }

  const days = data.days.map(day => {
    const tile = element('div', undefined, 'activity-day' + (day.total ? ' active' : ''));
    const date = element('time', day.date.slice(5));
    date.dateTime = day.date;
    tile.title = `${day.date}: ${day.total} reviews, ${day.recalled} recalled`;
    tile.append(date, element('strong', String(day.total)));
    return tile;
  });
  $('stats-activity').replaceChildren(...days);

  const words = data.difficult.map(word => {
    const row = element('article', undefined, 'word-row');
    const description = element('div');
    description.append(element('h2', word.word), element('p', `${word.again} Again grades in ${word.total} reviews`));
    row.append(description, button('Look up ↗', () => searchWord(word.word)));
    return row;
  });
  if (!words.length) {
    words.push(empty(
      'No difficult words recorded yet.',
      'Review a few words to build your learning history.',
      false
    ));
  }
  $('stats-difficult').replaceChildren(...words);
}

function wordMatchesFilter(word, filter) {
  if (!filter) {
    return { matched: true, context: '' };
  }
  if ((word.word || '').toLocaleLowerCase().includes(filter)) {
    return { matched: true, context: '' };
  }
  const fields = [
    ['Meaning', word.study_meaning],
    ['Note', word.note],
    ['Example', word.study_example],
    ...(word.entry?.definitions || []).map(def => ['Definition', def]),
    ...(word.entry?.examples || []).map(ex => ['Example', ex])
  ];
  for (const [label, text] of fields) {
    if (typeof text === 'string' && text.toLocaleLowerCase().includes(filter)) {
      return { matched: true, context: `${label}: ${text}` };
    }
  }
  return { matched: false, context: '' };
}

function wordMatchesStatus(word, status, nowSec = Date.now() / 1000) {
  if (!status) {
    return true;
  }
  if (status === 'due') {
    return (word.due_at || 0) <= nowSec;
  }
  if (status === 'new') {
    return (word.review_count || 0) === 0;
  }
  if (status === 'mastered') {
    return word.collection === 'tui'
      ? (word.interval_days || 0) >= 14
      : (word.streak || 0) >= 4 || (word.review_count || 0) >= 5;
  }
  if (status === 'missing-meaning') {
    return !(word.study_meaning && word.study_meaning.trim());
  }
  return true;
}

function sortWords(words, sortKey) {
  const list = [...words];
  if (sortKey === 'alpha') {
    list.sort((a, b) => (a.word || '').localeCompare(b.word || ''));
  } else if (sortKey === 'lookups') {
    list.sort((a, b) => (b.lookup_count || 0) - (a.lookup_count || 0) || (a.word || '').localeCompare(b.word || ''));
  } else if (sortKey === 'due') {
    list.sort((a, b) => (a.due_at || 0) - (b.due_at || 0) || (a.word || '').localeCompare(b.word || ''));
  } else if (sortKey === 'reviews') {
    list.sort((a, b) => (a.review_count || 0) - (b.review_count || 0) || (a.word || '').localeCompare(b.word || ''));
  }
  return list;
}

function renderWords() {
  const filter = $('word-filter').value.trim().toLocaleLowerCase();
  const folder = organizationKey($('word-folder')?.value || '');
  const tag = organizationKey($('word-tag')?.value || '');
  const status = $('word-status')?.value || '';
  const sortKey = $('word-sort')?.value || 'recent';
  const nowSec = Date.now() / 1000;
  const matchContexts = new Map();

  const filtered = state.words.filter(word => {
    if (folder && organizationKey(word.folder || '') !== folder) {
      return false;
    }
    if (tag && !(word.tags || []).some(value => organizationKey(value) === tag)) {
      return false;
    }
    if (!wordMatchesStatus(word, status, nowSec)) {
      return false;
    }
    const match = wordMatchesFilter(word, filter);
    if (!match.matched) {
      return false;
    }
    if (match.context) {
      matchContexts.set(word, match.context);
    }
    return true;
  });

  const words = sortWords(filtered, sortKey);
  $('words-status').textContent = `${words.length} saved entr${words.length === 1 ? 'y' : 'ies'}`;
  const fragment = document.createDocumentFragment();

  for (const word of words) {
    const row = element('article', undefined, 'word-row organizable-row');
    const copy = element('div');
    const summary = word.study_meaning
      || word.note
      || word.entry?.definitions?.[0]
      || 'Add your own study note when you look up this word.';
    copy.append(element('h2', word.word), element('p', summary));

    if (word.study_example) {
      copy.append(element('p', word.study_example, 'personal-example'));
    }
    const matchedContext = matchContexts.get(word);
    if (matchedContext) {
      copy.append(element('p', 'Matched · ' + matchedContext, 'word-match-snippet'));
    }
    const history = word.collection === 'tui'
      ? 'Shared with TUI'
      : `${word.lookup_count} lookup${word.lookup_count === 1 ? '' : 's'}`;
    const nextReview = word.due_at <= nowSec
      ? 'Ready for review'
      : 'Next review ' + formatTime(word.due_at);
    copy.append(element(
      'p',
      `${sourceNames[word.source]} · ${history} · Last seen ${formatTime(word.last_seen)} · ${nextReview}`,
      'word-meta'
    ));

    const actions = element('div', undefined, 'word-actions');
    const badges = element('div', undefined, 'word-tags');
    if (word.folder) {
      badges.append(element('span', 'Collection: ' + word.folder, 'word-tag'));
    }
    for (const tagItem of word.tags || []) {
      badges.append(element('span', tagItem, 'word-tag'));
    }
    copy.append(badges);

    const editor = organizationForm(word);
    editor.hidden = true;
    const meaningEditor = meaningForm(word);
    meaningEditor.hidden = true;
    const exampleEditor = exampleForm(word);
    exampleEditor.hidden = true;

    const editExample = button('Edit example', () => { exampleEditor.hidden = !exampleEditor.hidden; });
    const editMeaning = button('Edit meaning', () => { meaningEditor.hidden = !meaningEditor.hidden; });
    const organize = button('Organize', () => { editor.hidden = !editor.hidden; });
    const remove = button('Delete', () => deleteWord(word, remove), 'secondary delete-button');
    remove.setAttribute('aria-label', `Delete ${word.word}`);

    actions.append(button('Look up ↗', () => searchWord(word.word)), editMeaning, editExample, organize, remove);
    row.append(copy, actions, editor, meaningEditor, exampleEditor);
    fragment.append(row);
  }

  const hasActiveFilter = Boolean(filter || folder || tag || status);
  if (!words.length) {
    fragment.append(empty(
      hasActiveFilter ? 'No matching words.' : 'Your first word is waiting.',
      hasActiveFilter ? 'Try a different filter.' : 'Look up something new. It will appear here automatically.',
      !hasActiveFilter
    ));
  }
  $('word-list').replaceChildren(fragment);
}

// -----------------------------------------------------------------------------
// SRS Review, Active Recall Quiz Modes & Grading
// -----------------------------------------------------------------------------

function quizMode() {
  return $('review-quiz')?.value || 'flashcard';
}

function maskWordInText(text, targetWord) {
  if (!text || !targetWord) {
    return text || '';
  }
  const escaped = targetWord.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  if (!escaped) {
    return text;
  }
  const regex = new RegExp(escaped + '[a-z]*', 'gi');
  return text.replace(regex, '_____');
}

function buildQuizPrompt(word, mode) {
  if (mode === 'dictation') {
    return 'Listen to the pronunciation and type the word.';
  }
  if (mode === 'cloze') {
    const raw = word.study_example
      || word.entry?.examples?.[0]
      || word.study_meaning
      || word.entry?.definitions?.[0]
      || word.note
      || '';
    if (!raw) {
      return '_____ (no example sentence saved yet)';
    }
    const masked = maskWordInText(raw, word.word);
    return masked.includes('_____') ? masked : `${masked} (_____)`;
  }
  const meaning = word.study_meaning
    || word.entry?.definitions?.[0]
    || word.note
    || 'Recall the word for this card.';
  return maskWordInText(meaning, word.word);
}

function checkQuizAnswer(typed, expected) {
  const normTyped = String(typed || '').trim().toLocaleLowerCase().replace(/\s+/g, ' ');
  const normExpected = String(expected || '').trim().toLocaleLowerCase().replace(/\s+/g, ' ');
  return {
    correct: Boolean(normExpected && normTyped === normExpected),
    typed: String(typed || '').trim()
  };
}

async function gradeWord(word, remembered, gradeValue) {
  if (state.grading || state.reviewLoading || state.restoring || state.view !== 'review') {
    return;
  }
  const sameCard = item => item.id === word.id && (item.collection || 'web') === (word.collection || 'web');
  if (!state.queue.length || !sameCard(state.queue[0])) {
    return;
  }
  state.grading = true;
  lockSessionControls(true);

  const actions = document.querySelector('.review-actions');
  if (actions) {
    actions.querySelectorAll('button').forEach(node => { node.disabled = true; });
  }

  try {
    await api('/api/review', { id: word.id, collection: word.collection, remembered, grade: gradeValue });
    const index = state.queue.findIndex(sameCard);
    if (index < 0) {
      return;
    }
    state.queue.splice(index, 1);
    state.reviewed++;
    state.revealed = false;
    state.quizChecked = null;
    renderReview();
    await refreshCounts();
  } catch (error) {
    report(error);
  } finally {
    state.grading = false;
    lockSessionControls(false);
    if (actions) {
      actions.querySelectorAll('button').forEach(node => { node.disabled = false; });
    }
  }
}

function renderReview() {
  const target = $('review-card');
  target.replaceChildren();

  if (state.reviewLoading) {
    $('review-progress').textContent = 'Preparing your words…';
    target.append(element('p', 'Preparing your words…', 'study-answer'));
    return;
  }

  const matchingText = state.sessionMatching > state.total ? ` · ${state.sessionMatching} matching words` : '';
  $('review-progress').textContent = `${state.reviewed} of ${state.total} reviewed this session${matchingText}`;

  if (!state.queue.length) {
    target.append(empty(
      state.total ? 'A little wiser already.' : 'You’re all caught up.',
      state.total
        ? 'Your next reviews are scheduled. Come back for another small step.'
        : 'New words appear here as soon as you look them up.',
      true
    ));
    return;
  }

  const word = state.queue[0];
  const mode = quizMode();

  if (!state.revealed && mode !== 'flashcard') {
    target.append(
      element('p', sourceNames[word.source], 'eyebrow'),
      element('h2', mode === 'cloze' ? 'Fill in the blank' : mode === 'dictation' ? 'Audio dictation' : 'Guess the word'),
      element('p', buildQuizPrompt(word, mode), 'study-answer quiz-prompt')
    );
    if (mode === 'dictation') {
      target.append(button('🔊 Play audio', () => pronounceWord(word.word), 'secondary', 'P'));
    }
    const form = element('form', undefined, 'quiz-form');
    const input = element('input', undefined, 'filter quiz-input');
    input.id = 'quiz-input';
    input.type = 'text';
    input.placeholder = 'Type the word…';
    input.autocomplete = 'off';
    const submit = element('button', 'Check answer', 'primary');
    submit.type = 'submit';
    const skip = button('Reveal meaning', () => {
      state.quizChecked = null;
      state.revealed = true;
      renderReview();
    }, 'secondary', 'Space');
    form.append(input, submit, skip);
    form.addEventListener('submit', event => {
      event.preventDefault();
      state.quizChecked = checkQuizAnswer(input.value, word.word);
      state.revealed = true;
      renderReview();
    });
    target.append(
      form,
      element('p', 'Shortcuts: [Enter] check typed word · [Space] reveal · [P] pronounce', 'review-shortcuts-hint')
    );
    return;
  }

  target.append(element('p', sourceNames[word.source], 'eyebrow'), element('h2', word.word));

  if (!state.revealed) {
    target.append(
      element('p', 'What does this word mean?', 'study-answer'),
      button('Reveal meaning', () => { state.revealed = true; renderReview(); }, 'primary', 'Space'),
      element('p', 'Shortcuts: [Space] reveal · [P] pronounce', 'review-shortcuts-hint')
    );
    return;
  }

  if (state.quizChecked) {
    const feedbackText = state.quizChecked.correct
      ? `✓ Correct! You typed “${state.quizChecked.typed}”.`
      : `✗ Expected “${word.word}” (you typed “${state.quizChecked.typed || 'nothing'}”).`;
    target.append(element(
      'p',
      feedbackText,
      'quiz-feedback ' + (state.quizChecked.correct ? 'correct' : 'incorrect')
    ));
  }

  if (word.study_meaning) {
    target.append(element('p', word.study_meaning, 'personal-meaning'));
  }
  if (word.study_example) {
    target.append(element('p', 'Your example', 'eyebrow'), element('p', word.study_example, 'personal-example'));
  }
  if (word.note) {
    target.append(element('p', word.note, 'study-answer'));
  }
  definitions(word.entry, target);

  if (!word.study_meaning && !word.note && !word.entry) {
    target.append(
      element('p', 'This word has no saved meaning. Add your own meaning or study note.', 'study-answer'),
      button('Add your meaning', () => { target.append(meaningForm(word)); }),
      button('Look up ↗', () => searchWord(word.word))
    );
  }

  const actions = element('div', undefined, 'review-actions');
  const grades = word.collection === 'tui'
    ? [
      ['Again · 10 min', false, 'secondary', 0, '1'],
      ['Hard', true, 'secondary', 1, '2'],
      ['Good', true, 'primary', 2, '3'],
      ['Easy', true, 'secondary', 3, '4']
    ]
    : [
      ['Again · 10 min', false, 'secondary', undefined, '1'],
      ['Remembered ✓', true, 'primary', undefined, '2']
    ];

  for (const [label, remembered, style, gradeValue, kbd] of grades) {
    const grade = button(label, () => gradeWord(word, remembered, gradeValue), style, kbd);
    actions.append(grade);
  }
  target.append(actions);
  target.append(element(
    'p',
    `Shortcuts: [1–${grades.length}] grade · [Space] confirm · [P] pronounce`,
    'review-shortcuts-hint'
  ));
}

// -----------------------------------------------------------------------------
// View Navigation
// -----------------------------------------------------------------------------

async function showView(view) {
  if (state.grading || state.restoring) {
    return;
  }
  const reviewRequest = ++state.reviewRequest;
  state.view = view;
  state.reviewLoading = view === 'review';
  lockSessionControls(state.reviewLoading);
  if (view !== 'search') {
    hideSuggestions();
  }
  $('app-message').textContent = '';

  for (const name of ['search', 'words', 'review', 'proverbs', 'stats']) {
    const section = $(name + '-view');
    if (section) {
      section.hidden = name !== view;
    }
  }

  document.querySelectorAll('.nav-button').forEach(node => {
    node.classList.toggle('active', node.dataset.view === view);
    if (node.dataset.view === view) {
      node.setAttribute('aria-current', 'page');
    } else {
      node.removeAttribute('aria-current');
    }
  });

  try {
    if (view === 'words') {
      renderWords();
      await refreshCounts();
    }
    if (view === 'proverbs') {
      renderProverbs();
      await refreshCounts();
    }
    if (view === 'stats') {
      $('stats-status').textContent = 'Loading your progress…';
      const data = await api('/api/stats');
      if (state.view === 'stats' && reviewRequest === state.reviewRequest) {
        renderStatistics(data);
      }
    }
    if (view === 'review') {
      renderReview();
      const data = await api(reviewSessionUrl());
      if (state.view !== 'review' || reviewRequest !== state.reviewRequest) {
        return;
      }
      state.reviewLoading = false;
      lockSessionControls(false);
      state.sessionMatching = data.total_matching ?? data.words.length;
      state.queue = data.words;
      state.reviewed = 0;
      state.total = data.words.length;
      state.revealed = false;
      state.quizChecked = null;
      renderReview();
    }
  } catch (error) {
    if (reviewRequest !== state.reviewRequest) {
      return;
    }
    report(error);
    state.reviewLoading = false;
    lockSessionControls(false);
    if (view === 'review') {
      renderReview();
    }
  }
}

async function loadDaily() {
  const data = await api('/api/daily');
  state.daily = data;
  $('daily-date').textContent = new Date(data.date + 'T12:00:00Z').toLocaleDateString(undefined, {
    month: 'long',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'UTC'
  });

  // Automatically discover a fresh word & proverb on page refresh/load
  await Promise.all([fetchNextWord(), fetchNextProverb()]);

  // Fallback to daily content if dynamic cards were not populated
  if (!$('daily-word').textContent || $('daily-word').textContent === '…') {
    $('daily-word').textContent = data.word.word;
    $('daily-meaning').textContent = data.word.meaning;
    $('daily-label').textContent = data.word.source === 'local'
      ? '01 / FROM YOUR LOCAL VOCABULARY'
      : '01 / WORD OF THE DAY';
    $('daily-example').textContent = data.word.example ? `“${data.word.example}”` : '';
    const exampleAudioBtn = $('daily-example-audio');
    if (exampleAudioBtn) {
      exampleAudioBtn.hidden = !data.word.example;
    }
  }
  if (!$('daily-proverb').textContent || $('daily-proverb').textContent === '…') {
    $('daily-proverb').textContent = `“${data.proverb.text}”`;
    $('daily-chinese').textContent = data.proverb.chinese;
    $('daily-explanation').textContent = data.proverb.explanation || '';
    const audioBtn = $('daily-proverb-audio');
    if (audioBtn) {
      audioBtn.hidden = false;
    }
  }
}

// -----------------------------------------------------------------------------
// Search Autocomplete / Suggestions
// -----------------------------------------------------------------------------

let suggestTimer = null;
let suggestRequest = 0;
state.suggestIndex = -1;
state.suggestions = [];

function hideSuggestions() {
  clearTimeout(suggestTimer);
  suggestRequest++;
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
  if (!box) {
    return;
  }
  const items = box.querySelectorAll('.suggest-item');
  items.forEach((item, index) => {
    item.classList.toggle('active', index === state.suggestIndex);
    if (index === state.suggestIndex) {
      item.scrollIntoView({ block: 'nearest' });
    }
  });
}

function renderSuggestions(list) {
  const box = $('search-suggest');
  if (!box) {
    return;
  }
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
    if (item.snippet) {
      row.append(element('span', item.snippet, 'suggest-snippet'));
    }
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
  const request = ++suggestRequest;
  try {
    const data = await api('/api/suggest?q=' + encodeURIComponent(query));
    if (
      request !== suggestRequest
      || query !== $('query').value.trim()
      || state.view !== 'search'
      || state.busy
    ) {
      return;
    }
    renderSuggestions(data.suggestions || []);
  } catch (_) {
    if (request === suggestRequest) {
      hideSuggestions();
    }
  }
}

// -----------------------------------------------------------------------------
// Keyboard Navigation & DOM Event Listeners
// -----------------------------------------------------------------------------

$('query').addEventListener('input', () => {
  hideSuggestions();
  suggestTimer = setTimeout(() => fetchSuggestions($('query').value), 120);
});

$('query').addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    event.preventDefault();
    hideSuggestions();
    return;
  }
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
  }
});

document.addEventListener('click', event => {
  if (!event.target.closest('#search-form')) {
    hideSuggestions();
  }
});

window.addEventListener('keydown', event => {
  if (['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)) {
    return;
  }
  if (state.view !== 'review' || !state.queue.length || state.grading || state.reviewLoading) {
    return;
  }
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
$('word-folder')?.addEventListener('change', renderWords);
$('word-tag')?.addEventListener('change', renderWords);
$('word-status')?.addEventListener('change', renderWords);
$('word-sort')?.addEventListener('change', renderWords);

$('review-quiz')?.addEventListener('change', () => {
  if (state.view === 'review' && !state.grading && !state.reviewLoading) {
    state.revealed = false;
    state.quizChecked = null;
    renderReview();
  }
});

$('review-options')?.addEventListener('submit', event => {
  event.preventDefault();
  showView('review');
});

$('restore-button')?.addEventListener('click', () => {
  $('restore-file').click();
});

$('restore-file')?.addEventListener('change', async event => {
  await restoreBackup(event.target.files[0]);
  event.target.value = '';
});

$('daily-lookup').addEventListener('click', () => {
  if (state.daily) {
    searchWord(state.daily.word.word);
  }
});

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

$('daily-proverb-next')?.addEventListener('click', e => {
  fetchNextProverb(e.currentTarget);
});

$('daily-word-next')?.addEventListener('click', e => {
  fetchNextWord(e.currentTarget);
});

$('proverb-filter')?.addEventListener('input', renderProverbs);

const proverbSourceSelect = $('daily-proverb-source');
if (proverbSourceSelect) {
  const savedSource = localStorage.getItem('wordbook_proverb_source');
  if (savedSource) {
    proverbSourceSelect.value = savedSource;
  }
  proverbSourceSelect.addEventListener('change', () => {
    localStorage.setItem('wordbook_proverb_source', proverbSourceSelect.value);
    fetchNextProverb();
  });
}

const voiceSelect = $('voice-select');
if (voiceSelect) {
  const savedVoice = localStorage.getItem('wordbook_voice');
  if (savedVoice) {
    voiceSelect.value = savedVoice;
  }
  voiceSelect.addEventListener('change', () => {
    localStorage.setItem('wordbook_voice', voiceSelect.value);
  });
}

if ('speechSynthesis' in window) {
  window.speechSynthesis.onvoiceschanged = () => {
    window.speechSynthesis.getVoices();
  };
}

document.querySelectorAll('.nav-button').forEach(node => {
  node.addEventListener('click', () => showView(node.dataset.view));
});

// -----------------------------------------------------------------------------
// Application Startup Initialization
// -----------------------------------------------------------------------------

Promise.all([loadDaily(), refreshCounts()]).catch(report);

setInterval(() => {
  if (!document.hidden && state.daily?.date !== new Date().toISOString().slice(0, 10)) {
    loadDaily().catch(report);
  }
}, 60000);
