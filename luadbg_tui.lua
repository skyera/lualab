#!/usr/bin/env luajit
-- luadbg_tui.lua: two-pane terminal UI used by `luadbg.lua --tui`.
--
-- The top pane shows the source around the current line. Below it a log
-- holds debugger output and the program's print/io.write output, then one
-- input line takes debugger commands, or program input while the program
-- waits in io.read(). Frames are built by pure functions (render_frame,
-- render_input_row) so tests can check them without a terminal.
-- Source lines are syntax highlighted (lua_highlight.lua) unless NO_COLOR
-- or DBG_NOCOLOR is set.

local lua_highlight = require("lua_highlight")

local M = {}

-- =========================================================================
-- Constants
-- =========================================================================

local SOURCE_PANE_SHARE = 0.6
local FIXED_ROWS = 5 -- header, two rules, input row, help row
local MIN_COLS = 40
local MIN_ROWS = 12
local POLL_INTERVAL_MS = 100
local TAB_WIDTH = 4
local LOG_MAX_LINES = 5000
local LINE_NUMBER_WIDTH = 4
local CTRL_D = "\4"

local DEBUGGER_PROMPT = "dbg> "
local PROGRAM_PROMPT = "input> "
local EXIT_PROMPT = "Program finished. Press any key to leave. "
local HELP_TEXT = "Enter run (empty = repeat)  Up/Down history  "
    .. "PgUp/PgDn scroll source  h help  q quit"
local CURRENT_LINE_MARKER = "\226\150\182" -- U+25B6, one column wide
local RULE_CHAR = "\226\148\128" -- U+2500 box-drawing horizontal line

local CSI = "\27["
local CLEAR_TO_EOL = CSI .. "K"
local CLEAR_SCREEN = CSI .. "2J"
local SYNC_BEGIN = CSI .. "?2026h"
local SYNC_END = CSI .. "?2026l"
local SHOW_CURSOR = CSI .. "?25h"
local HIDE_CURSOR = CSI .. "?25l"
local STYLE_RESET = CSI .. "0m"
local STYLE_REVERSE = CSI .. "7m"
local STYLE_BOLD = CSI .. "1m"
local STYLE_DIM = CSI .. "2m"
-- 256-color grey: a background that keeps syntax colors readable.
local CURRENT_LINE_BACKGROUND = CSI .. "48;5;237m"

-- Basic ANSI colors so highlighting follows the terminal's theme.
local SYNTAX_STYLES = {
    keyword = CSI .. "35m",
    constant = CSI .. "36m",
    builtin = CSI .. "34m",
    string = CSI .. "32m",
    number = CSI .. "33m",
    comment = CSI .. "90m",
    plain = "",
}

local STATUS_LABELS = {
    stopped = "stopped",
    running = "running",
    input = "waiting for program input",
    exited = "exited",
}

-- termkit.read_key tokens that are keys, not text ("SPACE" is text).
local SYMBOLIC_KEYS = {
    ENTER = true, ESC = true, TAB = true, SHIFT_TAB = true,
    BACKSPACE = true, UP = true, DOWN = true, LEFT = true, RIGHT = true,
    HOME = true, END = true, PAGE_UP = true, PAGE_DOWN = true, F5 = true,
}

-- io.read formats the TUI can serve, mapped to the suffix they keep.
local LINE_READ_FORMATS = { ["*l"] = "", l = "", ["*L"] = "\n", L = "\n" }

-- =========================================================================
-- Text helpers
-- =========================================================================

--- Split `text` into an array of UTF-8 characters.
local function split_chars(text)
    local chars = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char
    end
    return chars
end

