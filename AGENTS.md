# Agent Instructions

For any issue, feature request, review, or modification task, the agent MUST follow this workflow:

1.  **Research & Think**: Analyze the request (including any review notes), explore the relevant parts of the codebase, and identify the root cause or optimal design for the change.
2.  **Design & Plan**: Formulate a clear plan of action and verification strategy.
    *   **Verification Strategy**: For every change, **ALWAYS consider and define how to verify/validate the change** (e.g., test suites, manual verification commands, edge-case checks) before writing code.
    *   **UI / Command Mockup**: If the task involves a TUI, GUI, or command output, **ALWAYS show a visual mockup UI or sample output preview**.
    *   **Recommendation**: Give clear, actionable recommendations with rationale.
    *   **ALWAYS show the user the plan/design before making any code changes.**
3.  **Approval Gate**: Wait for user approval before starting implementation (unless the user has indicated auto-approval).
4.  **Implement**: Perform surgical and idiomatic changes to the codebase directly.
5.  **Verify**: Validate the changes through testing, manual verification, or relevant shell commands to ensure the solution is correct and does not introduce regressions. Double check and verify every fix/solution thoroughly before concluding.
6.  **Ship Directly**: Once verification passes, ship directly — create the atomic commit locally and push to the remote repository without waiting for intermediate confirmation.

Verification is the only path to finality. Do not assume success. Always double check and verify every fix or solution for correctness.

## Error Handling & Diagnostics

* **Never Fail Silently**: Handle errors explicitly. Do not swallow exceptions, ignore failed return values, or exit without explaining what failed.
* **Visible, Actionable Errors**: Report the failed operation, relevant file path or resource, underlying error, and a practical recovery step when known. CLI tools must write errors to stderr and return a nonzero exit code for fatal failures. GUIs and TUIs must show failures in the active view without losing user input.
* **Startup & Progress Visibility**: Print and flush startup phases before loading native libraries, opening files or databases, scanning data, or starting servers. Long-running operations must show progress so a stall or native crash leaves a useful last-known phase.
* **Explicit Fallbacks**: When a missing optional config or resource causes defaults, degraded functionality, or automatic creation, say so and print its path. Distinguish expected first-run creation from an invalid, unreadable, or corrupt resource. Never silently create an empty replacement for a required existing database.
* **Protected Cleanup**: Protect application entry points and external operations where practical. Preserve error details and close handles, release locks, and restore terminal state on failure. Native crashes may bypass language-level handlers; do not claim they were caught.
* **Verify Writes Before Reporting Success**: After saving configuration or other critical files, verify the file exists and read back its expected contents. Print the resolved path only after successful verification; write or verification failures must never produce a success message.
* **Test Failure Paths**: Verify missing files and dependencies, permission and write failures, malformed data, busy resources, and failed subprocesses. Assert visible diagnostics, correct exit status, cleanup, and preservation of user data. Test intentional fallbacks and automatic creation as well as fatal errors.

## Windows SQLite DLL Selection

* **Multiple Versions Are Expected**: Windows can have several SQLite DLLs with different versions, architectures, and compile options. Do not assume the first `sqlite3.dll` found by the system loader is correct.
* **Discover and Allow Selection**: List candidate DLLs with their resolved paths and sources without loading them merely for discovery. Provide a way for the user to select a candidate or configure an explicit DLL path; use CodeFind's discovery and validation approach as a reference.
* **Validate Before Use**: Check that the DLL architecture matches LuaJIT, then verify required SQLite APIs and the features actually used by the application. Display the selected path and SQLite version. Do not require optional features the application does not use.
* **Persist the Selection**: Save the validated DLL path in configuration, preserve other settings, and verify the saved file by reading it back. Print the verified configuration path and reuse the saved selection on subsequent launches. Define and document precedence for command-line, environment, and saved configuration overrides.
* **Fail Clearly on Invalid Pins**: An invalid explicit or saved DLL selection must produce a visible error and instructions for selecting or configuring a replacement. Never silently replace a user-selected DLL with another version. Selection must remain available to repair an invalid saved pin.
* **Verify Selection and Recovery**: Test multiple candidates, architecture and API incompatibility, missing DLLs, invalid choices, configuration persistence, reuse on restart, and preservation of existing settings. Cover Windows paths containing spaces or Unicode and report loader failures clearly.

## Verification & Validation Guidelines

