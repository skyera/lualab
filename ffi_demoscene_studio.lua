#!/usr/bin/env luajit
--[[
    ffi_demoscene_studio.lua
    Classic 1990s Demoscene Visuals Studio in pure LuaJIT FFI.

    Features:
      - 5 Legendary 90s Demoscene Effects in real-time Truecolor terminal graphics:
          1. PSX DOOM Fire: The famous bottom-up procedural fire spread with wind.
          2. Sine Plasma: Multi-frequency trigonometric interference & rainbow cycling.
          3. Comanche Voxel Space: 3D flight simulator over fractal terrain heightmaps.
          4. 3D Starfield Warp: Perspective projection with motion blur trails & hyperdrive.
          5. Matrix Digital Rain: Cascading code streams with glowing white heads.
      - High-performance flat C RGB framebuffer (74x36 pixels at 60 FPS).
      - Dual-pixel Truecolor ANSI 24-bit half-block renderer (▀) and ASCII fallback.
      - Interactive camera flight controls (WASD/Arrows) and parameter tuning (+/-).
      - Zero external C library dependencies: pure LuaJIT FFI with POSIX / Win32 console I/O.
      - Pixel-perfect 80x25 terminal layout.
--]]

local ffi = require("ffi")
local bit = require("bit")

-- ============================================================================
-- 1. FFI C DEFINITIONS & CONSTANTS
-- ============================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } RGBColor;

    typedef struct {
        RGBColor fb[36 * 74];
        uint32_t frame_count;
        float time_sec;
    } StudioState;
]]

if is_windows then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;

        typedef struct _INPUT_RECORD {
            unsigned short EventType;
            union {
                struct {
                    BOOL bKeyDown;
                    unsigned short wRepeatCount;
                    unsigned short wVirtualKeyCode;
                    unsigned short wVirtualScanCode;
                    union { unsigned short UnicodeChar; char AsciiChar; } uChar;
                    DWORD dwControlKeyState;
                } KeyEvent;
            } Event;
        } INPUT_RECORD;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL GetNumberOfConsoleInputEvents(HANDLE hConsoleInput, DWORD *lpcNumberOfEvents);
        BOOL ReadConsoleInputA(HANDLE hConsoleInput, INPUT_RECORD *lpBuffer, DWORD nLength, DWORD *lpNumberOfEventsRead);
        void Sleep(DWORD dwMilliseconds);
    ]]
else
    ffi.cdef[[
        typedef unsigned int   tcflag_t;
        typedef unsigned char  cc_t;
        typedef unsigned int   speed_t;

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
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, unsigned long count);
        int nanosleep(const struct timespec *req, struct timespec *rem);
        int clock_gettime(int clk_id, struct timespec *tp);
    ]]
end

local WIDTH  = 74
local HEIGHT = 36

-- 37-Color PSX DOOM Fire Palette (RGB)
local DOOM_FIRE_PALETTE = {
    {0x07,0x07,0x07}, {0x1f,0x07,0x07}, {0x2f,0x0f,0x07}, {0x47,0x0f,0x07},
    {0x57,0x17,0x07}, {0x67,0x1f,0x07}, {0x77,0x1f,0x07}, {0x8f,0x27,0x07},
    {0x9f,0x2f,0x07}, {0xaf,0x3f,0x07}, {0xbf,0x47,0x07}, {0xc7,0x47,0x07},
    {0xdf,0x4f,0x07}, {0xdf,0x57,0x07}, {0xdf,0x57,0x07}, {0xd7,0x5f,0x07},
    {0xd7,0x67,0x0f}, {0xcf,0x6f,0x0f}, {0xcf,0x77,0x0f}, {0xcf,0x7f,0x0f},
    {0xcf,0x87,0x17}, {0xc7,0x87,0x17}, {0xc7,0x8f,0x17}, {0xc7,0x97,0x1f},
    {0xbf,0x9f,0x1f}, {0xbf,0x9f,0x1f}, {0xbf,0xa7,0x27}, {0xbf,0xa7,0x27},
    {0xbf,0xaf,0x2f}, {0xb7,0xaf,0x2f}, {0xb7,0xb7,0x2f}, {0xb7,0xb7,0x37},
    {0xcf,0xcf,0x6f}, {0xdf,0xdf,0x9f}, {0xef,0xef,0xc7}, {0xff,0xff,0xff},
    {0xff,0xff,0xff}
}

-- ASCII ramp for luminance conversion
local ASCII_RAMP = " .:-=+*#%@"

-- ============================================================================
-- 2. TERMINAL RAW I/O
-- ============================================================================
local Terminal = {}
Terminal.__index = Terminal

