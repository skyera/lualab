#!/usr/bin/env luajit
--[[
    ffi_circuit_racer.lua
    Top-down ASCII circuit racer built with LuaJIT FFI.

    A closed-loop track is generated procedurally and rasterised into a grid
    once at startup; each frame only samples the visible viewport, so drawing
    stays O(viewport) no matter how large the circuit is. The player drives with
    2D heading physics against hard walls, AI opponents travel the centreline at
    staggered speeds, and laps are gated by ordered checkpoints so the loop
    cannot be cut across the infield.

    Controls: A/D or Left/Right steer, W/S or Up/Down throttle/brake,
              P pause, R restart, Q quit.
    Modes: --help, --test, --snapshot [--ascii], --demo [--laps N].
]]

local ffi = require("ffi")
local bit = require("bit")

-- math.atan2 was dropped in Lua 5.3 but LuaJIT still provides it; keep a
-- fallback so the module also loads under a plain interpreter.
local atan2 = math.atan2
if not atan2 then
    atan2 = function(y, x)
        if x > 0 then return math.atan(y / x) end
        if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
        if y > 0 then return math.pi / 2 end
        if y < 0 then return -math.pi / 2 end
        return 0
    end
end

local TAU = math.pi * 2

--------------------------------------------------------------------------------
-- 1. Track Geometry
--------------------------------------------------------------------------------
local COLS, ROWS = 120, 54          -- rasterised track grid
local ROAD_HALF = 4.5               -- road half-width in cells
local WALL_OUTER = ROAD_HALF + 1.0  -- outer edge of the wall band
local SAMPLE_SPACING = 1.0          -- centreline resolution in cells
local CAR_RADIUS = 0.5              -- collision radius of a car
local CHECK_COUNT = 12              -- lap gates per circuit
local CHECKPOINT_R = ROAD_HALF + 1.0
local CHECKPOINT_R2 = CHECKPOINT_R * CHECKPOINT_R

-- Cell values stored in the rasterised track grid.
local VOID, ROAD, WALL, START = 0, 1, 2, 3

-- Sample offsets used to test whether a car can occupy a position. Declared
-- once so the hot path never allocates.
local DRIVE_OFFSETS = {
    { -CAR_RADIUS, -CAR_RADIUS }, { CAR_RADIUS, -CAR_RADIUS },
    { -CAR_RADIUS,  CAR_RADIUS }, { CAR_RADIUS,  CAR_RADIUS },
}

local TRACK_CACHE

-- Build the circuit: sample a wobbling ellipse by arc length so centreline
-- points are evenly spaced, then rasterise a road band plus a one-cell wall
-- border and stamp a start/finish line across the road.
local bit = bit or require("bit")
-- macOS/BSD poll() is unreliable on character devices, so use select() there.
-- Mirrors poll()'s contract (return value plus pfd.revents) so callers that
-- inspect revents need no change. fd_set is FD_SETSIZE/8 == 128 bytes on both.
local function posix_wait(pfd, timeout_ms)
    if ffi.os ~= "OSX" and ffi.os ~= "BSD" then
        return ffi.C.poll(pfd, 1, timeout_ms)
    end
    -- Callers pass either a scalar `struct pollfd` or a `struct pollfd[1]`.
    -- Only the array form is indexable, so probe that rather than inspecting
    -- the ctype (a scalar ctype has no `elemtype`/`kind` field).
    local entry = pfd
    local ok = pcall(function() return pfd[0] end)
    if ok then entry = pfd[0] end
    entry.revents = 0
    -- Use bit.rshift/bit.band rather than the >> and & operators: the bundled
    -- LuaJIT build used by the test suite is compiled with 5.2 compatibility,
    -- where those operators are a syntax error.
    local fds = ffi.new("unsigned char[128]")
    local byte = bit.rshift(entry.fd, 3)
    fds[byte] = fds[byte] + 2 ^ bit.band(entry.fd, 7)
    local tv = ffi.new("PosixTimeval")
    tv.tv_sec = math.floor(timeout_ms / 1000)
    tv.tv_usec = (timeout_ms % 1000) * 1000
    if ffi.C.select(entry.fd + 1, fds, nil, nil, tv) > 0 then
        entry.revents = 1 -- POLLIN
        return 1
    end
    return 0
end

