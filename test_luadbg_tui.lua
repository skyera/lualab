#!/usr/bin/env luajit
-- test_luadbg_tui.lua: headless tests for luadbg_tui.lua. Frames are
-- rendered to strings and the session runs with a fake termkit, a fake
-- debugger table and a fake stdout, so no terminal is needed.

local tui = require("luadbg_tui")

-- =========================================================================
-- Constants
-- =========================================================================

local SIZES = { { 80, 24 }, { 40, 12 }, { 200, 60 }, { 39, 11 }, { 20, 5 } }
local SOURCE_TEXT = table.concat({
    "local function add(a, b)",
    "\tlocal sum = a + b -- héllo wörld",
    "    return sum",
    "end",
    "",
    "local total = add(1, 2)",
    "print(total)",
    "local x =\t1 -- tab after other spans",
}, "\n") .. "\n"

-- =========================================================================
-- Helpers
-- =========================================================================

-- The session replaces the global print while the "program" runs, so test
-- results go through the original function to stay out of the log.
local REAL_PRINT = print

local tests_run = 0
local tests_passed = 0

local function check(condition, description)
    tests_run = tests_run + 1
    if condition then
        tests_passed = tests_passed + 1
        REAL_PRINT("  [PASS] " .. description)
    else
        REAL_PRINT("  [FAIL] " .. description)
    end
end

local function contains(text, fragment)
    return text:find(fragment, 1, true) ~= nil
end

--- Split a frame into { [row] = visible text } using its cursor moves.
--- Escape sequences are removed; each UTF-8 character counts as one cell.
local function split_frame_rows(frame)
    local rows = {}
    for row, body in frame:gmatch("\27%[(%d+);1H(.-)\27%[K") do
        local text = body:gsub("\27%[[%d;?]*[%a@~]", "")
        rows[tonumber(row)] = text
    end
    return rows
end

local function count_cells(text)
    local _, count = text:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function count_matches(text, fragment)
    local count = 0
    local position = 1
    while true do
        local found = text:find(fragment, position, true)
        if not found then
            return count
        end
        count = count + 1
        position = found + #fragment
    end
end

local function write_file(path, content)
    local file = assert(io.open(path, "w"))
    file:write(content)
    file:close()
end

local function new_fake_termkit(keys)
    local termkit = { cols = 80, rows = 24, left = false }
    function termkit.size()
        return termkit.cols, termkit.rows
    end
    function termkit.read_key()
        return table.remove(keys, 1) or "EOF"
    end
    function termkit.leave()
        termkit.left = true
    end
    return termkit
end

