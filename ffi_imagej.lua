#!/usr/bin/env luajit
--[[
================================================================================
ffi_imagej.lua
Scientific Image Viewer & Analysis TUI in LuaJIT FFI
Inspired by ImageJ (National Institutes of Health)

Features:
1. High-Performance FFI Memory Image Buffer:
   - Contiguous C-memory pixel buffers (Grayscale & 24-bit Truecolor RGB).
   - Native PPM / PGM (P2/P3/P5/P6) parser and procedural synthetic targets
     (Cell Colonies, USAF-1951 resolution bars, Linear/Radial Gradients).
   - Fallback to ImageMagick / FFmpeg pipe for PNG, JPG, TIFF, BMP.
2. Scientific ImageJ Analysis Engine:
   - Live Pixel Probe & Crosshair: Coordinates, normalized pos, raw intensity, RGB.
   - Region of Interest (ROI) Measure: Area, Mean, StdDev, Min, Max, Median, IntDen.
   - 1D Line Profile (Plot Profile): Horizontal/Vertical scan, Peak, FWHM analysis.
   - Real-time 256-bin Histogram with Min/Max Window & Level and Auto-Contrast.
   - Scientific Lookup Tables (LUTs): Grayscale, Fire, Viridis, Turbo, Cool, Green.
   - Thresholding & Particle Analysis: Otsu's method and connected component labeling.
   - Spatial Convolutions: 3x3 Median, Gaussian Blur, Sobel Edge Magnitude, Sharpen.
3. Flicker-Free Terminal UI:
   - 24-bit Truecolor ANSI half-block ('▄') image rendering (2 vertical px/cell).
   - Synchronized atomic updates (\27[?2026h ... \27[?2026l) with universal \27[K.
   - Split-pane layout: Visual image on left, Scientific Inspector on right.
================================================================================
]]

local ffi = require("ffi")
local bit = require("bit")

-- =============================================================================
-- 1. FFI C Definitions & OS Platform Abstraction
-- =============================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct { uint8_t r, g, b; } PixelRGB;
    typedef struct { uint8_t v; } PixelGray;
]]

local get_terminal_size
local enable_raw_mode
local disable_raw_mode
local read_key_nonblocking
local is_stdin_tty
local sleep_ms

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

        void* __stdcall GetStdHandle(uint32_t nStdHandle);
        int   __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int   __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int   __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int   __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        void  __stdcall Sleep(uint32_t dwMilliseconds);

        int _kbhit(void);
        int _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6 -- ((uint32_t)-10)
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- ((uint32_t)-11)

    local orig_in_mode = ffi.new("uint32_t[1]")
    local raw_mode_active = false

    pcall(function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        ffi.C.SetConsoleOutputCP(65001) -- UTF-8
        local out_mode = ffi.new("uint32_t[1]")
        if ffi.C.GetConsoleMode(hOut, out_mode) ~= 0 then
            local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            ffi.C.SetConsoleMode(hOut, bit.bor(out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
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
            if w > 0 and h > 0 then
                return tonumber(w), tonumber(h)
            end
        end
        return 100, 30
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        if ffi.C.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end

        local ENABLE_LINE_INPUT = 0x0002
        local ENABLE_ECHO_INPUT = 0x0004
        local new_mode = bit.band(orig_in_mode[0], bit.bnot(bit.bor(ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT)))
        ffi.C.SetConsoleMode(hIn, new_mode)
        raw_mode_active = true
        return true
    end

    disable_raw_mode = function()
        if raw_mode_active then
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            raw_mode_active = false
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
            elseif ch == 27 then
                return "ESC"
            elseif ch == 13 or ch == 10 then
                return "ENTER"
            elseif ch == 32 then
                return "SPACE"
            elseif ch == 3 then
                return "CTRL_C"
            elseif ch == 9 then
                return "TAB"
            else
                return string.char(ch)
            end
        end
        return nil
    end

    sleep_ms = function(ms)
        ffi.C.Sleep(ms)
    end
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

        int tcgetattr(int fd, struct termios* termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios* termios_p);
        int ioctl(int fd, unsigned long request, ...);
        int poll(struct pollfd* fds, unsigned long nfds, int timeout);
        long read(int fd, void* buf, size_t count);
        int isatty(int fd);
        int usleep(unsigned int usec);
    ]]

    local STDIN_FILENO  = 0
    local STDOUT_FILENO = 1
    local TIOCGWINSZ    = (ffi.os == "OSX") and 0x40087468 or 0x5413
    local TCSANOW       = 0
    local POLLIN        = 0x0001

    local orig_termios = ffi.new("struct termios")
    local raw_mode_active = false
    local key_buf = ffi.new("uint8_t[32]")

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(STDOUT_FILENO, TIOCGWINSZ, ws) == 0 then
            if ws.ws_col > 0 and ws.ws_row > 0 then
                return tonumber(ws.ws_col), tonumber(ws.ws_row)
            end
        end
        return 100, 30
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        if ffi.C.tcgetattr(STDIN_FILENO, orig_termios) ~= 0 then return false end

        local raw = ffi.new("struct termios")
        ffi.copy(raw, orig_termios, ffi.sizeof("struct termios"))
        local ICANON = 0x0002
        local ECHO   = 0x0008
        raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        if ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw) ~= 0 then return false end

        raw_mode_active = true
        return true
    end

    disable_raw_mode = function()
        if raw_mode_active then
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            raw_mode_active = false
        end
    end

    read_key_nonblocking = function()
        local pfd = ffi.new("struct pollfd[1]")
        pfd[0].fd = STDIN_FILENO
        pfd[0].events = POLLIN

        local ret = ffi.C.poll(pfd, 1, 0)
        if ret > 0 and bit.band(pfd[0].revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 31)
            if n > 0 then
                local b0 = key_buf[0]
                if b0 == 27 then
                    if n == 1 then
                        return "ESC"
                    elseif n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP"
                        elseif c2 == 66 then return "DOWN"
                        elseif c2 == 67 then return "RIGHT"
                        elseif c2 == 68 then return "LEFT"
                        end
                    end
                    return "ESC"
                elseif b0 == 10 or b0 == 13 then
                    return "ENTER"
                elseif b0 == 32 then
                    return "SPACE"
                elseif b0 == 3 then
                    return "CTRL_C"
                elseif b0 == 9 then
                    return "TAB"
                else
                    return string.char(b0)
                end
            end
        end
        return nil
    end

    sleep_ms = function(ms)
        ffi.C.usleep(ms * 1000)
    end
end

-- =============================================================================
-- 2. Lookup Tables (LUTs / Pseudocolor Palettes)
-- =============================================================================
local LUTS = {}

-- 1. Grayscale (1:1 Linear)
LUTS["Grayscale"] = function(v)
    return v, v, v
end

-- 2. Fire (ImageJ Classic Black -> Red -> Orange -> Yellow -> White)
LUTS["Fire"] = function(v)
    local r, g, b = 0, 0, 0
    if v < 64 then
        r = math.min(255, math.floor(v * 4))
    elseif v < 128 then
        r = 255
        g = math.min(255, math.floor((v - 64) * 4))
    elseif v < 192 then
        r = 255
        g = 255
        b = math.min(255, math.floor((v - 128) * 4))
    else
        r = 255
        g = 255
        b = 255
    end
    return r, g, b
end

-- 3. Viridis (Perceptually Uniform Scientific Colormap)
LUTS["Viridis"] = function(v)
    local t = v / 255.0
    local r = math.max(0, math.min(255, math.floor((0.267 + t * (0.005 + t * (2.0 - t * 1.5))) * 255)))
    local g = math.max(0, math.min(255, math.floor((0.004 + t * (1.4 - t * 0.45)) * 255)))
    local b = math.max(0, math.min(255, math.floor((0.329 + t * (0.8 - t * 1.1)) * 255)))
    return r, g, b
end

-- 4. Cool (Cyan to Magenta)
LUTS["Cool"] = function(v)
    return v, 255 - v, 255
end

-- 5. Turbo (Improved Rainbow with Smoothed Transitions)
LUTS["Turbo"] = function(v)
    local t = v / 255.0
    local r = math.floor(255 * math.sin(t * math.pi * 0.9))
    local g = math.floor(255 * math.sin((t - 0.2) * math.pi * 0.9))
    local b = math.floor(255 * math.cos(t * math.pi * 0.8))
    return math.max(0, math.min(255, r)), math.max(0, math.min(255, g)), math.max(0, math.min(255, b))
end

-- 6. Green Fluorescence (Classic GFP channel in microscopy)
LUTS["Green"] = function(v)
    return 0, v, 0
end

local LUT_NAMES = { "Grayscale", "Fire", "Viridis", "Cool", "Turbo", "Green" }

-- =============================================================================
-- 3. Image Buffer Class & Procedural Target Generators
-- =============================================================================
local ImageBuffer = {}
ImageBuffer.__index = ImageBuffer

function ImageBuffer.new(width, height, is_rgb)
    local self = setmetatable({}, ImageBuffer)
    self.width = width
    self.height = height
    self.is_rgb = is_rgb or false
    self.channels = self.is_rgb and 3 or 1
    self.size = width * height * self.channels
    self.data = ffi.new("uint8_t[?]", self.size)
    return self
end

function ImageBuffer:get_pixel(x, y)
    if x < 0 or x >= self.width or y < 0 or y >= self.height then
        return 0, 0, 0
    end
    if self.is_rgb then
        local idx = (y * self.width + x) * 3
        return self.data[idx], self.data[idx + 1], self.data[idx + 2]
    else
        local v = self.data[y * self.width + x]
        return v, v, v
    end
end

function ImageBuffer:get_gray(x, y)
    if x < 0 or x >= self.width or y < 0 or y >= self.height then
        return 0
    end
    if self.is_rgb then
        local idx = (y * self.width + x) * 3
        local r = self.data[idx]
        local g = self.data[idx + 1]
        local b = self.data[idx + 2]
        return math.floor(0.299 * r + 0.587 * g + 0.114 * b)
    else
        return self.data[y * self.width + x]
    end
end

function ImageBuffer:set_pixel(x, y, r, g, b)
    if x < 0 or x >= self.width or y < 0 or y >= self.height then return end
    if self.is_rgb then
        local idx = (y * self.width + x) * 3
        self.data[idx]     = r or 0
        self.data[idx + 1] = g or 0
        self.data[idx + 2] = b or 0
    else
        local v = r
        if g and b then
            v = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
        end
        self.data[y * self.width + x] = v or 0
    end
end

function ImageBuffer:clone()
    local copy = ImageBuffer.new(self.width, self.height, self.is_rgb)
    ffi.copy(copy.data, self.data, self.size)
    return copy
end

-- Procedural Generator: Fluorescent Cell Colony Blobs (ideal for ImageJ analysis)
function ImageBuffer.generate_cells(width, height)
    local img = ImageBuffer.new(width, height, false)
    local num_cells = 18
    local cells = {}
    math.randomseed(42)

    for i = 1, num_cells do
        cells[i] = {
            x = math.random(20, width - 20),
            y = math.random(20, height - 20),
            radius = math.random(6, 18),
            intensity = math.random(180, 255)
        }
    end

    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local total_val = 15 + math.random(0, 6) -- Background noise
            for i = 1, num_cells do
                local c = cells[i]
                local dx = x - c.x
                local dy = y - c.y
                local dist_sq = dx * dx + dy * dy
                local r_sq = c.radius * c.radius
                if dist_sq < r_sq * 4 then
                    local factor = math.exp(-dist_sq / (2 * (c.radius * 0.6) * (c.radius * 0.6)))
                    total_val = total_val + math.floor(c.intensity * factor)
                end
            end
            img:set_pixel(x, y, math.min(255, total_val))
        end
    end
    return img
end

-- Procedural Generator: USAF Resolution Target & Gradient Wedges
function ImageBuffer.generate_target(width, height)
    local img = ImageBuffer.new(width, height, false)
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local val = 0
            if y < height * 0.3 then
                -- Linear gradient bar
                val = math.floor((x / width) * 255)
            elseif y < height * 0.7 then
                -- Frequency bars
                local freq = 2 + math.floor((x / width) * 24)
                val = (math.sin(x * freq * 0.1) > 0) and 240 or 15
            else
                -- Concentric rings / spots
                local cx = width * 0.5
                local cy = height * 0.85
                local dist = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy))
                val = math.floor((math.sin(dist * 0.4) + 1.0) * 120)
            end
            img:set_pixel(x, y, math.max(0, math.min(255, val)))
        end
    end
    return img