local function build_track()
    local steps = 1024
    local cx, cy = COLS / 2, ROWS / 2
    local rx, ry = 36, 21

    -- Harmonics must stay gentle: a radial perturbation of amplitude a and
    -- frequency k scales curvature by (1 + a*(1-k^2)*sin(k*t)), so a strong
    -- high-frequency term drives the corner radius through zero and turns the
    -- circuit into a kink the car cannot physically take.
    local pts = {}
    for i = 0, steps - 1 do
        local t = (i / steps) * TAU
        local wob = 1 + 0.07 * math.sin(2 * t + 0.5) + 0.03 * math.sin(4 * t)
        pts[i + 1] = { x = cx + rx * wob * math.cos(t), y = cy + ry * wob * math.sin(t) }
    end

    -- Cumulative arc length around the closed loop.
    local cum = { 0 }
    local perimeter = 0
    for i = 1, steps do
        local a, b = pts[i], pts[(i % steps) + 1]
        perimeter = perimeter + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        cum[i + 1] = perimeter
    end

    local count = math.max(24, math.floor(perimeter / SAMPLE_SPACING + 0.5))
    local spacing = perimeter / count

    -- Resample the polyline at even arc-length intervals.
    local samples = {}
    local seg = 1
    for j = 0, count - 1 do
        local target = j * spacing
        while seg <= steps and cum[seg + 1] < target do seg = seg + 1 end
        local s1 = pts[seg]
        local s2 = pts[(seg % steps) + 1]
        local seg_start = cum[seg]
        local seg_len = cum[seg + 1] - seg_start
        local f = (seg_len > 0) and ((target - seg_start) / seg_len) or 0
        samples[j + 1] = { x = s1.x + (s2.x - s1.x) * f, y = s1.y + (s2.y - s1.y) * f }
    end

    -- Tangents and normals, used by AI lateral offsets and the start heading.
    local n = #samples
    for i = 1, n do
        local prev = samples[(i - 2) % n + 1]
        local nxt = samples[i % n + 1]
        local tx, ty = nxt.x - prev.x, nxt.y - prev.y
        local len = math.sqrt(tx * tx + ty * ty)
        if len < 1e-9 then tx, ty, len = 1, 0, 1 end
        samples[i].tx, samples[i].ty = tx / len, ty / len
        samples[i].nx, samples[i].ny = -ty / len, tx / len
    end
    local start_heading = atan2(samples[2].y - samples[1].y, samples[2].x - samples[1].x)

    -- Rasterise: road within ROAD_HALF of the centreline, wall out to
    -- WALL_OUTER, everything else is void. Distance is measured from cell
    -- centres so the band edges fall on cell boundaries.
    local grid = {}
    local d2_road = ROAD_HALF * ROAD_HALF
    local d2_wall = WALL_OUTER * WALL_OUTER
    for y = 0, ROWS - 1 do
        for x = 0, COLS - 1 do
            local px, py = x + 0.5, y + 0.5
            local best = math.huge
            for s = 1, n do
                local sp = samples[s]
                local dx, dy = px - sp.x, py - sp.y
                local d2 = dx * dx + dy * dy
                if d2 < best then best = d2 end
            end
            local v = VOID
            if best <= d2_road then v = ROAD
            elseif best <= d2_wall then v = WALL end
            grid[y * COLS + x] = v
        end
    end

    -- Start/finish line: a disc across the road at the first sample.
    local s0 = samples[1]
    for y = 0, ROWS - 1 do
        for x = 0, COLS - 1 do
            local i = y * COLS + x
            if grid[i] == ROAD then
                local dx, dy = (x + 0.5) - s0.x, (y + 0.5) - s0.y
                if dx * dx + dy * dy <= d2_road then grid[i] = START end
            end
        end
    end

    -- Ordered checkpoint gates, evenly spaced around the lap.
    local checkpoints = {}
    for c = 0, CHECK_COUNT - 1 do
        local idx = math.floor(c * n / CHECK_COUNT) + 1
        checkpoints[#checkpoints + 1] = { x = samples[idx].x, y = samples[idx].y, idx = idx }
    end

    return {
        samples = samples,
        grid = grid,
        length = perimeter,
        spacing = spacing,
        count = n,
        start_heading = start_heading,
        checkpoints = checkpoints,
        road_half = ROAD_HALF,
    }
end

local function get_track()
    if not TRACK_CACHE then TRACK_CACHE = build_track() end
    return TRACK_CACHE
end

local function cell_value(track, px, py)
    local x, y = math.floor(px), math.floor(py)
    if x < 0 or y < 0 or x >= COLS or y >= ROWS then return VOID end
    return track.grid[y * COLS + x]
end

local function is_road(v)
    return v == ROAD or v == START
end

-- True when the car's centre and all four corners sit on tarmac.
local function drivable(track, px, py)
    if not is_road(cell_value(track, px, py)) then return false end
    for i = 1, #DRIVE_OFFSETS do
        local o = DRIVE_OFFSETS[i]
        if not is_road(cell_value(track, px + o[1], py + o[2])) then return false end
    end
    return true
end

local function nearest_sample(track, x, y)
    local samples = track.samples
    local best, bi = math.huge, 1
    for i = 1, #samples do
        local sp = samples[i]
        local dx, dy = x - sp.x, y - sp.y
        local d2 = dx * dx + dy * dy
        if d2 < best then best = d2; bi = i end
    end
    return bi
end

-- Position (and road normal) at an arc-length offset along the centreline.
-- Negative or oversized offsets wrap around the lap.
local function sample_at(track, arc)
    local length = track.length
    local a = arc % length
    if a < 0 then a = a + length end
    local f = a / track.spacing
    local i = math.floor(f) + 1
    local frac = f - math.floor(f)
    local samples = track.samples
    local n = #samples
    local s1 = samples[i]
    local s2 = samples[(i % n) + 1]
    return s1.x + (s2.x - s1.x) * frac,
           s1.y + (s2.y - s1.y) * frac,
           s1.nx, s1.ny
end

local function fmt_time(t)
    if t == nil or t == math.huge then return "--:--.--" end
    local m = math.floor(t / 60)
    return string.format("%02d:%05.2f", m, t - m * 60)
end

-- Heading quantised to eight compass glyphs.
local PLAYER_GLYPHS = { [0] = ">", [1] = "\\", [2] = "v", [3] = "/",
                        [4] = "<", [5] = "/", [6] = "^", [7] = "\\" }
local function player_glyph(heading)
    local a = heading % TAU
    if a < 0 then a = a + TAU end
    local sector = math.floor(a / (math.pi / 4) + 0.5) % 8
    return PLAYER_GLYPHS[sector]
end

--------------------------------------------------------------------------------
-- 2. Physics Constants
--------------------------------------------------------------------------------
local MAX_SPEED  = 58
local ACCEL      = 40
local BRAKE      = 75
local DRAG       = 14
local TURN_RATE  = 3.4
local WALL_DAMP  = 0.45   -- speed retained when a wall blocks a move
local BUMP_RANGE = 2.2    -- player/AI contact distance
local KMH = 2.5           -- display conversion for "km/h"
-- AI is deliberately slower off the line than the player (30 vs 40 cells/s^2)
-- so a clean launch pulls clear of the grid instead of being rear-ended.
local AI_ACCEL   = 30
local AI_DECEL   = 45

--------------------------------------------------------------------------------
-- 3. Game Logic (pure Lua, fully headless-testable)
--------------------------------------------------------------------------------
local Game = {}
Game.__index = Game

function Game.new(opts)
    opts = opts or {}
    local track = get_track()
    local self = setmetatable({}, Game)

    self.track = track
    self.total_laps = opts.laps or 3
    self.ai_count = (opts.ai_count ~= nil) and opts.ai_count or 4
    self.laps_done = 0
    self.lap = 1
    self.lap_time = 0
    self.race_time = 0
    self.best_lap = math.huge
    self.last_lap = nil
    self.finished = false
    self.paused = false
    self.wall_hits = 0
    self.next_cp = 1
    self.checkpoints = track.checkpoints

    local s0 = track.samples[1]
    self.player = {
        x = s0.x, y = s0.y,
        heading = track.start_heading,
        speed = 0,
        sample_idx = 1,
    }

    -- AI opponents travel the centreline by arc length, staggered onto a
    -- starting grid just behind the line.
    self.ai = {}
    for i = 1, self.ai_count do
        local row = math.floor((i + 1) / 2)
        self.ai[i] = {
            start_prog = -row * 10,
            travelled = -i * 0.5,
            speed = 0,
            -- Paced just under a clean racing line (~4.7s/lap for the reference
            -- autopilot) so opponents are beatable but not a walkover.
            base = 37 + ((i - 1) % 3) * 3,
            amp = 3,
            wave = 0.6 + i * 0.13,
            phase = i * 1.7,
            offset_base = (i % 2 == 1) and -1.4 or 1.4,
            offset = 0, prog = 0, x = s0.x, y = s0.y,
        }
        local x, y = sample_at(track, self.ai[i].start_prog)
        self.ai[i].x, self.ai[i].y = x, y
    end

    return self
end

function Game:player_distance()
    return self.laps_done * self.track.length
         + (self.player.sample_idx - 1) * self.track.spacing
end

function Game:standings()
    local list = { { name = "YOU", distance = self:player_distance(), is_player = true } }
    for i, ai in ipairs(self.ai) do
        list[#list + 1] = { name = "CPU" .. i, distance = ai.travelled, is_player = false }
    end
    table.sort(list, function(a, b) return a.distance > b.distance end)
    return list
end

function Game:position()
    local list = self:standings()
    for i, e in ipairs(list) do
        if e.is_player then return i, #list end
    end
    return 1, #list
end

function Game:update_progress()
    local cp = self.checkpoints[self.next_cp]
    local p = self.player
    local dx, dy = p.x - cp.x, p.y - cp.y
    if dx * dx + dy * dy <= CHECKPOINT_R2 then
        self.next_cp = self.next_cp + 1
        if self.next_cp > #self.checkpoints then
            self.next_cp = 1
            self:complete_lap()
        end
    end
end

function Game:complete_lap()
    self.last_lap = self.lap_time
    if self.lap_time < self.best_lap then self.best_lap = self.lap_time end
    self.laps_done = self.laps_done + 1
    self.lap_time = 0
    if self.laps_done >= self.total_laps then
        self.finished = true
        self.lap = self.total_laps
    else
        self.lap = self.laps_done + 1
    end
end

function Game:update_ai(dt)
    for _, ai in ipairs(self.ai) do
        -- Ease toward the target pace rather than snapping to it, so the AI
        -- accelerates off the line in step with the player.
        local target = ai.base + math.sin(self.race_time * ai.wave + ai.phase) * ai.amp
        if ai.speed < target then
            ai.speed = math.min(target, ai.speed + AI_ACCEL * dt)
        else
            ai.speed = math.max(target, ai.speed - AI_DECEL * dt)
        end
        ai.travelled = ai.travelled + ai.speed * dt
        ai.prog = ai.start_prog + ai.travelled
        local x, y, nx, ny = sample_at(self.track, ai.prog)
        local lim = ROAD_HALF - 1
        local off = ai.offset_base + math.sin(self.race_time * 0.7 + ai.phase) * 0.5
        ai.offset = math.max(-lim, math.min(lim, off))
        ai.x = x + nx * ai.offset
        ai.y = y + ny * ai.offset
    end
end

function Game:resolve_collisions()
    local p = self.player
    for _, ai in ipairs(self.ai) do
        local dx, dy = p.x - ai.x, p.y - ai.y
        local d2 = dx * dx + dy * dy
        if d2 < BUMP_RANGE * BUMP_RANGE and d2 > 1e-6 then
            local d = math.sqrt(d2)
            local push = (BUMP_RANGE - d)
            local nx = p.x + (dx / d) * push
            local ny = p.y + (dy / d) * push
            -- Only shove the player if the result is still on the road,
            -- otherwise a side-by-side touch could squeeze them into a wall.
            if drivable(self.track, nx, ny) then p.x, p.y = nx, ny end
            -- Contact should cost the car behind far more than the one being
            -- nudged, otherwise a chasing pack can pin the player to a standstill.
            p.speed = p.speed * 0.95
            ai.speed = ai.speed * 0.6
            ai.travelled = ai.travelled - 3.0
        end
    end
end

-- dt is in seconds; input is { throttle = 0/1, brake = 0/1, steer = -1/0/1 }.
function Game:step(dt, input)
    if self.paused or self.finished then return end
    dt = math.min(dt, 0.05)
    local p = self.player

    if input.throttle > 0 then
        p.speed = p.speed + ACCEL * dt
    elseif input.brake > 0 then
        p.speed = p.speed - BRAKE * dt
    else
        p.speed = p.speed - DRAG * dt
    end
    p.speed = math.max(0, math.min(p.speed, MAX_SPEED))

    -- Steering authority grows with speed so a stationary car cannot pirouette.
    local grip = 0.35 + 0.65 * math.min(1, p.speed / 20)
    p.heading = p.heading + (input.steer or 0) * TURN_RATE * grip * dt

    -- Axis-separated movement: a blocked component slides along the wall
    -- instead of stopping dead, which keeps the car feeling planted.
    local dx = math.cos(p.heading) * p.speed * dt
    local dy = math.sin(p.heading) * p.speed * dt
    if drivable(self.track, p.x + dx, p.y) then
        p.x = p.x + dx
    else
        p.speed = p.speed * WALL_DAMP
        self.wall_hits = self.wall_hits + 1
    end
    if drivable(self.track, p.x, p.y + dy) then
        p.y = p.y + dy
    else
        p.speed = p.speed * WALL_DAMP
        self.wall_hits = self.wall_hits + 1
    end

    p.sample_idx = nearest_sample(self.track, p.x, p.y)
    self:update_progress()
    self:update_ai(dt)
    self:resolve_collisions()
    self.race_time = self.race_time + dt
    self.lap_time = self.lap_time + dt
end

-- Pure-pursuit driver used by --snapshot and --demo so headless runs produce a
-- representative frame without any terminal interaction.
function Game:autopilot_input()
    local p = self.player
    local samples, n = self.track.samples, self.track.count
    local idx = p.sample_idx or 1

    -- Look ahead and total the heading change that is coming up, so the car
    -- slows for a corner instead of arriving at full speed and scraping the wall.
    local turn = 0
    local prev = samples[idx]
    for k = 1, 18 do
        local s = samples[(idx - 1 + k) % n + 1]
        local a1, a2 = atan2(prev.ty, prev.tx), atan2(s.ty, s.tx)
        turn = turn + math.abs((a2 - a1 + math.pi) % TAU - math.pi)
        prev = s
    end
    local target = MAX_SPEED * math.max(0.34, 1 - turn * 0.5)

    local lookahead = 4 + p.speed * 0.20
    local arc = ((idx - 1) + lookahead) * self.track.spacing
    local tx, ty = sample_at(self.track, arc)
    local diff = (atan2(ty - p.y, tx - p.x) - p.heading + math.pi) % TAU - math.pi
    -- Proportional steering, not bang-bang: full lock every frame saws the car
    -- into the barriers on a circuit this curvy.
    local steer = math.max(-1, math.min(1, diff * 1.3))
    local throttle = (p.speed < target) and 1 or 0
    local brake = (p.speed > target + 4) and 1 or 0
    return { throttle = throttle, brake = brake, steer = steer }
end

--------------------------------------------------------------------------------
-- 4. Renderer
--------------------------------------------------------------------------------
local GLYPHS = { [VOID] = " ", [ROAD] = " ", [WALL] = "#", [START] = "=" }

-- Style table indices: 0 reset, 1 road, 2 wall, 3 start, 4 player, 5 AI,
-- 6 HUD text, 7 HUD dim.
local STYLES = {
    [0] = "\27[0m",
    [1] = "\27[48;5;236m",
    [2] = "\27[48;5;238m\27[38;5;250m",
    [3] = "\27[48;5;236m\27[1;97m",
    [4] = "\27[48;5;236m\27[1;93m",
    [5] = "\27[48;5;236m\27[1;96m",
    [6] = "\27[48;5;234m\27[1;97m",
    [7] = "\27[48;5;234m\27[90m",
}

local function fit(s, w)
    if #s > w then return s:sub(1, w) end
    return s .. string.rep(" ", w - #s)
end

-- Serialise one viewport row, emitting a colour escape only when the style
-- changes rather than once per cell.
local function row_to_string(ch, st, w, use_color)
    local parts = {}
    local cur = -1
    for c = 1, w do
        local s = st[c]
        if s ~= cur then
            if use_color then parts[#parts + 1] = STYLES[s] end
            cur = s
        end
        parts[#parts + 1] = ch[c]
    end
    if use_color then parts[#parts + 1] = STYLES[0] end
    return table.concat(parts)
end

local function put_text(ch, st, w, text, style)
    local start = math.max(1, math.floor((w - #text) / 2) + 1)
    for i = 1, #text do
        local c = start + i - 1
        if c >= 1 and c <= w then
            ch[c] = text:sub(i, i)
            st[c] = style
        end
    end
end

-- Returns a plain multi-line string (no cursor addressing) so it can be
-- printed directly by --snapshot or wrapped in a synchronized update by the
-- interactive loop.
local function render_frame(game, use_color, term_cols, term_rows)
    term_cols = term_cols or 80
    term_rows = term_rows or 24
    -- AGENTS.md TUI standard: clamp to cols-1 so a full row never wraps.
    local vpw = math.max(30, math.min(78, term_cols - 1))
    local vph = math.max(6, math.min(20, term_rows - 3))

    local track = game.track
    local cam_x = math.floor(game.player.x - vpw / 2 + 0.5)
    local cam_y = math.floor(game.player.y - vph / 2 + 0.5)
    cam_x = math.max(0, math.min(COLS - vpw, cam_x))
    cam_y = math.max(0, math.min(ROWS - vph, cam_y))

    local pos, total = game:position()
    local lines = {}

    local hud = string.format(
        " TURBO CIRCUIT   LAP %d/%d   POS %d/%d   SPD %3d km/h   LAP %s   BEST %s ",
        game.lap, game.total_laps, pos, total,
        math.floor(game.player.speed * KMH), fmt_time(game.lap_time), fmt_time(game.best_lap))
    lines[#lines + 1] = use_color and (STYLES[6] .. fit(hud, vpw) .. STYLES[0]) or fit(hud, vpw)

    local ents = {
        {
            col = math.floor(game.player.x) - cam_x + 1,
            row = math.floor(game.player.y) - cam_y + 1,
            glyph = player_glyph(game.player.heading), ascii = "@", style = 4,
        },
    }
    for _, ai in ipairs(game.ai) do
        ents[#ents + 1] = {
            col = math.floor(ai.x) - cam_x + 1,
            row = math.floor(ai.y) - cam_y + 1,
            glyph = "o", ascii = "o", style = 5,
        }
    end

    -- Overlay banners for pause / finish.
    local overlay = {}
    if game.paused then
        overlay = { "== PAUSED ==", "[P] Resume   [R] Restart   [Q] Quit" }
    elseif game.finished then
        overlay = {
            "== FINISHED ==",
            string.format("POSITION %d/%d", pos, total),
            string.format("BEST LAP %s", fmt_time(game.best_lap)),
            "[R] Race again   [Q] Quit",
        }
    end
    local ov_start = math.floor((vph - #overlay) / 2) + 1

    local ch, st = {}, {}
    for vr = 0, vph - 1 do
        local gy = cam_y + vr
        for vc = 0, vpw - 1 do
            local v = track.grid[gy * COLS + (cam_x + vc)] or VOID
            local col = vc + 1
            ch[col] = GLYPHS[v] or " "
            st[col] = (v == START) and 3 or ((v == WALL) and 2 or (v == ROAD and 1 or 0))
        end
        for e = 1, #ents do
            local ent = ents[e]
            if ent.row == vr + 1 and ent.col >= 1 and ent.col <= vpw then
                ch[ent.col] = use_color and ent.glyph or ent.ascii
                st[ent.col] = ent.style
            end
        end
        if #overlay > 0 then
            local oi = vr + 1 - ov_start + 1
            if oi >= 1 and oi <= #overlay then
                put_text(ch, st, vpw, overlay[oi], 6)
            end
        end
        lines[#lines + 1] = row_to_string(ch, st, vpw, use_color)
    end

    local ctl = " [A/D] Steer   [W/S] Throttle/Brake   [P] Pause   [R] Restart   [Q] Quit "
    lines[#lines + 1] = use_color and (STYLES[7] .. fit(ctl, vpw) .. STYLES[0]) or fit(ctl, vpw)

    local prog = (game:player_distance() % track.length) / track.length
    local filled = math.max(0, math.min(20, math.floor(prog * 20)))
    local bar = string.rep("=", filled) .. ">" .. string.rep(".", 20 - filled)
    local bot = string.format(" NEXT CP %d/%d   WALL HITS %d   LAP PROGRESS %s ",
                              game.next_cp, #game.checkpoints, game.wall_hits, bar)
    lines[#lines + 1] = use_color and (STYLES[7] .. fit(bot, vpw) .. STYLES[0]) or fit(bot, vpw)

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- 5. Built-in Self Tests
--------------------------------------------------------------------------------
local function run_self_tests()
    local function check(name, condition)
        assert(condition, "FAIL: " .. name)
        print("  PASS: " .. name)
    end

    local track = get_track()
    check("track rasterises road, wall and start cells",
          #track.samples > 100 and track.length > 100)

    local road_cells, wall_cells, start_cells = 0, 0, 0
    for _, v in pairs(track.grid) do
        if v == ROAD then road_cells = road_cells + 1
        elseif v == WALL then wall_cells = wall_cells + 1
        elseif v == START then start_cells = start_cells + 1 end
    end
    check("road band, wall border and start line all exist",
          road_cells > 500 and wall_cells > 100 and start_cells >= 1)
    check("the start line sits on drivable tarmac", drivable(track, track.samples[1].x, track.samples[1].y))
    check("open ground is not drivable", not drivable(track, 1.5, 1.5))

    -- Walking the centreline in order must trip every gate and bank a lap.
    local g = Game.new({ laps = 3 })
    for _ = 1, 3 do
        for i = 1, track.count do
            local s = track.samples[i]
            g.player.x, g.player.y = s.x, s.y
            g.player.sample_idx = i
            g:update_progress()
        end
    end
    check("ordered checkpoints bank three laps and finish the race",
          g.finished and g.laps_done == 3)

    local g2 = Game.new()
    check("player starts ahead of the grid", g2:position() == 1 and select(2, g2:position()) == g2.ai_count + 1)

    -- Driving straight at a wall must never put the car off the road.
    local g3 = Game.new()
    g3.player.heading = track.start_heading + math.pi / 2
    g3.player.speed = 55
    for _ = 1, 40 do g3:step(1 / 60, { throttle = 1, brake = 0, steer = 0 }) end
    check("wall collision is registered and the car stays on tarmac",
          g3.wall_hits > 0 and drivable(track, g3.player.x, g3.player.y))

    -- The pure-pursuit driver should be able to lap the circuit unaided.
    local g4 = Game.new({ laps = 99 })
    local t = 0
    while t < 90 and g4.laps_done < 1 do
        g4:step(1 / 60, g4:autopilot_input())
        t = t + 1 / 60
    end
    check("autopilot completes a lap within 90 simulated seconds", g4.laps_done >= 1)

    local frame = render_frame(Game.new(), false, 80, 24)
    check("snapshot renderer produces the HUD and the circuit",
          frame:find("TURBO CIRCUIT", 1, true) ~= nil and frame:find("#", 1, true) ~= nil)
    check("frames are rendered at the requested width",
          #(frame:match("[^\n]+")) == 78)

    print("ALL CIRCUIT RACER TESTS PASSED")
end

--------------------------------------------------------------------------------
-- 6. Terminal Backend (LuaJIT FFI)
--------------------------------------------------------------------------------
local SYNC_START = "\27[?2026h"
local SYNC_END = "\27[?2026l"
local terminal_callbacks = {}

local function launch_game(use_color)
    local is_windows = ffi.os == "Windows"
    local kernel32, msvcrt
    local original_mode, original_output_mode, original_termios
    local input_handle, output_handle
    local raw_enabled = false
    local interrupted = false
    local old_input_codepage, old_output_codepage
    local pollfd, input_buf

    if is_windows then
        ffi.cdef[[
            typedef struct { short X; short Y; } RacerCoord;
            typedef struct { short Left; short Top; short Right; short Bottom; } RacerRect;
            typedef struct {
                RacerCoord dwSize;
                RacerCoord dwCursorPosition;
                uint16_t   wAttributes;
                RacerRect  srWindow;
                RacerCoord dwMaximumWindowSize;
            } RacerConsoleInfo;
            int __stdcall GetConsoleMode(void *handle, uint32_t *mode);
            int __stdcall SetConsoleMode(void *handle, uint32_t mode);
            void *__stdcall GetStdHandle(uint32_t which);
            int __stdcall SetConsoleOutputCP(uint32_t codepage);
            uint32_t __stdcall GetConsoleCP(void);
            int __stdcall SetConsoleCP(uint32_t codepage);
            uint32_t __stdcall GetConsoleOutputCP(void);
            void __stdcall Sleep(uint32_t milliseconds);
            int __stdcall GetConsoleScreenBufferInfo(void *handle, RacerConsoleInfo *info);
            uint64_t __stdcall GetTickCount64(void);
            int _kbhit(void);
            int _getch(void);
        ]]
        kernel32 = ffi.load("kernel32")
        msvcrt = ffi.load("msvcrt")
    else
                -- macOS/BSD declare tcflag_t/speed_t as 64-bit and set NCCS to 20, while Linux
        -- uses 32-bit and NCCS=32.  Picking the wrong layout shifts every field offset
        -- and makes tcgetattr overrun the LuaJIT buffer, so select it at cdef time.
        -- On Linux the definition below passes through byte-for-byte unchanged.
        local function posix_termios_cdef(def)
            if ffi.os == "OSX" or ffi.os == "BSD" then
                def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
                def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
                def = def:gsub("c_cc%[32%]", "c_cc[20]")
            end
            return def
        end

ffi.cdef(posix_termios_cdef[[
            typedef unsigned char racer_cc_t;
            typedef unsigned int racer_speed_t;
            typedef unsigned int racer_tcflag_t;
            struct RacerTermios {
                racer_tcflag_t c_iflag;
                racer_tcflag_t c_oflag;
                racer_tcflag_t c_cflag;
                racer_tcflag_t c_lflag;
                racer_cc_t     c_line;
                racer_cc_t     c_cc[32];
                racer_speed_t  c_ispeed;
                racer_speed_t  c_ospeed;
            };
            struct RacerPollfd { int fd; short events; short revents; };
            struct RacerTimespec { long tv_sec; long tv_nsec; };
            int tcgetattr(int fd, struct RacerTermios *termios_p);
            int tcsetattr(int fd, int actions, const struct RacerTermios *termios_p);
            typedef struct { long tv_sec; long tv_usec; } PosixTimeval;
            int select(int nfds, void *readfds, void *writefds, void *exceptfds, PosixTimeval *timeout);
            int poll(struct RacerPollfd *fds, unsigned long nfds, int timeout);
            long read(int fd, void *buf, size_t count);
            int clock_gettime(int clock_id, struct RacerTimespec *tp);
            int usleep(unsigned int usec);
            int ioctl(int fd, unsigned long request, void *argp);
            typedef void (*racer_sighandler_t)(int);
            racer_sighandler_t signal(int signum, racer_sighandler_t handler);
]])

    end

    local function restore_terminal()
        if not raw_enabled then return end
        if is_windows then
            if input_handle then kernel32.SetConsoleMode(input_handle, original_mode[0]) end
            if output_handle then kernel32.SetConsoleMode(output_handle, original_output_mode[0]) end
            if old_input_codepage and old_input_codepage ~= 0 then kernel32.SetConsoleCP(old_input_codepage) end
            if old_output_codepage and old_output_codepage ~= 0 then kernel32.SetConsoleOutputCP(old_output_codepage) end
        elseif original_termios then
            ffi.C.tcsetattr(0, 0, original_termios)
        end
        raw_enabled = false
        -- Re-enable auto-wrap, leave the alternate buffer, show the cursor.
        io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
        io.flush()
    end

    local function enter_terminal()
        if is_windows then
            input_handle = kernel32.GetStdHandle(0xFFFFFFF6)
            output_handle = kernel32.GetStdHandle(0xFFFFFFF5)
            original_mode, original_output_mode = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
            assert(kernel32.GetConsoleMode(input_handle, original_mode) ~= 0, "stdin is not a Windows console")
            assert(kernel32.GetConsoleMode(output_handle, original_output_mode) ~= 0, "stdout is not a Windows console")
            old_input_codepage = kernel32.GetConsoleCP()
            old_output_codepage = kernel32.GetConsoleOutputCP()
            kernel32.SetConsoleOutputCP(65001)
            kernel32.SetConsoleCP(65001)
            -- ENABLE_VIRTUAL_TERMINAL_PROCESSING, and strip line/echo/processed input.
            kernel32.SetConsoleMode(output_handle, bit.bor(original_output_mode[0], 0x0004))
            kernel32.SetConsoleMode(input_handle,
                bit.band(original_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004)))
            raw_enabled = true
        else
            original_termios = ffi.new("struct RacerTermios")
            assert(ffi.C.tcgetattr(0, original_termios) == 0, "Turbo Circuit requires an interactive terminal")
            local raw = ffi.new("struct RacerTermios")
            ffi.copy(raw, original_termios, ffi.sizeof("struct RacerTermios"))
            -- No canonical input, echo or signal processing, and no flow control.
            raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
            raw.c_iflag = bit.band(raw.c_iflag, bit.bnot(bit.bor(0x0400, 0x0100)))
            raw.c_cc[5], raw.c_cc[6] = 0, 0
            assert(ffi.C.tcsetattr(0, 0, raw) == 0, "could not enable raw terminal mode")
            raw_enabled = true
            pollfd = ffi.new("struct RacerPollfd", { fd = 0, events = 1, revents = 0 })
            input_buf = ffi.new("char[64]")
        end
        -- Alternate screen, hide cursor, disable auto-wrap, clear once.
        io.write("\27[?1049h\27[?25l\27[?7l\27[2J")
        io.flush()
    end

    local function get_time()
        if is_windows then return tonumber(kernel32.GetTickCount64()) / 1000 end
        local ts = ffi.new("struct RacerTimespec")
        ffi.C.clock_gettime(1, ts)
        return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
    end

    local function sleep_ms(ms)
        if ms <= 0 then return end
        if is_windows then kernel32.Sleep(math.floor(ms)) else ffi.C.usleep(math.floor(ms * 1000)) end
    end

    local function get_term_size()
        if is_windows and output_handle then
            local info = ffi.new("RacerConsoleInfo")
            if kernel32.GetConsoleScreenBufferInfo(output_handle, info) ~= 0 then
                return info.srWindow.Right - info.srWindow.Left + 1,
                       info.srWindow.Bottom - info.srWindow.Top + 1
            end
            return 80, 24
        end
        local ws = ffi.new("struct { unsigned short rows, cols, xpixel, ypixel; }")
        if ffi.C.ioctl(1, (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413, ws) == 0 and ws.cols > 0 then
            return tonumber(ws.cols), tonumber(ws.rows)
        end
        return 80, 24
    end

    local input_queue = {}

    local function read_key(timeout_ms)
        if #input_queue > 0 then return table.remove(input_queue, 1) end
        if is_windows then
            local elapsed = 0
            while elapsed < timeout_ms do
                if msvcrt._kbhit() ~= 0 then
                    local ch = msvcrt._getch()
                    if ch == 0 or ch == 224 then
                        local code = msvcrt._getch()
                        if code == 72 then return "up"
                        elseif code == 80 then return "down"
                        elseif code == 75 then return "left"
                        elseif code == 77 then return "right" end
                    elseif ch == 27 then return "q"
                    elseif ch == 3 then return "q"
                    else return string.char(ch):lower() end
                end
                kernel32.Sleep(2)
                elapsed = elapsed + 2
            end
            return nil
        end
        pollfd.revents = 0
        if posix_wait(pollfd, timeout_ms) <= 0 then return nil end
        local n = ffi.C.read(0, input_buf, 64)
        if n <= 0 then return nil end
        local keys, i = {}, 0
        while i < n do
            local ch = input_buf[i]
            if ch == 27 and i + 2 < n and input_buf[i + 1] == 91 then
                local code = input_buf[i + 2]
                if code == 65 then keys[#keys + 1] = "up"
                elseif code == 66 then keys[#keys + 1] = "down"
                elseif code == 67 then keys[#keys + 1] = "right"
                elseif code == 68 then keys[#keys + 1] = "left" end
                i = i + 3
            else
                local s = string.char(ch):lower()
                if s == "\3" then s = "q" end
                keys[#keys + 1] = s
                i = i + 1
            end
        end
        for j = 2, #keys do input_queue[#input_queue + 1] = keys[j] end
        return keys[1]
    end

    -- Signal traps must live in the FFI callbacks table, or the GC can collect
    -- them and the handler becomes a dangling pointer.
    if not is_windows then
        local cb = ffi.cast("racer_sighandler_t", function() interrupted = true end)
        terminal_callbacks[#terminal_callbacks + 1] = cb
        ffi.C.signal(2, cb)   -- SIGINT
        ffi.C.signal(15, cb)  -- SIGTERM
    end

    -- A JIT-compiled FFI call that ends up invoking a callback panics with
    -- "bad callback" (see LuaJIT's FFI semantics doc). The polling loop makes
    -- FFI calls and a signal can fire the Lua handler at any point, which would
    -- otherwise leave the terminal stuck in the alternate buffer. Running the
    -- interactive loop interpreted is cheap enough and removes the hazard.
    local has_jit, jit_mod = pcall(require, "jit")
    if has_jit then jit_mod.off() end

    local game = Game.new()
    local act = { throttle = 0, brake = 0, left = 0, right = 0 }
    local last_cols, last_rows = 0, 0

    local function draw()
        local cols, rows = get_term_size()
        local clear = ""
        if cols ~= last_cols or rows ~= last_rows then
            -- Full clears are reserved for resize (AGENTS.md TUI standard).
            clear = "\27[2J"
            last_cols, last_rows = cols, rows
        end
        local frame = render_frame(game, use_color, cols, rows)
        io.write(SYNC_START .. clear .. "\27[H" .. frame .. SYNC_END)
        io.flush()
    end

    local ok, err = pcall(function()
        enter_terminal()
        last_cols, last_rows = get_term_size()
        local last = get_time()
        local running = true
        while running and not interrupted do
            local frame_start = get_time()

            local key = read_key(6)
            while key do
                if key == "q" then
                    running = false
                    break
                elseif key == "left" or key == "a" then act.left = 0.12
                elseif key == "right" or key == "d" then act.right = 0.12
                elseif key == "up" or key == "w" then act.throttle = 0.12
                elseif key == "down" or key == "s" then act.brake = 0.12
                elseif key == "p" and not game.finished then game.paused = not game.paused
                elseif key == "r" then game = Game.new(); act = { throttle = 0, brake = 0, left = 0, right = 0 }
                end
                key = read_key(0)
            end

            local now = get_time()
            local dt = math.min(0.05, now - last)
            last = now
            act.throttle = math.max(0, act.throttle - dt)
            act.brake = math.max(0, act.brake - dt)
            act.left = math.max(0, act.left - dt)
            act.right = math.max(0, act.right - dt)

            local input = {
                throttle = act.throttle > 0 and 1 or 0,
                brake = act.brake > 0 and 1 or 0,
                steer = (act.left > 0 and -1 or 0) + (act.right > 0 and 1 or 0),
            }
            game:step(dt, input)
            draw()

            -- Cap at ~60 FPS without busy-waiting on a full frame.
            local spent = get_time() - frame_start
            if spent < 1 / 60 then sleep_ms((1 / 60 - spent) * 1000) end
        end
    end)

    restore_terminal()
    if has_jit then jit_mod.on() end
    if not ok then error(err) end

    local pos, total = game:position()
    if game.finished then
        print(string.format("Race finished — position %d/%d, best lap %s.", pos, total, fmt_time(game.best_lap)))
    else
        print(string.format("Race abandoned — lap %d/%d, position %d/%d.", game.lap, game.total_laps, pos, total))
    end
end

--------------------------------------------------------------------------------
-- 7. CLI
--------------------------------------------------------------------------------
local function print_help()
    print([[Turbo Circuit — LuaJIT FFI Top-Down ASCII Circuit Racer

Usage: luajit ffi_circuit_racer.lua [--help|--test|--snapshot|--demo] [--ascii] [--laps N]

Controls: A/D or Left/Right steer, W/S or Up/Down throttle/brake,
          P pause, R restart, Q quit.

Modes:
  --help         Show this help.
  --test         Run the built-in self tests.
  --snapshot     Print one frame non-interactively.
  --demo         Drive the circuit with the autopilot and report the result.
  --ascii        Disable colour (for --snapshot / --demo / play).
  --laps N       Number of laps in a race (default 3).

Example: luajit ffi_circuit_racer.lua
         luajit ffi_circuit_racer.lua --snapshot --ascii]])
end

local function main(args)
    local snapshot, demo, ascii, laps = false, false, false, nil
    local i = 1
    while i <= #args do
        local option = args[i]
        if option == "--help" or option == "-h" then print_help(); return
        elseif option == "--test" then run_self_tests(); return
        elseif option == "--snapshot" then snapshot = true
        elseif option == "--demo" then demo = true
        elseif option == "--ascii" then ascii = true
        elseif option == "--laps" then
            i = i + 1
            laps = tonumber(args[i])
            if not laps or laps < 1 then
                io.stderr:write("--laps needs a positive number\n")
                os.exit(2)
            end
        else
            io.stderr:write("Unknown option: " .. tostring(option) .. "\n")
            print_help()
            os.exit(2)
        end
        i = i + 1
    end

    if snapshot then
        local game = Game.new({ laps = laps or 3 })
        for _ = 1, 180 do game:step(1 / 60, game:autopilot_input()) end
        print(render_frame(game, not ascii, 80, 24))
        return
    end

    if demo then
        local game = Game.new({ laps = laps or 3 })
        local t = 0
        while not game.finished and t < 300 do
            game:step(1 / 60, game:autopilot_input())
            t = t + 1 / 60
        end
        print(string.format(
            "demo: finished=%s laps=%d/%d best=%s elapsed=%.1fs wall_hits=%d",
            tostring(game.finished), game.laps_done, game.total_laps,
            fmt_time(game.best_lap), t, game.wall_hits))
        return
    end

    launch_game(not ascii)
end

local M = {
    Game = Game,
    build_track = build_track,
    get_track = get_track,
    render_frame = render_frame,
    sample_at = sample_at,
    nearest_sample = nearest_sample,
    drivable = drivable,
    cell_value = cell_value,
    fmt_time = fmt_time,
    player_glyph = player_glyph,
    COLS = COLS,
    ROWS = ROWS,
    ROAD_HALF = ROAD_HALF,
    CHECK_COUNT = CHECK_COUNT,
    MAX_SPEED = MAX_SPEED,
}

if ... == "ffi_circuit_racer" then
    return M
end
main(arg or {})
