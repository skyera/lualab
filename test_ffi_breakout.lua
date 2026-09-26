#!/usr/bin/env luajit
-- Tests for the Breakout game mechanics and non-interactive CLI.

local breakout = require("ffi_breakout")
local Game = breakout.Game
local passed, total = 0, 0

local function check(name, condition)
    total = total + 1
    if condition then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        io.stderr:write("  FAIL: " .. name .. "\n")
    end
end

local function run_cli(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok = pipe:close()
    return output, ok
end

print("=== Breakout unit and CLI tests ===")

local game = Game.new()
check("starts with three lives and 50 bricks", game.lives == 3 and game:remaining_bricks() == 50)

game:move_paddle(-1, 20)
check("paddle clamps to left wall", game.paddle_x == 2 + game.paddle_width / 2)
game:move_paddle(1, 20)
check("paddle clamps to right wall", game.paddle_x == breakout.WIDTH - 1 - game.paddle_width / 2)

game = Game.new()
game.bricks = {
    { x = 10, y = 5, w = 5, h = 1, row = 1 },
    { x = 20, y = 5, w = 5, h = 1, row = 2 },
}
game.ball_x, game.ball_y, game.ball_vx, game.ball_vy = 12, 6.2, 0, -10
game:update(0.04)
check("brick collision removes hit brick and awards points", #game.bricks == 1 and game.score == 50)

game = Game.new()
game.bricks = { { x = 10, y = 5, w = 5, h = 1, row = 1 } }
game.ball_x, game.ball_y, game.ball_vx, game.ball_vy = 12, 6.2, 0, -10
game:update(0.04)
check("clearing last brick advances level and resets rack", game.level == 2 and #game.bricks == 50)

game = Game.new()
game.ball_x, game.ball_y, game.ball_vx, game.ball_vy = 2.3, 10, -12, 0
game:update(0.05)
check("side wall reflects ball", game.ball_vx > 0)

game = Game.new()
game.ball_x, game.ball_y, game.ball_vx, game.ball_vy = game.paddle_x, breakout.PADDLE_Y - 0.5, 0, 12
game:update(0.05)
check("paddle hit sends ball upward", game.ball_vy < 0)

game = Game.new()
game.ball_x, game.ball_y, game.ball_vx, game.ball_vy = 32, breakout.HEIGHT - 1.1, 0, 10
game:update(0.05)
check("miss consumes life and resets ball", game.lives == 2 and game.ball_y < breakout.PADDLE_Y)
game.lives = 1
game.ball_x, game.ball_y, game.ball_vx, game.ball_vy = 32, breakout.HEIGHT - 1.1, 0, 10
game:update(0.05)
check("last miss sets game-over state", game.game_over and game.lives == 0)

game = Game.new()
game.paused = true
game:update(0.05)
check("pause freezes ball motion", game.ball_x == game.paddle_x and game.ball_y == breakout.PADDLE_Y - 1)
local frame = breakout.render_frame(Game.new(), false)
check("snapshot renders HUD and brick field", frame:find("BREAKOUT", 1, true) ~= nil and frame:find("#", 1, true) ~= nil)

local help, help_ok = run_cli("luajit ffi_breakout.lua --help")
check("--help prints usage", help_ok and help:find("Usage:", 1, true) ~= nil)
local snapshot, snapshot_ok = run_cli("luajit ffi_breakout.lua --snapshot --ascii")
check("--snapshot --ascii runs headlessly", snapshot_ok and snapshot:find("BREAKOUT", 1, true) ~= nil)

print(string.format("Test summary: %d/%d passed", passed, total))
os.exit(passed == total and 0 or 1)
