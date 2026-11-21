import {
  applyColormap,
  computeLuminance,
  renderColorbar
} from "./colormaps.js";
import { renderPlot } from "./plot.js";

const MIN_ZOOM = 0.1;
const MAX_ZOOM = 40;
const HANDLE_HIT_RADIUS = 14;

const dom = {
  imageCanvas: document.getElementById("imageCanvas"),
  plotCanvas: document.getElementById("plotCanvas"),
  canvasPane: document.getElementById("canvasPane"),
  colorbarCanvas: document.getElementById("colorbarCanvas"),
  colorbarWrap: document.getElementById("colorbarWrap"),
  splitDivider: document.getElementById("splitDivider"),
  analysisPane: document.getElementById("analysisPane"),
  pixelSwatch: document.getElementById("pixelSwatch"),
  cursorText: document.getElementById("cursorText"),
  statusPill: document.getElementById("statusPill"),
  statusText: document.getElementById("statusText"),
  fileInput: document.getElementById("fileInput")
};

const ctx = dom.imageCanvas.getContext("2d");

const state = {
  imageId: null,
  imgWidth: 0,
  imgHeight: 0,
  rawRGBA: null,
  displayCanvas: document.createElement("canvas"),
  colormap: "original",
  tool: "cutline",
  scale: 1,
  offsetX: 0,
  offsetY: 0,
  line: { x1: 80, y1: 80, x2: 420, y2: 320 },
  dragMode: null,
  dragStart: { x: 0, y: 0 },
  profile: null,
  hoverIdx: -1,
  pendingFetch: null,
  resizingSplit: false
};

function clampCoord(val, max) {
  return Math.max(0, Math.min(max, val));
}

function screenToImage(sx, sy) {
  return {
    x: (sx - state.offsetX) / state.scale,
    y: (sy - state.offsetY) / state.scale
  };
}

function imageToScreen(ix, iy) {
  return {
    x: ix * state.scale + state.offsetX,
    y: iy * state.scale + state.offsetY
  };
}

function snapPointToAngle(anchorX, anchorY, targetX, targetY) {
  const dx = targetX - anchorX;
  const dy = targetY - anchorY;
  const dist = Math.hypot(dx, dy);
  const step = Math.PI / 4;
  const angle = Math.round(Math.atan2(dy, dx) / step) * step;
  return {
    x: clampCoord(anchorX + Math.cos(angle) * dist, state.imgWidth - 1),
    y: clampCoord(anchorY + Math.sin(angle) * dist, state.imgHeight - 1)
  };
}

function getPlotOptions() {
  const isChecked = (id) => document.getElementById(id).checked;
  return {
    hoverIdx: state.hoverIdx,
    autoY: isChecked("chkAutoY"),
    series: [
      { key: "r", color: "#f87171", show: isChecked("chkR") },
      { key: "g", color: "#34d399", show: isChecked("chkG") },
      { key: "b", color: "#60a5fa", show: isChecked("chkB") },
      { key: "luma", color: "#e2e8f0", show: isChecked("chkLuma") }
    ]
  };
}

function drawPlot() {
  renderPlot(dom.plotCanvas, state.profile, getPlotOptions());
}

function drawAnchorHandle(pt, label) {
  ctx.fillStyle = "#0f172a";
  ctx.strokeStyle = "#22d3ee";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.arc(pt.x, pt.y, 8, 0, Math.PI * 2);
  ctx.fill();
  ctx.stroke();
  ctx.fillStyle = "#e2e8f0";
  ctx.font = "bold 10px sans-serif";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(label, pt.x, pt.y + 0.5);
}

function drawCutlineOverlay() {
  const p1 = imageToScreen(state.line.x1, state.line.y1);
  const p2 = imageToScreen(state.line.x2, state.line.y2);
  ctx.strokeStyle = "#22d3ee";
  ctx.lineWidth = 2.5;
  ctx.shadowColor = "rgba(34,211,238,0.6)";
  ctx.shadowBlur = 6;
  ctx.beginPath();
  ctx.moveTo(p1.x, p1.y);
  ctx.lineTo(p2.x, p2.y);
  ctx.stroke();
  ctx.shadowBlur = 0;
  drawAnchorHandle(p1, "A");
  drawAnchorHandle(p2, "B");
}

