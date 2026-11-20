#!/usr/bin/env luajit
-- test_lua_highlight.lua: token kinds, look-alikes, multi-line long
-- brackets, the round-trip invariant on every repo Lua file, and speed.

local lua_highlight = require("lua_highlight")

-- =========================================================================
-- Constants
-- =========================================================================

local LARGE_FILE = "codefind.lua"
local LARGE_FILE_SECONDS = 1.0

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

--- Describe spans as "kind<text>" pieces joined by spaces.
local function describe(spans)
    local parts = {}
    for _, span in ipairs(spans) do
        parts[#parts + 1] = span.kind .. "<" .. span.text .. ">"
    end
    return table.concat(parts, " ")
end

local function highlight_one(line)
    return describe(lua_highlight.highlight_lines({ line })[1])
end

--- Check that `line` produces exactly the span description `expected`.
local function check_line(line, expected, description)
    local actual = highlight_one(line)
    check(actual == expected, description)
    if actual ~= expected then
        print("      expected: " .. expected)
        print("      actual:   " .. actual)
    end
end

local function read_lines(path)
    local file = assert(io.open(path, "rb"))
    local lines = {}
    for line in file:lines() do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    file:close()
    return lines
end

local function join_spans(spans)
    local parts = {}
    for _, span in ipairs(spans) do
        parts[#parts + 1] = span.text
    end
    return table.concat(parts)
end

-- =========================================================================
-- Tests
-- =========================================================================

print("Test 1: token kinds")
check_line("local x = nil",
    "keyword<local> plain< x = > constant<nil>", "keyword and constant")
check_line("if not self then return true end",
    "keyword<if> plain< > keyword<not> plain< > constant<self> plain< > "
        .. "keyword<then> plain< > keyword<return> plain< > constant<true> "
        .. "plain< > keyword<end>", "self, true and control keywords")
check_line("print(#t, 0x1F, 1e-3, .5, 3.14, 10ULL)",
    "builtin<print> plain<(#t, > number<0x1F> plain<, > number<1e-3> "
        .. "plain<, > number<.5> plain<, > number<3.14> plain<, > "
        .. "number<10ULL> plain<)>", "builtin and number forms")
check_line('x = "a\\"b" .. \'c\' -- done',
    'plain<x = > string<"a\\"b"> plain< .. > string<\'c\'> '
        .. "plain< > comment<-- done>", "escaped quote, concat, comment")

print("Test 2: look-alikes are not tokens")
check_line("endpoint = ends + do_it",
    "plain<endpoint = ends + do_it>", "identifiers containing keywords")
check_line("a = b - c .. d",
    "plain<a = b - c .. d>", "minus and .. are plain")
check_line("obj.print(obj:type())",
    "plain<obj.print(obj:type())>", "fields named like builtins")
check_line("s = 'say \"hi\" -- not a comment'",
    "plain<s = > string<'say \"hi\" -- not a comment'>",
    "comment marker inside a string")
check_line('t = "unterminated',
    'plain<t = > string<"unterminated>', "unterminated string ends the line")

print("Test 3: long strings and comments across lines")
do
    local result = lua_highlight.highlight_lines({
        "local s = [==[ first",
        "still ]] inside ]=] too",
        "end ]==] local after",
        "--[[ block",
        "local inside_comment = 1",
        "]] x = 1 -- tail",
        "y = [[one line]] z = 2",
    })
    check(describe(result[1]) == "keyword<local> plain< s = > "
        .. "string<[==[ first>", "long string opens")
    check(describe(result[2]) == "string<still ]] inside ]=] too>",
        "wrong-level closers stay inside")
    check(describe(result[3]) == "string<end ]==]> plain< > keyword<local>"
        .. " plain< after>", "matching closer ends the string")
    check(describe(result[5]) == "comment<local inside_comment = 1>",
        "code inside a block comment is comment")
    check(describe(result[6]) == "comment<]]> plain< x = > number<1> "
        .. "plain< > comment<-- tail>", "block comment closes mid-line")
    check(describe(result[7]) == "plain<y = > string<[[one line]]> "
        .. "plain< z = > number<2>", "one-line long string")
end

print("Test 4: every repo Lua file round-trips")
do
    local pipe = assert(io.popen("ls *.lua"))
    local file_count, line_count, mismatches = 0, 0, {}
    for path in pipe:lines() do
        local lines = read_lines(path)
        local ok, result = pcall(lua_highlight.highlight_lines, lines)
        if not ok then
            mismatches[#mismatches + 1] = path .. ": " .. tostring(result)
        else
            for index, line in ipairs(lines) do
                if join_spans(result[index]) ~= line then
                    mismatches[#mismatches + 1] = path .. ":" .. index
                end
            end
        end
        file_count = file_count + 1
        line_count = line_count + #lines
    end
    pipe:close()
    check(file_count > 50 and #mismatches == 0, string.format(
        "%d files, %d lines: spans join back to every line", file_count,
        line_count))
    for i = 1, math.min(5, #mismatches) do
        print("      mismatch: " .. mismatches[i])
    end
end

--- Return the source with every comment span blanked out, keeping lines.
local function strip_comment_spans(lines)
    local kept = {}
    for index, spans in ipairs(lua_highlight.highlight_lines(lines)) do
        local parts = {}
        for _, span in ipairs(spans) do
            if span.kind == "comment" then
                parts[#parts + 1] = " "
            else
                parts[#parts + 1] = span.text
            end
        end
        kept[index] = table.concat(parts)
    end
    return table.concat(kept, "\n")
end

print("Test 5: removing comment spans never breaks code")
do
    local pipe = assert(io.popen("ls *.lua"))
    local checked, broken = 0, {}
    for path in pipe:lines() do
        local lines = read_lines(path)
        local original = table.concat(lines, "\n"):gsub("^#[^\n]*", "")
        if loadstring(original, "@" .. path) then
            local stripped = strip_comment_spans(lines):gsub("^#[^\n]*", "")
            local _, err = loadstring(stripped, "@" .. path)
            if err then
                broken[#broken + 1] = err
            end
            checked = checked + 1
        end
    end
    pipe:close()
    check(checked > 50 and #broken == 0, string.format(
        "%d compilable files still compile without comments", checked))
    for i = 1, math.min(5, #broken) do
        print("      broken: " .. broken[i])
    end
end

print("Test 6: large file speed")
do
    local lines = read_lines(LARGE_FILE)
    local started = os.clock()
    lua_highlight.highlight_lines(lines)
    local seconds = os.clock() - started
    check(seconds < LARGE_FILE_SECONDS, string.format(
        "%s (%d lines) in %.3fs (limit %.1fs)", LARGE_FILE, #lines, seconds,
        LARGE_FILE_SECONDS))
end

print(string.format("%d / %d passed", tests_passed, tests_run))
if tests_passed ~= tests_run then
    os.exit(1)
end
