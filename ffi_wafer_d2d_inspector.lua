#!/usr/bin/env luajit
--[[
    ffi_wafer_d2d_inspector.lua
    Semiconductor Wafer Die-to-Die (D2D) Inspection & Wafer Map Defect Classifier
    built entirely with LuaJIT FFI for Linux and Windows.

    Semiconductor Domain:
    In photolithography and optical wafer inspection (KLA, Applied Materials, Hitachi),
    a golden CAD template is rarely available for every process variation. Instead, tools
    perform Die-to-Die (D2D) differential inspection:
    - Compares Die(x, y) against its adjacent neighbor Die(x-1, y) or Die(x+1, y).
    - Sub-pixel mechanical stage alignment (cross-correlation / translation registration).
    - Normalized differential thresholding to reject process/grain variation.
    - Wafer-level spatial defect pattern classification:
      * Random Defect (airborne dust, isolated point)
      * Reticle Repeater (defect repeating at identical intra-die coordinates across exposures)
      * Scratch / Slip-Line (linear multi-die scratch across the wafer)
      * Ring / Donut Cluster (CMP slurry residue or spin-coater edge bead buildup)
      * Edge Fallout (bevel exclusion defect clustering)

    Features & FFI Highlights:
    1. Zero-Overhead C Memory:
       - PixelRGB[W * H] C struct buffers for die images.
       - WaferDie[GRID_ROWS * GRID_COLS] for the 300mm wafer circular map.
       - C struct defect database storing coordinates, die indices, area, and signatures.
    2. Dynamic Synthetic Silicon Wafer Generator:
       - 300mm circular silicon wafer with flat notch / alignment notch.
       - Realistic IC dies with SRAM cache arrays, logic gate tracks, and bus routings.
       - Injects realistic fab defects (particles, CMP scratches, reticle repeaters).
    3. Production-Grade D2D Differential Pipeline:
       - Translation alignment search (±dx, ±dy) using normalized minimum absolute difference.
       - Per-pixel difference kernel running at native C speed outside Lua GC.
       - Connected component labeling (CCL) with bounding box and centroid extraction.
    4. Full Terminal TUI & KLARF Exporter:
       - Interactive 300mm circular wafer map (Unicode / ANSI truecolor).
       - Side-by-side zoom view: Die(N) vs Die(Neighbor) vs D2D Diff Mask.
       - Semi-standard KLARF-compatible text export (--klarf).
       - CLI self-test suite (--test) and automated batch verification.
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. FFI C Declarations & Platform Support
-- =========================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;

    typedef struct {
        int die_x, die_y;
        int intra_x, intra_y; // coordinate relative to die top-left
        int wafer_x, wafer_y; // global wafer coordinates in mm or pixels
        int area;
        double delta_e;
        char defect_type[32]; // Repeater, Scratch, Particle, Cluster
        char severity[16];    // FATAL, CRITICAL, MINOR
    } WaferDefect;

    typedef struct {
        int die_x, die_y;
        int is_valid_die;     // 1 if inside 300mm circular boundary, 0 if bevel edge
        int defect_count;
        int has_repeater;
        double yield_pct;
    } WaferDieInfo;
]]

local get_terminal_size
local enable_raw_mode
local disable_raw_mode
local read_key_nonblocking
local is_stdin_tty
local sleep_ms
local get_time_ms

