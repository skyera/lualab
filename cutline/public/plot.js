const PLOT_PAD = { top: 16, right: 16, bottom: 32, left: 42 };

function findSeriesMinMax(profile, seriesList) {
  let lo = 255;
  let hi = 0;
  for (const series of seriesList) {
    if (!series.show) {
      continue;
    }
    for (const val of profile[series.key]) {
      if (val < lo) {
        lo = val;
      }
      if (val > hi) {
        hi = val;
      }
    }
  }
  return { lo, hi };
}

export function computeYRange(profile, seriesList, autoScale) {
  if (!autoScale || !profile) {
    return { yMin: 0, yMax: 255 };
  }
  const { lo, hi } = findSeriesMinMax(profile, seriesList);
  if (hi <= lo) {
    return { yMin: 0, yMax: 255 };
  }
  const margin = (hi - lo) * 0.08;
  return {
    yMin: Math.max(0, lo - margin),
    yMax: Math.min(255, hi + margin)
  };
}

function drawPlotGrid(ctx, w, h, yRange, theme) {
  const { yMin, yMax } = yRange;
  const ph = h - PLOT_PAD.top - PLOT_PAD.bottom;
  const ySpan = Math.max(1e-3, yMax - yMin);
  ctx.strokeStyle = theme.grid;
  ctx.lineWidth = 1;
  ctx.font = "10px sans-serif";
  ctx.textAlign = "right";
  for (let i = 0; i <= 4; i++) {
    const y = PLOT_PAD.top + (ph * i) / 4;
    ctx.beginPath();
    ctx.moveTo(PLOT_PAD.left, y);
    ctx.lineTo(w - PLOT_PAD.right, y);
    ctx.stroke();
    ctx.fillStyle = theme.axisLabel;
    const label = (yMax - (ySpan * i) / 4).toFixed(0);
    ctx.fillText(label, PLOT_PAD.left - 6, y + 3);
  }
}

function drawXAxisLabels(ctx, w, h, maxDist, theme) {
  const pw = w - PLOT_PAD.left - PLOT_PAD.right;
  ctx.fillStyle = theme.axisLabel;
  ctx.textAlign = "center";
  ctx.font = "10px sans-serif";
  for (let i = 0; i <= 4; i++) {
    const x = PLOT_PAD.left + (pw * i) / 4;
    ctx.fillText(`${((maxDist * i) / 4).toFixed(0)} px`, x, h - 10);
  }
}

function drawSeriesCurve(ctx, profile, series, bounds) {
  const vals = profile[series.key];
  ctx.strokeStyle = series.color;
  ctx.lineWidth = series.key === "luma" ? 2 : 1.3;
  ctx.beginPath();
  for (let i = 0; i < vals.length; i++) {
    const x = PLOT_PAD.left + (profile.distance[i] / bounds.maxDist) * bounds.pw;
    const normY = (vals[i] - bounds.yMin) / bounds.ySpan;
    const y = PLOT_PAD.top + bounds.ph - normY * bounds.ph;
    if (i === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  }
  ctx.stroke();
}

function drawHoverCrosshair(ctx, profile, hoverIdx, bounds, theme) {
  if (hoverIdx < 0 || hoverIdx >= profile.distance.length) {
    return;
  }
  const d = profile.distance[hoverIdx];
  const x = PLOT_PAD.left + (d / bounds.maxDist) * bounds.pw;
  ctx.strokeStyle = theme.crosshair;
  ctx.setLineDash([4, 3]);
  ctx.beginPath();
  ctx.moveTo(x, PLOT_PAD.top);
  ctx.lineTo(x, PLOT_PAD.top + bounds.ph);
  ctx.stroke();
  ctx.setLineDash([]);

  const text = `d=${d}px | L=${profile.luma[hoverIdx]} ` +
    `R=${profile.r[hoverIdx]} G=${profile.g[hoverIdx]} B=${profile.b[hoverIdx]}`;
  ctx.fillStyle = theme.tooltipBg;
  ctx.fillRect(PLOT_PAD.left + 4, PLOT_PAD.top + 2, 275, 18);
  ctx.fillStyle = theme.hover;
  ctx.textAlign = "left";
  ctx.font = "11px monospace";
  ctx.fillText(text, PLOT_PAD.left + 8, PLOT_PAD.top + 14);
}

export function renderPlot(canvas, profile, options) {
  const rect = canvas.parentElement.getBoundingClientRect();
  canvas.width = rect.width;
  canvas.height = rect.height;
  const ctx = canvas.getContext("2d");
  const { theme } = options;
  ctx.fillStyle = theme.plotBg;
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  const yRange = computeYRange(profile, options.series, options.autoY);
  const { yMin, yMax } = yRange;
  drawPlotGrid(ctx, canvas.width, canvas.height, yRange, theme);
  if (!profile || profile.distance.length < 2) {
    return;
  }

  const bounds = {
    pw: canvas.width - PLOT_PAD.left - PLOT_PAD.right,
    ph: canvas.height - PLOT_PAD.top - PLOT_PAD.bottom,
    maxDist: profile.distance[profile.distance.length - 1] || 1,
    yMin,
    ySpan: Math.max(1e-3, yMax - yMin)
  };
  drawXAxisLabels(ctx, canvas.width, canvas.height, bounds.maxDist, theme);
  for (const s of options.series) {
    if (s.show) {
      drawSeriesCurve(ctx, profile, s, bounds);
    }
  }
  drawHoverCrosshair(ctx, profile, options.hoverIdx, bounds, theme);
}
