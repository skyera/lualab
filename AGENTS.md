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

Verification is the only path to finality. Do not assume success. Always double check and verify every fix or solution for correctness.

## Verification & Validation Guidelines

For every change, consider how to prove correctness before concluding:
*   **Pre-Implementation Strategy**: Identify test commands, scripts, or reproduction steps *before* writing code.
*   **Automated Tests**: Run test suites (`--test`, unit tests, integration tests). Add new test cases covering the change and edge cases.
*   **Live Verification**: Execute the actual command or utility in the environment to confirm the fix works in practice.
*   **Edge Cases & Regressions**: Test boundary inputs, invalid parameters, error handling, and ensure existing behavior is preserved.
*   **Verification is Mandatory**: Never assume a fix works without running verification commands and inspecting output.

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

## TUI Performance & Refresh Standards

For any TUI application or terminal utility in the repository, the agent MUST adhere to these design and implementation principles:

1. **Flicker-Free Differential Refresh**:
   *   **No Full Screen Clears on Navigation**: Never emit `\27[2J` (clear screen) during cursor navigation, list traversal, or typing. Full screen clearing is strictly reserved for window resize events and returning from external sub-processes (e.g., `$EDITOR`).
   *   **Differential Updates on Local Movement**: When moving between items within the visible viewport page, update **only the changed rows** (e.g., un-highlight the previous row, highlight the new row) instead of rebuilding and redrawing the entire screen.
   *   **Atomic Synchronized Frame Emission**: Wrap frame buffer output in synchronized update escapes (`\27[?2026h` ... `\27[?2026l`) and flush in a single atomic `io.write()`. Never emit piecemeal terminal writes across multiple unbuffered calls.
   *   **Prevent Auto-Wrap Shift**: Disable line wrapping (`\27[?7l`) on startup and clamp layout width to `raw_cols - 1` to prevent wide strings from pushing the cursor to the next line and breaking coordinate-based row addressing (`\27[Y;XH`).

2. **Responsiveness & Edge Cases**:
   *   **Zero-Latency Prompt Echo**: For search inputs and typing modes, provide immediate 0ms visual echo for the query prompt row without waiting for asynchronous searches or redrawing unrelated panes. Drain burst keystrokes from input queues cleanly.
   *   **Strict Viewport Bounds & Invariants**: Enforce `1 <= selected_idx <= #items` and ensure `selected_idx` is always visible within `[scroll_offset + 1, scroll_offset + viewport_height]`.
   *   **Boundary Transitions**: Seamlessly handle first-item, last-item, and scroll-boundary crossings. Falling back from differential updates to full viewport scrolling must be robust and error-free.
   *   **Closure Scoping & Forward Declarations**: Always forward-declare all rendering functions (`render_full_screen`, `render_selection_differential`, etc.) at the top of TUI closures so boundary transitions and cross-calls never encounter uninitialized nil references.
   *   **Graceful Terminal Restoration**: Always register signal traps (`SIGINT`, `SIGTERM`, `EXIT`) and protected exit paths to guarantee alternate buffer exit (`\27[?1049l`), cursor restore (`\27[?25h`), and terminal raw mode reset.

## Commit Workflow

*   **One commit per issue**: Each fix should be its own atomic commit with a descriptive message.
*   **"commit"**: When the user says "commit", create the commit(s) locally. Do NOT push.
*   **"push"**: When the user says "push", push all local commits to the remote repository.

## Shorthand Triggers

*   **"ship"** or **"avcp"**: Shorthand for **"apply verify commit push"**. The agent MUST immediately implement the proposed changes, run all verification/test suites, create the atomic commit locally, and push to the remote repository without stopping for intermediate prompts.
*   **"lgtm"** or **"do it"**: Shorthand for approving implementation and verification immediately.
*   **"ci"**: Shorthand for local "commit".
*   **"gp"**: Shorthand for "push" to remote.
