# lualab
```
| |_   _  __ _  | | __ _| |__  
| | | | |/ _` | | |/ _` | '_ \ 
| | |_| | (_| | | | (_| | |_) |
|_|\__,_|\__,_| |_|\__,_|_.__/ 
```

A collection of Lua embedding examples using LuaJIT and LuaBridge.

## Prerequisites
Ensure you have the following installed on your system:
- `g++` (C++11 or later)
- `make`
- `libreadline-dev`

## Getting Started

### 1. Clone the repository
This project uses submodules for LuaJIT and LuaBridge. Clone with the `--recurse-submodules` flag:
```bash
git clone --recurse-submodules https://github.com/skyera/lualab.git
cd lualab
```
If you have already cloned the repository, initialize submodules with:
```bash
git submodule update --init --recursive
```

### 2. Build
Run `make` to build all binaries. This will automatically build the LuaJIT submodule if it hasn't been built yet.
```bash
make
```

### 3. Run
- **Interactive Shell (with C++ bindings):**
  ```bash
  ./demo_luabridge
  ```
- **Execute a script:**
  ```bash
  ./demo_luabridge scratch_lua_features.lua
  ```
- **Run other examples:**
  ```bash
  ./demo_custom_userdata   # Creating custom C types for Lua
  ./demo_stack_api        # Low-level Lua stack manipulation
  ./demo_repl             # Simple interactive REPL
  ```

