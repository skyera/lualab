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
* **Observation**: In `build_right_cell`:
  ```lua
  local max_code_w = math.max(0, r_text_w - 9)
  right_cell = string.format("  \27[90m%4d │ \27[0m%s%s%s", file_line_num, highlighted, line_pad, right_sb)
  ```
  The line number width is hardcoded to 4 digits (`%4d`, total gutter width = 9 columns).
* **Bug**:
  - In files with $\ge 10,000$ lines (e.g., SQLite amalgamation `sqlite3.c` with ~150,000 lines, generated code, large JSON data), `%4d` expands to 5 or 6 digits (`12345 │ `).
  - This pushes the code snippet to the right, exceeding `r_text_w` and displacing the right border and scrollbar.
* **Fix**:
  Dynamically compute gutter width based on `current_preview_total_lines`:
  ```lua
  local gutter_digits = math.max(3, #tostring(current_preview_total_lines))
  local gutter_w = gutter_digits + 5  -- "  " (2) + digits + " │ " (3)
  local max_code_w = math.max(0, r_text_w - gutter_w)
  local gutter_fmt = string.format("  \27[90m%%%dd │ \27[0m", gutter_digits)
  ```

---

#### 1.3 Footer Status Notifications Obscure All Keybinding Pills
* **Observation**: When `set_status()` is called (e.g., "📄 foo.lua — 3 match(es) [n/N to navigate]" or "✔ Copied to clipboard"), the entire footer row of keybinding pills is replaced for 3.0 seconds.
* **UX Friction**:
  - Navigating files or jumping to matches (`n`/`N`) triggers status updates, which causes the key shortcuts to constantly vanish right when a user needs to reference them.
* **Fix**:
  - Keep status messages and keybindings distinct:
    - Display file-match counts in the Preview Pane Header (where match count and line numbers already reside: `[Match 1/3] [Line 42/500]`).
    - Or render a split footer: transient message on the left, essential shortcut pills (`[F1] Help`, `[Tab] Switch`, `[^Q] Quit`) preserved on the right.

---

### Priority 2: Medium Impact (Visual Polish & Ergonomics)

#### 2.1 Narrow Terminal Behavior (< 80 Columns)
* **Observation**:
  - Layout sets `cur_cols = math.max(60, raw_cols - 1)`.
  - When the terminal is 60–75 columns wide, `left_col_w` is ~34 columns and `right_col_w` is ~24–38 columns.
  - After subtracting borders, line numbers, file badges, and indicators, the file path has only ~14 characters and the preview has ~12 characters of code.
* **Recommendation**:
  - Implement a responsive layout: when `cur_cols < 75`, switch to a single full-width pane with `Tab` toggling between List and Preview, or allow a manual pane zoom toggle (`Z` / `F2`).

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
* **Observation**:
  - When a query yields 0 results, the preview pane shows `(No file selected)` with blank lines, and the left pane displays a static `No matches found`.
* **Recommendation**:
  - Display contextual search tips on empty results:
    ```text
      No matches found for 'query'
      Try:
        • Wildcard search : term*
        • Boolean OR      : term1 OR term2
        • Exact phrase    : "exact phrase"
        • Filename search : files:pattern
        • Filter by ext   : @lua or @c
    ```

---

#### 2.4 Cursor Navigation Within Search Query
* **Observation**:
  - The terminal cursor is hidden, and `query` is displayed with a static trailing cursor bar (`> query|`).
  - Pressing `Left` or `Right` arrow does not move an insertion cursor within the query string.
* **Recommendation**:
  - Track `cursor_pos` within `query` to allow in-line `Left`/`Right` arrow movement, `Home`/`End`, and character insertion/deletion at arbitrary positions.

---

## 4. UI Layout Mockups

### Current TUI Layout
```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│ > query| (F1: help)      [12 Matches]│ 📄 foo.lua:42 [Match 1/3] [Line 42/98]│
├──────────────────────────────────────┼──────────────────────────────────────┤
│ ▶  1. [lua] src/main.lua        450L │    40 │ local function init()        │
│    2. [lua] src/db.lua         1.2kL │    41 │     local db = open()        │
│    3. [lua] src/search.lua      890L │ >  42 │     db:search(query)         │
│    4. [c]   src/sqlite.c       15.2kL│    43 │     return db                │
├──────────────────────────────────────┴──────────────────────────────────────┤
│ [Tab] Browse │ [F1] Help │ [Enter] Open │ [Esc] Clear │ [@ext] Filter       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Proposed Enhanced TUI Layout
```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│ > query| (F1: help)      [12 Matches]│ 📄 foo.lua:42 [Match 1/3] [Line 42/98]│
├──────────────────────────────────────┼──────────────────────────────────────┤
│ ▶  1. [lua] src/main.lua        450L │    40 │ local function init()        │
│    2. [lua] src/db.lua         1.2kL │    41 │     local db = open()        │
│    3. [lua] src/search.lua      890L │ >  42 │     db:search(query)         │
│    4. [c]   src/sqlite.c       15.2kL│    43 │     return db                │
├──────────────────────────────────────┴──────────────────────────────────────┤
│ 📄 Match 1/3 (line 42)    │ [Tab] Browse  [Enter] Open  [F1] Help  [^Q] Quit│
└─────────────────────────────────────────────────────────────────────────────┘
```
*(Notice: Status notices do not erase essential shortcut pills on the right; gutter width dynamically adapts to line count).*

---

## 5. Implementation Roadmap

| Phase | Improvements | Complexity | Impact |
|:---|:---|:---:|:---:|
| **Phase 1: Layout & Core Alignment** | • Dynamic line number gutter width (files $> 9,999$ lines)<br>• Dynamic Enter key pill (`Search` vs `Open`)<br>• Split status bar (keep shortcut pills visible) | Low | ⭐⭐⭐ |
| **Phase 2: Search Guidance & Ergonomics** | • Empty state contextual help tips<br>• In-line cursor navigation (`Left`/`Right` arrow in query) | Medium | ⭐⭐ |
| **Phase 3: Syntax & Responsive View** | • Rust, Go, Shell, JSON/YAML preview syntax highlighting<br>• Responsive single-pane mode for narrow terminals ($< 75$ cols) | Medium | ⭐⭐ |
