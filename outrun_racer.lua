#!/usr/bin/env luajit
--[[
  outrun_racer.lua - Fast Pseudo-3D Road Racer in LuaJIT FFI
  Zero external dependencies. Pure POSIX syscalls + ANSI VT100 / TrueColor output.
--]]

local ffi = require("ffi")
local bit = require("bit")

-- POSIX definitions for x86_64 Linux
ffi.cdef[[
  typedef unsigned char cc_t;
  typedef unsigned int  speed_t;
  typedef unsigned int  tcflag_t;

  struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;
    cc_t     c_line;
    cc_t     c_cc[32];
    speed_t  c_ispeed;
    speed_t  c_ospeed;
  };

  struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
  };

  struct pollfd {
    int   fd;
    short events;
    short revents;
  };

  struct timespec {
    long tv_sec;
    long tv_nsec;
  };

  int tcgetattr(int fd, struct termios *termios_p);
  int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
  int ioctl(int fd, unsigned long request, ...);
  int poll(struct pollfd *fds, unsigned long nfds, int timeout);
  long read(int fd, void *buf, size_t count);
  long write(int fd, const void *buf, size_t count);
  int clock_gettime(int clk_id, struct timespec *tp);
  int usleep(unsigned int usec);
]]

local C = ffi.C

-- Constants
local TCSANOW    = 0
local TIOCGWINSZ = 0x5413
local POLLIN     = 0x0001
local CLOCK_MONO = 1

-- Terminal state management
local orig_termios = ffi.new("struct termios")
local raw_termios  = ffi.new("struct termios")
local is_raw = false

local function restore_terminal()
  if is_raw then
    C.tcsetattr(0, TCSANOW, orig_termios)
    -- Show cursor, leave alternate screen buffer
    io.write("\27[?25h\27[?1049l\27[0m")
    io.flush()
    is_raw = false
  end
end

local function init_terminal()
  if C.tcgetattr(0, orig_termios) ~= 0 then
    error("Failed to get terminal attributes")
  end
  ffi.copy(raw_termios, orig_termios, ffi.sizeof("struct termios"))
  
  -- Set raw mode: disable ECHO, ICANON, ISIG, IEXTEN
  raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(0x0008, 0x0002, 0x0001, 0x8000)))
  -- disable IXON, ICRNL
  raw_termios.c_iflag = bit.band(raw_termios.c_iflag, bit.bnot(bit.bor(0x0400, 0x0100)))
  raw_termios.c_cc[5] = 0 -- VMIN
  raw_termios.c_cc[6] = 0 -- VTIME

  if C.tcsetattr(0, TCSANOW, raw_termios) ~= 0 then
    error("Failed to set raw terminal mode")
  end
  is_raw = true

  -- Enter alternate screen buffer, clear screen, hide cursor
  io.write("\27[?1049h\27[2J\27[?25l")
  io.flush()
end

local function get_term_size()
  local ws = ffi.new("struct winsize")
  if C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 10 and ws.ws_row > 10 then
    return tonumber(ws.ws_col), tonumber(ws.ws_row)
  end
  return 80, 24
end

local function get_time_sec()
  local ts = ffi.new("struct timespec")
  C.clock_gettime(CLOCK_MONO, ts)
  return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

-- Non-blocking input reader
local pollfd = ffi.new("struct pollfd", {fd = 0, events = POLLIN, revents = 0})
local in_buf = ffi.new("char[64]")

