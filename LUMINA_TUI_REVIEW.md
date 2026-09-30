# Lumina TUI — Comprehensive Architecture & UX Review

This document provides a detailed architectural, performance, and user experience review of [`lumina.lua`](file:///home/zliu/test/lualab/lumina.lua), evaluating Miller-columns rendering, TUI performance standards, terminal state management, preview responsiveness, input ergonomics, and modal dialogs.

---

## 1. Executive Summary

[`lumina.lua`](file:///home/zliu/test/lualab/lumina.lua) is a modern, high-performance terminal file manager inspired by Ranger and Yazi, written in pure LuaJIT with FFI. It provides zero-fork directory inspection via POSIX/Win32 native C bindings, half-block graphics preview via ImageMagick/ffmpeg, syntax highlighting, multi-selection tagging, clipboard operations, bookmarks, directory sorting modes, and an interactive fuzzy file finder.

While the core functionality and feature set are exceptionally rich, several discrepancies exist when assessed against the repository's **TUI Performance & Refresh Standards** defined in [AGENTS.md](file:///home/zliu/test/lualab/AGENTS.md). In particular, frequent emission of full-screen clears (`\27[2J`), absence of atomic synchronized frame emission (`\27[?2026h` ... `\27[?2026l`), lack of differential row updates on local cursor movement, and unhandled `Ctrl+C` terminal restoration represent key opportunities for optimization.

Addressing these issues will elevate `lumina.lua` to the smoothness, visual stability, and responsiveness expected of premier terminal tools like `yazi`, `lf`, and `broot`.

---

## 2. Key Architectural Strengths

1. **Native POSIX & Win32 FFI Engine**:
   - Zero-fork directory reading via `opendir`, `readdir`, `closedir`, and `stat` on Linux/macOS and `FindFirstFileA`/`FindNextFileA` on Windows.
   - Non-blocking keyboard polling via `poll()` on POSIX and `_kbhit()`/`_getch()` on Windows, yielding sub-millisecond input responsiveness without busy loops.
2. **Miller-Columns 3-Pane Layout**:
   - Clear spatial hierarchy: Column 1 (Parent context, 22%), Column 2 (Current folder & active cursor, 32%), Column 3 (Rich preview pane, 46%).
3. **Multi-Format Preview Pipeline**:
   - Truecolor 24-bit half-block graphics rendering (`▄`) for images (`.png`, `.jpg`, `.webp`, `.ppm`).
   - Keyword and string syntax-highlighted code preview with line numbers for source files.
   - Directory contents peek with file sizes and counts.
   - Hex dump view for binary files.
   - LRU preview caching (`PREVIEW_CACHE_LIMIT = 64`) avoiding redundant disk reads.
4. **Vim-Inspired Navigation & Key Ergonomics**:
   - Standard directional navigation (`h`/`j`/`k`/`l`, `Enter`, arrows).
   - Jumping shortcuts: `gg`/`G` for list bounds, `H`/`gh` for startup directory, `~` for `$HOME`, and `'<key>` for directory bookmarks.
   - In-directory instant filter (`/`) and global recursive search (`f`, `Ctrl+P`) with engine fallback (`fd` -> `find` -> native Lua).
5. **Comprehensive Multi-Selection & File Operations**:
   - Multi-file tagging via `Space` / `v` and batch invert `V`.
   - Full clipboard workflow: Copy (`y`), Cut (`d`/`x`), Paste (`p`), Create (`a`), Rename (`R`), and Delete (`D`) with modal confirmation.
6. **Dynamic Theming Engine**:
   - 6 built-in themes (Tokyo Night, Dracula, Nord, Monokai, Cyberpunk, Gruvbox) cycleable in-process (`t`/`T`).

---

## 3. Findings & Improvement Areas

### Priority 1: High Impact (TUI Standards Compliance & Visual Stability)

#### 1.1 Elimination of Screen Flashing (`\27[2J` Emission on User Actions)
* **Status**: ❌ **Standard Violation**
* **Observation**:
  [`lumina.lua`](file:///home/zliu/test/lualab/lumina.lua) invokes `io.write("\27[H\27[2J")` across numerous interactive user actions:
  - Entering a directory via `l`, `Enter`, or `RIGHT` ([line 2465](file:///home/zliu/test/lualab/lumina.lua#L2465)).
  - Leaving a directory via `h`, `LEFT`, or `Backspace` ([line 2441](file:///home/zliu/test/lualab/lumina.lua#L2441)).
  - Jumping via `H`, `gh` ([line 2406](file:///home/zliu/test/lualab/lumina.lua#L2406), [line 2417](file:///home/zliu/test/lualab/lumina.lua#L2417)) or `~` ([line 2429](file:///home/zliu/test/lualab/lumina.lua#L2429)).
  - Redundant directory change check ([line 2650](file:///home/zliu/test/lualab/lumina.lua#L2650)).
  - Dismissing dialogs on `Esc` or `Enter`: [`show_fuzzy_finder`](file:///home/zliu/test/lualab/lumina.lua#L1558), [`show_input_modal`](file:///home/zliu/test/lualab/lumina.lua#L1649), [`show_confirm_modal`](file:///home/zliu/test/lualab/lumina.lua#L1704), [`show_help_modal`](file:///home/zliu/test/lualab/lumina.lua#L1792), and [`show_image_fullscreen`](file:///home/zliu/test/lualab/lumina.lua#L1424).
* **Standard Violation**:
  [AGENTS.md](file:///home/zliu/test/lualab/AGENTS.md#L43-L46) explicitly mandates:
  > *"`\27[2J` (clear screen) MUST NEVER be emitted in response to any user-driven action — this includes key presses (Space, Enter, arrow keys, hotkeys), cursor navigation, list traversal, typing, stepping through algorithms, toggling modes, confirming prompts, or any other interactive input. The screen must remain visually stable at all times during normal interaction.*
  > *Full Clear is Reserved for Exceptional Events Only: `\27[2J` may ONLY be used for: (a) initial screen setup on program start, (b) terminal window resize events, (c) returning from an external sub-process (e.g., `$EDITOR`), or (d) a full data reset (e.g., restart/reload). In all other cases, use cursor-addressed row overwrites instead."*
* **Remediation**:
  - Remove all intermediate `io.write("\27[H\27[2J")` calls in directory navigation and modal closures.
  - When returning from a modal or moving between directories, reposition cursor to home (`\27[H`) and overwrite rows cleanly with trailing line-clear (`\27[K`).

---

#### 1.2 Atomic Synchronized Updates (`\27[?2026h` ... `\27[?2026l`) & Auto-Wrap Shift
* **Status**: ❌ **Standard Violation**
* **Observation**:
  - The main rendering loop ([line 2085](file:///home/zliu/test/lualab/lumina.lua#L2085)) and modal rendering functions emit frame strings directly to stdout without wrapping them in synchronized update escapes.
  - Line autowrap is never disabled: `enable_raw_mode` emits `\27[?1049h\27[?25l` ([line 345](file:///home/zliu/test/lualab/lumina.lua#L345)), omitting `\27[?7l`.
  - Column widths use the entire un-clamped terminal width (`col1_w + col2_w + col3_w = term_w`).
* **Standard Violation**:
  [AGENTS.md](file:///home/zliu/test/lualab/AGENTS.md#L48-L49) mandates:
  > *"`\27[?2026h` ... `\27[?2026l` atomic synchronized frame emission flushed in a single `io.write()`.*
  > *Disable line wrapping (`\27[?7l`) on startup and clamp layout width to `raw_cols - 1` to prevent wide strings from pushing the cursor to the next line and breaking coordinate-based row addressing (`\27[Y;XH`)."*
* **Remediation**:
  - Update [`enable_raw_mode`](file:///home/zliu/test/lualab/lumina.lua#L336) to emit `\27[?1049h\27[?25l\27[?7l` and [`disable_raw_mode`](file:///home/zliu/test/lualab/lumina.lua#L350) to emit `\27[?7h\27[?1049l\27[?25h\27[0m`.
  - Clamp column widths to `term_w - 1` to prevent right-edge terminal wrapping.
  - Wrap full frames and modals in `\27[?2026h` ... `\27[?2026l`.

---

#### 1.3 Differential Refresh on Local Cursor Movement
* **Status**: ❌ **Optimization Required**
* **Observation**:
  - Moving the cursor via `j`, `k`, `Space`, or `v` sets `needs_redraw = true` ([line 2242](file:///home/zliu/test/lualab/lumina.lua#L2242)).
  - This executes the full 150-line screen rendering pipeline, re-generating parent directory rows (Column 1), middle directory rows (Column 2), all pane box borders, and the header bar.
* **Standard Requirement**:
  [AGENTS.md](file:///home/zliu/test/lualab/AGENTS.md#L47) requires:
  > *"When moving between items within the visible viewport page, update **only the changed rows** (e.g., un-highlight the previous row, highlight the new row) instead of rebuilding and redrawing the entire screen."*
* **Remediation**:
  - Implement `render_selection_differential(old_sel, new_sel)`:
    * When `page_offset` does not change: overwrite row `old_sel` in Column 2 (plain item styling), overwrite row `new_sel` in Column 2 (highlighted cursor styling), update Column 3 (Preview pane), and update the status line.
    * Leave Column 1 (Parent folder), all box borders, and the top header completely untouched.
    * If `page_offset` changes (scrolling past the visible boundary), fall back to `render_full_screen(false)`.

---

#### 1.4 Signal Handling & Terminal Raw Mode Restoration
* **Status**: ⚠️ **Reliability Risk**
* **Observation**:
  - In POSIX [`enable_raw_mode`](file:///home/zliu/test/lualab/lumina.lua#L340):
    `raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))`
  - `ISIG` (0x0001) is not cleared, and no signal handlers are installed for `SIGINT` or `SIGTERM`.
  - If a user presses `Ctrl+C`, the process immediately receives `SIGINT` and exits abruptly, leaving the user's terminal stuck in raw mode, cursor hidden, and trapped in the alternate screen buffer.
* **Standard Requirement**:
  [AGENTS.md](file:///home/zliu/test/lualab/AGENTS.md#L55) requires:
  > *"Always register signal traps (`SIGINT`, `SIGTERM`, `EXIT`) and protected exit paths to guarantee alternate buffer exit (`\27[?1049l`), cursor restore (`\27[?25h`), and terminal raw mode reset."*
* **Remediation**:
  - In `enable_raw_mode`, disable `ISIG` and `IEXTEN` so that `Ctrl+C` arrives as character byte `\3`.
  - Handle `k == "\3"` in the main input loop as a clean exit signal that invokes `disable_raw_mode()` gracefully.
  - Add an emergency protected restore in `xpcall` error handler.

---

### Priority 2: Medium Impact (Performance & Responsiveness)

#### 2.1 Preview Debounce & Loading Flashes on Fast Traversal
* **Observation**:
  - Moving the cursor sets `preview_pending = true` ([line 2654](file:///home/zliu/test/lualab/lumina.lua#L2654)).
  - During `needs_redraw`, if `preview_pending` is true, it renders placeholder text:
    `"Loading preview... Pause briefly to render the selected item."` ([lines 2171-2174](file:///home/zliu/test/lualab/lumina.lua#L2171-L2174)).
  - It then waits 150ms in `read_key(150)` before triggering another frame to actually load the preview.
* **UX Friction**:
  - For files already cached in `preview_cache`, directories, or small text files (<64KB) that load in under 0.5ms, this causes the preview pane to flash blank/loading on every single keystroke.
* **Remediation**:
  - Check the preview cache immediately: if the target is already cached in `preview_cache`, or is a directory, or is a small file (<64KB), generate and render the preview immediately without setting `preview_pending = true`.
  - Reserve debouncing exclusively for heavy media files (images processed via external `convert`/`ffmpeg` or files >1MB).

---

#### 2.2 Modal Navigation & Usability in Fuzzy Finder & Help Overlay
* **Observation**:
  - In [`show_fuzzy_finder`](file:///home/zliu/test/lualab/lumina.lua#L1441), keyboard navigation only supports `UP`, `DOWN`, `BACKSPACE`, `TAB`, `ENTER`, and `ESC`. Keys such as `PAGE_UP`, `PAGE_DOWN`, `Ctrl+D` (`\4`), and `Ctrl+U` (`\21`) are ignored.
  - In [`show_help_modal`](file:///home/zliu/test/lualab/lumina.lua#L1715), on compact terminal displays, help items exceeding `term_h - 4` cannot be scrolled.
* **Remediation**:
  - Add `PAGE_UP`, `PAGE_DOWN`, `\4` (Ctrl+D), and `\21` (Ctrl+U) handling to `show_fuzzy_finder`, advancing selection by `visible_rows` or half-page increments.
  - Add scroll capability to `show_help_modal` if the terminal height is smaller than the cheatsheet content.

---

#### 2.3 Split Footer & Transient Status Notifications
* **Observation**:
  - When copying (`y`), cutting (`d`/`x`), deleting (`D`), pasting (`p`), or setting a bookmark (`m`), there is no transient visual feedback confirming the operation.
  - The status bar displays either a clipboard badge or file path, but lacks confirmation messages like *"✓ Copied 2 item(s) to clipboard"* or *"✓ Pasted 2 item(s)"*.
* **Remediation**:
  - Implement a transient notification mechanism: `set_status_message(msg)`.
  - Display the message in the footer bar and clear it on the subsequent navigation keystroke.

---

### Priority 3: Low Impact (Defensive Polish & Edge Cases)

#### 3.1 Nested Directory File Creation & Existence Checks
* **Observation**:
  - In file creation (`a` key, [line 2589](file:///home/zliu/test/lualab/lumina.lua#L2589)):
    Typing `sub/nested_file.txt` attempts `io.open(target, "a")`, which fails if the parent directory `sub` does not exist.
  - In rename (`R` key, [line 2612](file:///home/zliu/test/lualab/lumina.lua#L2612)):
    If `new_name` already exists, `move_file_or_dir` will overwrite the destination without warning.
* **Remediation**:
  - When creating a file with path separators, ensure intermediate directories are created first (`mkdir -p`).
  - When renaming, check if `new_path` exists; if so, prompt with `show_confirm_modal("OVERWRITE", "File already exists. Overwrite?")`.

---

## 4. UI & Output Visual Mockups

### Miller Columns Layout with Transient Notifications & Tokyo Night Theme

```
  ⚡ LUMINA │ /home/zliu/test/lualab (68 items)                   🎨 Tokyo Night 
╭ parent ──────────────╮╭ lualab [Name ↑] ─────────────╮╭ preview: lumina.lua ─────────╮
│ 📁 test              ││ 📄 AGENTS.md          4.8 K  ││   1 │ --[[                   │
│ 📁 scratch           ││ 📄 data.txt            30 B  ││   2 │     lumina.lua         │
│                      ││ 📄 deploy.lua         19.0 K ││   3 │     A fast, modern...  │
│                      ││▶📄 lumina.lua        109.8 K ││   4 │     Inspired by ranger │
│                      ││ 📄 Makefile            1.6 K ││   5 │                        │
│                      ││ 📁 portraits           774 B ││   6 │     Architecture:      │
│                      ││ 📄 test_lumina.lua    50.3 K ││   7 │     - POSIX FFI Native │
╰──────────────────────╯╰──────────────────────────────╯╰──────────────────────────────╯
  ✓ Copied 'lumina.lua' to clipboard │ [?] Help  [h/l] Nav  [Space] Tag  [y/d] Copy/Cut  [p] Paste
```

### Modal Fuzzy Finder with Engine Badge & Scroll Pagination

```
                 ╭ FUZZY FILE SEARCH (14/68) [fd] ──────────────────────────╮
                 │   > test_l                                               │
                 ├──────────────────────────────────────────────────────────┤
                 │    📄 test_lumina.lua                            50.3 K  │
                 │    📄 test_luatop.lua                            17.5 K  │
                 │ ▶  📄 test_codefind.lua                          75.1 K  │
                 │    📄 test_ffi_suite.lua                          8.3 K  │
                 │    📄 test_todo_tui.lua                           2.2 K  │
                 ╰──────────────── [PgUp/PgDn] Page  [Enter] Open  [Esc] ───╯
```

---

## 5. Detailed Implementation Plan & Code Comparison

### 5.1 Terminal Setup & Safe Signal Handling
```diff
-- lumina.lua L336-L358 (POSIX Raw Mode Setup)
@@ -336,15 +336,19 @@
     enable_raw_mode = function()
         if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
         ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
         ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
-        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
+        -- Disable ICANON, ECHO, ISIG, and IEXTEN so Ctrl-C arrives as byte 3 (\3)
+        local ICANON, ECHO, ISIG, IEXTEN = 0x0002, 0x0008, 0x0001, 0x8000
+        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG, IEXTEN)))
         ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
         in_raw_mode = true

-        -- Switch to alternate screen buffer, hide cursor
-        io.write("\27[?1049h\27[?25l")
+        -- Switch to alternate screen buffer, hide cursor, disable auto-wrap
+        io.write("\27[?1049h\27[?25l\27[?7l")
         io.flush()
         return true
     end

     disable_raw_mode = function()
         if in_raw_mode then
-            io.write("\27[?1049l\27[?25h\27[0m")
+            -- Re-enable auto-wrap, restore cursor, exit alternate buffer
+            io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
             io.flush()
             ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
             in_raw_mode = false
         end
     end
```

### 5.2 Elimination of Screen Clear (`\27[2J`) in Navigation & Modals
```diff
-- lumina.lua L2435-L2455 (Parent Directory Navigation)
@@ -2435,9 +2435,7 @@
                 if not is_root_dir(current_dir) then
                     local prev_dir = current_dir
                     current_dir = get_parent_dir(current_dir)
                     filter_query = ""
                     clear_preview_cache()
                     preview_pending = false
-                    io.write("\27[H\27[2J")
-                    io.flush()
                     current_entries = read_dir_entries(current_dir, show_hidden)
                     parent_dir = get_parent_dir(current_dir)
@@ -2458,9 +2456,7 @@
                 local sel = current_entries[sel_index]
                 if sel and sel.is_dir then
                     current_dir = sel.path
                     filter_query = ""
                     sel_index = 1
                     clear_preview_cache()
                     preview_pending = false
-                    io.write("\27[H\27[2J")
-                    io.flush()
                     reload_current()
```

### 5.3 Differential Selection Updates on Local Cursor Steps
```lua
-- Forward declaration at top of main()
local render_full_screen, render_selection_differential

render_selection_differential = function(old_sel, new_sel)
    local usable_h = math.max(10, term_h - 3)
    local visible_rows = usable_h - 2
    local cur_page_offset = (sel_index > visible_rows) and (sel_index - visible_rows + 1) or 1

    -- If viewport scrolled across page boundary, fall back to atomic full screen refresh without \27[2J
    if cur_page_offset ~= prev_page_offset then
        render_full_screen(false)
        return
    end

    local out = { "\27[?2026h" }

    -- 1. Un-highlight previous row in Column 2
    local old_row_idx = old_sel - cur_page_offset + 1
    if old_row_idx >= 1 and old_row_idx <= visible_rows then
        local old_entry = current_entries[old_sel]
        if old_entry then
            local icon, col = get_file_type_info(old_entry)
            local is_tagged = selected_paths[old_entry.path]
            local tag_badge = is_tagged and "\27[1;32m[✓]\27[0m " or ""
            local line_content = string.format(" %s%s %-18s %s", tag_badge, icon, old_entry.name, old_entry.size_str)
            table.insert(out, draw_row(col2_x, start_y + old_row_idx, col2_w, col .. " " .. line_content .. C.reset))
        end
    end

    -- 2. Highlight new row in Column 2
    local new_row_idx = new_sel - cur_page_offset + 1
    if new_row_idx >= 1 and new_row_idx <= visible_rows then
        local new_entry = current_entries[new_sel]
        if new_entry then
            local icon, col = get_file_type_info(new_entry)
            local is_tagged = selected_paths[new_entry.path]
            local tag_badge = is_tagged and "\27[1;32m[✓]\27[0m " or ""
            local line_content = string.format(" %s%s %-18s %s", tag_badge, icon, new_entry.name, new_entry.size_str)
            table.insert(out, draw_row(col2_x, start_y + new_row_idx, col2_w, C.cursor_bg .. "▶" .. line_content .. C.reset))
        end
    end

    -- 3. Render Column 3 (Preview) & Status bar
    render_preview_pane(out)
    render_footer_bar(out)

    table.insert(out, "\27[?2026l")
    io.write(table.concat(out))
    io.flush()
    prev_sel_index = new_sel
end
```

---

## 6. Verification & Validation Strategy

1. **Automated Regression Suite (`test_lumina.lua`)**:
   - Run `luajit test_lumina.lua` to ensure all existing 440 test assertions pass without regression.
   - Add new test cases:
     * **Suite 22: TUI Performance & Escape Sequences**: Verify presence of `\27[?2026h`, `\27[?2026l`, `\27[?7l`, and absence of `\27[2J` in navigation paths.
     * **Suite 23: Modal Scroll Keybindings**: Test `PAGE_UP`, `PAGE_DOWN`, `\4`, `\21` state transitions in modal search.
     * **Suite 24: Signal Masking**: Verify `ISIG` and `IEXTEN` masking in termios flags.
2. **Terminal Invariant Verification**:
   - Layout bounds invariant: `col1_w + col2_w + col3_w <= term_w - 1`.
   - Cursor address invariant: all `draw_row` coordinates are bounded by `[1, term_h]` and `[1, term_w - 1]`.
3. **Headless Execution Check**:
   - Run headless invocation: `luajit lumina.lua --theme=tokyo_night` in test harnesses to ensure clean non-interactive fallback.

---

## 7. Recommendations & Next Steps

1. **Implement TUI Performance Enhancements**: Apply synchronized updates, auto-wrap prevention, and eliminate screen-clearing escapes.
2. **Integrate Fast Differential Refresh**: Update local cursor movements (`j`, `k`, `Space`, `v`) to refresh only modified rows.
3. **Enhance Modals & Feedback**: Support page scrolling in fuzzy search and add transient status notifications for file operations.
4. **Update Test Coverage**: Expand [`test_lumina.lua`](file:///home/zliu/test/lualab/test_lumina.lua) to continuously guarantee flicker-free invariants.