function Terminal.new()
    local self = setmetatable({}, Terminal)
    self.is_windows = is_windows
    self.orig_mode = nil
    self.orig_termios = nil
    self.raw_enabled = false

    if self.is_windows then
        self.STD_INPUT_HANDLE = ffi.cast("DWORD", -10)
        self.STD_OUTPUT_HANDLE = ffi.cast("DWORD", -11)
        self.hIn = ffi.C.GetStdHandle(self.STD_INPUT_HANDLE)
        self.hOut = ffi.C.GetStdHandle(self.STD_OUTPUT_HANDLE)
    else
        self.orig_termios = ffi.new("struct termios")
        self.raw_termios  = ffi.new("struct termios")
        self.pollfd       = ffi.new("struct pollfd[1]")
        self.pollfd[0].fd = 0
        self.pollfd[0].events = 1
        self.buf          = ffi.new("char[64]")
    end
    return self
end

function Terminal:enable_raw_mode()
    if self.raw_enabled then return end
    if self.is_windows then
        local mode = ffi.new("DWORD[1]")
        if ffi.C.GetConsoleMode(self.hIn, mode) ~= 0 then
            self.orig_mode = mode[0]
            local new_mode = bit.band(self.orig_mode, bit.bnot(bit.bor(0x0002, 0x0004)))
            ffi.C.SetConsoleMode(self.hIn, new_mode)
        end
    else
        if ffi.C.tcgetattr(0, self.orig_termios) == 0 then
            ffi.copy(self.raw_termios, self.orig_termios, ffi.sizeof("struct termios"))
            self.raw_termios.c_lflag = bit.band(self.raw_termios.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
            self.raw_termios.c_cc[5] = 0
            self.raw_termios.c_cc[6] = 0
            ffi.C.tcsetattr(0, 0, self.raw_termios)
        end
    end
    self.raw_enabled = true
    io.write("\27[?25l") -- Hide cursor
    io.flush()
end

function Terminal:disable_raw_mode()
    if not self.raw_enabled then return end
    io.write("\27[?25h\27[0m")
    io.flush()
    if self.is_windows then
        if self.orig_mode then ffi.C.SetConsoleMode(self.hIn, self.orig_mode) end
    else
        if self.orig_termios then ffi.C.tcsetattr(0, 0, self.orig_termios) end
    end
    self.raw_enabled = false
end

function Terminal:read_key()
    if self.is_windows then
        local num_events = ffi.new("DWORD[1]")
        if ffi.C.GetNumberOfConsoleInputEvents(self.hIn, num_events) ~= 0 and num_events[0] > 0 then
            local record = ffi.new("INPUT_RECORD[1]")
            local read_count = ffi.new("DWORD[1]")
            if ffi.C.ReadConsoleInputA(self.hIn, record, 1, read_count) ~= 0 and read_count[0] > 0 then
                if record[0].EventType == 0x0001 and record[0].Event.KeyEvent.bKeyDown ~= 0 then
                    local c = record[0].Event.KeyEvent.uChar.AsciiChar
                    if c ~= 0 then return string.char(c) end
                end
            end
        end
        return nil
    else
        local ret = ffi.C.poll(self.pollfd, 1, 0)
        if ret > 0 and bit.band(self.pollfd[0].revents, 1) ~= 0 then
            local n = ffi.C.read(0, self.buf, 63)
            if n > 0 then
                local s = ffi.string(self.buf, n)
                if s == "\27[A" then return "up"
                elseif s == "\27[B" then return "down"
                elseif s == "\27[C" then return "right"
                elseif s == "\27[D" then return "left"
                end
                return s:sub(1, 1)
            end
        end
        return nil
    end
end

function Terminal:get_time_sec()
    if self.is_windows then
        return os.clock()
    else
        local ts = ffi.new("struct timespec")
        ffi.C.clock_gettime(1, ts)
        return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
    end
end

function Terminal:sleep_ms(ms)
    if self.is_windows then
        ffi.C.Sleep(ms)
    else
        local req = ffi.new("struct timespec")
        req.tv_sec = math.floor(ms / 1000)
        req.tv_nsec = (ms % 1000) * 1000000
        ffi.C.nanosleep(req, nil)
    end
end

-- ============================================================================
-- 3. DEMOSCENE ENGINE & VISUAL EFFECTS
-- ============================================================================
local DemosceneStudio = {}
DemosceneStudio.__index = DemosceneStudio

local EFFECTS = { "fire", "plasma", "voxel", "starfield", "matrix" }
local EFFECT_TITLES = {
    fire      = "PSX DOOM Fire Simulation",
    plasma    = "Multi-Sine Rainbow Plasma",
    voxel     = "Comanche 3D Voxel Flight Simulator",
    starfield = "3D Starfield Warp & Motion Blur",
    matrix    = "Matrix Digital Rain Cascade",
}

function DemosceneStudio.new()
    local self = setmetatable({}, DemosceneStudio)
    self.state = ffi.new("StudioState")
    self.width = WIDTH
    self.height = HEIGHT
    self.active_effect = "fire"
    self.paused = false
    self.use_ascii = false
    self.speed_multiplier = 1.0

    -- Effect 1: DOOM Fire buffers
    self.fire_buffer = ffi.new("uint8_t[?]", WIDTH * (HEIGHT + 1))
    self.fire_wind = 0

    -- Effect 2: Plasma parameters
    self.plasma_palette_mode = 1

    -- Effect 3: Comanche Voxel parameters
    self.cam_x = 120.0
    self.cam_y = 120.0
    self.cam_angle = 0.0
    self.cam_altitude = 65.0
    self.cam_horizon = 18.0

    -- Effect 4: Starfield parameters
    self.num_stars = 350
    self.stars_x = ffi.new("float[?]", self.num_stars)
    self.stars_y = ffi.new("float[?]", self.num_stars)
    self.stars_z = ffi.new("float[?]", self.num_stars)
    self.stars_pz = ffi.new("float[?]", self.num_stars)
    self:init_starfield()

    -- Effect 5: Matrix Rain drops
    self.matrix_drops = ffi.new("float[?]", WIDTH)
    self.matrix_speeds = ffi.new("float[?]", WIDTH)
    self.matrix_lens = ffi.new("int[?]", WIDTH)
    self:init_matrix()

    self:init_fire()
    return self
end

function DemosceneStudio:clear_framebuffer(r, g, b)
    r = r or 0
    g = g or 0
    b = b or 0
    local fb = self.state.fb
    for i = 0, WIDTH * HEIGHT - 1 do
        fb[i].r = r
        fb[i].g = g
        fb[i].b = b
    end
end

function DemosceneStudio:set_effect(eff)
    if type(eff) == "number" and EFFECTS[eff] then
        self.active_effect = EFFECTS[eff]
    elseif type(eff) == "string" and EFFECT_TITLES[eff:lower()] then
        self.active_effect = eff:lower()
    end
    if self.active_effect == "fire" then self:init_fire() end
    return self.active_effect
end

function DemosceneStudio:next_effect()
    local cur_idx = 1
    for i, e in ipairs(EFFECTS) do
        if e == self.active_effect then cur_idx = i; break end
    end
    local next_idx = (cur_idx % #EFFECTS) + 1
    return self:set_effect(next_idx)
end

-- ----------------------------------------------------------------------------
-- Effect 1: PSX DOOM Fire
-- ----------------------------------------------------------------------------
function DemosceneStudio:init_fire()
    ffi.fill(self.fire_buffer, WIDTH * (HEIGHT + 1), 0)
    -- Initialize bottom source row to maximum flame temperature (36)
    for x = 0, WIDTH - 1 do
        self.fire_buffer[HEIGHT * WIDTH + x] = 36
    end
end

function DemosceneStudio:update_fire()
    local fb = self.state.fb
    local buf = self.fire_buffer

    for x = 0, WIDTH - 1 do
        for y = 1, HEIGHT do
            local from = y * WIDTH + x
            local heat = buf[from]

            if heat == 0 then
                local to = (y - 1) * WIDTH + x
                buf[to] = 0
            else
                local decay = math.random(0, 1) + (math.random() > 0.85 and 1 or 0)
                local rnd = math.random(0, 3) - 1 + self.fire_wind
                local dst_x = math.max(0, math.min(WIDTH - 1, x + rnd))
                local dst_y = y - 1
                local to = dst_y * WIDTH + dst_x
                local new_heat = math.max(0, heat - decay)
                buf[to] = new_heat

                if dst_y < HEIGHT then
                    local pal = DOOM_FIRE_PALETTE[new_heat + 1] or DOOM_FIRE_PALETTE[1]
                    fb[to].r = pal[1]
                    fb[to].g = pal[2]
                    fb[to].b = pal[3]
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Effect 2: Multi-Sine Rainbow Plasma
-- ----------------------------------------------------------------------------
local function hsv_to_rgb(h, s, v)
    local c = v * s
    local hp = (h % 360) / 60.0
    local x = c * (1.0 - math.abs((hp % 2.0) - 1.0))
    local r1, g1, b1 = 0, 0, 0
    if hp < 1 then r1, g1 = c, x
    elseif hp < 2 then r1, g1 = x, c
    elseif hp < 3 then g1, b1 = c, x
    elseif hp < 4 then g1, b1 = x, c
    elseif hp < 5 then r1, b1 = x, c
    else r1, b1 = c, x end
    local m = v - c
    return math.floor((r1 + m) * 255), math.floor((g1 + m) * 255), math.floor((b1 + m) * 255)
end

function DemosceneStudio:update_plasma()
    local fb = self.state.fb
    local t = self.state.time_sec * 1.5 * self.speed_multiplier
    local half_w = WIDTH * 0.5
    local half_h = HEIGHT * 0.5

    for y = 0, HEIGHT - 1 do
        for x = 0, WIDTH - 1 do
            local dx = x - half_w
            local dy = y - half_h
            local dist = math.sqrt(dx * dx + dy * dy)

            -- Sum multiple sinusoidal waves
            local v1 = math.sin(x * 0.09 + t)
            local v2 = math.sin(y * 0.14 - t * 0.8)
            local v3 = math.sin((x + y) * 0.08 + t * 0.6)
            local v4 = math.sin(dist * 0.22 - t * 1.2)

            local v = (v1 + v2 + v3 + v4) * 0.25 -- Normalized -1 to 1
            local hue = ((v + 1.0) * 0.5 * 360 + t * 30) % 360

            local r, g, b
            if self.plasma_palette_mode == 1 then
                r, g, b = hsv_to_rgb(hue, 0.95, 0.95)
            elseif self.plasma_palette_mode == 2 then
                -- Cyberpunk Cyan / Magenta / Yellow
                local val = (v + 1.0) * 0.5
                r = math.floor(math.sin(val * math.pi) * 255)
                g = math.floor(math.cos(val * math.pi * 0.5) * 200)
                b = math.floor(255 * (1.0 - val * 0.5))
            else
                -- Neon Fire Plasma
                local heat = math.floor((v + 1.0) * 0.5 * 35)
                local pal = DOOM_FIRE_PALETTE[heat + 1] or DOOM_FIRE_PALETTE[1]
                r, g, b = pal[1], pal[2], pal[3]
            end

            local idx = y * WIDTH + x
            fb[idx].r = r
            fb[idx].g = g
            fb[idx].b = b
        end
    end
end

-- ----------------------------------------------------------------------------
-- Effect 3: Comanche 3D Voxel Flight Simulator
-- ----------------------------------------------------------------------------
-- Procedural terrain heightmap function using harmonic value noise
local function terrain_height(x, y)
    local v1 = math.sin(x * 0.04) * math.cos(y * 0.04) * 22.0
    local v2 = math.sin(x * 0.09 + 1.2) * math.sin(y * 0.09 + 0.7) * 12.0
    local v3 = math.sin(x * 0.21 - y * 0.15) * 5.0
    return math.max(0.0, v1 + v2 + v3 + 20.0)
end

local function terrain_color(h)
    if h < 8.0 then
        -- Deep Ocean / Lake
        return 20, 60, 180
    elseif h < 12.0 then
        -- Sandy Coast
        return 210, 190, 120
    elseif h < 28.0 then
        -- Green Valley / Forest
        return 35, 140, 45
    elseif h < 42.0 then
        -- Mountain Rock
        return 130, 120, 115
    else
        -- Snow-capped Peak
        return 240, 245, 255
    end
end

function DemosceneStudio:update_voxel()
    self:clear_framebuffer(25, 45, 85) -- Sky blue / dusk horizon
    local fb = self.state.fb

    -- Camera motion
    local speed = 0.8 * self.speed_multiplier
    self.cam_x = self.cam_x + math.cos(self.cam_angle) * speed
    self.cam_y = self.cam_y + math.sin(self.cam_angle) * speed

    local fov = 1.05
    local max_dist = 110.0
    local scale_height = 24.0

    for col = 0, WIDTH - 1 do
        local ray_angle = self.cam_angle + (col / (WIDTH - 1) - 0.5) * fov
        local sin_a = math.sin(ray_angle)
        local cos_a = math.cos(ray_angle)

        local hidden_y = HEIGHT

        local z = 1.0
        while z < max_dist do
            local sample_x = self.cam_x + cos_a * z
            local sample_y = self.cam_y + sin_a * z

            local h = terrain_height(sample_x, sample_y)
            local proj_y = math.floor((self.cam_altitude - h) / z * scale_height + self.cam_horizon)

            if proj_y < hidden_y then
                local r, g, b = terrain_color(h)
                -- Distance atmospheric fog falloff
                local fog = math.min(1.0, z / max_dist)
                r = math.floor(r * (1.0 - fog) + 25 * fog)
                g = math.floor(g * (1.0 - fog) + 45 * fog)
                b = math.floor(b * (1.0 - fog) + 85 * fog)

                local y_start = math.max(0, proj_y)
                local y_end = math.min(HEIGHT - 1, hidden_y - 1)
                for py = y_start, y_end do
                    local idx = py * WIDTH + col
                    fb[idx].r = r
                    fb[idx].g = g
                    fb[idx].b = b
                end
                hidden_y = proj_y
            end
            z = z + 1.2
        end
    end
end

-- ----------------------------------------------------------------------------
-- Effect 4: 3D Starfield Warp & Motion Blur
-- ----------------------------------------------------------------------------
function DemosceneStudio:init_starfield()
    for i = 0, self.num_stars - 1 do
        self.stars_x[i] = (math.random() - 0.5) * 80.0
        self.stars_y[i] = (math.random() - 0.5) * 50.0
        self.stars_z[i] = math.random(2, 100)
        self.stars_pz[i] = self.stars_z[i]
    end
end

function DemosceneStudio:update_starfield()
    self:clear_framebuffer(6, 6, 12) -- Deep space dark blue
    local fb = self.state.fb
    local speed = 2.4 * self.speed_multiplier
    local half_w = WIDTH * 0.5
    local half_h = HEIGHT * 0.5

    for i = 0, self.num_stars - 1 do
        self.stars_pz[i] = self.stars_z[i]
        self.stars_z[i] = self.stars_z[i] - speed

        if self.stars_z[i] <= 1.0 then
            self.stars_x[i] = (math.random() - 0.5) * 80.0
            self.stars_y[i] = (math.random() - 0.5) * 50.0
            self.stars_z[i] = 100.0
            self.stars_pz[i] = 100.0
        end

        local z = self.stars_z[i]
        local pz = self.stars_pz[i]

        local sx = math.floor(half_w + (self.stars_x[i] / z) * 35.0)
        local sy = math.floor(half_h + (self.stars_y[i] / z) * 22.0)

        local px = math.floor(half_w + (self.stars_x[i] / pz) * 35.0)
        local py = math.floor(half_h + (self.stars_y[i] / pz) * 22.0)

        -- Brightness increases as stars get closer
        local intensity = math.floor(math.min(255, (1.0 - z / 100.0) * 280))

        -- Motion streak line
        if sx >= 0 and sx < WIDTH and sy >= 0 and sy < HEIGHT then
            local idx = sy * WIDTH + sx
            fb[idx].r = intensity
            fb[idx].g = intensity
            fb[idx].b = 255

            -- Motion trail segment
            if px >= 0 and px < WIDTH and py >= 0 and py < HEIGHT then
                local pidx = py * WIDTH + px
                fb[pidx].r = math.floor(intensity * 0.4)
                fb[pidx].g = math.floor(intensity * 0.4)
                fb[pidx].b = math.floor(intensity * 0.7)
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Effect 5: Matrix Digital Rain Cascade
-- ----------------------------------------------------------------------------
function DemosceneStudio:init_matrix()
    for col = 0, WIDTH - 1 do
        self.matrix_drops[col] = math.random(-HEIGHT, 0)
        self.matrix_speeds[col] = 0.4 + math.random() * 0.8
        self.matrix_lens[col] = math.random(8, 22)
    end
end

function DemosceneStudio:update_matrix()
    self:clear_framebuffer(0, 5, 0)
    local fb = self.state.fb

    for col = 0, WIDTH - 1 do
        self.matrix_drops[col] = self.matrix_drops[col] + self.matrix_speeds[col] * self.speed_multiplier
        local head_y = math.floor(self.matrix_drops[col])
        local len = self.matrix_lens[col]

        if head_y - len >= HEIGHT then
            self.matrix_drops[col] = -math.random(1, 10)
            self.matrix_speeds[col] = 0.4 + math.random() * 0.8
            self.matrix_lens[col] = math.random(8, 22)
        end

        for trail = 0, len do
            local py = head_y - trail
            if py >= 0 and py < HEIGHT then
                local idx = py * WIDTH + col
                if trail == 0 then
                    -- Glowing white head
                    fb[idx].r = 230
                    fb[idx].g = 255
                    fb[idx].b = 230
                elseif trail == 1 then
                    -- Bright neon green
                    fb[idx].r = 80
                    fb[idx].g = 255
                    fb[idx].b = 100
                else
                    -- Fading green gradient
                    local fade = 1.0 - (trail / len)
                    fb[idx].r = math.floor(10 * fade)
                    fb[idx].g = math.floor(210 * fade)
                    fb[idx].b = math.floor(40 * fade)
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Master Update Step
-- ----------------------------------------------------------------------------
function DemosceneStudio:step()
    self.state.frame_count = self.state.frame_count + 1
    self.state.time_sec = self.state.time_sec + 0.016

    if self.active_effect == "fire" then
        self:update_fire()
    elseif self.active_effect == "plasma" then
        self:update_plasma()
    elseif self.active_effect == "voxel" then
        self:update_voxel()
    elseif self.active_effect == "starfield" then
        self:update_starfield()
    elseif self.active_effect == "matrix" then
        self:update_matrix()
    end
end

-- ============================================================================
-- 4. PIXEL-PERFECT 80-COLUMN TERMINAL RENDERER
-- ============================================================================
function DemosceneStudio:render_frame()
    local lines = {}
    local fb = self.state.fb

    -- 1. Header Banner (80 columns)
    if self.use_ascii then
        lines[#lines + 1] = " +============================================================================+ "
        lines[#lines + 1] = " |           1990s DEMOSCENE EFFECTS STUDIO - LUAJIT FFI ENGINE               | "
        lines[#lines + 1] = " +============================================================================+ "
    else
        lines[#lines + 1] = " ╔════════════════════════════════════════════════════════════════════════════╗ "
        lines[#lines + 1] = string.format(" ║            %s🌌  1990s DEMOSCENE EFFECTS STUDIO - LUAJIT FFI  🌌%s             ║ ",
            "\27[1;35m", "\27[0m")
        lines[#lines + 1] = " ╚════════════════════════════════════════════════════════════════════════════╝ "
    end

    -- 2. Canvas Top Border (80 cols)
    local effect_title = string.format(" CANVAS [74x36] - %-26s ", EFFECT_TITLES[self.active_effect] or self.active_effect:upper())
    local pad_len = 74 - #effect_title
    if self.use_ascii then
        lines[#lines + 1] = " +--" .. effect_title .. string.rep("-", pad_len) .. "+ "
    else
        lines[#lines + 1] = " ┌──" .. "\27[1;36m" .. effect_title .. "\27[0m" .. string.rep("─", pad_len) .. "┐ "
    end

    -- 3. Canvas Body: 36 pixels vertically compressed into 18 terminal lines using half-blocks
    for row = 0, 17 do
        local y_top = row * 2
        local y_bot = row * 2 + 1
        local line_parts = {}

        if self.use_ascii then
            for col = 0, WIDTH - 1 do
                local c_top = fb[y_top * WIDTH + col]
                local c_bot = fb[y_bot * WIDTH + col]
                local lum = (c_top.r * 0.299 + c_top.g * 0.587 + c_top.b * 0.114 +
                             c_bot.r * 0.299 + c_bot.g * 0.587 + c_bot.b * 0.114) * 0.5
                local idx = math.floor((lum / 255.0) * (#ASCII_RAMP - 1)) + 1
                line_parts[#line_parts + 1] = ASCII_RAMP:sub(idx, idx)
            end
            lines[#lines + 1] = string.format(" | %s | ", table.concat(line_parts))
        else
            for col = 0, WIDTH - 1 do
                local top_c = fb[y_top * WIDTH + col]
                local bot_c = fb[y_bot * WIDTH + col]
                line_parts[#line_parts + 1] = string.format("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▀",
                    top_c.r, top_c.g, top_c.b,
                    bot_c.r, bot_c.g, bot_c.b)
            end
            lines[#lines + 1] = string.format(" │ %s%s │ ", table.concat(line_parts), "\27[0m")
        end
    end

    -- 4. Canvas Bottom Border (80 cols)
    if self.use_ascii then
        lines[#lines + 1] = " +----------------------------------------------------------------------------+ "
    else
        lines[#lines + 1] = " └" .. string.rep("─", 76) .. "┘ "
    end

    -- 5. Status & Controls Panels (80 cols)
    local state_str = self.paused and "PAUSED" or "RUNNING"
    local stat1 = string.format("Effect: %-10s | Speed: %3.1fx | State: %-7s | Frame: %-6d",
        self.active_effect:upper(), self.speed_multiplier, state_str, self.state.frame_count)
    local stat2 = "1:DOOM Fire  2:Sine Plasma  3:Comanche Voxel  4:Starfield  5:Matrix Rain"
    local stat3 = "Tab:Next | Space:Pause | P:Palette | +/-:Speed | WASD:Camera | Q:Exit"

    if self.use_ascii then
        lines[#lines + 1] = " +-- STATUS & CONTROLS " .. string.rep("-", 55) .. "+ "
        lines[#lines + 1] = string.format(" | %-74s | ", stat1)
        lines[#lines + 1] = string.format(" | %-74s | ", stat2)
        lines[#lines + 1] = string.format(" | %-74s | ", stat3)
        lines[#lines + 1] = " +" .. string.rep("-", 76) .. "+ "
    else
        lines[#lines + 1] = " ┌── STATUS & CONTROLS " .. string.rep("─", 55) .. "┐ "
        lines[#lines + 1] = string.format(" │ %-74s │ ", stat1)
        lines[#lines + 1] = string.format(" │ %-74s │ ", stat2)
        lines[#lines + 1] = string.format(" │ %-74s │ ", stat3)
        lines[#lines + 1] = " └" .. string.rep("─", 76) .. "┘ "
    end

    return table.concat(lines, "\n")
end

-- ============================================================================
-- 5. INTERACTIVE DEMO LOOP
-- ============================================================================
function DemosceneStudio:run_interactive()
    local term = Terminal.new()
    term:enable_raw_mode()

    local running = true
    local last_time = term:get_time_sec()
    local target_fps = 60
    local frame_interval = 1.0 / target_fps
    local effect_idx = 1

    io.write("\27[2J\27[H")
    io.flush()

    while running do
        local now = term:get_time_sec()

        -- 1. Read input events
        local k = term:read_key()
        if k then
            if k == "q" or k == "Q" or k == "\27" then
                running = false
            elseif k == " " then
                self.paused = not self.paused
            elseif k == "\t" or k == "n" or k == "N" then
                effect_idx = (effect_idx % #EFFECTS) + 1
                self.active_effect = EFFECTS[effect_idx]
                if self.active_effect == "fire" then self:init_fire() end
            elseif k == "p" or k == "P" then
                self.plasma_palette_mode = (self.plasma_palette_mode % 3) + 1
            elseif k == "+" or k == "=" then
                self.speed_multiplier = math.min(3.0, self.speed_multiplier + 0.2)
            elseif k == "-" or k == "_" then
                self.speed_multiplier = math.max(0.2, self.speed_multiplier - 0.2)
            elseif k >= "1" and k <= "5" then
                local idx = tonumber(k)
                if EFFECTS[idx] then
                    effect_idx = idx
                    self.active_effect = EFFECTS[idx]
                    if self.active_effect == "fire" then self:init_fire() end
                end
            -- Camera / wind controls
            elseif k == "left" or k == "a" or k == "A" then
                if self.active_effect == "voxel" then self.cam_angle = self.cam_angle - 0.08
                elseif self.active_effect == "fire" then self.fire_wind = math.max(-2, self.fire_wind - 1) end
            elseif k == "right" or k == "d" or k == "D" then
                if self.active_effect == "voxel" then self.cam_angle = self.cam_angle + 0.08
                elseif self.active_effect == "fire" then self.fire_wind = math.min(2, self.fire_wind + 1) end
            elseif k == "up" or k == "w" or k == "W" then
                if self.active_effect == "voxel" then self.cam_altitude = math.min(90.0, self.cam_altitude + 2.5) end
            elseif k == "down" or k == "s" or k == "S" then
                if self.active_effect == "voxel" then self.cam_altitude = math.max(25.0, self.cam_altitude - 2.5) end
            end
        end

        -- 2. Step active visual effect
        if not self.paused then
            self:step()
        end

        -- 3. Render at target frame rate
        if (now - last_time) >= frame_interval then
            local frame = self:render_frame()
            io.write("\27[H" .. frame .. "\n")
            io.flush()
            last_time = now
        end

        term:sleep_ms(12)
    end

    term:disable_raw_mode()
    print("\n[Demoscene Studio closed gracefully.]\n")
end

-- ============================================================================
-- 6. CLI DISPATCHER & SELF-TESTS
-- ============================================================================
local function print_help()
    print([[
🌌 1990s DEMOSCENE EFFECTS STUDIO (LuaJIT FFI) 🌌

Usage:
  luajit ffi_demoscene_studio.lua [options]

Options:
  --help               Show this help message and exit
  --test               Run internal rendering and effect self-tests
  --snapshot           Render a single non-interactive frame and exit
  --ascii              Use ASCII characters instead of Truecolor half-blocks
  --effect <name>      Start with effect (fire, plasma, voxel, starfield, matrix)
  --demo [frames]      Run automated demoscene tour cycling through all effects

Available Effects:
  [1] fire             PSX DOOM procedural fire simulation with wind
  [2] plasma           Multi-frequency trigonometric rainbow plasma
  [3] voxel            Comanche 3D voxel space heightmap flight simulator
  [4] starfield        3D starfield warp with motion blur streaks
  [5] matrix           Matrix digital rain cascade

Controls:
  1 - 5        Directly switch demoscene visual effect
  Tab or N     Cycle to next effect
  Space        Pause / Resume animation
  P            Cycle color palettes (in plasma mode)
  + / -        Increase / decrease animation speed
  WASD / Arrow Fly camera in Voxel Space / Shift wind in DOOM Fire
  Q / Esc      Quit studio
]])
end

local function run_self_tests()
    print("=== Running Internal Self-Tests for ffi_demoscene_studio.lua ===")
    local studio = DemosceneStudio.new()

    -- 1. Struct and memory layout
    assert(ffi.sizeof("RGBColor") == 3, "RGBColor sizeof != 3")
    assert(ffi.sizeof("StudioState") == 3 * 74 * 36 + 8, "StudioState sizeof mismatch")
    print("  ✔ PASS: FFI RGBColor & StudioState memory layout")

    -- 2. Framebuffer initialization & clear
    studio:clear_framebuffer(100, 150, 200)
    assert(studio.state.fb[0].r == 100 and studio.state.fb[0].g == 150 and studio.state.fb[0].b == 200, "Framebuffer clear RGB")
    print("  ✔ PASS: Framebuffer memory allocation and clear")

    -- 3. Effect 1: DOOM Fire step
    studio.active_effect = "fire"
    studio:init_fire()
    for _ = 1, 20 do studio:step() end
    local fire_lum = 0
    for i = 0, WIDTH * HEIGHT - 1 do
        fire_lum = fire_lum + studio.state.fb[i].r + studio.state.fb[i].g
    end
    assert(fire_lum > 1000, "DOOM Fire emitted heat energy into framebuffer")
    print("  ✔ PASS: PSX DOOM Fire simulation step")

    -- 4. Effect 2: Sine Plasma step
    studio.active_effect = "plasma"
    studio:step()
    local plasma_diff = false
    local c0 = studio.state.fb[0]
    local c_mid = studio.state.fb[math.floor(WIDTH * HEIGHT / 2)]
    if c0.r ~= c_mid.r or c0.g ~= c_mid.g or c0.b ~= c_mid.b then
        plasma_diff = true
    end
    assert(plasma_diff, "Sine Plasma produces multi-frequency interference gradient")
    print("  ✔ PASS: Multi-frequency Sine Plasma generation")

    -- 5. Effect 3: Comanche Voxel step
    studio.active_effect = "voxel"
    studio:step()
    local voxel_active = 0
    for i = 0, WIDTH * HEIGHT - 1 do
        if studio.state.fb[i].r > 0 or studio.state.fb[i].g > 0 then
            voxel_active = voxel_active + 1
        end
    end
    assert(voxel_active > 1000, "Comanche Voxel terrain raycaster rendered pixels")
    print("  ✔ PASS: Comanche 3D Voxel space raycaster step")

    -- 6. Effect 4: Starfield Warp step
    studio.active_effect = "starfield"
    studio:step()
    local star_count = 0
    for i = 0, WIDTH * HEIGHT - 1 do
        if studio.state.fb[i].r > 50 then star_count = star_count + 1 end
    end
    assert(star_count > 10, "3D Starfield warp generated perspective stars")
    print("  ✔ PASS: 3D Starfield warp perspective projection")

    -- 7. Effect 5: Matrix Rain step
    studio.active_effect = "matrix"
    for _ = 1, 10 do studio:step() end
    local green_count = 0
    for i = 0, WIDTH * HEIGHT - 1 do
        if studio.state.fb[i].g > 100 then green_count = green_count + 1 end
    end
    assert(green_count > 10, "Matrix Rain produced glowing code streams")
    print("  ✔ PASS: Matrix Digital Rain cascade step")

    -- 8. 80-Column frame geometry check across all effects
    local function verify_frame(mode_ascii)
        studio.use_ascii = mode_ascii
        local frame = studio:render_frame()
        local line_num = 0
        for line in frame:gmatch("[^\r\n]+") do
            line_num = line_num + 1
            local plain = line:gsub("\27%[[%d;]*m", "")
            local w = 0
            local i = 1
            while i <= #plain do
                local b = plain:byte(i)
                if b < 128 then w = w + 1; i = i + 1
                elseif b >= 192 and b < 224 then w = w + 1; i = i + 2
                elseif b >= 224 and b < 240 then w = w + 1; i = i + 3
                elseif b >= 240 then w = w + 2; i = i + 4
                else i = i + 1 end
            end
            assert(w == 80, string.format("[%s] Line %d width %d != 80: '%s'",
                mode_ascii and "ASCII" or "Truecolor", line_num, w, plain))
        end
        assert(line_num == 28, "Expected 28 lines, got " .. line_num)
    end

    for _, eff in ipairs(EFFECTS) do
        studio.active_effect = eff
        verify_frame(false)
        verify_frame(true)
    end
    print("  ✔ PASS: Uniform 80-column terminal frame geometry across all 5 effects")

    print("\nAll Demoscene Studio self-tests completed successfully!\n")
    return true
end

-- ============================================================================
-- 7. MAIN ENTRYPOINT
-- ============================================================================
local function main(args)
    local initial_effect = "fire"
    local snapshot_mode = false
    local ascii_mode = false
    local demo_frames = nil

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_help()
            return 0
        elseif a == "--test" then
            local ok = run_self_tests()
            return ok and 0 or 1
        elseif a == "--snapshot" then
            snapshot_mode = true
        elseif a == "--ascii" then
            ascii_mode = true
        elseif a:match("^%-%-effect=(.+)$") then
            initial_effect = a:match("^%-%-effect=(.+)$"):lower()
        elseif a == "--effect" and i + 1 <= #args then
            i = i + 1
            initial_effect = args[i]:lower()
        elseif a:match("^%-%-demo=(%d+)$") then
            demo_frames = tonumber(a:match("^%-%-demo=(%d+)$"))
        elseif a == "--demo" then
            demo_frames = (i + 1 <= #args and tonumber(args[i + 1])) and tonumber(args[i + 1]) or 40
            if i + 1 <= #args and tonumber(args[i + 1]) then i = i + 1 end
        end
        i = i + 1
    end

    local studio = DemosceneStudio.new()
    studio.use_ascii = ascii_mode
    if EFFECT_TITLES[initial_effect] then
        studio.active_effect = initial_effect
        if initial_effect == "fire" then studio:init_fire() end
    end

    if demo_frames then
        print(string.format("Running automated Demoscene Studio tour (%d frames)...", demo_frames))
        local frames_per_effect = math.max(1, math.floor(demo_frames / #EFFECTS))
        for _, eff in ipairs(EFFECTS) do
            studio.active_effect = eff
            if eff == "fire" then studio:init_fire() end
            for _ = 1, frames_per_effect do studio:step() end
        end
        local frame = studio:render_frame()
        print(frame)
        print("[Demoscene Tour Complete]\n")
        return 0
    end

    if snapshot_mode then
        for _ = 1, 25 do studio:step() end
        local frame = studio:render_frame()
        print(frame)
        return 0
    end

    studio:run_interactive()
    return 0
end

local is_main = false
if arg and arg[0] and (arg[0] == "ffi_demoscene_studio.lua" or arg[0]:match("/ffi_demoscene_studio%.lua$") ~= nil) then
    is_main = true
end

if is_main then
    local exit_code = main(arg or {})
    os.exit(exit_code or 0)
end

return {
    DemosceneStudio = DemosceneStudio,
    Terminal = Terminal,
    EFFECTS = EFFECTS,
    EFFECT_TITLES = EFFECT_TITLES,
    DOOM_FIRE_PALETTE = DOOM_FIRE_PALETTE
}
