// =============================================================================
// theme.js
// Leaf Wiki: Palette Selection & OS Color Scheme Synchronization
// =============================================================================

// Apply the saved palette before CSS and body rendering; System follows OS changes.
(() => {
  'use strict';

  const key = 'leaf_wiki_theme';
  const themes = ['paper', 'midnight', 'sepia', 'ocean', 'system'];
  const system = typeof window.matchMedia === 'function'
    ? window.matchMedia('(prefers-color-scheme: dark)')
    : null;
  let preference = 'paper';

  try {
    const saved = localStorage.getItem(key);
    if (themes.includes(saved)) {
      preference = saved;
    }
  } catch (_) {
    /* Theme selection remains usable when storage is unavailable. */
  }

  function apply() {
    document.documentElement.dataset.theme = preference === 'system'
      ? (system?.matches ? 'midnight' : 'paper')
      : preference;
    const picker = document.getElementById('theme-select');
    if (picker) {
      picker.value = preference;
    }
  }

  function select(value) {
    if (!themes.includes(value)) {
      return false;
    }
    preference = value;
    try {
      localStorage.setItem(key, preference);
    } catch (_) {
      /* Keep the session choice. */
    }
    apply();
    return true;
  }

  function bind() {
    const picker = document.getElementById('theme-select');
    if (!picker) {
      return;
    }
    picker.value = preference;
    picker.addEventListener('change', () => select(picker.value));
  }

  apply();

  if (system?.addEventListener) {
    system.addEventListener('change', apply);
  } else if (system?.addListener) {
    system.addListener(apply);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bind, { once: true });
  } else {
    bind();
  }
})();
