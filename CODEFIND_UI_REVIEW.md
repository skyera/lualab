# CodeFind TUI — Comprehensive UI & UX Review

This document provides a detailed review of the Terminal User Interface (TUI) in [`codefind.lua`](file:///home/zliu/test/lualab/codefind.lua), evaluating rendering performance, layout geometry, input ergonomics, visual hierarchy, and cross-platform terminal behavior.

---

## 1. Executive Summary

`codefind.lua` features a high-performance, two-pane terminal interface with live side-by-side preview, built using pure LuaJIT FFI and ANSI escape sequences with zero external library dependencies. It adheres closely to flicker-free rendering standards by leveraging synchronized terminal updates (`\27[?2026h` ... `\27[?2026l`) and avoids full-screen clears during interaction.

While the architectural foundation is exceptionally solid, several key UX friction points, layout edge cases, and search workflow discrepancies exist. Addressing these will elevate `codefind.lua` to the polish and responsiveness of premier CLI utilities like `fzf`, `telescope.nvim`, and `ripgrep`.

---

## 2. Key Architectural Strengths

1. **Flicker-Free Synchronized Refresh**:
   - Frames are buffered in memory and emitted atomically using synchronized update escapes (`\27[?2026h` ... `\27[?2026l`).
   - Screen clearing (`\27[2J`) is strictly restricted to initial startup, window resize events, and returning from external child processes (e.g., `$EDITOR`).
2. **0ms Instant Query Echo**:
   - Keystrokes in the search box are immediately echoed to row 2 without waiting for heavy disk I/O.
3. **Windowed Streaming Preview**:
   - Previewing massive files (10,000 to 150,000+ lines) is instantaneous with zero memory bloat thanks to the sliding LRU line cache in `make_preview_reader`.
4. **Dedicated Fullscreen Help Modal**:
   - `F1` and `?` invoke an uncluttered, responsive Help View that documents all keyboard shortcuts and FTS5 search patterns, dismissible by any key.
5. **Vim-Style Navigation**:
   - Supports `j`/`k`, `g`/`G`, `Ctrl-U`/`Ctrl-D`, and `n`/`N` for match navigation in preview mode.
6. **Direct Editor Integration**:
   - Pressing `Enter` opens the active file in `$EDITOR` (or `nvim`/`vim`) directly positioned at the current match line (`+<line>`).
7. **Cross-Platform Clipboard**:
   - Pressing `y` copies the exact `filepath:line` to the system clipboard across Linux (`xclip`/`wl-copy`), macOS (`pbcopy`), and Windows (`clip`).

---

## 3. UI Issues & Improvement Areas

### Priority 1: High Impact (Usability & Layout Correctness)

#### 1.1 Search Execution Ergonomics & Enter Key Clarity
* **Observation**:
  - In `focus_pane == "search"`, typing characters updates the query string and echoes to row 2, but the search itself requires pressing `Enter` to run.
  - The footer keybinding pill displays `[Enter] Open`.
* **UX Friction**:
  - Users familiar with modern fuzzy finders (`fzf`, `telescope`, `skim`) expect live search results as they type.
  - A footer pill saying `[Enter] Open` misleads users into expecting the file to open on `Enter`. Instead, the first press searches, and only a subsequent press opens the editor.
* **Recommendations**:
  - If retaining manual search on `Enter`: dynamically label the pill as `[Enter] Search` when the query has been modified, switching to `[Enter] Open` only when the displayed results match the current query text.
  - If providing live search: use an active input guard (`has_pending_input()`) combined with adaptive debounce (e.g. 250ms for 1-char queries to avoid heavy FTS5 wildcard scans, 100ms for 2+ characters) so typing is never blocked.

---

#### 1.2 Line Number Gutter Overflow for Large Files (> 9,999 Lines)
* **Status**: ✅ **Implemented & Verified** (Commit: [`c7d8540`](https://github.com/skyera/lualab/commit/c7d8540))
* **Observation**: In `build_right_cell`:
  ```lua
  local max_code_w = math.max(0, r_text_w - 9)
  right_cell = string.format("  \27[90m%4d │ \27[0m%s%s%s", file_line_num, highlighted, line_pad, right_sb)
  ```
  The line number width was hardcoded to 4 digits (`%4d`, total gutter width = 9 columns).
* **Bug**:
  - In files with $\ge 10,000$ lines (e.g., SQLite amalgamation `sqlite3.c` with ~150,000 lines, generated code, large JSON data), `%4d` expands to 5 or 6 digits (`12345 │ `).
  - This pushed the code snippet to the right, exceeding `r_text_w` and displacing the right border and scrollbar.
* **Resolution**:
  - Implemented dynamic gutter width calculation in `format_preview_gutter(total_lines)`:
    ```lua
    local gutter_digits = math.max(3, #tostring(total_lines or 1))
    local gutter_w = gutter_digits + 5  -- "  " (2) + digits + " │ " (3)
    local max_code_w = math.max(0, r_text_w - gutter_w)
    local gutter_fmt = string.format("  \27[90m%%%dd │ \27[0m", gutter_digits)
    ```
  - For small files ($\le 999$ lines), gutter is compacted to 3 digits (`"    42 │ "`), giving 1 extra character of code width.
  - For large files (10,000 to 1,000,000+ lines), gutter automatically expands cleanly without pushing borders or displacing the scrollbar.
  - Added unit test validation in `test_codefind.lua` Suite 6 covering 1 to 1,000,000 line counts.

---

#### 1.3 Footer Status Notifications Obscure All Keybinding Pills
* **Status**: ✅ **Implemented & Verified** (Commit: [`df0efff`](https://github.com/skyera/lualab/commit/df0efff))
* **Observation**: When `set_status()` was called (e.g., "📄 foo.lua — 3 match(es) [n/N to navigate]" or "✔ Copied to clipboard"), the entire footer row of keybinding pills was replaced for 3.0 seconds.
* **UX Friction**:
  - Navigating files or jumping to matches (`n`/`N`) triggered status updates, causing key shortcuts to constantly vanish right when users needed to reference them.
* **Resolution**:
  - Implemented two-zone split footer in `build_footer_content(status_msg, focus_pane, is_zoomed, total_w)`:
    - Left side displays the transient status message (with ellipsis truncation if long).
    - Right side persistently displays essential keyboard shortcuts (`[Tab] Browse/Search`, `[Enter] Open`, `[F1] Help`, `[^Q] Quit`).
    - Normal state displays comprehensive shortcut bar (`[Tab] Browse │ [F1] Help │ [Enter] Open │ [Esc] Clear │ [@ext] Filter`).
  - Integrated file match counts directly into preview pane header (`📄 foo.lua:42 [Match 1/3] [Line 42/98]`) so normal cursor traversal does not trigger intrusive status messages.
  - Fully tested across multiple terminal widths in `test_codefind.lua` Suite 6.

---

### Priority 2: Medium Impact (Visual Polish & Ergonomics)

#### 2.1 Narrow Terminal Behavior (< 80 Columns)
* **Status**: ✅ **Implemented & Verified** (Commit: [`dd1206b`](https://github.com/skyera/lualab/commit/dd1206b))
* **Observation**:
  - Layout sets `cur_cols = math.max(60, raw_cols - 1)`.
  - When the terminal is 60–75 columns wide, `left_col_w` was ~34 columns and `right_col_w` was ~24–38 columns.
  - After subtracting borders, line numbers, file badges, and indicators, the file path had only ~14 characters and the preview had ~12 characters of code.
* **Resolution**:
  - Automatically switches to a full-width single pane (`content_w = cur_cols - 2`) when `cur_cols < 75`.
  - `Tab` seamlessly toggles between full-width file list and full-width code preview with zero flicker.
  - Added manual full-width pane zoom on any terminal size via `F2` (any mode) or `z` / `Z` (normal mode).
  - Single-pane borders omit middle dividers (`┌───┐`, `├───┤`, `└───┘`) with cyan/green active border indicators.
  - Footer dynamically labels `[Tab] Preview` vs `[Tab] Search` and provides `[F2] Zoom/Unzoom` and `[z] Zoom/Unzoom` pills.

---

#### 2.2 Extended Syntax Highlighting Language Coverage
* **Observation**:
  - `SYNTAX_KEYWORDS` and `highlight_code_line` support keywords and comments for C/C++, Lua, Python, and JavaScript/TypeScript.
  - File badges exist in `FILE_BADGES` for Go (`.go`), Rust (`.rs`), Shell (`.sh`), JSON/YAML (`.json`/`.yaml`), and Markdown (`.md`), but their keywords are unhighlighted in preview.
* **Recommendation**:
  - Add keyword sets and comment syntax for:
    - **Rust**: `fn`, `mut`, `impl`, `trait`, `pub`, `struct`, `enum`, `match`, `let`
    - **Go**: `func`, `package`, `import`, `type`, `struct`, `chan`, `go`, `select`
    - **Shell**: `if`, `then`, `fi`, `elif`, `else`, `for`, `in`, `do`, `done`, `case`, `esac`
    - **JSON/YAML**: property keys (`"key":`), YAML list dashes (`- `)

---

#### 2.3 Empty Search State & Guidance
* **Status**: ✅ **Implemented & Verified** (Commit: [`f1b605a`](https://github.com/skyera/lualab/commit/f1b605a))
* **Observation**:
  - When a query yielded 0 results, the preview pane showed `(No file selected)` with blank lines, and the left pane displayed a static `No matches found`.
  - On program startup with no initial query, the user saw an empty left list and empty preview pane with minimal guidance.
* **Resolution**:
  - Implemented `get_empty_state_left_lines(query, text_w)`:
    - **Initial State** (empty search box): displays CodeFind header, quick syntax cheat sheet (`term*`, `a AND b`, `"exact match"`, `files:*.lua`, `@lua`), and shortcut hints.
    - **No Matches Found** (`#results == 0`): displays warning `⚠ No matches found for '<query>'` and actionable suggestions (Wildcard search, Boolean OR, Exact phrase, Filename search, Extension filter).
    - Width-adaptive formatting cleanly compacts descriptions for narrow terminal columns ($< 36$).
  - Implemented `get_empty_state_right_lines(query, avail_w)`:
    - Transforms previously blank preview pane into a syntax-highlighted **CodeFind & FTS5 Search Reference** and **Keyboard Controls** cheat sheet.
    - Right header dynamically updates to `📄 Quick Reference & Shortcuts` (initial) or `📄 Syntax & Search Guidance` (0 matches).
  - Updated status notification on empty search to `No matches for '<query>' — see search tips`.
  - Added comprehensive test coverage in `test_codefind.lua` Suite 6 verifying text contents and strict visual width safety across widths 20 to 80 cols.

---

#### 2.4 Cursor Navigation Within Search Query
* **Status**: ✅ **Implemented & Verified** (Commit: [`d099a43`](https://github.com/skyera/lualab/commit/d099a43))
* **Observation**:
  - The terminal cursor was hidden, and `query` was displayed with a static trailing cursor bar (`> query|`).
  - Pressing `Left` or `Right` arrow did not move an insertion cursor within the query string.
  - Backspace always deleted from the end of the query string regardless of desired edit location.
* **Resolution**:
  - Implemented dynamic `cursor_pos` tracking (`1 <= cursor_pos <= #query + 1`) in `TUI.run`.
  - Added horizontal prompt sliding window `format_query_prompt(query, cursor_pos, avail_w, is_focused)` with visual indicators (`<` and `>`) when queries exceed prompt width, guaranteeing visual length never overflows or wraps.
  - Supported cursor navigation:
    - `Left` / `Ctrl-B`: Move insertion cursor backward 1 character.
    - `Right` / `Ctrl-F`: Move insertion cursor forward 1 character.
    - `Home` / `Ctrl-A`: Jump to start of query (`cursor_pos = 1`).
    - `End` / `Ctrl-E`: Jump to end of query (`cursor_pos = #query + 1`).
  - Supported in-line editing:
    - Character insertion at `cursor_pos` for single keystrokes and fast key queues.
    - `Backspace`: Delete character before cursor (`cursor_pos - 1`).
    - `Delete` / `Ctrl-D`: Delete character under cursor (`cursor_pos`).
    - `Ctrl-W`: Delete backward word before cursor.
    - `Ctrl-U`: Clear entire query and reset `cursor_pos = 1`.
  - Added ANSI-highlighted cursor bar (`\27[1;36m|\27[0m`) when search box is focused, cleanly hidden when preview pane is focused.
  - Added Windows console (`crt._getch()`), Windows VT, and POSIX VT keycode decoders for `DELETE`, `CTRL_B`, and `CTRL_F`.
  - Integrated into instant 0ms visual echo prompt renderer and Help View modal (`F1` / `?`).

---

## 4. UI Layout Mockups

### Dual-Pane Layout (Normal Mode)
Features dynamic gutter width, in-line query cursor, and split footer status preservation:
```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│ > data|base             [12 Matches]│ 📄 src/db.lua:42 [Match 1/3] [Line 42]│
├──────────────────────────────────────┼──────────────────────────────────────┤
│ ▶  1. [lua] src/main.lua        450L │    40 │ local function init()        │
│    2. [lua] src/db.lua         1.2kL │    41 │     local db = open()        │
│    3. [lua] src/search.lua      890L │ >  42 │     db:search(query)         │
│    4. [c]   src/sqlite.c      150.2kL│ 15243 │     return db;               │
├──────────────────────────────────────┴──────────────────────────────────────┤
│ ✔ Copied to clipboard     │ [Tab] Browse  [Enter] Open  [F1] Help  [^Q] Quit│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Responsive Single-Pane Layout (< 75 Columns or `F2` / `z` Zoom)
Automatically maximizes screen real estate without border overflow:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│ > data|base                                                    [12 Matches] │
├─────────────────────────────────────────────────────────────────────────────┤
│ ▶  1. [lua] src/main.lua                                              450L  │
│    2. [lua] src/db.lua                                               1.2kL  │
│    3. [lua] src/search.lua                                            890L  │
│    4. [c]   src/sqlite.c                                            150.2kL │
├─────────────────────────────────────────────────────────────────────────────┤
│ [Tab] Preview │ [F1] Help │ [F2] Unzoom │ [Enter] Open │ [^Q] Quit          │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Horizontal Prompt Sliding Window (Long Queries)
```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│ > <unction search_record|(filters)>  │ 📄 src/db.lua:42          [Line 42/98│
└──────────────────────────────────────┴──────────────────────────────────────┘
```

---

## 5. Implementation Roadmap & Status Tracker

| Issue | Description | Status | Commit | Complexity | Impact |
|:---|:---|:---:|:---:|:---:|:---:|
| **1.1** | Dynamic Enter key pill (`Search` vs `Open`) / Adaptive live search | ⏳ Pending | — | Low | ⭐⭐⭐ |
| **1.2** | Dynamic line number gutter width (files $\ge 10,000$ lines) | ✅ Implemented | [`c7d8540`](https://github.com/skyera/lualab/commit/c7d8540) | Low | ⭐⭐⭐ |
| **1.3** | Split footer status bar (keep shortcut pills visible during alerts) | ✅ Implemented | [`df0efff`](https://github.com/skyera/lualab/commit/df0efff) | Low | ⭐⭐⭐ |
| **2.1** | Responsive single-pane mode (< 75 cols) & full-width zoom (`F2`/`z`) | ✅ Implemented | [`dd1206b`](https://github.com/skyera/lualab/commit/dd1206b) | Medium | ⭐⭐ |
| **2.2** | Rust, Go, Shell, JSON/YAML preview syntax highlighting | ⏳ Pending | — | Medium | ⭐⭐ |
| **2.3** | Empty state contextual search tips and syntax guidance | ✅ Implemented | [`f1b605a`](https://github.com/skyera/lualab/commit/f1b605a) | Medium | ⭐⭐ |
| **2.4** | In-line cursor navigation (`←`/`→`/`Home`/`End`) & sliding window | ✅ Implemented | [`d099a43`](https://github.com/skyera/lualab/commit/d099a43) | Medium | ⭐⭐ |