For every change, define how it will be proven correct *before* writing code,
and choose the method that fits what changed:

| Change type            | Minimum verification                                         |
|------------------------|--------------------------------------------------------------|
| Bug fix                | Reproduce the failure first; show it passes after the fix    |
| New behavior / feature | Add a test; run the real command and inspect its output      |
| Error handling         | Trigger the failure; confirm the exact message shown         |
| TUI / rendering        | Run it in a terminal; check resize, shrink, and cleanup      |
| Refactor / formatting  | Existing tests unchanged; `git diff --check`; no behavior diff |
| Docs / config only     | Syntax or lint check; confirm the file is still parsed       |

*   **Pre-Implementation Strategy**: Identify test commands, scripts, or reproduction steps *before* writing code.
*   **Automated Tests**: Run the narrowest relevant test first, then the full suite (`--test`, unit tests, integration tests). Add new test cases covering the change and edge cases.
*   **Live Verification**: Execute the actual command or utility in the environment to confirm the fix works in practice.
*   **Edge Cases & Regressions**: Test boundary inputs, invalid parameters, error handling, and ensure existing behavior is preserved.
*   **Verification is Mandatory**: Never assume a fix works without running verification commands and inspecting output.
*   **Report Evidence**: End each task with a `Verified:` block listing the real commands run and their results, taken from actual output (never assumed).
*   **If Something Cannot Be Verified** (e.g. Windows-only code on Linux), state exactly what was not verified and why. Never describe it as passing.

    ```
    Verified:     make check                -> all suites passed
    Verified:     make lint                 -> no new luacheck issues
    Verified:     luajit app.lua /nonexistent -> "error: path not found: /nonexistent"
    Not verified: Windows console path (no Windows host available)
    ```

*   **Full Regression Run**: `make check` runs every Lua suite (`run_all_tests.lua`) and the self-contained Python PTY/deploy/server suites, continues after failures, and exits non-zero if any failed (about 2 minutes). Run it before shipping changes to shared modules such as `termkit.lua` or `deploy.lua`.
*   **Pre-Ship Checklist**: Before every commit, run each gate that applies and report it in the `Verified:` block:
    1. `git diff --check` (always).
    2. The 80-column diff check from "Source Line Length" (any source file changed).
    3. `make lint` (any `.lua` file added or modified; see "Static Analysis (luacheck)").
    4. The narrowest relevant test, then `make check` (code changed; always for shared modules).
    5. Docs or config only: steps 1–2 suffice; say that `make check` was not run and why.
*   **TUI Render & Viewport Coverage**: Never leave UI/modal rendering functions uncalled in tests. Test suites must execute all view and modal renderers directly (or via headless harness) across boundary conditions (empty data, long strings, special characters, and terminal size boundaries) to catch format-string mismatches (`bad argument to 'format'`) and clipping bugs before release.
*   **Keystroke Simulation Testing**: Never test text input using only pre-composed strings. Test interactive input loops by feeding actual token sequences emitted by the key reader (including symbolic tokens like `"SPACE"`, `"BACKSPACE"`, `"ENTER"`, `"ESC"`).
*   **Subprocess & External Command Validation**: Any feature invoking shell commands or external tools must be verified end-to-end to ensure standard output/error is visible to the user and terminal state (raw mode, screen buffer) transitions correctly.
*   **Headless Pipeline Sanity Checks**: For interactive terminal utilities, run a non-interactive pipeline test (e.g. `printf ":\x1b" | luajit app.lua`) or mock driver to verify that invocation, key dispatch, and clean exit complete without runtime crashes.
*   **Undeclared Global Check**: Always run `make lint`; it must report no new `W111` (setting a global) or `W113` (reading an undefined variable) in the files you changed. In Lua, undefined variable typos (like `term` instead of `query`) silently evaluate to `nil` and can hide undetected in unexercised fallback branches. Optional diagnostics, not substitutes:
    *   `luajit -bl <script.lua> | grep -E 'GGET|GSET'` shows what the compiler actually resolved as global. Standard globals (`string`, `io`, `pairs`, ...) appear too, so look for names that are not standard library.
    *   `test_yt.lua` Test 12 is a regression test for `yt.lua` only.
*   **State-Machine Round-Trip Testing**: Test interactive utilities through multi-step view transitions (e.g. `Empty State -> History [h] -> Exit History [h]`, `Search Results -> History [h] -> Restore Search Results`). Verify that transitioning from a populated view to a shorter or empty view cleanly overwrites all rows with zero visual ghosting.