local function read_keys()
  local keys = {}
  while true do
    pollfd.revents = 0
    local ret = C.poll(pollfd, 1, 0)
    if ret <= 0 then break end
    local n = C.read(0, in_buf, 64)
    if n <= 0 then break end
    local i = 0
    while i < n do
      local b = in_buf[i]
      if b == 27 and i + 2 < n and in_buf[i+1] == 91 then -- Escape sequence \27[
        local code = in_buf[i+2]
        if code == 65 then table.insert(keys, "UP")
        elseif code == 66 then table.insert(keys, "DOWN")
        elseif code == 67 then table.insert(keys, "RIGHT")
        elseif code == 68 then table.insert(keys, "LEFT")
        end
        i = i + 3
      else
        local ch = string.char(b):lower()
        table.insert(keys, ch)
        i = i + 1
      end
    end
  end
  return keys
end

--------------------------------------------------------------------------------
-- Game State & Track Generation
--------------------------------------------------------------------------------
local SEGMENT_LENGTH = 100
local RUMBLE_LENGTH  = 3
local LANES          = 3
local ROAD_WIDTH     = 1000
local CAMERA_HEIGHT  = 600
local CAMERA_DEPTH   = 0.8
local DRAW_DISTANCE  = 120

local function create_track()
  local segments = {}
  local function add_road(enter, hold, leave, curve, y)
    local total = enter + hold + leave
    for i = 1, total do
      local t = (i <= enter) and (i / enter) or
                ((i <= enter + hold) and 1 or (1 - (i - enter - hold) / leave))
      local cur_curve = curve * t
      local seg = {
        index = #segments + 1,
        p1 = { world = { x = 0, y = 0, z = (#segments) * SEGMENT_LENGTH }, camera = {}, screen = {} },
        p2 = { world = { x = 0, y = 0, z = (#segments + 1) * SEGMENT_LENGTH }, camera = {}, screen = {} },
        curve = cur_curve,
        sprites = {},
        cars = {}
      }
      table.insert(segments, seg)
    end
  end

  -- Track layout: mix of straights, curves, and S-turns
  add_road(30, 60, 30, 0, 0)       -- Starting straight
  add_road(30, 80, 30, 2.5, 0)     -- Right curve
  add_road(20, 40, 20, 0, 0)       -- Straight
  add_road(30, 90, 30, -3.0, 0)    -- Sharp Left curve
  add_road(20, 50, 20, 1.5, 0)     -- Easy Right
  add_road(40, 80, 40, -2.0, 0)    -- Left S-curve
  add_road(40, 80, 40, 2.0, 0)     -- Right S-curve
  add_road(30, 100, 30, 0, 0)      -- Final straight to finish line

  -- Add roadside scenery (palm trees & billboards)
  for i = 1, #segments, 4 do
    local side = (i % 8 == 0) and 1 or -1
    table.insert(segments[i].sprites, {
      type = "tree",
      offset = side * (1.3 + (i % 5) * 0.15)
    })
  end

  return segments
end

local function project(p, cameraX, cameraY, cameraZ, cameraDepth, width, height, roadW)
  p.camera.x = (p.world.x or 0) - cameraX
  p.camera.y = (p.world.y or 0) - cameraY
  p.camera.z = (p.world.z or 0) - cameraZ

  if p.camera.z <= 0.01 then
    p.camera.z = 0.01
  end

  p.screen.scale = cameraDepth / p.camera.z
  p.screen.x = math.floor((width / 2) + (p.screen.scale * p.camera.x * width / 2))
  p.screen.y = math.floor((height / 2) - (p.screen.scale * p.camera.y * height / 2))
  p.screen.w = math.floor(p.screen.scale * roadW * width / 2)
end

--------------------------------------------------------------------------------
-- Rendering Subsystem (ANSI 24-bit TrueColor)
--------------------------------------------------------------------------------
local ANSI = {
  RESET     = "\27[0m",
  HOME      = "\27[H",
  CLEAR     = "\27[2J",
  BOLD      = "\27[1m",
  DIM       = "\27[2m",
  -- TrueColor helpers
  BG_SKY_TOP = "\27[48;2;25;20;60m",     -- Deep twilight purple
  BG_SKY_MID = "\27[48;2;80;40;90m",     -- Sunset magenta
  BG_SKY_BOT = "\27[48;2;180;90;70m",    -- Dusk orange
  BG_GRASS_L = "\27[48;2;20;90;30m",     -- Light Grass
  BG_GRASS_D = "\27[48;2;15;70;25m",     -- Dark Grass
  BG_ROAD_L  = "\27[48;2;75;75;80m",     -- Light Asphalt
  BG_ROAD_D  = "\27[48;2;60;60;65m",     -- Dark Asphalt
  BG_RUMBLE_R= "\27[48;2;190;30;30m",    -- Red curb
  BG_RUMBLE_W= "\27[48;2;220;220;220m",  -- White curb
  BG_LANE    = "\27[48;2;240;240;240m",  -- Lane white
  FG_WHITE   = "\27[38;2;255;255;255m",
  FG_YELLOW  = "\27[38;2;255;220;50m",
  FG_CYAN    = "\27[38;2;80;220;255m",
  FG_GREEN   = "\27[38;2;80;240;100m",
  FG_RED     = "\27[38;2;255;70;70m",
  FG_DARK    = "\27[38;2;30;30;40m",
}

-- Player Sports Car ASCII Sprite
local CAR_SPRITE = {
  "  ▄██████▄  ",
  " █▀██████▀█ ",
  "▄███▀▀▀▀███▄",
  "▀██▄▄▄▄▄▄██▀",
  "  ▀▀    ▀▀  "
}

local CAR_SPRITE_LEFT = {
  " ▄██████▄   ",
  " █▀██████▀█ ",
  "▄███▀▀▀▀███▄",
  "▀██▄▄▄▄▄▄██▀",
  "  ▀▀    ▀▀  "
}

local CAR_SPRITE_RIGHT = {
  "   ▄██████▄ ",
  " █▀██████▀█ ",
  "▄███▀▀▀▀███▄",
  "▀██▄▄▄▄▄▄██▀",
  "  ▀▀    ▀▀  "
}

--------------------------------------------------------------------------------
-- Main Game Engine
--------------------------------------------------------------------------------
local function run_game(is_test_mode)
  local width, height = get_term_size()
  if width < 60 or height < 20 then
    width = 80
    height = 24
  end

  local segments = create_track()
  local track_length = #segments * SEGMENT_LENGTH

  -- Opponent AI traffic
  local traffic = {
    { pos = 400,  offset = -0.5, speed = 120, model = "🚗" },
    { pos = 1200, offset =  0.6, speed = 140, model = "🚙" },
    { pos = 2200, offset = -0.2, speed = 110, model = "🚚" },
    { pos = 3200, offset =  0.4, speed = 150, model = "🏎️" },
    { pos = 4500, offset = -0.7, speed = 130, model = "🚗" },
    { pos = 5800, offset =  0.1, speed = 160, model = "🏎️" },
  }

  -- Player state
  local playerX = 0
  local playerZ = 0
  local speed = 0
  local maxSpeed = 240
  local accel = 120
  local decel = -80
  local braking = -200
  local offRoadDecel = -150
  local turn_tilt = 0

  local lap = 1
  local total_laps = 3
  local lap_time = 0
  local best_time = 999.99
  local game_over = false
  local victory = false

  local last_time = get_time_sec()
  local frame_count = 0
  local fps = 60
  local fps_timer = last_time
  local running = true

  -- Self-contained pre-allocated frame buffer
  local buf_capacity = 256 * 1024
  local out_buffer = ffi.new("char[?]", buf_capacity)

  -- Horizon line (starts at 45% of height)
  local horizon = math.floor(height * 0.42)

  while running do
    local now = get_time_sec()
    local dt = now - last_time
    if dt < 0.001 then dt = 0.001 end
    if dt > 0.05 then dt = 0.05 end
    last_time = now

    frame_count = frame_count + 1
    if now - fps_timer >= 1.0 then
      fps = frame_count / (now - fps_timer)
      frame_count = 0
      fps_timer = now
    end

    ----------------------------------------------------------------------------
    -- 1. Input Handling
    ----------------------------------------------------------------------------
    local keys = read_keys()
    local accelerating = false
    local is_braking = false
    local steer = 0

    if is_test_mode then
      -- Auto-drive in test mode
      accelerating = true
      if speed < 180 then speed = speed + 200 * dt end
      if frame_count > 80 then running = false end
    else
      for _, k in ipairs(keys) do
        if k == "q" or k == "\27" then
          running = false
        elseif k == "w" or k == "UP" then
          accelerating = true
        elseif k == "s" or k == "DOWN" then
          is_braking = true
        elseif k == "a" or k == "LEFT" then
          steer = -1
        elseif k == "d" or k == "RIGHT" then
          steer = 1
        end
      end
    end

    ----------------------------------------------------------------------------
    -- 2. Physics & Position Updates
    ----------------------------------------------------------------------------
    if accelerating then
      speed = speed + accel * dt
    elseif is_braking then
      speed = speed + braking * dt
    else
      speed = speed + decel * dt
    end

    -- Off-road penalty
    if (playerX < -1.0 or playerX > 1.0) and speed > 60 then
      speed = speed + offRoadDecel * dt
    end

    -- Clamp speed
    speed = math.max(0, math.min(speed, maxSpeed))

    -- Steering & Centrifugal Force in curves
    local base_seg_idx = math.floor(playerZ / SEGMENT_LENGTH) % #segments + 1
    local cur_seg = segments[base_seg_idx]

    local speed_ratio = speed / maxSpeed
    playerX = playerX + steer * 2.2 * speed_ratio * dt
    playerX = playerX - (cur_seg.curve * 1.8 * speed_ratio * speed_ratio * dt)

    turn_tilt = steer

    playerZ = playerZ + speed * 15 * dt
    lap_time = lap_time + dt

    -- Check Lap / Finish
    if playerZ >= track_length then
      playerZ = playerZ - track_length
      if lap_time < best_time then best_time = lap_time end
      lap = lap + 1
      if lap > total_laps then
        victory = true
        running = false
      else
        lap_time = 0
      end
    end

    -- Update AI traffic
    for _, car in ipairs(traffic) do
      car.pos = (car.pos + car.speed * 12 * dt) % track_length
      -- Traffic collision detection
      local dist_z = math.abs(car.pos - playerZ)
      if dist_z < 120 and math.abs(car.offset - playerX) < 0.4 then
        -- Bump! Slow down player
        speed = math.max(20, speed * 0.6)
      end
    end

    ----------------------------------------------------------------------------
    -- 3. Render Pipeline (Scanline Rasterization into Screen Grid)
    ----------------------------------------------------------------------------
    local term_w, term_h = get_term_size()
    if term_w ~= width or term_h ~= height then
      width, height = term_w, term_h
      horizon = math.floor(height * 0.42)
    end

    -- Clear screen buffer representation
    local lines = {}

    -- (A) Sky & Sunset Parallax Backdrop
    local sky_offset = math.floor((playerX * 10) + (cur_seg.curve * 15))
    for y = 1, horizon do
      local sky_bg = (y <= horizon * 0.3) and ANSI.BG_SKY_TOP or
                     ((y <= horizon * 0.7) and ANSI.BG_SKY_MID or ANSI.BG_SKY_BOT)
      
      -- Add background mountain silhouettes and sun
      local row_chars = {}
      for x = 1, width do
        local sx = (x + sky_offset) % 80
        if y == math.floor(horizon * 0.5) and sx >= 58 and sx <= 66 then
          row_chars[x] = ANSI.FG_YELLOW .. "█"
        elseif y == math.floor(horizon * 0.4) and sx >= 60 and sx <= 64 then
          row_chars[x] = ANSI.FG_YELLOW .. "█"
        elseif y > horizon - 3 and (sx % 22 < 9) then
          row_chars[x] = "\27[38;2;45;25;50m▲"
        elseif y > horizon - 2 and (sx % 18 < 7) then
          row_chars[x] = "\27[38;2;60;35;60m▄"
        else
          row_chars[x] = " "
        end
      end
      lines[y] = sky_bg .. table.concat(row_chars) .. ANSI.RESET
    end

    -- (B) 3D Road Projection
    -- Project visible track segments
    local start_pos = math.floor(playerZ / SEGMENT_LENGTH)
    local camH = CAMERA_HEIGHT
    local camX = playerX * ROAD_WIDTH
    local maxy = height

    -- Initialize road lines with default grass
    for y = horizon + 1, height - 2 do
      lines[y] = { grass = ANSI.BG_GRASS_D, road = ANSI.BG_ROAD_D, rumble = ANSI.BG_RUMBLE_W,
                   lane = false, x = math.floor(width / 2), w = 0 }
    end

    for n = 1, DRAW_DISTANCE do
      local seg_idx = ((start_pos + n - 1) % #segments) + 1
      local seg = segments[seg_idx]
      local loop_offset = math.floor((start_pos + n - 1) / #segments) * track_length

      project(seg.p1, camX, camH, playerZ - loop_offset, CAMERA_DEPTH, width, height, ROAD_WIDTH)
      project(seg.p2, camX, camH, playerZ - loop_offset, CAMERA_DEPTH, width, height, ROAD_WIDTH)

      if seg.p1.camera.z > 0 and seg.p2.screen.y < maxy and seg.p2.screen.y > horizon then
        local sy = seg.p2.screen.y
        if sy > horizon and sy <= height - 2 then
          local is_rumble_stripe = (math.floor(seg_idx / RUMBLE_LENGTH) % 2 == 0)
          local is_grass_stripe  = (math.floor(seg_idx / (RUMBLE_LENGTH * 2)) % 2 == 0)
          
          local rdata = lines[sy]
          if type(rdata) == "table" then
            rdata.x = seg.p2.screen.x
            rdata.w = math.max(4, seg.p2.screen.w)
            rdata.grass  = is_grass_stripe and ANSI.BG_GRASS_L or ANSI.BG_GRASS_D
            rdata.road   = is_rumble_stripe and ANSI.BG_ROAD_L or ANSI.BG_ROAD_D
            rdata.rumble = is_rumble_stripe and ANSI.BG_RUMBLE_R or ANSI.BG_RUMBLE_W
            rdata.lane   = is_rumble_stripe
          end
        end
        maxy = seg.p2.screen.y
      end
    end

    -- Render road scanlines into string rows
    for y = horizon + 1, height - 2 do
      local r = lines[y]
      if type(r) == "table" then
        local rw = r.w
        local rx = r.x
        local r1 = math.max(1, math.min(width, rx - rw))
        local r2 = math.max(1, math.min(width, rx + rw))
        local curb_w = math.max(1, math.floor(rw * 0.12))

        local left_grass_len  = math.max(0, r1 - 1)
        local left_curb_len   = math.min(curb_w, width - left_grass_len)
        local road_inner_len  = math.max(0, (r2 - r1) - (2 * curb_w))
        local right_curb_len  = math.min(curb_w, width - left_grass_len - left_curb_len - road_inner_len)
        local right_grass_len = math.max(0, width - (left_grass_len + left_curb_len + road_inner_len + right_curb_len))

        local row_str = r.grass .. string.rep(" ", left_grass_len) ..
                        r.rumble .. string.rep(" ", left_curb_len) ..
                        r.road

        -- Center dashed lane line
        if r.lane and road_inner_len > 6 then
          local half = math.floor(road_inner_len / 2)
          row_str = row_str .. string.rep(" ", half - 1) ..
                    ANSI.BG_LANE .. "  " .. r.road ..
                    string.rep(" ", road_inner_len - half - 1)
        else
          row_str = row_str .. string.rep(" ", road_inner_len)
        end

        row_str = row_str .. r.rumble .. string.rep(" ", right_curb_len) ..
                  r.grass .. string.rep(" ", right_grass_len) .. ANSI.RESET

        lines[y] = row_str
      end
    end

    -- (C) Render AI Traffic on track
    for _, car in ipairs(traffic) do
      local rel_z = car.pos - playerZ
      if rel_z < 0 then rel_z = rel_z + track_length end
      if rel_z > 50 and rel_z < (DRAW_DISTANCE * SEGMENT_LENGTH * 0.6) then
        local scale = CAMERA_DEPTH / rel_z
        local sx = math.floor((width / 2) + (scale * (car.offset * ROAD_WIDTH - camX) * width / 2))
        local sy = math.floor((height / 2) - (scale * (0 - camH) * height / 2))
        if sy > horizon + 1 and sy < height - 5 and sx >= 4 and sx <= width - 6 then
          local old_line = lines[sy] or ""
          -- Simple car representation
          local car_txt = ANSI.FG_CYAN .. ANSI.BOLD .. car.model .. ANSI.RESET
          if #old_line > 0 then
            lines[sy] = string.sub(old_line, 1, math.max(1, sx - 2)) .. car_txt .. string.sub(old_line, sx + 2)
          end
        end
      end
    end

    -- (D) Render Player Car Sprite
    local pcar = CAR_SPRITE
    if turn_tilt < 0 then pcar = CAR_SPRITE_LEFT
    elseif turn_tilt > 0 then pcar = CAR_SPRITE_RIGHT end

    local car_y_start = height - 7
    local car_x_center = math.floor(width / 2) - 6
    for idx, sprite_row in ipairs(pcar) do
      local cy = car_y_start + idx - 1
      if cy >= 1 and cy <= height - 2 then
        local line_prefix = string.rep(" ", math.max(0, car_x_center))
        lines[cy] = "\27[" .. cy .. ";1H" .. line_prefix .. ANSI.FG_RED .. ANSI.BOLD .. sprite_row .. ANSI.RESET
      end
    end

    -- (E) Top Title & HUD Bar
    local lap_str = string.format(" LAP: %d/%d ", math.min(lap, total_laps), total_laps)
    local time_str = string.format(" TIME: %05.2fs ", lap_time)
    local speed_str = string.format(" SPEED: %3d MPH ", math.floor(speed))
    local fps_str = string.format(" %2.0f FPS ", fps)

    local hud_top = ANSI.BG_SKY_TOP .. ANSI.FG_WHITE .. ANSI.BOLD ..
                    " 🏎️  OUTRUN TERMINAL " ..
                    string.rep(" ", math.max(2, width - 24 - #lap_str - #time_str - #speed_str - #fps_str)) ..
                    ANSI.FG_CYAN .. lap_str ..
                    ANSI.FG_YELLOW .. time_str ..
                    ANSI.FG_GREEN .. speed_str ..
                    ANSI.FG_WHITE .. ANSI.DIM .. fps_str .. ANSI.RESET
    lines[1] = hud_top

    -- (F) Bottom Dashboard & Telemetry Bar
    local rpm_blocks = math.floor((speed / maxSpeed) * 16)
    local rpm_bar = ANSI.FG_RED .. string.rep("|", rpm_blocks) .. ANSI.FG_DARK .. string.rep(".", 16 - rpm_blocks) .. ANSI.RESET

    local progress_pct = math.min(1.0, (playerZ + (lap - 1) * track_length) / (total_laps * track_length))
    local prog_blocks = math.floor(progress_pct * 12)
    local prog_bar = ANSI.FG_CYAN .. string.rep("=", prog_blocks) .. ">" .. ANSI.FG_DARK .. string.rep(".", math.max(0, 11 - prog_blocks)) .. ANSI.RESET

    local hud_bot1 = ANSI.FG_WHITE .. ANSI.DIM .. " CONTROLS: [A/D] or [←/→] Steer | [W/S] or [↑/↓] Gas/Brake | [Q] Quit" .. ANSI.RESET
    local hud_bot2 = string.format(" RPM: [%s]  TRACK: [%s] %2d%%  BEST: %s",
                                   rpm_bar, prog_bar, math.floor(progress_pct * 100),
                                   best_time < 900 and string.format("%05.2fs", best_time) or "--:--")
    lines[height - 1] = ANSI.FG_WHITE .. hud_bot1 .. ANSI.RESET
    lines[height]     = ANSI.FG_WHITE .. ANSI.BOLD .. hud_bot2 .. ANSI.RESET

    ----------------------------------------------------------------------------
    -- 4. Single-Write Flush to Terminal
    ----------------------------------------------------------------------------
    local frame_str = ANSI.HOME .. table.concat(lines, "\n")
    C.write(1, frame_str, #frame_str)

    -- Sleep to maintain ~60 FPS cap
    C.usleep(14000)
  end

  return { laps_completed = lap, best_time = best_time, victory = victory }
end

--------------------------------------------------------------------------------
-- Entry Point
--------------------------------------------------------------------------------
local is_test = false
for i = 1, #arg do
  if arg[i] == "--test" or arg[i] == "--demo" then
    is_test = true
  end
end

if not is_test then
  init_terminal()
end

local ok, res_or_err = pcall(function()
  return run_game(is_test)
end)

restore_terminal()

if not ok then
  io.stderr:write("Error during game execution: " .. tostring(res_or_err) .. "\n")
  os.exit(1)
end

if is_test then
  print("✓ Test execution completed successfully!")
  print(string.format("  Laps simulated: %d, Engine status: OK", res_or_err.laps_completed))
end