- **Run FFI Examples (requires LuaJIT):**
  ```bash
  luajit ffi_duplicates.lua ~/Downloads ~/Pictures  # Find exact duplicate files (Windows / Linux)
  ./LuaJIT/src/luajit ffi_system_info.lua   # Rich POSIX system diagnostics, hardware specs & memory benchmark (--compact, --json, --bench)
  ./LuaJIT/src/luajit ffi_advanced_demo.lua
  ./LuaJIT/src/luajit ffi_sqlite_demo.lua   # In-memory SQLite3 FFI engine & benchmark
  luajit ffi_log_explorer.lua             # Browse current directory; Enter opens logs, Backspace goes up
  luajit ffi_log_explorer.lua app.log worker.log # Windows/Linux: follow, filter, severity, bookmarks
  luajit ffi_asteroids.lua                 # Linux terminal Asteroids (A/D rotate, W thrust, Space fire; --snapshot, --test)
  ./LuaJIT/src/luajit ffi_game_snake.lua    # Real-time terminal Snake game via POSIX FFI
  ./LuaJIT/src/luajit ffi_image_terminal_demo.lua  # Fast C image generation & terminal truecolor viewer
  luajit ffi_thumbnailer.lua [dir] [--max WxH] [--cols N]    # Interactive TUI thumbnail browser (PgUp/PgDn, lazy-load, cache)
  ./LuaJIT/src/luajit view_image_terminal.lua <image.png|jpg|ppm>  # Terminal image viewer with auto-scaling
  ./LuaJIT/src/luajit pix.lua [dir]                                # Interactive terminal image gallery & viewer (defaults to '.')
  ./LuaJIT/src/luajit gallery_portrait.lua  # Dynamic procedural portrait gallery with interactive selection
  ./LuaJIT/src/luajit ffi_3d_viewer.lua     # Real-time interactive 3D polygonal mesh engine with Z-buffer shading
  ./LuaJIT/src/luajit ffi_fractal_explorer.lua # Real-time truecolor mathematical fractal explorer (Mandelbrot, Julia, etc.)
  ./LuaJIT/src/luajit ffi_image_filter_studio.lua # Interactive Photoshop/Lightroom-style image processing & filter studio
  ./LuaJIT/src/luajit todo_tui.lua         # Interactive keyboard-driven Todo TUI with modal dialogs & categories
  luajit dictionary_web/app.lua         # Wordbook web app: local dictionary, dict.cn, Youdao, SQLite journal & review
  luajit download_dict.lua              # Download and import the offline Wordset dictionary if needed
  ./LuaJIT/src/luajit ffi_tetris.lua        # Classic Tetris terminal game in pure LuaJIT FFI (or: ./tetris.lua)
  ./LuaJIT/src/luajit ffi_chinese_chess.lua # Chinese Chess (Xiangqi) engine with Alpha-Beta AI & ANSI/ASCII TUI
  ./LuaJIT/src/luajit ffi_chip8.lua        # Retro Chip-8 CPU emulator & VM with 7 built-in classic games
  ./LuaJIT/src/luajit ffi_falling_sand.lua # Interactive Falling Sand & Cellular Physics Sandbox (Truecolor & Mouse)
  ./LuaJIT/src/luajit ffi_verlet_cloth.lua # Interactive Verlet cloth & rope simulator (drag, cut, pause)
  ./LuaJIT/src/luajit ffi_demoscene_studio.lua # Classic 1990s Demoscene Effects Studio (DOOM Fire, Plasma, Comanche Voxel, Starfield, Matrix)
  ./LuaJIT/src/luajit ffi_wolf3d_raycaster.lua # Wolfenstein-style 3D Raycasting Engine (DDA, Textures, Doors, Sprites & Weapons)
  ./LuaJIT/src/luajit ffi_game_2048.lua    # 2048 sliding-tile puzzle game & automated Expectimax AI solver
  ./LuaJIT/src/luajit ffi_image_defect_detector.lua --demo # Optical defect inspector & dynamic PCB image diff engine
  ./LuaJIT/src/luajit ffi_wafer_d2d_inspector.lua # Semiconductor 300mm wafer Die-to-Die (D2D) inspection & KLARF exporter
  ./LuaJIT/src/luajit ffi_midi_keyboard.lua       # Real-time interactive synthesizer, visual piano keyboard & oscilloscope
  ./LuaJIT/src/luajit ffi_elf_inspector.lua <bin> # Interactive ELF binary analyzer, symbol inspector & disassembler
  ./LuaJIT/src/luajit codefind.lua index .        # High-performance local code & document search engine (SQLite FTS5)
  ./LuaJIT/src/luajit luatop.lua                  # Professional terminal system & process monitor (CPU, GPU, Net, Tree)
  ./LuaJIT/src/luajit enigma.lua                  # WWII Enigma cipher machine simulator & glowing lampboard TUI
  ./LuaJIT/src/luajit lan_dashboard.lua           # Real-time LAN device radar & glassmorphic web dashboard (--port 8888, --scan-only)
  ```

  LAN Dashboard saves its device inventory in `lan_inventory.json` in the working
  directory. MAC identities preserve first-seen timestamps and custom names across
  IP changes; missing devices remain visible as **Not observed**, with their last
  scan observation time. This time means the device appeared in the scan, even if
  it did not respond to ping. Saved devices start as **Not yet checked** after a
  restart. Scans without port probing preserve previously detected services.
  `lan_names.json` remains compatible. Set `LAN_INVENTORY_FILE` to use another
  inventory path. Invalid inventories are reported and preserved; repair or move
  the file and restart to resume saving. Changed inventories are replaced via a
  temporary file, so failed writes leave the previous inventory intact.

  Inventory checks: `luajit test_lan_inventory.lua`,
  `luajit test_lan_dashboard.lua`, and `node test_lan_dashboard_ui.js`.

  Web scans run in a separate LuaJIT worker, including startup and automatic
  scans. The dashboard polls progress every 500 ms and offers **Cancel scan**;
  the current inventory stays visible until a completed scan replaces it.
  Cancellation or worker failure preserves the current inventory. Renames and
  port probes made during a scan survive completion. CLI `--scan-only` and
  `--json` scans remain synchronous.

  `POST /api/scan` now returns **202 Accepted** with a `scan` job object instead
  of waiting for device results. Duplicate starts return the current job.
  Poll `GET /api/scan` for `state`, `phase`, `completed`, and `total`, then fetch
  `/api/devices` after `state` becomes `completed`. Use
  `POST /api/scan/cancel` to stop a running job. `/api/devices` also includes
  the job status. Job states are `idle`, `running`, `cancelling`, `cancelled`,
  `completed`, and `failed`. The discovery count covers addresses sent an ARP
  priming packet; the device phase checks entries discovered in the neighbor cache.

  Worker checks: `luajit test_lan_scan_job.lua` and
  `python3 test_lan_dashboard_scan.py` (POSIX live HTTP harness).

  **Changes** shows the latest 1,000 discoveries, IP changes, and port
  observations, saved with the inventory. First-time reachable ports appear as
  **Port detected**; subsequent probes can report **Port opened** or
  **Port no longer reachable**. Only ports actually checked by a probe can change
  their recorded state. Scans that skip probing and cancelled scans do not create
  port events. Standard probes preserve services outside their scan scope.

  Use **Organize** on a device card or table row to mark it trusted and assign
  up to eight tags, with 1–64 characters per tag. Trust and tags stay with the
  device's MAC identity across IP changes and restarts, including edits made
  during a background scan. Devices without a valid MAC use their IP identity.
  The **Unrecognized** filter shows devices not marked trusted; tags and search
  work in both Devices and Changes. Existing inventories start with empty tags,
  no trusted devices, and no retrospective timeline.

  `GET /api/events` returns the retained events in recording order.
  `POST /api/device/meta` accepts JSON such as
  `{"id":"mac:aa:bb:cc:dd:ee:01","trusted":true,"tags":["Office","Storage"]}`.
  Device IDs are included in `/api/devices`. Invalid input returns 400, unknown
  IDs return 404, and persistence failures return 500 without changing metadata.
  Feature checks: `luajit test_lan_inventory_features.lua`.

  Device details include optional **5000–6000**, **8000–9000**, and **Both ranges**
  TCP probe presets. Endpoints are inclusive: both ranges check 2,002 ports.
  Custom probes accept up to 4,096 distinct ports, remove duplicates, and reject
  invalid or oversized ranges instead of silently truncating them. Standard
  probes keep their existing service list.

  Scopes above 64 ports run in an independent background worker. Its progress and
  **Cancel port probe** control remain visible when device details are closed;
  cancellation preserves existing observations. One large port probe can run
  alongside a LAN scan. `GET /api/probe?ip=...&ports=...` returns **202 Accepted**
  for large scopes; poll `GET /api/probe/status` and cancel with
  `POST /api/probe/cancel`. Completed jobs include reachable `ports`, and known
  device results are saved to inventory and timeline. Conflicting large probes
  return 409. Parser checks: `luajit test_lan_ports.lua`.