## Request & Issue Workflow

When the user asks about an issue, problem, feature, or modification, the agent MUST:

1.  **Think & Analyze**: Explain the root cause or understand the requirement clearly.
    *   **Show the Investigation Trail**: Before stating a root cause, list the decisive commands used to find it (reproduction, grep/search, log or state inspection), each with a one-line result. Keep them copy-pasteable and in order. Skip noise; keep dead ends only when they ruled out a likely suspect. Finish with a short "Troubleshoot it yourself" tip. If the cause is not confirmed, label it **Hypothesis** and give the command that would confirm it.
2.  **Propose a Solution & Design**: Explain what needs to change, the plan of action, and why.
3.  **Define Verification / Validation Plan**: Explicitly state how the change will be tested and validated (commands to run, expected results, edge cases).
4.  **Show Mockup UI / Command Output**: If the request involves TUI, GUI, or command output, provide a realistic mockup or sample output preview.
5.  **Give Recommendation**: Provide your professional recommendation and options.
6.  **Show Code Comparison**: Present a before/after diff so the user can see exactly what changes.
7.  **Approval Mode**:
    *   If the user has indicated **"approve always"**, **"do it"**, **"auto approve"**, or explicitly asks to fix/implement directly: proceed immediately with implementation and verification without asking for confirmation.
    *   Otherwise: **WAIT for user approval before applying changes or starting implementation.**
8.  **Ship After Verification**: Once changes are implemented and verified, **ship directly** (create the atomic commit locally and push to remote) without waiting for intermediate prompts.

## TUI Performance & Refresh Standards

For any TUI application or terminal utility in the repository, the agent MUST adhere to these design and implementation principles:

1. **Flicker-Free Differential Refresh**:
   *   **Never Flash the Screen on Any User Action**: `\27[2J` (clear screen) MUST NEVER be emitted in response to any user-driven action — this includes key presses (Space, Enter, arrow keys, hotkeys), cursor navigation, list traversal, typing, stepping through algorithms, toggling modes, confirming prompts, or any other interactive input. The screen must remain visually stable at all times during normal interaction.
   *   **Full Clear is Reserved for Exceptional Events Only**: `\27[2J` may ONLY be used for: (a) initial screen setup on program start, (b) terminal window resize events, (c) returning from an external sub-process (e.g., `$EDITOR`), or (d) a full data reset (e.g., restart/reload). In all other cases, use cursor-addressed row overwrites instead.
   *   **Differential Updates on Local Movement**: When moving between items within the visible viewport page, update **only the changed rows** (e.g., un-highlight the previous row, highlight the new row) instead of rebuilding and redrawing the entire screen.
   *   **Atomic Synchronized Frame Emission**: Wrap frame buffer output in synchronized update escapes (`\27[?2026h` ... `\27[?2026l`) and flush in a single atomic `io.write()`. Never emit piecemeal terminal writes across multiple unbuffered calls.
   *   **Prevent Auto-Wrap Shift**: Disable line wrapping (`\27[?7l`) on startup and clamp layout width to `raw_cols - 1` to prevent wide strings from pushing the cursor to the next line and breaking coordinate-based row addressing (`\27[Y;XH`).
   *   **Universal Row-Clear Invariant (`\27[K`)**: Every row emitted during differential redraws (including blank spacing lines, empty list placeholders, and status messages) MUST terminate with `\27[K\n` (clear to end of line). Never emit a bare `\n` without `\27[K`, ensuring transitions from longer to shorter or empty views never leave ghost text, stale item titles, or trailing duration digits bleeding through.

