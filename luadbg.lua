#!/usr/bin/env luajit
-- luadbg.lua: run any LuaJIT script under debugger.lua (vendored).
--
-- Usage:
--   luajit luadbg.lua [--on-error] [--where N] <script.lua> [args...]
--
-- Default mode stops at the script's first line. --on-error runs the
-- script normally and stops at the line that raised an error.
-- Every stop shows N source lines around the current line (default 2;
-- --where 0 turns it off). The JIT is turned off so line stepping is
-- reliable.

-- =========================================================================
-- Constants
-- =========================================================================

local USAGE = "usage: luajit luadbg.lua [--on-error] [--where N] "
    .. "<script.lua> [args...]"
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

-- =========================================================================
-- Entry point
-- =========================================================================

local options, parse_err = parse_command_line(arg)
if not options then
    if parse_err then
        io.stderr:write("luadbg: ", parse_err, "\n")
    end
    fail(USAGE, EXIT_USAGE)
end

-- Find debugger.lua next to this file, and the script's own modules.
local script_dir = get_directory(options.script_path)
package.path = get_directory(arg[0]) .. "/?.lua;"
    .. script_dir .. "/?.lua;"
    .. package.path

local dbg = require("debugger")
require("jit").off()
if options.where_lines > 0 then
    -- Print this many source lines around the current line at each stop.
    dbg.auto_where = options.where_lines
end

local chunk, err = load_script(options.script_path, not options.on_error)
if not chunk then
    fail(err, EXIT_USAGE)
end

local mode = options.on_error and "stop on error" or "stop at first line"
io.stderr:write(
    "luadbg: debugging ", options.script_path,
    " (", mode, ", JIT off)\n"
)

-- The script sees its own path in arg[0], as if run directly.
arg = options.script_args -- luacheck: ignore 121 (scripts read global arg)

if not options.on_error then
    -- Tail call keeps the stack as shallow as a direct run, which
    -- scripts using a debug.getlocal "am I main?" check rely on.
    return chunk(unpack(options.script_args))
end

local ok = dbg.call(chunk, unpack(options.script_args))
os.exit(ok and 0 or EXIT_SCRIPT_ERROR)
