# LuaJIT Cutline Analyzer (Luvit)

A lightweight web application powered by **Luvit (LuaJIT 2.1 + FFI)** to display images, draw interactive cutlines (`A → B`), plot RGB/Luminance intensity profiles, compute line statistics, and export CSV data.

## Project Structure

- `server.lua` — Luvit HTTP server + LuaJIT FFI `uint8_t[?]` pixel buffer & bilinear cutline sampler
- `public/index.html` — Dark-mode web UI (image canvas, draggable cutline handles, colormaps, live intensity plot)

## Quick Start

1. Install **Luvit** from https://luvit.io/
2. Run the server from this directory:

```powershell
luvit server.lua
```

3. Open your browser to:

```
http://127.0.0.1:8080/
```
