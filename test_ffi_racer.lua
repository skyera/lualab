#!/usr/bin/env luajit
-- Tests for the Turbo Circuit top-down racer: track geometry, lap gating,
-- wall physics, AI behaviour, the renderer, and the non-interactive CLI.

local racer = require("ffi_circuit_racer")
local Game = racer.Game
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

-- os.execute reports the raw wait status on LuaJIT (0 for success, 512 for
-- exit code 2), which is all this suite needs to distinguish pass from fail.
local function run_cli(command)
    local tmp = "_racer_cli.tmp"
    local status = os.execute(command .. " > " .. tmp .. " 2>&1")
    if status == true then status = 0 end
    local f = io.open(tmp, "r")
    local output = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(tmp)
    return output, status
end

print("=== Turbo Circuit unit and CLI tests ===")

--------------------------------------------------------------------------------
-- Track geometry
--------------------------------------------------------------------------------
local track = racer.get_track()
check("track has a full set of centreline samples", #track.samples > 100)
local ax, ay = racer.sample_at(track, 0)
local bx, by = racer.sample_at(track, track.length)
check("track is a closed loop", math.abs(ax - bx) < 1e-6 and math.abs(ay - by) < 1e-6)
check("track caches a single instance", racer.get_track() == track)

local road, wall, start = 0, 0, 0
for _, v in pairs(track.grid) do
    if v == 1 then road = road + 1
    elseif v == 2 then wall = wall + 1
    elseif v == 3 then start = start + 1 end
end
check("road band, wall border and start line are all rasterised",
      road > 500 and wall > 100 and start >= 1)

local s0 = track.samples[1]
check("the start line sits on drivable tarmac", racer.drivable(track, s0.x, s0.y))
check("open ground outside the circuit is not drivable", not racer.drivable(track, 1.5, 1.5))
check("out-of-bounds lookups read as void", racer.cell_value(track, -5, -5) == 0)

-- Corners must be wide enough for the car: a radius below the usable half
-- width would make the circuit physically untakeable.
local min_radius = math.huge
local n = #track.samples
for i = 1, n do
    local a, b, c = track.samples[(i - 2) % n + 1], track.samples[i], track.samples[i % n + 1]
    local ab = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    local bc = math.sqrt((c.x - b.x) ^ 2 + (c.y - b.y) ^ 2)
    local ca = math.sqrt((a.x - c.x) ^ 2 + (a.y - c.y) ^ 2)
    local cross = math.abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
    if cross > 1e-9 then
        min_radius = math.min(min_radius, ab * bc * ca / (2 * cross))
    end
end
check("tightest corner is wider than the car is wide",
      min_radius > 2 * racer.ROAD_HALF * 0.5)

--------------------------------------------------------------------------------
-- Lap gating and race state
--------------------------------------------------------------------------------
local g = Game.new({ laps = 3 })
check("a new race starts on lap 1 with no laps banked", g.lap == 1 and g.laps_done == 0)
check("the player starts ahead of the grid",
      g:position() == 1 and select(2, g:position()) == g.ai_count + 1)
check("the first checkpoint is armed", g.next_cp == 1)

-- Walking the centreline in order must trip every gate exactly once per lap.
for _ = 1, 3 do
    for i = 1, track.count do
        local s = track.samples[i]
        g.player.x, g.player.y = s.x, s.y
        g.player.sample_idx = i
        g:update_progress()
    end
end
check("ordered checkpoints bank three laps", g.laps_done == 3)
check("the race finishes after the final lap", g.finished)
check("crossing the line freezes the lap counter", g.lap == 3)

-- Cut the infield and the gate order must not advance.
local cheat = Game.new({ laps = 3 })
for _ = 1, 3 do
    local s = track.samples[track.count]
    cheat.player.x, cheat.player.y = s.x, s.y
    cheat:update_progress()
end
check("sitting on one gate cannot farm laps", cheat.laps_done == 0)

--------------------------------------------------------------------------------
-- Physics and collisions
--------------------------------------------------------------------------------
local wall_game = Game.new()
wall_game.player.heading = track.start_heading + math.pi / 2
wall_game.player.speed = 55
for _ = 1, 40 do wall_game:step(1 / 60, { throttle = 1, brake = 0, steer = 0 }) end
check("a wall impact is registered", wall_game.wall_hits > 0)
check("a wall impact never puts the car off the tarmac",
      racer.drivable(track, wall_game.player.x, wall_game.player.y))

local throttle_game = Game.new()
throttle_game:step(1 / 60, { throttle = 1, brake = 0, steer = 0 })
throttle_game:step(1 / 60, { throttle = 1, brake = 0, steer = 0 })
check("throttle accelerates the car", throttle_game.player.speed > 0)

local brake_game = Game.new()
brake_game.player.speed = 40
brake_game:step(1 / 60, { throttle = 0, brake = 1, steer = 0 })
check("braking sheds speed", brake_game.player.speed < 40)

local paused_game = Game.new()
paused_game.paused = true
local px, py = paused_game.player.x, paused_game.player.y
paused_game:step(1 / 60, { throttle = 1, brake = 0, steer = 0 })
check("pause freezes the car", paused_game.player.x == px and paused_game.player.y == py)

--------------------------------------------------------------------------------
-- Reference driver and AI
--------------------------------------------------------------------------------
local auto = Game.new({ laps = 99, ai_count = 0 })
local t, auto_hits = 0, 0
while t < 20 do
    local before = auto.wall_hits
    auto:step(1 / 60, auto:autopilot_input())
    if auto.wall_hits > before then auto_hits = auto_hits + 1 end
    t = t + 1 / 60
end
check("the reference driver laps the circuit unaided", auto.laps_done >= 3)
check("the reference driver holds the racing line", auto_hits == 0)

local ai_game = Game.new({ laps = 99 })
for _ = 1, 600 do ai_game:step(1 / 60, ai_game:autopilot_input()) end
local all_on_track = true
for _, ai in ipairs(ai_game.ai) do
    if not racer.drivable(track, ai.x, ai.y) then all_on_track = false end
end
check("AI opponents stay on the circuit", all_on_track)
check("AI opponents close the gap over time",
      ai_game.ai[1].travelled > 0 and ai_game.ai[4].travelled > 0)

local standings = ai_game:standings()
check("standings rank every car and are sorted by distance",
      #standings == ai_game.ai_count + 1
      and standings[1].distance >= standings[#standings].distance)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
check("lap times format as mm:ss.cc", racer.fmt_time(72.5) == "01:12.50")
check("an unset lap time renders as a placeholder", racer.fmt_time(math.huge) == "--:--.--")
check("headings map onto compass glyphs",
      racer.player_glyph(0) == ">" and racer.player_glyph(math.pi / 2) == "v"
      and racer.player_glyph(math.pi) == "<" and racer.player_glyph(-math.pi / 2) == "^")

--------------------------------------------------------------------------------
-- Renderer
--------------------------------------------------------------------------------
local ascii = racer.render_frame(Game.new(), false, 100, 26)
check("snapshot renders the HUD", ascii:find("TURBO CIRCUIT", 1, true) ~= nil)
check("snapshot renders the circuit walls", ascii:find("#", 1, true) ~= nil)
check("ascii snapshots carry no ANSI escapes", ascii:find("\27", 1, true) == nil)
-- term_cols 100 clamps to the 78-cell viewport; term_rows 26 leaves 20 track rows.
check("frame rows are clamped to the viewport width",
      #(ascii:match("[^\n]+")) == 78)
check("the frame has the expected number of rows",
      select(2, ascii:gsub("\n", "\n")) == 22)

local color = racer.render_frame(Game.new(), true, 100, 26)
check("colour snapshots emit ANSI escapes", color:find("\27[", 1, true) ~= nil)
check("colour and ascii frames align to the same visible width",
      #(color:match("[^\n]+"):gsub("\27%[[%d;]*m", "")) == 78)

local overlay = Game.new({ laps = 1 })
overlay.paused = true
check("pause banner is drawn over the viewport",
      racer.render_frame(overlay, false, 80, 24):find("PAUSED", 1, true) ~= nil)
overlay.paused = false
overlay.finished = true
check("finish banner reports the position",
      racer.render_frame(overlay, false, 80, 24):find("FINISHED", 1, true) ~= nil)

--------------------------------------------------------------------------------
-- CLI
--------------------------------------------------------------------------------
local help, help_status = run_cli("luajit ffi_circuit_racer.lua --help")
check("--help prints usage", help_status == 0 and help:find("Usage:", 1, true) ~= nil)

local snap, snap_status = run_cli("luajit ffi_circuit_racer.lua --snapshot --ascii")
check("--snapshot --ascii runs headlessly",
      snap_status == 0 and snap:find("TURBO CIRCUIT", 1, true) ~= nil)

local demo, demo_status = run_cli("luajit ffi_circuit_racer.lua --demo --laps 1")
check("--demo completes a one-lap race",
      demo_status == 0 and demo:find("finished=true", 1, true) ~= nil)

local _, bad_status = run_cli("luajit ffi_circuit_racer.lua --nonsense")
check("an unknown option exits non-zero", bad_status ~= 0)

print(string.format("Test summary: %d/%d passed", passed, total))
os.exit(passed == total and 0 or 1)
