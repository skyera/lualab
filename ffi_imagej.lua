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
   - Universal pipe loader via FFmpeg / ImageMagick for PNG, JPG, TIFF, BMP, WEBP.
2. Scientific ImageJ Analysis Engine:
   - Live Pixel Probe & Reticle: Coordinates, normalized pos, raw RGB & intensity.
   - Interactive 2-Point ROI Measure: Area, Mean, StdDev, Min, Max, Median, IntDen.
   - 1D Line Profile (Plot Profile): Horizontal/Vertical scan, Peak, FWHM analysis.
   - Real-time 256-bin Histogram with bidirectional Window/Level and Auto-Contrast.
   - Truecolor RGB + Scientific Lookup Tables (LUTs): Grayscale, Fire, Viridis,
     Cool, Turbo, Green, and Invert.
   - Live Split-Pane Thresholding & Particle Analysis: Otsu's method and 8-way
     connected component blob labeling with live red segmentation overlay.
   - Spatial Convolutions: 3x3 Median, Gaussian Blur, Sobel Edge, Sharpen, Invert.
   - Verified Export: Save CSV measurement reports and processed PPM images.
3. Flicker-Free Terminal UI:
   - 24-bit Truecolor ANSI half-block ('▄') rendering with interactive Zoom & Pan.
   - Synchronized atomic updates (\27[?2026h ... \27[?2026l) with universal \27[K.
   - Zero-CPU idle loop (renders only on input or terminal resize).
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

-- 7. Invert (Negative Grayscale)
LUTS["Invert"] = function(v)
    local inv = 255 - v
    return inv, inv, inv
end

local LUT_NAMES = { "Grayscale", "Fire", "Viridis", "Cool", "Turbo", "Green", "Invert" }
local FILTER_NAMES = { "none", "median", "blur", "sobel", "sharpen" }
local MORPH_NAMES = { "none", "erode", "dilate", "open", "close" }
local CHANNEL_MODES = { "composite", "red", "green", "blue", "gray" }

local FILTER_DESCRIPTIONS = {
    none    = "No spatial filter (raw pixel intensities)",
    median  = "3x3 non-linear rank filter — removes salt-and-pepper noise while keeping sharp edges",
    blur    = "3x3 Gaussian smoothing kernel — reduces high-frequency sensor grain",
    sobel   = "3x3 Sobel gradient operator — highlights horizontal & vertical boundary edges",
    sharpen = "3x3 Laplacian unsharp kernel — enhances local edge contrast"
}

local MORPH_DESCRIPTIONS = {
    none   = "No morphological operation",
    erode  = "3x3 local minimum — shrinks bright spots & removes isolated speckles",
    dilate = "3x3 local maximum — expands bright regions & bridges narrow gaps",
    open   = "Erode then Dilate — removes small bright speckles while preserving object size",
    close  = "Dilate then Erode — fills small dark holes inside bright objects"
}

local LUT_DESCRIPTIONS = {
    Grayscale = "1:1 linear luminance mapping (0=Black to 255=White)",
    Fire      = "NIH ImageJ thermal colormap (Black -> Red -> Orange -> Yellow -> White)",
    Viridis   = "Perceptually uniform scientific colormap (Dark Purple -> Teal -> Yellow)",
    Cool      = "Dual-tone cyan-to-magenta gradient",
    Turbo     = "Smooth high-contrast rainbow colormap",
    Green     = "GFP fluorescence microscopy channel (0, G, 0)",
    Invert    = "Photographic negative grayscale (255 - v)"
}

local CHANNEL_DESCRIPTIONS = {
    composite = "Full 24-bit RGB composite color",
    red       = "Isolated Red channel (R) — all stats & histograms measure Red intensity",
    green     = "Isolated Green channel (G) — all stats & histograms measure Green intensity",
    blue      = "Isolated Blue channel (B) — all stats & histograms measure Blue intensity",
    gray      = "Weighted Rec.601 luminance (Y = 0.299R + 0.587G + 0.114B)"
}

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
        self.data[idx]     = math.max(0, math.min(255, r or 0))
        self.data[idx + 1] = math.max(0, math.min(255, g or r or 0))
        self.data[idx + 2] = math.max(0, math.min(255, b or r or 0))
    else
        local v = r
        if g and b then
            v = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
        end
        self.data[y * self.width + x] = math.max(0, math.min(255, v or 0))
    end
end

function ImageBuffer:clone()
    local copy = ImageBuffer.new(self.width, self.height, self.is_rgb)
    ffi.copy(copy.data, self.data, self.size)
    return copy
end

function ImageBuffer:extract_channel(mode)
    if not mode or mode == "composite" then
        return self:clone()
    end
    local out = ImageBuffer.new(self.width, self.height, false)
    for y = 0, self.height - 1 do
        for x = 0, self.width - 1 do
            if mode == "red" then
                local r = self:get_pixel(x, y)
                out:set_pixel(x, y, r)
            elseif mode == "green" then
                local _, g = self:get_pixel(x, y)
                out:set_pixel(x, y, g)
            elseif mode == "blue" then
                local _, _, b = self:get_pixel(x, y)
                out:set_pixel(x, y, b)
            else
                out:set_pixel(x, y, self:get_gray(x, y))
            end
        end
    end
    return out
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
        local img = ImageBuffer.load_pnm(filepath)
        if img then return img end
    end

    -- 2. Pipe fallback via FFmpeg or ImageMagick
    local devnull = is_windows and "nul" or "/dev/null"
    local popen_mode = is_windows and "rb" or "r"
    local cmd = string.format('ffmpeg -nostdin -loglevel quiet -i %q -f image2pipe -vcodec ppm - 2>%s || magick %q ppm:- 2>%s',
        filepath, devnull, filepath, devnull)
    local pipe = io.popen(cmd, popen_mode)
    if pipe then
        local img = ImageBuffer.parse_pnm_handle(pipe)
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
    local rx1 = (roi and roi.x1) or 0
    local ry1 = (roi and roi.y1) or 0
    local rx2 = (roi and roi.x2) or (img.width - 1)
    local ry2 = (roi and roi.y2) or (img.height - 1)

    local x1 = math.max(0, math.min(rx1, rx2))
    local x2 = math.min(img.width - 1, math.max(rx1, rx2))
    local y1 = math.max(0, math.min(ry1, ry2))
    local y2 = math.min(img.height - 1, math.max(ry1, ry2))

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
            min = 0, max = 0, median = 0, mode = 0, int_den = 0,
            x1 = x1, y1 = y1, x2 = x2, y2 = y2
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

-- Point-to-Point Euclidean Ruler & Angle Measurement
local function compute_ruler(img, x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local angle_deg = math.deg(math.atan2(-dy, dx))
    local v1 = img:get_gray(x1, y1)
    local v2 = img:get_gray(x2, y2)
    return {
        x1 = x1,
        y1 = y1,
        x2 = x2,
        y2 = y2,
        dx = dx,
        dy = dy,
        dist = dist,
        angle_deg = angle_deg,
        v1 = v1,
        v2 = v2,
        dv = v2 - v1
    }
end

-- 3x3 Spatial Convolution Filters, Morphological Ops, Equalization & Invert
local function apply_filter(img, filter_name)
    if filter_name == "none" or not filter_name then
        return img:clone()
    end

    local w = img.width
    local h = img.height
    local out = ImageBuffer.new(w, h, false)

    if filter_name == "invert" then
        local inv_out = ImageBuffer.new(w, h, img.is_rgb)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                if img.is_rgb then
                    local r, g, b = img:get_pixel(x, y)
                    inv_out:set_pixel(x, y, 255 - r, 255 - g, 255 - b)
                else
                    inv_out:set_pixel(x, y, 255 - img:get_gray(x, y))
                end
            end
        end
        return inv_out
    elseif filter_name == "median" then
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
    elseif filter_name == "sharpen" then
        -- 3x3 Unsharp / Laplacian Sharpen: [0 -1 0; -1 5 -1; 0 -1 0]
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local center = img:get_gray(x, y) * 5
                local top    = img:get_gray(x, math.max(0, y - 1))
                local bot    = img:get_gray(x, math.min(h - 1, y + 1))
                local left   = img:get_gray(math.max(0, x - 1), y)
                local right  = img:get_gray(math.min(w - 1, x + 1), y)
                local val = math.max(0, math.min(255, center - top - bot - left - right))
                out:set_pixel(x, y, val)
            end
        end
    elseif filter_name == "erode" or filter_name == "dilate" then
        local is_erode = (filter_name == "erode")
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local best = is_erode and 255 or 0
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local px = math.max(0, math.min(w - 1, x + dx))
                        local py = math.max(0, math.min(h - 1, y + dy))
                        local v = img:get_gray(px, py)
                        if is_erode then
                            if v < best then best = v end
                        else
                            if v > best then best = v end
                        end
                    end
                end
                out:set_pixel(x, y, best)
            end
        end
    elseif filter_name == "open" then
        return apply_filter(apply_filter(img, "erode"), "dilate")
    elseif filter_name == "close" then
        return apply_filter(apply_filter(img, "dilate"), "erode")
    elseif filter_name == "equalize" then
        local hist, total = compute_histogram(img)
        local cdf = {}
        local acc = 0
        local cdf_min = nil
        for i = 0, 255 do
            acc = acc + hist[i]
            cdf[i] = acc
            if acc > 0 and not cdf_min then
                cdf_min = acc
            end
        end
        cdf_min = cdf_min or 0
        local denom = math.max(1, total - cdf_min)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local v = img:get_gray(x, y)
                local eq = math.floor(((cdf[v] - cdf_min) / denom) * 255 + 0.5)
                out:set_pixel(x, y, math.max(0, math.min(255, eq)))
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
        roi = {
            x1 = 10,
            y1 = 10,
            x2 = 50,
            y2 = 40,
            active = false,
            state = "none" -- "none", "sizing", "locked"
        },
        roi_state = "none",
        ruler = {
            x1 = 0,
            y1 = 0,
            x2 = 0,
            y2 = 0,
            active = false,
            state = "none" -- "none", "measuring", "locked"
        },
        measurement_log = {},
        channel_idx = 1, -- 1: composite, 2: red, 3: green, 4: blue, 5: gray
        lut_idx = 1, -- 1: Grayscale, 2: Fire, 3: Viridis, etc.
        rgb_passthrough = initial_img.is_rgb, -- Truecolor RGB display when lut_idx == 1
        filter_idx = 1, -- 1: none, 2: median, 3: blur, 4: sobel, 5: sharpen
        morph_idx = 1, -- 1: none, 2: erode, 3: dilate, 4: open, 5: close
        equalized = false,
        inverted = false,
        gamma = 1.0,
        win_low = 0,
        win_high = 255,
        win_width = 255,
        win_level = 127,
        zoom = 1.0,
        pan_x = 0,
        pan_y = 0,
        mode = "normal", -- "normal", "profile", "threshold", "threshold_table", "surface3d"
        profile_horizontal = true,
        threshold_val = 128,
        show_help = false,
        help_page = 1,
        status_msg = "Ready. Arrows: Probe | [+/-] Zoom | [r] ROI | [d] Ruler | [l] LUT | [1] Reset | [?] Help"
    }

    function app:sync_wl()
        self.win_width = math.max(1, self.win_high - self.win_low)
        self.win_level = math.floor((self.win_high + self.win_low) / 2)
    end

    -- Auto W/L on startup
    app.win_low, app.win_high = compute_auto_window_level(app.img)
    app:sync_wl()

    function app:stretch_channel(v)
        local norm = v / 255.0
        if self.win_high > self.win_low then
            norm = (v - self.win_low) / (self.win_high - self.win_low)
        end
        norm = math.max(0.0, math.min(1.0, norm))
        if math.abs(self.gamma - 1.0) > 0.001 then
            norm = math.pow(norm, self.gamma)
        end
        return math.max(0, math.min(255, math.floor(norm * 255 + 0.5)))
    end

    function app:map_display_color(gray_val)
        local stretched = self:stretch_channel(gray_val)
        local lut_fn = LUTS[LUT_NAMES[self.lut_idx]] or LUTS["Grayscale"]
        return lut_fn(stretched)
    end

    function app:get_display_rgb(x, y)
        local ch_mode = CHANNEL_MODES[self.channel_idx] or "composite"
        if self.img.is_rgb and self.rgb_passthrough and self.lut_idx == 1 and ch_mode == "composite" then
            local r, g, b = self.img:get_pixel(x, y)
            return self:stretch_channel(r), self:stretch_channel(g), self:stretch_channel(b)
        end
        local gray_val = self.img:get_gray(x, y)
        if self.lut_idx == 1 then
            local s = self:stretch_channel(gray_val)
            if ch_mode == "red" then
                return s, 0, 0
            elseif ch_mode == "green" then
                return 0, s, 0
            elseif ch_mode == "blue" then
                return 0, 0, s
            end
        end
        return self:map_display_color(gray_val)
    end

    function app:rebuild_filtered_image()
        local ch_mode = CHANNEL_MODES[self.channel_idx] or "composite"
        local processed = self.raw_img:extract_channel(ch_mode)
        local fname = FILTER_NAMES[self.filter_idx] or "none"
        if fname ~= "none" then
            processed = apply_filter(processed, fname)
        end
        local mname = MORPH_NAMES[self.morph_idx] or "none"
        if mname ~= "none" then
            processed = apply_filter(processed, mname)
        end
        if self.equalized then
            processed = apply_filter(processed, "equalize")
        end
        if self.inverted then
            processed = apply_filter(processed, "invert")
        end
        self.img = processed
    end

    function app:record_measurement()
        local full_roi = { x1 = 0, y1 = 0, x2 = self.img.width - 1, y2 = self.img.height - 1 }
        local active_roi = self.roi.active and self.roi or full_roi
        local stats = compute_roi_stats(self.img, active_roi)
        local entry = {
            id = #self.measurement_log + 1,
            channel = CHANNEL_MODES[self.channel_idx] or "composite",
            x1 = stats.x1,
            y1 = stats.y1,
            x2 = stats.x2,
            y2 = stats.y2,
            area = stats.area,
            mean = stats.mean,
            std_dev = stats.std_dev,
            min = stats.min,
            max = stats.max,
            median = stats.median,
            int_den = stats.int_den
        }
        table.insert(self.measurement_log, entry)
        return entry
    end

    function app:export_data(csv_path, ppm_path)
        csv_path = csv_path or "imagej_measurements.csv"
        ppm_path = ppm_path or "imagej_export.ppm"

        -- 1. Write CSV Report
        local full_roi = { x1 = 0, y1 = 0, x2 = self.img.width - 1, y2 = self.img.height - 1 }
        local active_roi = self.roi.active and self.roi or full_roi
        local stats = compute_roi_stats(self.img, active_roi)
        local prof = compute_line_profile(self.img, self.profile_horizontal,
            self.profile_horizontal and self.probe_y or self.probe_x)
        local parts = analyze_particles(self.img, self.threshold_val)

        local cf = io.open(csv_path, "wb")
        if not cf then
            return false, "Cannot open CSV for writing: " .. tostring(csv_path)
        end
        cf:write("Metric,Value,Units_or_Notes\n")
        cf:write(string.format("Filename,%s,%dx%d\n", self.filename, self.img.width, self.img.height))
        cf:write(string.format("Channel,%s,active_channel\n", CHANNEL_MODES[self.channel_idx] or "composite"))
        cf:write(string.format("Gamma,%.2f,nonlinear\n", self.gamma))
        cf:write(string.format("Probe_X,%d,px\n", self.probe_x))
        cf:write(string.format("Probe_Y,%d,px\n", self.probe_y))
        cf:write(string.format("ROI_Active,%s,[%d;%d to %d;%d]\n",
            tostring(self.roi.active), stats.x1, stats.y1, stats.x2, stats.y2))
        cf:write(string.format("Area,%d,px^2\n", stats.area))
        cf:write(string.format("Mean,%.4f,intensity\n", stats.mean))
        cf:write(string.format("StdDev,%.4f,intensity\n", stats.std_dev))
        cf:write(string.format("Min,%d,intensity\n", stats.min))
        cf:write(string.format("Max,%d,intensity\n", stats.max))
        cf:write(string.format("Median,%d,intensity\n", stats.median))
        cf:write(string.format("Integrated_Density,%d,sum\n", stats.int_den))
        cf:write(string.format("Profile_Peak,%d,at_pos_%d\n", prof.peak_val, prof.peak_pos))
        cf:write(string.format("Profile_FWHM,%d,px\n", prof.fwhm))
        cf:write(string.format("Threshold_Cutoff,%d,0-255\n", self.threshold_val))
        cf:write(string.format("Particle_Count,%d,blobs\n", parts.count))
        cf:write(string.format("Particle_Total_Area,%d,px^2\n", parts.total_area))

        if #self.measurement_log > 0 then
            cf:write("\nLog_ID,Channel,X1,Y1,X2,Y2,Area,Mean,StdDev,Min,Max,Median,IntDen\n")
            for _, m in ipairs(self.measurement_log) do
                cf:write(string.format("%d,%s,%d,%d,%d,%d,%d,%.4f,%.4f,%d,%d,%d,%d\n",
                    m.id, m.channel, m.x1, m.y1, m.x2, m.y2,
                    m.area, m.mean, m.std_dev, m.min, m.max, m.median, m.int_den))
            end
        end
        cf:close()

        -- 2. Write Binary P6 PPM Image
        local pf = io.open(ppm_path, "wb")
        if not pf then
            return false, "Cannot open PPM for writing: " .. tostring(ppm_path)
        end
        pf:write(string.format("P6\n%d %d\n255\n", self.img.width, self.img.height))
        local row_bytes = ffi.new("uint8_t[?]", self.img.width * 3)
        for y = 0, self.img.height - 1 do
            for x = 0, self.img.width - 1 do
                local r, g, b = self:get_display_rgb(x, y)
                local idx = x * 3
                row_bytes[idx]     = r
                row_bytes[idx + 1] = g
                row_bytes[idx + 2] = b
            end
            pf:write(ffi.string(row_bytes, self.img.width * 3))
        end
        pf:close()

        -- 3. Verify Writes Before Reporting Success (per AGENTS.md)
        local v_csv = io.open(csv_path, "rb")
        if not v_csv then return false, "Verification failed: CSV not found" end
        local csv_head = v_csv:read(16) or ""
        v_csv:close()
        if not csv_head:match("^Metric,Value") then
            return false, "Verification failed: CSV header mismatch"
        end

        local v_ppm = io.open(ppm_path, "rb")
        if not v_ppm then return false, "Verification failed: PPM not found" end
        local ppm_head = v_ppm:read(2) or ""
        v_ppm:close()
        if ppm_head ~= "P6" then
            return false, "Verification failed: PPM magic mismatch"
        end

        return true, string.format("Verified export: %s & %s", csv_path, ppm_path)
    end

    function app:get_viewport_bounds()
        local vis_w = math.max(8, math.floor(self.img.width / self.zoom))
        local vis_h = math.max(8, math.floor(self.img.height / self.zoom))
        local vx0 = math.max(0, math.min(self.img.width - vis_w, math.floor(self.probe_x - vis_w / 2)))
        local vy0 = math.max(0, math.min(self.img.height - vis_h, math.floor(self.probe_y - vis_h / 2)))
        return vx0, vy0, vis_w, vis_h
    end

    function app:render_frame(cols, rows)
        local lines = {}
        local emit = function(s) table.insert(lines, s) end

        cols = math.max(80, cols)
        rows = math.max(24, rows)

        local pane_w = math.floor(cols * 0.52)
        local insp_w = cols - pane_w - 3
        local view_h = rows - 4

        -- 1. Top Header
        local ch_mode = CHANNEL_MODES[self.channel_idx] or "composite"
        local lut_label = (self.img.is_rgb and self.rgb_passthrough and self.lut_idx == 1 and ch_mode == "composite")
            and "RGB" or LUT_NAMES[self.lut_idx]
        if ch_mode ~= "composite" then
            lut_label = lut_label .. "/" .. ch_mode:upper()
        end
        local filter_name = FILTER_NAMES[self.filter_idx]
        local morph_name = MORPH_NAMES[self.morph_idx]
        local filter_tag = ""
        if filter_name ~= "none" then filter_tag = filter_tag .. " | Flt:" .. filter_name end
        if morph_name ~= "none" then filter_tag = filter_tag .. " | Mrp:" .. morph_name end
        if self.equalized then filter_tag = filter_tag .. " | EQ" end
        if math.abs(self.gamma - 1.0) > 0.001 then
            filter_tag = filter_tag .. string.format(" | y:%.1f", self.gamma)
        end

        local title = string.format(" ffi_imagej: %s [%dx%d] ", self.filename, self.img.width, self.img.height)
        local mode_tag = string.format(" [%.1fx | %s | LUT:%s%s | W/L:%d-%d] ",
            self.zoom, self.mode:upper(), lut_label, filter_tag, self.win_low, self.win_high)
        local help_tag = " [?] Help "
        local fill_len = math.max(0, cols - #title - #mode_tag - #help_tag - 4)

        emit("\27[1;37;44m┌─" .. title .. string.rep("─", fill_len) .. mode_tag .. help_tag .. "─┐\27[0m\27[K\n")

        -- 2. Gather Inspector Data
        local probe_val = self.img:get_gray(self.probe_x, self.probe_y)
        local raw_r, raw_g, raw_b = self.raw_img:get_pixel(self.probe_x, self.probe_y)
        local pr_r, pr_g, pr_b = self:get_display_rgb(self.probe_x, self.probe_y)

        local full_roi = { x1 = 0, y1 = 0, x2 = self.img.width - 1, y2 = self.img.height - 1 }
        local active_roi = self.roi.active and self.roi or full_roi
        local roi_stats = compute_roi_stats(self.img, active_roi)

        local prof = compute_line_profile(self.img, self.profile_horizontal,
            self.profile_horizontal and self.probe_y or self.probe_x)
        local hist = compute_histogram(self.img)

        -- 3. Pre-format Right Pane Lines
        local right_lines = {}
        local function add_right(str)
            table.insert(right_lines, str)
        end

        add_right(string.format("\27[1;36m── 1. Pixel Probe & Ruler ([d] | %.1fx) ─────\27[0m", self.zoom))
        add_right(string.format(" Pos: (X: \27[1m%3d\27[0m, Y: \27[1m%3d\27[0m)  Norm: %2d%%, %2d%%",
            self.probe_x, self.probe_y,
            math.floor(self.probe_x * 100 / math.max(1, self.img.width)),
            math.floor(self.probe_y * 100 / math.max(1, self.img.height))))
        if self.raw_img.is_rgb then
            add_right(string.format(" Raw RGB: (%3d, %3d, %3d)  Val: \27[1;33m%3d\27[0m (%2.0f%%)",
                raw_r, raw_g, raw_b, probe_val, (probe_val / 255.0) * 100.0))
        else
            add_right(string.format(" Value: \27[1;33m%3d / 255\27[0m  Intensity: \27[1m%2.1f%%\27[0m",
                probe_val, (probe_val / 255.0) * 100.0))
        end
        add_right(string.format(" Display: \27[38;2;%d;%d;%dm██\27[0m RGB(%3d, %3d, %3d) #%02X%02X%02X",
            pr_r, pr_g, pr_b, pr_r, pr_g, pr_b, pr_r, pr_g, pr_b))

        if self.ruler.active then
            local rm = compute_ruler(self.img, self.ruler.x1, self.ruler.y1, self.ruler.x2, self.ruler.y2)
            add_right(string.format(" \27[1;35mRuler:\27[0m (%d,%d)->(%d,%d) \27[1;33mD=%.1f px\27[0m (%.1f deg, dI=%+d)",
                rm.x1, rm.y1, rm.x2, rm.y2, rm.dist, rm.angle_deg, rm.dv))
        else
            add_right("")
        end

        if self.mode == "threshold" then
            -- Live Split-Pane Threshold & Particle Inspector
            local parts = analyze_particles(self.img, self.threshold_val)
            add_right(string.format("\27[1;36m── 2. Threshold Control (Otsu / Manual) ───\27[0m"))
            local seg_pct = (parts.total_area / math.max(1, self.img.width * self.img.height)) * 100.0
            add_right(string.format(" Cutoff: \27[1;33mT = %3d / 255\27[0m  Segmented: \27[1m%4.1f%%\27[0m",
                self.threshold_val, seg_pct))
            local slider_w = math.max(10, insp_w - 14)
            local knob_pos = math.max(1, math.min(slider_w, math.floor((self.threshold_val / 255.0) * slider_w)))
            local slider_bar = string.rep("─", knob_pos - 1) .. "\27[1;31m●\27[0m" .. string.rep("─", slider_w - knob_pos)
            add_right(" [0 " .. slider_bar .. " 255]")
            add_right(" Adjust: [</>] Step 1  [a] Otsu Auto  [Tab] Table")
            add_right("")

            add_right(string.format("\27[1;36m── 3. Connected Component Particles ───────\27[0m"))
            add_right(string.format(" Blobs: \27[1;32m%d\27[0m  Total Area: %d px  Avg: %.1f px",
                parts.count, parts.total_area, parts.avg_area))
            add_right(" \27[1mID   Center(X,Y)   Box(WxH)   Area    %Img\27[0m")
            local max_rows = math.min(#parts.blobs, math.max(3, view_h - #right_lines - 1))
            for i = 1, max_rows do
                local b = parts.blobs[i]
                local bpct = (b.area / (self.img.width * self.img.height)) * 100.0
                add_right(string.format(" #%02d  (%3d,%3d)     %3dx%-3d   %5d   %4.1f%%",
                    i, b.cx, b.cy, b.w, b.h, b.area, bpct))
            end
        else
            -- Standard Inspector: ROI, Line Profile, Histogram
            add_right(string.format("\27[1;36m── 2. ROI Statistics ([r] ROI | [m] Log:%d) ─\27[0m", #self.measurement_log))
            if self.roi.active then
                local r_tag = (self.roi.state == "sizing") and "\27[1;33m[SIZING]\27[0m" or "\27[1;32m[LOCKED]\27[0m"
                add_right(string.format(" %s [%d,%d to %d,%d] Area: \27[1m%d px\27[0m",
                    r_tag, roi_stats.x1, roi_stats.y1, roi_stats.x2, roi_stats.y2, roi_stats.area))
            else
                add_right(string.format(" \27[90m[Full Image: %dx%d = %d px | 'r' Set ROI]\27[0m",
                    self.img.width, self.img.height, roi_stats.area))
            end
            add_right(string.format(" Mean: \27[1;32m%.2f\27[0m  StdDev: \27[1;32m%.2f\27[0m",
                roi_stats.mean, roi_stats.std_dev))
            add_right(string.format(" Min: \27[1m%d\27[0m  Max: \27[1m%d\27[0m  Median: \27[1m%d\27[0m",
                roi_stats.min, roi_stats.max, roi_stats.median))
            if #self.measurement_log > 0 then
                local last_m = self.measurement_log[#self.measurement_log]
                add_right(string.format(" IntDen: \27[1;33m%d\27[0m | Last #%d Mean: %.1f",
                    roi_stats.int_den, last_m.id, last_m.mean))
            else
                add_right(string.format(" Integrated Density: \27[1;33m%d\27[0m", roi_stats.int_den))
            end
            add_right("")

            add_right(string.format("\27[1;36m── 3. Line Profile (%s @ %d) ───\27[0m",
                self.profile_horizontal and "Horiz Y" or "Vert X",
                self.profile_horizontal and self.probe_y or self.probe_x))
            add_right(string.format(" Peak: \27[1;33m%d\27[0m @ pos %d  Baseline: %d",
                prof.peak_val, prof.peak_pos, prof.baseline))
            add_right(string.format(" Half-Max: %.1f  \27[1;35mFWHM: %d px\27[0m",
                prof.half_max, prof.fwhm))

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
            add_right("   0└──" .. string.rep("─", math.min(insp_w - 6, math.floor(#spark_str / 3))))
            add_right("")

            add_right(string.format("\27[1;36m── 4. Histogram & Window / Level ───────────\27[0m"))
            local max_hist = 1
            for i = 0, 255 do
                if hist[i] > max_hist then max_hist = hist[i] end
            end
            local hist_str = ""
            local hist_step = math.max(1, math.floor(256 / math.max(1, (insp_w - 6))))
            for i = 0, 255, hist_step do
                local bucket_sum = 0
                for k = 0, hist_step - 1 do bucket_sum = bucket_sum + (hist[i + k] or 0) end
                local s_idx = math.max(1, math.min(8, math.floor((bucket_sum / (max_hist * hist_step)) * 7) + 1))
                hist_str = hist_str .. spark_chars[s_idx]
                if #hist_str >= (insp_w - 6) then break end
            end
            add_right(" 100%│\27[33m" .. hist_str .. "\27[0m")
            add_right(string.format(" Range: [\27[1m%d\27[0m-\27[1m%d\27[0m] Win:%d Lvl:%d y:%.2f",
                self.win_low, self.win_high, self.win_width, self.win_level, self.gamma))
        end

        -- 4. Render Dual-Pane Viewport (with Zoom, Pan, Ruler & Scale Bar)
        local img_display_w = pane_w - 2
        local img_display_h = view_h * 2 -- Half blocks give 2 vertical px per cell
        local vx0, vy0, vis_w, vis_h = self:get_viewport_bounds()

        local cur_col = math.max(0, math.min(img_display_w - 1,
            math.floor((self.probe_x - vx0) * img_display_w / vis_w)))
        local cur_row_px = math.max(0, math.min(img_display_h - 1,
            math.floor((self.probe_y - vy0) * img_display_h / vis_h)))

        -- High-visibility compact crosshair reticle (clean, no long lines)
        local function apply_crosshair(r, g, b, col, py)
            local dx = math.abs(col - cur_col)
            local dy = math.abs(py - cur_row_px)

            if dx == 0 and dy == 0 then
                local lum = (r * 0.299 + g * 0.587 + b * 0.114)
                if lum > 140 then
                    return 255, 0, 80 -- Neon Crimson on bright background
                else
                    return 255, 255, 0 -- Electric Yellow on dark background
                end
            elseif (dx <= 2 and dy == 0) or (dx == 0 and dy <= 2) then
                local lum = (r * 0.299 + g * 0.587 + b * 0.114)
                if lum > 140 then
                    return 0, 220, 255 -- Electric Cyan
                else
                    return 255, 220, 0 -- Vivid Amber
                end
            end

            return r, g, b
        end

        -- Pre-map ROI box to zoomed display coordinates
        local drx1, drx2, dry1, dry2 = -1, -1, -1, -1
        if self.roi.active then
            local rx1 = math.min(self.roi.x1, self.roi.x2)
            local rx2 = math.max(self.roi.x1, self.roi.x2)
            local ry1 = math.min(self.roi.y1, self.roi.y2)
            local ry2 = math.max(self.roi.y1, self.roi.y2)
            drx1 = math.floor((rx1 - vx0) * img_display_w / vis_w)
            drx2 = math.floor((rx2 - vx0) * img_display_w / vis_w)
            dry1 = math.floor((ry1 - vy0) * img_display_h / vis_h)
            dry2 = math.floor((ry2 - vy0) * img_display_h / vis_h)
        end

        -- Pre-map Ruler line to zoomed display coordinates
        local rlx1, rly1, rlx2, rly2 = -1, -1, -1, -1
        if self.ruler.active then
            rlx1 = math.floor((self.ruler.x1 - vx0) * img_display_w / vis_w)
            rly1 = math.floor((self.ruler.y1 - vy0) * img_display_h / vis_h)
            rlx2 = math.floor((self.ruler.x2 - vx0) * img_display_w / vis_w)
            rly2 = math.floor((self.ruler.y2 - vy0) * img_display_h / vis_h)
        end

        local function is_on_ruler(col, py)
            if not self.ruler.active then return false end
            local min_x = math.min(rlx1, rlx2)
            local max_x = math.max(rlx1, rlx2)
            local min_y = math.min(rly1, rly2)
            local max_y = math.max(rly1, rly2)
            if col < min_x or col > max_x or py < min_y or py > max_y then
                return false
            end
            local ldx = rlx2 - rlx1
            local ldy = rly2 - rly1
            local len_sq = ldx * ldx + ldy * ldy
            if len_sq == 0 then
                return (col == rlx1 and py == rly1)
            end
            local cross = math.abs((col - rlx1) * ldy - (py - rly1) * ldx) / math.sqrt(len_sq)
            return cross <= 0.75
        end

        -- Scale bar parameters (bottom-right of viewport)
        local scale_px = math.max(8, math.floor(vis_w / 5))
        local scale_cols = math.max(4, math.floor(scale_px * img_display_w / vis_w))
        local sb_x2 = img_display_w - 3
        local sb_x1 = math.max(2, sb_x2 - scale_cols)
        local sb_py = img_display_h - 3

        for row = 0, view_h - 1 do
            local row_str = "\27[1;37;44m│\27[0m"
            local top_py = row * 2
            local bot_py = row * 2 + 1

            for col = 0, img_display_w - 1 do
                local top_img_x = vx0 + math.floor(col * vis_w / img_display_w)
                local top_img_y = vy0 + math.floor(top_py * vis_h / img_display_h)
                local bot_img_x = top_img_x
                local bot_img_y = vy0 + math.floor(bot_py * vis_h / img_display_h)

                local top_val = self.img:get_gray(top_img_x, top_img_y)
                local bot_val = self.img:get_gray(bot_img_x, bot_img_y)

                local is_top_thresh = (self.mode == "threshold" and top_val >= self.threshold_val)
                local is_bot_thresh = (self.mode == "threshold" and bot_val >= self.threshold_val)

                local tr, tg, tb
                local br, bg, bb

                if is_top_thresh then
                    tr, tg, tb = 255, 35, 35 -- Live red segmentation mask
                else
                    tr, tg, tb = self:get_display_rgb(top_img_x, top_img_y)
                end

                if is_bot_thresh then
                    br, bg, bb = 255, 35, 35
                else
                    br, bg, bb = self:get_display_rgb(bot_img_x, bot_img_y)
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

                -- Screen-space Ruler Line Overlay
                if is_on_ruler(col, top_py) then tr, tg, tb = 255, 80, 255 end
                if is_on_ruler(col, bot_py) then br, bg, bb = 255, 80, 255 end

                -- Calibrated Scale Bar Overlay (bottom-right)
                if top_py == sb_py and col >= sb_x1 and col <= sb_x2 then
                    tr, tg, tb = 255, 255, 255
                end
                if bot_py == sb_py and col >= sb_x1 and col <= sb_x2 then
                    br, bg, bb = 255, 255, 255
                end

                -- Screen-space Compact Crosshair Reticle
                tr, tg, tb = apply_crosshair(tr, tg, tb, col, top_py)
                br, bg, bb = apply_crosshair(br, bg, bb, col, bot_py)

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
        local hotkeys = " [Arrows]Move [+-]Zoom [r]ROI [d]Rule [m]Log [c]Ch [l]LUT [g/e]Gam [f/o]Flt [3]3D [1]Rst [?]Help"
        if #hotkeys > cols - 2 then
            hotkeys = hotkeys:sub(1, cols - 2)
        elseif #hotkeys < cols - 2 then
            hotkeys = hotkeys .. string.rep(" ", cols - 2 - #hotkeys)
        end
        emit("\27[1;30;47m" .. hotkeys .. "\27[0m\27[K\n")
        local status_line = string.format(" [Scalebar: %dpx] %s", scale_px, self.status_msg)
        if #status_line > cols - 2 then
            status_line = status_line:sub(1, cols - 2)
        elseif #status_line < cols - 2 then
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

        for r = plot_h, 1, -1 do
            local y_val = math.floor((r / plot_h) * 255)
            local row_str = string.format(" %3d │ ", y_val)
            for c = 1, plot_w do
                local sample_idx = math.max(1, math.min(prof.length, math.floor((c / plot_w) * prof.length)))
                local val = prof.data[sample_idx] or 0
                if val >= y_val then
                    if math.abs(val - prof.half_max) < 8 then
                        row_str = row_str .. "\27[1;35m█\27[0m"
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

        emit("\27[1;37;44m┌─ Threshold & Connected Component Particle Table ────────────────────────── [Esc/Tab] Back ─┐\27[0m\27[K\n")
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

        emit(" Controls: [</>] Adjust Cutoff (1)  [a] Otsu Auto  [Tab/Esc] Return to Split-Pane View\27[K")
        return table.concat(lines)
    end

    function app:render_surface3d_modal(cols, rows)
        local lines = {}
        local emit = function(s) table.insert(lines, s) end
        cols = math.max(80, cols)
        rows = math.max(24, rows)

        local plot_w = cols - 4
        local plot_h = rows - 5

        -- Allocate 2D character & color canvas
        local canvas_ch = {}
        local canvas_fg = {}
        for r = 1, plot_h do
            canvas_ch[r] = {}
            canvas_fg[r] = {}
            for c = 1, plot_w do
                canvas_ch[r][c] = " "
                canvas_fg[r][c] = ""
            end
        end

        local full_roi = { x1 = 0, y1 = 0, x2 = self.img.width - 1, y2 = self.img.height - 1 }
        local active_roi = self.roi.active and self.roi or full_roi
        local rx1 = math.min(active_roi.x1, active_roi.x2)
        local rx2 = math.max(active_roi.x1, active_roi.x2)
        local ry1 = math.min(active_roi.y1, active_roi.y2)
        local ry2 = math.max(active_roi.y1, active_roi.y2)
        local rw = math.max(4, rx2 - rx1 + 1)
        local rh = math.max(4, ry2 - ry1 + 1)

        local grid_nx = math.min(60, math.floor(plot_w * 0.62))
        local grid_ny = math.min(28, math.floor(plot_h * 0.65))
        local max_z_rows = math.max(4, math.floor(plot_h * 0.45))

        -- Back-to-front painter's algorithm for isometric 3D surface plot
        for gy = 0, grid_ny - 1 do
            local iy = ry1 + math.floor(gy * (rh - 1) / math.max(1, grid_ny - 1))
            for gx = 0, grid_nx - 1 do
                local ix = rx1 + math.floor(gx * (rw - 1) / math.max(1, grid_nx - 1))
                local val = self.img:get_gray(ix, iy)
                local cr, cg, cb = self:map_display_color(val)
                local z_h = math.floor((val / 255.0) * max_z_rows)

                local screen_x = math.floor(4 + gx + (grid_ny - 1 - gy) * 0.45)
                local base_y = math.floor(plot_h - 2 - (grid_ny - 1 - gy) * 0.45)
                local top_y = math.max(1, base_y - z_h)

                if screen_x >= 1 and screen_x <= plot_w then
                    for sy = base_y, top_y, -1 do
                        if sy >= 1 and sy <= plot_h then
                            if sy == top_y then
                                canvas_ch[sy][screen_x] = "▄"
                                canvas_fg[sy][screen_x] = string.format("\27[38;2;%d;%d;%dm", cr, cg, cb)
                            else
                                canvas_ch[sy][screen_x] = "│"
                                canvas_fg[sy][screen_x] = string.format("\27[38;2;%d;%d;%dm",
                                    math.floor(cr * 0.55), math.floor(cg * 0.55), math.floor(cb * 0.55))
                            end
                        end
                    end
                end
            end
        end

        local lut_name = LUT_NAMES[self.lut_idx] or "Fire"
        emit(string.format("\27[1;37;44m┌─ 3D Isometric Surface Plot (Z = Luminance, LUT = %s) ──── [l] LUT  [3/Esc] Return ─┐\27[0m\27[K\n", lut_name))
        for r = 1, plot_h do
            local row_t = { "  " }
            for c = 1, plot_w do
                if canvas_fg[r][c] ~= "" then
                    row_t[#row_t + 1] = canvas_fg[r][c] .. canvas_ch[r][c] .. "\27[0m"
                else
                    row_t[#row_t + 1] = " "
                end
            end
            emit(table.concat(row_t) .. "\27[K\n")
        end

        local stats = compute_roi_stats(self.img, active_roi)
        emit("\27[1;37;44m├" .. string.rep("─", cols - 2) .. "┤\27[0m\27[K\n")
        emit(string.format(" Region [%d,%d to %d,%d] | Peak Z: \27[1;33m%d\27[0m | Min Z: %d | Mean Z: \27[1;32m%.2f\27[0m | [l] Cycle LUT  [3/Esc] Back\27[K",
            rx1, ry1, rx2, ry2, stats.max, stats.min, stats.mean))

        return table.concat(lines)
    end

    function app:render_help_modal(cols, rows)
        local lines = {}
        local emit = function(s) table.insert(lines, s) end
        local p = self.help_page or 1

        if p == 1 then
            emit("\27[1;37;44m┌─ ffi_imagej Help & Reference ─── [Page 1/3: Keyboard Controls] ─── [Tab/Arrows] Page ─┐\27[0m\27[K\n")
            emit("│  NAVIGATION, ZOOM & RESET                                                             │\27[K\n")
            emit("│    Arrow keys / Shift+H,J,K   Move pixel probe crosshair (1 px / 8 px fast jump)      │\27[K\n")
            emit("│    + / - / 0                  Zoom In (up to 8x) / Zoom Out / [0] Reset Zoom to 1.0x  │\27[K\n")
            emit("│    1  (or Shift+R)            FULL RESET: Restore raw image, 1.0x zoom, Auto W/L      │\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  SCIENTIFIC IMAGEJ ANALYSIS & TOOLS                                                   │\27[K\n")
            emit("│    r                          2-Point ROI Box: Anchor -> Resize -> Lock -> Clear      │\27[K\n")
            emit("│    d                          Straight-Line Ruler: Measure Distance (px), Angle & dI  │\27[K\n")
            emit("│    m                          Record current ROI stats into persistent Results Log    │\27[K\n")
            emit("│    p                          1D Intensity Line Profile modal (with FWHM width math)  │\27[K\n")
            emit("│    3                          3D Isometric Surface Plot (Topographic Z = Luminance)   │\27[K\n")
            emit("│    c                          Split RGB Channels (Composite / Red / Green / Blue)     │\27[K\n")
            emit("│    l / L                      Cycle Lookup Tables (RGB/Gray/Fire/Viridis/Cool/Turbo)  │\27[K\n")
            emit("│    w / W, b / B               Narrow/Widen Contrast Window & Raise/Lower Brightness   │\27[K\n")
            emit("│    g / G, e                   Adjust Gamma Curve (0.2-3.0) / Toggle Histogram Equal.  │\27[K\n")
            emit("│    a                          Auto-Contrast (0.35% ImageJ histogram tail clip)        │\27[K\n")
            emit("│    t                          Live Split-Pane Threshold & 8-Connected Blob Counter    │\27[K\n")
            emit("│    f / o                      Cycle 3x3 Spatial Filter / Binary Morphological Ops     │\27[K\n")
            emit("│    i / s                      Invert Image (255-v) / Save CSV Report & PPM Image      │\27[K\n")
            emit("└─ [Tab or Left/Right or 1/2/3] Page: (1) Controls  (2) Analysis Guide  (3) Filters ────┘\27[K")
        elseif p == 2 then
            emit("\27[1;37;44m┌─ ffi_imagej Help & Reference ─── [Page 2/3: Scientific Analysis] ─ [Tab/Arrows] Page ─┐\27[0m\27[K\n")
            emit("│  1. PIXEL PROBE & STRAIGHT-LINE RULER ([Arrows], [d])                                 │\27[K\n")
            emit("│     • Displays (X, Y) position, raw 24-bit (R, G, B), and luminance Y=0.299R+0.587G+… │\27[K\n")
            emit("│     • [d] Ruler measures Euclidean distance D = sqrt(dx^2+dy^2), angle (deg), and dI. │\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  2. 2-POINT ROI STATISTICS & MEASUREMENT LOG ([r], [m], [s])                          │\27[K\n")
            emit("│     • Mean & StdDev: Average intensity and pixel-to-pixel contrast spread in box.     │\27[K\n")
            emit("│     • Integrated Density (IntDen): Area * Mean — measures total signal/fluorescence.  │\27[K\n")
            emit("│     • [m] snapshots ROI metrics to the Results Log; [s] exports all rows to CSV.      │\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  3. 1D INTENSITY LINE PROFILE & FWHM ([p], [v])                                       │\27[K\n")
            emit("│     • Plots intensity along horizontal (Y) or vertical (X) slice through cursor.      │\27[K\n")
            emit("│     • FWHM (Full Width at Half Maximum): Peak width at 50% height (optical sharpness).│\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  4. OTSU AUTO-THRESHOLDING & PARTICLE COUNTER ([t], [a], [Tab])                       │\27[K\n")
            emit("│     • Otsu's Method automatically finds cutoff T (0-255) maximizing class variance.   │\27[K\n")
            emit("│     • 8-Connected Blob Labeling counts segmented particles, centroids, and areas.     │\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  5. RGB CHANNEL SPLITTING ([c])                                                       │\27[K\n")
            emit("│     • Isolates Red, Green, or Blue channels so all stats & histograms measure that ch.│\27[K\n")
            emit("└─ [Tab or Left/Right or 1/2/3] Page: (1) Controls  (2) Analysis Guide  (3) Filters ────┘\27[K")
        else
            emit("\27[1;37;44m┌─ ffi_imagej Help & Reference ─── [Page 3/3: Filters & Contrast] ── [Tab/Arrows] Page ─┐\27[0m\27[K\n")
            emit("│  6. CONTRAST, WINDOW/LEVEL, GAMMA & EQUALIZATION ([w/W], [b/B], [a], [g/G], [e])      │\27[K\n")
            emit("│     • Window/Level: Maps [Low..High] intensity to [0..255]. Narrow window = high ctr. │\27[K\n")
            emit("│     • Auto W/L ([a]): Clips extreme 0.35% histogram tails (NIH ImageJ standard).      │\27[K\n")
            emit("│     • Gamma ([g/G]): Non-linear power curve V_out = V_in^y (<1 brightens shadows).    │\27[K\n")
            emit("│     • Equalize ([e]): Flattens histogram via Cumulative Distribution Function (CDF).  │\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  7. 3x3 SPATIAL CONVOLUTION FILTERS ([f]) & INVERT ([i])                              │\27[K\n")
            emit("│     • Median:  Replaces pixel with 3x3 median; removes salt noise while keeping edges.│\27[K\n")
            emit("│     • Blur:    3x3 Gaussian smoothing ([1 2 1; 2 4 2; 1 2 1]/16) reduces sensor grain.│\27[K\n")
            emit("│     • Sobel:   Gradient magnitude sqrt(Gx^2 + Gy^2) highlights object boundaries.     │\27[K\n")
            emit("│     • Sharpen: 3x3 Laplacian unsharp mask ([0 -1 0; -1 5 -1; 0 -1 0]) crisps edges.   │\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  8. MORPHOLOGICAL BINARY OPERATIONS ([o]) & 3D SURFACE PLOT ([3])                     │\27[K\n")
            emit("│     • Erode / Dilate: 3x3 local minimum (shrinks spots) / maximum (expands spots).    │\27[K\n")
            emit("│     • Open / Close:   Erode->Dilate (removes speckles) / Dilate->Erode (fills holes). │\27[K\n")
            emit("│     • 3D Surface ([3]): Isometric heightmap where Z = pixel luminance colored by LUT. │\27[K\n")
            emit("│                                                                                       │\27[K\n")
            emit("│  9. FULL RESET ([1] or [Shift+R])                                                     │\27[K\n")
            emit("│     • Restores raw image, clears filters/ROI/ruler, resets zoom=1.0x & Auto W/L.      │\27[K\n")
            emit("└─ [Tab or Left/Right or 1/2/3] Page: (1) Controls  (2) Analysis Guide  (3) Filters ────┘\27[K")
        end

        return table.concat(lines)
    end

    function app:render(cols, rows)
        if self.show_help then
            return self:render_help_modal(cols, rows)
        elseif self.mode == "profile" then
            return self:render_profile_modal(cols, rows)
        elseif self.mode == "threshold_table" then
            return self:render_threshold_modal(cols, rows)
        elseif self.mode == "surface3d" then
            return self:render_surface3d_modal(cols, rows)
        else
            return self:render_frame(cols, rows)
        end
    end

    function app:move_probe(dx, dy)
        self.probe_x = math.max(0, math.min(self.img.width - 1, self.probe_x + dx))
        self.probe_y = math.max(0, math.min(self.img.height - 1, self.probe_y + dy))
        if self.roi.state == "sizing" then
            self.roi.x2 = self.probe_x
            self.roi.y2 = self.probe_y
        end
        if self.ruler.state == "measuring" then
            self.ruler.x2 = self.probe_x
            self.ruler.y2 = self.probe_y
        end
    end

    function app:handle_key(key)
        if key == "CTRL_C" or key == "q" then
            return false
        elseif key == "ESC" then
            if self.show_help then
                self.show_help = false
            elseif self.mode == "threshold_table" then
                self.mode = "threshold"
            elseif self.mode ~= "normal" then
                self.mode = "normal"
                self.status_msg = "Returned to normal inspection mode."
            else
                return false
            end
        elseif key == "?" then
            self.show_help = not self.show_help
        elseif self.show_help then
            if key == "ENTER" or key == "SPACE" then
                self.show_help = false
            elseif key == "TAB" or key == "RIGHT" or key == "l" then
                self.help_page = (self.help_page % 3) + 1
            elseif key == "LEFT" or key == "h" then
                self.help_page = ((self.help_page - 2) % 3) + 1
            elseif key == "1" then
                self.help_page = 1
            elseif key == "2" then
                self.help_page = 2
            elseif key == "3" then
                self.help_page = 3
            end
        elseif self.mode == "surface3d" then
            if key == "3" then
                self.mode = "normal"
            elseif key == "l" then
                self.lut_idx = (self.lut_idx % #LUT_NAMES) + 1
            elseif key == "L" then
                self.lut_idx = ((self.lut_idx - 2) % #LUT_NAMES) + 1
            end
        elseif self.mode == "profile" then
            if key == "v" then
                self.profile_horizontal = not self.profile_horizontal
            elseif key == "UP" or key == "k" then
                if self.profile_horizontal then
                    self:move_probe(0, -1)
                else
                    self:move_probe(-1, 0)
                end
            elseif key == "DOWN" or key == "j" then
                if self.profile_horizontal then
                    self:move_probe(0, 1)
                else
                    self:move_probe(1, 0)
                end
            end
        elseif self.mode == "threshold_table" then
            if key == "TAB" then
                self.mode = "threshold"
            elseif key == "LEFT" or key == "<" or key == "," then
                self.threshold_val = math.max(0, self.threshold_val - 2)
            elseif key == "RIGHT" or key == ">" or key == "." then
                self.threshold_val = math.min(255, self.threshold_val + 2)
            elseif key == "a" then
                self.threshold_val = compute_otsu_threshold(self.img)
            end
        else
            -- Normal & Split-Pane Threshold Viewport Keybindings
            if key == "UP" then
                self:move_probe(0, -1)
            elseif key == "DOWN" then
                self:move_probe(0, 1)
            elseif key == "LEFT" then
                if self.mode == "threshold" then
                    self.threshold_val = math.max(0, self.threshold_val - 4)
                    self.status_msg = string.format("Threshold T = %d (segments pixels >= T in red)", self.threshold_val)
                else
                    self:move_probe(-1, 0)
                end
            elseif key == "RIGHT" then
                if self.mode == "threshold" then
                    self.threshold_val = math.min(255, self.threshold_val + 4)
                    self.status_msg = string.format("Threshold T = %d (segments pixels >= T in red)", self.threshold_val)
                else
                    self:move_probe(1, 0)
                end
            elseif key == "<" or key == "," then
                self.threshold_val = math.max(0, self.threshold_val - 1)
                self.status_msg = string.format("Threshold T = %d (fine step -1)", self.threshold_val)
            elseif key == ">" or key == "." then
                self.threshold_val = math.min(255, self.threshold_val + 1)
                self.status_msg = string.format("Threshold T = %d (fine step +1)", self.threshold_val)
            elseif key == "TAB" and self.mode == "threshold" then
                self.mode = "threshold_table"
            elseif key == "K" then
                self:move_probe(0, -8)
            elseif key == "J" then
                self:move_probe(0, 8)
            elseif key == "H" then
                self:move_probe(-8, 0)
            elseif key == "+" or key == "=" then
                self.zoom = math.min(8.0, self.zoom * 2.0)
                self.status_msg = string.format("Zoom In: %.1fx (centered on probe; press '0' to reset zoom)", self.zoom)
            elseif key == "-" or key == "_" then
                self.zoom = math.max(1.0, self.zoom / 2.0)
                self.status_msg = string.format("Zoom Out: %.1fx", self.zoom)
            elseif key == "0" then
                self.zoom = 1.0
                self.status_msg = "Zoom reset to 1.0x (press '1' or 'R' for full image reset)."
            elseif key == "l" then
                if self.raw_img.is_rgb and self.rgb_passthrough and self.lut_idx == 1 then
                    self.rgb_passthrough = false
                    self.lut_idx = 2
                    local lname = LUT_NAMES[self.lut_idx]
                    self.status_msg = string.format("LUT: %s — %s", lname, LUT_DESCRIPTIONS[lname] or "")
                elseif self.raw_img.is_rgb and self.lut_idx == #LUT_NAMES then
                    self.lut_idx = 1
                    self.rgb_passthrough = true
                    self.status_msg = "LUT: Original RGB — Truecolor 24-bit display"
                else
                    self.lut_idx = (self.lut_idx % #LUT_NAMES) + 1
                    local lname = LUT_NAMES[self.lut_idx]
                    self.status_msg = string.format("LUT: %s — %s", lname, LUT_DESCRIPTIONS[lname] or "")
                end
            elseif key == "L" then
                if self.raw_img.is_rgb and not self.rgb_passthrough and self.lut_idx == 1 then
                    self.rgb_passthrough = true
                    self.status_msg = "LUT: Original RGB — Truecolor 24-bit display"
                elseif self.raw_img.is_rgb and self.rgb_passthrough and self.lut_idx == 1 then
                    self.rgb_passthrough = false
                    self.lut_idx = #LUT_NAMES
                    local lname = LUT_NAMES[self.lut_idx]
                    self.status_msg = string.format("LUT: %s — %s", lname, LUT_DESCRIPTIONS[lname] or "")
                else
                    self.rgb_passthrough = false
                    self.lut_idx = ((self.lut_idx - 2) % #LUT_NAMES) + 1
                    local lname = LUT_NAMES[self.lut_idx]
                    self.status_msg = string.format("LUT: %s — %s", lname, LUT_DESCRIPTIONS[lname] or "")
                end
            elseif key == "c" or key == "C" then
                self.channel_idx = (self.channel_idx % #CHANNEL_MODES) + 1
                self:rebuild_filtered_image()
                local cname = CHANNEL_MODES[self.channel_idx]
                self.status_msg = string.format("Channel: %s (%s)", cname:upper(), CHANNEL_DESCRIPTIONS[cname] or "")
            elseif key == "r" then
                if self.roi.state == "none" then
                    self.roi.state = "sizing"
                    self.roi_state = "sizing"
                    self.roi.active = true
                    self.roi.x1 = self.probe_x
                    self.roi.y1 = self.probe_y
                    self.roi.x2 = self.probe_x
                    self.roi.y2 = self.probe_y
                    self.status_msg = "ROI Sizing: Move cursor to resize box, press 'r' to lock, 'm' to log stats."
                elseif self.roi.state == "sizing" then
                    self.roi.state = "locked"
                    self.roi_state = "locked"
                    self.roi.active = true
                    self.status_msg = string.format("ROI Locked [%d,%d to %d,%d]. Press 'm' to log or 'r' to clear.",
                        self.roi.x1, self.roi.y1, self.roi.x2, self.roi.y2)
                else
                    self.roi.state = "none"
                    self.roi_state = "none"
                    self.roi.active = false
                    self.status_msg = "ROI cleared (Section 2 now measures full-image statistics)."
                end
            elseif key == "d" then
                if self.ruler.state == "none" then
                    self.ruler.state = "measuring"
                    self.ruler.active = true
                    self.ruler.x1 = self.probe_x
                    self.ruler.y1 = self.probe_y
                    self.ruler.x2 = self.probe_x
                    self.ruler.y2 = self.probe_y
                    self.status_msg = "Ruler Measuring: Move cursor to target point, press 'd' to lock distance & angle."
                elseif self.ruler.state == "measuring" then
                    self.ruler.state = "locked"
                    self.ruler.active = true
                    local rm = compute_ruler(self.img, self.ruler.x1, self.ruler.y1, self.ruler.x2, self.ruler.y2)
                    self.status_msg = string.format("Ruler Locked: D = %.2f px, Angle = %.1f deg, dI = %+d",
                        rm.dist, rm.angle_deg, rm.dv)
                else
                    self.ruler.state = "none"
                    self.ruler.active = false
                    self.status_msg = "Ruler cleared."
                end
            elseif key == "m" then
                local entry = self:record_measurement()
                self.status_msg = string.format("Logged Measurement #%d (Area=%d, Mean=%.2f, IntDen=%d) — press 's' to export CSV",
                    entry.id, entry.area, entry.mean, entry.int_den)
            elseif key == "p" then
                self.mode = "profile"
                self.status_msg = "1D Intensity Profile: Inspects cross-section & Full Width at Half Maximum (FWHM)."
            elseif key == "3" then
                self.mode = "surface3d"
                self.status_msg = "3D Surface Plot: Isometric terrain where height Z = pixel luminance."
            elseif key == "t" then
                if self.mode == "threshold" then
                    self.mode = "normal"
                    self.status_msg = "Exited Threshold mode."
                else
                    self.mode = "threshold"
                    self.threshold_val = compute_otsu_threshold(self.img)
                    self.status_msg = string.format("Otsu Auto-Threshold (T=%d): Red overlay = segmented blobs >= T.", self.threshold_val)
                end
            elseif key == "w" then
                self.win_low = math.min(self.win_high - 5, self.win_low + 4)
                self.win_high = math.max(self.win_low + 5, self.win_high - 4)
                self:sync_wl()
                self.status_msg = string.format("Contrast Window narrowed: [%d - %d] (Win:%d — steeper contrast slope)",
                    self.win_low, self.win_high, self.win_width)
            elseif key == "W" then
                self.win_low = math.max(0, self.win_low - 4)
                self.win_high = math.min(255, self.win_high + 4)
                self:sync_wl()
                self.status_msg = string.format("Contrast Window widened: [%d - %d] (Win:%d — softer dynamic range)",
                    self.win_low, self.win_high, self.win_width)
            elseif key == "b" then
                local shift = 6
                self.win_low = math.max(0, self.win_low - shift)
                self.win_high = math.max(self.win_low + 5, self.win_high - shift)
                self:sync_wl()
                self.status_msg = string.format("Brightness raised (Window Level shifted down to %d): [%d - %d]",
                    self.win_level, self.win_low, self.win_high)
            elseif key == "B" then
                local shift = 6
                self.win_high = math.min(255, self.win_high + shift)
                self.win_low = math.min(self.win_high - 5, self.win_low + shift)
                self:sync_wl()
                self.status_msg = string.format("Brightness lowered (Window Level shifted up to %d): [%d - %d]",
                    self.win_level, self.win_low, self.win_high)
            elseif key == "g" then
                self.gamma = math.max(0.20, self.gamma - 0.10)
                self.status_msg = string.format("Gamma y = %.2f (non-linear power curve V^y — brightens dark shadows)", self.gamma)
            elseif key == "G" then
                self.gamma = math.min(3.00, self.gamma + 0.10)
                self.status_msg = string.format("Gamma y = %.2f (non-linear power curve V^y — deepens midtones/shadows)", self.gamma)
            elseif key == "e" then
                self.equalized = not self.equalized
                self:rebuild_filtered_image()
                self.status_msg = self.equalized
                    and "Histogram Equalization ON (stretches cumulative distribution CDF across 0-255)."
                    or "Histogram Equalization OFF."
            elseif key == "a" then
                if self.mode == "threshold" then
                    self.threshold_val = compute_otsu_threshold(self.img)
                    self.status_msg = string.format("Otsu Auto-Threshold recomputed: T = %d (maximizes bimodal variance)", self.threshold_val)
                else
                    self.win_low, self.win_high = compute_auto_window_level(self.img)
                    self:sync_wl()
                    self.status_msg = string.format("Auto W/L applied (0.35%% histogram tail clip): [%d - %d]", self.win_low, self.win_high)
                end
            elseif key == "f" then
                self.filter_idx = (self.filter_idx % #FILTER_NAMES) + 1
                self:rebuild_filtered_image()
                local fname = FILTER_NAMES[self.filter_idx]
                self.status_msg = string.format("Filter: %s (%s)", fname:upper(), FILTER_DESCRIPTIONS[fname] or "")
            elseif key == "o" then
                self.morph_idx = (self.morph_idx % #MORPH_NAMES) + 1
                self:rebuild_filtered_image()
                local mname = MORPH_NAMES[self.morph_idx]
                self.status_msg = string.format("Morphology: %s (%s)", mname:upper(), MORPH_DESCRIPTIONS[mname] or "")
            elseif key == "i" then
                self.inverted = not self.inverted
                self:rebuild_filtered_image()
                self.status_msg = self.inverted
                    and "Image Inverted: I_out = 255 - I_in (photographic negative)."
                    or "Image Inversion OFF."
            elseif key == "s" then
                local ok, msg = self:export_data()
                self.status_msg = msg
                if not ok then
                    io.stderr:write(msg .. "\n")
                end
            elseif key == "1" or key == "R" then
                self.channel_idx = 1
                self.filter_idx = 1
                self.morph_idx = 1
                self.equalized = false
                self.inverted = false
                self.gamma = 1.0
                self.zoom = 1.0
                self.lut_idx = 1
                self.rgb_passthrough = self.raw_img.is_rgb
                self.roi.state = "none"
                self.roi_state = "none"
                self.roi.active = false
                self.ruler.state = "none"
                self.ruler.active = false
                self.mode = "normal"
                self.img = self.raw_img:clone()
                self.win_low, self.win_high = compute_auto_window_level(self.img)
                self:sync_wl()
                self.status_msg = "FULL RESET: Restored raw image, 1.0x zoom, cleared filters/ROI/ruler, Auto W/L."
            end
        end
        return true
    end

    return app
end

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
    "  IMAGE_FILE             Path to image file (PGM, PPM, or PNG/JPG/TIFF/BMP/WEBP).",
    "                         If omitted, loads procedural cell colonies.",
    "",
    "Options:",
    "  -h, --help, /?         Show this help message and exit.",
    "  -t, --test             Headless render test (outputs single frame and exits).",
    "  --target=TARGET        Generate synthetic target: 'cells' (default), 'usaf', or 'gradient'.",
    "  --lut=LUT_NAME         Set initial colormap: Grayscale, Fire, Viridis, Cool, Turbo, Green, Invert.",
    "  --threshold=N          Set initial segmentation threshold (0-255).",
    "",
    "Interactive Keybindings:",
    "  Arrow keys             Move pixel probe crosshair (+)",
    "  + / - / 0              Zoom In / Zoom Out / [0] Reset Zoom (1.0x to 8.0x)",
    "  1 / Shift+R            FULL RESET: Restore original image, 1.0x zoom, Auto W/L, clear ROI/Ruler",
    "  r                      2-Point ROI: Anchor -> Resize -> Lock -> Clear",
    "  d                      Point-to-Point Euclidean Distance & Angle Ruler",
    "  m                      Record ROI Measurement into Results Log",
    "  p                      1D Intensity Profile (Horiz/Vert slice with FWHM)",
    "  3                      3D Isometric Surface Plot (Topographic Z=Luminance)",
    "  c                      Split RGB Channels (Composite, Red, Green, Blue, Gray)",
    "  l / L                  Cycle scientific Lookup Tables (LUTs) forward/backward",
    "  w / W, b / B           Adjust Window (Contrast) and Level (Brightness)",
    "  g / G, e               Adjust Gamma (0.2-3.0) / Toggle Histogram Equalization",
    "  a                      Auto-Contrast (0.35% ImageJ saturation clip)",
    "  t                      Live Split-Pane Threshold & Particle analysis (Otsu)",
    "  f / o                  Cycle Spatial Filter / Binary Morphological Ops",
    "  i                      Invert image values (255 - v)",
    "  s                      Save CSV Measurements & Export Processed PPM Image",
    "  ?                      Toggle 3-Page Interactive Help & Scientific Reference",
    "  q / Esc                Exit viewer",
    "",
    "Scientific Functions & Algorithms Guide:",
    "  * ROI Statistics (r/m) : Computes Area, Mean, StdDev, Min, Max, Median, and Integrated Density",
    "                           (IntDen = Area * Mean, measuring total fluorescence/signal energy).",
    "  * Line Profile (p)     : Extracts 1D intensity cross-section and Full Width at Half Maximum",
    "                           (FWHM), measuring optical feature width at 50% peak height above baseline.",
    "  * Otsu Threshold (t/a) : Automatically finds threshold T (0-255) maximizing inter-class variance,",
    "                           followed by 8-connected flood-fill blob labeling & centroid measurement.",
    "  * Spatial Filters (f)  : 3x3 Median (impulse noise removal), Gaussian Blur (grain smoothing),",
    "                           Sobel (gradient edge magnitude), and Laplacian Sharpen (edge enhancement).",
    "  * Morphology Ops (o)   : 3x3 Erode (min), Dilate (max), Open (removes speckles), Close (fills holes).",
    "  * Contrast & Gamma     : Linear Window/Level [Low..High], non-linear Gamma (V^y), and CDF Equalization.",
    "",
    "Examples:",
    "  luajit ffi_imagej.lua                           # Open with procedural cell colonies",
    "  luajit ffi_imagej.lua --target=usaf             # View USAF-1951 resolution target",
    "  luajit ffi_imagej.lua ..\\lena.png               # Open color PNG image",
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
                app.rgb_passthrough = false
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
    local dirty = true
    local last_cols, last_rows = 0, 0

    while running do
        local cols, rows = get_terminal_size()
        if cols ~= last_cols or rows ~= last_rows then
            last_cols = cols
            last_rows = rows
            dirty = true
            io.write("\27[2J") -- Clear once on resize
        end

        if dirty then
            local frame = app:render(cols, rows)
            io.write("\27[?2026h\27[1;1H" .. frame .. "\27[?2026l")
            io.flush()
            dirty = false
        end

        local key = read_key_nonblocking()
        if key then
            running = app:handle_key(key)
            dirty = true
        else
            sleep_ms(16)
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
    compute_ruler = compute_ruler,
    apply_filter = apply_filter,
    LUTS = LUTS,
    LUT_NAMES = LUT_NAMES,
    FILTER_NAMES = FILTER_NAMES,
    MORPH_NAMES = MORPH_NAMES,
    CHANNEL_MODES = CHANNEL_MODES,
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
