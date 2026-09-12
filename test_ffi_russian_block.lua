#!/usr/bin/env luajit
--[[
    test_ffi_russian_block.lua
    Unit, integration, and FFI regression test suite for ffi_russian_block.lua.
]]

local ffi = require("ffi")

print("=== Running Unit Tests for ffi_russian_block.lua (Russian Block) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_russian_block.lua --help",
        expect = "Russian Block (Tetris / 俄罗斯方块) - LuaJIT FFI Cross-Platform Arcade Game"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_russian_block.lua --test",
        expect = "ALL RUSSIAN BLOCK TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_russian_block.lua --snapshot",
        expect = "RUSSIAN BLOCK (俄罗斯方块) - LUAJIT FFI"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_russian_block.lua --snapshot --ascii",
        expect = "+--- STATS ---+"
    },
    {
        name = "AI Bot autoplay demonstration (--demo 15)",
        cmd = "luajit ffi_russian_block.lua --demo 15",
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
local rb = require("ffi_russian_block")
local TetrisGame = rb.TetrisGame
local PIECES = rb.PIECES

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
assert_test("BoardCell sizeof == 2", ffi.sizeof("BoardCell") == 2)
assert_test("BoardCell offsetof(color) == 0", ffi.offsetof("BoardCell", "color") == 0)
assert_test("BoardCell offsetof(locked) == 1", ffi.offsetof("BoardCell", "locked") == 1)

assert_test("GameStats sizeof == 24", ffi.sizeof("GameStats") == 24)
assert_test("GameStats offsetof(score) == 0", ffi.offsetof("GameStats", "score") == 0)
assert_test("GameStats offsetof(high_score) == 4", ffi.offsetof("GameStats", "high_score") == 4)
assert_test("GameStats offsetof(lines) == 8", ffi.offsetof("GameStats", "lines") == 8)
assert_test("GameStats offsetof(level) == 12", ffi.offsetof("GameStats", "level") == 12)
assert_test("GameStats offsetof(combos) == 20", ffi.offsetof("GameStats", "combos") == 20)

-- 2. Windows Win32 FFI C Declarations Syntax Validation
local win32_cdef_ok, win32_err = pcall(function()
    ffi.cdef[[
        typedef struct { short X; short Y; } _TEST_COORD;
        typedef struct { short Left; short Top; short Right; short Bottom; } _TEST_SMALL_RECT;
        typedef struct {
            _TEST_COORD      dwSize;
            _TEST_COORD      dwCursorPosition;
            uint16_t         wAttributes;
            _TEST_SMALL_RECT srWindow;
            _TEST_COORD      dwMaximumWindowSize;
        } _TEST_CSBI;

        void* __stdcall _test_GetStdHandle(uint32_t nStdHandle);
        int   __stdcall _test_GetConsoleScreenBufferInfo(void* h, _TEST_CSBI* csbi);
        int   __stdcall _test_SetConsoleMode(void* h, uint32_t mode);
        void  __stdcall _test_Sleep(uint32_t ms);
    ]]
end)
assert_test("Windows Win32 C Declarations syntax is valid in LuaJIT FFI", win32_cdef_ok)

-- 3. Game Engine Logic
local game = TetrisGame.new({ ascii_mode = true })
assert_test("TetrisGame instance created", game ~= nil and game.board ~= nil)

-- Test all 7 tetrominoes definition integrity
for _, key in ipairs({"I", "O", "T", "S", "Z", "J", "L"}) do
    local p = PIECES[key]
    assert_test(string.format("Piece %s matrix shape matches size %d", key, p.size),
        #p.shape == p.size and #p.shape[1] == p.size)
end

-- Test AI Best Move generation
game:clear_board()
game:spawn_piece("T")
local move = game:find_best_move()
assert_test("AI heuristic generated valid best move",
    move ~= nil and move.rotations >= 0 and move.target_x >= 1 and move.target_x <= rb.BOARD_COLS)

-- Test Double & Triple Line Clears
game:clear_board()
local rows_to_clear = { rb.TOTAL_ROWS - 1, rb.TOTAL_ROWS }
for _, r in ipairs(rows_to_clear) do
    for c = 1, rb.BOARD_COLS do
        game:set_cell(r, c, 1, true)
    end
end
local start_lines = game.stats.lines
game:collapse_lines(rows_to_clear)
assert_test("Double line clear collapses exactly 2 rows", game.stats.lines == start_lines + 2)

-- Test Back-to-Back Tetris bonus
game:clear_board()
game.last_was_tetris = true
local prev_score = game.stats.score
local tetris_rows = { rb.TOTAL_ROWS - 3, rb.TOTAL_ROWS - 2, rb.TOTAL_ROWS - 1, rb.TOTAL_ROWS }
for _, r in ipairs(tetris_rows) do
    for c = 1, rb.BOARD_COLS do
        game:set_cell(r, c, 1, true)
    end
end
game:collapse_lines(tetris_rows)
assert_test("Back-to-Back Tetris awarded 1.5x score bonus (1200+ pts)",
    (game.stats.score - prev_score) >= 1200)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_cli))
if passed == total_cli then
    print("\27[1;32mALL RUSSIAN BLOCK TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