local function new_fake_stdout()
    local stdout = { chunks = {} }
    function stdout.write(_, ...)
        for i = 1, select("#", ...) do
            stdout.chunks[#stdout.chunks + 1] = select(i, ...)
        end
    end
    function stdout.flush()
    end
    function stdout.take()
        local text = table.concat(stdout.chunks)
        stdout.chunks = {}
        return text
    end
    return stdout
end

local function new_fake_debugger()
    return {
        use_color = function()
        end,
        format_stack_frame_info = function(info)
            return info.short_src .. ":" .. info.currentline
        end,
    }
end

local function make_frame_info(path, line, name)
    return {
        source = "@" .. path,
        short_src = path,
        currentline = line,
        name = name,
        namewhat = "local",
        what = "Lua",
    }
end

local source_path = os.tmpname()
write_file(source_path, SOURCE_TEXT)

-- =========================================================================
-- Tests: rendering
-- =========================================================================

print("Test 1: layout fills the terminal exactly")
do
    local layout = tui.compute_layout(24)
    check(layout.source_height == 11 and layout.log_height == 8,
        "24 rows: 11 source rows and 8 log rows")
    check(layout.log_top + layout.log_height == layout.input_rule,
        "log pane ends just above the input rule")
    check(layout.help == 24 and layout.input == 23, "input and help rows")
end

print("Test 2: frames at boundary sizes stay inside the screen")
for _, size in ipairs(SIZES) do
    local cols, rows = size[1], size[2]
    local state = tui.new_state()
    state.location = { path = source_path, line = 2, label = "in local 'add'" }
    tui.append_log(state, string.rep("x", 500) .. "\n\tTab\27[31mred\n")
    local frame = tui.render_frame(state, cols, rows)
    local frame_rows = split_frame_rows(frame)
    local widest = 0
    for _, text in pairs(frame_rows) do
        widest = math.max(widest, count_cells(text))
    end
    local label = string.format("%dx%d", cols, rows)
    check(widest <= cols - 1, label .. ": no row wider than cols - 1")
    local cleared_rows = count_matches(frame, "\27[K")
    check(cleared_rows >= rows, label .. ": every row ends with \\27[K")
    check(frame:sub(1, 8) == "\27[?2026h" and frame:sub(-8) == "\27[?2026l",
        label .. ": frame is one synchronized update")
    check(not contains(frame, "\27[2J"), label .. ": no clear unless asked")
end

print("Test 3: source pane, header and log contents")
do
    local state = tui.new_state()
    state.location = { path = source_path, line = 2, label = "in local 'add'" }
    tui.append_log(state, "dbg> p a\na => 1\npartial")
    local frame = tui.render_frame(state, 80, 24)
    local rows = split_frame_rows(frame)
    check(contains(rows[1], source_path .. ":2  in local 'add'"),
        "header shows path, line and function")
    check(contains(rows[1], "[stopped]"), "header shows the status")
    check(contains(frame, "\27[7m   2 \226\150\182     local sum"),
        "current line is reversed, marked and tab-expanded")
    check(contains(rows[3], "héllo wörld"), "UTF-8 source is kept")
    check(contains(frame, "a => 1") and contains(frame, "partial"),
        "log shows complete and partial lines")
    check(contains(rows[23], "dbg> "), "input row shows the prompt")
end

print("Test 4: empty, missing and too-small states")
do
    local state = tui.new_state()
    local frame = tui.render_frame(state, 80, 24)
    check(contains(frame, "(no location yet)"), "no location placeholder")
    state.location = { path = "/no/such/file.lua", line = 3, label = "x" }
    frame = tui.render_frame(state, 80, 24)
    check(contains(frame, "source not available: /no/such/file.lua"),
        "missing source file is reported")
    frame = tui.render_frame(state, 39, 11)
    check(contains(split_frame_rows(frame)[1],
        "Terminal too small (39x11, min 40x12)"),
        "too-small terminal shows the whole message")
    frame = tui.render_frame(state, 80, 24, true)
    check(contains(frame, "\27[?2026h\27[?25l\27[2J"),
        "clear is inside the synchronized update when asked")
end

print("Test 5: long log lines wrap and the newest stay visible")
do
    local state = tui.new_state()
    for i = 1, 30 do
        tui.append_log(state, "line " .. i .. "\n")
    end
    tui.append_log(state, string.rep("w", 100) .. "\n")
    local rows = split_frame_rows(tui.render_frame(state, 80, 24))
    local layout = tui.compute_layout(24)
    local last_log_row = layout.log_top + layout.log_height - 1
    check(rows[last_log_row] == string.rep("w", 21),
        "wrapped tail is on the last log row")
    check(rows[last_log_row - 1] == string.rep("w", 79),
        "first wrapped piece is one row above")
    check(rows[last_log_row - 2] == "line 30", "older lines scroll up")
end

print("Test 6: source window stays centred and clamped")
do
    local start = tui.get_source_window_start
    check(start(50, 100, 10, 0) == 45, "middle of a long file is centred")
    check(start(2, 100, 10, 0) == 1, "near the top clamps to line 1")
    check(start(99, 100, 10, 0) == 91, "near the end clamps to the last page")
    check(start(3, 5, 10, 0) == 1, "short file starts at line 1")
    check(start(50, 100, 10, -9) == 36, "offset shifts the window")
end

-- =========================================================================
-- Tests: line editor with real key tokens
-- =========================================================================

local function type_keys(editor, keys)
    local result
    for _, key in ipairs(keys) do
        result = tui.apply_editor_key(editor, key)
    end
    return result
end

print("Test 7: line editor handles termkit tokens")
do
    local editor = tui.new_editor()
    type_keys(editor, { "BACKSPACE", "p", "SPACE", "x", "BACKSPACE", "y" })
    check(table.concat(editor.chars) == "p y",
        "SPACE inserts, BACKSPACE at 0 is safe")
    type_keys(editor, { "HOME", "é", "END", "LEFT", "z" })
    check(table.concat(editor.chars) == "ép zy" and editor.cursor == 4,
        "HOME/END/LEFT move by character, UTF-8 inserts")
    type_keys(editor, { "TAB", "ESC", "F5", { type = "mouse" }, "\1" })
    check(table.concat(editor.chars) == "ép zy",
        "symbolic keys, mouse events and control bytes are ignored")
    check(tui.apply_editor_key(editor, "ENTER") == "submit", "ENTER submits")
    check(tui.take_editor_line(editor) == "ép zy" and #editor.chars == 0,
        "take_editor_line returns the text and clears")
end

print("Test 8: history with UP and DOWN")
do
    local editor = tui.new_editor()
    for _, command in ipairs({ "n", "p x", "p x", "s" }) do
        type_keys(editor, { command })
        tui.take_editor_line(editor)
    end
    check(#editor.history == 3, "repeated commands are stored once")
    type_keys(editor, { "UP" })
    check(table.concat(editor.chars) == "s", "UP shows the newest")
    type_keys(editor, { "UP", "UP", "UP" })
    check(table.concat(editor.chars) == "n", "UP stops at the oldest")
    type_keys(editor, { "DOWN", "DOWN", "DOWN" })
    check(#editor.chars == 0, "DOWN past the newest gives an empty line")
end

print("Test 9: input row scrolls sideways to keep the cursor visible")
do
    local state = tui.new_state()
    type_keys(state.editor, { string.rep("a", 1), "b" })
    for _ = 1, 120 do
        tui.apply_editor_key(state.editor, "c")
    end
    local row = tui.render_input_row(state, 80, 24)
    local column = tonumber(row:match("\27%[23;(%d+)H\27%[%?25h$"))
    check(column ~= nil and column <= 79, "cursor column stays on screen")
    check(contains(row, "\27[K"), "input row ends with \\27[K")
end

-- =========================================================================
-- Tests: session with fake terminal and debugger
-- =========================================================================

print("Test 10: debugger hooks, location tracking and program I/O")
do
    local keys = { "n", "ENTER", "t", "ENTER", "ENTER", "a", "b", "ENTER",
        "x", "ENTER" }
    local termkit = new_fake_termkit(keys)
    local dbg = new_fake_debugger()
    local stdout = new_fake_stdout()
    local session = tui.new_session(termkit, dbg, stdout)
    local real_print = print
    session:attach_debugger()

    dbg.format_stack_frame_info(make_frame_info(source_path, 2, "add"))
    check(dbg.read() == "n", "dbg.read returns the typed command")
    check(session.state.location.line == 2, "a stop moves the source pane")
    check(print ~= real_print, "program output is redirected while running")
    print("from program", 42)
    check(session.state.log_lines[#session.state.log_lines]
        == "from program\t42", "print goes to the log")

    dbg.write("trace\n")
    check(print == real_print, "dbg.write restores the real print")
    for line = 1, 3 do
        dbg.format_stack_frame_info(make_frame_info(source_path, line, "f"))
    end
    check(dbg.read() == "t" and session.state.location.line == 2,
        "t (several frames described) does not move the source pane")
    check(dbg.read() == "", "empty ENTER is passed on for repeat")
    check(contains(table.concat(session.state.log_lines, "\n"), "dbg> t"),
        "empty ENTER echoes the repeated command")

    check(io.read() == "ab", "program io.read() is served by the input row")
    check(io.read("*L") == "x\n", "io.read('*L') keeps the newline")
    local ok, err = pcall(io.read, "*n")
    check(not ok and contains(err, "only io.read() of one line"),
        "unsupported io.read format raises a clear error")
    check(io.read() == nil, "closed input gives nil to the program")

    session:restore_program_io()
    check(print == real_print and io.read ~= nil, "real I/O is restored")
    stdout.take()
    session:close()
    check(termkit.left, "close leaves the terminal")
    check(stdout.take() == "from program\t42\nab\nx\n",
        "program output and input are replayed after leaving")
end

print("Test 11: resize triggers one full clear, typing does not")
do
    local termkit = new_fake_termkit({ "p", "ENTER" })
    local stdout = new_fake_stdout()
    local session = tui.new_session(termkit, new_fake_debugger(), stdout)
    session:handle_key("q")
    check(not contains(stdout.take(), "\27[2J"), "typing does not clear")
    termkit.cols, termkit.rows = 100, 30
    session:refresh_size()
    local frame = stdout.take()
    check(contains(frame, "\27[2J") and contains(frame, "\27[30;1H"),
        "resize clears once and draws the new last row")
    session:refresh_size()
    check(stdout.take() == "", "no redraw when the size is unchanged")
end

-- =========================================================================
-- Tests: syntax highlighting
-- =========================================================================

local function new_located_state(color)
    local state = tui.new_state({ color = color })
    state.location = { path = source_path, line = 2, label = "in local 'add'" }
    return state
end

--- Return { [row] = raw row body with escapes } for one frame.
local function split_raw_rows(frame)
    local rows = {}
    for row, body in frame:gmatch("\27%[(%d+);1H(.-)\27%[K") do
        rows[tonumber(row)] = body
    end
    return rows
end

print("Test 12: colored frames show the same text as plain frames")
for _, size in ipairs(SIZES) do
    local cols, rows = size[1], size[2]
    local label = string.format("%dx%d", cols, rows)
    local colored = tui.render_frame(new_located_state(true), cols, rows)
    local plain = tui.render_frame(new_located_state(false), cols, rows)
    local colored_rows = split_frame_rows(colored)
    local plain_rows = split_frame_rows(plain)
    local same = true
    for row = 1, rows do
        if colored_rows[row] ~= plain_rows[row] then
            same = false
        end
    end
    check(same, label .. ": visible text matches plain (tabs, cuts, pad)")
    local layout = tui.compute_layout(rows)
    local raw_rows = split_raw_rows(colored)
    local reset_before_clear = true
    for row = layout.source_top, layout.source_top + layout.source_height - 1 do
        local body = raw_rows[row] or ""
        if body:find("\27%[") and body:sub(-4) ~= "\27[0m" then
            reset_before_clear = false
        end
    end
    check(reset_before_clear, label .. ": styled rows reset before \\27[K")
end

print("Test 13: colors, current line and NO_COLOR")
do
    local state = new_located_state(true)
    local frame = tui.render_frame(state, 80, 24)
    local raw_rows = split_raw_rows(frame)
    check(contains(raw_rows[2], "\27[35mlocal")
        and contains(raw_rows[2], "\27[35mfunction"),
        "keywords are colored")
    check(contains(raw_rows[3], "\27[48;5;237m")
        and contains(raw_rows[3], "\226\150\182"),
        "current line has the background and the marker")
    check(contains(raw_rows[3], "\27[90m-- héllo wörld"),
        "comment after a tab keeps its color and UTF-8")
    local first_spans = state.highlight_cache[source_path]
    tui.render_frame(state, 80, 24)
    check(first_spans ~= nil and state.highlight_cache[source_path]
        == first_spans, "a file is tokenized once and cached")

    local plain = tui.render_frame(new_located_state(false), 80, 24)
    check(not contains(plain, "\27[35m") and not contains(plain, "48;5;237"),
        "color off: no syntax colors or background")
    check(contains(split_raw_rows(plain)[3], "\27[7m"),
        "color off: current line uses reverse video")

    local function env(values)
        return function(name)
            return values[name]
        end
    end
    check(tui.is_color_enabled(env({})), "color on by default")
    check(not tui.is_color_enabled(env({ NO_COLOR = "1" })),
        "NO_COLOR=1 turns color off")
    check(tui.is_color_enabled(env({ NO_COLOR = "" })),
        "empty NO_COLOR is ignored")
    check(not tui.is_color_enabled(env({ DBG_NOCOLOR = "1" })),
        "DBG_NOCOLOR=1 turns color off")
end

os.remove(source_path)
print(string.format("%d / %d passed", tests_passed, tests_run))
if tests_passed ~= tests_run then
    os.exit(1)
end