function drawHoverMarker() {
  if (!state.profile || state.hoverIdx < 0) {
    return;
  }
  const len = state.profile.distance.length;
  if (len < 2) {
    return;
  }
  const ratio = state.hoverIdx / (len - 1);
  const hx = state.line.x1 + (state.line.x2 - state.line.x1) * ratio;
  const hy = state.line.y1 + (state.line.y2 - state.line.y1) * ratio;
  const hp = imageToScreen(hx, hy);
  ctx.fillStyle = "#fbbf24";
  // Dark ring keeps the marker visible on bright pixels and yellow LUTs.
  ctx.strokeStyle = "#0f172a";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.arc(hp.x, hp.y, 5, 0, Math.PI * 2);
  ctx.fill();
  ctx.stroke();
}

function renderImage() {
  ctx.clearRect(0, 0, dom.imageCanvas.width, dom.imageCanvas.height);
  if (!state.imgWidth) {
    return;
  }
  ctx.save();
  ctx.imageSmoothingEnabled = state.scale < 4;
  ctx.drawImage(
    state.displayCanvas,
    state.offsetX,
    state.offsetY,
    state.imgWidth * state.scale,
    state.imgHeight * state.scale
  );
  drawCutlineOverlay();
  drawHoverMarker();
  ctx.restore();
}

function rebuildDisplayCanvas() {
  if (!state.rawRGBA) {
    return;
  }
  state.displayCanvas.width = state.imgWidth;
  state.displayCanvas.height = state.imgHeight;
  const dctx = state.displayCanvas.getContext("2d");
  const imgData = dctx.createImageData(state.imgWidth, state.imgHeight);
  applyColormap(state.rawRGBA, imgData.data, state.colormap);
  dctx.putImageData(imgData, 0, 0);
  renderColorbar(dom.colorbarCanvas, dom.colorbarWrap, state.colormap);
  renderImage();
}

function fitImageToView() {
  const rect = dom.canvasPane.getBoundingClientRect();
  dom.imageCanvas.width = rect.width;
  dom.imageCanvas.height = rect.height;
  if (!state.imgWidth) {
    return;
  }
  const pad = 36;
  const sx = (dom.imageCanvas.width - pad * 2) / state.imgWidth;
  const sy = (dom.imageCanvas.height - pad * 2) / state.imgHeight;
  state.scale = Math.min(sx, sy);
  state.offsetX = (dom.imageCanvas.width - state.imgWidth * state.scale) / 2;
  state.offsetY = (dom.imageCanvas.height - state.imgHeight * state.scale) / 2;
  renderImage();
}

function updateStatsUi(stats) {
  document.getElementById("statLength").textContent = stats.length;
  document.getElementById("statMin").textContent = stats.min;
  document.getElementById("statMax").textContent = stats.max;
  document.getElementById("statMean").textContent = stats.mean;
  document.getElementById("statStd").textContent = stats.stddev;
  document.getElementById("sampleCountBadge").textContent =
    `${stats.samples} samples`;
  document.getElementById("inX1").value = Math.round(state.line.x1);
  document.getElementById("inY1").value = Math.round(state.line.y1);
  document.getElementById("inX2").value = Math.round(state.line.x2);
  document.getElementById("inY2").value = Math.round(state.line.y2);
}

async function fetchCutlineProfile(signal) {
  const res = await fetch("/api/cutline", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ image_id: state.imageId, ...state.line }),
    signal
  });
  if (!res.ok) {
    throw new Error(`Cutline HTTP ${res.status}`);
  }
  return res.json();
}

async function requestCutline() {
  if (!state.imageId) {
    return;
  }
  if (state.pendingFetch) {
    state.pendingFetch.abort();
  }
  state.pendingFetch = new AbortController();
  try {
    state.profile = await fetchCutlineProfile(state.pendingFetch.signal);
    updateStatsUi(state.profile.stats);
    drawPlot();
  } catch (err) {
    if (err.name !== "AbortError") {
      console.error("Cutline request failed:", err);
    }
  }
}

