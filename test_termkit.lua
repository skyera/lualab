#!/usr/bin/env luajit
--[[
    test_termkit.lua
    Unit tests for termkit.lua: key tokenizer, burst/piped input via read_key, size
    fallback, and behaviour when no terminal is attached. Terminal-mode behaviour is
    covered by test_termkit_pty.py.
]]

local termkit = require("termkit")

local passed, failed = 0, 0

local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  \27[32m✔\27[0m " .. name)
    else
        failed = failed + 1
        print("  \27[31m✘\27[0m " .. name)
        print("    \27[31m" .. tostring(err) .. "\27[0m")
    end
end

local function describe(name, fn)
    print("\n\27[1;36m▶ " .. name .. "\27[0m")
    fn()
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "mismatch",
            tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(value, msg)
    if not value then
        error(msg or "expected true", 2)
    end
end

--- Tokenize `bytes` completely; mouse events are rendered as "mouse:btn,x,y,M|m".
local function tokenize(bytes)
    local tokens = {}
    while bytes ~= "" do
        local token
        token, bytes = termkit.next_token(bytes)
        if type(token) == "table" then
            token = string.format("mouse:%d,%d,%d,%s", token.btn, token.x, token.y,
                token.release and "m" or "M")
        end
        tokens[#tokens + 1] = token
    end
    return table.concat(tokens, " ")
end

print("=== Running termkit test suite ===")

describe("1. Tokenizer", function()
    it("maps arrow, navigation and function keys", function()
        assert_eq(tokenize("\27[A\27[B\27[C\27[D"), "UP DOWN RIGHT LEFT")
        assert_eq(tokenize("\27[H\27[F\27[1~\27[4~"), "HOME END HOME END")
        assert_eq(tokenize("\27[5~\27[6~\27[Z\27[15~"), "PAGE_UP PAGE_DOWN SHIFT_TAB F5")
    end)

    it("maps control bytes to named keys", function()
        assert_eq(tokenize("\r\n \t\8\127"), "ENTER ENTER SPACE TAB BACKSPACE BACKSPACE")
    end)

    it("returns printable ASCII and multi-byte UTF-8 characters whole", function()
        assert_eq(tokenize("aZ9/é中😀"), "a Z 9 / é 中 😀")
    end)

    it("treats a lone ESC and unknown sequences as ESC, consuming them", function()
        assert_eq(tokenize("\27"), "ESC")
        assert_eq(tokenize("\27x"), "ESC x")
        assert_eq(tokenize("\27[1;5A"), "ESC", "ctrl-arrow is consumed as one ESC")
        assert_eq(tokenize("\27[99~q"), "ESC q")
    end)

    it("parses SGR mouse press, release and wheel events", function()
        assert_eq(tokenize("\27[<0;10;5M\27[<0;10;5m"), "mouse:0,10,5,M mouse:0,10,5,m")
        assert_eq(tokenize("\27[<64;120;40M"), "mouse:64,120,40,M")
    end)

    it("splits mixed bursts without dropping any key", function()
        assert_eq(tokenize("q\27[C\27[<0;1;2Mj é\27[6~\r"),
            "q RIGHT mouse:0,1,2,M j SPACE é PAGE_DOWN ENTER")
    end)

    it("handles a truncated escape at the end of a buffer", function()
        assert_eq(tokenize("a\27["), "a ESC [")
    end)
end)

describe("2. read_key on piped input (subprocess)", function()
    local script_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
    local code = string.format([[
        package.path = %q .. "/?.lua;" .. package.path
        local termkit = require("termkit")
        local out = {}
        while true do
            local key = termkit.read_key(200)
            if key == "EOF" then break end
            if key ~= nil then
                if type(key) == "table" then
                    key = "mouse"
                end
                out[#out + 1] = key
            end
        end
        print(table.concat(out, ","))
    ]], script_dir)

    local function run_with_input(input_shell)
        local program = code:gsub("'", "'\\''")
        local file = io.popen(input_shell .. " | luajit -e '" .. program .. "' 2>&1")
        local out = file:read("*a")
        file:close()
        return (out:gsub("%s+$", ""))
    end

    it("delivers every token of a burst, then EOF", function()
        assert_eq(run_with_input("printf 'ab\\033[C\\033[<0;1;2Mq'"), "a,b,RIGHT,mouse,q")
    end)

    it("handles a long burst larger than one read chunk", function()
        local out = run_with_input("head -c 1000 /dev/zero | tr '\\0' 'x'")
        local _, count = out:gsub("x", "")
        assert_eq(count, 1000, "all 1000 keys delivered")
    end)

    it("reports EOF immediately for empty input", function()
        assert_eq(run_with_input("printf ''"), "")
    end)

    it("times out with nil when no input arrives", function()
        local file = io.popen("(sleep 1) | luajit -e '"
            .. code:gsub("'", "'\\''") .. "' 2>&1")
        local out = file:read("*a")
        file:close()
        assert_eq((out:gsub("%s+$", "")), "", "no spurious keys while waiting")
    end)
end)

describe("3. Terminal-independent behaviour", function()
    it("size() returns positive integers (default when not a terminal)", function()
        local cols, rows = termkit.size()
        assert_true(cols > 0 and rows > 0, "positive size")
        assert_eq(cols % 1, 0, "integer columns")
    end)

    it("enter() declines cleanly without a terminal and changes nothing", function()
        local code = [[
            package.path = "./?.lua;" .. package.path
            local termkit = require("termkit")
            io.write(tostring(termkit.enter({ mouse = true })), " ", tostring(termkit.is_raw()))
        ]]
        local file = io.popen("echo | luajit -e '" .. code:gsub("'", "'\\''") .. "' 2>&1")
        local out = file:read("*a")
        file:close()
        assert_eq(out, "false false", "enter refused when stdin is a pipe")
    end)

    it("leave(), suspend() and resume() are harmless when not in raw mode", function()
        termkit.leave()
        termkit.suspend()
        termkit.resume()
        termkit.flush_input()
        assert_true(not termkit.is_raw(), "still not raw")
    end)
end)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
