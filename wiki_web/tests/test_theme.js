// =============================================================================
// test_theme.js
// Leaf Wiki: Theme Persistence, OS Synchronization & Palette Contrast Test Suite
// =============================================================================

const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..', 'static');
const script = fs.readFileSync(path.join(root, 'theme.js'), 'utf8');

function harness(saved, { dark = false, blocked = false, legacy = false, media = true } = {}) {
  const values = new Map(saved === undefined ? [] : [['leaf_wiki_theme', saved]]);
  const picker = {
    value: '',
    addEventListener(name, handler) {
      this[name] = handler;
    }
  };
  const document = {
    documentElement: { dataset: {} },
    readyState: 'loading',
    getElementById(id) {
      if (this.readyState === 'loading') return null;
      return id === 'theme-select' ? picker : null;
    },
    addEventListener(name, handler) {
      this[name] = handler;
    }
  };
  const preference = { matches: dark };
  if (legacy) {
    preference.addListener = handler => { preference.change = handler; };
  } else {
    preference.addEventListener = (_, handler) => { preference.change = handler; };
  }
  const context = {
    document,
    localStorage: {
      getItem(key) {
        if (blocked) {
          throw Error('Storage unavailable');
        }
        return values.get(key) || null;
      },
      setItem(key, value) {
        if (blocked) {
          throw Error('Storage unavailable');
        }
        values.set(key, value);
      }
    },
    window: media ? { matchMedia: () => preference } : {}
  };

  vm.runInNewContext(script, context);
  const initial = document.documentElement.dataset.theme;
  document.readyState = 'interactive';
  if (document.DOMContentLoaded) {
    document.DOMContentLoaded();
  }
  return {
    initial,
    picker,
    values,
    preference,
    theme: () => document.documentElement.dataset.theme
  };
}

test('saved themes apply before the picker exists and choices persist across reloads', () => {
  for (const name of ['paper', 'midnight', 'sepia', 'ocean', 'system']) {
    const page = harness(name, { dark: true });
    assert.equal(page.initial, name === 'system' ? 'midnight' : name);
    assert.equal(page.picker.value, name);
    page.picker.value = 'ocean';
    page.picker.change();
    assert.equal(page.theme(), 'ocean');
    assert.equal(page.values.get('leaf_wiki_theme'), 'ocean');
    assert.equal(harness(page.values.get('leaf_wiki_theme')).initial, 'ocean');
  }
  assert.equal(harness().initial, 'paper');
  assert.equal(harness('unknown').initial, 'paper');
});

test('System follows live OS changes without overriding an explicit palette', () => {
  for (const legacy of [false, true]) {
    const page = harness('system', { dark: false, legacy });
    assert.equal(page.theme(), 'paper');
    page.preference.matches = true;
    page.preference.change();
    assert.equal(page.theme(), 'midnight');
    assert.equal(page.picker.value, 'system');
    page.picker.value = 'sepia';
    page.picker.change();
    page.preference.matches = false;
    page.preference.change();
    assert.equal(page.theme(), 'sepia');
  }
  assert.equal(harness('system', { media: false }).theme(), 'paper');
});

test('blocked storage keeps selection usable and invalid choices do not change the palette', () => {
  const page = harness('midnight', { blocked: true });
  assert.equal(page.theme(), 'paper');
  page.picker.value = 'midnight';
  page.picker.change();
  assert.equal(page.theme(), 'midnight');
  page.picker.value = 'invalid';
  page.picker.change();
  assert.equal(page.theme(), 'midnight');
});

function luminance(hex) {
  const channels = hex.match(/[a-f\d]{2}/gi).map(value => parseInt(value, 16) / 255);
  const linear = channels.map(value => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4));
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}

function contrast(a, b) {
  const values = [luminance(a), luminance(b)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

test('all palettes define complete tokens and readable text in controls, cards, and marks', () => {
  const css = fs.readFileSync(path.join(root, 'style.css'), 'utf8');
  const palettes = [...css.matchAll(/:root(?:,\s*:root\[data-theme="([a-z]+)"\]|\[data-theme="([a-z]+)"\])\s*\{([^}]+)\}/g)];
  assert.equal(palettes.length, 4);

  const used = new Set([...css.matchAll(/var\((--[\w-]+)\)/g)].map(match => match[1]));
  const pairs = [
    ['ink', 'paper'], ['ink', 'surface'], ['muted', 'paper'], ['muted', 'surface'],
    ['green', 'surface'], ['on-primary', 'green'], ['on-primary', 'primary-hover'],
    ['error', 'surface'], ['snippet-color', 'paper'], ['mark-ink', 'mark-bg']
  ];

  for (const match of palettes) {
    const name = match[1] || match[2];
    const block = match[3];
    const tokens = Object.fromEntries(
      [...block.matchAll(/(--[\w-]+):\s*(#[a-f\d]+|rgba\([^)]+\));/gi)].map(m => [m[1], m[2]])
    );
    for (const token of used) {
      assert.ok(tokens[token], `${name}: missing ${token}`);
    }
    for (const [text, background] of pairs) {
      const fg = tokens['--' + text];
      const bg = tokens['--' + background];
      if (fg?.startsWith('#') && bg?.startsWith('#')) {
        const ratio = contrast(fg, bg);
        assert.ok(ratio >= 4.5, `${name}: ${text}/${background} contrast ${ratio.toFixed(2)}`);
      }
    }
  }

  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  assert.ok(html.indexOf('src="/theme.js"') < html.indexOf('href="/style.css"'));
  assert.match(html, /<script src="\/theme.js"><\/script>/);
  assert.match(html, /<select id="theme-select"/);
});