function resetCutlineCoords() {
  state.line = {
    x1: Math.round(state.imgWidth * 0.18),
    y1: Math.round(state.imgHeight * 0.25),
    x2: Math.round(state.imgWidth * 0.82),
    y2: Math.round(state.imgHeight * 0.72)
  };
}

async function uploadRgba(rgba, width, height) {
  state.rawRGBA = rgba;
  state.imgWidth = width;
  state.imgHeight = height;
  document.getElementById("statSize").textContent = `${width}×${height}`;
  const res = await fetch("/api/image", {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Image-Width": String(width),
      "X-Image-Height": String(height)
    },
    body: rgba
  });
  if (!res.ok) {
    throw new Error(`Image upload HTTP ${res.status}`);
  }
  state.imageId = (await res.json()).image_id;
  resetCutlineCoords();
  rebuildDisplayCanvas();
  fitImageToView();
  requestCutline();
}

function loadImageFile(file) {
  if (!file || !file.type.startsWith("image/")) {
    return;
  }
  const img = new Image();
  img.onload = () => {
    const tmp = document.createElement("canvas");
    tmp.width = img.width;
    tmp.height = img.height;
    const tctx = tmp.getContext("2d");
    tctx.drawImage(img, 0, 0);
    const rgba = tctx.getImageData(0, 0, img.width, img.height).data;
    uploadRgba(rgba, img.width, img.height).catch(console.error);
  };
  img.src = URL.createObjectURL(file);
}

function loadSampleImage() {
  const w = 640;
  const h = 480;
  const rgba = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const rDist = Math.hypot(x - w * 0.5, y - h * 0.5);
      const rings = 0.5 + 0.5 * Math.cos(rDist * 0.09);
      const s1 = Math.exp(-((x - 210) ** 2 + (y - 170) ** 2) / 4500);
      const s2 = Math.exp(-((x - 430) ** 2 + (y - 310) ** 2) / 6000);
      const i = (y * w + x) * 4;
      rgba[i] = Math.min(255, Math.round(35 + 150 * rings + 140 * s1));
      rgba[i + 1] = Math.min(255, Math.round(45 + 130 * rings + 170 * s2));
      rgba[i + 2] = Math.min(255, Math.round(65 + 160 * (1 - rings) + 120 * s1));
      rgba[i + 3] = 255;
    }
  }
  uploadRgba(rgba, w, h).catch(console.error);
}

function updateCursorInspector(sx, sy, rect) {
  if (!state.imgWidth || sx < 0 || sy < 0 || sx > rect.width || sy > rect.height) {
    return;
  }
  const pt = screenToImage(sx, sy);
  const ix = Math.floor(pt.x);
  const iy = Math.floor(pt.y);
  if (ix < 0 || iy < 0 || ix >= state.imgWidth || iy >= state.imgHeight) {
    return;
  }
  const idx = (iy * state.imgWidth + ix) * 4;
  const r = state.rawRGBA[idx];
  const g = state.rawRGBA[idx + 1];
  const b = state.rawRGBA[idx + 2];
  const luma = computeLuminance(r, g, b);
  const zoom = (state.scale * 100).toFixed(0);
  dom.pixelSwatch.style.background = `rgb(${r},${g},${b})`;
  dom.cursorText.textContent =
    `(${ix}, ${iy}) | RGB(${r}, ${g}, ${b}) L=${luma} | Zoom ${zoom}%`;
}

function applyCutlineDrag(sx, sy, shiftKey) {
  const pt = screenToImage(sx, sy);
  let cx = clampCoord(pt.x, state.imgWidth - 1);
  let cy = clampCoord(pt.y, state.imgHeight - 1);
  if (shiftKey) {
    const anchor = state.dragMode === "A"
      ? { x: state.line.x2, y: state.line.y2 }
      : { x: state.line.x1, y: state.line.y1 };
    const snapped = snapPointToAngle(anchor.x, anchor.y, cx, cy);
    cx = snapped.x;
    cy = snapped.y;
  }
  if (state.dragMode === "A") {
    state.line.x1 = cx;
    state.line.y1 = cy;
  } else {
    state.line.x2 = cx;
    state.line.y2 = cy;
  }
  renderImage();
  requestCutline();
}

