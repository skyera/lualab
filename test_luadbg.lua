#!/usr/bin/env luajit
-- test_luadbg.lua: drives luadbg.lua by piping debugger commands into it.
-- POSIX only: uses sh, printf, mkdir, and rm through io.popen/os.execute.

-- =========================================================================
-- Constants
-- =========================================================================

local LUAJIT = (arg and arg[-1]) or "luajit"

local SAMPLE_SOURCE = [[
#!/usr/bin/env luajit
local helper = require("luadbg_helper")

local function add(a, b)
    return a + b
end

local total = add(1, 2)
print("total", total, helper.name, arg[0], arg[1])
]]

local HELPER_SOURCE = 'return { name = "helper-ok" }\n'
local BOOM_SOURCE = "local t = nil\nprint(t.x)\n"
local BAD_SOURCE = "local x =\n"

-- =========================================================================
-- Helpers
-- =========================================================================

local tests_run = 0
local tests_passed = 0

local function check(condition, description)
    tests_run = tests_run + 1
    if condition then
        tests_passed = tests_passed + 1
        print("  [PASS] " .. description)
    else
        print("  [FAIL] " .. description)
    end
end

local function shell_quote(text)
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function write_file(path, content)
    local file = assert(io.open(path, "w"))
    file:write(content)
    file:close()
end

local function read_command(command)
    local pipe = assert(io.popen(command))
    local output = pipe:read("*a")
    pipe:close()
    return output
end

local function make_temp_directory()
    local path = os.tmpname()
    os.remove(path)
    assert(os.execute("mkdir " .. shell_quote(path)) == 0)
    return path
end

local function contains(text, fragment)
    return text:find(fragment, 1, true) ~= nil
end