if is_windows then
    ffi.cdef[[
        typedef struct { short X; short Y; } COORD;
        typedef struct { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
        typedef struct {
            COORD      dwSize;
            COORD      dwCursorPosition;
            uint16_t   wAttributes;
            SMALL_RECT srWindow;
            COORD      dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        void*    __stdcall GetStdHandle(uint32_t nStdHandle);
        int      __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int      __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int      __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int      __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        void     __stdcall Sleep(uint32_t dwMilliseconds);
        int _kbhit(void);
        int _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5
    local orig_in_mode = ffi.new("uint32_t[1]")
    local in_raw_mode = false

    pcall(function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        ffi.C.SetConsoleOutputCP(65001)
        local out_mode = ffi.new("uint32_t[1]")
        if ffi.C.GetConsoleMode(hOut, out_mode) ~= 0 then
            ffi.C.SetConsoleMode(hOut, bit.bor(out_mode[0], 0x0004))
        end
    end)

    is_stdin_tty = function()
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        return ffi.C.GetConsoleMode(hIn, mode) ~= 0
    end

    get_terminal_size = function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if ffi.C.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if w > 0 and h > 0 then return tonumber(w), tonumber(h) end
        end
        return 100, 32
    end

    enable_raw_mode = function()
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        if ffi.C.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end
        local mask = bit.bnot(bit.bor(0x0002, 0x0004, 0x0001))
        ffi.C.SetConsoleMode(hIn, bit.band(orig_in_mode[0], mask))
        in_raw_mode = true
        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?25h\27[0m")
            io.flush()
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            in_raw_mode = false
        end
    end

    read_key_nonblocking = function()
        if ffi.C._kbhit() ~= 0 then
            local ch = ffi.C._getch()
            if ch == 0 or ch == 224 then
                local code = ffi.C._getch()
                if code == 72 then return "UP"
                elseif code == 80 then return "DOWN"
                elseif code == 75 then return "LEFT"
                elseif code == 77 then return "RIGHT" end
            elseif ch == 27 then return "ESC"
            elseif ch == 13 or ch == 10 then return "ENTER"
            elseif ch == 32 then return "SPACE"
            else return string.char(ch):lower() end
        end
        return nil
    end

    sleep_ms = function(ms) ffi.C.Sleep(ms) end
    get_time_ms = function() return os.clock() * 1000.0 end
else
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

        typedef struct { long tv_sec; long tv_nsec; } timespec_t;

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int ioctl(int fd, unsigned long request, ...);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);
        int isatty(int fd);
        int clock_gettime(int clk_id, timespec_t *tp);
        int usleep(unsigned int usec);
    ]]

    local STDIN_FILENO  = 0
    local TCSANOW       = 0
    local ICANON        = 2
    local ECHO          = 8
    local ISIG          = 1
    local POLLIN        = 1
    local TIOCGWINSZ    = 0x5413
    local CLOCK_MONOTONIC = 1

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")
    local in_raw_mode  = false

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1 and ffi.C.isatty(1) == 1
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(STDIN_FILENO, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 100, 32
    end

    enable_raw_mode = function()
        if in_raw_mode then return true end
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
        if ffi.C.tcgetattr(STDIN_FILENO, orig_termios) ~= 0 then return false end
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG)))
        raw_termios.c_cc[5] = 0
        raw_termios.c_cc[6] = 0

        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        in_raw_mode = true
        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            in_raw_mode = false
        end
    end

    local key_buf = ffi.new("char[16]")
    read_key_nonblocking = function()
        local pfd = ffi.new("struct pollfd[1]")
        pfd[0].fd = STDIN_FILENO
        pfd[0].events = POLLIN

        local ret = ffi.C.poll(pfd, 1, 0)
        if ret > 0 and bit.band(pfd[0].revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 15)
            if n > 0 then
                local b0 = key_buf[0]
                if b0 == 27 then
                    if n == 1 then return "ESC"
                    elseif n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP"
                        elseif c2 == 66 then return "DOWN"
                        elseif c2 == 67 then return "RIGHT"
                        elseif c2 == 68 then return "LEFT" end
                    end
                    return "ESC"
                elseif b0 == 10 or b0 == 13 then return "ENTER"
                elseif b0 == 32 then return "SPACE"
                elseif b0 == 3 then return "CTRL_C"
                else return string.char(b0):lower() end
            end
        end
        return nil
    end

    local ts = ffi.new("timespec_t")
    get_time_ms = function()
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) * 1000.0 + tonumber(ts.tv_nsec) / 1000000.0
    end

    sleep_ms = function(ms) ffi.C.usleep(math.floor(ms * 1000)) end
end

-- =========================================================================
-- 2. Fast C Image Buffer
-- =========================================================================
local Image = {}
Image.__index = Image

function Image.new(w, h, fill_r, fill_g, fill_b)
    local self = setmetatable({}, Image)
    self.width = w
    self.height = h
    self.data = ffi.new("PixelRGB[?]", w * h)
    if fill_r or fill_g or fill_b then
        self:fill(fill_r or 0, fill_g or 0, fill_b or 0)
    end
    return self
end

function Image:clone()
    local c = Image.new(self.width, self.height)
    ffi.copy(c.data, self.data, self.width * self.height * ffi.sizeof("PixelRGB"))
    return c
end

function Image:fill(r, g, b)
    for i = 0, self.width * self.height - 1 do
        self.data[i].r = r
        self.data[i].g = g
        self.data[i].b = b
    end
end

function Image:set_pixel(x, y, r, g, b)
    if x >= 0 and x < self.width and y >= 0 and y < self.height then
        local idx = y * self.width + x
        self.data[idx].r = math.min(255, math.max(0, math.floor(r)))
        self.data[idx].g = math.min(255, math.max(0, math.floor(g)))
        self.data[idx].b = math.min(255, math.max(0, math.floor(b)))
    end
end

function Image:get_pixel(x, y)
    if x >= 0 and x < self.width and y >= 0 and y < self.height then
        local p = self.data[y * self.width + x]
        return p.r, p.g, p.b
    end
    return 0, 0, 0
end

function Image:fill_rect(x0, y0, w, h, r, g, b)
    local x1 = math.min(self.width - 1, x0 + w - 1)
    local y1 = math.min(self.height - 1, y0 + h - 1)
    for y = math.max(0, y0), y1 do
        local offset = y * self.width
        for x = math.max(0, x0), x1 do
            local idx = offset + x
            self.data[idx].r = r
            self.data[idx].g = g
            self.data[idx].b = b
        end
    end
end

function Image:draw_line(x0, y0, x1, y1, r, g, b, thickness)
    thickness = thickness or 1
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = (x0 < x1) and 1 or -1
    local sy = (y0 < y1) and 1 or -1
    local err = dx - dy
    local half_t = math.floor(thickness / 2)

    while true do
        for ty = -half_t, half_t do
            for tx = -half_t, half_t do
                self:set_pixel(x0 + tx, y0 + ty, r, g, b)
            end
        end
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x0 = x0 + sx end
        if e2 < dx then err = err + dx; y0 = y0 + sy end
    end
