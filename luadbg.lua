#!/usr/bin/env luajit
-- luadbg.lua: run any LuaJIT script under debugger.lua (vendored).
--
-- Usage:
--   luajit luadbg.lua [--on-error] [--where N] [--tui [--theme NAME]]
--                     <script.lua> [args...]
--
-- Default mode stops at the script's first line. --on-error runs the
-- script normally and stops at the line that raised an error.
-- Every stop shows N source lines around the current line (default 2;
-- --where 0 turns it off). --tui shows the source in a top pane and
-- takes commands in a bottom pane instead (see luadbg_tui.lua); --theme
-- picks its colors (dark, light, plain; LUADBG_THEME sets a default).
-- The JIT is turned off so line stepping is reliable.

-- =========================================================================
-- Constants
-- =========================================================================

local USAGE = "usage: luajit luadbg.lua [--on-error] [--where N] "
    .. "[--tui [--theme NAME]] <script.lua> [args...]"
local DEFAULT_WHERE_LINES = 2
local EXIT_USAGE = 2
local EXIT_SCRIPT_ERROR = 1

-- =========================================================================
-- Helpers
-- =========================================================================

--- Return the directory part of `path`, or "." when it has none.
local function get_directory(path)
    return path:match("^(.*)[/\\]") or "."
end

--- Write `message` to stderr with the luadbg prefix and exit with `code`.
local function fail(message, code)
    io.stderr:write("luadbg: ", message, "\n")
    os.exit(code)
end

--- Return `text` as a non-negative integer line count, or nil.
local function parse_where_lines(text)
    if text and text:match("^%d+$") then
        return tonumber(text)
    end
    return nil
end

--- Read the leading luadbg options from `argv` into `options`.
--- Returns the position of the first non-option argument, or nil and an
--- error message for an invalid option value.
local function parse_options(argv, options)
    local position = 1
    while true do
        local option = argv[position]
        if option == "--on-error" then
            options.on_error = true
            position = position + 1
        elseif option == "--where" then
            local value = argv[position + 1]
            options.where_lines = parse_where_lines(value)
            if not options.where_lines then
                return nil, "invalid --where value: " .. (value or "(missing)")
            end
            position = position + 2
        elseif option == "--tui" then
            options.tui = true
            position = position + 1
        elseif option == "--theme" then
            options.theme = argv[position + 1]
            if not options.theme then
                return nil, "missing value for --theme"
            end
            position = position + 2
        else
            return position
        end
    end
end

