// Canvas colors for the cutline UI, read from the CSS variables in
// index.html so one :root block defines the whole theme.

const CANVAS_COLOR_VARIABLES = {
  surfaceSunken: "--surface-sunken",
  plotBg: "--panel-2",
  grid: "--grid",
  axisLabel: "--muted",
  cutline: "--cyan",
  cutlineGlow: "--cutline-glow",
  handleLabel: "--text",
  hover: "--amber",
  crosshair: "--crosshair",
  tooltipBg: "--overlay-bg",
  seriesR: "--series-r",
  seriesG: "--series-g",
  seriesB: "--series-b",
  seriesLuma: "--series-luma"
};

// Resolve the canvas colors from the CSS variables on `rootElement`.
// Read once at startup: the theme does not change while the page is open.
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