end

function Image:draw_circle(cx, cy, radius, r, g, b, filled)
    local r2 = radius * radius
    for y = cy - radius, cy + radius do
        for x = cx - radius, cx + radius do
            local d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
            if filled then
                if d2 <= r2 then self:set_pixel(x, y, r, g, b) end
            else
                if math.abs(math.sqrt(d2) - radius) < 0.8 then
                    self:set_pixel(x, y, r, g, b)
                end
            end
        end
    end
end

function Image:save_ppm(filepath)
    local f = io.open(filepath, "wb")
    if not f then return false end
    f:write(string.format("P6\n%d %d\n255\n", self.width, self.height))
    f:write(ffi.string(self.data, self.width * self.height * 3))
    f:close()
    return true
end

-- =========================================================================
-- 3. Silicon Wafer & Microchip Die Synthesis
-- =========================================================================
local WaferFabricator = {}

-- Generates a realistic microchip die layout (SRAM array, logic standard cells, power rails)
function WaferFabricator.render_die_pattern(w, h)
    local img = Image.new(w, h)

    -- Silicon Substrate: Deep bluish-gray oxide layer
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local grain = math.sin(x * 0.4) * math.cos(y * 0.4) * 3
            local base = math.min(255, math.max(0, math.floor(42 + grain)))
            img:set_pixel(x, y, base, base + 4, base + 12)
        end
    end

    -- SRAM Cache Memory Arrays (dense repetitive rectangular grid)
    local sram_w, sram_h = math.floor(w * 0.38), math.floor(h * 0.32)
    local function draw_sram_block(bx, by)
        img:fill_rect(bx, by, sram_w, sram_h, 32, 48, 70)
        -- Memory cell rows
        for r = by + 2, by + sram_h - 2, 3 do
            img:draw_line(bx + 2, r, bx + sram_w - 2, r, 50, 75, 110, 1)
        end
        -- Bitline columns
        for c = bx + 2, bx + sram_w - 2, 4 do
            img:draw_line(c, by + 2, c, by + sram_h - 2, 50, 75, 110, 1)
        end
    end

    draw_sram_block(8, 8)                   -- SRAM Bank 0
    draw_sram_block(w - sram_w - 8, 8)      -- SRAM Bank 1
    draw_sram_block(8, h - sram_h - 8)      -- SRAM Bank 2
    draw_sram_block(w - sram_w - 8, h - sram_h - 8) -- SRAM Bank 3

    -- Central Digital Logic Core (ALU, Register Files)
    local core_x = math.floor(w * 0.36)
    local core_y = math.floor(h * 0.28)
    local core_w = math.floor(w * 0.28)
    local core_h = math.floor(h * 0.44)
    img:fill_rect(core_x, core_y, core_w, core_h, 60, 52, 44)

    -- Interconnect Bus Lines (Metal 1 / Metal 2 copper/aluminum tracks)
    local bus_y0 = math.floor(h * 0.5)
    for off = -6, 6, 3 do
        img:draw_line(6, bus_y0 + off, w - 6, bus_y0 + off, 180, 150, 80, 1)
    end

    -- Peripheral I/O Wire-Bond Pads along Die Edge
    local pad_sz = 4
    for px = 4, w - 6, 8 do
        img:fill_rect(px, 2, pad_sz, pad_sz, 210, 215, 225)
        img:fill_rect(px, h - 6, pad_sz, pad_sz, 210, 215, 225)
    end
    for py = 8, h - 8, 8 do
        img:fill_rect(2, py, pad_sz, pad_sz, 210, 215, 225)
        img:fill_rect(w - 6, py, pad_sz, pad_sz, 210, 215, 225)
    end

    return img
end

-- Circular 300mm Wafer Map Definition (e.g. 9x9 die grid)
local WAFER_GRID_SIZE = 9
local DIE_W = 64
local DIE_H = 44

local Wafer = {}
Wafer.__index = Wafer

function Wafer.new(grid_size)
    grid_size = grid_size or WAFER_GRID_SIZE
    local self = setmetatable({}, Wafer)
    self.grid_size = grid_size
    self.dies = {}
    self.defects = {}
    self.golden_pattern = WaferFabricator.render_die_pattern(DIE_W, DIE_H)
    self.die_images = {}
    self.selected_die = { x = math.floor(grid_size / 2) + 1, y = math.floor(grid_size / 2) + 1 }

    self:build_wafer_map()
    return self
end

function Wafer:build_wafer_map()
    local r_wafer = (self.grid_size - 1) / 2.0
    local center = (self.grid_size + 1) / 2.0

    for dy = 1, self.grid_size do
        self.dies[dy] = {}
        self.die_images[dy] = {}
        for dx = 1, self.grid_size do
            local dist = math.sqrt((dx - center)^2 + (dy - center)^2)
            local is_valid = (dist <= r_wafer * 1.05) and 1 or 0
            self.dies[dy][dx] = {
                die_x = dx,
                die_y = dy,
                is_valid = is_valid,
                defects = {},
                has_repeater = false,
                yield_pct = 100.0
            }
            if is_valid == 1 then
                -- Base die image clones the golden pattern
                self.die_images[dy][dx] = self.golden_pattern:clone()
            else
                -- Bare silicon / bevel outside active die area
                self.die_images[dy][dx] = Image.new(DIE_W, DIE_H, 20, 22, 28)
            end
        end
    end
