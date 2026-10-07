# yt.lua — YouTube Terminal Viewer & Player: Comprehensive Architecture & TUI Review

This document provides a detailed architectural, performance, security, and user experience review of [`yt.lua`](file:///home/zliu/test/lualab/yt.lua), evaluating terminal rendering stability against the repository's **TUI Performance & Refresh Standards** defined in [`AGENTS.md`](file:///home/zliu/test/lualab/AGENTS.md), streaming pipelines, shell escaping, IPC control loops, input ergonomics, and test suite coverage.

---

## 1. Executive Summary & Resolution Matrix

[`yt.lua`](file:///home/zliu/test/lualab/yt.lua) is a cross-platform YouTube and YouTube Music terminal browser and player written in pure LuaJIT with FFI native C bindings. It provides audio/video streaming via `mpv`, background mini-player control via bidirectional IPC (UNIX domain sockets on POSIX, Named Pipes on Windows), closed caption (CC) rolling deduplication, search filtering, offline downloading, and terminal half-block/GUI window playback.

A systematic audit identified critical bugs, security vulnerabilities, and opportunities for performance and ergonomics enhancement:

### Issue & Resolution Matrix

| ID | Issue / Feature | Severity / Type | Status | File & Line Range | Impact |
|:---|:---|:---|:---|:---|:---|
| **1.1** | Undefined Global `term` Crashes Curl Web Fallback | **Critical / Correctness** | ✅ **Fixed** | [`yt.lua:1215, 1219`](file:///home/zliu/test/lualab/yt.lua#L1215) | Crashes web scraping when yt-dlp fails |
| **1.2** | Search Sort Filters (`--sort views/date/rating`) Shadowed / Dead Code | **High / Correctness** | ✅ **Fixed** | [`yt.lua:1093-1108`](file:///home/zliu/test/lualab/yt.lua#L1093) | Sort options in `[f]` modal have zero effect |
| **1.3** | Shell Metacharacter Injection in Search Spec Commands | **High / Security** | Proposed | [`yt.lua:1093, 1108`](file:///home/zliu/test/lualab/yt.lua#L1093) | `$VAR`, `$(cmd)`, and backticks evaluated by shell |
| **1.4** | Missing Signal Handlers & Terminal Restoration on Interrupt | **High / Stability** | Proposed | [`yt.lua:398-424, 2251`](file:///home/zliu/test/lualab/yt.lua#L398) | Leaves terminal frozen/invisible on `Ctrl+C` |
| **1.5** | Multi-Byte Pasted Input Truncation in POSIX `read_key` | **Medium / Usability** | Proposed | [`yt.lua:432-463`](file:///home/zliu/test/lualab/yt.lua#L432) | Pasting URLs drops up to 15 characters per chunk |
| **1.6** | Search Query Prompt Discards Active Search on Refinement | **Medium / UX Polish** | Proposed | [`yt.lua:2128`](file:///home/zliu/test/lualab/yt.lua#L2128) | Forces user to retype query from scratch on `[/]` |
| **1.7** | Terminal Autowrap Shift & Missing Synchronized Updates | **Medium / TUI Standard** | Proposed | [`yt.lua:411, 2365`](file:///home/zliu/test/lualab/yt.lua#L411) | Layout shift on narrow terminals, tearing during redraws |
| **1.8** | Test Suite `LUA_PATH` Subshell Resolution & Offline Fallback | **Medium / Test Suite** | Proposed | [`test_yt.lua:164-185`](file:///home/zliu/test/lualab/test_yt.lua#L164) | Bytecode global checks fail without module paths |

---

## 2. Key Architectural Strengths

1. **Dual Extraction & Streaming Engine**:
   - Primary high-fidelity JSON metadata extraction via `yt-dlp --dump-json --flat-playlist`.
   - Built-in zero-dependency web scraper (`scrape_youtube_search`) using `curl` to parse YouTube's initial HTML payload when `yt-dlp` is unavailable, blocked by anti-bot verification, or rate-limited.
2. **Rolling Closed Caption (CC) Deduplication Engine**:
   - Sophisticated sliding-window string normalizer (`clean_rolling_caption`) that eliminates repetitive 10ms roll-up transitions and HTML entities (`&quot;`, `&#39;`), delivering smooth lyrics and subtitle display.
3. **Cross-Platform IPC Mini-Player**:
   - Asynchronous non-blocking background audio playback while keeping the TUI responsive.
   - POSIX: Native UNIX domain socket FFI (`AF_UNIX`, `struct sockaddr_un`, `poll`, `write`, `read`).
   - Windows: Win32 Named Pipes FFI (`CreateFileA`, `PeekNamedPipe`, `ReadFile`, `WriteFile`).
4. **Rich Terminal Visuals & Video Player Modes**:
   - Interactive modal overlays: Search (`/`), Filters & Sort (`f`), Up-Next Queue (`Q`), Downloads (`d`), and Cheat Sheet (`?`).
   - Multi-tier video playback: Terminal Truecolor half-block (`--vo=tct`) and external MPV GUI window (`--window`).
   - Optional ANSI/Chafa album artwork and thumbnail rendering.

---

## 3. In-Depth Findings & Root Cause Analysis

### 3.1 Undefined Global `term` Causing Crash in Web Scraping Fallback
- **Status**: ✅ **FIXED** ([`yt.lua`](file:///home/zliu/test/lualab/yt.lua#L1215))
- **Severity**: Critical (Severity 1)
- **Problem**:
  In `fetch_youtube_results(query, mode, ...)`:
  ```lua
  -- yt.lua lines 1212-1224:
  if site == "youtube" and not is_liked and not is_direct_url then
      local fallback_items = scrape_youtube_search(term, max_results, proxy, insecure)
      if fallback_items and #fallback_items > 0 then
          return fallback_items, nil, insecure
      elseif not insecure then
          local fallback_insecure = scrape_youtube_search(term, max_results, proxy, true)
          ...
      end
  end
  ```
  The function argument is `query`. The identifier `term` is an undefined global (`nil`).
- **Failure Mode**:
  When `scrape_youtube_search(query, ...)` receives `nil`, it immediately crashes at line 1025:
  ```
  ./LuaJIT/src/luajit: yt.lua:1025: attempt to index local 'query' (a nil value)
  ```
- **Fix**:
  Pass `query` instead of `term`, and add a safety coercion `query = tostring(query or "")` inside `scrape_youtube_search`.

---

### 3.2 Search Sort Filters (`--sort views/date/rating`) Shadowed
- **Status**: ✅ **FIXED** ([`yt.lua`](file:///home/zliu/test/lualab/yt.lua#L1093))
- **Severity**: High (Severity 2)
- **Problem**:
  In `build_search_spec(query, mode, max_results, is_liked, filters, site)`:
  ```lua
  -- yt.lua lines 1081-1109:
  local SITE_SEARCH_PREFIXES = {
      youtube = "ytsearch",
      soundcloud = "scsearch",
      twitch = "twsearch",
  }
  ...
  elseif SITE_SEARCH_PREFIXES[site] then
      return string.format('"%s%d:%s"', SITE_SEARCH_PREFIXES[site], max_results, query:gsub('"', '\\"'))
  elseif filters and filters.sort and filters.sort ~= "relevance" then
      local sp_map = { views = "CAM%253D", date = "CAI%253D", rating = "CAE%253D" }
      ...
  ```
  Because `site` defaults to `"youtube"`, `SITE_SEARCH_PREFIXES["youtube"]` is always truthy (`"ytsearch"`).
  Therefore, execution enters the `SITE_SEARCH_PREFIXES[site]` branch on every query. The `elseif filters.sort` branch is **unreachable dead code**.
- **Failure Mode**:
  Selecting *View Count (Popular)*, *Upload Date (Latest)*, or *Rating* in the filter modal (`[f]`) or passing `--sort views` produces a standard un-sorted search query.
- **Fix**:
  Evaluate the sort filter branch before falling back to `SITE_SEARCH_PREFIXES[site]`:
  ```lua
  elseif site == "youtube" and filters and filters.sort and filters.sort ~= "relevance" then
      local sp_map = { views = "CAM%253D", date = "CAI%253D", rating = "CAE%253D" }
      ...
  ```

---

### 3.3 Shell Metacharacter Injection in Search Commands
- **Severity**: High (Security)
- **Problem**:
  Search specs in `build_search_spec` only escape double quotes:
  ```lua
  query:gsub('"', '\\"')
  ```
  This is then interpolated into:
  ```lua
  yt-dlp --dump-json ... "ytsearch20:<query>" 2>&1
  ```
  In POSIX shells (`/bin/sh`), expressions inside double quotes still interpret and expand:
  1. `$VAR` and `$(command)` (command substitution).
  2. `` `command` `` (legacy command substitution).
  3. `\` (escape character).
- **Failure Mode**:
  Searching for terms like `"top $100 songs"` causes the shell to evaluate `$100` as an empty variable. Searching with backticks or `$(...)` can execute unintended commands.
- **Fix**:
  Escape `\`, `"`, `$`, and `` ` `` before constructing double-quoted shell arguments:
  ```lua
  local safe_q = query:gsub('["\\$`]', '\\%1')
  ```

---

### 3.4 Missing Signal Handlers & Terminal Restoration on Interrupt
- **Severity**: High (Reliability & Standard Compliance)
- **Problem**:
  When `run_app()` activates raw mode (`enable_raw_mode()`), it puts the terminal into raw non-canonical mode, switches to the alternate screen buffer (`\27[?1049h`), and hides the cursor (`\27[?25l`).
  If the process receives `SIGINT` (Ctrl+C), `SIGTERM`, or `SIGHUP`, `yt.lua` terminates immediately without executing `disable_raw_mode()`.
- **Failure Mode**:
  The user is returned to their terminal with the cursor invisible, keyboard echo disabled, and trapped in the alternate buffer.
- **Fix**:
  1. Define `suspend_raw_mode()` and `resume_raw_mode()` in POSIX and Windows FFI.
  2. Install POSIX signal handlers (`SIGHUP=1`, `SIGINT=2`, `SIGQUIT=3`, `SIGTERM=15`) invoking `disable_raw_mode()` and `os.exit(128 + sig)`.
  3. Emit autowrap disable (`\27[?7l`) on startup and restore (`\27[?7h`) on exit.

---

### 3.5 Multi-Byte Pasted Input Truncation in `read_key`
- **Severity**: Medium (Usability)
- **Problem**:
  In POSIX `read_key`:
  ```lua
  local n = ffi.C.read(STDIN_FILENO, key_buf, 16)
  if n > 0 then
      local c0 = bit.band(key_buf[0], 0xFF)
      ...
      elseif c0 >= 32 and c0 <= 126 then
          return string.char(c0)
      end
  ```
  When the user pastes a URL (e.g. `https://www.youtube.com/watch?v=dQw4w9WgXcQ`), `read()` consumes up to 16 bytes in a single call. However, `read_key` returns only `key_buf[0]` (`'h'`) and discards `key_buf[1..n-1]`.
- **Failure Mode**:
  Pasting a 43-character YouTube URL results in only 3 or 4 characters being recognized, making URL pasting unusable.
- **Fix**:
  Introduce an internal FIFO pending buffer:
  ```lua
  local pending_keys = {}
  read_key = function(timeout_ms)
      if #pending_keys > 0 then
          return table.remove(pending_keys, 1)
      end
      ...
      elseif c0 >= 32 and c0 <= 126 then
          for i = 1, n - 1 do
              table.insert(pending_keys, string.char(key_buf[i]))
          end
          return string.char(c0)
      end
  ```

---

### 3.6 Search Query Modal Discards Active Search on Refinement
- **Severity**: Medium (UX Polish)
- **Problem**:
  Function `prompt_search_query(current_query)` declares:
  ```lua
  local input_str = ""
  ```
  completely ignoring `current_query`.
- **Failure Mode**:
  When a user searches for `"lofi hip hop study beats"` and wants to change one word, pressing `/` clears the entire input box, forcing them to retype everything.
- **Fix**:
  Initialize `local input_str = current_query or ""` and add `CTRL_U` handler to wipe the buffer in one keystroke if a fresh query is desired.

---

## 4. UI / Command Mockup

### 4.1 Enhanced Search Modal (Pre-filled Query & `Ctrl+U` Support)
```
 ╔════════════════════════════════════════════════════════════════╗
 ║ Search YouTube / Direct URL:                                   ║
 ║ > synthwave radio chill                                      █ ║
 ║ [Enter] Search   [Ctrl+U] Clear   [Esc] Cancel                 ║
 ╚════════════════════════════════════════════════════════════════╝
```

### 4.2 Active Filter Output (View Count Sorting Activated)
```
 YouTube Terminal Viewer | [MUSIC / AUDIO] | [AUTO: OFF] | [CC: ON] | [QUEUE: 0] | Guest / Public
===================================================================================================
  Search: "synthwave" [Sort: views | Dur: all]  (Found 20 results)
---------------------------------------------------------------------------------------------------
> 01. Synthwave Radio - 24/7 Chill Beats        Lofi Girl          --:--
  02. RETROWAVE / SYNTHWAVE MIX 2026            Astrosurf          1:12:45
  03. Best of Synthwave 80s Cyberpunk           NewRetroWave         54:12
```

---

## 5. Verification & Test Plan

1. **Automated Internal Self-Tests**:
   ```bash
   ./LuaJIT/src/luajit yt.lua --test
   ```
   *Expected*: All 25+ assertions pass, validating:
   - `build_search_spec` sort precedence for `CAM%253D`, `CAI%253D`, `CAE%253D`.
   - `scrape_youtube_search` query parameter passing and non-nil fallback behavior.
   - Shell metacharacter escaping (`$`, `` ` ``, `\`, `"`).
   - Multi-byte pending key queue for pasted input.
2. **Backend Regression Suite**:
   ```bash
   LUA_PATH="LuaJIT/src/?.lua;;" ./LuaJIT/src/luajit test_yt.lua
   ```
   *Expected*: Tests 1 through 12 complete cleanly, confirming 0 undeclared globals in `yt.lua`.
3. **Live Web Scraper Fallback Test**:
   ```bash
   ./LuaJIT/src/luajit yt.lua --no-interactive --max-results 2 "synthwave"
   ```
   *Expected*: Results successfully extracted without nil index crashes.
4. **Shell Escaping Assertion**:
   ```bash
   ./LuaJIT/src/luajit yt.lua --no-interactive --max-results 1 "lofi $HOME \`echo test\`"
   ```
   *Expected*: Query is preserved literally and does not trigger environment variable or command expansion.

---

## 6. Implementation Diff Preview

```diff
--- a/yt.lua
+++ b/yt.lua
@@ -411,6 +411,6 @@ else
         raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
         ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
         raw_mode_enabled = true
-        io.write("\27[?1049h\27[?25l")
+        io.write("\27[?1049h\27[?25l\27[?7l")
         io.flush()
         return true
@@ -418,6 +418,6 @@ else
     disable_raw_mode = function()
         if raw_mode_enabled then
-            io.write("\27[?1049l\27[?25h\27[0m")
+            io.write("\27[?1049l\27[?25h\27[?7h\27[0m")
             io.flush()
             ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
@@ -428,6 +428,10 @@ else
     local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
     local key_buf = ffi.new("char[16]")
+    local pending_keys = {}
 
     read_key = function(timeout_ms)
+        if #pending_keys > 0 then
+            return table.remove(pending_keys, 1)
+        end
         timeout_ms = timeout_ms or -1
         local ret = ffi.C.poll(pfd, 1, timeout_ms)
@@ -459,6 +463,9 @@ else
                 elseif c0 == 21 then
                     return "CTRL_U"
                 elseif c0 >= 32 and c0 <= 126 then
+                    for i = 1, n - 1 do
+                        table.insert(pending_keys, string.char(key_buf[i]))
+                    end
                     return string.char(c0)
                 end
@@ -1024,6 +1031,7 @@ end
 local function scrape_youtube_search(query, max_results, proxy, insecure)
+    query = tostring(query or "")
     max_results = max_results or 20
     local encoded = query:gsub("([^%w%-%_%.%~])", function(c)
@@ -1083,6 +1091,15 @@ local function build_search_spec(query, mode, max_results, is_liked, filters, s
     local is_direct_url = query:match("^https?://") or query:match("^www%.") or query:match("^youtu%.be/")
+    local safe_q = query:gsub('["\\$`]', '\\%1')
     if is_liked then
         if mode == "music" then
             return '"https://music.youtube.com/playlist?list=LM"'
         else
             return '":ytfavorites"'
         end
     elseif is_direct_url then
         return string.format("%q", query)
+    elseif site == "youtube" and filters and filters.sort and filters.sort ~= "relevance" then
+        local sp_map = { views = "CAM%253D", date = "CAI%253D", rating = "CAE%253D" }
+        local sp = sp_map[filters.sort]
+        if sp then
+            local enc_term = query:gsub("%s+", "+"):gsub('["\\$`]', '\\%1')
+            return string.format('"https://www.youtube.com/results?search_query=%s&sp=%s"', enc_term, sp)
+        else
+            return string.format('"ytsearch%d:%s"', max_results, safe_q)
+        end
     elseif SITE_SEARCH_PREFIXES[site] then
-        return string.format('"%s%d:%s"', SITE_SEARCH_PREFIXES[site], max_results, query:gsub('"', '\\"'))
+        return string.format('"%s%d:%s"', SITE_SEARCH_PREFIXES[site], max_results, safe_q)
     else
-        return string.format('"ytsearch%d:%s"', max_results, query:gsub('"', '\\"'))
+        return string.format('"ytsearch%d:%s"', max_results, safe_q)
     end
 end
@@ -1214,7 +1231,7 @@ local function fetch_youtube_results(query, mode, browser, cookies_file, max_re
     if site == "youtube" and not is_liked and not is_direct_url then
-        local fallback_items = scrape_youtube_search(term, max_results, proxy, insecure)
+        local fallback_items = scrape_youtube_search(query, max_results, proxy, insecure)
         if fallback_items and #fallback_items > 0 then
             return fallback_items, nil, insecure
         elseif not insecure then
-            local fallback_insecure = scrape_youtube_search(term, max_results, proxy, true)
+            local fallback_insecure = scrape_youtube_search(query, max_results, proxy, true)
@@ -2128,7 +2145,7 @@ local function prompt_search_query(current_query)
-    local input_str = ""
+    local input_str = current_query or ""
@@ -2160,6 +2177,9 @@ local function prompt_search_query(current_query)
         elseif k == "BACKSPACE" then
             if #input_str > 0 then
                 input_str = input_str:sub(1, #input_str - 1)
                 draw_modal()
             end
+        elseif k == "CTRL_U" then
+            input_str = ""
+            draw_modal()
```
