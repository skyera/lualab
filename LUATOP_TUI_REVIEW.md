# luatop.lua — Comprehensive TUI Architecture Review & UI Improvement Proposals

This document provides a detailed architectural, performance, and user experience review of [`luatop.lua`](file:///home/zliu/test/lualab/luatop.lua), evaluating its responsive 4-pane grid layout, telemetry pipelines, theme engine, process tree manipulation, and interactive modal dialogs. It presents **4 major UI improvement proposals** designed to elevate `luatop.lua` to modern terminal monitor standards set by `btop`, `bottom`, and `htop`.

---

## 1. Executive Summary & Assessment Matrix

[`luatop.lua`](file:///home/zliu/test/lualab/luatop.lua) (3,838 lines) is a high-performance terminal system and process monitor written in pure LuaJIT with FFI. It provides zero-fork hardware telemetry via direct POSIX C I/O and Win32 APIs, monitoring CPU (per-core, scaling frequencies, package thermals), RAM & Swap, GPU (discrete & integrated), disk filesystems & I/O throughput, network bandwidth, and a zero-fork process table with hierarchical tree folding (`t`), smart multi-tag search (`/`), and interactive signal (`k`) and renice (`R`) modals.

### Current Architecture Assessment

| Subsystem | Current Implementation | Rating | Strengths & Remaining Limitations |
| :--- | :--- | :---: | :--- |
| **Telemetry Engine** | Direct `/proc` & Win32 FFI | ⭐⭐⭐⭐⭐ | Zero-fork, sub-millisecond polling, thread-safe, Linux & Windows compatible. |
| **Theme Engine** | 24-bit Truecolor palettes | ⭐⭐⭐⭐⭐ | 5 presets (Tokyo Night, Dracula, Nord, Monokai, Cyberpunk), on-the-fly cycling (`T`). |
| **Layout & Grids** | Responsive 4-pane grid | ⭐⭐⭐⭐☆ | Adapts horizontally/vertically; **lacks individual pane focus and zoom/maximization**. |
| **Visual Meters** | Block meters & 1-row sparklines | ⭐⭐⭐⭐☆ | Smooth meters; **1-row sparklines lack vertical resolution and timeline scale**. |
| **Process Management** | Table & Foldable Tree (`t`) | ⭐⭐⭐⭐☆ | Parent-child tree rollups; **lacks quick category pills (User/System/Zombies)**. |
| **Diagnostic Tooling** | Signal (`k`) & Renice (`R`) | ⭐⭐⭐☆☆ | Interactive modals work well; **lacks open file (`lsof`) or syscall trace (`strace`) hooks**. |
| **Input & Search** | Raw mode + symbolic keys | ⭐⭐⭐☆☆ | Fast typing; **spacebar dropped in search (`#k == 1` rejects `"SPACE"`)**. |

---

## 2. Key Architectural Strengths

1. **Zero-Fork Telemetry Core**:
   - Linux: Directly opens and parses `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `/proc/diskstats`, and `/proc/[pid]/stat`, `/proc/[pid]/io` using native `open()`, `read()`, and `close()` FFI without invoking subprocesses like `ps`, `top`, or `df`.
   - Windows: Leverages `kernel32`, `psapi`, and registry APIs (`GetSystemTimes`, `GlobalMemoryStatusEx`, `CreateToolhelp32Snapshot`, `GetDiskFreeSpaceExA`).
2. **Process Tree Folding with Subtree Metric Rollups**:
   - `build_process_tree()` constructs a tree with cyclic PPID detection.
   - Folded parent rows (`Space`/`Tab`) display cumulative aggregated CPU (`total_sub_cpu`) and memory (`total_sub_res`) rollups.
3. **Synchronized Atomic Frame Emission**:
   - Wraps frame output in synchronized update escapes (`\27[?2026h` ... `\27[?2026l`) to eliminate visual tearing and flickering during high refresh rates.
4. **Rich Process Inspection & Signal Dispatching**:
   - Deep inspection modal (`Enter`/`i`) breaking down VIRT, RES, PPID, Nice, I/O rates, elapsed runtime, and full commandline arguments.
   - Safe signal picker (`k`) displaying signal descriptions and prevent inadvertent kills.

---

## 3. Four Concrete UI Improvement Proposals

---

### Proposal 1: Interactive Pane Focus & Maximized View (`Tab`, `1`-`4`, `z` / `f`)

#### Problem Statement
Currently, the 4 panes (CPU, Memory & Storage, Network, Processes) have fixed proportions:
- On high-core workstations (16, 32, 64 cores), the CPU pane consumes vertical space, restricting the process table to 10–12 rows.
- If a user is diagnosing high CPU spikes or network saturation, they cannot maximize a single pane to inspect high-density data.
- The process list is always the only pane receiving keyboard navigation.

#### Proposed Design & Behavior
1. **Active Pane Focus (`Tab` / `Shift+Tab` or `1`-`4`)**:
   - `[1] CPU`, `[2] Memory & Disks`, `[3] Network`, `[4] Processes`.
   - Focused pane receives `C.border_focus` (bright cyan/accent border) and an active indicator in the title:
     `╭─── [4] Processes (Active) ──────────────────────────╮`
2. **Zoom / Maximized Fullscreen Toggle (`z` or `f`)**:
   - Pressing `z` or `f` maximizes the focused pane to occupy **100% of the screen area** between header and footer.
   - **Zoomed Processes**: Expands from 12 rows to 40+ rows with extended columns (`VIRT`, `NICE`, `PPID`, `DISK R`, `DISK W`).
   - **Zoomed CPU**: Expands per-core view into a detailed matrix with core temperature, scaling frequency, and historical sparklines per core.
   - **Zoomed Network**: Expands into an interface picker and multi-row bandwidth timeline.
   - Pressing `z`, `f`, or `Esc` immediately restores the balanced 4-pane grid.

#### Visual Mockup (Zoomed Process View `z`)
```
  ⚡ LUATOP v2.2 │ CachyOS │ Load: 0.42, 0.58, 0.65 │ Tasks: 274 procs │ Theme: Tokyo Night │ 1.0s
╭─── [4] Processes (MAXIMIZED - Press [z] or [Esc] to Restore) ─────────────────────────────────────────────────────────────╮
│  PID     USER     %CPU    %MEM   RES       VIRT      TH   NICE  STAT  TIME+      DISK R    DISK W    COMMAND                 │
│ ▶14820   zliu     42.5%   1.2%   45.2 MB   180.4 MB   4     0   ● R    0:12.44    0 B/s     4.2 KB/s  luajit luatop.lua       │
│  12044   zliu     12.1%   3.4%  138.0 MB   890.2 MB  12     0   ○ S    4:21.05    1.2 MB/s  0 B/s     /usr/bin/code           │
│   1042   root      1.8%   0.8%   32.0 MB    98.1 MB   1     0   ○ S    1:05.18    0 B/s     0 B/s     /usr/lib/systemd-journal│
│  18920   zliu      0.5%   0.2%    8.4 MB    22.0 MB   1     0   ○ S    0:00.32    0 B/s     0 B/s     zsh                     │
│  19104   zliu      0.0%   0.1%    3.2 MB    14.0 MB   1     0   ○ S    0:00.08    0 B/s     0 B/s     tmux                    │
│  ... (45 visible process rows fitting the full terminal height) ...                                                       │
╰───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
  [Tab] Next Pane  [z/f] Restore Grid  [/] Filter  [k] Kill  [R] Renice  [c/m/p/n] Sort  [?] Help  [q] Quit
```

---

### Proposal 2: Multi-Line Braille / 2D Historical Trend Graphs (`g` / Graph Mode)

#### Problem Statement
`luatop.lua` currently uses 1-row Unicode block sparklines (` ▂▃▄▅▆▇█`) in headers. While compact, 1-row sparklines lack vertical resolution (only 8 levels), cannot display min/max scale values, and do not convey rapid oscillations in bandwidth or CPU load.

#### Proposed Design & Behavior
1. Implement a 2D Braille chart generator `make_braille_chart(data, width, height, color)`:
   - Uses Unicode Braille patterns (`\u2800` to `\u28FF`), providing a **2x4 dot matrix per character cell**.
   - A 4-row high Braille chart gives **16 vertical steps of resolution** and **$2 \times \text{width}$ horizontal sample points**.
2. Pressing `g` toggles **Graph Mode**:
   - In the Network pane: transforms the 3-row summary into a 5-row dual RX/TX timeline with labeled peak axis markers (`8.2 MB/s`, `0 B/s`).
   - In the CPU pane: displays a rolling 60-second system load curve alongside core meters.

#### Visual Mockup (Network Braille Graph)
```
╭─── Network (wlan0) [Graph Mode: 60s History] ─────────────────────────────────────────────────────────╮
│ RX: 2.45 MB/s (Peak: 8.20 MB/s)                   TX: 412 KB/s (Peak: 1.10 MB/s)                      │
│ 8.2M ┤    ⢠⠊⠑⡄     ⢀⠔⠉⡆                 1.1M ┤             ⢀⡠⠤⡀                    │
│ 4.1M ┤  ⢀⠎   ⠣⡀ ⢀⠜  ⠸⡀               550K ┤     ⡠⠔⠊⠉    ⠈⠢⡀                │
│ 0 B  ┴──⠁─────⠈─⠤⠊──────┴───────────────   0 B  ┴────⠊───────────────┴─────────────── │
╰───────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

---

### Proposal 3: Process Diagnostic Command Runner Modal (`:`, `!`) with Macro Expansion

#### Problem Statement
When diagnosing system bottlenecks, finding the culprit PID in `luatop` is only step one. The user immediately wants to run diagnostics:
- *What open files or network connections does it have?* (`lsof -p <PID>`)
- *What system calls is it blocking on?* (`strace -p <PID>`)
- *What does its memory map look like?* (`pmap -x <PID>`)
- *What are its thread stack traces?* (`pstack <PID>`)

Currently, users must exit `luatop`, remember the PID, and type commands manually.

#### Proposed Design & Behavior
1. Pressing `:` or `!` opens the **Process Diagnostic Runner** modal for the currently selected process.
2. Supports dynamic macro substitution:
   - `%p` $\to$ selected process PID
   - `%c` $\to$ binary / comm name
   - `%u` $\to$ username
3. Provides one-touch numeric presets:
   - `[1] Open Files & Sockets` $\to$ `lsof -p %p | less`
   - `[2] Live Syscall Trace` $\to$ `strace -f -p %p`
   - `[3] Thread Stack Trace` $\to$ `pstack %p 2>/dev/null || gdb -batch -ex "thread apply all bt" -p %p`
   - `[4] Memory Map (pmap)` $\to$ `pmap -x %p | less`
   - `[5] Systemd Service Journal` $\to$ `journalctl _PID=%p -n 50 --no-pager`
4. Uses `suspend_raw_mode()` to execute the command inline on the active screen buffer, flushes input via `tcflush`, pauses with `[Press Enter to return]`, and restores `luatop` with zero screen flicker.

#### Visual Mockup (Diagnostic Modal `:`)
```
╭─── Process Diagnostic Runner [PID 14820: luajit] ──────────────────╮
│ Command: [lsof -p %p                                           ]   │
│ Preview: $ lsof -p 14820                                           │
│                                                                    │
│ Quick Presets:                                                     │
│   [1] Open Files & Sockets       (lsof -p %p)                      │
│   [2] Live Syscall Trace         (strace -f -p %p)                 │
│   [3] Thread Stack Trace         (pstack %p / gdb -p %p)           │
│   [4] Memory Map Analysis        (pmap -x %p)                      │
│   [5] Systemd Service Journal    (journalctl _PID=%p -n 50)        │
│                                                                    │
│ Tokens: %p (PID), %c (Binary), %u (User)                           │
│ [Enter] Execute   [1-5] Run Preset   [Esc] Cancel                  │
╰────────────────────────────────────────────────────────────────────╯
```

---

### Proposal 4: Process Category Tabs / Filter Pills & Process State Badges (+ Search Bug Fix)

#### Problem Statement & Bug Uncovered
1. **Filtering Ergonomics**: Filtering currently requires pressing `/` and typing exact queries (`u:zliu`, `s:Z`, `cpu>5`). Common workflows (isolating *My* processes, *Root* services, or *Zombies*) take multiple keystrokes.
2. **Search Spacebar Bug**: In [`luatop.lua` line 2825](file:///home/zliu/test/lualab/luatop.lua#L2825):
   ```lua
   elseif #k == 1 and k:byte() >= 32 and k:byte() <= 126 then
       filter_query = filter_query .. k
   ```
   `read_key()` returns symbolic token `"SPACE"` (length 5) on spacebar presses. Thus, **typing spaces in search mode is silently ignored!**

#### Proposed Design & Behavior
1. **Interactive Category Pills**:
   Display interactive filter tabs above the process table:
   `[All: 274]` `[User: 182]` `[System: 92]` `[Active: 8]` `[Zombies: 0]`
   - Cycle between tabs using `[` and `]` or hotkeys `F1`-`F4`.
   - `[User]`: Filters processes matching `$USER`.
   - `[Active]`: Filters active processes (`%CPU > 0.5%`).
   - `[Zombies]`: Immediately isolates all defunct (`STAT == "Z"`) processes.
2. **Color-Coded State Badges**:
   Replace plain single-letter `STAT` with visual status indicators:
   - `● R` (Running / Runnable, Green)
   - `○ S` (Sleeping, Dim)
   - `■ D` (Uninterruptible Disk Sleep / I/O Wait, Amber)
   - `▲ Z` (Zombie / Defunct, Flashing Red)
   - `❚ T` (Stopped / Traced, Cyan)
3. **Spacebar Normalization**:
   Add `if k == "SPACE" then k = " " end` in `in_search_mode`.

#### Visual Mockup (Category Pills & State Badges)
```
╭─── Processes: 274 [Sort: CPU▼] [Tree: OFF] ────────────────────────────────────────────────────────╮
│  [All: 274]  ▶[User: 182]◀  [System: 92]  [Active: 8]  [Zombies: 0]      (Press [ / ] to switch)  │
│  PID     USER     %CPU    %MEM   RES       TH   STAT   TIME+      DISK R    DISK W    COMMAND      │
│ ▶14820   zliu     42.5%   1.2%   45.2 MB   4    ● R    0:12.44    0 B/s     4.2 KB/s  luajit luatop│
│  12044   zliu     12.1%   3.4%  138.0 MB  12    ○ S    4:21.05    1.2 MB/s  0 B/s     code         │
│  19201   zliu      0.0%   0.1%    2.4 MB   1    ■ D    0:00.02    14.2 MB/s 0 B/s     dd if=/dev/..│
│  20411   zliu      0.0%   0.0%    0 B      1    ▲ Z    0:00.00    0 B/s     0 B/s     <defunct>    │
╰────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

---

## 4. Existing Discovered Issues in Test Suites

During this review, running `luajit test_luatop.lua` revealed one existing test failure:
- **Test 225**: `Error: test_luatop.lua:225: Disk dual column row must not be truncated with ellipsis`
  - *Cause*: In `test_luatop.lua` line 182, the test runner evaluates disk rows across narrow widths (`rw = 50, 54, 66...`). At `rw = 50`, `col_w = 22`. Mount points + usage percentages + capacity strings require $\ge 23$ characters, causing intentional truncation with `...`. However, `luatop.lua` itself only activates dual columns when `right_w >= 50` AND `num_mounts >= 4`.
  - *Fix*: Align `test_luatop.lua`'s dual-column condition with `luatop.lua`'s actual threshold, or format capacity in compact notation (`4G/39G`) when column width is tight.

---

## 5. Verification & Testing Strategy

In compliance with [`AGENTS.md`](file:///home/zliu/test/lualab/AGENTS.md):
1. **Decoupled Frame Generation**:
   Expose pure frame generators (`render_zoom_frame`, `render_diagnostic_modal_frame`, `make_braille_chart`) so they can be asserted headlessly across terminal boundaries (80x24, 120x40, 60x20) without format-string mismatches (`bad argument to 'format'`).
2. **Keystroke Simulation Testing**:
   Inject simulated key token streams (including symbolic tokens `"SPACE"`, `"BACKSPACE"`, `"ENTER"`, `"ESC"`) into the search loop and category switcher to guarantee 0-drop keystroke handling.
3. **Subprocess & Screen Buffer Discipline**:
   Ensure the diagnostic command runner executes via `suspend_raw_mode()` without switching to the primary buffer, flushes `tcflush()`, and restores cleanly.
4. **Headless Pipeline Sanity Checks**:
   - `printf "z\x1b" | luajit luatop.lua` (Zoom mode entry & clean exit).
   - `printf "/test space\n\x1b" | luajit luatop.lua` (Spacebar in search query).
   - `printf ":\x1b" | luajit luatop.lua` (Diagnostic modal entry & clean exit).

---

## 6. Implementation Phasing Recommendation

- **Phase 1 (Immediate Polish & Bug Fixes)**:
  - Proposal 4: Process Category Tabs (`[All]`, `[User]`, `[System]`, `[Active]`, `[Zombies]`) + Process State Badges (`● R`, `○ S`, `■ D`, `▲ Z`).
  - Search mode `"SPACE"` token normalization fix.
  - Fix test assertion in `test_luatop.lua` line 225.
- **Phase 2 (Ergonomics & Deep Diagnostics)**:
  - Proposal 1: Interactive Pane Focus (`Tab`, `1`-`4`) & Fullscreen Zoom (`z` / `f`).
  - Proposal 3: Process Diagnostic Command Runner Modal (`:`, `!`) with `%p` macro expansion.
- **Phase 3 (Visual Data Density)**:
  - Proposal 2: Multi-Row Braille Historical Graphs (`g`).