- **Run Unit Tests:**
  ```bash
  make test
  # or directly:
  ./LuaJIT/src/luajit test_ffi_suite.lua
  ```

## Maintenance
- **Remove binaries:** `make clean`
- **Remove binaries and clean submodules:** `make clean-all`

## Reference
* [LuaBridge](https://github.com/vinniefalco/LuaBridge)
* [LuaJIT](https://github.com/LuaJIT/LuaJIT)
* [Lua Quick Start Guide](https://github.com/PacktPublishing/Lua-Quick-Start-Guide)
* [Awesome Lua](https://github.com/LewisJEllis/awesome-lua)
* [lua-users.org](http://lua-users.org/)

### Deploy the log explorer

```bash
luajit deploy.lua --app logexplorer
logexplorer                 # Browse the current directory
logexplorer app.log         # Follow a log file
```

The default install location is `~/bin` on Linux and `C:\app\bin` on Windows.

### Duplicate-file finder

`ffi_duplicates.lua` is a standalone script that recursively scans files or
directories using Linux libc FFI (`statx`, `opendir`, `read`) or native Windows
APIs. Both backends and JSON output are included in the same script, with no
additional Lua modules or external commands required. It groups candidates by size, computes a streaming
hash, and confirms every match byte-for-byte. It never deletes or modifies files.

```bash
luajit ffi_duplicates.lua ./photos ./backup
luajit ffi_duplicates.lua --tui ./photos ./backup
luajit ffi_duplicates.lua --min-size=1048576 .
luajit ffi_duplicates.lua --json . > duplicates.json
luajit ffi_duplicates.lua -- ./-unusual-directory
luajit test_ffi_duplicates.lua
```

On Windows, use native Windows LuaJIT (no WSL needed):

```powershell
luajit ffi_duplicates.lua "C:\Users\Alice\Downloads" "D:\Backup"
luajit ffi_duplicates.lua --json "C:\Users\Alice\Pictures"
```

Windows paths and command-line arguments use Unicode Win32 APIs, including
extended-length drive and UNC paths. Symlinks, junctions, and other reparse
points are skipped, including cloud placeholders with reparse attributes.

With no paths, it scans the current directory. Hidden files and empty files are
included; `--min-size=1` excludes empty files. Symlinks and special files are
skipped, and repeated roots and hard links are counted once by device/inode.
Output is sorted by descending file size and then path. Text output quotes paths
so control characters cannot affect the terminal. JSON contains `groups`
(`size`, `paths`), `files`, `redundant_bytes`, `skipped_links`, and `errors`.

For Linux filenames containing invalid UTF-8, JSON display paths substitute
U+FFFD for invalid bytes. The affected group also includes `paths_hex`, a parallel
array encoding the original bytes of every path. Error records similarly add
`path_hex` or `message_hex` when needed. Decode hex to recover the exact bytes;
valid Unicode paths keep their existing representation.

Use `--tui` in an interactive Linux terminal or Windows console to browse
duplicate groups sorted by redundant bytes. Wide terminals show groups and files
side by side; narrow terminals show the active pane. Arrow keys or `j`/`k` move,
Tab switches panes, Page Up/Down and Home/End navigate, `/` filters paths, Space
marks groups, Enter opens scrollable full-path details, and `!` opens scan errors.
Escape returns from a view or cancels a prompt; `q` exits. During scanning,
`q`/Escape cancel and Ctrl-C exits with status 130.
Bordered panes align file counts and redundant sizes. A blue selection bar shows
the active item, and the status line counts marked groups. Long paths display
their trailing filename; Enter shows full paths. Help, errors, and scan progress
use the same layout, with a compact fallback for small terminals. Set `NO_COLOR`
to disable colors (also disabled when `TERM=dumb`); borders and selection markers
remain visible.
Press `?` for scrollable help with all keys, filtering instructions, and export
behavior; Enter/Escape returns to the previous view. `--help` (or `-h`) shows
options, Linux/Windows examples, scan behavior, exit codes, and TUI keys.

Press `e` to export marked groups, or the current group when none are marked.
Enter a new JSON filename; existing files are preserved. Scanned files are never
modified. A failed write may leave a partial export file. `--tui` and `--json`
cannot be combined, and redirected terminal input/output is rejected cleanly.

TUI verification commands:

```bash
luajit test_ffi_duplicates_tui.lua
python3 test_ffi_duplicates_tui_pty.py  # Linux: real terminal resize/input/signal checks
```

Requires Windows 8+ with file-ID support, or 64-bit Linux with libc/kernel
support for `statx`. Exit status is 0 for
complete scans (including no duplicates), 1 for filesystem/read errors, and 2
for invalid arguments. Errors appear on stderr and in JSON. Read buffers are
bounded; file metadata and paths are held in memory. Detected changes during
hashing/comparison produce errors, but a scan is not a filesystem snapshot:
rescan quiescent files before taking action. Redundant bytes describe logical
content, not guaranteed disk savings from sparse, compressed, or reflink files.
