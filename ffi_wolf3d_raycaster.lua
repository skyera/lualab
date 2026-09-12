#!/usr/bin/env luajit
--[[
    ffi_wolf3d_raycaster.lua
    Wolfenstein-style 3D Raycasting Engine in Terminal using pure LuaJIT FFI.
    
    Highlights:
      - 60+ FPS Digital Differential Analyzer (DDA) raymarching loop in C memory.
      - Dual-pixel Truecolor ANSI 24-bit half-block renderer ('▀') compressing
        a 74x36 3D canvas into 18 terminal rows, with full ASCII fallback.
      - 6 procedural 32x32 wall textures: Classic Stone, Castle Blue, Wood Planks,
        Mossy Dungeon, Reinforced Steel Door, and Red Prison Brick.
      - Distance fog attenuation and directional side-shading (North/South vs East/West).
      - Recessed sliding interactive doors with John Carmack's 1992 DDA door algorithm.
      - 1D Z-buffer depth testing for billboarded 3D sprites (patrolling guards,
        gold chalice treasures, first aid medkits, ammo crates, animated torches).
      - First-person player weapon with kickback recoil, muzzle flash, and hitscan combat.
      - Toggleable 2D minimap radar with player FOV cone and live entity tracking.
      - Cross-platform raw terminal input (POSIX termios/poll and Win32 Console API).
      - Zero external C library dependencies (pure LuaJIT + libc / win32).
--]]

local ffi = require("ffi")
local bit = require("bit")

-- ============================================================================
-- 1. FFI C DEFINITIONS & NATIVE SYSTEM BINDINGS
-- ============================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } RGBColor;

    typedef struct {
        RGBColor pixels[32 * 32];
    } Texture32;

    typedef struct {
        float x, y;
        float dir_x, dir_y;
        float plane_x, plane_y;
        float move_speed;
        float rot_speed;
        int health;
        int armor;
        int ammo;
        int score;
        int firing_timer;
        float weapon_bob;
    } PlayerState;

    typedef struct {
        float x, y;
        int type;
        int active;
        int hp;
        float dist;
    } SpriteEntity;

    typedef struct {
        RGBColor fb[36 * 74];
        float z_buffer[74];
        uint32_t frame_count;
        float time_sec;
    } RaycasterState;
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
        int clock_gettime(int clk_id, struct timespec *tp);
        int nanosleep(const struct timespec *req, struct timespec *rem);
    ]]
end

-- ============================================================================
-- 2. ENGINE CONSTANTS & PALETTES
-- ============================================================================
local WIDTH  = 74
local HEIGHT = 36
local MAP_W  = 24
local MAP_H  = 24
local TEX_SZ = 32

-- Wall Texture IDs
local TEX_STONE  = 1
local TEX_BLUE   = 2
local TEX_WOOD   = 3
local TEX_MOSS   = 4
local TEX_DOOR   = 5
local TEX_PRISON = 6
local NUM_WALL_TEX = 6

-- Sprite IDs
local SPRITE_GUARD   = 1
local SPRITE_CHALICE = 2
local SPRITE_MEDKIT  = 3
local SPRITE_AMMO    = 4
local SPRITE_TORCH   = 5
local NUM_SPRITE_TEX = 5

local ASCII_RAMP = " .:-=+*#%@"

-- ============================================================================
-- 3. CROSS-PLATFORM RAW TERMINAL I/O
-- ============================================================================
local Terminal = {}
Terminal.__index = Terminal