2. **Responsiveness & Edge Cases**:
   *   **Zero-Latency Prompt Echo**: For search inputs and typing modes, provide immediate 0ms visual echo for the query prompt row without waiting for asynchronous searches or redrawing unrelated panes. Drain burst keystrokes from input queues cleanly.
   *   **Strict Viewport Bounds & Invariants**: Enforce `1 <= selected_idx <= #items` and ensure `selected_idx` is always visible within `[scroll_offset + 1, scroll_offset + viewport_height]`.
   *   **Boundary Transitions**: Seamlessly handle first-item, last-item, and scroll-boundary crossings. Falling back from differential updates to full viewport scrolling must be robust and error-free.
   *   **Closure Scoping & Forward Declarations**: Always forward-declare all rendering functions (`render_full_screen`, `render_selection_differential`, etc.) at the top of TUI closures so boundary transitions and cross-calls never encounter uninitialized nil references.
   *   **Secondary View State Preservation**: Toggling temporary views (like History `[h]` or Queue `[Q]`) must preserve the active search results, cursor index, and scroll offset. Exiting via the toggle key or `[Esc]` must instantly restore the previous screen with 0ms latency, zero screen flicker, and zero network re-queries.
   *   **Graceful Terminal Restoration**: Always register signal traps (`SIGINT`, `SIGTERM`, `EXIT`) and protected exit paths to guarantee alternate buffer exit (`\27[?1049l`), cursor restore (`\27[?25h`), and terminal raw mode reset.

3. **Component Render Decoupling & Format Safety**:
   *   **Pure Frame Generators**: Decouple visual rendering from interactive event loops. Expose or structure views as pure frame render functions (`render_<view>_frame(...) -> string`) that can be executed and asserted headlessly without an interactive TTY.
   *   **Format String Invariants**: In format strings (`string.format`), ensure placeholder counts strictly match argument counts. Never construct multi-line templates with variable numbers of arguments without parameter parity checks or programmatic line joining.

4. **Text Input & Keystroke Normalization**:
   *   **Symbolic Token Translation**: Key readers often return symbolic strings (e.g., `"SPACE"`, `"ENTER"`, `"UP"`). Text-entry loops must never assume all printable characters satisfy `#key == 1`. Always normalize symbolic tokens (e.g., map `"SPACE"` to `" "`) before length or printable checks.
   *   **Cursor & Buffer Bounds**: Support multi-byte characters, backspace at index 0, and clamped cursor positions when editing text buffers.

5. **Subprocess Execution & Screen Buffer Discipline**:
   *   **In-Place Execution vs. Terminal Handoff**:
       *   Use `suspend_raw_mode()` (restoring canonical mode and echo, while keeping the active screen buffer intact) for inline commands where output must be seen by the user before returning.
       *   Reserve `disable_raw_mode()` (restoring primary buffer `\27[?1049l`) for full program termination or full-screen external tool handoffs (e.g., launching `$EDITOR`).
   *   **Buffer Flash & Overwrite Prevention**: Never flip screen buffers (`\27[?1049h` / `\27[?1049l`) around an inline subprocess, as switching buffers instantly hides command stdout/stderr.
   *   **Input Drainage Before Confirmation**: Always flush the terminal input buffer (`tcflush` or OS equivalent) before prompting `Press Enter to continue...`, preventing queued or burst keystrokes from unintentionally skipping command output.

## Source Line Length (All Languages)

Applies to every source file and script in the repository: Lua, Python, C/C++, JavaScript, shell, SQL, and the `Makefile`. Markdown, data files, and vendored or generated code are exempt.

* **Hard limit 80**: Never exceed 80 characters per line.
* **Only exception**: a string literal, URL, or file path that cannot be split may exceed 80. Keep a greppable error message intact rather than splitting it.
* **Wrap, do not shorten names**: Fix a long line by wrapping it or by pulling a sub-expression into a named local, never by abbreviating identifiers.
* **Applies to lines you add or modify**: Older files contain longer lines. Do not reformat untouched code only to meet the limit; that buries the real change in the diff. Bring a function within the limit when you are already modifying it.
* **Check before shipping**: The command below lists added lines over 80 characters and must print nothing (the threshold is 81 because each diff line starts with `+`):

    ```
    git diff -U0 HEAD -- '*.lua' '*.py' '*.sh' '*.js' '*.cpp' Makefile \
        | grep '^+' | grep -v '^+++' | awk 'length($0) > 81'
    ```

## Lua Code Formatting & Style Standards

All Lua files created or modified in the repository MUST adhere to consistent, clean, and idiomatic formatting:

1. **Readability-First Philosophy & Spacing**:
   * **Code must be immediately readable**: Write code for humans first. Prioritize clear, uncluttered layout over compaction.
   * **4 spaces per indentation level** (never tabs, never 2-space or mixed indentation).
   * **Spaces around binary operators**: Use `a = b + c`, `x == y`, `key = value` (not `a=b+c`).
   * **Table spacing**: Space inside curly braces for single-line tables: `{ id = 1, name = "app" }`.
   * **Function arguments & commas**: Always place a single space after commas: `fn(a, b, c)`.
   * **Line length**: Follow "Source Line Length (All Languages)" above: 80 characters is the hard limit.
   * **Wrap long lines, do not shorten names**: Break after a comma or before a binary operator (`and`, `or`, `..`, `+`), and indent continuation lines by 4 spaces. Put one argument or table field per line once a call or constructor no longer fits. Pull a long sub-expression into a named local instead of wrapping it three times:
     ```lua
     -- Good:
     local is_busy = process.state == "R"
         or process.cpu_percent > ACTIVE_CPU_THRESHOLD
     local label = string.format(
         "%s: %d processes",
         category.label,
         category_counts[category.id] or 0
     )

     -- Prohibited:
     local label = string.format("%s: %d processes", category.label, category_counts[category.id] or 0)
     ```

2. **One Statement Per Line & Multi-Line Control Flow (No Clutter)**:
   * **One statement per line**: Never pack multiple statements on a single line separated by semicolons (e.g., avoid `stmt1; stmt2`, `count = count + 1; print(...)`). Use `,` to separate table fields, never `;`. Semicolons belong only inside strings (such as `package.path` lists and `ffi.cdef` declarations).
   * **No single-line control structures**: `if ... then ... end`, `for ... do ... end`, and `while ... do ... end` MUST NEVER be written on a single line. Even simple guard clauses or early returns must be expanded across separate lines with standard 4-space indentation:
     ```lua
     -- Good:
     if not success then
         return nil, err
     end

     for index, item in ipairs(items) do
         process_item(item)
     end

     -- Prohibited:
     if not success then return nil, err end
     for i, v in ipairs(t) do print(v) end
     ```
   * **Clarity over compaction**: Never micro-compact or minify Lua code to reduce line counts. Code must be structured for rapid comprehension, clean git diffs, and effortless debugging.
   * **Multi-line tables & arguments**: Format complex table constructors and long argument lists across multiple lines with clean indentation rather than sprawling horizontally.

3. **Small Functions & Clean Code**:
   * **Small, single-purpose functions**: Each function must do one thing well and be describable in one sentence without "and". Aim for about 30 lines; 50 is the hard limit. If a function mixes parsing with rendering, needs section comments to navigate, or takes more than 5 parameters, split it into focused local helpers (group related parameters into one table).
   * **Read top-down**: A function body should read as a short list of steps at one level of detail. Move the details of each step into a well-named helper rather than inlining them.
   * **Shallow nesting**: Prefer guard clauses and early returns over deeply nested blocks. Aim for at most 3 levels of indentation inside a function.
   * **No nested `and`/`or` chains**: Use `cond and a or b` only for a single simple choice. Write two or more chained choices as `if`/`elseif`, or as a lookup table.
     Never use it when `a` can be `false` or `nil`: the expression then returns `b` even though `cond` is true (`enabled and false or true` is always `true`). Use `if`/`else` instead.
   * **Named constants, not magic numbers**: Give thresholds, sizes, column widths, and key or signal codes an `UPPER_SNAKE_CASE` name at the top of the file.
   * **Table-driven over long `elseif` ladders**: Map keys, modes, or names to values or handler functions in a table instead of repeating `elseif x == "..." then`.
   * **Keep code uncluttered**: Remove dead code, unused local variables, leftover debug prints, commented-out code blocks, and speculative features. Do not introduce abstractions or fallback layers that no active code path uses. This does not cover the reported fallbacks required by "Explicit Fallbacks" or per-platform implementations required by "OS branching & FFI".
   * **No duplicate logic**: Extract repeated patterns into shared local functions rather than copy-pasting.

