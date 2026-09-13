#!/usr/bin/env luajit
--[[
    test_ffi_game_2048.lua
    Unit, regression, and integration test suite for ffi_game_2048.lua.
]]

local ffi = require("ffi")

print("=== Running Unit Tests for ffi_game_2048.lua (2048 & Expectimax AI) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "./LuaJIT/src/luajit ffi_game_2048.lua --help",
        expect = "2048 • LuaJIT FFI Sliding Tile Puzzle & Expectimax AI Solver"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "./LuaJIT/src/luajit ffi_game_2048.lua --test",
        expect = "ALL 2048 TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "./LuaJIT/src/luajit ffi_game_2048.lua --snapshot",
        expect = "2048  *  LUAJIT FFI EDITION"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "./LuaJIT/src/luajit ffi_game_2048.lua --snapshot --ascii",
        expect = "SCORE:"
    },
    {
        name = "AI Bot autoplay demonstration (--demo 10)",
        cmd = "./LuaJIT/src/luajit ffi_game_2048.lua --demo 10",
        expect = "[AI Demo Complete]"
    }
}

local passed = 0
local total_cli = #tests

for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
    local out = p:read("*a")
    p:close()

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, total_cli, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, total_cli, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

-- =========================================================================
-- In-Depth Module & FFI API Tests
-- =========================================================================
print("\n--- In-Depth FFI Struct & Engine Unit Tests ---")
local g2048 = require("ffi_game_2048")
local Game2048 = g2048.Game2048
local AI = g2048.AI
local slide_and_merge_line = g2048.slide_and_merge_line
local DIR_UP = g2048.DIR_UP
local DIR_DOWN = g2048.DIR_DOWN
local DIR_LEFT = g2048.DIR_LEFT
local DIR_RIGHT = g2048.DIR_RIGHT

local function assert_test(name, cond)
    if cond then
        passed = passed + 1
        print(string.format("  \27[32m✔ PASS\27[0m: %s", name))
    else
        print(string.format("  \27[31m✘ FAIL\27[0m: %s", name))
    end
    total_cli = total_cli + 1
end

-- 1. FFI C Struct layout checks
assert_test("BoardCell sizeof == 8", ffi.sizeof("BoardCell") == 8)
assert_test("BoardCell offsetof(val) == 0", ffi.offsetof("BoardCell", "val") == 0)
assert_test("BoardCell offsetof(merged) == 4", ffi.offsetof("BoardCell", "merged") == 4)
assert_test("Game2048Stats sizeof == 20", ffi.sizeof("Game2048Stats") == 20)

-- 2. Advanced Merging Mechanics
local v0, v1, v2, v3, pts, chg = slide_and_merge_line(4, 4, 8, 8)
assert_test("Merging [4,4,8,8] produces [8,16,0,0]", v0 == 8 and v1 == 16 and v2 == 0 and v3 == 0)
assert_test("Merging [4,4,8,8] awards 24 points", pts == 24)

v0, v1, v2, v3, pts, chg = slide_and_merge_line(0, 0, 0, 2)
assert_test("Sliding [0,0,0,2] produces [2,0,0,0]", v0 == 2 and v1 == 0 and v2 == 0 and v3 == 0)
assert_test("Sliding [0,0,0,2] awards 0 points", pts == 0)

-- 3. Four Direction Grid Physics
local g = Game2048.new({ use_ascii = true })
for i = 0, 15 do g.board[i].val = 0 end

-- Set up vertical merge:
-- 2 . . .
-- 2 . . .
-- 4 . . .
-- 4 . . .
g.board[0].val = 2
g.board[4].val = 2
g.board[8].val = 4
g.board[12].val = 4

local moved_up = g:move(DIR_UP)
assert_test("Move UP merged correctly", moved_up == true)
assert_test("Top cell merged into 4", g.board[0].val == 4)
assert_test("Second cell merged into 8", g.board[4].val == 8)

-- 4. Multiple Undo verification
local undo1 = g:undo()
assert_test("Undo restored previous board configuration", undo1 == true and g.board[0].val == 2 and g.board[4].val == 2)

-- 5. AI Evaluation and Decision Making
local b_eval = {}
for i = 0, 15 do b_eval[i] = 0 end
b_eval[0] = 1024
b_eval[1] = 512
b_eval[2] = 256
b_eval[3] = 128
local score_ordered = AI.evaluate(b_eval)

-- Scramble monotonic order
b_eval[0] = 128
b_eval[1] = 1024
b_eval[2] = 256
b_eval[3] = 512
local score_scrambled = AI.evaluate(b_eval)
assert_test("AI heuristic prioritizes monotonic snake ordering", score_ordered > score_scrambled)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_cli))
if passed == total_cli then
    print("\27[1;32mALL 2048 TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