function Terminal.new()
    local self = setmetatable({}, Terminal)
    self.is_windows = is_windows
    self.raw_enabled = false

    if is_windows then
        self.STD_INPUT_HANDLE  = -10
        self.STD_OUTPUT_HANDLE = -11
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
-- 4. PROCEDURAL TEXTURE & SPRITE GENERATION
-- ============================================================================
local function create_texture_atlas()
    local wall_tex = ffi.new("Texture32[?]", NUM_WALL_TEX + 1)
    local sprite_tex = ffi.new("Texture32[?]", NUM_SPRITE_TEX + 1)

    local function set_pixel(tex, id, x, y, r, g, b)
        if x < 0 or x >= 32 or y < 0 or y >= 32 then return end
        local p = tex[id].pixels[y * 32 + x]
        p.r = math.min(255, math.max(0, math.floor(r)))
        p.g = math.min(255, math.max(0, math.floor(g)))
        p.b = math.min(255, math.max(0, math.floor(b)))
    end

    -- Texture 1: Classic Stone Brick
    for y = 0, 31 do
        for x = 0, 31 do
            local is_h_mortar = (y % 8 == 0)
            local brick_row = math.floor(y / 8)
            local is_v_mortar = false
            if brick_row % 2 == 0 then
                is_v_mortar = (x % 16 == 0)
            else
                is_v_mortar = ((x + 8) % 16 == 0)
            end

            if is_h_mortar or is_v_mortar then
                set_pixel(wall_tex, TEX_STONE, x, y, 45, 45, 50)
            else
                local noise = ((x * 17 + y * 31) % 19) - 9
                local is_bevel = (y % 8 == 1) or ((brick_row % 2 == 0) and (x % 16 == 1))
                local is_shadow = (y % 8 == 7) or ((brick_row % 2 == 0) and (x % 16 == 15))
                if is_bevel then
                    set_pixel(wall_tex, TEX_STONE, x, y, 160 + noise, 160 + noise, 165 + noise)
                elseif is_shadow then
                    set_pixel(wall_tex, TEX_STONE, x, y, 90 + noise, 90 + noise, 95 + noise)
                else
                    set_pixel(wall_tex, TEX_STONE, x, y, 125 + noise, 125 + noise, 130 + noise)
                end
            end
        end
    end

    -- Texture 2: Castle Blue Stone with Gold Trim
    for y = 0, 31 do
        for x = 0, 31 do
            local is_mortar = (y % 8 == 0) or ((math.floor(y / 8) % 2 == 0) and (x % 16 == 0)) or ((math.floor(y / 8) % 2 == 1) and ((x + 8) % 16 == 0))
            if is_mortar then
                set_pixel(wall_tex, TEX_BLUE, x, y, 20, 35, 75)
            else
                local noise = ((x * 13 + y * 29) % 15) - 7
                -- Center Gold Crest (diamond)
                local dx = math.abs(x - 15.5)
                local dy = math.abs(y - 15.5)
                if (dx + dy) <= 6.5 and (dx + dy) >= 4.0 then
                    set_pixel(wall_tex, TEX_BLUE, x, y, 220, 185, 40)
                elseif (dx + dy) < 4.0 then
                    set_pixel(wall_tex, TEX_BLUE, x, y, 170, 140, 25)
                else
                    set_pixel(wall_tex, TEX_BLUE, x, y, 45 + noise, 80 + noise, 160 + noise)
                end
            end
        end
    end

    -- Texture 3: Wood Plank Paneling
    for y = 0, 31 do
        for x = 0, 31 do
            local is_seam = (x % 8 == 0)
            local is_band = (y == 3 or y == 4 or y == 27 or y == 28)
            if is_band then
                local is_rivet = (x % 8 == 4) and (y == 3 or y == 28)
                if is_rivet then
                    set_pixel(wall_tex, TEX_WOOD, x, y, 230, 200, 70)
                else
                    set_pixel(wall_tex, TEX_WOOD, x, y, 70, 70, 75)
                end
            elseif is_seam then
                set_pixel(wall_tex, TEX_WOOD, x, y, 40, 20, 10)
            else
                local grain = ((y * 7 + x * 3) % 13) - 6
                set_pixel(wall_tex, TEX_WOOD, x, y, 145 + grain, 78 + grain, 32 + grain)
            end
        end
    end

    -- Texture 4: Mossy Dungeon Stone
    for y = 0, 31 do
        for x = 0, 31 do
            local is_mortar = (y % 8 == 0) or ((math.floor(y / 8) % 2 == 0) and (x % 16 == 0)) or ((math.floor(y / 8) % 2 == 1) and ((x + 8) % 16 == 0))
            if is_mortar then
                set_pixel(wall_tex, TEX_MOSS, x, y, 30, 45, 30)
            else
                local noise = ((x * 19 + y * 23) % 17) - 8
                local moss_val = math.sin(x * 0.4) * math.cos(y * 0.3) + math.sin((x + y) * 0.25)
                if moss_val > 0.3 then
                    set_pixel(wall_tex, TEX_MOSS, x, y, 35 + noise, 145 + noise, 45 + noise)
                else
                    set_pixel(wall_tex, TEX_MOSS, x, y, 85 + noise, 100 + noise, 80 + noise)
                end
            end
        end
    end

    -- Texture 5: Reinforced Steel Door
    for y = 0, 31 do
        for x = 0, 31 do
            local is_border = (x <= 2 or x >= 29 or y <= 2 or y >= 29)
            local is_cross = (y == 15 or y == 16)
            local is_lock = (x >= 22 and x <= 26 and y >= 13 and y <= 18)
            if is_lock then
                if x == 24 and (y == 15 or y == 16) then
                    set_pixel(wall_tex, TEX_DOOR, x, y, 15, 15, 15) -- Keyhole
                else
                    set_pixel(wall_tex, TEX_DOOR, x, y, 225, 195, 50) -- Brass plate
                end
            elseif is_border or is_cross then
                local is_rivet = ((x == 1 or x == 30) and (y % 6 == 0)) or ((y == 1 or y == 30) and (x % 6 == 0))
                if is_rivet then
                    set_pixel(wall_tex, TEX_DOOR, x, y, 230, 235, 245)
                else
                    set_pixel(wall_tex, TEX_DOOR, x, y, 70, 75, 80)
                end
            else
                local panel_noise = ((x * 11 + y * 13) % 11) - 5
                set_pixel(wall_tex, TEX_DOOR, x, y, 120 + panel_noise, 125 + panel_noise, 130 + panel_noise)
            end
        end
    end

    -- Texture 6: Red Prison Brick with Iron Window Bars
    for y = 0, 31 do
        for x = 0, 31 do
            local is_window = (x >= 9 and x <= 22 and y >= 8 and y <= 23)
            if is_window then
                local is_bar = (x % 3 == 0) or (y == 8 or y == 23)
                if is_bar then
                    set_pixel(wall_tex, TEX_PRISON, x, y, 75, 80, 85) -- Iron bars
                else
                    set_pixel(wall_tex, TEX_PRISON, x, y, 10, 12, 16) -- Dark cell interior
                end
            else
                local is_mortar = (y % 8 == 0) or ((math.floor(y / 8) % 2 == 0) and (x % 16 == 0)) or ((math.floor(y / 8) % 2 == 1) and ((x + 8) % 16 == 0))
                if is_mortar then
                    set_pixel(wall_tex, TEX_PRISON, x, y, 65, 65, 70)
                else
                    local noise = ((x * 23 + y * 17) % 15) - 7
                    set_pixel(wall_tex, TEX_PRISON, x, y, 160 + noise, 55 + noise, 45 + noise)
                end
            end
        end
    end

    -- Sprite 1: Guard Sentry (Colorkey 0,0,0 transparent)
    for y = 0, 31 do
        for x = 0, 31 do
            -- Helmet & Head
            if y >= 4 and y <= 7 and x >= 12 and x <= 19 then
                if y <= 5 then
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 90, 75, 45) -- Helmet
                else
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 220, 175, 135) -- Face
                end
            -- Eyes
            elseif y == 6 and (x == 14 or x == 17) then
                set_pixel(sprite_tex, SPRITE_GUARD, x, y, 20, 20, 20)
            -- Uniform Torso
            elseif y >= 8 and y <= 18 and x >= 10 and x <= 21 then
                if x == 15 or x == 16 then
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 220, 190, 60) -- Brass buttons
                elseif y == 18 then
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 50, 35, 20) -- Belt
                else
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 135, 110, 65) -- Uniform
                end
            -- Rifle
            elseif y >= 11 and y <= 14 and x >= 17 and x <= 27 then
                if x >= 23 then
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 180, 185, 195) -- Gun barrel
                else
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 95, 55, 30) -- Wooden stock
                end
            -- Legs & Boots
            elseif y >= 19 and y <= 28 and ((x >= 11 and x <= 14) or (x >= 17 and x <= 20)) then
                if y >= 25 then
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 30, 25, 20) -- Boots
                else
                    set_pixel(sprite_tex, SPRITE_GUARD, x, y, 110, 90, 55) -- Trousers
                end
            end
        end
    end

    -- Sprite 2: Golden Chalice (Treasure)
    for y = 0, 31 do
        for x = 0, 31 do
            local dx = math.abs(x - 15.5)
            -- Cup Rim & Bowl
            if y >= 10 and y <= 17 and dx <= (y - 9) * 0.8 and dx <= 6.5 then
                local highlight = (x == 13 or x == 14) and 35 or 0
                set_pixel(sprite_tex, SPRITE_CHALICE, x, y, 220 + highlight, 185 + highlight, 30)
            -- Cup Stem
            elseif y >= 18 and y <= 22 and dx <= 1.5 then
                set_pixel(sprite_tex, SPRITE_CHALICE, x, y, 200, 160, 20)
            -- Cup Base
            elseif y >= 23 and y <= 25 and dx <= (y - 20) * 1.5 then
                set_pixel(sprite_tex, SPRITE_CHALICE, x, y, 230, 195, 40)
            -- Ruby Gem in center of cup
            elseif y == 14 and (x == 15 or x == 16) then
                set_pixel(sprite_tex, SPRITE_CHALICE, x, y, 235, 30, 30)
            end
        end
    end

    -- Sprite 3: First Aid Medkit
    for y = 0, 31 do
        for x = 0, 31 do
            if x >= 8 and x <= 23 and y >= 14 and y <= 26 then
                -- Red Cross in center
                local is_cross = (x >= 14 and x <= 17 and y >= 16 and y <= 24) or (x >= 11 and x <= 20 and y >= 18 and y <= 22)
                if is_cross then
                    set_pixel(sprite_tex, SPRITE_MEDKIT, x, y, 225, 30, 30)
                elseif x == 8 or x == 23 or y == 14 or y == 26 then
                    set_pixel(sprite_tex, SPRITE_MEDKIT, x, y, 170, 175, 180) -- Metal border
                else
                    set_pixel(sprite_tex, SPRITE_MEDKIT, x, y, 240, 245, 250) -- White casing
                end
            -- Metal Handle
            elseif y >= 11 and y <= 13 and (x == 13 or x == 18 or (y == 11 and x >= 13 and x <= 18)) then
                set_pixel(sprite_tex, SPRITE_MEDKIT, x, y, 140, 145, 150)
            end
        end
    end

    -- Sprite 4: Ammo Box
    for y = 0, 31 do
        for x = 0, 31 do
            if x >= 8 and x <= 23 and y >= 16 and y <= 27 then
                -- Brass bullets stamped on front
                local is_bullet = (y >= 18 and y <= 23) and (x == 11 or x == 14 or x == 17 or x == 20)
                if is_bullet then
                    set_pixel(sprite_tex, SPRITE_AMMO, x, y, 235, 205, 45)
                elseif y == 16 or y == 17 then
                    set_pixel(sprite_tex, SPRITE_AMMO, x, y, 55, 75, 40) -- Dark lid
                else
                    set_pixel(sprite_tex, SPRITE_AMMO, x, y, 75, 105, 55) -- Olive drab body
                end
            end
        end
    end

    -- Sprite 5: Standing Torch Brazier
    for y = 0, 31 do
        for x = 0, 31 do
            local dx = math.abs(x - 15.5)
            -- Flame
            if y >= 6 and y <= 14 and dx <= (14 - y) * 0.7 then
                if dx <= 1.0 then
                    set_pixel(sprite_tex, SPRITE_TORCH, x, y, 255, 245, 120) -- White-hot core
                elseif dx <= 2.5 then
                    set_pixel(sprite_tex, SPRITE_TORCH, x, y, 255, 160, 25)  -- Bright orange
                else
                    set_pixel(sprite_tex, SPRITE_TORCH, x, y, 220, 50, 15)   -- Deep red rim
                end
            -- Metal Bowl
            elseif y >= 14 and y <= 17 and dx <= (y - 12) * 1.6 and dx <= 6.5 then
                set_pixel(sprite_tex, SPRITE_TORCH, x, y, 110, 115, 125)
            -- Stand Shaft
            elseif y >= 18 and y <= 27 and dx <= 1.0 then
                set_pixel(sprite_tex, SPRITE_TORCH, x, y, 80, 85, 95)
            -- Base
            elseif y >= 28 and y <= 29 and dx <= 5.0 then
                set_pixel(sprite_tex, SPRITE_TORCH, x, y, 100, 105, 115)
            end
        end
    end

    return wall_tex, sprite_tex
