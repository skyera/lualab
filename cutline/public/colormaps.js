const LUMA_WEIGHT_R = 0.2126;
const LUMA_WEIGHT_G = 0.7152;
const LUMA_WEIGHT_B = 0.0722;

const VIRIDIS_STOPS = [
  [0.0, 68, 1, 84],
  [0.25, 59, 82, 139],
  [0.5, 33, 145, 140],
  [0.75, 94, 201, 98],
  [1.0, 253, 231, 37]
];

const INFERNO_STOPS = [
  [0.0, 0, 0, 4],
  [0.25, 87, 16, 110],
  [0.5, 188, 55, 84],
  [0.75, 249, 142, 9],
  [1.0, 252, 255, 164]
];

export function buildLut(stops) {
  const lut = new Uint8ClampedArray(256 * 3);
  for (let i = 0; i < 256; i++) {
    const t = i / 255;
    let s = 0;
    while (s < stops.length - 2 && t > stops[s + 1][0]) {
      s++;
    }
    const [t0, r0, g0, b0] = stops[s];
    const [t1, r1, g1, b1] = stops[s + 1];
    const frac = (t - t0) / Math.max(1e-6, t1 - t0);
    lut[i * 3] = r0 + (r1 - r0) * frac;
    lut[i * 3 + 1] = g0 + (g1 - g0) * frac;
    lut[i * 3 + 2] = b0 + (b1 - b0) * frac;
  }
  return lut;
}

export const COLORMAP_LUTS = {
  viridis: buildLut(VIRIDIS_STOPS),
  inferno: buildLut(INFERNO_STOPS)
};

export function computeLuminance(r, g, b) {
  return Math.round(
    LUMA_WEIGHT_R * r + LUMA_WEIGHT_G * g + LUMA_WEIGHT_B * b
  );
}

export function applyColormap(srcRgba, dstRgba, colormap) {
  if (colormap === "original") {
    dstRgba.set(srcRgba);
    return;
  }
  const lut = COLORMAP_LUTS[colormap];
  for (let i = 0; i < srcRgba.length; i += 4) {
    const luma = computeLuminance(srcRgba[i], srcRgba[i + 1], srcRgba[i + 2]);
    if (colormap === "gray") {
      dstRgba[i] = luma;
      dstRgba[i + 1] = luma;
      dstRgba[i + 2] = luma;
    } else {
      dstRgba[i] = lut[luma * 3];
      dstRgba[i + 1] = lut[luma * 3 + 1];
      dstRgba[i + 2] = lut[luma * 3 + 2];
    }
    dstRgba[i + 3] = 255;
  }
}

export function renderColorbar(canvas, wrapEl, colormap) {
  if (colormap === "original") {
    wrapEl.classList.remove("visible");
    return;
  }
  wrapEl.classList.add("visible");
  const ctx = canvas.getContext("2d");
  const lut = COLORMAP_LUTS[colormap];
  for (let y = 0; y < canvas.height; y++) {
    const val = Math.round(255 * (1 - y / (canvas.height - 1)));
    if (colormap === "gray") {
      ctx.fillStyle = `rgb(${val},${val},${val})`;
    } else {
      const r = lut[val * 3];
      const g = lut[val * 3 + 1];
      const b = lut[val * 3 + 2];
      ctx.fillStyle = `rgb(${r},${g},${b})`;
    }
    ctx.fillRect(0, y, canvas.width, 1);
  }
}
