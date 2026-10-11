// Theme startup, persistence, system changes, and palette readability regressions.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..', 'static');
const script = fs.readFileSync(path.join(root, 'theme.js'), 'utf8');

function harness(saved, { dark = false, blocked = false, legacy = false, media = true } = {}) {
  const values = new Map(saved === undefined ? [] : [['wordbook_theme', saved]]);
  const picker = { value: '', addEventListener(name, handler) { this[name] = handler; } };
  const document = {
    documentElement: { dataset: {} }, readyState: 'loading',
    getElementById() { return this.readyState === 'loading' ? null : picker; },
    addEventListener(name, handler) { this[name] = handler; },
  };
  const preference = { matches: dark };
  if (legacy) preference.addListener = handler => { preference.change = handler; };
  else preference.addEventListener = (_, handler) => { preference.change = handler; };
  const context = { document, localStorage: {
    getItem(key) { if (blocked) throw Error('Storage unavailable'); return values.get(key) || null; },
    setItem(key, value) { if (blocked) throw Error('Storage unavailable'); values.set(key, value); },
  }, window: media ? { matchMedia: () => preference } : {} };
  vm.runInNewContext(script, context);
  const initial = document.documentElement.dataset.theme;
  document.readyState = 'interactive'; document.DOMContentLoaded();
  return { initial, picker, values, preference, theme: () => document.documentElement.dataset.theme };
}

test('saved themes apply before the picker exists and choices persist across reloads', () => {
  for (const name of ['paper', 'midnight', 'sepia', 'ocean', 'system']) {
    const page = harness(name, { dark: true });
    assert.equal(page.initial, name === 'system' ? 'midnight' : name);
    assert.equal(page.picker.value, name);
    page.picker.value = 'ocean'; page.picker.change();
    assert.equal(page.theme(), 'ocean');
    assert.equal(page.values.get('wordbook_theme'), 'ocean');
    assert.equal(harness(page.values.get('wordbook_theme')).initial, 'ocean');
  }
  assert.equal(harness().initial, 'paper');
  assert.equal(harness('unknown').initial, 'paper');
});

test('System follows live OS changes without overriding an explicit palette', () => {
  for (const legacy of [false, true]) {
    const page = harness('system', { dark: false, legacy });
    assert.equal(page.theme(), 'paper');
    page.preference.matches = true; page.preference.change();
    assert.equal(page.theme(), 'midnight');
    assert.equal(page.picker.value, 'system');
    page.picker.value = 'sepia'; page.picker.change();
    page.preference.matches = false; page.preference.change();
    assert.equal(page.theme(), 'sepia');
  }
  assert.equal(harness('system', { media: false }).theme(), 'paper');
});

test('blocked storage keeps selection usable and invalid choices do not change the palette', () => {
  const page = harness('midnight', { blocked: true });
  assert.equal(page.theme(), 'paper');
  page.picker.value = 'midnight'; page.picker.change();
  assert.equal(page.theme(), 'midnight');
  page.picker.value = 'invalid'; page.picker.change();
  assert.equal(page.theme(), 'midnight');
});

function luminance(hex) {
  const channels = hex.match(/[a-f\d]{2}/gi).map(value => parseInt(value, 16) / 255);
  const linear = channels.map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}
function contrast(a, b) {
  const values = [luminance(a), luminance(b)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}
test('all palettes define complete tokens and readable text in cards, controls and errors', () => {
  const css = fs.readFileSync(path.join(root, 'style.css'), 'utf8');
  const palettes = [...css.matchAll(/:root\[data-theme="([a-z]+)"\]\s*\{([^}]+)\}/g)];
  assert.equal(palettes.length, 4);
  const used = new Set([...css.matchAll(/var\((--[\w-]+)\)/g)].map(match => match[1]));
  const pairs = [['ink', 'paper'], ['ink', 'white'], ['ink', 'input'], ['muted', 'paper'],
    ['muted', 'white'], ['green', 'white'], ['green', 'active'], ['green', 'word-card'],
    ['word-muted', 'word-card'], ['proverb-ink', 'proverb-card'], ['proverb-muted', 'proverb-card'],
    ['error', 'error-bg'], ['on-accent', 'green'], ['on-accent', 'accent-hover']];
  for (const [, name, block] of palettes) {
    const tokens = Object.fromEntries([...block.matchAll(/(--[\w-]+):\s*(#[a-f\d]+);/gi)].map(match => [match[1], match[2]]));
    for (const token of used) assert.ok(tokens[token], `${name}: missing ${token}`);
    for (const [text, background] of pairs) {
      const ratio = contrast(tokens['--' + text], tokens['--' + background]);
      assert.ok(ratio >= 4.5, `${name}: ${text}/${background} contrast ${ratio.toFixed(2)}`);
    }
  }
  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  assert.ok(html.indexOf('src="/theme.js"') < html.indexOf('href="/style.css"'));
  assert.match(html, /<script src="\/theme.js"><\/script>/);
  assert.doesNotMatch(html, /(?:color|background|border-color):#[a-f\d]+/i);
});