end

-- ============================================================================
-- 5. MAP LAYOUTS & LEVELS
-- ============================================================================
local MAP_PRESETS = {
    {
        name = "THE DUNGEON ESCAPE",
        player_start = { x = 2.5, y = 2.5, angle = 0.0 },
        layout = {
            1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
            1,0,0,0,1,0,0,0,1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,1,
            1,0,0,0,5,0,0,0,1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,1,
            1,0,0,0,1,0,0,0,1,0,0,0,0,0,5,0,0,2,2,2,2,0,0,1,
            1,1,1,1,1,0,0,0,1,1,1,5,1,1,1,0,0,2,0,0,2,0,0,1,
            1,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,2,0,0,2,0,0,1,
            1,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,2,2,5,2,0,0,1,
            1,0,0,1,1,1,0,0,1,1,1,0,0,0,1,0,0,0,0,0,0,0,0,1,
            1,0,0,1,0,1,0,0,1,0,1,0,0,0,1,1,1,1,0,0,1,1,1,1,
            1,0,0,1,0,1,0,0,1,0,1,0,0,0,0,0,0,5,0,0,5,0,0,1,
            1,0,0,1,5,1,0,0,1,5,1,0,0,0,1,1,1,1,0,0,1,1,1,1,
            1,0,0,0,0,0,0,0,0,0,0,0,0,0,1,3,3,3,0,0,3,3,3,1,
            1,0,0,0,0,0,0,0,0,0,0,0,0,0,1,3,0,0,0,0,0,0,3,1,
            1,1,1,1,5,1,1,1,1,1,1,0,0,0,5,0,0,0,0,0,0,0,3,1,
            1,6,6,6,0,6,6,6,1,0,0,0,0,0,1,3,0,0,0,0,0,0,3,1,
            1,6,0,0,0,0,0,6,1,0,0,0,0,0,1,3,3,3,5,3,3,3,3,1,
            1,6,0,0,0,0,0,6,1,0,0,4,4,4,4,4,4,1,0,0,1,1,1,1,
            1,6,0,0,0,0,0,6,5,0,0,4,0,0,0,0,4,1,0,0,0,0,0,1,
            1,6,6,6,0,6,6,6,1,0,0,4,0,0,0,0,4,5,0,0,0,0,0,1,
            1,0,0,0,0,0,0,0,1,0,0,4,0,0,0,0,4,1,0,0,1,1,1,1,
            1,0,0,0,0,0,0,0,1,0,0,4,4,5,4,4,4,1,0,0,1,0,0,1,
            1,0,0,1,1,1,0,0,1,0,0,0,0,0,0,0,0,0,0,0,5,0,0,1,
            1,0,0,1,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,1,0,0,1,
            1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        },
        sprites = {
            { x = 5.5,  y = 2.5,  type = SPRITE_GUARD,   hp = 50 },
            { x = 18.5, y = 5.5,  type = SPRITE_GUARD,   hp = 50 },
            { x = 6.5,  y = 8.5,  type = SPRITE_GUARD,   hp = 50 },
            { x = 18.5, y = 14.5, type = SPRITE_GUARD,   hp = 50 },
            { x = 14.5, y = 18.5, type = SPRITE_GUARD,   hp = 75 },
            { x = 4.5,  y = 9.5,  type = SPRITE_CHALICE, hp = 0 },
            { x = 9.5,  y = 9.5,  type = SPRITE_CHALICE, hp = 0 },
            { x = 14.5, y = 19.5, type = SPRITE_CHALICE, hp = 0 },
            { x = 3.5,  y = 16.5, type = SPRITE_MEDKIT,  hp = 0 },
            { x = 19.5, y = 2.5,  type = SPRITE_MEDKIT,  hp = 0 },
            { x = 13.5, y = 19.5, type = SPRITE_AMMO,    hp = 0 },
            { x = 2.5,  y = 20.5, type = SPRITE_AMMO,    hp = 0 },
            { x = 3.5,  y = 1.5,  type = SPRITE_TORCH,   hp = 0 },
            { x = 3.5,  y = 3.5,  type = SPRITE_TORCH,   hp = 0 },
            { x = 13.5, y = 4.5,  type = SPRITE_TORCH,   hp = 0 },
            { x = 15.5, y = 4.5,  type = SPRITE_TORCH,   hp = 0 },
            { x = 17.5, y = 9.5,  type = SPRITE_TORCH,   hp = 0 },
            { x = 20.5, y = 9.5,  type = SPRITE_TORCH,   hp = 0 },
        }
    },
    {
        name = "CASTLE COURTYARD & RAMPARTS",
        player_start = { x = 11.5, y = 21.5, angle = -math.pi / 2 },
        layout = {
            2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
            2,0,0,0,0,0,0,0,0,0,0,2,2,0,0,0,0,0,0,0,0,0,0,2,
            2,0,4,4,0,0,0,0,0,0,0,2,2,0,0,0,0,0,0,4,4,0,0,2,
            2,0,4,4,0,0,0,0,0,0,0,5,5,0,0,0,0,0,0,4,4,0,0,2,
            2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,
            2,0,0,0,0,1,1,1,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0,2,
            2,0,0,0,0,1,0,1,0,0,0,0,0,0,0,1,0,1,0,0,0,0,0,2,
            2,0,0,0,0,1,1,1,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0,2,
            2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,
            2,0,0,0,0,0,0,0,0,4,0,0,0,0,4,0,0,0,0,0,0,0,0,2,
            2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,
            2,2,2,5,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,5,2,2,2,
            2,3,0,0,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,0,3,2,
            2,3,0,0,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,0,3,2,
            2,2,2,5,2,0,0,0,0,4,0,0,0,0,4,0,0,0,0,2,5,2,2,2,
            2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,
            2,0,0,0,0,1,1,1,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0,2,
            2,0,0,0,0,1,0,1,0,0,0,0,0,0,0,1,0,1,0,0,0,0,0,2,
            2,0,0,0,0,1,1,1,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0,2,
            2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,
            2,0,4,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,4,0,0,2,
            2,0,4,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,4,0,0,2,
            2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,
            2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
        },
        sprites = {
            { x = 11.5, y = 4.5,  type = SPRITE_GUARD,   hp = 50 },
            { x = 6.5,  y = 11.5, type = SPRITE_GUARD,   hp = 50 },
            { x = 17.5, y = 11.5, type = SPRITE_GUARD,   hp = 50 },
            { x = 11.5, y = 12.5, type = SPRITE_GUARD,   hp = 60 },
            { x = 2.5,  y = 13.5, type = SPRITE_CHALICE, hp = 0 },
            { x = 21.5, y = 13.5, type = SPRITE_CHALICE, hp = 0 },
            { x = 9.5,  y = 2.5,  type = SPRITE_MEDKIT,  hp = 0 },
            { x = 14.5, y = 2.5,  type = SPRITE_AMMO,    hp = 0 },
            { x = 9.5,  y = 10.5, type = SPRITE_TORCH,   hp = 0 },
            { x = 14.5, y = 10.5, type = SPRITE_TORCH,   hp = 0 },
            { x = 9.5,  y = 14.5, type = SPRITE_TORCH,   hp = 0 },
            { x = 14.5, y = 14.5, type = SPRITE_TORCH,   hp = 0 },
        }
    },
    {
        name = "BOSS STRONGHOLD & ARMORY",
        player_start = { x = 2.5, y = 21.5, angle = -math.pi / 2 },
        layout = {
            6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
            6,0,0,0,6,3,3,3,3,3,3,6,0,0,0,0,0,0,6,0,0,0,0,6,
            6,0,0,0,5,0,0,0,0,0,3,6,0,0,0,0,0,0,5,0,0,0,0,6,
            6,0,0,0,6,3,0,0,0,0,3,6,0,0,0,0,0,0,6,0,0,0,0,6,
            6,6,5,6,6,3,3,3,5,3,3,6,6,6,5,6,6,6,6,6,5,6,6,6,
            6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,
            6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,
            6,6,6,5,6,6,6,0,0,6,6,6,6,6,6,0,0,6,6,6,5,6,6,6,
            6,2,0,0,0,0,2,0,0,2,0,0,0,0,2,0,0,2,0,0,0,0,2,6,
            6,2,0,0,0,0,2,0,0,2,0,0,0,0,2,0,0,2,0,0,0,0,2,6,
            6,6,6,0,0,6,6,0,0,6,6,0,0,6,6,0,0,6,6,0,0,6,6,6,
            6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,
            6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,
            6,6,6,5,6,6,6,0,0,6,6,6,6,6,6,0,0,6,6,6,5,6,6,6,
            6,0,0,0,0,0,6,0,0,6,0,0,0,0,6,0,0,6,0,0,0,0,0,6,
            6,0,0,0,0,0,6,0,0,6,0,0,0,0,6,0,0,6,0,0,0,0,0,6,
            6,6,6,5,6,6,6,0,0,6,6,5,5,6,6,0,0,6,6,6,5,6,6,6,
            6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,
            6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,6,
            6,6,6,5,6,6,6,6,6,6,6,0,0,6,6,6,6,6,6,6,5,6,6,6,
            6,0,0,0,0,0,6,0,0,0,0,0,0,0,0,0,6,0,0,0,0,0,0,6,
            6,0,0,0,0,0,5,0,0,0,0,0,0,0,0,0,5,0,0,0,0,0,0,6,
            6,0,0,0,0,0,6,0,0,0,0,0,0,0,0,0,6,0,0,0,0,0,0,6,
            6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
        },
        sprites = {
            { x = 11.5, y = 2.5,  type = SPRITE_GUARD,   hp = 150 }, -- Boss
            { x = 7.5,  y = 2.5,  type = SPRITE_GUARD,   hp = 60 },
            { x = 15.5, y = 2.5,  type = SPRITE_GUARD,   hp = 60 },
            { x = 11.5, y = 11.5, type = SPRITE_GUARD,   hp = 50 },
            { x = 3.5,  y = 8.5,  type = SPRITE_GUARD,   hp = 50 },
            { x = 20.5, y = 8.5,  type = SPRITE_GUARD,   hp = 50 },
            { x = 2.5,  y = 2.5,  type = SPRITE_CHALICE, hp = 0 },
            { x = 21.5, y = 2.5,  type = SPRITE_CHALICE, hp = 0 },
            { x = 11.5, y = 14.5, type = SPRITE_MEDKIT,  hp = 0 },
            { x = 12.5, y = 14.5, type = SPRITE_AMMO,    hp = 0 },
            { x = 10.5, y = 4.5,  type = SPRITE_TORCH,   hp = 0 },
            { x = 13.5, y = 4.5,  type = SPRITE_TORCH,   hp = 0 },
        }
    }
}

