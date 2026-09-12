#!/usr/bin/env luajit
--[[
    test_ffi_chinese_chess.lua
    Unit, integration, and FFI regression test suite for ffi_chinese_chess.lua (Xiangqi / 中国象棋).
]]

local ffi = require("ffi")

print("=== Running Unit Tests for ffi_chinese_chess.lua (Chinese Chess / Xiangqi) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_chinese_chess.lua --help",
        expect = "Chinese Chess (Xiangqi / 中国象棋) - LuaJIT FFI Cross-Platform Engine"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_chinese_chess.lua --test",
        expect = "ALL CHINESE CHESS TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_chinese_chess.lua --snapshot",
        expect = "CHINESE CHESS (中国象棋) - LUAJIT FFI ENGINE"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_chinese_chess.lua --snapshot --ascii",
        expect = "+-- STATUS --------------------+"
    },
    {
        name = "AI Bot autoplay demonstration (--demo 4)",
        cmd = "luajit ffi_chinese_chess.lua --demo 4",
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
-- In-Depth Engine, Rules & FFI API Tests
-- =========================================================================
print("\n--- In-Depth Xiangqi Engine, Rules & FFI API Unit Tests ---")
local cc = require("ffi_chinese_chess")
local XiangqiGame = cc.XiangqiGame

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
assert_test("BoardPoint sizeof == 2", ffi.sizeof("BoardPoint") == 2)
assert_test("BoardPoint offsetof(piece_type) == 0", ffi.offsetof("BoardPoint", "piece_type") == 0)
assert_test("BoardPoint offsetof(side) == 1", ffi.offsetof("BoardPoint", "side") == 1)

-- 2. Board Setup & Initial State
local game = XiangqiGame.new()
assert_test("XiangqiGame instance created with 90-cell board", game ~= nil and game.board ~= nil)
assert_test("Red General at (5, 1)", game:get_point(5, 1).piece_type == cc.PIECE_GENERAL and game:get_point(5, 1).side == cc.SIDE_RED)
assert_test("Black General at (5, 10)", game:get_point(5, 10).piece_type == cc.PIECE_GENERAL and game:get_point(5, 10).side == cc.SIDE_BLACK)
assert_test("Red Chariots at (1, 1) and (9, 1)",
    game:get_point(1, 1).piece_type == cc.PIECE_CHARIOT and game:get_point(9, 1).piece_type == cc.PIECE_CHARIOT)
assert_test("Red Cannons at (2, 3) and (8, 3)",
    game:get_point(2, 3).piece_type == cc.PIECE_CANNON and game:get_point(8, 3).piece_type == cc.PIECE_CANNON)
assert_test("Initial legal moves count for Red is exactly 44", #game:get_legal_moves(cc.SIDE_RED) == 44)
assert_test("Initial legal moves count for Black is exactly 44", #game:get_legal_moves(cc.SIDE_BLACK) == 44)

-- 3. Flying Generals Rule (飞将 / 对脸将)
game:reset()
ffi.fill(game.board, ffi.sizeof("BoardPoint") * 90, 0)
game:set_point(5, 1, cc.PIECE_GENERAL, cc.SIDE_RED)
game:set_point(5, 10, cc.PIECE_GENERAL, cc.SIDE_BLACK)
assert_test("Generals directly facing on same file triggers Flying Generals", game:is_flying_generals() == true)
game:set_point(5, 5, cc.PIECE_SOLDIER, cc.SIDE_RED)
assert_test("Obstacle between Generals clears Flying Generals", game:is_flying_generals() == false)

-- 4. Horse Movement and Hobbling (蹩马腿)
game:reset()
ffi.fill(game.board, ffi.sizeof("BoardPoint") * 90, 0)
game:set_point(5, 5, cc.PIECE_HORSE, cc.SIDE_RED)
game:set_point(5, 1, cc.PIECE_GENERAL, cc.SIDE_RED)
game:set_point(4, 10, cc.PIECE_GENERAL, cc.SIDE_BLACK)
assert_test("Unhobbled central Horse has 8 legal destinations", #game:get_legal_moves_for_piece(5, 5) == 8)
-- Hobble up direction: put piece at (5, 6)
game:set_point(5, 6, cc.PIECE_SOLDIER, cc.SIDE_RED)
assert_test("Hobbled upward leg removes 2 moves (6 remaining)", #game:get_legal_moves_for_piece(5, 5) == 6)
-- Hobble left direction: put piece at (4, 5)
game:set_point(4, 5, cc.PIECE_SOLDIER, cc.SIDE_RED)
assert_test("Hobbling left leg removes 2 more moves (4 remaining)", #game:get_legal_moves_for_piece(5, 5) == 4)

-- 5. Elephant Movement, River Restriction, and Eye Blocking (塞象眼)
game:reset()
ffi.fill(game.board, ffi.sizeof("BoardPoint") * 90, 0)
game:set_point(3, 1, cc.PIECE_ELEPHANT, cc.SIDE_RED)
game:set_point(5, 1, cc.PIECE_GENERAL, cc.SIDE_RED)
game:set_point(4, 10, cc.PIECE_GENERAL, cc.SIDE_BLACK)
assert_test("Free Elephant has 2 valid jumps within home territory", #game:get_legal_moves_for_piece(3, 1) == 2)
-- Block eye at (4, 2)
game:set_point(4, 2, cc.PIECE_SOLDIER, cc.SIDE_RED)
assert_test("Blocked elephant eye eliminates jump to (5, 3)", #game:get_legal_moves_for_piece(3, 1) == 1)
-- River crossing check: elephant at (5, 5) cannot jump to (7, 7) or (3, 7)
game:set_point(5, 5, cc.PIECE_ELEPHANT, cc.SIDE_RED)
local e_river_moves = game:get_legal_moves_for_piece(5, 5)
local river_crossed = false
for _, m in ipairs(e_river_moves) do
    if m.to_y > 5 then river_crossed = true end
end
assert_test("Red Elephant cannot cross river to row 6+", not river_crossed)

-- 6. Cannon Movement and Screen Mechanics (炮架)
game:reset()
ffi.fill(game.board, ffi.sizeof("BoardPoint") * 90, 0)
game:set_point(2, 5, cc.PIECE_CANNON, cc.SIDE_RED)
game:set_point(5, 1, cc.PIECE_GENERAL, cc.SIDE_RED)
game:set_point(4, 10, cc.PIECE_GENERAL, cc.SIDE_BLACK)
-- Without screen: cannot jump over enemy or capture without mount
game:set_point(2, 8, cc.PIECE_HORSE, cc.SIDE_BLACK)
local c_moves_noscreen = game:get_legal_moves_for_piece(2, 5)
local can_cap_noscreen = false
for _, m in ipairs(c_moves_noscreen) do
    if m.to_x == 2 and m.to_y == 8 then can_cap_noscreen = true end
end
assert_test("Cannon cannot capture directly without a screen", not can_cap_noscreen)
-- With screen at (2, 7), can capture (2, 8)
game:set_point(2, 7, cc.PIECE_SOLDIER, cc.SIDE_BLACK)
local c_moves_screen = game:get_legal_moves_for_piece(2, 5)
local can_cap_screen = false
for _, m in ipairs(c_moves_screen) do
    if m.to_x == 2 and m.to_y == 8 then can_cap_screen = true end
end
assert_test("Cannon can capture enemy piece using intervening screen", can_cap_screen)

-- 7. Soldier / Pawn Movement (Before and After River)
game:reset()
ffi.fill(game.board, ffi.sizeof("BoardPoint") * 90, 0)
game:set_point(5, 1, cc.PIECE_GENERAL, cc.SIDE_RED)
game:set_point(4, 10, cc.PIECE_GENERAL, cc.SIDE_BLACK)
-- Before river: at (5, 4), can only move forward to (5, 5)
game:set_point(5, 4, cc.PIECE_SOLDIER, cc.SIDE_RED)
assert_test("Soldier before river has only 1 forward move", #game:get_legal_moves_for_piece(5, 4) == 1)
-- After river: at (5, 6), can move forward (5, 7), left (4, 6), right (6, 6)
game:set_point(5, 6, cc.PIECE_SOLDIER, cc.SIDE_RED)
assert_test("Soldier after river has 3 moves (forward, left, right)", #game:get_legal_moves_for_piece(5, 6) == 3)

-- 8. Check Detection
game:reset()
ffi.fill(game.board, ffi.sizeof("BoardPoint") * 90, 0)
game:set_point(5, 1, cc.PIECE_GENERAL, cc.SIDE_RED)
game:set_point(4, 10, cc.PIECE_GENERAL, cc.SIDE_BLACK)
game:set_point(5, 8, cc.PIECE_CHARIOT, cc.SIDE_BLACK)
assert_test("Enemy Chariot checking Red General is detected", game:is_in_check(cc.SIDE_RED) == true)

-- 9. Move Execution, Capture, and Undo Integrity
game:reset()
local start_caps = #game.captured_black
local move = { from_x = 2, from_y = 3, to_x = 2, to_y = 10, piece_type = cc.PIECE_CANNON, side = cc.SIDE_RED }
game:execute_move(move)
assert_test("Move executed: target square occupied", game:get_point(2, 10).piece_type == cc.PIECE_CANNON)
assert_test("Move executed: source square vacated", game:get_point(2, 3).piece_type == cc.PIECE_EMPTY)
assert_test("Capture recorded: black horse added to captured list", #game.captured_black == start_caps + 1)
game:undo_move()
assert_test("Move undone: piece restored to source", game:get_point(2, 3).piece_type == cc.PIECE_CANNON)
assert_test("Move undone: captured piece restored to target", game:get_point(2, 10).piece_type == cc.PIECE_HORSE)
assert_test("Move undone: captured list restored", #game.captured_black == start_caps)

-- 10. Traditional Chinese Move Notation Generation
game:reset()
local notat1 = game:move_to_notation({ from_x = 8, from_y = 3, to_x = 5, to_y = 3, piece_type = cc.PIECE_CANNON, side = cc.SIDE_RED })
assert_test("Canonical opening move produces '炮二平五'", notat1 == "炮二平五")
local notat2 = game:move_to_notation({ from_x = 8, from_y = 10, to_x = 7, to_y = 8, piece_type = cc.PIECE_HORSE, side = cc.SIDE_BLACK })
assert_test("Canonical black opening move produces '馬8進7'", notat2 == "馬8進7")

-- 11. AI Alpha-Beta Search Engine
game:reset()
local best_move, eval = game:find_best_move(2)
assert_test("AI returns a valid legal move object", best_move ~= nil and best_move.from_x >= 1 and best_move.to_x <= 9)
assert_test("AI returns numerical position evaluation", type(eval) == "number")

-- 12. Frame Snapshot Uniform 80-Column Display Width
local function check_uniform_80(g_obj)
    local frame = g_obj:render_frame()
    for line in frame:gmatch("([^\r\n]+)") do
        local w = cc.utf8_visible_width(line)
        if w > 0 and w ~= 80 then return false, w end
    end
    return true
end
local u_ok, u_w = check_uniform_80(game)
assert_test("Frame render is uniformly 80 terminal columns in Unicode mode", u_ok)
local ascii_game = XiangqiGame.new({ ascii_mode = true })
local a_ok, a_w = check_uniform_80(ascii_game)
assert_test("Frame render is uniformly 80 terminal columns in ASCII mode", a_ok)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_cli))
if passed == total_cli then
    print("\27[1;32mALL CHINESE CHESS TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