--- Return the numbers of the source lines printed at the stop whose
--- location line contains `marker`, in the order shown.
local function get_shown_source_lines(output, marker)
    local start = output:find(marker, 1, true)
    if not start then
        return {}
    end
    local block_end = output:find("debugger.lua>", start, true) or #output
    local block = output:sub(start, block_end)
    local line_numbers = {}
    for number in block:gmatch("\n%s*(%d+)[ =]") do
        line_numbers[#line_numbers + 1] = tonumber(number)
    end
    return line_numbers
end

-- Absolute path, so tests can run luadbg.lua from other directories.
local LUADBG_PATH = read_command("pwd"):gsub("%s+$", "") .. "/luadbg.lua"

--- Run luadbg.lua from `directory` with `debugger_input` on stdin and
--- `arguments` (already shell-quoted) on its command line.
--- Returns the combined stdout/stderr text and the exit status.
local function run_luadbg(directory, debugger_input, arguments, interpreter)
    local runtime = interpreter or LUAJIT
    local command = string.format(
        "cd %s && printf %s | DBG_NOCOLOR=1 %s %s %s 2>&1; echo \"EXIT=$?\"",
        shell_quote(directory),
        shell_quote(debugger_input),
        shell_quote(runtime),
        shell_quote(LUADBG_PATH),
        arguments
    )
    local output = read_command(command)
    local status = tonumber(output:match("EXIT=(%d+)%s*$"))
    return output, status
end

-- =========================================================================
-- Fixtures
-- =========================================================================

local repo_dir = LUADBG_PATH:match("^(.*)/")
local fixture_dir = make_temp_directory()
local other_dir = make_temp_directory()
write_file(fixture_dir .. "/sample.lua", SAMPLE_SOURCE)
write_file(fixture_dir .. "/luadbg_helper.lua", HELPER_SOURCE)
write_file(fixture_dir .. "/boom.lua", BOOM_SOURCE)
write_file(fixture_dir .. "/bad.lua", BAD_SOURCE)
local sample_path = fixture_dir .. "/sample.lua"

-- =========================================================================
-- Tests
-- =========================================================================

print("Test 1: default mode stops at the first line and can step")
do
    local output, status = run_luadbg(
        other_dir,
        "s\ns\ns\ns\np a + b\nf\nc\n",
        shell_quote(sample_path) .. " X"
    )
    check(contains(output, "stop at first line, JIT off"),
        "startup line names the mode")
    check(contains(output, "break via dbg() => " .. sample_path .. ":2"),
        "breaks at line 2, below the shebang")
    check(contains(output, "sample.lua:5 in local 'add'"),
        "s steps into add()")
    check(contains(output, "a + b => 3"), "p evaluates an expression")
    check(contains(output, "total\t3\thelper-ok\t" .. sample_path .. "\tX"),
        "sibling require, arg[0] and arg[1] work from another directory")
    check(status == 0, "exit status is 0")
end

print("Test 2: --on-error stops at the failing line")
do
    local boom_path = fixture_dir .. "/boom.lua"
    local output, status = run_luadbg(
        other_dir,
        "p t\nc\n",
        "--on-error " .. shell_quote(boom_path)
    )
    check(contains(output, "stop on error, JIT off"),
        "startup line names the mode")
    check(contains(output, "attempt to index local 't' (a nil value)"),
        "error message is shown")
    check(contains(output, "break via dbg.call() => " .. boom_path .. ":2"),
        "breaks at the failing line")
    check(contains(output, "t => nil"), "locals are inspectable")
    check(status == 1, "exit status is 1")
end

print("Test 3: invalid invocations fail with a message and exit 2")
do
    local output, status = run_luadbg(other_dir, "", "")
    check(contains(output, "luadbg: usage: luajit luadbg.lua"),
        "no arguments prints usage")
    check(status == 2, "no arguments exits 2")

    local missing = fixture_dir .. "/missing.lua"
    output, status = run_luadbg(other_dir, "", shell_quote(missing))
    check(contains(output, "luadbg: cannot open script: " .. missing),
        "missing script is reported with its path")
    check(status == 2, "missing script exits 2")

    output, status = run_luadbg(
        other_dir, "", shell_quote(fixture_dir .. "/bad.lua")
    )
    check(contains(output, "luadbg: cannot load script: "),
        "syntax error is reported")
    check(contains(output, "bad.lua:2:"), "syntax error keeps the line")
    check(status == 2, "syntax error exits 2")
end

print("Test 4: a script's own main check still sees a direct run")
do
    local tasks_path = other_dir .. "/tasks.txt"
    local arguments = shell_quote(repo_dir .. "/oop_todo.lua")
        .. " " .. shell_quote(tasks_path)
    local output, status = run_luadbg(
        other_dir, "c\nadd hello\nquit\n", arguments
    )
    check(contains(output, "Added:\t[ ] hello"), "oop_todo.lua CLI runs")
    check(status == 0, "exit status is 0")
end

print("Test 5: --where controls the source shown at each stop")
do
    local step_into_add = "s\ns\ns\ns\nc\n"
    local add_marker = "in local 'add'"
    local output = run_luadbg(
        other_dir, step_into_add, shell_quote(sample_path)
    )
    local shown = get_shown_source_lines(output, add_marker)
    check(contains(output, "   5 =>     return a + b"),
        "default marks the current line with =>")
    check(table.concat(shown, ",") == "3,4,5,6,7",
        "default shows 2 lines of context")

    output = run_luadbg(
        other_dir, step_into_add, "--where 4 " .. shell_quote(sample_path)
    )
    shown = get_shown_source_lines(output, add_marker)
    check(table.concat(shown, ",") == "1,2,3,4,5,6,7,8,9",
        "--where 4 shows 4 lines of context")

    output = run_luadbg(
        other_dir, step_into_add, "--where 0 " .. shell_quote(sample_path)
    )
    check(contains(output, add_marker), "--where 0 still reports the stop")
    check(not output:find("%d =>"), "--where 0 shows no source")

    local boom_path = shell_quote(fixture_dir .. "/boom.lua")
    for _, arguments in ipairs({
        "--where 1 --on-error " .. boom_path,
        "--on-error --where 1 " .. boom_path,
    }) do
        output = run_luadbg(other_dir, "c\n", arguments)
        shown = get_shown_source_lines(output, "boom.lua:2 in")
        check(table.concat(shown, ",") == "1,2",
            "options in any order: " .. arguments:match("^%S+ %S+ %S+"))
    end

    for _, value in ipairs({ "-1", "abc" }) do
        local status
        output, status = run_luadbg(
            other_dir, "", "--where " .. value .. " "
                .. shell_quote(sample_path)
        )
        check(contains(output, "luadbg: invalid --where value: " .. value)
            and contains(output, "luadbg: usage:") and status == 2,
            "--where " .. value .. " is rejected with usage, exit 2")
    end
    local status
    output, status = run_luadbg(other_dir, "", "--where")
    check(contains(output, "luadbg: invalid --where value: (missing)")
        and status == 2,
        "--where without a value is rejected, exit 2")
end

print("Test 6: --theme is validated before the terminal check")
do
    local script = shell_quote(sample_path)
    local cases = {
        {
            arguments = "--tui --theme neon " .. script,
            message = "luadbg: unknown theme 'neon' (choose dark, light, "
                .. "plain)",
            label = "unknown --theme",
        },
        {
            arguments = "--theme neon --tui " .. script,
            message = "luadbg: unknown theme 'neon'",
            label = "unknown --theme before --tui",
        },
        {
            arguments = "--theme dark " .. script,
            message = "luadbg: --theme only applies with --tui",
            label = "--theme without --tui",
        },
        {
            arguments = "--tui --theme",
            message = "luadbg: missing value for --theme",
            label = "--theme without a value",
        },
    }
    for _, case in ipairs(cases) do
        local output, status = run_luadbg(other_dir, "", case.arguments)
        check(contains(output, case.message) and status == 2,
            case.label .. " is rejected with a message, exit 2")
    end
    local output, status = run_luadbg(other_dir, "",
        "--tui --theme light " .. script)
    check(contains(output, "--tui needs an interactive terminal")
        and status == 2, "a valid --theme reaches the terminal check")
end

print("Test 7: luvit runtime supports relative require, uv, and --on-error")
do
    local has_luvit = os.execute("command -v luvit >/dev/null 2>&1") == 0
    if not has_luvit then
        print("  [SKIP] luvit is not installed")
    else
        local luvit_sample = fixture_dir .. "/luvit_sample.lua"
        write_file(luvit_sample, [[
local uv = require("uv")
local helper = require("./luadbg_helper")
local timer = uv.new_timer()
timer:start(1, 0, function()
    print("timer-ok", helper.name, args[2])
    timer:close()
end)
]])
        local output, status = run_luadbg(
            other_dir,
            "c\n",
            shell_quote(luvit_sample) .. " hello",
            "luvit"
        )
        check(contains(output, "timer-ok\thelper-ok\thello") and status == 0,
            "luvit runs relative require, args, and uv timer callback")

        local err_out, err_status = run_luadbg(
            other_dir,
            "c\n",
            "--on-error " .. shell_quote(fixture_dir .. "/boom.lua"),
            "luvit"
        )
        check(contains(err_out, "attempt to index local 't'")
            and err_status == 1,
            "luvit --on-error stops on script error and exits 1")
    end
end

os.execute("rm -rf " .. shell_quote(fixture_dir) .. " "
    .. shell_quote(other_dir))
print(string.format("%d / %d passed", tests_passed, tests_run))
if tests_passed ~= tests_run then
    os.exit(1)
end