function bindCanvasEvents() {
  dom.imageCanvas.addEventListener("wheel", (e) => {
    if (!state.imgWidth) {
      return;
    }
    e.preventDefault();
    const rect = dom.imageCanvas.getBoundingClientRect();
    const sx = e.clientX - rect.left;
    const sy = e.clientY - rect.top;
    const before = screenToImage(sx, sy);
    const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
    state.scale = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, state.scale * factor));
    state.offsetX = sx - before.x * state.scale;
    state.offsetY = sy - before.y * state.scale;
    renderImage();
  }, { passive: false });

  dom.imageCanvas.addEventListener("mousedown", (e) => {
    if (!state.imgWidth) {
      return;
    }
    const rect = dom.imageCanvas.getBoundingClientRect();
    const sx = e.clientX - rect.left;
    const sy = e.clientY - rect.top;
    if (state.tool === "pan" || e.button === 1) {
      state.dragMode = "pan";
      state.dragStart = { x: sx - state.offsetX, y: sy - state.offsetY };
      return;
    }
    const p1 = imageToScreen(state.line.x1, state.line.y1);
    const p2 = imageToScreen(state.line.x2, state.line.y2);
    if (Math.hypot(sx - p1.x, sy - p1.y) < HANDLE_HIT_RADIUS) {
      state.dragMode = "A";
    } else if (Math.hypot(sx - p2.x, sy - p2.y) < HANDLE_HIT_RADIUS) {
      state.dragMode = "B";
    } else {
      const pt = screenToImage(sx, sy);
      state.dragMode = "new";
      state.line.x1 = clampCoord(pt.x, state.imgWidth - 1);
      state.line.y1 = clampCoord(pt.y, state.imgHeight - 1);
      state.line.x2 = state.line.x1;
      state.line.y2 = state.line.y1;
    }
    renderImage();
  });
}

function bindGlobalDragEvents() {
  window.addEventListener("mousemove", (e) => {
    if (state.resizingSplit) {
      const maxW = window.innerWidth * 0.65;
      const newW = Math.max(320, Math.min(maxW, window.innerWidth - e.clientX));
      dom.analysisPane.style.width = `${newW}px`;
      fitImageToView();
      drawPlot();
      return;
    }
    const rect = dom.imageCanvas.getBoundingClientRect();
    const sx = e.clientX - rect.left;
    const sy = e.clientY - rect.top;
    updateCursorInspector(sx, sy, rect);
    if (!state.dragMode) {
      return;
    }
    if (state.dragMode === "pan") {
      state.offsetX = sx - state.dragStart.x;
      state.offsetY = sy - state.dragStart.y;
      renderImage();
      return;
    }
    applyCutlineDrag(sx, sy, e.shiftKey);
  });

  window.addEventListener("mouseup", () => {
    if (state.dragMode) {
      state.dragMode = null;
      requestCutline();
    }
    if (state.resizingSplit) {
      state.resizingSplit = false;
      dom.splitDivider.classList.remove("dragging");
    }
  });
}

function bindDropAndPlotHover() {
  dom.canvasPane.addEventListener("dragover", (e) => {
    e.preventDefault();
    dom.canvasPane.classList.add("drag-over");
  });
  dom.canvasPane.addEventListener("dragleave", () => {
    dom.canvasPane.classList.remove("drag-over");
  });
  dom.canvasPane.addEventListener("drop", (e) => {
    e.preventDefault();
    dom.canvasPane.classList.remove("drag-over");
    if (e.dataTransfer.files.length) {
      loadImageFile(e.dataTransfer.files[0]);
    }
  });
  dom.splitDivider.addEventListener("mousedown", () => {
    state.resizingSplit = true;
    dom.splitDivider.classList.add("dragging");
  });
  dom.plotCanvas.addEventListener("mousemove", (e) => {
    if (!state.profile || state.profile.distance.length < 2) {
      return;
    }
    const rect = dom.plotCanvas.getBoundingClientRect();
    const t = clampCoord((e.clientX - rect.left - 42) / (rect.width - 58), 1);
    state.hoverIdx = Math.round(t * (state.profile.distance.length - 1));
    drawPlot();
    renderImage();
  });
  dom.plotCanvas.addEventListener("mouseleave", () => {
    state.hoverIdx = -1;
    drawPlot();
    renderImage();
  });
}