--- Convert `text` into display cells, one character per column: tabs are
--- expanded, terminal escape sequences dropped, other control bytes shown
--- as "?". Wide (CJK) characters are counted as one column.
--- `start_column` (default 0) is where `text` begins, for tab stops.
local function to_display_chars(text, start_column)
    start_column = start_column or 0
    text = text:gsub("\27%[[%d;?]*[%a@~]", ""):gsub("\r", "")
    local cells = {}
    for _, char in ipairs(split_chars(text)) do
        local byte = char:byte()
        if char == "\t" then
            repeat
                cells[#cells + 1] = " "
            until (start_column + #cells) % TAB_WIDTH == 0
        elseif byte < 32 or byte == 127 then
            cells[#cells + 1] = "?"
        else
            cells[#cells + 1] = char
        end
    end
    return cells
end

--- Return `text` cut to `width` columns, padded with spaces when `pad`.
local function fit_row(text, width, pad)
    local cells = to_display_chars(text)
    local count = math.min(#cells, width)
    local row = table.concat(cells, "", 1, count)
    if pad and count < width then
        row = row .. string.rep(" ", width - count)
    end
    return row
end

--- Split `text` into rows of at most `width` columns (at least one row).
local function wrap_text(text, width)
    local cells = to_display_chars(text)
    local rows = {}
    for first = 1, #cells, width do
        local last = math.min(#cells, first + width - 1)
        rows[#rows + 1] = table.concat(cells, "", first, last)
    end
    if #rows == 0 then
        rows[1] = ""
    end
    return rows
end

--- Return the number of columns `text` takes on screen.
local function display_width(text)
    return #to_display_chars(text)
end

--- Render highlighted `spans` into at most `width` columns. Every span
--- starts from STYLE_RESET plus `base_style` (e.g. the current-line
--- background) plus its syntax color. Tabs expand from the first span.
--- Returns the styled text and the number of columns used.
local function fit_spans(spans, width, base_style)
    local out = {}
    local column = 0
    for _, span in ipairs(spans) do
        if column >= width then
            break
        end
        local cells = to_display_chars(span.text, column)
        local count = math.min(#cells, width - column)
        out[#out + 1] = STYLE_RESET .. base_style
            .. (SYNTAX_STYLES[span.kind] or "")
            .. table.concat(cells, "", 1, count)
        column = column + count
    end
    return table.concat(out), column
end

--- Return true unless `getenv` reports NO_COLOR or DBG_NOCOLOR set to a
--- non-empty value (NO_COLOR convention; DBG_NOCOLOR is debugger.lua's).
function M.is_color_enabled(getenv)
    for _, name in ipairs({ "NO_COLOR", "DBG_NOCOLOR" }) do
        local value = getenv(name)
        if value and value ~= "" then
            return false
        end
    end
    return true
end

-- =========================================================================
-- State, log and source
-- =========================================================================

--- Create an empty line editor with its own history.
function M.new_editor()
    return { chars = {}, cursor = 0, history = {}, history_index = nil }
end

--- Create the UI state shared by the renderer and the input loop.
--- `options.color` turns on syntax highlighting (default off).
function M.new_state(options)
    local command_editor = M.new_editor()
    return {
        color = (options and options.color) == true,
        location = nil, -- { path, line, label } of the inspected frame
        status = "stopped",
        exit_message = nil,
        source_cache = {}, -- path -> array of lines, or false if unreadable
        highlight_cache = {}, -- path -> array of span arrays, one per line
        source_offset = 0, -- PgUp/PgDn shift from the centred view
        log_lines = {},
        log_partial = "", -- text after the last newline
        command_editor = command_editor,
        input_editor = M.new_editor(),
        editor = command_editor,
        prompt = DEBUGGER_PROMPT,
    }
end

--- Append `text` to the log; it may hold several or partial lines.
function M.append_log(state, text)
    local pending = state.log_partial .. text
    for line in pending:gmatch("([^\n]*)\n") do
        state.log_lines[#state.log_lines + 1] = line
    end
    state.log_partial = pending:match("([^\n]*)$")
    while #state.log_lines > LOG_MAX_LINES do
        table.remove(state.log_lines, 1)
    end
end

--- Return the lines of the file at `path` (cached), or nil if unreadable.
local function load_source_lines(state, path)
    local cached = state.source_cache[path]
    if cached ~= nil then
        return cached or nil
    end
    local file = io.open(path, "rb")
    if not file then
        state.source_cache[path] = false
        return nil
    end
    local lines = {}
    for line in file:lines() do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    file:close()
    state.source_cache[path] = lines
    return lines
end

--- Return the first line to show so `current` sits near the middle of a
--- `height`-row pane, shifted by `offset` and clamped to the file.
function M.get_source_window_start(current, line_count, height, offset)
    local first = current - math.floor(height / 2) + offset
    local last_start = math.max(1, line_count - height + 1)
    return math.max(1, math.min(first, last_start))
end

-- =========================================================================
-- Line editor
-- =========================================================================

local function set_editor_text(editor, text)
    editor.chars = split_chars(text)
    editor.cursor = #editor.chars
end

local function show_older_history(editor)
    if #editor.history == 0 then
        return
    end
    local index = (editor.history_index or #editor.history + 1) - 1
    editor.history_index = math.max(1, index)
    set_editor_text(editor, editor.history[editor.history_index])
end

local function show_newer_history(editor)
    if not editor.history_index then
        return
    end
    editor.history_index = editor.history_index + 1
    if editor.history_index > #editor.history then
        editor.history_index = nil
        set_editor_text(editor, "")
        return
    end
    set_editor_text(editor, editor.history[editor.history_index])
end

local function delete_before_cursor(editor)
    if editor.cursor > 0 then
        table.remove(editor.chars, editor.cursor)
        editor.cursor = editor.cursor - 1
    end
end

local EDITOR_ACTIONS = {
    BACKSPACE = delete_before_cursor,
    LEFT = function(editor)
        editor.cursor = math.max(0, editor.cursor - 1)
    end,
    RIGHT = function(editor)
        editor.cursor = math.min(#editor.chars, editor.cursor + 1)
    end,
    HOME = function(editor)
        editor.cursor = 0
    end,
    END = function(editor)
        editor.cursor = #editor.chars
    end,
    UP = show_older_history,
    DOWN = show_newer_history,
}

local function is_text_key(key)
    if type(key) ~= "string" or SYMBOLIC_KEYS[key] then
        return false
    end
    local byte = key:byte()
    return byte ~= nil and byte >= 32 and byte ~= 127
end

--- Apply one termkit key token to `editor`.
--- Returns "submit" for ENTER, otherwise nil.
function M.apply_editor_key(editor, key)
    if key == "ENTER" then
        return "submit"
    end
    if key == "SPACE" then
        key = " "
    end
    local action = EDITOR_ACTIONS[key]
    if action then
        action(editor)
    elseif is_text_key(key) then
        editor.cursor = editor.cursor + 1
        table.insert(editor.chars, editor.cursor, key)
    end
    return nil
end

--- Return the editor's text, record it in history, and clear the editor.
function M.take_editor_line(editor)
    local line = table.concat(editor.chars)
    local history = editor.history
    if line ~= "" and history[#history] ~= line then
        history[#history + 1] = line
    end
    set_editor_text(editor, "")
    editor.history_index = nil
    return line
end

-- =========================================================================
-- Rendering
-- =========================================================================

--- Return the screen row of each UI part for a terminal `rows` high.
function M.compute_layout(rows)
    local pane_rows = rows - FIXED_ROWS
    local source_height = math.floor(pane_rows * SOURCE_PANE_SHARE)
    return {
        header = 1,
        source_top = 2,
        source_height = source_height,
        log_rule = source_height + 2,
        log_top = source_height + 3,
        log_height = pane_rows - source_height,
        input_rule = rows - 2,
        input = rows - 1,
        help = rows,
    }
end

local function render_header(state, width)
    local status = STATUS_LABELS[state.status]
    if state.status == "exited" and state.exit_message then
        status = state.exit_message
    end
    local right = "[" .. status .. "] "
    local room = width - display_width(right)
    local location = state.location
    local left = " (starting)"
    if location then
        left = string.format(" %s:%d  %s",
            location.path, location.line, location.label)
        if display_width(left) > room then
            local name = location.path:match("[^/\\]+$") or location.path
            left = string.format(" %s:%d  %s",
                name, location.line, location.label)
        end
    end
    if room < 1 then
        return fit_row(right, width)
    end
    return fit_row(left, room, true) .. fit_row(right, width - room)
end

local function format_line_prefix(number, is_current)
    local marker = " "
    if is_current then
        marker = CURRENT_LINE_MARKER
    end
    return string.format("%" .. LINE_NUMBER_WIDTH .. "d %s ", number, marker)
end

--- Render one source line without colors; the current line is reversed.
local function render_plain_source_line(number, text, is_current, width)
    -- Expand tabs relative to the source text, not the screen row.
    local expanded = table.concat(to_display_chars(text))
    local row = format_line_prefix(number, is_current) .. expanded
    if is_current then
        return STYLE_REVERSE .. fit_row(row, width, true) .. STYLE_RESET
    end
    return fit_row(row, width)
end

--- Render one source line from highlighted `spans`; the current line
--- gets a grey background across the whole row.
local function render_colored_source_line(number, spans, is_current, width)
    local base_style = ""
    if is_current then
        base_style = CURRENT_LINE_BACKGROUND
    end
    local prefix = fit_row(format_line_prefix(number, is_current), width)
    local prefix_width = display_width(prefix)
    local body, used = fit_spans(spans, width - prefix_width, base_style)
    local padding = ""
    if is_current then
        padding = string.rep(" ", width - prefix_width - used)
    end
    -- The padding is spaces, so the last span's color does not show and
    -- the background from base_style is still active.
    return base_style .. prefix .. body .. padding .. STYLE_RESET
end

--- Return the highlighted spans of every line of `path` (cached).
local function get_source_spans(state, path, lines)
    local spans = state.highlight_cache[path]
    if not spans then
        spans = lua_highlight.highlight_lines(lines)
        state.highlight_cache[path] = spans
    end
    return spans
end

local function render_source_rows(state, width, height)
    local location = state.location
    if not location then
        return { fit_row(" (no location yet)", width) }
    end
    local lines = load_source_lines(state, location.path)
    if not lines then
        return { fit_row(" source not available: " .. location.path, width) }
    end
    local first = M.get_source_window_start(
        location.line, #lines, height, state.source_offset
    )
    local spans = state.color and get_source_spans(state, location.path, lines)
    local rows = {}
    for number = first, math.min(#lines, first + height - 1) do
        local is_current = number == location.line
        if spans then
            rows[#rows + 1] = render_colored_source_line(
                number, spans[number], is_current, width
            )
        else
            rows[#rows + 1] = render_plain_source_line(
                number, lines[number], is_current, width
            )
        end
    end
    return rows
end

--- Return the last `height` wrapped log rows, oldest first.
local function get_log_tail(state, width, height)
    local reversed = {}
    local index = #state.log_lines
    local pending = state.log_partial
    while #reversed < height and (pending ~= "" or index >= 1) do
        local text = pending
        if pending ~= "" then
            pending = ""
        else
            text = state.log_lines[index]
            index = index - 1
        end
        local pieces = wrap_text(text, width)
        for i = #pieces, math.max(1, #pieces - (height - #reversed) + 1), -1 do
            reversed[#reversed + 1] = pieces[i]
        end
    end
    local rows = {}
    for i = #reversed, 1, -1 do
        rows[#rows + 1] = reversed[i]
    end
    return rows
end

local function render_rule(title, width)
    local rule = RULE_CHAR .. title
    return fit_row(rule .. string.rep(RULE_CHAR, width), width)
end

local function put_row(out, row, text)
    out[#out + 1] = CSI .. row .. ";1H" .. text .. CLEAR_TO_EOL
end

local function put_rows(out, top, height, rows)
    for i = 1, height do
        put_row(out, top + i - 1, rows[i] or "")
    end
end

local function is_too_small(cols, rows)
    return cols < MIN_COLS or rows < MIN_ROWS
end

--- Build the input row (prompt, visible part of the editor, cursor).
--- The editor scrolls sideways so the cursor always stays on screen.
function M.render_input_row(state, cols, rows)
    local width = cols - 1
    local row = M.compute_layout(rows).input
    local prompt = fit_row(state.prompt, width)
    local available = math.max(1, width - display_width(prompt) - 1)
    local editor = state.editor
    local start = math.max(0, editor.cursor - available)
    local visible = table.concat(editor.chars, "", start + 1,
        math.min(#editor.chars, start + available))
    local cursor_column = display_width(prompt) + editor.cursor - start + 1
    return CSI .. row .. ";1H" .. prompt .. fit_row(visible, available)
        .. CLEAR_TO_EOL .. CSI .. row .. ";" .. cursor_column .. "H"
        .. SHOW_CURSOR
end

local function render_too_small(cols, rows)
    local out = {}
    local message = string.format(
        " Terminal too small (%dx%d, min %dx%d)",
        cols, rows, MIN_COLS, MIN_ROWS
    )
    put_rows(out, 1, rows, { fit_row(message, math.max(1, cols - 1)) })
    return table.concat(out)
end

--- Build a full frame for a `cols` x `rows` terminal as one string,
--- wrapped in synchronized-update escapes. `clear` adds a full clear
--- (only for startup and resize). Every row ends with "\27[K".
function M.render_frame(state, cols, rows, clear)
    local out = { SYNC_BEGIN, HIDE_CURSOR }
    if clear then
        out[#out + 1] = CLEAR_SCREEN
    end
    if is_too_small(cols, rows) then
        out[#out + 1] = render_too_small(cols, rows)
        out[#out + 1] = SYNC_END
        return table.concat(out)
    end
    local width = cols - 1
    local layout = M.compute_layout(rows)
    put_row(out, layout.header,
        STYLE_BOLD .. render_header(state, width) .. STYLE_RESET)
    put_rows(out, layout.source_top, layout.source_height,
        render_source_rows(state, width, layout.source_height))
    put_row(out, layout.log_rule, render_rule(" output ", width))
    put_rows(out, layout.log_top, layout.log_height,
        get_log_tail(state, width, layout.log_height))
    put_row(out, layout.input_rule, render_rule("", width))
    put_row(out, layout.help,
        STYLE_DIM .. fit_row(HELP_TEXT, width) .. STYLE_RESET)
    out[#out + 1] = M.render_input_row(state, cols, rows)
    out[#out + 1] = SYNC_END
    return table.concat(out)
end

-- =========================================================================
-- Terminal session (debugger and program I/O)
-- =========================================================================

local Session = {}
Session.__index = Session

--- Create a session around `termkit` and the debugger table `dbg`.
--- `stdout` defaults to io.stdout; tests pass a fake with write/flush.
function M.new_session(termkit, dbg, stdout)
    local session = setmetatable({}, Session)
    session.termkit = termkit
    session.dbg = dbg
    session.stdout = stdout or io.stdout
    session.state = M.new_state({ color = M.is_color_enabled(os.getenv) })
    session.cols, session.rows = termkit.size()
    session.saved_io = { print = print, write = io.write, read = io.read }
    session.program_io_installed = false
    session.program_output = {}
    session.frame_calls = 0
    session.last_frame_info = nil
    session.last_command = nil
    session.closed = false
    return session
end

function Session:draw(clear)
    local frame = M.render_frame(self.state, self.cols, self.rows, clear)
    self.stdout:write(frame)
    self.stdout:flush()
end

function Session:draw_input_row()
    if is_too_small(self.cols, self.rows) then
        self:draw()
        return
    end
    local row = M.render_input_row(self.state, self.cols, self.rows)
    self.stdout:write(SYNC_BEGIN, row, SYNC_END)
    self.stdout:flush()
end

--- Redraw with a full clear when the terminal size changed.
function Session:refresh_size()
    local cols, rows = self.termkit.size()
    if cols ~= self.cols or rows ~= self.rows then
        self.cols, self.rows = cols, rows
        self:draw(true)
    end
end

function Session:scroll_source(direction)
    local state = self.state
    local location = state.location
    local lines = location and load_source_lines(state, location.path)
    if not lines then
        return
    end
    local height = M.compute_layout(self.rows).source_height
    local offset = state.source_offset + direction * math.max(1, height - 1)
    local first = M.get_source_window_start(
        location.line, #lines, height, offset
    )
    state.source_offset = first - (location.line - math.floor(height / 2))
    self:draw()
end

--- Handle one key while reading a line.
--- Returns the finished line (nil for Ctrl-D on an empty line) and
--- whether reading is finished.
function Session:handle_key(key)
    local editor = self.state.editor
    if key == CTRL_D and #editor.chars == 0 then
        return nil, true
    end
    if key == "PAGE_UP" or key == "PAGE_DOWN" then
        local direction = 1
        if key == "PAGE_UP" then
            direction = -1
        end
        self:scroll_source(direction)
        return nil, false
    end
    if M.apply_editor_key(editor, key) == "submit" then
        return M.take_editor_line(editor), true
    end
    self:draw_input_row()
    return nil, false
end

--- Read one line in the input row. Returns the line, or nil when stdin
--- is closed or Ctrl-D is pressed on an empty line.
function Session:read_line()
    self:draw()
    while true do
        local key = self.termkit.read_key(POLL_INTERVAL_MS)
        if key == nil then
            self:refresh_size()
        elseif key == "EOF" then
            return nil
        else
            local line, finished = self:handle_key(key)
            if finished then
                return line
            end
        end
    end
end

-- -------------------------------------------------------------------------
-- Program I/O redirection (active only while the program runs)
-- -------------------------------------------------------------------------

local function join_print_args(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    return table.concat(parts, "\t") .. "\n"
end

local function join_write_args(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) ~= "string" and type(value) ~= "number" then
            error(string.format(
                "bad argument #%d to 'write' (string expected, got %s)",
                i, type(value)
            ), 3)
        end
        parts[i] = tostring(value)
    end
    return table.concat(parts)
end

function Session:capture_program_output(text)
    M.append_log(self.state, text)
    self.program_output[#self.program_output + 1] = text
end

function Session:install_program_io()
    if self.program_io_installed then
        return
    end
    rawset(_G, "print", function(...)
        self:capture_program_output(join_print_args(...))
    end)
    rawset(io, "write", function(...)
        self:capture_program_output(join_write_args(...))
        return io.stdout
    end)
    rawset(io, "read", function(...)
        return self:read_program_input(...)
    end)
    self.program_io_installed = true
end

function Session:restore_program_io()
    if not self.program_io_installed then
        return
    end
    rawset(_G, "print", self.saved_io.print)
    rawset(io, "write", self.saved_io.write)
    rawset(io, "read", self.saved_io.read)
    self.program_io_installed = false
end

--- Serve the program's io.read() from the input row.
--- Only line formats are supported; others raise an error.
function Session:read_program_input(...)
    local format = ...
    local suffix = LINE_READ_FORMATS[format or "*l"]
    if select("#", ...) > 1 or not suffix then
        error("luadbg --tui: only io.read() of one line is supported, got "
            .. "io.read(" .. tostring(format) .. ")", 2)
    end
    self:restore_program_io()
    local state = self.state
    state.status = "input"
    state.editor = state.input_editor
    state.prompt = PROGRAM_PROMPT
    local line = self:protect(self.read_line)
    if line then
        self:capture_program_output(line .. "\n")
    end
    state.status = "running"
    self:draw()
    self:install_program_io()
    if line == nil then
        return nil
    end
    return line .. suffix
end

-- -------------------------------------------------------------------------
-- Debugger hooks
-- -------------------------------------------------------------------------

local function describe_frame(info)
    if info.name then
        local kind = info.namewhat
        if kind == "" then
            kind = "function"
        end
        return string.format("in %s '%s'", kind, info.name)
    end
    if info.what == "main" then
        return "in main chunk"
    end
    return "in function"
end

--- Follow the frame the debugger last described, but only when exactly
--- one frame was described since the last command: a stop, u, d or i.
--- `t` describes every frame and must not move the source pane.
function Session:update_location()
    local info = self.last_frame_info
    if self.frame_calls == 1 and info then
        self.state.location = {
            path = info.source:match("^@(.*)$") or info.short_src,
            line = info.currentline,
            label = describe_frame(info),
        }
        self.state.source_offset = 0
    end
    self.frame_calls = 0
end

function Session:read_debugger_command()
    self:restore_program_io()
    self:update_location()
    local state = self.state
    state.status = "stopped"
    state.editor = state.command_editor
    state.prompt = DEBUGGER_PROMPT
    local line = self:read_line()
    if line then
        if line ~= "" then
            self.last_command = line
        end
        local shown = self.last_command or "h"
        M.append_log(state, DEBUGGER_PROMPT .. shown .. "\n")
    end
    state.status = "running"
    self:draw()
    self:install_program_io()
    return line
end

--- Run `method` on this session; on an internal error, restore the
--- terminal, report the error with a traceback and exit with status 1.
function Session:protect(method, ...)
    local results = { xpcall(method, debug.traceback, self, ...) }
    if not results[1] then
        self:close()
        io.stderr:write("luadbg: internal --tui error: ", results[2], "\n")
        os.exit(1)
    end
    return unpack(results, 2)
end

--- Route the debugger's output, input, frame descriptions and exit
--- through this session.
function Session:attach_debugger()
    local dbg = self.dbg
    dbg.use_color(false)
    dbg.auto_where = false
    local format_frame = dbg.format_stack_frame_info
    dbg.format_stack_frame_info = function(info)
        self.frame_calls = self.frame_calls + 1
        self.last_frame_info = info
        return format_frame(info)
    end
    dbg.write = function(text)
        self:restore_program_io()
        M.append_log(self.state, text)
    end
    dbg.read = function()
        return self:protect(self.read_debugger_command)
    end
    dbg.exit = function(code)
        self:close()
        os.exit(code)
    end
end

-- -------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------

function Session:wait_for_exit_key()
    local state = self.state
    state.editor = M.new_editor()
    state.prompt = EXIT_PROMPT
    self:draw()
    while true do
        local key = self.termkit.read_key(POLL_INTERVAL_MS)
        if key ~= nil then
            return
        end
        self:refresh_size()
    end
end

--- Leave the TUI, then print the program's output to the normal screen
--- so it is not lost with the alternate screen. Safe to call twice.
function Session:close()
    if self.closed then
        return
    end
    self.closed = true
    self:restore_program_io()
    self.termkit.leave()
    self.stdout:write(table.concat(self.program_output))
    if self.state.exit_message then
        io.stderr:write("luadbg: program ", self.state.exit_message, "\n")
    end
    self.stdout:flush()
end

--- Run the script and record how it ended. Returns the exit status.
function Session:run_script(chunk, script_args)
    self:install_program_io()
    local ok, err = self.dbg.call(chunk, unpack(script_args))
    self:restore_program_io()
    local state = self.state
    state.status = "exited"
    if ok then
        state.exit_message = "exited normally"
        return 0
    end
    state.exit_message = "raised an error"
    M.append_log(state, "error: " .. tostring(err) .. "\n")
    return 1
end

-- =========================================================================
-- Entry points
-- =========================================================================

--- Return true when the TUI can run here, or nil and the reason.
function M.check_terminal()
    if require("ffi").os == "Windows" then
        return nil, "--tui is not supported on Windows; "
            .. "run luadbg without --tui"
    end
    if not require("termkit").is_tty() then
        return nil, "--tui needs an interactive terminal "
            .. "(stdin and stdout must be a TTY)"
    end
    return true
end

--- Run `chunk` with `script_args` under debugger `dbg` inside the TUI.
--- Returns the exit status (0 finished, 1 script error), or nil and an
--- error message when the terminal could not be set up.
function M.run(dbg, chunk, script_args)
    local termkit = require("termkit")
    local session = M.new_session(termkit, dbg)
    if not termkit.enter() then
        return nil, "--tui could not switch the terminal to raw mode"
    end
    session:attach_debugger()
    session:draw(true)
    local status = session:protect(session.run_script, chunk, script_args)
    session:protect(session.wait_for_exit_key)
    session:close()
    return status
end

return M