4. **Meaningful Variable & Function Names**:
   * **Descriptive and intent-revealing**: Choose names that clearly convey purpose and semantics (e.g., `selected_index`, `line_count`, `parse_http_header`).
   * **Self-explaining function names**: A function's name must tell a reader what it does without opening its body. Start with a verb and name the object and, when it matters, the result (`parse_http_header`, `build_status_line`, `is_valid_port`, `remove_stale_sessions`). Avoid vague names such as `process`, `handle`, `do_work`, `run2`, `helper`, `util`, or `misc`.
   * **Name matches behavior**: If a function does more than its name says (writes a file, mutates its argument, spawns a process), either rename it or split it. Use `is_`/`has_` for boolean results and `find_`/`get_` only when the failure case (`nil`, `nil, err`) is clear.
   * **Comment when the name cannot carry it**: Add a `---` doc comment when behavior is not obvious from the name and signature: side effects, units, ownership of arguments, error returns, ordering requirements, or why it exists. Do not add a comment that only repeats the name.
   * **No cryptic abbreviations**: Avoid arbitrary short forms (e.g., use `connection` instead of `cn`, `buffer` instead of `buf_dat`).
   * **Single-letter variables restricted**: Single-letter names are permitted ONLY for:
     * numeric loop counters `i`, `j` in short loops;
     * `k, v` in a short generic loop where the key and value have no domain meaning (copying, merging, or serializing a table). When they mean something, name them: `for name, app in pairs(APPS)`, not `for k, v in pairs(APPS)`;
     * `_` for a value that is deliberately ignored: `for _, item in ipairs(items)`, `local _, err = f()`;
     * `M` as the table a module returns (`local M = {}` … `return M`), and nowhere else;
     * coordinate and size pairs `x`, `y`, `w`, `h`.
   * **Scoping & casing**:
     * Variables and helper functions: `local` by default, `snake_case` (`load_config`, `process_event`). Never leak symbols into global `_G`.
     * Constants: `UPPER_SNAKE_CASE` (`HISTORY_MAX`, `DEFAULT_TIMEOUT_MS`).
     * Classes & metatables: `PascalCase` (`Database`, `Indexer`).

5. **Cross-Platform Compatibility (Windows & POSIX)**:
   * **Path separators**: Build and join paths with `/`; Windows file APIs accept it. Do not assume an absolute path starts with `/` (`C:/x` and `\\server\share` are absolute too). Convert to `\` only when passing a path to a Windows shell command (`cmd.exe`, `start`, `dir`).
   * **Line endings**: Handle both CRLF (`\r\n`) and LF (`\n`) gracefully when parsing files or subprocess output (e.g., strip trailing `\r`).
   * **OS branching & FFI**: When utilizing native syscalls or FFI libraries, explicitly inspect `ffi.os` (`"Windows"`, `"Linux"`, `"OSX"`) and provide tested implementations or graceful fallbacks for each supported platform.
   * **Subprocess execution**: Account for OS shell differences (e.g., Windows `cmd.exe`/PowerShell argument escaping vs. POSIX `/bin/sh`) and executable extensions (`.exe`).

6. **Comments & Documentation**:
   * **Comment the "why", not the "what"**: Add comments when rationale is not obvious: non-obvious constraints, workarounds, platform quirks, unit conversions, invariants, or deliberate trade-offs. Never restate self-evident code.
   * **Document public and exported functions**: Precede every module-level or exported function with a concise doc comment. Use `---` (not `--`) on every line so tools and `grep '^---'` find it:
     * First line: one sentence saying what the function does, starting with a verb.
     * Then, only what the name and signature do not already say: arguments by name in backticks, units, side effects, and every return value, including the failure return (`nil, err`).
     * LuaLS tags (`---@param name type`, `---@return type`) are optional; use them when a type is not obvious (FFI cdata, callbacks, option tables).
     ```lua
     --- Parse an SGR mouse report at the start of `s`.
     --- Returns the event table and the remaining bytes, or nil when `s`
     --- does not start with a mouse report.
     local function parse_mouse(s)
     ```

7. **File Structure, Headers & Whitespace Discipline**:
   * **Hashbang**: Executable scripts start with `#!/usr/bin/env luajit`.
   * **Module / script banner**: Include a clear descriptive header comment at the top explaining the module's responsibility.
   * **Section dividers**: Separate top-level sections (banner, requires, constants, helpers, core logic, entry point) with `-- ` plus `=` to 76 columns, and subsections inside one of them with `-` to 80 columns. Use one style per level within a file; do not mix widths.
     ```lua
     -- =========================================================================
     -- Helpers
     -- =========================================================================

     --------------------------------------------------------------------------------
     ```
   * **Group related code**: Order a file as banner, requires, constants, C declarations, helpers, core logic, entry point, using section dividers. Keep related functions adjacent, and define helpers before their first use.
   * **Consistent idioms**: Follow one error-handling convention per module (e.g., `value, err` returns, never silent `nil`), one naming style, and one way to build strings and tables.
   * **Raise vs return**: Decide by who caused the failure:
     * Return `nil, err` for expected runtime failures: I/O, missing files or libraries, parse errors, network, subprocesses, and user input. `err` names the operation and the resource (`"open config: /path: No such file"`).
     * Raise with `error(message, 2)` or `assert` for programmer errors: wrong argument types, broken invariants, impossible states. Level `2` points the message at the caller.
     * Catch with `pcall`/`xpcall` only at boundaries (entry point, one event-loop iteration, a request handler, a native or FFI load) and report it per "Error Handling & Diagnostics". Never use `pcall` to hide an error.
     * Check every `nil, err` return: pass it up with context (`return nil, "load config: " .. err`) or handle it. `assert(f())` is acceptable only in tests and one-off scripts.
   * **Whitespace discipline**: No trailing whitespace, single final newline (`\n`), and at most 1–2 blank lines between major functions or sections.

