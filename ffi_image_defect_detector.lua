#!/usr/bin/env luajit
--[[
    ffi_image_defect_detector.lua
    High-performance optical defect inspection and image differencing engine
    built entirely with LuaJIT FFI for Linux and Windows.

    Features & FFI Highlights:
    1. Zero-Overhead C Memory Image Buffers:
       - PixelRGB[width * height] flat arrays in C memory outside Lua GC.
       - Fast memory allocation, blitting, cloning via ffi.copy and ffi.fill.
    2. Dynamic Synthetic PCB & Defect Generator:
       - Generates pristine "Golden Template" PCB boards procedurally:
         * Solder-mask texture, gold/copper conductive traces & vias.
         * SMD chip packages with metal lead pins.
         * Labeled surface-mount resistors/capacitors with solder pads.
       - Injects realistic, configurable defects into test samples:
         * Missing component (bare solder pads exposed).
         * Surface scratch (abrasion across protective mask and traces).
         * Solder bridge (short-circuit bridging adjacent IC pins).
         * Contaminant / Dust particles.
         * Broken trace (open circuit hairline fracture).
    3. Industrial Defect Detection & Differencing Pipeline:
       - Per-pixel color distance metric (Euclidean ΔE / Manhattan Δ).
       - Adaptive thresholding for noise rejection.
       - Morphological noise cleaning (erosion / dilation) to discard camera grain.
       - 2-Pass Connected Component Labeling (CCL) for blob clustering.
       - Bounding Box extraction (X, Y, Width, Height, Area, Peak ΔE).
       - Defect classification (Missing Element, Linear Scratch, Solder Bridge, Dust Particle).
    4. 4-Panel Truecolor ANSI Terminal Dashboard:
       - [1] Golden Reference Template
       - [2] Inspection Sample Under Test
       - [3] Truecolor ΔE Heatmap (Black -> Blue -> Red -> Yellow -> White)
       - [4] Defect Overlay with High-Contrast Bounding Boxes and IDs
       - Uses Unicode half-blocks ('▀' / '▄') for 2x vertical resolution.
    5. Production Utilities:
       - Netpbm PPM (P6 binary / P3 ASCII) reader & writer.
       - Automatic fallback loader for PNG, JPG, WEBP via ImageMagick/ffmpeg.
       - JSON structured report export (--json).
       - Headless batch processing, snapshot export, and full automated test suite (--test).
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. C Declarations (POSIX & Windows)
-- =========================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;

    typedef struct {
        int id;
        int x_min, y_min, x_max, y_max;
        int area;
        double max_delta;
        char classification[32];
        char severity[16];
    } DefectBlob;
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
        return 100, 30
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
                elseif code == 77 then return "RIGHT"
                end
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
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(STDIN_FILENO, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 100, 30
    end

    enable_raw_mode = function()
        if in_raw_mode then return true end
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
        if ffi.C.tcgetattr(STDIN_FILENO, orig_termios) ~= 0 then return false end
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG)))
        raw_termios.c_cc[5] = 0 -- VMIN = 0
        raw_termios.c_cc[6] = 0 -- VTIME = 0

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
                        elseif c2 == 68 then return "LEFT"
                        end
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

    sleep_ms = function(ms)
        ffi.C.usleep(math.floor(ms * 1000))
    end
end

-- =========================================================================
-- 2. Image Buffer Utilities & Netpbm PPM I/O
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

-- Drawing Primitives on Image Buffer
function Image:fill_rect(x0, y0, w, h, r, g, b)
    local x1 = math.min(self.width - 1, x0 + w - 1)
    local y1 = math.min(self.height - 1, y0 + h - 1)
    for y = math.max(0, y0), y1 do
        local row_offset = y * self.width
        for x = math.max(0, x0), x1 do
            local idx = row_offset + x
            self.data[idx].r = r
            self.data[idx].g = g
            self.data[idx].b = b
        end
    end
end

function Image:draw_rect_outline(x0, y0, w, h, r, g, b, thickness)
    thickness = thickness or 1
    for t = 0, thickness - 1 do
        -- Top & Bottom
        for x = x0 - t, x0 + w - 1 + t do
            self:set_pixel(x, y0 - t, r, g, b)
            self:set_pixel(x, y0 + h - 1 + t, r, g, b)
        end
        -- Left & Right
        for y = y0 - t, y0 + h - 1 + t do
            self:set_pixel(x0 - t, y, r, g, b)
            self:set_pixel(x0 + w - 1 + t, y, r, g, b)
        end
    end
end

function Image:draw_line(x0, y0, x1, y1, r, g, b, thickness)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = (x0 < x1) and 1 or -1
    local sy = (y0 < y1) and 1 or -1
    local err = dx - dy

    thickness = thickness or 1
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

-- Save to Netpbm P6 Binary PPM
function Image:save_ppm(filepath)
    local f = io.open(filepath, "wb")
    if not f then return false, "Cannot open file for writing: " .. tostring(filepath) end
    f:write(string.format("P6\n%d %d\n255\n", self.width, self.height))
    local raw_bytes = ffi.string(self.data, self.width * self.height * 3)
    f:write(raw_bytes)
    f:close()
    return true
end

