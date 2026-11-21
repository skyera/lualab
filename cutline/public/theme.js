// Color themes for the cutline UI. Colors live in the CSS variables of
// index.html: the base :root block is the "slate" theme and each other
// theme is a :root[data-theme="name"] block that overrides some of them.

export const THEME_NAMES = ["slate", "graphite", "paper"];
export const DEFAULT_THEME = "slate";
const STORAGE_KEY = "cutline.theme";

const CANVAS_COLOR_VARIABLES = {
  plotBg: "--panel-2",
  grid: "--grid",
  axisLabel: "--muted",
  tooltipText: "--amber",
  crosshair: "--crosshair",
  tooltipBg: "--overlay-bg",
  seriesR: "--series-r",
  seriesG: "--series-g",
  seriesB: "--series-b",
  seriesLuma: "--series-luma",
  // Drawn on top of the image, so these stay the same in every theme.
  cutline: "--cutline",
  cutlineGlow: "--cutline-glow",
  handleFill: "--handle-fill",
  handleLabel: "--handle-label",
  hoverMarker: "--hover-marker",
  hoverRing: "--hover-ring"
};

// Resolve the canvas colors from the CSS variables on `rootElement`.
// Call again after applyTheme(): canvas drawing does not follow CSS.
// Throws when variables are missing, naming each one, so a typo in
// index.html fails loudly instead of drawing in the canvas default black.
export function readCanvasTheme(rootElement) {
  const style = getComputedStyle(rootElement);
  const theme = {};
  const missing = [];
  for (const [name, variable] of Object.entries(CANVAS_COLOR_VARIABLES)) {
    const value = style.getPropertyValue(variable).trim();
    if (value === "") {
      missing.push(variable);
    }
    theme[name] = value;
  }
  if (missing.length > 0) {
    throw new Error(`missing CSS color variables: ${missing.join(", ")}`);
  }
  return theme;
}

// Switch the page to theme `name` by setting data-theme on `rootElement`.
export function applyTheme(rootElement, name) {
  if (!THEME_NAMES.includes(name)) {
    throw new Error(`unknown theme "${name}"`);
  }
  rootElement.dataset.theme = name;
}

// Return the theme saved by saveTheme(), or DEFAULT_THEME when none is
// saved. Storage can be blocked (private mode, disabled site data); that
// and an unknown saved name are reported in the console, not thrown.
export function loadSavedTheme() {
  let saved = null;
  try {
    saved = localStorage.getItem(STORAGE_KEY);
  } catch (err) {
    console.warn(`theme: cannot read saved theme, using ${DEFAULT_THEME}:`,
      err);
    return DEFAULT_THEME;
  }
  if (saved === null) {
    return DEFAULT_THEME;
  }
  if (!THEME_NAMES.includes(saved)) {
    console.warn(`theme: unknown saved theme "${saved}", ` +
      `using ${DEFAULT_THEME}`);
    return DEFAULT_THEME;
  }
  return saved;
}

// Remember theme `name` for the next visit.
// Returns false (and warns in the console) when storage is blocked.
export function saveTheme(name) {
  try {
    localStorage.setItem(STORAGE_KEY, name);
    return true;
  } catch (err) {
    console.warn(`theme: cannot save "${name}"; it lasts until reload:`,
      err);
    return false;
  }
}
