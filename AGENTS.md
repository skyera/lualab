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

For every change, consider how to prove correctness before concluding:
*   **Pre-Implementation Strategy**: Identify test commands, scripts, or reproduction steps *before* writing code.
*   **Automated Tests**: Run test suites (`--test`, unit tests, integration tests). Add new test cases covering the change and edge cases.
*   **Live Verification**: Execute the actual command or utility in the environment to confirm the fix works in practice.
*   **Edge Cases & Regressions**: Test boundary inputs, invalid parameters, error handling, and ensure existing behavior is preserved.
*   **Verification is Mandatory**: Never assume a fix works without running verification commands and inspecting output.
*   **TUI Render & Viewport Coverage**: Never leave UI/modal rendering functions uncalled in tests. Test suites must execute all view and modal renderers directly (or via headless harness) across boundary conditions (empty data, long strings, special characters, and terminal size boundaries) to catch format-string mismatches (`bad argument to 'format'`) and clipping bugs before release.
*   **Keystroke Simulation Testing**: Never test text input using only pre-composed strings. Test interactive input loops by feeding actual token sequences emitted by the key reader (including symbolic tokens like `"SPACE"`, `"BACKSPACE"`, `"ENTER"`, `"ESC"`).
*   **Subprocess & External Command Validation**: Any feature invoking shell commands or external tools must be verified end-to-end to ensure standard output/error is visible to the user and terminal state (raw mode, screen buffer) transitions correctly.
*   **Headless Pipeline Sanity Checks**: For interactive terminal utilities, run a non-interactive pipeline test (e.g. `printf ":\x1b" | luajit app.lua`) or mock driver to verify that invocation, key dispatch, and clean exit complete without runtime crashes.
*   **Bytecode Scoping & Undeclared Global Check**: Always run LuaJIT bytecode analysis (`luajit -bl <script.lua>`) or the scoping test suite (`test_yt.lua` Test 12) to assert 0 undeclared globals (`GGET`). In Lua, undefined variable typos (like `term` instead of `query`) silently evaluate to `nil` and can hide undetected in unexercised fallback branches.
*   **State-Machine Round-Trip Testing**: Test interactive utilities through multi-step view transitions (e.g. `Empty State -> History [h] -> Exit History [h]`, `Search Results -> History [h] -> Restore Search Results`). Verify that transitioning from a populated view to a shorter or empty view cleanly overwrites all rows with zero visual ghosting.

## Request & Issue Workflow

When the user asks about an issue, problem, feature, or modification, the agent MUST:

1.  **Think & Analyze**: Explain the root cause or understand the requirement clearly.
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
   *   **Symbolic Token Translation**: Key readers often return symbolic strings (e.g., `"SPACE"`, `"ENTER"`, `"UP"`). Text-entry loops must never assume all printable characters satisfy `#k == 1`. Always normalize symbolic tokens (e.g., map `"SPACE"` to `" "`) before length or printable checks.
   *   **Cursor & Buffer Bounds**: Support multi-byte characters, backspace at index 0, and clamped cursor positions when editing text buffers.

5. **Subprocess Execution & Screen Buffer Discipline**:
   *   **In-Place Execution vs. Terminal Handoff**:
       *   Use `suspend_raw_mode()` (restoring canonical mode and echo, while keeping the active screen buffer intact) for inline commands where output must be seen by the user before returning.
       *   Reserve `disable_raw_mode()` (restoring primary buffer `\27[?1049l`) for full program termination or full-screen external tool handoffs (e.g., launching `$EDITOR`).
   *   **Buffer Flash & Overwrite Prevention**: Never flip screen buffers (`\27[?1049h` / `\27[?1049l`) around an inline subprocess, as switching buffers instantly hides command stdout/stderr.
   *   **Input Drainage Before Confirmation**: Always flush the terminal input buffer (`tcflush` or OS equivalent) before prompting `Press Enter to continue...`, preventing queued or burst keystrokes from unintentionally skipping command output.

## Lua Code Formatting & Style Standards

All Lua files created or modified in the repository MUST adhere to consistent, clean, and idiomatic formatting:

1. **Indentation & Spacing**:
   * **4 spaces per indentation level** (never tabs, never 2-space or mixed indentation).
   * **Spaces around binary operators**: Use `a = b + c`, `x == y`, `key = value` (not `a=b+c`).
   * **Table spacing**: Space inside curly braces for single-line tables: `{ id = 1, name = "app" }`.
   * **Function arguments & commas**: Always place a single space after commas: `fn(a, b, c)`.

2. **File Structure & Clean Headers**:
   * **Hashbang**: Executable scripts start with `#!/usr/bin/env luajit`.
   * **Module / Script Banner**: Include a clear, top-of-file descriptive comment banner outlining the purpose and key features.
   * **Section Dividers**: Use consistent 80-character comment dividers (e.g., `-- =========================================================================` or `--------------------------------------------------------------------------------`) between logical module sections.

3. **Line Length & Whitespace Discipline**:
   * **No Trailing Whitespace**: Strip all trailing whitespace from ends of lines.
   * **Single Final Newline**: Ensure every file ends with exactly one newline (`\n`).
   * **Max Line Width**: Keep code comfortably readable (aim for <= 100-120 columns where practical).
   * **No Redundant Blank Lines**: Use at most 1-2 blank lines between major functions or sections; never consecutive runs of 3+ blank lines.

4. **Naming & Scoping Conventions**:
   * **Local by Default**: Always declare variables and helper functions as `local`. Never leak symbols into global `_G`.
   * **Constants**: Use `UPPER_SNAKE_CASE` for file-level constants and static configuration tables.
   * **Functions & Variables**: Use `snake_case` for functions and variables (`load_config`, `parse_args`).
   * **Classes / Metatables**: Use `PascalCase` for OOP-like metatables or types (`Database`, `Indexer`).

5. **Readability-First & Statement Separation**:
   * **One statement per line**: Never pack multiple statements on a single line separated by semicolons (e.g. avoid `stmt1; stmt2`, `if not ok then release(); error(err) end`, `count = count + 1; print(...)`). Semicolons in Lua code are reserved strictly for `package.path` lists, C struct declarations in `ffi.cdef`, or string literals.
   * **Structured Control Flow**: Avoid single-line `if ... then ... end` or compressed loops when statements involve side effects, error reporting, returns, or resource cleanup. Expand them into structured multi-line blocks with standard 4-space indentation.
   * **Clarity Over Compaction**: Never micro-compact or minify Lua code to reduce line counts. Code must be formatted for clarity, rapid comprehension, effortless debugging, and clean git diffs.
   * **Multi-line Tables & Arguments**: When table constructors or function calls contain multiple fields or exceed comfortable reading width, format them across multiple lines with clean indentation rather than sprawling horizontally.

## Commit Workflow

*   **One commit per issue**: Each fix should be its own atomic commit with a descriptive message.
*   **Ship Directly After Verification**: Once verification passes, create the atomic commit locally and push to the remote repository directly without stopping for manual prompts.
*   **"commit"**: When the user explicitly says "commit", create the commit(s) locally. Do NOT push.
*   **"push"**: When the user explicitly says "push", push all local commits to the remote repository.

## Shorthand Triggers

*   **"ship"** or **"avcp"**: Shorthand for **"apply verify commit push"**. The agent MUST immediately implement the proposed changes, run all verification/test suites, create the atomic commit locally, and push to the remote repository without stopping for intermediate prompts.
*   **"lgtm"** or **"do it"**: Shorthand for approving implementation and verification immediately.
*   **"ci"**: Shorthand for local "commit".
*   **"gp"**: Shorthand for "push" to remote.