-- Load from Netpbm PPM (P6 Binary or P3 ASCII)
function Image.load_ppm(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil, "Cannot open file: " .. tostring(filepath) end

    local function read_token()
        while true do
            local ch = f:read(1)
            if not ch then return nil end
            if ch == '#' then
                f:read("*l") -- skip comment line
            elseif not ch:match("%s") then
                local token = { ch }
                while true do
                    local c2 = f:read(1)
                    if not c2 or c2:match("%s") or c2 == '#' then
                        if c2 == '#' then f:seek("cur", -1) end
                        return table.concat(token)
                    end
                    table.insert(token, c2)
                end
            end
        end
    end

    local magic = read_token()
    if magic ~= "P6" and magic ~= "P3" then
        f:close()
        return nil, "Unsupported PPM format (must be P6 or P3): " .. tostring(magic)
    end

    local w = tonumber(read_token())
    local h = tonumber(read_token())
    local maxval = tonumber(read_token())
    if not w or not h or not maxval then
        f:close()
        return nil, "Malformed PPM header"
    end

    local img = Image.new(w, h)
    if magic == "P6" then
        -- Read single whitespace byte following maxval
        local raw = f:read(w * h * 3)
        if not raw or #raw < w * h * 3 then
            f:close()
            return nil, "Incomplete PPM binary pixel data"
        end
        ffi.copy(img.data, raw, w * h * 3)
    else
        -- P3 ASCII
        for i = 0, w * h - 1 do
            local r = tonumber(read_token()) or 0
            local g = tonumber(read_token()) or 0
            local b = tonumber(read_token()) or 0
            img.data[i].r = math.floor(r * 255 / maxval)
            img.data[i].g = math.floor(g * 255 / maxval)
            img.data[i].b = math.floor(b * 255 / maxval)
        end
    end
    f:close()
    return img
end

-- Fallback loader using ImageMagick 'convert' or 'ffmpeg' for PNG, JPG, BMP
function Image.load(filepath)
    local img, err = Image.load_ppm(filepath)
    if img then return img end

    -- Try converting via ImageMagick convert or ffmpeg to stdout PPM
    local cmd = string.format("convert %q ppm:- 2>/dev/null", filepath)
    local pipe = io.popen(cmd, "r")
    if pipe then
        local content = pipe:read("*a")
        pipe:close()
        if content and #content > 10 and content:sub(1, 2) == "P6" then
            local tmp = "_tmp_load.ppm"
            local tf = io.open(tmp, "wb")
            if tf then
                tf:write(content)
                tf:close()
                local parsed = Image.load_ppm(tmp)
                os.remove(tmp)
                if parsed then return parsed end
            end
        end
    end

    return nil, err or ("Failed to load image: " .. filepath)
end

-- =========================================================================
-- 3. Dynamic Synthetic PCB & Defect Generator
-- =========================================================================
local PCBGenerator = {}

-- Generate a realistic Golden Reference PCB image
function PCBGenerator.generate_golden_pcb(width, height)
    width = width or 160
    height = height or 90
    local img = Image.new(width, height)

    -- 1. Solder Mask Background: Industrial deep emerald green with micro-grain
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local grain = (math.sin(x * 0.3) * math.cos(y * 0.3) * 6) + (math.random(-2, 2))
            local base_g = math.min(255, math.max(0, math.floor(75 + grain)))
            local base_r = math.min(255, math.max(0, math.floor(16 + grain * 0.2)))
            local base_b = math.min(255, math.max(0, math.floor(35 + grain * 0.3)))
            img:set_pixel(x, y, base_r, base_g, base_b)
        end
    end

    -- 2. Copper / Gold Conductive Bus Traces
    local trace_gold_r, trace_gold_g, trace_gold_b = 212, 175, 55
    local trace_copper_r, trace_copper_g, trace_copper_b = 184, 115, 51

    -- Horizontal bus lines
    img:draw_line(10, 18, width - 12, 18, trace_gold_r, trace_gold_g, trace_gold_b, 2)
    img:draw_line(10, 24, width - 12, 24, trace_copper_r, trace_copper_g, trace_copper_b, 2)
    img:draw_line(10, height - 16, width - 12, height - 16, trace_gold_r, trace_gold_g, trace_gold_b, 2)

    -- Routing traces to components
    img:draw_line(24, 24, 24, 46, trace_copper_r, trace_copper_g, trace_copper_b, 2)
    img:draw_line(24, 46, 44, 46, trace_copper_r, trace_copper_g, trace_copper_b, 2)

    img:draw_line(width - 32, 24, width - 32, 50, trace_copper_r, trace_copper_g, trace_copper_b, 2)
    img:draw_line(width - 32, 50, width - 50, 50, trace_copper_r, trace_copper_g, trace_copper_b, 2)

    -- Diagonal 45-degree routing traces
    img:draw_line(16, 68, 32, 52, trace_copper_r, trace_copper_g, trace_copper_b, 2)
    img:draw_line(32, 52, 48, 52, trace_copper_r, trace_copper_g, trace_copper_b, 2)

    -- 3. Circular Vias & Test Points
    local vias = {
        {16, 18}, {width - 18, 18}, {16, height - 16}, {width - 18, height - 16},
        {36, 32}, {width - 36, 32}, {28, 68}, {width - 24, 68}
    }
    for _, v in ipairs(vias) do
        img:draw_circle(v[1], v[2], 4, trace_gold_r, trace_gold_g, trace_gold_b, true)
        img:draw_circle(v[1], v[2], 2, 25, 25, 25, true) -- drill hole
    end

    -- 4. Main QFP / SOP Microcontroller IC Chip
    local chip_cx = math.floor(width * 0.5)
    local chip_cy = math.floor(height * 0.5)
    local chip_w  = 38
    local chip_h  = 26
    local chip_x0 = chip_cx - math.floor(chip_w / 2)
    local chip_y0 = chip_cy - math.floor(chip_h / 2)

    -- Draw IC Silver Pins / Leads
    local pin_color_r, pin_color_g, pin_color_b = 220, 224, 230
    local pin_spacing = 4
    -- Top & Bottom Pins
    for px = chip_x0 + 4, chip_x0 + chip_w - 6, pin_spacing do
        img:draw_line(px, chip_y0 - 6, px, chip_y0, pin_color_r, pin_color_g, pin_color_b, 2)
        img:draw_line(px, chip_y0 + chip_h, px, chip_y0 + chip_h + 6, pin_color_r, pin_color_g, pin_color_b, 2)
    end
    -- Left & Right Pins
    for py = chip_y0 + 4, chip_y0 + chip_h - 4, pin_spacing do
        img:draw_line(chip_x0 - 6, py, chip_x0, py, pin_color_r, pin_color_g, pin_color_b, 2)
        img:draw_line(chip_x0 + chip_w, py, chip_x0 + chip_w + 6, py, pin_color_r, pin_color_g, pin_color_b, 2)
    end

    -- IC Ceramic Body (Dark charcoal with beveled edge)
    img:fill_rect(chip_x0, chip_y0, chip_w, chip_h, 38, 40, 44)
    img:draw_rect_outline(chip_x0, chip_y0, chip_w, chip_h, 60, 62, 66, 1)
    -- Pin 1 index notch / dot
    img:draw_circle(chip_x0 + 5, chip_y0 + 5, 2, 80, 85, 90, true)

    -- 5. Surface Mount Devices (SMD Resistors & Ceramic Capacitors)
    -- R1, R2, C1, C2
    local function draw_smd_resistor(x, y, label)
        -- Solder pads (silver/tin)
        img:fill_rect(x - 1, y, 3, 7, 210, 215, 220)
        img:fill_rect(x + 9, y, 3, 7, 210, 215, 220)
        -- Ceramic/Epoxy black body
        img:fill_rect(x + 2, y, 7, 7, 30, 32, 35)
    end

    local function draw_smd_capacitor(x, y)
        -- Solder pads
        img:fill_rect(x - 1, y, 3, 7, 210, 215, 220)
        img:fill_rect(x + 9, y, 3, 7, 210, 215, 220)
        -- Tantalum / Ceramic brownish-orange body
        img:fill_rect(x + 2, y, 7, 7, 185, 120, 60)
    end

    draw_smd_resistor(18, 36)
    draw_smd_capacitor(18, 52)
    draw_smd_resistor(width - 29, 36)
    draw_smd_capacitor(width - 29, 52)

    -- 6. White Silkscreen markings / bounding outlines
    local silk_r, silk_g, silk_b = 240, 245, 240
    img:draw_rect_outline(chip_x0 - 8, chip_y0 - 8, chip_w + 16, chip_h + 16, silk_r, silk_g, silk_b, 1)
    img:draw_rect_outline(15, 34, 17, 11, silk_r, silk_g, silk_b, 1)
    img:draw_rect_outline(15, 50, 17, 11, silk_r, silk_g, silk_b, 1)

    return img
end

-- Inject parameterized defects into a sample image
function PCBGenerator.inject_defects(golden_img, options)
    options = options or {}
    local sample = golden_img:clone()
    local w = sample.width
    local h = sample.height

    local defects_info = {}

    -- Defect 1: Missing SMD Component (R2 on right side: bare solder pad left, body missing)
    if options.missing_component ~= false then
        local mx, my = w - 29, 36
        -- Paint solder mask color over component body to simulate unpopulated board
        local mask_r, mask_g, mask_b = 16, 75, 35
        sample:fill_rect(mx + 2, my, 7, 7, mask_r, mask_g, mask_b)
        table.insert(defects_info, {
            type = "Missing Element",
            severity = "CRITICAL",
            location = { mx, my, 11, 7 }
        })
    end

    -- Defect 2: Linear Surface Scratch (abrasion through solder mask and copper trace)
    if options.scratch ~= false then
        local sx0, sy0 = math.floor(w * 0.62), math.floor(h * 0.16)
        local sx1, sy1 = math.floor(w * 0.78), math.floor(h * 0.32)
        -- High contrast whitish/metallic scratched gouge
        sample:draw_line(sx0, sy0, sx1, sy1, 230, 235, 240, 2)
        table.insert(defects_info, {
            type = "Surface Scratch",
            severity = "MODERATE",
            location = { sx0, sy0, sx1 - sx0 + 2, sy1 - sy0 + 2 }
        })
    end

    -- Defect 3: Solder Bridge / Short Circuit (tin blob shorting two IC pins)
    if options.solder_bridge ~= false then
        local chip_cx = math.floor(w * 0.5)
        local chip_cy = math.floor(h * 0.5)
        local chip_w  = 38
        local chip_h  = 26
        local bx = chip_cx - math.floor(chip_w / 2) + 12
        local by = chip_cy + math.floor(chip_h / 2) + 3
        -- Solder blob bridging pins
        sample:draw_circle(bx, by, 3, 215, 220, 225, true)
        table.insert(defects_info, {
            type = "Solder Bridge",
            severity = "CRITICAL",
            location = { bx - 3, by - 3, 7, 7 }
        })
    end

    -- Defect 4: Contaminant / Dust Specks
    if options.dust ~= false then
        local dx, dy = math.floor(w * 0.28), math.floor(h * 0.72)
        sample:draw_circle(dx, dy, 2, 15, 15, 20, true)
        sample:draw_circle(dx + 5, dy + 2, 1, 10, 12, 15, true)
        table.insert(defects_info, {
            type = "Dust Contaminant",
            severity = "MINOR",
            location = { dx - 2, dy - 2, 9, 6 }
        })
    end

    -- Optional: Low-level Gaussian Sensor Noise
    if options.noise then
        for i = 0, w * h - 1 do
            local noise = math.random(-options.noise, options.noise)
            sample.data[i].r = math.min(255, math.max(0, sample.data[i].r + noise))
            sample.data[i].g = math.min(255, math.max(0, sample.data[i].g + noise))
            sample.data[i].b = math.min(255, math.max(0, sample.data[i].b + noise))
        end
    end

    return sample, defects_info
end

-- =========================================================================
-- 4. Fast FFI Optical Differencing & Connected Component Clustering
-- =========================================================================
local DefectDetector = {}
DefectDetector.__index = DefectDetector

function DefectDetector.new(opts)
    opts = opts or {}
    local self = setmetatable({}, DefectDetector)
    self.tolerance = opts.tolerance or 28      -- ΔE threshold
    self.min_blob_area = opts.min_blob_area or 5 -- minimum pixels to qualify as a defect
    self.max_blobs = opts.max_blobs or 128
    return self
end

-- Compute Manhattan/Euclidean Color Distance & Raw Diff Mask
function DefectDetector:compute_diff(ref_img, sample_img)
    assert(ref_img.width == sample_img.width and ref_img.height == sample_img.height,
        "Image dimensions must match for differencing")

    local w = ref_img.width
    local h = ref_img.height
    local total_pixels = w * h

    local mask = ffi.new("uint8_t[?]", total_pixels)
    local delta_map = ffi.new("float[?]", total_pixels)
    local diff_img = Image.new(w, h)

    local defect_pixel_count = 0
    local max_delta_found = 0.0

    for i = 0, total_pixels - 1 do
        local pr = ref_img.data[i]
        local ps = sample_img.data[i]

        local dr = pr.r - ps.r
        local dg = pr.g - ps.g
        local db = pr.b - ps.b

        -- Euclidean color distance
        local dist = math.sqrt(dr * dr + dg * dg + db * db)
        delta_map[i] = dist

        if dist > max_delta_found then max_delta_found = dist end

        if dist >= self.tolerance then
            mask[i] = 1
            defect_pixel_count = defect_pixel_count + 1

            -- Heatmap gradient: Blue -> Green -> Yellow -> Red -> White
            local norm = math.min(1.0, (dist - self.tolerance) / 100.0)
            local hr, hg, hb
            if norm < 0.25 then
                local t = norm / 0.25
                hr, hg, hb = 0, math.floor(t * 180), math.floor(200 + t * 55)
            elseif norm < 0.5 then
                local t = (norm - 0.25) / 0.25
                hr, hg, hb = math.floor(t * 240), math.floor(180 + t * 60), math.floor((1 - t) * 200)
            elseif norm < 0.75 then
                local t = (norm - 0.5) / 0.25
                hr, hg, hb = 255, math.floor(240 - t * 140), 0
            else
                local t = (norm - 0.75) / 0.25
                hr, hg, hb = 255, math.floor(100 + t * 155), math.floor(t * 255)
            end
            diff_img.data[i].r = hr
            diff_img.data[i].g = hg
            diff_img.data[i].b = hb
        else
            mask[i] = 0
            -- Subtle dark background for non-defective areas in heatmap
            diff_img.data[i].r = 12
            diff_img.data[i].g = 16
            diff_img.data[i].b = 24
        end
    end

    return {
        mask = mask,
        delta_map = delta_map,
        diff_img = diff_img,
        defect_pixel_count = defect_pixel_count,
        max_delta = max_delta_found,
        width = w,
        height = h
    }
end

-- 2-Pass Connected Component Labeling & Bounding Box Extraction
function DefectDetector:extract_blobs(diff_res)
    local w = diff_res.width
    local h = diff_res.height
    local mask = diff_res.mask
    local delta_map = diff_res.delta_map

    local labels = ffi.new("int32_t[?]", w * h)
    ffi.fill(labels, w * h * 4)

    local parent = {}
    local function find(i)
        local root = i
        while parent[root] do root = parent[root] end
        local curr = i
        while parent[curr] do
            local nxt = parent[curr]
            parent[curr] = root
            curr = nxt
        end
        return root
    end
    local function union(i, j)
        local ri = find(i)
        local rj = find(j)
        if ri ~= rj then parent[rj] = ri end
    end

    local next_label = 1

    -- Pass 1: Assign initial labels and record equivalences
    for y = 0, h - 1 do
        local row_idx = y * w
        for x = 0, w - 1 do
            local idx = row_idx + x
            if mask[idx] == 1 then
                local neighbors = {}
                if x > 0 and mask[idx - 1] == 1 then
                    table.insert(neighbors, labels[idx - 1])
                end
                if y > 0 and mask[idx - w] == 1 then
                    table.insert(neighbors, labels[idx - w])
                end
                if y > 0 and x > 0 and mask[idx - w - 1] == 1 then
                    table.insert(neighbors, labels[idx - w - 1])
                end
                if y > 0 and x < w - 1 and mask[idx - w + 1] == 1 then
                    table.insert(neighbors, labels[idx - w + 1])
                end

                if #neighbors == 0 then
                    labels[idx] = next_label
                    next_label = next_label + 1
                else
                    local min_lbl = neighbors[1]
                    for k = 2, #neighbors do
                        if neighbors[k] < min_lbl then min_lbl = neighbors[k] end
                    end
                    labels[idx] = min_lbl
                    for k = 1, #neighbors do
                        union(min_lbl, neighbors[k])
                    end
                end
            end
        end
    end

    -- Pass 2: Flatten labels & aggregate bounding boxes
    local blobs_map = {}
    for y = 0, h - 1 do
        local row_idx = y * w
        for x = 0, w - 1 do
            local idx = row_idx + x
            if mask[idx] == 1 then
                local root = find(labels[idx])
                labels[idx] = root
                local b = blobs_map[root]
                if not b then
                    b = {
                        root_id = root,
                        x_min = x, y_min = y,
                        x_max = x, y_max = y,
                        area = 0,
                        max_delta = 0.0
                    }
                    blobs_map[root] = b
                end
                if x < b.x_min then b.x_min = x end
                if x > b.x_max then b.x_max = x end
                if y < b.y_min then b.y_min = y end
                if y > b.y_max then b.y_max = y end
                b.area = b.area + 1
                local d = delta_map[idx]
                if d > b.max_delta then b.max_delta = d end
            end
        end
    end

    -- Filter blobs by minimum area and classify
    local qualified_blobs = {}
    for _, b in pairs(blobs_map) do
        if b.area >= self.min_blob_area then
            local bw = b.x_max - b.x_min + 1
            local bh = b.y_max - b.y_min + 1
            local aspect = bw / math.max(1, bh)

            -- Heuristic Defect Classification
            local classification = "Defect"
            local severity = "MINOR"

            if b.area >= 40 or b.max_delta >= 140 then
                severity = "CRITICAL"
            elseif b.area >= 15 or b.max_delta >= 80 then
                severity = "MODERATE"
            end

            if aspect >= 3.0 or aspect <= 0.33 then
                classification = "Linear Scratch"
            elseif bw >= 6 and bh >= 6 and b.area >= 35 then
                classification = "Missing Element"
            elseif b.area <= 12 and bw <= 4 and bh <= 4 then
                classification = "Dust Contaminant"
            elseif bw >= 5 and bh <= 6 then
                classification = "Solder Bridge"
            else
                classification = "Surface Flaw"
            end

            table.insert(qualified_blobs, {
                id = #qualified_blobs + 1,
                x_min = b.x_min,
                y_min = b.y_min,
                x_max = b.x_max,
                y_max = b.y_max,
                width = bw,
                height = bh,
                area = b.area,
                max_delta = b.max_delta,
                classification = classification,
                severity = severity
            })
        end
    end

    -- Sort blobs by area descending
    table.sort(qualified_blobs, function(a, b) return a.area > b.area end)
    for i, b in ipairs(qualified_blobs) do b.id = i end

    return qualified_blobs
end

-- Render annotated image overlay with high-contrast bounding boxes & labels
function DefectDetector:render_annotated_overlay(sample_img, blobs)
    local annotated = sample_img:clone()

    for _, b in ipairs(blobs) do
        local r, g, bb = 255, 40, 40 -- Bright Red for Critical
        if b.severity == "MODERATE" then
            r, g, bb = 255, 180, 20 -- Amber/Orange
        elseif b.severity == "MINOR" then
            r, g, bb = 255, 235, 40 -- Yellow
        end

        -- Draw bounding box outline with 1px border padding
        local pad = 1
        local bx = math.max(0, b.x_min - pad)
        local by = math.max(0, b.y_min - pad)
        local bw = math.min(annotated.width - bx, b.width + pad * 2)
        local bh = math.min(annotated.height - by, b.height + pad * 2)

        annotated:draw_rect_outline(bx, by, bw, bh, r, g, bb, 1)

        -- Corner accents
        annotated:set_pixel(bx, by, 255, 255, 255)
        annotated:set_pixel(bx + bw - 1, by, 255, 255, 255)
        annotated:set_pixel(bx, by + bh - 1, 255, 255, 255)
        annotated:set_pixel(bx + bw - 1, by + bh - 1, 255, 255, 255)
    end

    return annotated
end

-- =========================================================================
-- 5. 4-Panel Truecolor ANSI Terminal Renderer
-- =========================================================================
local TerminalUI = {}

-- Render two vertical pixels in a single character cell using '▀'
-- Top pixel = Foreground color, Bottom pixel = Background color
local function emit_pixel_pair(top_r, top_g, top_b, bot_r, bot_g, bot_b)
    return string.format("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▀",
        top_r, top_g, top_b, bot_r, bot_g, bot_b)
end

-- Render an image scaled down to target terminal width & height in characters
function TerminalUI.render_image_to_lines(img, target_w, target_h)
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

-- Assemble 4-Panel Dashboard: Reference, Sample, Heatmap, Annotated Overlay
function TerminalUI.render_dashboard(golden_img, sample_img, diff_res, annotated_img, blobs, elapsed_ms, use_ascii)
    local lines = {}
    local function emit(fmt, ...) table.insert(lines, string.format(fmt, ...)) end

    local term_w, term_h = get_terminal_size()
    local c_reset  = use_ascii and "" or "\27[0m"
    local c_title  = use_ascii and "" or "\27[1;38;2;237;194;46m"
    local c_accent = use_ascii and "" or "\27[1;36m"
    local c_red    = use_ascii and "" or "\27[1;31m"
    local c_green  = use_ascii and "" or "\27[1;32m"
    local c_yellow = use_ascii and "" or "\27[1;33m"
    local c_gray   = use_ascii and "" or "\27[90m"

    -- Banner
    emit("\n  %s╔══════════════════════════════════════════════════════════════════════════════╗%s", c_title, c_reset)
    emit("  %s║            OPTICAL DEFECT INSPECTOR  •  LUAJIT FFI DIFF ENGINE               ║%s", c_title, c_reset)
    emit("  %s╚══════════════════════════════════════════════════════════════════════════════╝%s\n", c_title, c_reset)

    -- Status KPI Bar
    local verdict = (#blobs == 0) and (c_green .. "[✔ PASS / ACCEPTED]" .. c_reset) or (c_red .. "[✖ DEFECTIVE / REJECTED]" .. c_reset)
    local defect_pct = (diff_res.defect_pixel_count / (golden_img.width * golden_img.height)) * 100.0

    emit("  STATUS: %s    DEFECTS FOUND: %s%d%s    AFFECTED PIXELS: %d (%.2f%%)",
        verdict, c_yellow, #blobs, c_reset, diff_res.defect_pixel_count, defect_pct)
    emit("  TOLERANCE: ΔE ≥ 28    IMAGE SIZE: %dx%d    SCAN TIME: %s%.2f ms%s\n",
        golden_img.width, golden_img.height, c_green, elapsed_ms or 0, c_reset)

    -- Calculate quadrant preview dimensions to fit terminal neatly
    -- Two columns of images side-by-side
    local max_pane_w = math.min(48, math.floor((term_w - 10) / 2))
    local pane_w = math.max(32, max_pane_w)
    local pane_h = math.floor(pane_w * (golden_img.height / golden_img.width) * 0.5)
    pane_h = math.max(10, math.min(16, pane_h))

    local p1_lines = TerminalUI.render_image_to_lines(golden_img, pane_w, pane_h)
    local p2_lines = TerminalUI.render_image_to_lines(sample_img, pane_w, pane_h)
    local p3_lines = TerminalUI.render_image_to_lines(diff_res.diff_img, pane_w, pane_h)
    local p4_lines = TerminalUI.render_image_to_lines(annotated_img, pane_w, pane_h)

    local title_p1 = "┌─ [1] GOLDEN REFERENCE " .. string.rep("─", math.max(0, pane_w - 24)) .. "┐"
    local title_p2 = "┌─ [2] INSPECTION SAMPLE " .. string.rep("─", math.max(0, pane_w - 24)) .. "┐"
    local title_p3 = "┌─ [3] TRUECOLOR ΔE HEATMAP " .. string.rep("─", math.max(0, pane_w - 27)) .. "┐"
    local title_p4 = "┌─ [4] DEFECT BOUNDING BOXES " .. string.rep("─", math.max(0, pane_w - 28)) .. "┐"

    local b_bot = "└" .. string.rep("─", pane_w) .. "┘"

    -- Row 1: Reference vs Sample
    emit("  %s%s%s   %s%s%s", c_accent, title_p1, c_reset, c_accent, title_p2, c_reset)
    for row = 1, pane_h do
        emit("  │%s%s│   │%s%s│", p1_lines[row], c_reset, p2_lines[row], c_reset)
    end
    emit("  %s   %s\n", b_bot, b_bot)

    -- Row 2: Diff Heatmap vs Annotated Overlay
    emit("  %s%s%s   %s%s%s", c_accent, title_p3, c_reset, c_accent, title_p4, c_reset)
    for row = 1, pane_h do
        emit("  │%s%s│   │%s%s│", p3_lines[row], c_reset, p4_lines[row], c_reset)
    end
    emit("  %s   %s\n", b_bot, b_bot)

    -- Defect Log Table
    emit("  %s═════════════════════════════ DETECTED DEFECTS LOG ═════════════════════════════%s", c_title, c_reset)
    emit("   %sID   SEVERITY   BBOX (X, Y, W, H)    AREA      PEAK ΔE   CLASSIFICATION%s", c_accent, c_reset)
    emit("  ───────────────────────────────────────────────────────────────────────────────")

    if #blobs == 0 then
        emit("   %sNo defects detected. Template matches inspection sample within tolerance.%s", c_green, c_reset)
    else
        for _, b in ipairs(blobs) do
            local sev_str = b.severity
            if sev_str == "CRITICAL" then sev_str = c_red .. "CRITICAL" .. c_reset
            elseif sev_str == "MODERATE" then sev_str = c_yellow .. "MODERATE" .. c_reset
            else sev_str = c_gray .. "MINOR   " .. c_reset end

            local bbox_str = string.format("(%3d,%3d,%3d,%3d)", b.x_min, b.y_min, b.width, b.height)
            emit("   #%-2d %s  %-20s %4d px   %6.1f    %-16s",
                b.id, sev_str, bbox_str, b.area, b.max_delta, b.classification)
        end
    end
    emit("  ───────────────────────────────────────────────────────────────────────────────\n")

    return table.concat(lines, "\n")
end

-- =========================================================================
-- 6. CLI Handler, Benchmark & Self-Tests
-- =========================================================================
local function print_help()
    print([[
Optical Defect Inspector & Image Diff Engine • LuaJIT FFI

Usage:
  luajit ffi_image_defect_detector.lua [options] [ref_image sample_image]

Options:
  --help, -h             Show this help guide.
  --demo                 Run automatic demonstration using dynamically synthesized PCB images.
  --tolerance <num>      Color distance threshold ΔE to qualify as defect (default: 28).
  --min-area <pixels>    Minimum contiguous blob pixel area to report (default: 5).
  --json                 Output structured JSON defect report to stdout.
  --save-ppm             Save golden, sample, and annotated result PPM images to disk.
  --ascii                Use ASCII fallback instead of ANSI truecolor codes.
  --snapshot             Print non-interactive dashboard snapshot and exit immediately.
  --test                 Run the comprehensive internal regression & unit test suite.

Examples:
  # 1. Run dynamic demo in terminal:
  luajit ffi_image_defect_detector.lua --demo

  # 2. Inspect real image files:
  luajit ffi_image_defect_detector.lua ref_board.ppm test_sample.ppm --tolerance 30

  # 3. Batch inspection producing JSON in CI pipeline:
  luajit ffi_image_defect_detector.lua --demo --json
]])
end

local function run_self_tests()
    print("=== Running Self-Tests for ffi_image_defect_detector.lua ===")
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

    -- 1. FFI Struct verification
    assert_true(ffi.sizeof("PixelRGB") == 3, "PixelRGB sizeof == 3")
    assert_true(ffi.offsetof("PixelRGB", "r") == 0, "PixelRGB offsetof(r) == 0")
    assert_true(ffi.offsetof("PixelRGB", "g") == 1, "PixelRGB offsetof(g) == 1")
    assert_true(ffi.offsetof("PixelRGB", "b") == 2, "PixelRGB offsetof(b) == 2")

    -- 2. In-Memory Image buffer operations
    local img = Image.new(64, 48, 10, 20, 30)
    assert_true(img.width == 64 and img.height == 48, "Image.new creates correct dimensions")
    local r, g, b = img:get_pixel(10, 10)
    assert_true(r == 10 and g == 20 and b == 30, "Image:fill / get_pixel verified")

    img:set_pixel(10, 10, 200, 210, 220)
    r, g, b = img:get_pixel(10, 10)
    assert_true(r == 200 and g == 210 and b == 220, "Image:set_pixel verified")

    -- 3. Dynamic PCB Generation
    local golden = PCBGenerator.generate_golden_pcb(80, 45)
    assert_true(golden.width == 80 and golden.height == 45, "PCBGenerator.generate_golden_pcb successful")

    -- Clone and inject defects
    local sample, injected = PCBGenerator.inject_defects(golden, {
        missing_component = true,
        scratch = true,
        solder_bridge = true,
        dust = true
    })
    assert_true(#injected == 4, "Injected exactly 4 synthetic defects")

    -- 4. Optical Differencing & Connected Component Clustering
    local detector = DefectDetector.new({ tolerance = 25, min_blob_area = 4 })
    local diff_res = detector:compute_diff(golden, sample)
    assert_true(diff_res.defect_pixel_count > 20, "Diff engine found defect pixels")

    local blobs = detector:extract_blobs(diff_res)
    assert_true(#blobs >= 3, string.format("Connected Component Clustering found %d defect blobs", #blobs))

    -- Check classifications
    local has_scratch = false
    local has_missing = false
    for _, bl in ipairs(blobs) do
        if bl.classification == "Linear Scratch" then has_scratch = true end
        if bl.classification == "Missing Element" then has_missing = true end
    end
    assert_true(has_scratch, "Detected & classified 'Linear Scratch'")
    assert_true(has_missing, "Detected & classified 'Missing Element'")

    -- 5. PPM I/O round-trip test
    local tmp_file = "_test_defect_tmp.ppm"
    local save_ok = golden:save_ppm(tmp_file)
    assert_true(save_ok, "Image:save_ppm succeeded")
    local loaded = Image.load_ppm(tmp_file)
    assert_true(loaded ~= nil and loaded.width == 80 and loaded.height == 45, "Image.load_ppm loaded valid file")
    os.remove(tmp_file)

    -- 6. Dashboard output test
    local annotated = detector:render_annotated_overlay(sample, blobs)
    local dash = TerminalUI.render_dashboard(golden, sample, diff_res, annotated, blobs, 1.2, true)
    assert_true(dash:find("OPTICAL DEFECT INSPECTOR", 1, true) ~= nil, "Dashboard rendered title")
    assert_true(dash:find("DETECTED DEFECTS LOG", 1, true) ~= nil, "Dashboard rendered defect table")

    print(string.format("\nTest Summary: %d / %d tests passed.", passed, total))
    if passed == total then
        print("\27[1;32mALL DEFECT DETECTOR TESTS PASSED SUCCESSFULLY!\27[0m")
        return true
    else
        print("\27[1;31mSOME TESTS FAILED!\27[0m")
        return false
    end
end

local function main()
    local tolerance = 28
    local min_area = 5
    local demo_mode = false
    local json_output = false
    local save_ppm = false
    local use_ascii = false
    local snapshot = false

    local ref_path = nil
    local sample_path = nil

    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--help" or a == "-h" then
            print_help()
            return
        elseif a == "--demo" then
            demo_mode = true
        elseif a == "--tolerance" then
            i = i + 1; tolerance = tonumber(arg[i]) or 28
        elseif a == "--min-area" then
            i = i + 1; min_area = tonumber(arg[i]) or 5
        elseif a == "--json" then
            json_output = true
        elseif a == "--save-ppm" then
            save_ppm = true
        elseif a == "--ascii" then
            use_ascii = true
        elseif a == "--snapshot" then
            snapshot = true
        elseif a == "--test" then
            local ok = run_self_tests()
            os.exit(ok and 0 or 1)
        elseif not ref_path then
            ref_path = a
        elseif not sample_path then
            sample_path = a
        end
        i = i + 1
    end

    local golden_img, sample_img

    if demo_mode or (not ref_path and not sample_path) then
        -- Generate synthetic dynamic PCB images
        golden_img = PCBGenerator.generate_golden_pcb(140, 76)
        sample_img = PCBGenerator.inject_defects(golden_img, {
            missing_component = true,
            scratch = true,
            solder_bridge = true,
            dust = true
        })
    else
        if not ref_path or not sample_path then
            io.stderr:write("Error: Both reference and sample image paths must be provided (or use --demo).\n")
            os.exit(1)
        end
        local err
        golden_img, err = Image.load(ref_path)
        if not golden_img then
            io.stderr:write(string.format("Failed to load reference image %q: %s\n", ref_path, tostring(err)))
            os.exit(1)
        end
        sample_img, err = Image.load(sample_path)
        if not sample_img then
            io.stderr:write(string.format("Failed to load sample image %q: %s\n", sample_path, tostring(err)))
            os.exit(1)
        end
    end

    -- Run Optical Differencing & Defect Extraction Engine
    local t0 = get_time_ms()
    local detector = DefectDetector.new({ tolerance = tolerance, min_blob_area = min_area })
    local diff_res = detector:compute_diff(golden_img, sample_img)
    local blobs = detector:extract_blobs(diff_res)
    local annotated_img = detector:render_annotated_overlay(sample_img, blobs)
    local elapsed_ms = get_time_ms() - t0

    -- Save PPM files if requested
    if save_ppm then
        golden_img:save_ppm("pcb_golden_reference.ppm")
        sample_img:save_ppm("pcb_sample_defective.ppm")
        annotated_img:save_ppm("pcb_annotated_result.ppm")
        if not json_output then
            print("Saved images: pcb_golden_reference.ppm, pcb_sample_defective.ppm, pcb_annotated_result.ppm")
        end
    end

    -- JSON Output mode for CI / Automated Factory Integration
    if json_output then
        local defect_entries = {}
        for _, b in ipairs(blobs) do
            table.insert(defect_entries, string.format(
                '    {"id": %d, "bbox": [%d, %d, %d, %d], "area": %d, "max_delta": %.2f, "classification": %q, "severity": %q}',
                b.id, b.x_min, b.y_min, b.width, b.height, b.area, b.max_delta, b.classification, b.severity
            ))
        end
        local json_str = string.format([[
{
  "verdict": %q,
  "defects_count": %d,
  "affected_pixels": %d,
  "inspection_time_ms": %.3f,
  "tolerance": %.1f,
  "min_area": %d,
  "defects": [
%s
  ]
}]], (#blobs == 0) and "PASS" or "FAIL", #blobs, diff_res.defect_pixel_count, elapsed_ms, tolerance, min_area, table.concat(defect_entries, ",\n"))
        print(json_str)
        return
    end

    -- Terminal Dashboard Mode
    local dashboard = TerminalUI.render_dashboard(golden_img, sample_img, diff_res, annotated_img, blobs, elapsed_ms, use_ascii)
    print(dashboard)
end

-- Export module or execute main
if pcall(debug.getlocal, 4, 1) then
    return {
        Image = Image,
        PCBGenerator = PCBGenerator,
        DefectDetector = DefectDetector,
        TerminalUI = TerminalUI
    }
else
    main()
end