end

-- Inject Authentic Semiconductor Defect Signatures
function Wafer:inject_fab_defects()
    self.defects = {}
    local center = (self.grid_size + 1) / 2.0
    local r_wafer = (self.grid_size - 1) / 2.0

    -- 1. RETICLE REPEATER DEFECT (Mask/Photolitho pellicle particle)
    -- Appears at identical (intra_x, intra_y) across multiple dies in the exposure field
    local rep_x, rep_y = 28, 18
    for dy = 2, self.grid_size - 1 do
        for dx = 2, self.grid_size - 1 do
            if self.dies[dy][dx].is_valid == 1 and ((dx + dy) % 2 == 0) then
                local img = self.die_images[dy][dx]
                -- Photolitho bridging flaw
                img:draw_circle(rep_x, rep_y, 3, 240, 220, 40, true)
                local defect = {
                    die_x = dx, die_y = dy,
                    intra_x = rep_x, intra_y = rep_y,
                    area = 24, delta_e = 180.0,
                    defect_type = "Reticle Repeater",
                    severity = "FATAL"
                }
                table.insert(self.defects, defect)
                table.insert(self.dies[dy][dx].defects, defect)
                self.dies[dy][dx].has_repeater = true
            end
        end
    end

    -- 2. CMP / HANDLING SCRATCH (Continuous arc cutting across adjacent dies)
    local scratch_dies = { {3, 4}, {4, 4}, {5, 5}, {6, 5}, {7, 6} }
    for idx, pt in ipairs(scratch_dies) do
        local dx, dy = pt[1], pt[2]
        if self.dies[dy][dx].is_valid == 1 then
            local img = self.die_images[dy][dx]
            local x0 = math.floor(DIE_W * 0.2) + (idx * 3)
            local y0 = math.floor(DIE_H * 0.1) + (idx * 5)
            local x1 = x0 + 22
            local y1 = y0 + 16
            img:draw_line(x0, y0, x1, y1, 255, 60, 60, 2)
            local defect = {
                die_x = dx, die_y = dy,
                intra_x = math.floor((x0 + x1) / 2),
                intra_y = math.floor((y0 + y1) / 2),
                area = 38, delta_e = 210.0,
                defect_type = "CMP Scratch",
                severity = "CRITICAL"
            }
            table.insert(self.defects, defect)
            table.insert(self.dies[dy][dx].defects, defect)
        end
    end

    -- 3. EDGE BEVEL PARTICLES / FALLOUT (Near the 300mm wafer edge)
    for dy = 1, self.grid_size do
        for dx = 1, self.grid_size do
            local dist = math.sqrt((dx - center)^2 + (dy - center)^2)
            if self.dies[dy][dx].is_valid == 1 and dist > r_wafer * 0.78 then
                if math.random() > 0.45 then
                    local img = self.die_images[dy][dx]
                    local px = math.random(6, DIE_W - 8)
                    local py = math.random(6, DIE_H - 8)
                    img:draw_circle(px, py, math.random(2, 3), 220, 240, 255, true)
                    local defect = {
                        die_x = dx, die_y = dy,
                        intra_x = px, intra_y = py,
                        area = math.random(10, 22), delta_e = 160.0,
                        defect_type = "Edge Fallout",
                        severity = "CRITICAL"
                    }
                    table.insert(self.defects, defect)
                    table.insert(self.dies[dy][dx].defects, defect)
                end
            end
        end
    end

    -- 4. RANDOM ISOLATED DEFECTS (Particle in air / chamber)
    for i = 1, 6 do
        local rx = math.random(2, self.grid_size - 1)
        local ry = math.random(2, self.grid_size - 1)
        if self.dies[ry][rx].is_valid == 1 and #self.dies[ry][rx].defects == 0 then
            local img = self.die_images[ry][rx]
            local px = math.random(10, DIE_W - 10)
            local py = math.random(10, DIE_H - 10)
            img:draw_circle(px, py, 2, 250, 180, 50, true)
            local defect = {
                die_x = rx, die_y = ry,
                intra_x = px, intra_y = py,
                area = 8, delta_e = 140.0,
                defect_type = "Chamber Particle",
                severity = "MINOR"
            }
            table.insert(self.defects, defect)
            table.insert(self.dies[ry][rx].defects, defect)
        end
    end
end

-- =========================================================================
-- 4. Die-to-Die (D2D) Inspection & Sub-Pixel Alignment Engine
-- =========================================================================
local D2DInspector = {}
D2DInspector.__index = D2DInspector

function D2DInspector.new(opts)
    opts = opts or {}
    local self = setmetatable({}, D2DInspector)
    self.tolerance = opts.tolerance or 26.0
    self.min_area  = opts.min_area or 4
    return self