end

-- Parse PNM stream from an open file handle or pipe
function ImageBuffer.parse_pnm_handle(f)
    local function read_token()
        local tok = ""
        while true do
            local ch = f:read(1)
            if not ch then break end
            if ch == "#" then
                f:read("*l") -- Skip comment line
            elseif ch:match("%s") then
                if #tok > 0 then break end
            else
                tok = tok .. ch
            end
        end
        return tok
    end

    local magic = read_token()
    if not magic or magic == "" then
        return nil, "Invalid or empty PNM header"
    end

    local is_rgb = (magic == "P3" or magic == "P6")
    local is_binary = (magic == "P5" or magic == "P6")
    if not (magic == "P2" or magic == "P3" or magic == "P5" or magic == "P6") then
        return nil, "Unsupported magic format: " .. tostring(magic)
    end

    local width_str = read_token()
    local height_str = read_token()
    local max_val_str = read_token()

    local w = tonumber(width_str)
    local h = tonumber(height_str)
    local max_val = tonumber(max_val_str) or 255

    if not w or not h or w <= 0 or h <= 0 then
        return nil, "Invalid dimensions: " .. tostring(width_str) .. "x" .. tostring(height_str)
    end

    local img = ImageBuffer.new(w, h, is_rgb)

    if is_binary then
        local bytes_per_px = is_rgb and 3 or 1
        local total_bytes = w * h * bytes_per_px
        local raw_data = f:read(total_bytes)
        if not raw_data or #raw_data < total_bytes then
            return nil, "Premature end of file in binary PNM stream"
        end
        ffi.copy(img.data, raw_data, total_bytes)
    else
        -- ASCII P2 or P3
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                if is_rgb then
                    local r = math.floor((tonumber(read_token()) or 0) * 255 / max_val)
                    local g = math.floor((tonumber(read_token()) or 0) * 255 / max_val)
                    local b = math.floor((tonumber(read_token()) or 0) * 255 / max_val)
                    img:set_pixel(x, y, r, g, b)
                else
                    local v = math.floor((tonumber(read_token()) or 0) * 255 / max_val)
                    img:set_pixel(x, y, v)
                end
            end
        end
    end

    return img
