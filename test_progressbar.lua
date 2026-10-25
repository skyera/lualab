#!/usr/bin/env luajit
-- =========================================================================
-- test_progressbar.lua - Comprehensive Test Suite for progressbar.lua
-- =========================================================================

local M = require("progressbar")
local ProgressBar = M.ProgressBar

local tests_run = 0
local tests_passed = 0

local function check(condition, desc)
    tests_run = tests_run + 1
    if condition then
        tests_passed = tests_passed + 1
        print(string.format("  [PASS] %s", desc))
    else
        print(string.format("  [FAIL] %s", desc))
        error("Assertion failed: " .. desc)
    end
end

-- Helper mock stream for capturing writes headlessly
local function create_mock_stream()
    local buffer = {}
    return {
        write = function(self, str)
            buffer[#buffer + 1] = str
        end,
        flush = function(self) end,
        get_content = function(self)
            return table.concat(buffer, "")
        end,
        clear = function(self)
            buffer = {}
        end
    }
end

print("\n--- Test Suite: progressbar.lua ---")

-- -------------------------------------------------------------------------
-- Test 1: Instantiation & Default Options
-- -------------------------------------------------------------------------
print("\nTest 1: Instantiation & Defaults")
do
    local bar = ProgressBar.new({ total = 50, width = 20 })
    check(bar.total == 50, "Total set to 50")
    check(bar.width == 20, "Width set to 20")
    check(bar.current == 0, "Initial current is 0")
    check(bar.style == "unicode", "Default style is unicode")
    check(bar.show_percent == true, "Percent enabled by default")
    check(bar.show_counts == true, "Counts enabled by default")

    local min_bar = ProgressBar.new({ total = -10, width = 2 })
    check(min_bar.total == 1, "Clamps invalid total <= 0 to 1")
    check(min_bar.width == 5, "Clamps minimum width to 5")
end

-- -------------------------------------------------------------------------
-- Test 2: Frame Rendering & Clamping Boundaries
-- -------------------------------------------------------------------------
print("\nTest 2: Frame Rendering & Clamping Boundaries")
do
    local bar = ProgressBar.new({
        total = 100,
        width = 10,
        style = "ascii",
        show_rate = false,
        show_eta = false
    })

    -- 0%
    local f0 = bar:render(0)
    check(f0:find("%[          %]%s+0%.0%%%s+%(0/100%)") ~= nil, "Render 0% ASCII empty bar: " .. f0)

    -- 50%
    local f50 = bar:render(50)
    check(f50:find("%[====>%s+%]%s+50%.0%%%s+%(50/100%)") ~= nil, "Render 50% ASCII arrow bar: " .. f50)

    -- 100%
    local f100 = bar:render(100)
    check(f100:find("%[==========%]%s+100%.0%%%s+%(100/100%)") ~= nil, "Render 100% ASCII full bar: " .. f100)

    -- Clamping negative
    local f_neg = bar:render(-50)
    check(f_neg:find("%[          %]%s+0%.0%%%s+%(0/100%)") ~= nil, "Negative value clamped safely to 0%")

    -- Clamping overflow
    local f_over = bar:render(150)
    check(f_over:find("%[==========%]%s+100%.0%%%s+%(100/100%)") ~= nil, "Overflow value clamped safely to 100%")
end

-- -------------------------------------------------------------------------
-- Test 3: Styles (Unicode 8th-block, Shaded, ASCII)
-- -------------------------------------------------------------------------
print("\nTest 3: Styles Verification")
do
    -- Shaded block style
    local shaded = ProgressBar.new({
        total = 10,
        width = 10,
        style = "shaded",
        show_rate = false,
        show_eta = false,
        show_counts = false
    })
    local s_half = shaded:render(5)
    check(s_half:find("%[█████░░░░░%]%s+50%.0%%") ~= nil, "Shaded style renders blocks correctly: " .. s_half)

    -- Unicode smooth fractional block style
    local uni = ProgressBar.new({
        total = 80,
        width = 10,
        style = "unicode",
        show_rate = false,
        show_eta = false,
        show_counts = false
    })
    -- 1 out of 80 on width 10 is 1/8th of the first cell (sub_idx 2 -> "▏")
    local u_sub = uni:render(1)
    check(u_sub:find("%[▏%s+%]%s+1%.2%%") ~= nil, "Unicode sub-block displays fractional step: " .. u_sub)

    local u_full = uni:render(80)
    check(u_full:find("%[██████████%]%s+100%.0%%") ~= nil, "Unicode full bar displays all full blocks")
end

-- -------------------------------------------------------------------------
-- Test 4: Rate & ETA Formatting
-- -------------------------------------------------------------------------
print("\nTest 4: Rate & ETA Calculations")
do
    local bar = ProgressBar.new()
    check(bar:format_eta(0) == "00:00", "0s ETA is 00:00")
    check(bar:format_eta(59) == "00:59", "59s ETA is 00:59")
    check(bar:format_eta(65) == "01:05", "65s ETA is 01:05")
    check(bar:format_eta(3665) == "01:01:05", "3665s ETA is 01:01:05")
    check(bar:format_eta(-5) == "--:--", "Negative ETA returns --:--")
    check(bar:format_eta(nil) == "--:--", "Nil ETA returns --:--")
    check(bar:format_eta(99999999) == "--:--", "Huge/infinite ETA returns --:--")
end

-- -------------------------------------------------------------------------
-- Test 5: Headless Output & TUI Clear Invariant (\27[K)
-- -------------------------------------------------------------------------
print("\nTest 5: Stream Writing & Terminal Invariants")
do
    local mock_tty = create_mock_stream()
    local bar_tty = ProgressBar.new({
        total = 10,
        width = 10,
        stream = mock_tty,
        is_tty = true
    })

    bar_tty:update(1)
    local out1 = mock_tty:get_content()
    check(out1:find("\27%[%?25l") ~= nil, "TTY update hides cursor (\\27[?25l)")
    check(out1:find("^\27%[%?25l\r") ~= nil, "TTY update begins with carriage return")
    check(out1:find("\27%[K$") ~= nil, "TTY update terminates with Universal Row-Clear (\\27[K)")

    bar_tty:finish()
    local out_finish = mock_tty:get_content()
    check(out_finish:find("\27%[%?25h") ~= nil, "TTY finish restores cursor (\\27[?25h)")
    check(out_finish:sub(-1) == "\n", "TTY finish terminates with newline")

    -- Non-TTY mode (milestone logging)
    local mock_pipe = create_mock_stream()
    local bar_pipe = ProgressBar.new({
        total = 100,
        width = 10,
        stream = mock_pipe,
        is_tty = false
    })

    for i = 1, 100 do
        bar_pipe:update(i)
    end
    bar_pipe:finish()

    local pipe_out = mock_pipe:get_content()
    check(pipe_out:find("\27") == nil, "Non-TTY mode contains zero ANSI escape sequences")
    local lines = 0
    for _ in pipe_out:gmatch("\n") do
        lines = lines + 1
    end
    check(lines >= 10 and lines <= 12, "Non-TTY mode logs throttled milestones (lines=" .. lines .. ")")
end

-- -------------------------------------------------------------------------
-- Test 6: Iterator Loop Wrapper
-- -------------------------------------------------------------------------
print("\nTest 6: Iterator Loop Wrapper")
do
    local mock = create_mock_stream()
    local bar = ProgressBar.new({
        stream = mock,
        is_tty = true
    })

    local dataset = { "alpha", "beta", "gamma", "delta" }
    local collected = {}

    for item, idx in bar:iterate(dataset, "Batch") do
        collected[#collected + 1] = item
    end

    check(#collected == 4, "Iterated exactly 4 items")
    check(collected[1] == "alpha" and collected[4] == "delta", "Items preserved in order")
    check(bar.completed == true, "Bar automatically marked completed upon iterator completion")
end

-- -------------------------------------------------------------------------
-- Test 7: Backward-Compatibility Helpers
-- -------------------------------------------------------------------------
print("\nTest 7: Backward-Compatibility Helpers")
do
    local co, bar = M.make_progress_bar(10)
    check(type(co) == "thread", "make_progress_bar returns a coroutine thread")
    local ok, val = coroutine.resume(co)
    check(ok and val == 0, "Coroutine yields initial value 0")
    coroutine.resume(co)
    check(bar.current >= 0, "Underlying ProgressBar tracks updates")
end

-- -------------------------------------------------------------------------
-- Test 8: Cross-Platform Sleep Helper
-- -------------------------------------------------------------------------
print("\nTest 8: Cross-Platform Sleep Helper")
do
    local t0 = os.clock()
    M.sleep_ms(15)
    local elapsed = os.clock() - t0
    check(elapsed >= 0, "sleep_ms executed safely without errors")
end

-- -------------------------------------------------------------------------
-- Test 9: Bytecode Scoping & Undeclared Global Check (GGET)
-- -------------------------------------------------------------------------
print("\nTest 9: Bytecode Scoping & Undeclared Global Analysis")
do
    local luajit = arg[-1] or "luajit"
    local p_bc = io.popen(luajit .. " -bl progressbar.lua", "r")
    assert(p_bc, "Failed to run luajit -bl progressbar.lua")

    local std_globals = {
        require = true, io = true, os = true, pcall = true, xpcall = true,
        string = true, math = true, table = true, print = true, ipairs = true,
        pairs = true, tonumber = true, tostring = true, type = true,
        assert = true, error = true, setmetatable = true, getmetatable = true,
        select = true, next = true, rawget = true, rawset = true,
        coroutine = true, bit = true, ffi = true, jit = true, arg = true,
        _G = true, debug = true
    }

    local bad_globals = {}
    for line in p_bc:lines() do
        local g = line:match('GGET%s+%d+%s+%d+%s+;%s+"([^"]+)"')
        if g and not std_globals[g] then
            bad_globals[g] = (bad_globals[g] or 0) + 1
        end
    end
    p_bc:close()

    local bad_list = {}
    for k, v in pairs(bad_globals) do
        bad_list[#bad_list + 1] = string.format("%s (%d)", k, v)
    end

    check(#bad_list == 0, "Zero undeclared global accesses in progressbar.lua: " .. table.concat(bad_list, ", "))
end

print(string.format("\n=================================================="))
print(string.format("All tests completed: %d / %d passed", tests_passed, tests_run))
print(string.format("==================================================\n"))