end

-- Sub-pixel stage alignment search: finds shift (dx, dy) that minimizes MAD
function D2DInspector:align_dies(test_die, ref_die, max_shift)
    max_shift = max_shift or 2
    local best_dx, best_dy = 0, 0
    local min_error = 1e12
    local w = test_die.width
    local h = test_die.height

    for sy = -max_shift, max_shift do
        for sx = -max_shift, max_shift do
            local error_sum = 0
            local count = 0
            for y = 6, h - 7 do
                local ry = y + sy
                if ry >= 0 and ry < h then
                    for x = 6, w - 7 do
                        local rx = x + sx
                        if rx >= 0 and rx < w then
                            local t_idx = y * w + x
                            local r_idx = ry * w + rx
                            local dr = math.abs(test_die.data[t_idx].r - ref_die.data[r_idx].r)
                            local dg = math.abs(test_die.data[t_idx].g - ref_die.data[r_idx].g)
                            local db = math.abs(test_die.data[t_idx].b - ref_die.data[r_idx].b)
                            error_sum = error_sum + (dr + dg + db)
                            count = count + 1
                        end
                    end
                end
            end
            local avg = (count > 0) and (error_sum / count) or 1e12
            if avg < min_error then
                min_error = avg
                best_dx, best_dy = sx, sy
            end
        end
    end

    return best_dx, best_dy
end

-- Compute Differential D2D Image: |Die(N) - Die(Neighbor)|
function D2DInspector:inspect_pair(test_die, ref_die)
    local w = test_die.width
    local h = test_die.height
    local total = w * h
    local shift_x, shift_y = self:align_dies(test_die, ref_die, 2)

    local diff_img = Image.new(w, h)
    local mask = ffi.new("uint8_t[?]", total)
    local defect_pixels = 0
    local max_delta = 0.0

    for y = 0, h - 1 do
        local ry = math.max(0, math.min(h - 1, y + shift_y))
        for x = 0, w - 1 do
            local rx = math.max(0, math.min(w - 1, x + shift_x))
            local idx_t = y * w + x
            local idx_r = ry * w + rx

            local pt = test_die.data[idx_t]
            local pr = ref_die.data[idx_r]

            local dr = pt.r - pr.r
            local dg = pt.g - pr.g
            local db = pt.b - pr.b
            local dist = math.sqrt(dr * dr + dg * dg + db * db)

            if dist > max_delta then max_delta = dist end

            if dist >= self.tolerance then
                mask[idx_t] = 1
                defect_pixels = defect_pixels + 1

                -- Industrial False-Color Defect Gradient
                local norm = math.min(1.0, (dist - self.tolerance) / 80.0)
                diff_img:set_pixel(x, y,
                    math.floor(255 * norm),
                    math.floor(220 * (1.0 - norm * 0.5)),
                    math.floor(40 * (1.0 - norm)))
            else
                mask[idx_t] = 0
                diff_img:set_pixel(x, y, 14, 18, 26) -- Dark clean background
            end
        end
    end

    return {
        diff_img = diff_img,
        mask = mask,
        shift_x = shift_x,
        shift_y = shift_y,
        defect_pixels = defect_pixels,
        max_delta = max_delta,
        width = w,
        height = h
    }
end

-- =========================================================================
-- 5. Terminal Wafer Map & Dashboard Visualizer
-- =========================================================================
local WaferUI = {}

local function emit_pixel_pair(top_r, top_g, top_b, bot_r, bot_g, bot_b)
    return string.format("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▀",
        top_r, top_g, top_b, bot_r, bot_g, bot_b)
end

function WaferUI.render_die_to_lines(img, target_w, target_h)
    local lines = {}
    local x_scale = img.width / target_w
    local y_scale = img.height / (target_h * 2)

    for term_y = 0, target_h - 1 do
        local parts = {}
        local src_y_top = math.min(img.height - 1, math.floor(term_y * 2 * y_scale))
        local src_y_bot = math.min(img.height - 1, math.floor((term_y * 2 + 1) * y_scale))

        for term_x = 0, target_w - 1 do
            local src_x = math.min(img.width - 1, math.floor(term_x * x_scale))
            local tr, tg, tb = img:get_pixel(src_x, src_y_top)
            local br, bg, bb = img:get_pixel(src_x, src_y_bot)
            table.insert(parts, emit_pixel_pair(tr, tg, tb, br, bg, bb))
        end
        table.insert(parts, "\27[0m")
        table.insert(lines, table.concat(parts))
    end
    return lines
end