end

-- Load PPM / PGM format (P2, P3, P5, P6)
function ImageBuffer.load_pnm(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil, "Cannot open file: " .. tostring(filepath) end
    local img, err = ImageBuffer.parse_pnm_handle(f)
    f:close()
    return img, err
end

-- Universal Image Loader: Native PNM with FFmpeg & ImageMagick fallback (PNG, JPG, TIFF, BMP)
function ImageBuffer.load_image(filepath)
    local test_f = io.open(filepath, "rb")
    if not test_f then
        return nil, "Cannot open file: " .. tostring(filepath)
    end
    local header = test_f:read(3) or ""
    test_f:close()

    -- 1. Native PNM format
    if header:match("^P[2356]") then
        local img, err = ImageBuffer.load_pnm(filepath)
        if img then return img end
    end

    -- 2. Pipe fallback via FFmpeg or ImageMagick
    local devnull = is_windows and "nul" or "/dev/null"
    local popen_mode = is_windows and "rb" or "r"
    local cmd = string.format('ffmpeg -nostdin -loglevel quiet -i %q -f image2pipe -vcodec ppm - 2>%s || magick %q ppm:- 2>%s',
        filepath, devnull, filepath, devnull)
    local pipe = io.popen(cmd, popen_mode)
    if pipe then
        local img, err = ImageBuffer.parse_pnm_handle(pipe)
        pipe:close()
        if img then
            return img
        end
    end

    return nil, "Unsupported image format or missing decoder (requires PNM, ffmpeg, or magick)"
end

-- =============================================================================
-- 4. Scientific ImageJ Analysis Algorithms
-- =============================================================================

-- Region of Interest (ROI) Descriptive Statistics
local function compute_roi_stats(img, roi)
    local x1 = math.max(0, math.min(roi.x1, roi.x2))
    local x2 = math.min(img.width - 1, math.max(roi.x1, roi.x2))
    local y1 = math.max(0, math.min(roi.y1, roi.y2))
    local y2 = math.min(img.height - 1, math.max(roi.y1, roi.y2))

    local count = 0
    local sum = 0
    local min_val = 255
    local max_val = 0
    local hist = {}
    for i = 0, 255 do hist[i] = 0 end

    for y = y1, y2 do
        for x = x1, x2 do
            local v = img:get_gray(x, y)
            count = count + 1
            sum = sum + v
            if v < min_val then min_val = v end
            if v > max_val then max_val = v end
            hist[v] = hist[v] + 1
        end
    end

    if count == 0 then
        return {
            area = 0, mean = 0, std_dev = 0,
            min = 0, max = 0, median = 0, mode = 0, int_den = 0
        }
    end

    local mean = sum / count

    -- Standard Deviation
    local variance_sum = 0
    for y = y1, y2 do
        for x = x1, x2 do
            local v = img:get_gray(x, y)
            local diff = v - mean
            variance_sum = variance_sum + (diff * diff)
        end
    end
    local std_dev = math.sqrt(variance_sum / count)

    -- Median & Mode
    local median = 0
    local running_count = 0
    local half = count / 2.0
    for i = 0, 255 do
        running_count = running_count + hist[i]
        if running_count >= half then
            median = i
            break
        end
    end

    local mode = 0
    local mode_count = -1
    for i = 0, 255 do
        if hist[i] > mode_count then
            mode_count = hist[i]
            mode = i
        end
    end

    return {
        area = count,
        mean = mean,
        std_dev = std_dev,
        min = min_val,
        max = max_val,
        median = median,
        mode = mode,
        int_den = sum,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2
    }
end

-- 1D Line Intensity Profile & Full Width at Half Maximum (FWHM)
local function compute_line_profile(img, is_horizontal, fixed_coord)
    local profile = {}
    local max_len = is_horizontal and img.width or img.height
    local peak_val = -1
    local peak_pos = 0
    local min_val = 256
    local sum = 0

    for i = 0, max_len - 1 do
        local v = is_horizontal and img:get_gray(i, fixed_coord) or img:get_gray(fixed_coord, i)
        profile[i + 1] = v
        sum = sum + v
        if v > peak_val then
            peak_val = v
            peak_pos = i
        end
        if v < min_val then
            min_val = v
        end
    end

    local baseline = min_val
    local half_max = baseline + (peak_val - baseline) / 2.0

    -- Calculate FWHM
    local left_crossing = peak_pos
    local right_crossing = peak_pos

    for i = peak_pos, 0, -1 do
        if profile[i + 1] <= half_max then
            left_crossing = i
            break
        end
    end

    for i = peak_pos, max_len - 1 do
        if profile[i + 1] <= half_max then
            right_crossing = i
            break
        end
    end

    local fwhm = math.max(0, right_crossing - left_crossing)

    return {
        data = profile,
        length = max_len,
        peak_val = peak_val,
        peak_pos = peak_pos,
        baseline = baseline,
        half_max = half_max,
        fwhm = fwhm,
        mean = sum / math.max(1, max_len)
    }
end

-- Full Image 256-Bin Histogram
local function compute_histogram(img)
    local hist = {}
    for i = 0, 255 do hist[i] = 0 end
    local total = img.width * img.height

    for y = 0, img.height - 1 do
        for x = 0, img.width - 1 do
            local v = img:get_gray(x, y)
            hist[v] = hist[v] + 1
        end
    end
    return hist, total
end

-- ImageJ Auto Window / Level (0.35% High / Low Saturation Cutoff)
local function compute_auto_window_level(img)
    local hist, total = compute_histogram(img)
    local limit = math.floor(total * 0.0035)

    local low = 0
    local accum = 0
    for i = 0, 255 do
        accum = accum + hist[i]
        if accum > limit then
            low = i
            break
        end
    end

    local high = 255
    accum = 0
    for i = 255, 0, -1 do
        accum = accum + hist[i]
        if accum > limit then
            high = i
            break
        end
    end

    if high <= low then
        low = 0
        high = 255
    end

    return low, high
end

-- Otsu's Auto-Thresholding (Maximizes Inter-Class Bimodal Variance)
local function compute_otsu_threshold(img)
    local hist, total = compute_histogram(img)
    if total == 0 then return 128 end

    local sum_all = 0
    for i = 0, 255 do
        sum_all = sum_all + i * hist[i]
    end

    local sum_bg = 0
    local weight_bg = 0
    local max_variance = -1.0
    local threshold = 128

    local max_t_start = 128
    local max_t_end = 128

    for t = 0, 255 do
        weight_bg = weight_bg + hist[t]
        if weight_bg > 0 and weight_bg < total then
            local weight_fg = total - weight_bg
            sum_bg = sum_bg + t * hist[t]

            local mean_bg = sum_bg / weight_bg
            local mean_fg = (sum_all - sum_bg) / weight_fg
            local mean_diff = mean_bg - mean_fg

            local between_variance = weight_bg * weight_fg * mean_diff * mean_diff
            if between_variance > max_variance then
                max_variance = between_variance
                max_t_start = t
                max_t_end = t
            elseif max_variance > 0 and math.abs(between_variance - max_variance) < 1e-6 then
                max_t_end = t
            end
        end
    end

    threshold = math.floor((max_t_start + max_t_end) / 2)
    return threshold
end

-- Particle / Connected Component Analysis (8-Connected Blobs)
local function analyze_particles(img, threshold)
    local w = img.width
    local h = img.height
    local visited = ffi.new("uint8_t[?]", w * h)
    local blobs = {}

    local queue_x = ffi.new("int32_t[?]", w * h)
    local queue_y = ffi.new("int32_t[?]", w * h)

    local dx = { -1, 0, 1, -1, 1, -1, 0, 1 }
    local dy = { -1, -1, -1, 0, 0, 1, 1, 1 }

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local idx = y * w + x
            if visited[idx] == 0 and img:get_gray(x, y) >= threshold then
                -- Flood fill blob
                local head = 0
                local tail = 0
                queue_x[tail] = x
                queue_y[tail] = y
                tail = tail + 1
                visited[idx] = 1

                local blob_area = 0
                local sum_x = 0
                local sum_y = 0
                local min_bx = x
                local max_bx = x
                local min_by = y
                local max_by = y

                while head < tail do
                    local cx = queue_x[head]
                    local cy = queue_y[head]
                    head = head + 1
                    blob_area = blob_area + 1
                    sum_x = sum_x + cx
                    sum_y = sum_y + cy

                    if cx < min_bx then min_bx = cx end
                    if cx > max_bx then max_bx = cx end
                    if cy < min_by then min_by = cy end
                    if cy > max_by then max_by = cy end

                    for d = 1, 8 do
                        local nx = cx + dx[d]
                        local ny = cy + dy[d]
                        if nx >= 0 and nx < w and ny >= 0 and ny < h then
                            local nidx = ny * w + nx
                            if visited[nidx] == 0 and img:get_gray(nx, ny) >= threshold then
                                visited[nidx] = 1
                                queue_x[tail] = nx
                                queue_y[tail] = ny
                                tail = tail + 1
                            end
                        end
                    end
                end

                if blob_area >= 4 then -- Filter 1-3 px noise artifacts
                    table.insert(blobs, {
                        area = blob_area,
                        cx = math.floor(sum_x / blob_area),
                        cy = math.floor(sum_y / blob_area),
                        w = max_bx - min_bx + 1,
                        h = max_by - min_by + 1
                    })
                end
            end
        end
    end

    table.sort(blobs, function(a, b) return a.area > b.area end)

    local total_area = 0
    for _, b in ipairs(blobs) do
        total_area = total_area + b.area
    end

    return {
        blobs = blobs,
        count = #blobs,
        total_area = total_area,
        avg_area = (#blobs > 0) and (total_area / #blobs) or 0
    }
end

-- 3x3 Spatial Convolution Filters
local function apply_filter(img, filter_name)
    local w = img.width
    local h = img.height
    local out = ImageBuffer.new(w, h, false)

    if filter_name == "median" then
        local window = {}
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local n = 0
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local px = math.max(0, math.min(w - 1, x + dx))
                        local py = math.max(0, math.min(h - 1, y + dy))
                        n = n + 1
                        window[n] = img:get_gray(px, py)
                    end
                end
                table.sort(window)
                out:set_pixel(x, y, window[5])
            end
        end
    elseif filter_name == "blur" then
        -- 3x3 Gaussian approximation: [1 2 1; 2 4 2; 1 2 1] / 16
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local sum = 0
                sum = sum + img:get_gray(math.max(0, x - 1), math.max(0, y - 1)) * 1
                sum = sum + img:get_gray(x, math.max(0, y - 1)) * 2
                sum = sum + img:get_gray(math.min(w - 1, x + 1), math.max(0, y - 1)) * 1
                sum = sum + img:get_gray(math.max(0, x - 1), y) * 2
                sum = sum + img:get_gray(x, y) * 4
                sum = sum + img:get_gray(math.min(w - 1, x + 1), y) * 2
                sum = sum + img:get_gray(math.max(0, x - 1), math.min(h - 1, y + 1)) * 1
                sum = sum + img:get_gray(x, math.min(h - 1, y + 1)) * 2
                sum = sum + img:get_gray(math.min(w - 1, x + 1), math.min(h - 1, y + 1)) * 1
                out:set_pixel(x, y, math.floor(sum / 16))
            end
        end
    elseif filter_name == "sobel" then
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local p00 = img:get_gray(math.max(0, x - 1), math.max(0, y - 1))
                local p01 = img:get_gray(x, math.max(0, y - 1))
                local p02 = img:get_gray(math.min(w - 1, x + 1), math.max(0, y - 1))
                local p10 = img:get_gray(math.max(0, x - 1), y)
                local p12 = img:get_gray(math.min(w - 1, x + 1), y)
                local p20 = img:get_gray(math.max(0, x - 1), math.min(h - 1, y + 1))
                local p21 = img:get_gray(x, math.min(h - 1, y + 1))
                local p22 = img:get_gray(math.min(w - 1, x + 1), math.min(h - 1, y + 1))

                local gx = (-1 * p00) + (1 * p02) + (-2 * p10) + (2 * p12) + (-1 * p20) + (1 * p22)
                local gy = (-1 * p00) + (-2 * p01) + (-1 * p02) + (1 * p20) + (2 * p21) + (1 * p22)
                local mag = math.floor(math.sqrt(gx * gx + gy * gy))
                out:set_pixel(x, y, math.min(255, mag))
            end
        end
    end

    return out
end

-- =============================================================================
-- 5. Terminal User Interface & Differential Frame Renderer
-- =============================================================================
local function build_tui_app(initial_img, filename)
    local app = {
        img = initial_img,
        raw_img = initial_img:clone(),
        filename = filename or "sample_cells.pgm",
        probe_x = math.floor(initial_img.width / 2),
        probe_y = math.floor(initial_img.height / 2),
        roi = { x1 = 10, y1 = 10, x2 = 50, y2 = 40, active = false },
        lut_idx = 1, -- 1: Grayscale, 2: Fire, 3: Viridis, etc.
        win_low = 0,
        win_high = 255,
        zoom = 1.0,
        pan_x = 0,
        pan_y = 0,
        mode = "normal", -- "normal", "profile", "threshold", "help"
        profile_horizontal = true,
        threshold_val = 128,
        show_help = false,
        status_msg = "Ready. Use arrows to probe pixels. [?] for Help."
    }

    -- Auto W/L on startup
    app.win_low, app.win_high = compute_auto_window_level(app.img)

    function app:map_display_color(gray_val)
        -- Apply Window / Level Contrast Stretch
        local stretched = 0
        if self.win_high > self.win_low then
            local norm = (gray_val - self.win_low) / (self.win_high - self.win_low)
            stretched = math.max(0, math.min(255, math.floor(norm * 255)))
        else
            stretched = gray_val
        end

        local lut_fn = LUTS[LUT_NAMES[self.lut_idx]] or LUTS["Grayscale"]
        return lut_fn(stretched)
    end

    function app:render_frame(cols, rows)
        local lines = {}
        local emit = function(s) table.insert(lines, s) end

        -- Clamp terminal width
        cols = math.max(80, cols)
        rows = math.max(24, rows)

        local pane_w = math.floor(cols * 0.52)
        local insp_w = cols - pane_w - 3
        local view_h = rows - 4

        -- 1. Top Header
        local lut_name = LUT_NAMES[self.lut_idx]
        local title = string.format(" ffi_imagej: %s [%dx%d] ", self.filename, self.img.width, self.img.height)
        local mode_tag = string.format(" [Mode: %s | LUT: %s | W/L: %d-%d] ", self.mode:upper(), lut_name, self.win_low, self.win_high)
        local help_tag = " [?] Help "
        local fill_len = math.max(0, cols - #title - #mode_tag - #help_tag - 4)

        emit("\27[1;37;44m┌─" .. title .. string.rep("─", fill_len) .. mode_tag .. help_tag .. "─┐\27[0m\27[K\n")

        -- 2. Gather Inspector Data
        local probe_val = self.img:get_gray(self.probe_x, self.probe_y)
        local pr_r, pr_g, pr_b = self:map_display_color(probe_val)
        local roi_stats = compute_roi_stats(self.img, self.roi)
        local prof = compute_line_profile(self.img, self.profile_horizontal, self.profile_horizontal and self.probe_y or self.probe_x)
        local hist, total_px = compute_histogram(self.img)

        -- 3. Pre-format Right Pane Lines
        local right_lines = {}
        local function add_right(str)
            table.insert(right_lines, str)
        end

        add_right(string.format("\27[1;36m── 1. Pixel Probe ──────────────────────────\27[0m"))
        add_right(string.format(" Pos: (X: \27[1m%3d\27[0m, Y: \27[1m%3d\27[0m)  Norm: %2d%%, %2d%%",
            self.probe_x, self.probe_y,
            math.floor(self.probe_x * 100 / math.max(1, self.img.width)),
            math.floor(self.probe_y * 100 / math.max(1, self.img.height))))
        add_right(string.format(" Value: \27[1;33m%3d / 255\27[0m  Intensity: \27[1m%2.1f%%\27[0m",
            probe_val, (probe_val / 255.0) * 100.0))
        add_right(string.format(" Display: \27[38;2;%d;%d;%dm██\27[0m RGB(%3d, %3d, %3d) #%02X%02X%02X",
            pr_r, pr_g, pr_b, pr_r, pr_g, pr_b, pr_r, pr_g, pr_b))
        add_right("")

        add_right(string.format("\27[1;36m── 2. ROI Statistics (Measure) ─────────────\27[0m"))
        if self.roi.active then
            add_right(string.format(" Box: [%d,%d to %d,%d] Area: \27[1m%d px\27[0m",
                roi_stats.x1, roi_stats.y1, roi_stats.x2, roi_stats.y2, roi_stats.area))
            add_right(string.format(" Mean: \27[1;32m%.2f\27[0m  StdDev: \27[1;32m%.2f\27[0m",
                roi_stats.mean, roi_stats.std_dev))
            add_right(string.format(" Min: \27[1m%d\27[0m  Max: \27[1m%d\27[0m  Median: \27[1m%d\27[0m",
                roi_stats.min, roi_stats.max, roi_stats.median))
            add_right(string.format(" Integrated Density: \27[1;33m%d\27[0m", roi_stats.int_den))
        else
            add_right(" \27[90m[No ROI active. Press 'r' to set box]\27[0m")
            add_right(string.format(" Full Image Area: %d px", self.img.width * self.img.height))
            add_right(string.format(" Full Mean: %.2f  StdDev: %.2f", roi_stats.mean, roi_stats.std_dev))
            add_right("")
        end
        add_right("")

        add_right(string.format("\27[1;36m── 3. Line Profile (%s @ %d) ───\27[0m",
            self.profile_horizontal and "Horiz Y" or "Vert X",
            self.profile_horizontal and self.probe_y or self.probe_x))
        add_right(string.format(" Peak: \27[1;33m%d\27[0m @ pos %d  Baseline: %d",
            prof.peak_val, prof.peak_pos, prof.baseline))
        add_right(string.format(" Half-Max: %.1f  \27[1;35mFWHM: %d px\27[0m",
            prof.half_max, prof.fwhm))

        -- Compact Sparkline for Line Profile
        local spark_chars = { " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
        local spark_str = ""
        local spark_step = math.max(1, math.floor(prof.length / math.max(1, (insp_w - 6))))
        for i = 1, prof.length, spark_step do
            local val = prof.data[i] or 0
            local s_idx = math.max(1, math.min(8, math.floor((val / 255.0) * 7) + 1))
            spark_str = spark_str .. spark_chars[s_idx]
            if #spark_str >= (insp_w - 6) then break end
        end
        add_right(" 255│\27[36m" .. spark_str .. "\27[0m")
        add_right("   0└──" .. string.rep("─", #spark_str))
        add_right("")

        add_right(string.format("\27[1;36m── 4. Histogram & Window / Level ───────────\27[0m"))
        local max_hist = 1
        for i = 0, 255 do
            if hist[i] > max_hist then max_hist = hist[i] end
        end
        local hist_str = ""
        local hist_step = math.floor(256 / math.max(1, (insp_w - 6)))
        for i = 0, 255, hist_step do
            local bucket_sum = 0
            for k = 0, hist_step - 1 do bucket_sum = bucket_sum + (hist[i + k] or 0) end
            local s_idx = math.max(1, math.min(8, math.floor((bucket_sum / (max_hist * hist_step)) * 7) + 1))
            hist_str = hist_str .. spark_chars[s_idx]
            if #hist_str >= (insp_w - 6) then break end
        end
        add_right(" 100%│\27[33m" .. hist_str .. "\27[0m")
        add_right(string.format(" Range: [\27[1m%d\27[0m - \27[1m%d\27[0m] Win: %d  Lvl: %d",
            self.win_low, self.win_high, self.win_high - self.win_low, math.floor((self.win_high + self.win_low) / 2)))

        -- 4. Render Dual-Pane Viewport
        local img_display_w = pane_w - 2
        local img_display_h = view_h * 2 -- Half blocks give 2 vertical px per cell

        local cur_col = math.max(0, math.min(img_display_w - 1, math.floor(self.probe_x * img_display_w / self.img.width)))
        local cur_row_px = math.max(0, math.min(img_display_h - 1, math.floor(self.probe_y * img_display_h / self.img.height)))

        -- High-visibility crosshair styler
        local function apply_crosshair(r, g, b, col, py)
            local dx = math.abs(col - cur_col)
            local dy = math.abs(py - cur_row_px)

            if dx == 0 and dy == 0 then
                -- Center target point: high-contrast inverted neon
                local lum = (r * 0.299 + g * 0.587 + b * 0.114)
                if lum > 140 then
                    return 255, 0, 80 -- Neon Crimson on bright background
                else
                    return 255, 255, 0 -- Electric Yellow on dark background
                end
            elseif (dx <= 2 and dy == 0) or (dx == 0 and dy <= 2) then
                -- Prominent reticle arms (+)
                local lum = (r * 0.299 + g * 0.587 + b * 0.114)
                if lum > 140 then
                    return 0, 220, 255 -- Electric Cyan
                else
                    return 255, 220, 0 -- Vivid Amber
                end
            elseif (dx == 0 and (py % 2 == 0)) or (dy == 0 and (col % 2 == 0)) then
                -- Dashed hairline guides across entire viewport
                return math.min(255, r + 50), math.min(255, g + 50), math.max(0, b - 30)
            end

            return r, g, b
        end

        -- Pre-map ROI box to display coordinates
        local drx1, drx2, dry1, dry2 = -1, -1, -1, -1
        if self.roi.active then
            local rx1 = math.min(self.roi.x1, self.roi.x2)
            local rx2 = math.max(self.roi.x1, self.roi.x2)
            local ry1 = math.min(self.roi.y1, self.roi.y2)
            local ry2 = math.max(self.roi.y1, self.roi.y2)
            drx1 = math.floor(rx1 * img_display_w / self.img.width)
            drx2 = math.floor(rx2 * img_display_w / self.img.width)
            dry1 = math.floor(ry1 * img_display_h / self.img.height)
            dry2 = math.floor(ry2 * img_display_h / self.img.height)
        end

        for row = 0, view_h - 1 do
            local row_str = "\27[1;37;44m│\27[0m"
            local top_py = row * 2
            local bot_py = row * 2 + 1

            -- Left: Image Half-Block Rendering
            for col = 0, img_display_w - 1 do
                -- Map cell (col, row) to image coordinates
                local top_img_x = math.floor(col * self.img.width / img_display_w)
                local top_img_y = math.floor(top_py * self.img.height / img_display_h)
                local bot_img_x = top_img_x
                local bot_img_y = math.floor(bot_py * self.img.height / img_display_h)

                local top_val = self.img:get_gray(top_img_x, top_img_y)
                local bot_val = self.img:get_gray(bot_img_x, bot_img_y)

                -- Threshold overlay in threshold mode
                local is_top_thresh = (self.mode == "threshold" and top_val >= self.threshold_val)
                local is_bot_thresh = (self.mode == "threshold" and bot_val >= self.threshold_val)

                local tr, tg, tb
                local br, bg, bb

                if is_top_thresh then
                    tr, tg, tb = 255, 30, 30 -- Highlight red
                else
                    tr, tg, tb = self:map_display_color(top_val)
                end

                if is_bot_thresh then
                    br, bg, bb = 255, 30, 30
                else
                    br, bg, bb = self:map_display_color(bot_val)
                end

                -- Screen-space ROI Box Overlay
                if self.roi.active then
                    local in_top_border = (col >= drx1 and col <= drx2 and (top_py == dry1 or top_py == dry2)) or
                                          (top_py >= dry1 and top_py <= dry2 and (col == drx1 or col == drx2))
                    local in_bot_border = (col >= drx1 and col <= drx2 and (bot_py == dry1 or bot_py == dry2)) or
                                          (bot_py >= dry1 and bot_py <= dry2 and (col == drx1 or col == drx2))
                    if in_top_border then tr, tg, tb = 0, 255, 255 end
                    if in_bot_border then br, bg, bb = 0, 255, 255 end
                end

                -- Screen-space High-Visibility Crosshair & Reticle
                tr, tg, tb = apply_crosshair(tr, tg, tb, col, top_py)
                br, bg, bb = apply_crosshair(br, bg, bb, col, bot_py)

                -- UTF-8 '▄' (bottom half block): foreground = bottom px, background = top px
                row_str = row_str .. string.format("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▄\27[0m",
                    br, bg, bb, tr, tg, tb)
            end

            -- Middle Divider
            row_str = row_str .. "\27[1;37;44m│\27[0m"

            -- Right: Inspector Content
            local r_text = right_lines[row + 1] or ""
            row_str = row_str .. " " .. r_text
            local vis_len = #r_text:gsub("\27%[[%d;]*m", "") + 1
            if vis_len < insp_w then
                row_str = row_str .. string.rep(" ", insp_w - vis_len)
            end

            row_str = row_str .. "\27[1;37;44m│\27[0m\27[K\n"
            emit(row_str)
        end

        -- 5. Bottom Status Bar & Hotkeys
        emit("\27[1;37;44m├" .. string.rep("─", cols - 2) .. "┤\27[0m\27[K\n")
        local hotkeys = " [Arrows] Probe  [r] ROI  [p] Profile  [l] LUT  [w/b] W/L  [a] Auto  [t] Thresh  [f] Filter  [q] Quit"
        if #hotkeys < cols - 2 then
            hotkeys = hotkeys .. string.rep(" ", cols - 2 - #hotkeys)
        end
        emit("\27[1;30;47m" .. hotkeys .. "\27[0m\27[K\n")
        local status_line = " " .. self.status_msg
        if #status_line < cols - 2 then
            status_line = status_line .. string.rep(" ", cols - 2 - #status_line)
        end
        emit("\27[1;37;44m└" .. status_line .. "┘\27[0m\27[K")

        return table.concat(lines)
    end

    function app:render_profile_modal(cols, rows)
        local lines = {}
        local emit = function(s) table.insert(lines, s) end
        local prof = compute_line_profile(self.img, self.profile_horizontal, self.profile_horizontal and self.probe_y or self.probe_x)

        emit("\27[1;37;44m┌─ 1D Intensity Cross-Section Profile [" .. (self.profile_horizontal and "Horizontal" or "Vertical") .. "] ─ [Esc] Close ─┐\27[0m\27[K\n")

        local plot_h = rows - 8
        local plot_w = cols - 12
        local spark_chars = { " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

        for r = plot_h, 1, -1 do
            local y_val = math.floor((r / plot_h) * 255)
            local row_str = string.format(" %3d │ ", y_val)
            for c = 1, plot_w do
                local sample_idx = math.max(1, math.min(prof.length, math.floor((c / plot_w) * prof.length)))
                local val = prof.data[sample_idx] or 0
                if val >= y_val then
                    if math.abs(val - prof.half_max) < 8 then
                        row_str = row_str .. "\27[1;35m█\27[0m" -- Highlight Half-Max
                    else
                        row_str = row_str .. "\27[36m█\27[0m"
                    end
                else
                    row_str = row_str .. " "
                end
            end
            emit(row_str .. "\27[K\n")
        end

        emit("   0 └──" .. string.rep("─", plot_w) .. "\27[K\n")
        emit(string.format(" Statistics: Peak: \27[1;33m%d\27[0m @ Pos %d | Baseline: %d | Half-Max: %.1f | \27[1;35mFWHM: %d px\27[0m\27[K\n",
            prof.peak_val, prof.peak_pos, prof.baseline, prof.half_max, prof.fwhm))
        emit(" Controls: [v] Toggle Horiz/Vert Scan  [Up/Down] Shift Slice  [Esc] Return to Viewer\27[K")

        return table.concat(lines)
    end

    function app:render_threshold_modal(cols, rows)
        local lines = {}
        local emit = function(s) table.insert(lines, s) end
        local parts = analyze_particles(self.img, self.threshold_val)

        emit("\27[1;37;44m┌─ Threshold & Connected Component Particle Analysis ─────────────────────── [Esc] Exit ─┐\27[0m\27[K\n")
        emit(string.format(" Cutoff Threshold: \27[1;33mT = %d\27[0m  Total Particles: \27[1;32m%d blobs\27[0m  Total Area: %d px  Avg: %.1f px\27[K\n",
            self.threshold_val, parts.count, parts.total_area, parts.avg_area))
        emit(" ────────────────────────────────────────────────────────────────────────────────────────\27[K\n")
        emit("  ID    Center (X, Y)       Bounding Box (W x H)    Area (px)    Fraction of Image\27[K\n")
        emit(" ────────────────────────────────────────────────────────────────────────────────────────\27[K\n")

        local list_limit = math.min(#parts.blobs, rows - 10)
        for i = 1, list_limit do
            local b = parts.blobs[i]
            local pct = (b.area / (self.img.width * self.img.height)) * 100.0
            emit(string.format("  #%02d   (X: %3d, Y: %3d)    %3d x %3d px             %5d px        %4.2f%%\27[K\n",
                i, b.cx, b.cy, b.w, b.h, b.area, pct))
        end

        for _ = 1, math.max(0, rows - 10 - list_limit) do
            emit("\27[K\n")
        end

        emit(" Controls: [Left/Right] Adjust Cutoff  [a] Otsu Auto-Calculate  [Esc] Return to Viewer\27[K")
        return table.concat(lines)
    end

    function app:render_help_modal(cols, rows)
        local lines = {}
        local emit = function(s) table.insert(lines, s) end

        emit("\27[1;37;44m┌───────────────────────── ffi_imagej Keyboard Controls ─────────────────────────┐\27[0m\27[K\n")
        emit("│                                                                                │\27[K\n")
        emit("│  NAVIGATION & PROBE                                                            │\27[K\n")
        emit("│    Arrow keys / h j k l       Move pixel probe crosshair                       │\27[K\n")
        emit("│                                                                                │\27[K\n")
        emit("│  SCIENTIFIC ANALYSIS                                                           │\27[K\n")
        emit("│    r                          Toggle Region of Interest (ROI) box on/off       │\27[K\n")
        emit("│    p                          1D Intensity Line Profile (with FWHM analysis)   │\27[K\n")
        emit("│    l                          Cycle Lookup Tables (Grayscale, Fire, Viridis..) │\27[K\n")
        emit("│    w / b                      Window & Level (Contrast / Brightness) adjust    │\27[K\n")
        emit("│    a                          Auto-Contrast (0.35% ImageJ saturation clip)     │\27[K\n")
        emit("│    t                          Threshold & Connected Component Particle Counter │\27[K\n")
        emit("│    f                          Cycle Spatial Filter (Median, Gaussian Blur, etc)│\27[K\n")
        emit("│    1                          Reset image to raw original                      │\27[K\n")
        emit("│                                                                                │\27[K\n")
        emit("│  SYSTEM                                                                        │\27[K\n")
        emit("│    ?                          Toggle this Help dialog                          │\27[K\n")
        emit("│    q / Esc                    Exit application                                 │\27[K\n")
        emit("│                                                                                │\27[K\n")
        emit("└──────────────────────────── Press [Enter] or [Esc] to Close ───────────────────┘\27[K")

        return table.concat(lines)
    end

    function app:render(cols, rows)
        if self.show_help then
            return self:render_help_modal(cols, rows)
        elseif self.mode == "profile" then
            return self:render_profile_modal(cols, rows)
        elseif self.mode == "threshold" then
            return self:render_threshold_modal(cols, rows)
        else
            return self:render_frame(cols, rows)
        end
    end

    function app:handle_key(key)
        if key == "CTRL_C" or key == "q" then
            return false
        elseif key == "ESC" then
            if self.show_help then
                self.show_help = false
            elseif self.mode ~= "normal" then
                self.mode = "normal"
            else
                return false
            end
        elseif key == "?" then
            self.show_help = not self.show_help
        elseif self.show_help then
            if key == "ENTER" or key == "SPACE" then self.show_help = false end
        elseif self.mode == "profile" then
            if key == "v" then
                self.profile_horizontal = not self.profile_horizontal
            elseif key == "UP" or key == "k" then
                if self.profile_horizontal then
                    self.probe_y = math.max(0, self.probe_y - 1)
                else
                    self.probe_x = math.max(0, self.probe_x - 1)
                end
            elseif key == "DOWN" or key == "j" then
                if self.profile_horizontal then
                    self.probe_y = math.min(self.img.height - 1, self.probe_y + 1)
                else
                    self.probe_x = math.min(self.img.width - 1, self.probe_x + 1)
                end
            end
        elseif self.mode == "threshold" then
            if key == "LEFT" or key == "h" then
                self.threshold_val = math.max(0, self.threshold_val - 4)
            elseif key == "RIGHT" or key == "l" then
                self.threshold_val = math.min(255, self.threshold_val + 4)
            elseif key == "a" then
                self.threshold_val = compute_otsu_threshold(self.img)
            end
        else
            -- Normal Viewport Keybindings
            if key == "UP" or key == "k" then
                self.probe_y = math.max(0, self.probe_y - 1)
            elseif key == "DOWN" or key == "j" then
                self.probe_y = math.min(self.img.height - 1, self.probe_y + 1)
            elseif key == "LEFT" or key == "h" then
                self.probe_x = math.max(0, self.probe_x - 1)
            elseif key == "RIGHT" or key == "l" then
                self.probe_x = math.min(self.img.width - 1, self.probe_x + 1)
            elseif key == "K" then
                self.probe_y = math.max(0, self.probe_y - 8)
            elseif key == "J" then
                self.probe_y = math.min(self.img.height - 1, self.probe_y + 8)
            elseif key == "H" then
                self.probe_x = math.max(0, self.probe_x - 8)
            elseif key == "L" then
                self.probe_x = math.min(self.img.width - 1, self.probe_x + 8)
            elseif key == "r" then
                self.roi.active = not self.roi.active
                if self.roi.active then
                    self.roi.x1 = math.max(0, self.probe_x - 15)
                    self.roi.y1 = math.max(0, self.probe_y - 10)
                    self.roi.x2 = math.min(self.img.width - 1, self.probe_x + 15)
                    self.roi.y2 = math.min(self.img.height - 1, self.probe_y + 10)
                    self.status_msg = "ROI activated around cursor."
                else
                    self.status_msg = "ROI cleared."
                end
            elseif key == "p" then
                self.mode = "profile"
            elseif key == "t" then
                self.mode = "threshold"
                self.threshold_val = compute_otsu_threshold(self.img)
            elseif key == "l" then
                self.lut_idx = (self.lut_idx % #LUT_NAMES) + 1
                self.status_msg = "LUT changed to: " .. LUT_NAMES[self.lut_idx]
            elseif key == "w" then
                self.win_high = math.max(self.win_low + 5, self.win_high - 10)
                self.status_msg = string.format("Window adjusted: %d - %d", self.win_low, self.win_high)
            elseif key == "b" then
                self.win_low = math.min(self.win_high - 5, self.win_low + 10)
                self.status_msg = string.format("Level adjusted: %d - %d", self.win_low, self.win_high)
            elseif key == "a" then
                self.win_low, self.win_high = compute_auto_window_level(self.img)
                self.status_msg = string.format("Auto W/L applied (0.35%% clip): %d - %d", self.win_low, self.win_high)
            elseif key == "f" then
                self.img = apply_filter(self.img, "median")
                self.status_msg = "Applied 3x3 Median Filter (noise removal)."
            elseif key == "1" then
                self.img = self.raw_img:clone()
                self.win_low, self.win_high = compute_auto_window_level(self.img)
                self.status_msg = "Reset to original raw image."
            end
        end
        return true
    end

    return app
end

-- =============================================================================
-- 6. CLI Entry Point & Interactive Event Loop
-- =============================================================================
-- =============================================================================
-- 6. CLI Help & Argument Options
-- =============================================================================
local CLI_HELP = table.concat({
    "ffi_imagej - Scientific Image Viewer & Analysis TUI in LuaJIT FFI",
    "Inspired by ImageJ (National Institutes of Health)",
    "",
    "Usage: luajit ffi_imagej.lua [OPTIONS] [IMAGE_FILE]",
    "",
    "Arguments:",
    "  IMAGE_FILE             Path to image file (PGM, PPM, or PNG/JPG/TIFF).",
    "                         If omitted, loads procedural cell colonies.",
    "",
    "Options:",
    "  -h, --help, /?         Show this help message and exit.",
    "  -t, --test             Headless render test (outputs single frame and exits).",
    "  --target=TARGET        Generate synthetic target: 'cells' (default), 'usaf', or 'gradient'.",
    "  --lut=LUT_NAME         Set initial colormap: Grayscale, Fire, Viridis, Cool, Turbo, Green.",
    "  --threshold=N          Set initial segmentation threshold (0-255).",
    "",
    "Interactive Keybindings:",
    "  Arrow keys / h j k l   Move pixel probe crosshair (+)",
    "  r                      Toggle Region of Interest (ROI) box",
    "  p                      1D Intensity Profile (Horiz/Vert slice with FWHM)",
    "  l                      Cycle scientific Lookup Tables (LUTs)",
    "  w / b                  Adjust Window / Level (Contrast / Brightness)",
    "  a                      Auto-Contrast (0.35% ImageJ saturation clip)",
    "  t                      Threshold & Particle / Connected Component analysis",
    "  f                      Apply 3x3 Median noise reduction filter",
    "  1                      Reset to raw original image",
    "  ?                      Toggle in-app Help dialog",
    "  q / Esc                Exit viewer",
    "",
    "Examples:",
    "  luajit ffi_imagej.lua                           # Open with procedural cell colonies",
    "  luajit ffi_imagej.lua --target=usaf             # View USAF-1951 resolution target",
    "  luajit ffi_imagej.lua sample.pgm                # Open local scientific PGM image",
    "  luajit ffi_imagej.lua --lut=Fire cells.pgm      # Open with Fire false-color palette",
    "  luajit ffi_imagej.lua --help                    # Show this help text"
}, "\n")

local function main(args)
    args = args or {}
    local filepath = nil
    local target_type = nil
    local initial_lut = nil
    local initial_thresh = nil
    local is_test = false

    for _, a in ipairs(args) do
        if a == "-h" or a == "--help" or a == "/?" then
            io.write(CLI_HELP, "\n")
            return 0
        elseif a == "-t" or a == "--test" then
            is_test = true
        elseif a:match("^%-%-target=") then
            target_type = a:match("^%-%-target=(%w+)$")
        elseif a:match("^%-%-lut=") then
            initial_lut = a:match("^%-%-lut=(.+)$")
        elseif a:match("^%-%-threshold=") then
            initial_thresh = tonumber(a:match("^%-%-threshold=(%d+)$"))
        elseif not a:match("^%-") and not filepath then
            filepath = a
        end
    end

    local img
    local filename = "cell_colony_procedural.pgm"

    if target_type == "usaf" then
        img = ImageBuffer.generate_target(128, 128)
        filename = "usaf_target.pgm"
    elseif target_type == "gradient" then
        img = ImageBuffer.generate_target(128, 128)
        filename = "gradient_wedge.pgm"
    elseif filepath then
        local err
        img, err = ImageBuffer.load_image(filepath)
        if not img then
            io.stderr:write(string.format("Error loading '%s': %s\nFalling back to procedural target.\n", filepath, tostring(err)))
            img = ImageBuffer.generate_cells(128, 128)
        else
            filename = filepath:match("[^/\\]+$") or filepath
        end
    else
        img = ImageBuffer.generate_cells(128, 128)
    end

    local app = build_tui_app(img, filename)

    if initial_lut then
        for idx, name in ipairs(LUT_NAMES) do
            if name:lower() == initial_lut:lower() then
                app.lut_idx = idx
                break
            end
        end
    end

    if initial_thresh then
        app.threshold_val = math.max(0, math.min(255, initial_thresh))
    end

    -- Headless test mode
    if is_test or not is_stdin_tty() then
        local cols, rows = 100, 30
        local frame = app:render(cols, rows)
        if #frame > 100 then
            io.write(frame)
            return 0
        end
        return 1
    end

    enable_raw_mode()
    io.write("\27[?1049h\27[?25l\27[?7l") -- Alt buffer, hide cursor, disable line wrap
    io.flush()

    local running = true
    local last_cols, last_rows = 0, 0

    while running do
        local cols, rows = get_terminal_size()
        if cols ~= last_cols or rows ~= last_rows then
            last_cols = cols
            last_rows = rows
            io.write("\27[2J") -- Clear once on resize
        end

        local frame = app:render(cols, rows)
        io.write("\27[?2026h\27[1;1H" .. frame .. "\27[?2026l")
        io.flush()

        local key = read_key_nonblocking()
        if key then
            running = app:handle_key(key)
        else
            sleep_ms(20)
        end
    end

    -- Graceful Terminal Restoration
    io.write("\27[?7h\27[?25h\27[?1049l")
    io.flush()
    disable_raw_mode()
    return 0
end

-- Export module functions for tests
local M = {
    ImageBuffer = ImageBuffer,
    compute_roi_stats = compute_roi_stats,
    compute_line_profile = compute_line_profile,
    compute_histogram = compute_histogram,
    compute_auto_window_level = compute_auto_window_level,
    compute_otsu_threshold = compute_otsu_threshold,
    analyze_particles = analyze_particles,
    apply_filter = apply_filter,
    LUTS = LUTS,
    LUT_NAMES = LUT_NAMES,
    build_tui_app = build_tui_app,
    main = main
}

local caller = debug.getinfo(2, "f")
if caller and caller.func == require then
    return M
end
if ... and (...) == "ffi_imagej" then
    return M
end

return main(arg or { ... })