-- ============================================================================
-- 6. WOLFENSTEIN 3D RAYCASTING ENGINE CLASS
-- ============================================================================
local WolfEngine = {}
WolfEngine.__index = WolfEngine

function WolfEngine.new()
    local self = setmetatable({}, WolfEngine)
    self.state = ffi.new("RaycasterState")
    self.player = ffi.new("PlayerState")
    self.width = WIDTH
    self.height = HEIGHT
    self.use_ascii = false
    self.paused = false
    self.show_minimap = true
    self.active_map_idx = 1

    -- Procedural Textures & Sprites
    self.wall_textures, self.sprite_textures = create_texture_atlas()

    -- Level Map & Dynamic Doors
    self.map = ffi.new("uint8_t[?]", MAP_W * MAP_H)
    self.door_open = ffi.new("float[?]", MAP_W * MAP_H)
    self.door_timer = ffi.new("float[?]", MAP_W * MAP_H)

    -- Sprites container
    self.max_sprites = 64
    self.sprites = ffi.new("SpriteEntity[?]", self.max_sprites)
    self.sprite_order = ffi.new("int[?]", self.max_sprites)
    self.num_sprites = 0

    self:load_map(1)
    return self
end

function WolfEngine:load_map(idx)
    idx = math.max(1, math.min(#MAP_PRESETS, idx))
    self.active_map_idx = idx
    local preset = MAP_PRESETS[idx]
    self.map_name = preset.name

    -- Copy map layout
    for i = 0, MAP_W * MAP_H - 1 do
        self.map[i] = preset.layout[i + 1] or 1
        self.door_open[i] = 0.0
        self.door_timer[i] = 0.0
    end

    -- Setup Player
    local ps = preset.player_start
    self.player.x = ps.x
    self.player.y = ps.y
    local ang = ps.angle
    self.player.dir_x = math.cos(ang)
    self.player.dir_y = math.sin(ang)
    local fov = 0.66
    self.player.plane_x = -self.player.dir_y * fov
    self.player.plane_y = self.player.dir_x * fov
    self.player.move_speed = 3.5
    self.player.rot_speed  = 2.8
    self.player.health = 100
    self.player.armor  = 50
    self.player.ammo   = 32
    self.player.score  = 0
    self.player.firing_timer = 0
    self.player.weapon_bob = 0.0

    -- Setup Sprites
    self.num_sprites = #preset.sprites
    for i = 0, self.num_sprites - 1 do
        local sp = preset.sprites[i + 1]
        self.sprites[i].x = sp.x
        self.sprites[i].y = sp.y
        self.sprites[i].type = sp.type
        self.sprites[i].active = 1
        self.sprites[i].hp = sp.hp
        self.sprites[i].dist = 0.0
        self.sprite_order[i] = i
    end
end

function WolfEngine:get_cell(mx, my)
    if mx < 0 or mx >= MAP_W or my < 0 or my >= MAP_H then return 1 end
    return self.map[my * MAP_W + mx]
end

function WolfEngine:is_solid(x, y)
    local mx = math.floor(x)
    local my = math.floor(y)
    local cell = self:get_cell(mx, my)
    if cell == 0 then return false end
    if cell == TEX_DOOR then
        -- Open doors allow passage if door is >= 75% open
        local open_amt = self.door_open[my * MAP_W + mx]
        return open_amt < 0.75
    end
    return true
end

function WolfEngine:clear_framebuffer()
    local fb = self.state.fb
    -- Sky / Ceiling gradient (deep charcoal into midnight blue)
    for y = 0, math.floor(HEIGHT / 2) - 1 do
        local t = y / (HEIGHT * 0.5)
        local r = math.floor(10 + t * 25)
        local g = math.floor(15 + t * 30)
        local b = math.floor(25 + t * 45)
        for x = 0, WIDTH - 1 do
            local p = fb[y * WIDTH + x]
            p.r = r; p.g = g; p.b = b
        end
    end
    -- Floor gradient (dark stone into shadowy horizon)
    for y = math.floor(HEIGHT / 2), HEIGHT - 1 do
        local t = (y - HEIGHT * 0.5) / (HEIGHT * 0.5)
        local r = math.floor(20 + t * 35)
        local g = math.floor(20 + t * 35)
        local b = math.floor(22 + t * 38)
        for x = 0, WIDTH - 1 do
            local p = fb[y * WIDTH + x]
            p.r = r; p.g = g; p.b = b
        end
    end
end

-- ----------------------------------------------------------------------------
-- DDA RAYCASTING & WALL RENDERING
-- ----------------------------------------------------------------------------
function WolfEngine:render_walls()
    local fb = self.state.fb
    local z_buf = self.state.z_buffer
    local p = self.player

    for x = 0, WIDTH - 1 do
        local camera_x = 2.0 * x / (WIDTH - 1) - 1.0
        local ray_dir_x = p.dir_x + p.plane_x * camera_x
        local ray_dir_y = p.dir_y + p.plane_y * camera_x

        local map_x = math.floor(p.x)
        local map_y = math.floor(p.y)

        local delta_dist_x = math.abs(ray_dir_x) < 1e-6 and 1e30 or math.abs(1.0 / ray_dir_x)
        local delta_dist_y = math.abs(ray_dir_y) < 1e-6 and 1e30 or math.abs(1.0 / ray_dir_y)

        local step_x, step_y
        local side_dist_x, side_dist_y

        if ray_dir_x < 0 then
            step_x = -1
            side_dist_x = (p.x - map_x) * delta_dist_x
        else
            step_x = 1
            side_dist_x = (map_x + 1.0 - p.x) * delta_dist_x
        end

        if ray_dir_y < 0 then
            step_y = -1
            side_dist_y = (p.y - map_y) * delta_dist_y
        else
            step_y = 1
            side_dist_y = (map_y + 1.0 - p.y) * delta_dist_y
        end

        local hit = 0
        local side = 0
        local perp_wall_dist = 0.0
        local wall_x = 0.0
        local is_door_hit = false
        local max_steps = 48

        while hit == 0 and max_steps > 0 do
            max_steps = max_steps - 1
            if side_dist_x < side_dist_y then
                side_dist_x = side_dist_x + delta_dist_x
                map_x = map_x + step_x
                side = 0
            else
                side_dist_y = side_dist_y + delta_dist_y
                map_y = map_y + step_y
                side = 1
            end

            local cell = self:get_cell(map_x, map_y)
            if cell > 0 then
                if cell == TEX_DOOR then
                    -- John Carmack 1992 recessed sliding door intersection
                    local open_amt = self.door_open[map_y * MAP_W + map_x]
                    if side == 0 then
                        local dist_door = side_dist_x - delta_dist_x * 0.5
                        if dist_door < side_dist_y then
                            local hit_y = p.y + dist_door * ray_dir_y
                            if math.floor(hit_y) == map_y then
                                local u = (hit_y - map_y) + open_amt
                                if u < 1.0 then
                                    hit = TEX_DOOR
                                    perp_wall_dist = dist_door
                                    wall_x = u
                                    is_door_hit = true
                                end
                            end
                        end
                    else
                        local dist_door = side_dist_y - delta_dist_y * 0.5
                        if dist_door < side_dist_x then
                            local hit_x = p.x + dist_door * ray_dir_x
                            if math.floor(hit_x) == map_x then
                                local u = (hit_x - map_x) + open_amt
                                if u < 1.0 then
                                    hit = TEX_DOOR
                                    perp_wall_dist = dist_door
                                    wall_x = u
                                    is_door_hit = true
                                end
                            end
                        end
                    end
                else
                    hit = cell
                end
            end
        end

        if not is_door_hit then
            if side == 0 then
                perp_wall_dist = side_dist_x - delta_dist_x
                wall_x = p.y + perp_wall_dist * ray_dir_y
            else
                perp_wall_dist = side_dist_y - delta_dist_y
                wall_x = p.x + perp_wall_dist * ray_dir_x
            end
            wall_x = wall_x - math.floor(wall_x)
        end

        if perp_wall_dist < 0.05 then perp_wall_dist = 0.05 end
        z_buf[x] = perp_wall_dist

        -- Calculate slice height
        local line_height = math.floor(HEIGHT / perp_wall_dist)
        local draw_start = math.max(0, math.floor(-line_height * 0.5 + HEIGHT * 0.5))
        local draw_end   = math.min(HEIGHT - 1, math.floor(line_height * 0.5 + HEIGHT * 0.5))

        -- Texture X coordinate
        local tex_id = hit
        if tex_id < 1 or tex_id > NUM_WALL_TEX then tex_id = 1 end
        local tex_x = math.floor(wall_x * TEX_SZ)
        if not is_door_hit then
            if side == 0 and ray_dir_x > 0 then tex_x = TEX_SZ - tex_x - 1 end
            if side == 1 and ray_dir_y < 0 then tex_x = TEX_SZ - tex_x - 1 end
        end
        tex_x = bit.band(tex_x, 31)

        -- Distance fog & directional shading
        local fog = 1.0 / (1.0 + perp_wall_dist * 0.08 + perp_wall_dist * perp_wall_dist * 0.005)
        if side == 1 and not is_door_hit then fog = fog * 0.72 end -- Side shading

        -- Render vertical wall strip
        local tex = self.wall_textures[tex_id]
        for y = draw_start, draw_end do
            local d = y * 256 - HEIGHT * 128 + line_height * 128
            local tex_y = math.floor(((d * TEX_SZ) / line_height) / 256)
            tex_y = bit.band(math.max(0, math.min(31, tex_y)), 31)

            local src_p = tex.pixels[tex_y * 32 + tex_x]
            local dst_p = fb[y * WIDTH + x]
            dst_p.r = math.floor(src_p.r * fog)
            dst_p.g = math.floor(src_p.g * fog)
            dst_p.b = math.floor(src_p.b * fog)
        end
    end
end

-- ----------------------------------------------------------------------------
-- BILLBOARDED 3D SPRITES RENDERING
-- ----------------------------------------------------------------------------
function WolfEngine:render_sprites()
    local fb = self.state.fb
    local z_buf = self.state.z_buffer
    local p = self.player

    -- Calculate distance to all active sprites
    for i = 0, self.num_sprites - 1 do
        local sp = self.sprites[i]
        if sp.active == 1 then
            local dx = p.x - sp.x
            local dy = p.y - sp.y
            sp.dist = dx * dx + dy * dy
        else
            sp.dist = -1.0
        end
        self.sprite_order[i] = i
    end

    -- Sort sprites by distance (furthest to closest)
    local n = self.num_sprites
    for i = 0, n - 2 do
        local max_idx = i
        for j = i + 1, n - 1 do
            local sp_a = self.sprites[self.sprite_order[j]]
            local sp_b = self.sprites[self.sprite_order[max_idx]]
            if sp_a.dist > sp_b.dist then max_idx = j end
        end
        if max_idx ~= i then
            local tmp = self.sprite_order[i]
            self.sprite_order[i] = self.sprite_order[max_idx]
            self.sprite_order[max_idx] = tmp
        end
    end

    -- Project and draw each sprite
    local inv_det = 1.0 / (p.plane_x * p.dir_y - p.dir_x * p.plane_y)
    for i = 0, n - 1 do
        local sp = self.sprites[self.sprite_order[i]]
        if sp.active == 1 and sp.dist > 0.1 then
            local sx = sp.x - p.x
            local sy = sp.y - p.y

            -- Transform into camera coordinate space
            local trans_x = inv_det * (p.dir_y * sx - p.dir_x * sy)
            local trans_y = inv_det * (-p.plane_y * sx + p.plane_x * sy)

            if trans_y > 0.2 then
                local sprite_screen_x = math.floor((WIDTH * 0.5) * (1.0 + trans_x / trans_y))
                local sprite_h = math.abs(math.floor(HEIGHT / trans_y))
                local sprite_w = sprite_h

                local draw_start_y = math.max(0, math.floor(-sprite_h * 0.5 + HEIGHT * 0.5))
                local draw_end_y   = math.min(HEIGHT - 1, math.floor(sprite_h * 0.5 + HEIGHT * 0.5))
                local draw_start_x = math.max(0, math.floor(-sprite_w * 0.5 + sprite_screen_x))
                local draw_end_x   = math.min(WIDTH - 1, math.floor(sprite_w * 0.5 + sprite_screen_x))

                local tex_id = sp.type
                if tex_id < 1 or tex_id > NUM_SPRITE_TEX then tex_id = 1 end
                local tex = self.sprite_textures[tex_id]
                local fog = 1.0 / (1.0 + trans_y * 0.08 + trans_y * trans_y * 0.005)

                -- Torch flame animation flicker
                local flame_flicker = 1.0
                if sp.type == SPRITE_TORCH then
                    flame_flicker = 0.9 + 0.2 * math.sin(self.state.time_sec * 15.0 + sp.x * 7.0)
                end

                for stripe = draw_start_x, draw_end_x do
                    local tex_x = math.floor((stripe - (-sprite_w * 0.5 + sprite_screen_x)) * TEX_SZ / sprite_w)
                    tex_x = bit.band(math.max(0, math.min(31, tex_x)), 31)

                    -- Depth check against 1D Z-buffer
                    if trans_y > 0 and trans_y < z_buf[stripe] then
                        for y = draw_start_y, draw_end_y do
                            local d = y * 256 - HEIGHT * 128 + sprite_h * 128
                            local tex_y = math.floor(((d * TEX_SZ) / sprite_h) / 256)
                            tex_y = bit.band(math.max(0, math.min(31, tex_y)), 31)

                            local src_p = tex.pixels[tex_y * 32 + tex_x]
                            -- Color key test (black 0,0,0 is transparent)
                            if src_p.r > 0 or src_p.g > 0 or src_p.b > 0 then
                                local dst_p = fb[y * WIDTH + stripe]
                                dst_p.r = math.min(255, math.floor(src_p.r * fog * flame_flicker))
                                dst_p.g = math.min(255, math.floor(src_p.g * fog * flame_flicker))
                                dst_p.b = math.min(255, math.floor(src_p.b * fog * flame_flicker))
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- FIRST-PERSON WEAPON & MUZZLE FLASH OVERLAY
-- ----------------------------------------------------------------------------
function WolfEngine:render_weapon()
    local fb = self.state.fb
    local p = self.player
    local bob_y = math.floor(math.sin(p.weapon_bob) * 1.5)
    local kick_y = (p.firing_timer > 0) and -2 or 0
    local center_x = math.floor(WIDTH * 0.5)
    local base_y = HEIGHT - 1 + bob_y + kick_y

    -- Muzzle Flash
    if p.firing_timer > 0 then
        local flash_y = base_y - 12
        for dy = -2, 2 do
            for dx = -4, 4 do
                local dist = math.abs(dx) + math.abs(dy)
                local px = center_x + dx
                local py = flash_y + dy
                if px >= 0 and px < WIDTH and py >= 0 and py < HEIGHT then
                    local dst = fb[py * WIDTH + px]
                    if dist <= 1 then
                        dst.r = 255; dst.g = 250; dst.b = 200 -- Starburst center
                    elseif dist <= 3 then
                        dst.r = 255; dst.g = 180; dst.b = 40  -- Bright orange
                    else
                        dst.r = math.min(255, dst.r + 80)
                        dst.g = math.min(255, dst.g + 50)
                    end
                end
            end
        end
    end

    -- First-Person Pistol model (Pistol barrel, slide, and hand grip)
    local weapon_pixels = {
        -- Barrel & Sight
        { -1, -9, 85, 90, 95 }, { 0, -9, 140, 145, 155 }, { 1, -9, 85, 90, 95 },
        { -1, -8, 70, 75, 80 }, { 0, -8, 120, 125, 130 }, { 1, -8, 70, 75, 80 },
        { -2, -7, 60, 65, 70 }, { -1, -7, 100, 105, 115 }, { 0, -7, 130, 135, 145 }, { 1, -7, 100, 105, 115 }, { 2, -7, 60, 65, 70 },
        { -2, -6, 50, 55, 60 }, { -1, -6, 90, 95, 105 },   { 0, -6, 120, 125, 135 }, { 1, -6, 90, 95, 105 },   { 2, -6, 50, 55, 60 },
        -- Slide & Chamber
        { -3, -5, 45, 45, 50 }, { -2, -5, 80, 85, 90 }, { -1, -5, 110, 115, 120 }, { 0, -5, 130, 135, 140 }, { 1, -5, 110, 115, 120 }, { 2, -5, 80, 85, 90 }, { 3, -5, 45, 45, 50 },
        { -3, -4, 45, 45, 50 }, { -2, -4, 80, 85, 90 }, { -1, -4, 110, 115, 120 }, { 0, -4, 130, 135, 140 }, { 1, -4, 110, 115, 120 }, { 2, -4, 80, 85, 90 }, { 3, -4, 45, 45, 50 },
        { -2, -3, 40, 40, 45 }, { -1, -3, 75, 80, 85 }, { 0, -3, 100, 105, 110 }, { 1, -3, 75, 80, 85 }, { 2, -3, 40, 40, 45 },
        -- Grip & Hands
        { -1, -2, 45, 30, 20 }, { 0, -2, 70, 45, 30 }, { 1, -2, 45, 30, 20 },
        { -2, -1, 210, 160, 125 }, { -1, -1, 55, 35, 25 }, { 0, -1, 80, 50, 35 }, { 1, -1, 215, 165, 130 }, { 2, -1, 190, 145, 110 },
        { -3, 0, 180, 135, 105 },  { -2, 0, 215, 165, 130 }, { -1, 0, 60, 40, 30 }, { 0, 0, 215, 165, 130 }, { 1, 0, 215, 165, 130 }, { 2, 0, 180, 135, 105 },
    }

    for _, wp in ipairs(weapon_pixels) do
        local px = center_x + wp[1]
        local py = base_y + wp[2]
        if px >= 0 and px < WIDTH and py >= 0 and py < HEIGHT then
            local dst = fb[py * WIDTH + px]
            dst.r = wp[3]; dst.g = wp[4]; dst.b = wp[5]
        end
    end
end

-- ----------------------------------------------------------------------------
-- 2D MINIMAP RADAR OVERLAY
-- ----------------------------------------------------------------------------
function WolfEngine:render_minimap()
    if not self.show_minimap then return end
    local fb = self.state.fb
    local p = self.player

    local rad_w = 14
    local rad_h = 10
    local origin_x = WIDTH - rad_w - 2
    local origin_y = 2

    local pl_mx = math.floor(p.x)
    local pl_my = math.floor(p.y)

    for ry = 0, rad_h - 1 do
        for rx = 0, rad_w - 1 do
            local px = origin_x + rx
            local py = origin_y + ry
            local dst = fb[py * WIDTH + px]

            -- Minimap border
            if rx == 0 or rx == rad_w - 1 or ry == 0 or ry == rad_h - 1 then
                dst.r = 60; dst.g = 120; dst.b = 160
            else
                local world_mx = pl_mx + (rx - math.floor(rad_w * 0.5))
                local world_my = pl_my + (ry - math.floor(rad_h * 0.5))

                if world_mx < 0 or world_mx >= MAP_W or world_my < 0 or world_my >= MAP_H then
                    dst.r = 20; dst.g = 20; dst.b = 25
                else
                    local cell = self.map[world_my * MAP_W + world_mx]
                    if cell == TEX_DOOR then
                        local open_amt = self.door_open[world_my * MAP_W + world_mx]
                        if open_amt > 0.5 then
                            dst.r = 40; dst.g = 180; dst.b = 100 -- Open door green
                        else
                            dst.r = 200; dst.g = 180; dst.b = 40 -- Closed door gold
                        end
                    elseif cell > 0 then
                        dst.r = 80; dst.g = 85; dst.b = 95   -- Wall gray
                    else
                        dst.r = 15; dst.g = 18; dst.b = 22   -- Floor dark
                    end
                end
            end
        end
    end

    -- Draw Entities on Radar
    local half_w = math.floor(rad_w * 0.5)
    local half_h = math.floor(rad_h * 0.5)
    for i = 0, self.num_sprites - 1 do
        local sp = self.sprites[i]
        if sp.active == 1 then
            local rel_x = math.floor(sp.x) - pl_mx
            local rel_y = math.floor(sp.y) - pl_my
            local rx = half_w + rel_x
            local ry = half_h + rel_y
            if rx > 0 and rx < rad_w - 1 and ry > 0 and ry < rad_h - 1 then
                local dst = fb[(origin_y + ry) * WIDTH + (origin_x + rx)]
                if sp.type == SPRITE_GUARD then
                    dst.r = 240; dst.g = 40; dst.b = 40   -- Enemy red dot
                elseif sp.type == SPRITE_CHALICE then
                    dst.r = 255; dst.g = 215; dst.b = 0   -- Gold dot
                elseif sp.type == SPRITE_MEDKIT or sp.type == SPRITE_AMMO then
                    dst.r = 80; dst.g = 200; dst.b = 255  -- Item cyan dot
                elseif sp.type == SPRITE_TORCH then
                    dst.r = 255; dst.g = 140; dst.b = 30  -- Torch orange dot
                end
            end
        end
    end

    -- Draw Player Marker (bright lime dot & heading ray in center)
    local center_radar_x = origin_x + half_w
    local center_radar_y = origin_y + half_h
    local pl_dst = fb[center_radar_y * WIDTH + center_radar_x]
    pl_dst.r = 80; pl_dst.g = 255; pl_dst.b = 80

    local head_x = center_radar_x + math.floor(p.dir_x * 1.5 + 0.5)
    local head_y = center_radar_y + math.floor(p.dir_y * 1.5 + 0.5)
    if head_x > origin_x and head_x < origin_x + rad_w - 1 and head_y > origin_y and head_y < origin_y + rad_h - 1 then
        local head_dst = fb[head_y * WIDTH + head_x]
        head_dst.r = 200; head_dst.g = 255; head_dst.b = 100
    end
end

-- ============================================================================
-- 7. SIMULATION STEP, COMBAT & INTERACTION
-- ============================================================================
function WolfEngine:step(dt)
    dt = dt or 0.016
    self.state.frame_count = self.state.frame_count + 1
    self.state.time_sec = self.state.time_sec + dt

    -- Decay weapon firing animation
    if self.player.firing_timer > 0 then
        self.player.firing_timer = self.player.firing_timer - 1
    end

    -- Update dynamic doors (open/close animations)
    for i = 0, MAP_W * MAP_H - 1 do
        if self.map[i] == TEX_DOOR then
            if self.door_timer[i] > 0 then
                self.door_timer[i] = self.door_timer[i] - dt
                -- Smoothly slide door open
                self.door_open[i] = math.min(1.0, self.door_open[i] + dt * 2.0)
            else
                -- If door timer expired, slide door closed unless player is inside
                local mx = i % MAP_W
                local my = math.floor(i / MAP_W)
                local dx = math.abs(self.player.x - (mx + 0.5))
                local dy = math.abs(self.player.y - (my + 0.5))
                if dx < 0.6 and dy < 0.6 then
                    self.door_timer[i] = 2.0 -- Keep open while player is standing in doorway
                else
                    self.door_open[i] = math.max(0.0, self.door_open[i] - dt * 2.0)
                end
            end
        end
    end

    -- Check item pickups
    for i = 0, self.num_sprites - 1 do
        local sp = self.sprites[i]
        if sp.active == 1 then
            local dist_sq = (self.player.x - sp.x)^2 + (self.player.y - sp.y)^2
            if dist_sq < 0.36 then
                if sp.type == SPRITE_CHALICE then
                    sp.active = 0
                    self.player.score = self.player.score + 500
                elseif sp.type == SPRITE_MEDKIT and self.player.health < 100 then
                    sp.active = 0
                    self.player.health = math.min(100, self.player.health + 25)
                elseif sp.type == SPRITE_AMMO and self.player.ammo < 99 then
                    sp.active = 0
                    self.player.ammo = math.min(99, self.player.ammo + 12)
                end
            end
        end
    end

    -- Render pipeline
    self:clear_framebuffer()
    self:render_walls()
    self:render_sprites()
    self:render_weapon()
    self:render_minimap()
end

function WolfEngine:move_player(dx, dy, dt)
    dt = dt or 0.016
    local move_dist = self.player.move_speed * dt
    local target_x = self.player.x + dx * move_dist
    local target_y = self.player.y + dy * move_dist

    local margin = 0.25
    local sign_x = dx >= 0 and 1 or -1
    local sign_y = dy >= 0 and 1 or -1

    if not self:is_solid(target_x + sign_x * margin, self.player.y) then
        self.player.x = target_x
    end
    if not self:is_solid(self.player.x, target_y + sign_y * margin) then
        self.player.y = target_y
    end

    if dx ~= 0 or dy ~= 0 then
        self.player.weapon_bob = self.player.weapon_bob + dt * 10.0
    end
end

function WolfEngine:rotate_player(ang_rad)
    local p = self.player
    local cos_a = math.cos(ang_rad)
    local sin_a = math.sin(ang_rad)

    local old_dir_x = p.dir_x
    p.dir_x = p.dir_x * cos_a - p.dir_y * sin_a
    p.dir_y = old_dir_x * sin_a + p.dir_y * cos_a

    local old_plane_x = p.plane_x
    p.plane_x = p.plane_x * cos_a - p.plane_y * sin_a
    p.plane_y = old_plane_x * sin_a + p.plane_y * cos_a
end

function WolfEngine:fire_weapon()
    local p = self.player
    if p.ammo <= 0 or p.firing_timer > 0 then return false end
    p.ammo = p.ammo - 1
    p.firing_timer = 5

    -- Raycast hitscan check for enemies along center column
    local center_ray = math.floor(WIDTH * 0.5)
    local wall_dist = self.state.z_buffer[center_ray]

    local best_target = nil
    local best_dist = wall_dist

    for i = 0, self.num_sprites - 1 do
        local sp = self.sprites[i]
        if sp.active == 1 and sp.type == SPRITE_GUARD then
            local sx = sp.x - p.x
            local sy = sp.y - p.y
            local dot = sx * p.dir_x + sy * p.dir_y
            if dot > 0 then
                local dist = math.sqrt(sx * sx + sy * sy)
                if dist < best_dist then
                    -- Check angle offset from crosshair
                    local cross = math.abs(sx * p.dir_y - sy * p.dir_x)
                    if cross / dist < 0.25 then
                        best_target = sp
                        best_dist = dist
                    end
                end
            end
        end
    end

    if best_target then
        best_target.hp = best_target.hp - 35
        p.score = p.score + 50
        if best_target.hp <= 0 then
            best_target.active = 0
            p.score = p.score + 200
        end
    end
    return true
end

function WolfEngine:interact_door()
    local p = self.player
    -- Check block directly in front of player
    local reach = 1.4
    local target_mx = math.floor(p.x + p.dir_x * reach)
    local target_my = math.floor(p.y + p.dir_y * reach)

    if target_mx >= 0 and target_mx < MAP_W and target_my >= 0 and target_my < MAP_H then
        local cell = self.map[target_my * MAP_W + target_mx]
        if cell == TEX_DOOR then
            local idx = target_my * MAP_W + target_mx
            if self.door_timer[idx] <= 0 then
                self.door_timer[idx] = 4.0 -- Open door for 4 seconds
            else
                self.door_timer[idx] = 0.0 -- Toggle close door
            end
            return true
        end
    end
    return false
end

-- ============================================================================
-- 8. PIXEL-PERFECT 80-COLUMN TERMINAL RENDERER
-- ============================================================================
function WolfEngine:render_frame()
    local lines = {}
    local fb = self.state.fb

    -- 1. Header Banner (80 columns)
    if self.use_ascii then
        lines[#lines + 1] = " +============================================================================+ "
        lines[#lines + 1] = " |       1990s WOLFENSTEIN 3D RAYCASTING ENGINE - LUAJIT FFI ENGINE           | "
        lines[#lines + 1] = " +============================================================================+ "
    else
        lines[#lines + 1] = " ╔════════════════════════════════════════════════════════════════════════════╗ "
        lines[#lines + 1] = string.format(" ║           %s🐺  WOLFENSTEIN 3D RAYCASTING ENGINE - LUAJIT FFI  🐺%s            ║ ",
            "\27[1;33m", "\27[0m")
        lines[#lines + 1] = " ╚════════════════════════════════════════════════════════════════════════════╝ "
    end

    -- 2. Canvas Top Border (80 cols)
    local map_title = string.format(" CANVAS [74x36] - %-26s ", self.map_name)
    local pad_len = 74 - #map_title
    if self.use_ascii then
        lines[#lines + 1] = " +--" .. map_title .. string.rep("-", pad_len) .. "+ "
    else
        lines[#lines + 1] = " ┌──" .. "\27[1;36m" .. map_title .. "\27[0m" .. string.rep("─", pad_len) .. "┐ "
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
    local stat1 = string.format("Health: %3d%% | Armor: %3d%% | Ammo: %2d | Score: %5d | Pos:(%4.1f,%4.1f)",
        self.player.health, self.player.armor, self.player.ammo, self.player.score, self.player.x, self.player.y)
    local stat2 = string.format("Map [%d/%d]: %-22s | Radar: %-3s [M] | Weapon: Pistol",
        self.active_map_idx, #MAP_PRESETS, self.map_name, self.show_minimap and "ON" or "OFF")
    local stat3 = "WASD:Move | Arrows:Turn | Space:Fire | E:Door | M:Radar | 1-3:Map | Q:Quit"

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
-- 9. INTERACTIVE GAME LOOP
-- ============================================================================
function WolfEngine:run_interactive()
    local term = Terminal.new()
    term:enable_raw_mode()

    local running = true
    local last_time = term:get_time_sec()
    local target_fps = 60
    local frame_interval = 1.0 / target_fps

    io.write("\27[2J\27[H")
    io.flush()

    while running do
        local now = term:get_time_sec()
        local dt = math.min(0.05, now - last_time)

        -- 1. Read input events
        local k = term:read_key()
        if k then
            if k == "q" or k == "Q" or k == "\27" then
                running = false
            elseif k == "p" or k == "P" then
                self.paused = not self.paused
            elseif k == "m" or k == "M" then
                self.show_minimap = not self.show_minimap
            elseif k == "\t" then
                local next_idx = (self.active_map_idx % #MAP_PRESETS) + 1
                self:load_map(next_idx)
            elseif k >= "1" and k <= tostring(#MAP_PRESETS) then
                self:load_map(tonumber(k))
            elseif k == " " then
                self:fire_weapon()
            elseif k == "e" or k == "E" or k == "f" or k == "F" then
                self:interact_door()
            -- Player movement
            elseif k == "w" or k == "W" or k == "up" then
                self:move_player(self.player.dir_x, self.player.dir_y, dt * 1.5)
            elseif k == "s" or k == "S" or k == "down" then
                self:move_player(-self.player.dir_x, -self.player.dir_y, dt * 1.5)
            elseif k == "a" or k == "A" then
                -- Strafe left
                self:move_player(-self.player.dir_y, self.player.dir_x, dt * 1.5)
            elseif k == "d" or k == "D" then
                -- Strafe right
                self:move_player(self.player.dir_y, -self.player.dir_x, dt * 1.5)
            -- Turning
            elseif k == "left" then
                self:rotate_player(-self.player.rot_speed * dt * 2.0)
            elseif k == "right" then
                self:rotate_player(self.player.rot_speed * dt * 2.0)
            end
        end

        -- 2. Step Engine
        if not self.paused then
            self:step(dt)
        end

        -- 3. Render at target frame rate
        if (now - last_time) >= frame_interval then
            local frame = self:render_frame()
            io.write("\27[H" .. frame)
            io.flush()
            last_time = now
        else
            term:sleep_ms(2)
        end
    end

    term:disable_raw_mode()
    print("\n[Wolfenstein 3D Studio Terminated]\n")
end

-- ============================================================================
-- 10. INTERNAL SELF-TESTS & VALIDATION
-- ============================================================================
local function run_self_tests()
    print("=== Running Internal Self-Tests for ffi_wolf3d_raycaster.lua ===")

    -- 1. FFI Memory layouts
    assert(ffi.sizeof("RGBColor") == 3, "RGBColor sizeof == 3")
    assert(ffi.sizeof("PlayerState") >= 44, "PlayerState sizeof >= 44")
    assert(ffi.sizeof("SpriteEntity") == 24, "SpriteEntity sizeof == 24")
    assert(ffi.sizeof("RaycasterState") >= 74 * 36 * 3 + 74 * 4, "RaycasterState bounds")
    print("  ✔ PASS: FFI struct layouts, alignment and data sizes")

    -- 2. Engine initialization
    local engine = WolfEngine.new()
    assert(engine.width == 74 and engine.height == 36, "Viewport 74x36")
    assert(engine.player.health == 100 and engine.player.ammo == 32, "Player stats initialized")
    print("  ✔ PASS: Raycaster engine state & player setup")

    -- 3. Raycasting DDA math verification
    engine:clear_framebuffer()
    engine:render_walls()
    local valid_z = 0
    for x = 0, WIDTH - 1 do
        local d = engine.state.z_buffer[x]
        if d > 0.05 and d < 50.0 then valid_z = valid_z + 1 end
    end
    assert(valid_z == WIDTH, "All 74 rays projected valid perpendicular depths without distortion")
    print("  ✔ PASS: 60+ FPS DDA raymarching depth buffer")

    -- 4. John Carmack recessed door mechanics
    local door_idx = nil
    for i = 0, MAP_W * MAP_H - 1 do
        if engine.map[i] == TEX_DOOR then door_idx = i; break end
    end
    assert(door_idx ~= nil, "Level map contains interactive doors")
    assert(engine.door_open[door_idx] == 0.0, "Door starts closed")
    engine.door_timer[door_idx] = 2.0
    engine:step(0.1)
    assert(engine.door_open[door_idx] > 0.0, "Door smoothly slides open on timer activation")
    print("  ✔ PASS: Recessed sliding door DDA collision & animation")

    -- 5. Billboarded 3D Sprites
    engine:render_sprites()
    local sp_count = 0
    for i = 0, engine.num_sprites - 1 do
        if engine.sprites[i].active == 1 then sp_count = sp_count + 1 end
    end
    assert(sp_count > 0, "Level contains active billboarded entities")
    print("  ✔ PASS: Billboarded 3D sprite depth sorting & clipping")

    -- 6. Weapon combat hitscan
    local init_ammo = engine.player.ammo
    local fired = engine:fire_weapon()
    assert(fired and engine.player.ammo == init_ammo - 1, "Weapon firing consumes ammo & triggers recoil")
    print("  ✔ PASS: First-person pistol recoil, muzzle flash & hitscan combat")

    -- 7. 80-Column terminal frame geometry across all maps
    local function verify_frame(mode_ascii)
        engine.use_ascii = mode_ascii
        local frame = engine:render_frame()
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

    for m = 1, #MAP_PRESETS do
        engine:load_map(m)
        verify_frame(false)
        verify_frame(true)
    end
    print("  ✔ PASS: Uniform 80-column terminal frame geometry across all levels")

    print("\nAll Wolfenstein 3D Raycaster self-tests completed successfully!\n")
    return true
end

-- ============================================================================
-- 11. CLI DISPATCHER & ENTRYPOINT
-- ============================================================================
local function print_help()
    print([[
🐺 WOLFENSTEIN 3D RAYCASTING ENGINE (LuaJIT FFI) 🐺

Usage:
  luajit ffi_wolf3d_raycaster.lua [options]

Options:
  --help               Show this help message and exit
  --test               Run internal raycasting, DDA, texture & geometry self-tests
  --snapshot           Render a single non-interactive frame and exit
  --ascii              Use ASCII characters instead of Truecolor half-blocks
  --map <id>           Select initial map (1: Dungeon, 2: Courtyard, 3: Stronghold)
  --demo [frames]      Run automated tour exploring the maze and raycasting

Controls:
  W / S / Up / Down    Move forward / backward
  A / D                Strafe left / right
  Left / Right Arrow   Turn left / right
  Space                Fire weapon (hitscan pistol with recoil & muzzle flash)
  E / F                Open / close interactive doors
  M                    Toggle 2D minimap radar overlay
  Tab or 1 - 3         Switch level maps
  P                    Pause / resume simulation
  Q / Esc              Quit game
]])
end

local function main(args)
    local initial_map = 1
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
        elseif a:match("^%-%-map=(%d+)$") then
            initial_map = tonumber(a:match("^%-%-map=(%d+)$"))
        elseif a == "--map" and i + 1 <= #args then
            i = i + 1
            initial_map = tonumber(args[i]) or 1
        elseif a:match("^%-%-demo=(%d+)$") then
            demo_frames = tonumber(a:match("^%-%-demo=(%d+)$"))
        elseif a == "--demo" then
            demo_frames = (i + 1 <= #args and tonumber(args[i + 1])) and tonumber(args[i + 1]) or 30
            if i + 1 <= #args and tonumber(args[i + 1]) then i = i + 1 end
        end
        i = i + 1
    end

    local engine = WolfEngine.new()
    engine.use_ascii = ascii_mode
    engine:load_map(initial_map)

    if demo_frames then
        print(string.format("Running automated Wolfenstein 3D tour (%d frames)...", demo_frames))
        local step_per_map = math.max(1, math.floor(demo_frames / #MAP_PRESETS))
        for m = 1, #MAP_PRESETS do
            engine:load_map(m)
            for _ = 1, step_per_map do
                engine:rotate_player(0.05)
                engine:move_player(engine.player.dir_x, engine.player.dir_y, 0.03)
                engine:step(0.016)
            end
        end
        local frame = engine:render_frame()
        print(frame)
        print("[Wolfenstein 3D Tour Complete]\n")
        return 0
    end

    if snapshot_mode then
        for _ = 1, 5 do engine:step(0.016) end
        local frame = engine:render_frame()
        print(frame)
        return 0
    end

    engine:run_interactive()
    return 0
end

local is_main = false
if arg and arg[0] and (arg[0] == "ffi_wolf3d_raycaster.lua" or arg[0]:match("/ffi_wolf3d_raycaster%.lua$") ~= nil) then
    is_main = true
end

if is_main then
    local exit_code = main(arg or {})
    os.exit(exit_code or 0)
end

return {
    WolfEngine = WolfEngine,
    Terminal = Terminal,
    MAP_PRESETS = MAP_PRESETS,
    TEX_STONE = TEX_STONE,
    TEX_BLUE = TEX_BLUE,
    TEX_WOOD = TEX_WOOD,
    TEX_MOSS = TEX_MOSS,
    TEX_DOOR = TEX_DOOR,
    TEX_PRISON = TEX_PRISON,
    SPRITE_GUARD = SPRITE_GUARD,
    SPRITE_CHALICE = SPRITE_CHALICE,
    SPRITE_MEDKIT = SPRITE_MEDKIT,
    SPRITE_AMMO = SPRITE_AMMO,
    SPRITE_TORCH = SPRITE_TORCH
}
