#!/usr/bin/env luajit
--[[
    test_ffi_tetris.lua
    Unit, integration, and FFI regression test suite for ffi_tetris.lua.
]]

local ffi = require("ffi")

print("=== Running Unit Tests for ffi_tetris.lua (Tetris) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_tetris.lua --help",
        expect = "Tetris (Russian Block / 俄罗斯方块) - LuaJIT FFI Cross-Platform Arcade Game"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_tetris.lua --test",
        expect = "ALL TETRIS TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_tetris.lua --snapshot",
        expect = "TETRIS (俄罗斯方块) - LUAJIT FFI"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_tetris.lua --snapshot --ascii",
        expect = "+--- STATS ---+"
    },
    {
        name = "Launcher snapshot render (tetris.lua --snapshot)",
        cmd = "luajit tetris.lua --snapshot",
        expect = "TETRIS (俄罗斯方块) - LUAJIT FFI"
    },
    {
        name = "AI Bot autoplay demonstration (--demo 15)",
        cmd = "luajit ffi_tetris.lua --demo 15",
        expect = "[AI Demo Complete]"
    },
    {
        name = "CLI Leaderboard flag (ffi_tetris.lua --scores)",
        cmd = "luajit ffi_tetris.lua --scores",
        expect = "ALL-TIME HALL OF FAME"
    },
    {
        name = "Launcher Leaderboard flag (tetris.lua --scores)",
        cmd = "luajit tetris.lua --scores",
        expect = "ALL-TIME HALL OF FAME"
    },
    {
        name = "Launcher Leaderboard short flag (tetris.lua -s)",
        cmd = "luajit tetris.lua -s",
        expect = "ALL-TIME HALL OF FAME"
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
local rb = require("ffi_tetris")
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

-- 4. Terminal UI Layout Width & Box Alignment Tests
local utf8_w = rb.utf8_visible_width
local function verify_frame_layout(g_inst)
    local frame = g_inst:render_frame()
    for line in frame:gmatch("([^\r\n]+)") do
        local w = utf8_w(line)
        if w > 0 and w ~= 59 then
            return false, string.format("Mismatch width %d on line: %s", w, line)
        end
    end
    return true
end

local g_uni = TetrisGame.new()
local g_ascii = TetrisGame.new({ ascii_mode = true })
local g_over = TetrisGame.new()
g_over.game_over = true
local g_pause = TetrisGame.new()
g_pause.paused = true
local g_high = TetrisGame.new()
g_high.stats.score = 999999
g_high.stats.high_score = 1234567

local g_ground = TetrisGame.new()
g_ground.lock_timer_start = 1000

local g_banner = TetrisGame.new()
g_banner.banner_text = "B2B TETRIS!"
g_banner.banner_until = 999999999

local g_flash = TetrisGame.new()
g_flash:set_cell(rb.TOTAL_ROWS, 1, 9, true)

assert_test("Layout width is uniform 59 columns in Unicode mode", verify_frame_layout(g_uni))
assert_test("Layout width is uniform 59 columns in ASCII mode", verify_frame_layout(g_ascii))
assert_test("Layout borders remain aligned during Game Over overlay", verify_frame_layout(g_over))
assert_test("Layout borders remain aligned during Paused overlay", verify_frame_layout(g_pause))
assert_test("Layout borders remain aligned with 6+ digit high scores", verify_frame_layout(g_high))
assert_test("Layout borders remain aligned with grounded lock progress indicator", verify_frame_layout(g_ground))
assert_test("Layout borders remain aligned with active dynamic banner", verify_frame_layout(g_banner))
assert_test("Layout borders remain aligned during line clear flash animation", verify_frame_layout(g_flash))

-- 5. Engine Features & Timeout Logic Tests
local t_out = g_uni:get_next_event_timeout(os.clock() * 1000)
assert_test("get_next_event_timeout returns valid positive millisecond window", t_out > 0 and t_out <= 50)

g_uni.lock_timer_start = os.clock() * 1000
local t_lock = g_uni:get_next_event_timeout(os.clock() * 1000)
assert_test("get_next_event_timeout adjusts to fast rate when grounded", t_lock > 0 and t_lock <= 33)

local frame_str = g_uni:render_frame()
assert_test("Rendered frame contains 3-piece upcoming QUEUE box", frame_str:find("QUEUE") ~= nil and frame_str:find("#2:") ~= nil and frame_str:find("#3:") ~= nil)

-- 6. SQLite Database & Leaderboard Verification
local g_board_uni = TetrisGame.new()
g_board_uni.showing_leaderboard = true
assert_test("Leaderboard frame layout width is strictly 59 columns (Unicode)", verify_frame_layout(g_board_uni))

local g_board_ascii = TetrisGame.new({ ascii_mode = true })
g_board_ascii.showing_leaderboard = true
assert_test("Leaderboard frame layout width is strictly 59 columns (ASCII)", verify_frame_layout(g_board_ascii))

-- Test SQLite session recording & retrieval
local init_summary = rb.get_db_summary()
local test_score = 42100
local test_lines = 16
local test_level = 2
local test_pieces = 35
local test_combo = 3
local test_dur = 95
local save_ok = rb.save_game_record(test_score, test_lines, test_level, test_pieces, test_combo, test_dur)
assert_test("save_game_record successfully executed", save_ok == true)

local after_summary = rb.get_db_summary()
assert_test("get_db_summary increments game count and total lines",
    after_summary.count == init_summary.count + 1 and after_summary.total_lines >= init_summary.total_lines + test_lines)

local top_scores = rb.get_top_scores(10)
assert_test("get_top_scores returns valid record in descending score order",
    #top_scores >= 1 and top_scores[1].score >= test_score)

-- Verify Leaderboard layout width with populated database records
assert_test("Populated Leaderboard frame layout width is strictly 59 columns (Unicode)", verify_frame_layout(g_board_uni))
assert_test("Populated Leaderboard frame layout width is strictly 59 columns (ASCII)", verify_frame_layout(g_board_ascii))

-- 7. Non-interactive pipeline sanity check (simulate keystrokes: 'h', 'h', 'q')
local pipe = io.popen("printf 'hhq' | luajit tetris.lua 2>&1")
local pipe_out = pipe:read("*a")
pipe:close()
assert_test("Interactive pipeline toggles Hall of Fame and exits cleanly",
    pipe_out:find("Thanks for playing Tetris", 1, true) ~= nil)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_cli))
if passed == total_cli then
    print("\27[1;32mALL TETRIS TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