8. **Idioms**:
   * **Methods use `:`**: Define and call methods with `:` (`function Account:deposit(amount)`, `account:deposit(10)`); use `.` for constructors and module functions (`Account.new`, `string.format`). Calling a `:` method with `.` shifts every argument and leaves `self` as the first real argument. See `notes.md` §3.
   * **Build strings in loops with `table.concat`**: Collect pieces in a table and join once. `s = s .. piece` inside a loop copies the whole string each time (about 100× slower for 20,000 pieces). A single concatenation outside a loop is fine.
   * **Keep arrays without holes**: `#t` and `ipairs` are only reliable on sequences `1..n` with no `nil` gaps; after `t[2] = nil` on four items, `#t` can still be 4 while `ipairs` stops after 1. Remove items with `table.remove`; for sparse data keep an explicit count or iterate with `pairs`.
   * **`continue` is `goto continue`**: Lua has no `continue`. Prefer a guard clause or a helper function; when the loop body is long, jump to a `::continue::` label at the end of the body. Never emulate it with `repeat ... until true`.
   * **Double quotes by default**: Use `"..."` for strings; use `'...'` only when the text contains `"` to avoid escaping. Use `[[...]]` for multi-line text.

## Static Analysis (luacheck)

Luacheck enforces the scoping and clean-code rules above mechanically: leaked or undefined globals, unused variables and arguments, shadowing, unreachable code, and syntax errors.

* **Config**: `.luacheckrc` at the repo root sets `std = "luajit"`, excludes the vendored `LuaJIT/` and `LuaBridge/` submodules, and ignores unused `self`. Line length is not checked there; the diff check in "Source Line Length" owns it so legacy long lines are not reported.
* **No new warnings**: Run `make lint` before shipping any Lua change. It compares every added or modified Lua file with its `HEAD` version and fails if the luacheck issue count grew. New files must have zero issues. Exit status: 0 clean, 1 new issues, 2 luacheck missing or failed.
* **Legacy warnings**: `make lint-all` reports the whole repo (761 warnings when adopted). Fix legacy warnings in their own commits, never mixed into an unrelated change.
* **Silence only on purpose**: Prefer fixing the code. When a warning is intentional (e.g. a tutorial that demonstrates globals), add `-- luacheck: ignore <code>` on that line with the reason. For a short block (a few lines, such as stubbing and restoring `os.execute` in a test), wrap it in `-- luacheck: push ignore <code>` … `-- luacheck: pop` with the reason above it. Never add file-wide or config-wide ignores to make `make lint` pass.
* **Install**: Linux: distro package or `luarocks install luacheck`. Windows: standalone `luacheck.exe` from https://github.com/lunarmodules/luacheck/releases, or `luarocks install luacheck`. Check with `luacheck --version`.
* **Windows**: `lint_changed.sh` is POSIX `sh`, and Git Bash (installed with Git for Windows) does not include `make`. Run the gate directly from Git Bash with `sh lint_changed.sh`; it is exactly what `make lint` runs. `luacheck.exe` must be on the Git Bash `PATH`.

## Deployment (`deploy.lua`)