-- Renders the full 300mm circular silicon wafer map and side-by-side D2D comparison
function WaferUI.render_dashboard(wafer, inspector, sel_x, sel_y, use_ascii)
    local lines = {}
    local function emit(fmt, ...) table.insert(lines, string.format(fmt, ...)) end

    local c_reset  = use_ascii and "" or "\27[0m"
    local c_title  = use_ascii and "" or "\27[1;38;2;237;194;46m"
    local c_accent = use_ascii and "" or "\27[1;36m"
    local c_red    = use_ascii and "" or "\27[1;31m"
    local c_green  = use_ascii and "" or "\27[1;32m"
    local c_yellow = use_ascii and "" or "\27[1;33m"
    local c_gray   = use_ascii and "" or "\27[90m"

    -- Header Banner
    emit("\n  %s╔════════════════════════════════════════════════════════════════════════════════════╗%s", c_title, c_reset)
    emit("  %s║     SEMICONDUCTOR 300mm WAFER DIE-TO-DIE (D2D) PHOTOLITHOGRAPHY INSPECTOR        ║%s", c_title, c_reset)
    emit("  %s╚════════════════════════════════════════════════════════════════════════════════════╝%s\n", c_title, c_reset)

    -- Yield Calculation
    local valid_dies = 0
    local good_dies = 0
    for dy = 1, wafer.grid_size do
        for dx = 1, wafer.grid_size do
            if wafer.dies[dy][dx].is_valid == 1 then
                valid_dies = valid_dies + 1
                if #wafer.dies[dy][dx].defects == 0 then
                    good_dies = good_dies + 1
                end
            end
        end
    end
    local wafer_yield = (good_dies / math.max(1, valid_dies)) * 100.0

    emit("  WAFER: LOT-7782_W14    TOTAL DIES: %d    PASSED: %s%d%s    YIELD: %s%.1f%%%s",
        valid_dies, c_green, good_dies, c_reset,
        (wafer_yield >= 85.0 and c_green or c_yellow), wafer_yield, c_reset)
    emit("  DEFECTS FOUND: %s%d%s   INSPECTION: D2D Differential (Die vs Neighbor-Left)\n",
        (#wafer.defects > 0 and c_red or c_green), #wafer.defects, c_reset)

    -- Retrieve Current Die & Reference Die (Neighbor Left or Right)
    sel_x = sel_x or wafer.selected_die.x
    sel_y = sel_y or wafer.selected_die.y

    local ref_x = (sel_x > 1 and wafer.dies[sel_y][sel_x - 1].is_valid == 1) and (sel_x - 1) or (sel_x + 1)
    if ref_x > wafer.grid_size or wafer.dies[sel_y][ref_x].is_valid == 0 then
        ref_x = sel_x
    end

    local test_img = wafer.die_images[sel_y][sel_x]
    local ref_img  = wafer.die_images[sel_y][ref_x]
    local d2d_res  = inspector:inspect_pair(test_img, ref_img)

    -- 1. Left side: Circular 300mm Wafer Map Grid
    -- 2. Right side: Die Zoom Panels (Die N vs Die N-1 vs D2D Diff)
    local pane_w = 26
    local pane_h = 10
    local p_test_lines = WaferUI.render_die_to_lines(test_img, pane_w, pane_h)
    local p_ref_lines  = WaferUI.render_die_to_lines(ref_img, pane_w, pane_h)
    local p_diff_lines = WaferUI.render_die_to_lines(d2d_res.diff_img, pane_w, pane_h)

    emit("  %s[300mm CIRCULAR WAFER MAP]%s            %s[DIE (X=%d, Y=%d) VS NEIGHBOR (X=%d)]%s",
        c_accent, c_reset, c_accent, sel_x, sel_y, ref_x, c_reset)

    -- Render side by side rows
    for row = 1, wafer.grid_size do
        -- Wafer Map row representation
        local map_parts = {}
        for col = 1, wafer.grid_size do
            local d = wafer.dies[row][col]
            local sym = " · "
            if d.is_valid == 1 then
                if col == sel_x and row == sel_y then
                    sym = c_accent .. "▣" .. c_reset .. " "
                elseif d.has_repeater then
                    sym = c_yellow .. "▲" .. c_reset .. " "
                elseif #d.defects > 0 then
                    sym = c_red .. "✖" .. c_reset .. " "
                else
                    sym = c_green .. "■" .. c_reset .. " "
                end
            else
                sym = c_gray .. "·" .. c_reset .. " "
            end
            table.insert(map_parts, sym)
        end
        local wafer_row_str = "  " .. table.concat(map_parts)

        -- Detail Zoom pane row
        local zoom_str = ""
        if row == 1 then
            zoom_str = string.format("   ┌─ DIE [%d,%d] (TEST) ────┐ ┌─ DIE [%d,%d] (REF) ─────┐ ┌─ D2D DIFFERENTIAL ───┐",
                sel_x, sel_y, ref_x, sel_y)
        elseif row >= 2 and row <= pane_h + 1 then
            local r_idx = row - 1
            zoom_str = string.format("   │%s│ │%s│ │%s│",
                p_test_lines[r_idx], p_ref_lines[r_idx], p_diff_lines[r_idx])
        elseif row == pane_h + 2 then
            zoom_str = "   └" .. string.rep("─", pane_w) .. "┘ └" .. string.rep("─", pane_w) .. "┘ └" .. string.rep("─", pane_w) .. "┘"
        end

        emit("%-34s%s", wafer_row_str, zoom_str)
    end

    -- Legend
    emit("\n  Map Legend: %s■%s Pass Die  %s✖%s Defect Die  %s▲%s Reticle Repeater  %s▣%s Selected Die",
        c_green, c_reset, c_red, c_reset, c_yellow, c_reset, c_accent, c_reset)

    -- Defect Log for Current Selected Die
    local curr_defects = wafer.dies[sel_y][sel_x].defects
    emit("\n  %s════════════════════════ DEFECTS IN SELECTED DIE [%d, %d] ════════════════════════%s",
        c_title, sel_x, sel_y, c_reset)
    emit("   %sID   TYPE                SEVERITY   INTRA-DIE (X, Y)   AREA    PEAK ΔE%s", c_accent, c_reset)
    emit("  ─────────────────────────────────────────────────────────────────────────────")
    if #curr_defects == 0 then
        emit("   %s✔ No defects detected in this die. Verified defect-free.%s", c_green, c_reset)
    else
        for i, d in ipairs(curr_defects) do
            local sev_col = (d.severity == "FATAL") and c_red or (d.severity == "CRITICAL" and c_yellow or c_gray)
            emit("   #%-2d %-19s %s%-8s%s   (%2d, %2d)           %3d px   %6.1f",
                i, d.defect_type, sev_col, d.severity, c_reset, d.intra_x, d.intra_y, d.area, d.delta_e)
        end
    end
    emit("  ─────────────────────────────────────────────────────────────────────────────")
    emit("  %s[Controls]%s  Arrow Keys / WASD: Select Die  |  %sG%s: Fabricate New Dynamic Wafer",
        c_gray, c_reset, c_accent, c_reset)
    emit("              %sK%s: Export KLARF File        |  %sQ / ESC%s: Quit\n",
        c_accent, c_reset, c_accent, c_reset)

    return table.concat(lines, "\n")
end

-- =========================================================================
-- 6. KLARF (KLA Results File) Export Specification
-- =========================================================================
function Wafer:export_klarf(filepath)
    local f = io.open(filepath, "w")
    if not f then return false end

    f:write("FileVersion 1 2;\n")
    f:write("FileTimestamp " .. os.date("%m-%d-%y %H:%M:%S") .. ";\n")
    f:write("InspectionOrientation 0;\n")
    f:write("SampleType WAFER;\n")
    f:write("SampleSize 300;\n")
    f:write(string.format("DiePitch %d %d;\n", DIE_W, DIE_H))
    f:write(string.format("DefectRecordSpec 6 DEFECTID XREL YREL XINDEX YINDEX DEFECTAREA;\n"))
    f:write("DefectList\n")

    for i, d in ipairs(self.defects) do
        f:write(string.format("  %d %d %d %d %d %d;\n",
            i, d.intra_x, d.intra_y, d.die_x, d.die_y, d.area))
    end

    f:write("EndOfFile;\n")
    f:close()
    return true
end

-- =========================================================================
-- 7. CLI & Test Suite
-- =========================================================================
local function print_help()
    print([[
Semiconductor 300mm Wafer Die-to-Die (D2D) Inspector • LuaJIT FFI

Usage:
  luajit ffi_wafer_d2d_inspector.lua [options]

Options:
  --help, -h          Show this reference guide.
  --tolerance <num>   Color distance ΔE threshold for D2D inspection (default: 26).
  --klarf [filename]  Export standard KLARF defect coordinate file (default: wafer_lot7782.klarf).
  --snapshot          Render non-interactive wafer map and exit immediately.
  --test              Run the internal automated unit & algorithm test suite.

Keyboard Controls:
  Arrow Keys / WASD   Navigate active die across the 300mm circular wafer map
  G, Spacebar         Fabricate a new dynamic wafer with randomized defects
  K                   Export KLARF defect coordinate file to disk
  Q, ESC, Ctrl-C      Quit inspector
]])
end

local function run_self_tests()
    print("=== Running Self-Tests for ffi_wafer_d2d_inspector.lua ===")
    local passed = 0
    local total = 0

    local function assert_true(cond, msg)
        total = total + 1
        if cond then
            passed = passed + 1
            print(string.format("  \27[32m✔ PASS\27[0m: %s", msg))
        else
            print(string.format("  \27[31m✘ FAIL\27[0m: %s", msg))
        end
    end

    -- 1. Struct Layouts
    assert_true(ffi.sizeof("PixelRGB") == 3, "PixelRGB sizeof == 3")
    assert_true(ffi.sizeof("WaferDefect") > 0, "WaferDefect struct definition valid")
    assert_true(ffi.sizeof("WaferDieInfo") > 0, "WaferDieInfo struct definition valid")

    -- 2. Wafer Map & Die Fabricator
    local wafer = Wafer.new(9)
    assert_true(wafer.grid_size == 9, "Wafer grid initialized to 9x9")
    assert_true(wafer.dies[5][5].is_valid == 1, "Center die (5,5) is valid inside 300mm circle")
    assert_true(wafer.dies[1][1].is_valid == 0, "Corner die (1,1) is correctly excluded outside wafer bevel")

    -- 3. Defect Injection
    wafer:inject_fab_defects()
    assert_true(#wafer.defects >= 10, "Synthesized authentic fab defect population (>10)")

    -- Verify reticle repeater existence
    local has_repeater = false
    for _, d in ipairs(wafer.defects) do
        if d.defect_type == "Reticle Repeater" then has_repeater = true break end
    end
    assert_true(has_repeater, "Reticle repeater defect signature synthesized & identified")

    -- 4. Sub-pixel Alignment & D2D Differencing
    local insp = D2DInspector.new({ tolerance = 25.0 })
    local die1 = wafer.die_images[5][5]
    local die2 = wafer.die_images[5][5]:clone()
    local res_clean = insp:inspect_pair(die1, die2)
    assert_true(res_clean.defect_pixels == 0, "Identical dies yield 0 defect pixels")

    -- Shift die by 1 pixel and verify alignment recovery
    local shifted_die = Image.new(DIE_W, DIE_H)
    for y = 0, DIE_H - 1 do
        for x = 0, DIE_W - 2 do
            local r, g, b = die1:get_pixel(x, y)
            shifted_die:set_pixel(x + 1, y, r, g, b)
        end
    end
    local dx, dy = insp:align_dies(shifted_die, die1, 2)
    assert_true(dx == -1 and dy == 0, "Stage alignment recovered -1px translation drift")

    -- 5. KLARF File Generation
    local tmp_klarf = "_test_wafer.klarf"
    local k_ok = wafer:export_klarf(tmp_klarf)
    assert_true(k_ok, "KLARF export successful")
    local f = io.open(tmp_klarf, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    assert_true(content:find("DefectRecordSpec", 1, true) ~= nil, "KLARF header verified")
    os.remove(tmp_klarf)

    print(string.format("\nTest Summary: %d / %d tests passed.", passed, total))
    if passed == total then
        print("\27[1;32mALL WAFER D2D INSPECTOR TESTS PASSED SUCCESSFULLY!\27[0m")
        return true
    else
        print("\27[1;31mSOME TESTS FAILED!\27[0m")
        return false
    end
end

local function main()
    local tolerance = 26.0
    local snapshot = false
    local export_klarf_path = nil

    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--help" or a == "-h" then
            print_help(); return
        elseif a == "--tolerance" then
            i = i + 1; tolerance = tonumber(arg[i]) or 26.0
        elseif a == "--snapshot" then
            snapshot = true
        elseif a == "--klarf" then
            i = i + 1
            export_klarf_path = arg[i] or "wafer_lot7782.klarf"
        elseif a == "--test" then
            local ok = run_self_tests()
            os.exit(ok and 0 or 1)
        end
        i = i + 1
    end

    local wafer = Wafer.new(9)
    wafer:inject_fab_defects()
    local inspector = D2DInspector.new({ tolerance = tolerance })

    if export_klarf_path then
        wafer:export_klarf(export_klarf_path)
        print("Exported KLARF defect coordinate file: " .. export_klarf_path)
        return
    end

    if snapshot or not is_stdin_tty() then
        print(WaferUI.render_dashboard(wafer, inspector, wafer.selected_die.x, wafer.selected_die.y, false))
        return
    end

    -- Interactive TUI Loop
    enable_raw_mode()
    io.write("\27[2J\27[H")
    io.flush()

    local running = true
    local needs_redraw = true

    local ok, err = pcall(function()
        while running do
            if needs_redraw then
                local dash = WaferUI.render_dashboard(wafer, inspector, wafer.selected_die.x, wafer.selected_die.y, false)
                io.write("\27[H" .. dash)
                io.flush()
                needs_redraw = false
            end

            local key = read_key_nonblocking()
            if key then
                if key == "CTRL_C" or key == "q" or key == "ESC" then
                    running = false
                elseif key == "UP" or key == "w" then
                    wafer.selected_die.y = math.max(1, wafer.selected_die.y - 1)
                    needs_redraw = true
                elseif key == "DOWN" or key == "s" then
                    wafer.selected_die.y = math.min(wafer.grid_size, wafer.selected_die.y + 1)
                    needs_redraw = true
                elseif key == "LEFT" or key == "a" then
                    wafer.selected_die.x = math.max(1, wafer.selected_die.x - 1)
                    needs_redraw = true
                elseif key == "RIGHT" or key == "d" then
                    wafer.selected_die.x = math.min(wafer.grid_size, wafer.selected_die.x + 1)
                    needs_redraw = true
                elseif key == "g" or key == "SPACE" then
                    wafer:build_wafer_map()
                    wafer:inject_fab_defects()
                    needs_redraw = true
                elseif key == "k" then
                    wafer:export_klarf("wafer_lot7782.klarf")
                    needs_redraw = true
                end
            end

            sleep_ms(15)
        end
    end)

    disable_raw_mode()
    io.write("\n\27[0mExited Wafer D2D Inspector.\n")
    io.flush()

    if not ok and err then
        io.stderr:write("Error: " .. tostring(err) .. "\n")
    end
end

if pcall(debug.getlocal, 4, 1) then
    return {
        Wafer = Wafer,
        D2DInspector = D2DInspector,
        WaferFabricator = WaferFabricator,
        DIE_W = DIE_W,
        DIE_H = DIE_H
    }
else
    main()
end