--- Split the command line into options, the script path and its args.
--- Returns a table { on_error, where_lines, script_path, script_args },
--- or nil plus an optional error message when the command line is invalid
--- (the message is nil when only the script path is missing).
local function parse_command_line(argv)
    local options = { on_error = false, where_lines = DEFAULT_WHERE_LINES }
    local first, err = parse_options(argv, options)
    if not first then
        return nil, err
    end
    local script_path = argv[first]
    if not script_path then
        return nil
    end
    local script_args = { [0] = script_path }
    for i = first + 1, #argv do
        script_args[#script_args + 1] = argv[i]
    end
    options.script_path = script_path
    options.script_args = script_args
    return options
end

--- Load `script_path` as a function, optionally starting with a
--- debugger break. Returns the chunk, or nil and an error message.
local function load_script(script_path, break_at_start)
    local file, open_err = io.open(script_path, "rb")
    if not file then
        return nil, "cannot open script: " .. open_err
    end
    local source = file:read("*a")
    file:close()

    -- Drop a shebang but keep its line, so line numbers stay unchanged.
    source = source:gsub("^#[^\n]*", "")
    if break_at_start then
        source = 'require("debugger")() ' .. source
    end

    local chunk, load_err = loadstring(source, "@" .. script_path)
    if not chunk then
        return nil, "cannot load script: " .. load_err
    end
    return chunk
end

--- Return `self_path`, 1-based `argv`, and `is_luvit` for LuaJIT or Luvit.
local function get_cli_args()
    if arg then
        return arg[0], arg, false
    end
    local luvit_args = args -- luacheck: ignore 113 (luvit global)
    local argv = {}
    for i = 2, #luvit_args do
        argv[#argv + 1] = luvit_args[i]
    end
    return luvit_args[1] or "luadbg.lua", argv, true
end

--- Build Luvit's 1-based `args` table (`args[1]` is the script path).
local function build_luvit_args(script_path, script_args)
    local luvit_args = { script_path }
    for i = 1, #script_args do
        luvit_args[#luvit_args + 1] = script_args[i]
    end
    return luvit_args
end

--- Bind Luvit's per-file `require` and `module` onto `chunk`.
local function setup_luvit_env(chunk, script_path)
    local abs_path = require("path").resolve(script_path)
    local script_require, script_module = require("require")(abs_path)
    local env = setmetatable({
        require = script_require,
        module = script_module
    }, { __index = _G, __newindex = _G })
    setfenv(chunk, env)
end

--- Wrap `chunk` so Luvit's libuv event loop runs before `os.exit`.
local function wrap_luvit_event_loop(chunk)
    local uv = require("uv")
    return function(...)
        local results = { chunk(...) }
        uv.run()
        return unpack(results)
    end
end

--- Build a `dbg.read` replacement for Luvit CLI mode on POSIX.
--- Luvit sets a TTY stdin to O_NONBLOCK, so `io.read()` returns EAGAIN;
--- waiting on `poll(0, POLLIN, -1)` blocks cleanly until a line is ready.
local function make_luvit_reader(dbg_write)
    local ffi = require("ffi")
    if ffi.os == "Windows" then
        return nil
    end
    pcall(ffi.cdef, [[
        struct luadbg_pollfd { int fd; short events; short revents; };
        int poll(struct luadbg_pollfd *fds, unsigned long nfds, int timeout);
    ]])
    local pfd = ffi.new("struct luadbg_pollfd[1]")
    pfd[0].fd = 0
    pfd[0].events = 1
    return function(prompt)
        dbg_write(prompt)
        io.stderr:flush()
        while true do
            local line, err = io.read()
            if line ~= nil or err == nil then
                return line
            end
            ffi.C.poll(pfd, 1, -1)
        end
    end
end

-- =========================================================================
-- Entry point
-- =========================================================================

local self_path, cli_argv, is_luvit = get_cli_args()
local options, parse_err = parse_command_line(cli_argv)
if not options then
    if parse_err then
        io.stderr:write("luadbg: ", parse_err, "\n")
    end
    fail(USAGE, EXIT_USAGE)
end

-- Find debugger.lua next to this file, and the script's own modules.
local script_dir = get_directory(options.script_path)
package.path = get_directory(self_path) .. "/?.lua;"
    .. script_dir .. "/?.lua;"
    .. package.path

local tui, tui_options
if options.tui then
    tui = require("luadbg_tui")
    -- Check the theme before the terminal so a typo is reported first.
    local theme, message = tui.resolve_theme(options.theme, os.getenv)
    if not theme then
        fail(message, EXIT_USAGE)
    end
    if message then
        io.stderr:write("luadbg: ", message, "\n")
    end
    tui_options = { theme = theme, warning = message }
    local supported, tui_err = tui.check_terminal()
    if not supported then
        fail(tui_err, EXIT_USAGE)
    end
elseif options.theme then
    fail("--theme only applies with --tui", EXIT_USAGE)
end

local dbg = require("debugger")
require("jit").off()
if is_luvit and not tui then
    local reader = make_luvit_reader(dbg.write)
    if reader then
        dbg.read = reader
    end
end
if options.where_lines > 0 then
    -- Print this many source lines around the current line at each stop.
    dbg.auto_where = options.where_lines
end

local chunk, err = load_script(options.script_path, not options.on_error)
if not chunk then
    fail(err, EXIT_USAGE)
end
if is_luvit then
    setup_luvit_env(chunk, options.script_path)
end

local mode = options.on_error and "stop on error" or "stop at first line"
io.stderr:write(
    "luadbg: debugging ", options.script_path,
    " (", mode, ", JIT off)\n"
)

-- The script sees its own path in arg[0] (and args[1] under Luvit).
arg = options.script_args -- luacheck: ignore 121 (scripts read global arg)
if is_luvit then
    _G.args = build_luvit_args(options.script_path, options.script_args)
end

if tui then
    local run_chunk = chunk
    if is_luvit then
        run_chunk = wrap_luvit_event_loop(chunk)
    end
    -- The TUI always runs the script inside dbg.call, so a script error
    -- stops in the debugger instead of leaving the terminal in raw mode.
    local status, run_err = tui.run(
        dbg, run_chunk, options.script_args, tui_options
    )
    if not status then
        fail(run_err, EXIT_SCRIPT_ERROR)
    end
    os.exit(status)
end

if not options.on_error then
    -- Tail call keeps the stack as shallow as a direct run, which
    -- scripts using a debug.getlocal "am I main?" check rely on.
    return chunk(unpack(options.script_args))
end

local run_chunk = chunk
if is_luvit then
    run_chunk = wrap_luvit_event_loop(chunk)
end
local ok = dbg.call(run_chunk, unpack(options.script_args))
os.exit(ok and 0 or EXIT_SCRIPT_ERROR)