* **Local modules are discovered automatically**: `deploy.lua` scans each app's source for `require("name")` / `pcall(require, "name")` and installs the matching `name.lua` (transitively) next to the app. Adding a `require` of a repo module needs no registry edit.
* **Register new apps**: add the app to `APPS` and `APP_ORDER` in `deploy.lua`. Use `deps` only for files loaded without a literal `require` (e.g. `dofile`, computed names) and `system_modules` for modules installed system-wide.
* **Unresolvable requires fail the deploy** before anything is written. Never silence this by wrapping a hard dependency in `pcall`.
* **Verify**: after adding an app, a `require` of a new module, or moving a module, run `python3 test_deploy_dependencies.py` and `python3 test_deploy_mdview.py`, and deploy to a temp directory and start the installed app from a different working directory.

## Commit Workflow

*   **One commit per issue**: Each fix should be its own atomic commit with a descriptive message.
*   **Ship Directly After Verification**: Once verification passes, create the atomic commit locally and push to the remote repository directly without stopping for manual prompts.
*   **"commit"**: When the user explicitly says "commit", create the commit(s) locally. Do NOT push.
*   **"push"**: When the user explicitly says "push", push all local commits to the remote repository.

## Shorthand Triggers

*   **"ship"** or **"avcp"**: Shorthand for **"apply verify commit push"**. The agent MUST immediately implement the proposed changes, run the "Pre-Ship Checklist" and the change's verification/test suites, create the atomic commit locally, and push to the remote repository without stopping for intermediate prompts.
*   **"lgtm"** or **"do it"**: Shorthand for approving implementation and verification immediately.
*   **"ci"**: Shorthand for local "commit".
*   **"gp"**: Shorthand for "push" to remote.
*   **"list"** (or **"list issues"**, optionally scoped, e.g. "list issues for AGENTS.md"): List the remaining issues, ordered by priority. Do not change any files.
    *   **Numbered for reference**: Give every issue a number the user can cite (`#1`, `#2`, ...). Format each item as one line: `#N [P0-P3] short title — file:line or command that shows it — suggested next step`.
    *   **Stable numbers**: Within a session, an issue keeps its number across repeated lists, and numbers are never reused. Fixed issues are dropped (not renumbered); newly found issues get the next unused number. If the scope changes (e.g. from the repo to one file), start a new numbering and say so.
    *   **Order**: Most important first: P0 broken behavior or failing tests, P1 correctness and safety risks, P2 rule violations and style, P3 cleanup and nice-to-haves.
    *   **Source**: Re-check the current repo state (`git status`, failing tests, linters, open findings from this session) rather than relying on memory, and drop items that are already fixed.
*   **"next"**, **"next #N"**, **"explain #N"**, or just **"#N"**: Present one issue for approval. "next" means the top remaining issue; the others mean issue `#N` from the latest list. Do not change any files until the user approves.
    *   **Header**: Start with `#N [priority] title` so the issue is unambiguous.
    *   **Problem**: Explain what is wrong and why it matters, with the investigation trail (commands and one-line results) that shows it.
    *   **Solution**: State the proposed fix and how it works.
    *   **Recommendation**: Say which option you recommend and why, with alternatives only when they change the decision.
    *   **Code changes**: Show before and after for each change, one block per file.
    *   **Test plan**: List the exact commands and expected results that will prove the fix, including failure paths and the full-suite run.
    *   **Ask for approval**: End by asking the user to approve ("do it", "lgtm", or "ship"), then stop and wait.
    *   **On approval**: Implement, verify, commit, and push that one issue without further prompts (one commit per issue; mention `#N` only in the chat report, not in the commit message, since numbers are session-local). Finish with the `Verified:` block and `#N shipped as <short sha>`.
*   **"guide me"**: Teaching mode. The user types the code themselves to learn and master it; the agent MUST NOT edit, create, commit, or push files for that task.
    *   **Review first**: Start by reviewing the code and listing the findings, then give a short numbered outline of the steps (titles only, no code yet).
    *   **One step at a time**: Show only the current step: the exact code to type and where it goes. Never show later steps' code in advance.
    *   **Explain**: For the current step, explain what the code does and why it is written that way (the concept, the Lua/LuaJIT idiom, the pitfall it avoids), not just what to type.
    *   **Checkpoint**: End the step with a command the user can run and the output to expect, then stop and wait.
    *   **Check on request**: When the user asks to check, read their file, run the verification commands, and report what differs from the step. Point out the fix; do not apply it. If something is wrong, stay on the same step until the user has fixed it and asked for another check.
    *   **Advance only after a passing check**: Move to the next step only once the current step has been checked and passes.
    *   Teaching mode lasts until the last step passes or the user gives an implementing trigger (e.g. "do it", "ship").