function bindToolbarButtons() {
  document.getElementById("btnUpload").onclick = () => dom.fileInput.click();
  dom.fileInput.onchange = (e) => loadImageFile(e.target.files[0]);
  document.getElementById("btnSample").onclick = loadSampleImage;
  document.getElementById("btnExportPng").onclick = () => {
    const link = document.createElement("a");
    link.download = "cutline_profile.png";
    link.href = dom.plotCanvas.toDataURL("image/png");
    link.click();
  };
  document.getElementById("btnExport").onclick = () => {
    if (!state.imageId) {
      return;
    }
    const q = new URLSearchParams({ image_id: state.imageId, ...state.line });
    window.location.href = `/api/export?${q.toString()}`;
  };
  document.getElementById("toolCutline").onclick = () => setActiveTool("cutline");
  document.getElementById("toolPan").onclick = () => setActiveTool("pan");
  document.getElementById("toolReset").onclick = () => {
    if (!state.imgWidth) {
      return;
    }
    resetCutlineCoords();
    fitImageToView();
    requestCutline();
  };
  document.getElementById("toolZoomIn").onclick = () => {
    state.scale = Math.min(MAX_ZOOM, state.scale * 1.25);
    renderImage();
  };
  document.getElementById("toolZoomOut").onclick = () => {
    state.scale = Math.max(MIN_ZOOM, state.scale / 1.25);
    renderImage();
  };
  document.getElementById("colormapSelect").onchange = (e) => {
    state.colormap = e.target.value;
    rebuildDisplayCanvas();
  };
  ["chkLuma", "chkR", "chkG", "chkB", "chkAutoY"].forEach((id) => {
    document.getElementById(id).onchange = drawPlot;
  });
  ["inX1", "inY1", "inX2", "inY2"].forEach((id) => {
    document.getElementById(id).addEventListener("change", applyEndpointInputs);
  });
  window.addEventListener("resize", () => {
    fitImageToView();
    drawPlot();
  });
}

function setActiveTool(tool) {
  state.tool = tool;
  const isCut = tool === "cutline";
  document.getElementById("toolCutline").classList.toggle("active", isCut);
  document.getElementById("toolPan").classList.toggle("active", !isCut);
  dom.imageCanvas.style.cursor = isCut ? "crosshair" : "grab";
}

function applyEndpointInputs() {
  if (!state.imgWidth) {
    return;
  }
  const readNum = (id, max) => {
    return clampCoord(Number(document.getElementById(id).value) || 0, max);
  };
  state.line.x1 = readNum("inX1", state.imgWidth - 1);
  state.line.y1 = readNum("inY1", state.imgHeight - 1);
  state.line.x2 = readNum("inX2", state.imgWidth - 1);
  state.line.y2 = readNum("inY2", state.imgHeight - 1);
  renderImage();
  requestCutline();
}

async function checkBackendHealth() {
  try {
    const res = await fetch("/api/health");
    if (!res.ok) {
      throw new Error(`Health HTTP ${res.status}`);
    }
    const data = await res.json();
    dom.statusText.textContent = `LuaJIT: ${data.runtime}`;
  } catch (err) {
    console.error("Backend health check failed:", err);
    dom.statusPill.classList.add("offline");
    dom.statusText.textContent = "Backend Offline";
  }
}

bindCanvasEvents();
bindGlobalDragEvents();
bindDropAndPlotHover();
bindToolbarButtons();
checkBackendHealth();
loadSampleImage();
