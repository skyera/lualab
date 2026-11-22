const PALETTES = [
  { bg: "#fff0f3", outer: "#c9184a", inner: "#ff758f", center: "#ffd166" },
  { bg: "#fff8e7", outer: "#e07a00", inner: "#ffb703", center: "#5c3d00" },
  { bg: "#f3e8ff", outer: "#7b2cbf", inner: "#c77dff", center: "#ffe66d" },
  { bg: "#e8f7ff", outer: "#0077b6", inner: "#48cae4", center: "#ffd166" },
  { bg: "#fff1eb", outer: "#e63946", inner: "#ff9f89", center: "#fff3b0" }
]

function drawPetalRing(ctx, count, radius, petalW, petalH, color, spin) {
  ctx.fillStyle = color;
  for (let i = 0; i < count; i++) {
    const angle = (i * Math.PI * 2) / count + spin;
    ctx.save();
    ctx.rotate(angle);
    ctx.beginPath();
    ctx.ellipse(0, -radius, petalW, petalH, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }
}

export function createRandomFlowerBlob() {
  const canvas = document.createElement("canvas");
  canvas.width = 160;
  canvas.height = 160;
  const ctx = canvas.getContext("2d");
  const pal = PALETTES[Math.floor(Math.random() * PALETTES.length)];
  const petals = 5 + Math.floor(Math.random() * 5);

  ctx.fillStyle = pal.bg;
  ctx.fillRect(0, 0, 160, 160);
  ctx.translate(80, 80);
  drawPetalRing(ctx, petals, 34, 18, 30, pal.outer, 0);
  drawPetalRing(ctx, petals, 22, 14, 22, pal.inner, Math.PI / petals);

  ctx.fillStyle = pal.center;
  ctx.beginPath();
  ctx.arc(0, 0, 14, 0, Math.PI * 2);
  ctx.fill();

  return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}
