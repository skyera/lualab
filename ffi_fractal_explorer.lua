--[[
    ffi_fractal_explorer.lua
    Interactive Real-time Fractal Explorer in Terminal Truecolor.
    Built entirely using LuaJIT FFI.

    Features:
    1. Multiple Fractal Types:
       - 1: Mandelbrot Set (Classic complex polynomial z -> z^2 + c)
       - 2: Julia Set (Dynamic parameterized Julia morphing)
       - 3: Burning Ship Fractal (z -> (|Re(z)| + i|Im(z)|)^2 + c)
       - 4: Tricorn / Mandelbar Fractal (Complex conjugate z -> (conj(z))^2 + c)
       - 5: Newton-Raphson Fractal (Basins of attraction for z^3 - 1 = 0)
    2. High-Performance Math & Rendering:
       - Smooth continuous potential coloring (renormalized fractional iteration count)
         to eliminate banding artifacts.
       - 24-bit ANSI Truecolor half-block engine ('▄' for 2 vertical pixels per text row).
       - Automatically adapts to terminal dimensions via POSIX ioctl(TIOCGWINSZ).
    3. Vibrant Color Palettes:
       - 1: Cyberpunk Neon (Electric Pink, Cyan, Violet, Dark Indigo)
       - 2: Fire & Magma (Black, Red, Orange, Gold, White)
       - 3: Deep Ocean Sapphire (Midnight Navy, Royal Azure, Aqua, Foam White)
       - 4: Emerald Forest (Deep Spruce, Jade, Lime, Mint)
       - 5: Rainbow Spectrum (Ultra-smooth 360° chromatic gradient)
    4. Real-time Interactive Exploration:
       - [← / → / ↑ / ↓] or [H / J / K / L]: Pan view
       - [+ / =]: Zoom in
       - [- / _]: Zoom out
       - [Page Up / Page Down]: Large jump zoom in / out
       - [1 - 5]: Switch fractal types
       - [C]: Cycle color palettes
       - [R]: Reset viewport coordinates and zoom
       - [J]: Morph Julia constant in real-time
       - [Space]: Toggle continuous Julia morph animation
       - [S]: Save screenshot as PPM / PNG to disk
       - [Q / Esc]: Quit
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. C Declarations for Terminal, POSIX I/O, Clock, and Pixel Buffers
-- =========================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;
]]

local get_time_sec
local get_terminal_size
local enable_raw_mode
local disable_raw_mode
local read_key
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

        typedef union {
            struct {
                uint32_t LowPart;
                int32_t  HighPart;
            };
            int64_t QuadPart;
        } LARGE_INTEGER;

        void* __stdcall GetStdHandle(uint32_t nStdHandle);
        int   __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int   __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int   __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int   __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        int   __stdcall QueryPerformanceCounter(LARGE_INTEGER* lpPerformanceCount);
        int   __stdcall QueryPerformanceFrequency(LARGE_INTEGER* lpFrequency);
        void  __stdcall Sleep(uint32_t dwMilliseconds);

        int _kbhit(void);
        int _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6 -- ((uint32_t)-10)
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- ((uint32_t)-11)

    local qpc_freq = ffi.new("LARGE_INTEGER")
    ffi.C.QueryPerformanceFrequency(qpc_freq)
    local freq_val = tonumber(qpc_freq.QuadPart)

    get_time_sec = function()
        local count = ffi.new("LARGE_INTEGER")
        ffi.C.QueryPerformanceCounter(count)
        return tonumber(count.QuadPart) / freq_val
    end

    local orig_in_mode = ffi.new("uint32_t[1]")
    local raw_mode_enabled = false

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
        return 80, 24
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        if ffi.C.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end

        local ENABLE_LINE_INPUT = 0x0002
        local ENABLE_ECHO_INPUT = 0x0004
        local new_mode = bit.band(orig_in_mode[0], bit.bnot(bit.bor(ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT)))
        ffi.C.SetConsoleMode(hIn, new_mode)
        raw_mode_enabled = true

        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?25h\27[0m\n")
            io.flush()
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            raw_mode_enabled = false
        end
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 0
        if timeout_ms > 0 then
            local start_t = get_time_sec()
            while (get_time_sec() - start_t) * 1000 < timeout_ms do
                if ffi.C._kbhit() ~= 0 then break end
                ffi.C.Sleep(1)
            end
        end

        if ffi.C._kbhit() ~= 0 then
            local ch = ffi.C._getch()
            if ch == 0 or ch == 224 then
                local code = ffi.C._getch()
                if code == 72 then return "UP"
                elseif code == 80 then return "DOWN"
                elseif code == 75 then return "LEFT"
                elseif code == 77 then return "RIGHT"
                elseif code == 73 then return "PAGE_UP"
                elseif code == 81 then return "PAGE_DOWN"
                end
            elseif ch == 27 then
                return "ESC"
            elseif ch == 13 or ch == 10 then
                return "ENTER"
            elseif ch == 32 then
                return "SPACE"
            elseif ch == 8 then
                return "BACKSPACE"
            else
                return string.char(ch):lower()
            end
        end
        return nil
    end

    sleep_ms = function(ms)
        if ms > 0 then ffi.C.Sleep(ms) end
    end
else
    ffi.cdef[[
        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, void *argp);
        int isatty(int fd);

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

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);

        struct pollfd {
            int   fd;
            short events;
            short revents;
        };
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);

        typedef struct { long tv_sec; long tv_nsec; } timespec_t;
        int clock_gettime(int clk_id, timespec_t *tp);
        int usleep(unsigned int usec);
    ]]

    local TIOCGWINSZ = 0x5413
    local STDIN_FILENO = 0
    local TCSANOW = 0
    local ICANON = 2
    local ECHO = 8
    local POLLIN = 1
    local CLOCK_MONOTONIC = 1

    get_time_sec = function()
        local ts = ffi.new("timespec_t")
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
    end

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 80, 24
    end

    local orig_termios = ffi.new("struct termios")
    local raw_termios = ffi.new("struct termios")
    local raw_mode_enabled = false

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        raw_mode_enabled = true

        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?25h\27[0m\n")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            raw_mode_enabled = false
        end
    end

    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local key_buf = ffi.new("char[16]")

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 0
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 16)
            if n > 0 then
                local c0 = key_buf[0]
                if c0 == 27 then
                    if n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP" end
                        if c2 == 66 then return "DOWN" end
                        if c2 == 67 then return "RIGHT" end
                        if c2 == 68 then return "LEFT" end
                        if c2 == 53 and n >= 4 and key_buf[3] == 126 then return "PAGE_UP" end
                        if c2 == 54 and n >= 4 and key_buf[3] == 126 then return "PAGE_DOWN" end
                    end
                    return "ESC"
                elseif c0 == 10 or c0 == 13 then
                    return "ENTER"
                elseif c0 == 32 then
                    return "SPACE"
                elseif c0 == 127 or c0 == 8 then
                    return "BACKSPACE"
                else
                    return string.char(c0):lower()
                end
            end
        end
        return nil
    end

    sleep_ms = function(ms)
        if ms > 0 then ffi.C.usleep(ms * 1000) end
    end
end

-- =========================================================================
-- 3. Color Palettes
-- =========================================================================
local PALETTES = {
    {
        name = "Cyberpunk Neon",
        stops = {
            {pos = 0.00, r = 10,  g = 10,  b = 25},
            {pos = 0.20, r = 60,  g = 20,  b = 110},
            {pos = 0.45, r = 240, g = 30,  b = 140},
            {pos = 0.70, r = 30,  g = 220, b = 240},
            {pos = 0.90, r = 255, g = 230, b = 255},
            {pos = 1.00, r = 10,  g = 10,  b = 25},
        }
    },
    {
        name = "Fire & Magma",
        stops = {
            {pos = 0.00, r = 10,  g = 4,   b = 4},
            {pos = 0.25, r = 180, g = 25,  b = 10},
            {pos = 0.50, r = 245, g = 110, b = 15},
            {pos = 0.75, r = 255, g = 220, b = 50},
            {pos = 0.95, r = 255, g = 255, b = 230},
            {pos = 1.00, r = 10,  g = 4,   b = 4},
        }
    },
    {
        name = "Deep Ocean Azure",
        stops = {
            {pos = 0.00, r = 4,   g = 10,  b = 25},
            {pos = 0.30, r = 20,  g = 60,  b = 140},
            {pos = 0.60, r = 40,  g = 150, b = 220},
            {pos = 0.85, r = 120, g = 230, b = 245},
            {pos = 0.98, r = 235, g = 250, b = 255},
            {pos = 1.00, r = 4,   g = 10,  b = 25},
        }
    },
    {
        name = "Emerald Forest",
        stops = {
            {pos = 0.00, r = 6,   g = 20,  b = 14},
            {pos = 0.28, r = 20,  g = 90,  b = 50},
            {pos = 0.55, r = 40,  g = 180, b = 80},
            {pos = 0.80, r = 160, g = 240, b = 110},
            {pos = 0.95, r = 235, g = 255, b = 220},
            {pos = 1.00, r = 6,   g = 20,  b = 14},
        }
    },
    {
        name = "Rainbow Chromatic",
        stops = {
            {pos = 0.00, r = 255, g = 40,  b = 40},
            {pos = 0.20, r = 255, g = 180, b = 30},
            {pos = 0.40, r = 60,  g = 220, b = 60},
            {pos = 0.60, r = 40,  g = 200, b = 255},
            {pos = 0.80, r = 180, g = 60,  b = 255},
            {pos = 1.00, r = 255, g = 40,  b = 40},
        }
    }
}

local function sample_palette(palette_idx, t)
    local pal = PALETTES[palette_idx]
    t = t % 1.0
    if t < 0 then t = t + 1.0 end

    local stops = pal.stops
    for i = 1, #stops - 1 do
        local s0 = stops[i]
        local s1 = stops[i + 1]
        if t >= s0.pos and t <= s1.pos then
            local span = s1.pos - s0.pos
            local alpha = (span > 1e-6) and ((t - s0.pos) / span) or 0
            local r = math.floor(s0.r * (1 - alpha) + s1.r * alpha)
            local g = math.floor(s0.g * (1 - alpha) + s1.g * alpha)
            local b = math.floor(s0.b * (1 - alpha) + s1.b * alpha)
            return r, g, b
        end
    end
    local last = stops[#stops]
    return last.r, last.g, last.b
end

-- =========================================================================
-- 4. Mathematical Fractal Engines
-- =========================================================================
-- 1. Mandelbrot: z -> z^2 + c
local function compute_mandelbrot(cr, ci, max_iter)
    local zr, zi = 0.0, 0.0
    local zr2, zi2 = 0.0, 0.0
    local iter = 0

    while iter < max_iter and (zr2 + zi2) <= 4.0 do
        zi = 2.0 * zr * zi + ci
        zr = zr2 - zi2 + cr
        zr2 = zr * zr
        zi2 = zi * zi
        iter = iter + 1
    end

    if iter >= max_iter then
        return nil -- inside the set
    end

    -- Continuous potential formula for smooth banding-free coloring:
    -- nu = iter + 1 - log(log(|z|)) / log(2)
    local mod2 = zr2 + zi2
    local smooth_iter = iter + 1.0 - (math.log(math.max(1e-12, math.log(mod2) * 0.5)) / 0.69314718)
    return math.max(0.0, smooth_iter)
end

-- 2. Julia Set: z -> z^2 + K
local function compute_julia(zr, zi, max_iter, kr, ki)
    local zr2, zi2 = zr * zr, zi * zi
    local iter = 0

    while iter < max_iter and (zr2 + zi2) <= 4.0 do
        zi = 2.0 * zr * zi + ki
        zr = zr2 - zi2 + kr
        zr2 = zr * zr
        zi2 = zi * zi
        iter = iter + 1
    end

    if iter >= max_iter then
        return nil
    end

    local mod2 = zr2 + zi2
    local smooth_iter = iter + 1.0 - (math.log(math.max(1e-12, math.log(mod2) * 0.5)) / 0.69314718)
    return math.max(0.0, smooth_iter)
end

-- 3. Burning Ship: z -> (|Re(z)| + i|Im(z)|)^2 + c
local function compute_burning_ship(cr, ci, max_iter)
    local zr, zi = 0.0, 0.0
    local zr2, zi2 = 0.0, 0.0
    local iter = 0

    while iter < max_iter and (zr2 + zi2) <= 4.0 do
        local abs_zr = (zr < 0) and -zr or zr
        local abs_zi = (zi < 0) and -zi or zi
        zi = 2.0 * abs_zr * abs_zi + ci
        zr = zr2 - zi2 + cr
        zr2 = zr * zr
        zi2 = zi * zi
        iter = iter + 1
    end

    if iter >= max_iter then
        return nil
    end

    local mod2 = zr2 + zi2
    local smooth_iter = iter + 1.0 - (math.log(math.max(1e-12, math.log(mod2) * 0.5)) / 0.69314718)
    return math.max(0.0, smooth_iter)
end

-- 4. Tricorn / Mandelbar: z -> (conj(z))^2 + c
local function compute_tricorn(cr, ci, max_iter)
    local zr, zi = 0.0, 0.0
    local zr2, zi2 = 0.0, 0.0
    local iter = 0

    while iter < max_iter and (zr2 + zi2) <= 4.0 do
        zi = -2.0 * zr * zi + ci
        zr = zr2 - zi2 + cr
        zr2 = zr * zr
        zi2 = zi * zi
        iter = iter + 1
    end

    if iter >= max_iter then
        return nil
    end

    local mod2 = zr2 + zi2
    local smooth_iter = iter + 1.0 - (math.log(math.max(1e-12, math.log(mod2) * 0.5)) / 0.69314718)
    return math.max(0.0, smooth_iter)
end

-- 5. Newton-Raphson: Basins of attraction for z^3 - 1 = 0
-- Roots are 1, -0.5 + 0.866i, -0.5 - 0.866i
local function compute_newton(zr, zi, max_iter)
    local iter = 0
    local tol = 1e-4

    while iter < max_iter do
        local zr2 = zr * zr
        local zi2 = zi * zi
        local d = 3.0 * ((zr2 - zi2) * (zr2 - zi2) + 4.0 * zr2 * zi2)
        if d < 1e-10 then break end

        -- f(z) = z^3 - 1, f'(z) = 3*z^2
        -- z_next = z - (z^3 - 1) / (3*z^2) = (2*z^3 + 1) / (3*z^2)
        local num_r = 2.0 * zr * (zr2 - 3.0 * zi2) + 1.0
        local num_i = 2.0 * zi * (3.0 * zr2 - zi2)
        local den_r = 3.0 * (zr2 - zi2)
        local den_i = 6.0 * zr * zi
        local den_mag = den_r * den_r + den_i * den_i

        local next_r = (num_r * den_r + num_i * den_i) / den_mag
        local next_i = (num_i * den_r - num_r * den_i) / den_mag

        local dr = next_r - zr
        local di = next_i - zi
        zr = next_r
        zi = next_i
        iter = iter + 1

        if (dr * dr + di * di) < tol * tol then
            break
        end
    end

    -- Classify which root was reached
    local r1_dist = (zr - 1.0) * (zr - 1.0) + zi * zi
    local r2_dist = (zr + 0.5) * (zr + 0.5) + (zi - 0.866025) * (zi - 0.866025)
    local root_id = 0
    if r1_dist < 0.1 then
        root_id = 1
    elseif r2_dist < 0.1 then
        root_id = 2
    else
        root_id = 3
    end

    return iter + (root_id * 8.0)
end

local FRACTAL_TYPES = {
    {
        name = "Mandelbrot Set",
        default_center = {r = -0.75, i = 0.0},
        default_zoom = 1.0,
        max_iter = 120,
        eval = function(cr, ci, max_iter, state)
            return compute_mandelbrot(cr, ci, max_iter)
        end
    },
    {
        name = "Julia Set",
        default_center = {r = 0.0, i = 0.0},
        default_zoom = 1.1,
        max_iter = 120,
        eval = function(zr, zi, max_iter, state)
            return compute_julia(zr, zi, max_iter, state.julia_kr, state.julia_ki)
        end
    },
    {
        name = "Burning Ship",
        default_center = {r = -0.45, i = -0.55},
        default_zoom = 1.0,
        max_iter = 120,
        eval = function(cr, ci, max_iter, state)
            return compute_burning_ship(cr, ci, max_iter)
        end
    },
    {
        name = "Tricorn (Mandelbar)",
        default_center = {r = -0.15, i = 0.0},
        default_zoom = 1.0,
        max_iter = 120,
        eval = function(cr, ci, max_iter, state)
            return compute_tricorn(cr, ci, max_iter)
        end
    },
    {
        name = "Newton-Raphson (z³ - 1)",
        default_center = {r = 0.0, i = 0.0},
        default_zoom = 1.0,
        max_iter = 60,
        eval = function(zr, zi, max_iter, state)
            return compute_newton(zr, zi, max_iter)
        end
    }
}

-- =========================================================================
-- 5. Truecolor Pixel Buffer & Screen Renderer
-- =========================================================================
local Framebuffer = {}
Framebuffer.__index = Framebuffer

function Framebuffer.new(w, h)
    local self = setmetatable({
        width = w,
        height = h,
        pixels = ffi.new("PixelRGB[?]", w * h)
    }, Framebuffer)
    return self
end

function Framebuffer:render_fractal(fractal, state, palette_idx)
    local w = self.width
    local h = self.height
    local px = self.pixels
    local max_iter = fractal.max_iter

    -- Viewport coordinate mapping
    -- Screen aspect ratio correction: terminal characters are ~2:1 vertical height
    local aspect = (w / (h * 0.5)) * 0.55
    local span_y = 2.4 / state.zoom
    local span_x = span_y * aspect

    local min_r = state.center_r - span_x * 0.5
    local min_i = state.center_i - span_y * 0.5
    local step_r = span_x / w
    local step_i = span_y / h

    for y = 0, h - 1 do
        local ci = min_i + y * step_i
        local row_idx = y * w
        for x = 0, w - 1 do
            local cr = min_r + x * step_r
            local val = fractal.eval(cr, ci, max_iter, state)
            local p = px[row_idx + x]

            if not val then
                -- Inside set: deep sleek black/indigo interior
                p.r = 4
                p.g = 4
                p.b = 10
            else
                -- Outside set: map continuous potential to color palette
                local t = (val * 0.035 + state.color_shift) % 1.0
                local r, g, b = sample_palette(palette_idx, t)
                p.r = r
                p.g = g
                p.b = b
            end
        end
    end
end

function Framebuffer:render_ansi_screen(title_str, stat_str, term_w)
    local out = {}
    table.insert(out, "\27[H") -- Cursor home

    table.insert(out, title_str .. "\n")

    local w = self.width
    local h = self.height
    local px = self.pixels

    local margin_left = math.max(0, math.floor((term_w - w) / 2))
    local pad = string.rep(" ", margin_left)

    -- Half-block rendering: 2 vertical pixels per terminal text row
    for y = 0, h - 1, 2 do
        local line = { pad }
        for x = 0, w - 1 do
            local top = px[y * w + x]
            local bot = (y + 1 < h) and px[(y + 1) * w + x] or top

            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                top.r, top.g, top.b,
                bot.r, bot.g, bot.b
            ))
        end
        table.insert(line, "\27[0m\n")
        table.insert(out, table.concat(line))
    end

    table.insert(out, stat_str)
    io.write(table.concat(out))
    io.flush()
end

function Framebuffer:save_ppm(filename)
    local f = io.open(filename, "wb")
    if not f then return false, "Cannot write to " .. filename end
    local header = string.format("P6\n%d %d\n255\n", self.width, self.height)
    f:write(header)
    f:write(ffi.string(self.pixels, self.width * self.height * 3))
    f:close()
    return true
end

function Framebuffer:save_png(filename)
    local ppm_tmp = filename:gsub("%.png$", "") .. "_tmp.ppm"
    local ok, err = self:save_ppm(ppm_tmp)
    if not ok then return false, err end
    local devnull = is_windows and "nul" or "/dev/null"
    local cmd
    if is_windows then
        cmd = string.format("magick %q %q 2>%s || ffmpeg -y -i %q %q 2>%s",
            ppm_tmp, filename, devnull, ppm_tmp, filename, devnull)
    else
        cmd = string.format("magick %q %q 2>%s || convert %q %q 2>%s || ffmpeg -y -i %q %q 2>%s",
            ppm_tmp, filename, devnull, ppm_tmp, filename, devnull, ppm_tmp, filename, devnull)
    end
    local code = os.execute(cmd)
    os.remove(ppm_tmp)
    return (code == 0 or code == true)
end

-- =========================================================================
-- 6. Main Interactive Explorer Loop
-- =========================================================================
local function main()
    local interactive = is_stdin_tty and is_stdin_tty() or false

    -- CLI arguments
    local fractal_idx = 1
    local palette_idx = 1
    local run_once = not interactive
    local save_screenshot_path = nil

    local i = 1
    while i <= #(arg or {}) do
        local a = arg[i]
        if tonumber(a) and tonumber(a) >= 1 and tonumber(a) <= #FRACTAL_TYPES then
            fractal_idx = tonumber(a)
        elseif a == "--palette" or a == "-p" then
            i = i + 1
            palette_idx = math.max(1, math.min(#PALETTES, tonumber(arg[i]) or 1))
        elseif a == "--save" or a == "-s" then
            i = i + 1
            save_screenshot_path = arg[i]
            run_once = true
        elseif a == "--once" then
            run_once = true
        elseif a == "-h" or a == "--help" then
            print("\27[1;36mTerminal Fractal Explorer (LuaJIT FFI Truecolor)\27[0m")
            print("Usage:")
            print("  ./LuaJIT/src/luajit ffi_fractal_explorer.lua [fractal 1-5] [options]")
            print("\nFractals:")
            print("  1: Mandelbrot Set (Default)")
            print("  2: Julia Set")
            print("  3: Burning Ship")
            print("  4: Tricorn (Mandelbar)")
            print("  5: Newton-Raphson (z³ - 1)")
            print("\nOptions:")
            print("  --palette, -p <1-5>   Initial color palette (1: Cyberpunk, 2: Fire, 3: Ocean, 4: Emerald, 5: Rainbow)")
            print("  --save, -s <file>     Render and save high-resolution screenshot (PNG/PPM)")
            print("  --once                Render a single frame and exit (batch/script mode)")
            print("  -h, --help            Show this help information")
            os.exit(0)
        end
        i = i + 1
    end

    local current_fractal = FRACTAL_TYPES[fractal_idx]
    local state = {
        center_r = current_fractal.default_center.r,
        center_i = current_fractal.default_center.i,
        zoom = current_fractal.default_zoom,
        color_shift = 0.0,
        julia_kr = -0.7,
        julia_ki = 0.27015,
        animate_julia = false,
        msg = nil,
        julia_theta = 0.0
    }

    local function reset_view(idx)
        fractal_idx = idx
        current_fractal = FRACTAL_TYPES[fractal_idx]
        state.center_r = current_fractal.default_center.r
        state.center_i = current_fractal.default_center.i
        state.zoom = current_fractal.default_zoom
        state.color_shift = 0.0
    end

    if interactive and not run_once then
        enable_raw_mode()
        io.write("\27[2J") -- Clear full terminal
    end

    local last_t = get_time_sec()
    local frame_count = 0
    local fps = 0
    local fps_t0 = last_t

    while true do
        local now = get_time_sec()
        local dt = math.min(0.1, now - last_t)
        last_t = now

        -- Handle user input
        if interactive and not run_once then
            local k = read_key(0)
            local pan_speed = (0.2 / state.zoom)

            if k == "q" or k == "ESC" then
                break
            elseif k == "UP" or k == "k" then
                state.center_i = state.center_i - pan_speed
            elseif k == "DOWN" or k == "j" then
                state.center_i = state.center_i + pan_speed
            elseif k == "LEFT" or k == "h" then
                state.center_r = state.center_r - pan_speed
            elseif k == "RIGHT" or k == "l" then
                state.center_r = state.center_r + pan_speed
            elseif k == "+" or k == "=" then
                state.zoom = state.zoom * 1.35
            elseif k == "-" or k == "_" then
                state.zoom = math.max(0.1, state.zoom / 1.35)
            elseif k == "PAGE_UP" then
                state.zoom = state.zoom * 2.5
            elseif k == "PAGE_DOWN" then
                state.zoom = math.max(0.1, state.zoom / 2.5)
            elseif k == "c" then
                palette_idx = (palette_idx % #PALETTES) + 1
            elseif k == "r" then
                reset_view(fractal_idx)
                state.msg = "Reset view coordinates & zoom"
            elseif k == "SPACE" then
                state.animate_julia = not state.animate_julia
                state.msg = state.animate_julia and "Julia auto-morphing enabled" or "Julia morph paused"
            elseif k == "j" then
                state.julia_theta = state.julia_theta + 0.15
                state.julia_kr = -0.8 * math.cos(state.julia_theta)
                state.julia_ki = 0.156 + 0.3 * math.sin(state.julia_theta)
                state.msg = string.format("Julia constant: %.3f + %.3fi", state.julia_kr, state.julia_ki)
            elseif k == "s" then
                local term_w, term_h = get_terminal_size()
                local fb_snap = Framebuffer.new(math.min(term_w, 80), math.max(12, (term_h - 7) * 2))
                fb_snap:render_fractal(current_fractal, state, palette_idx)
                local snap_ppm = string.format("fractal_%d.ppm", fractal_idx)
                local snap_png = string.format("fractal_%d.png", fractal_idx)
                fb_snap:save_ppm(snap_ppm)
                fb_snap:save_png(snap_png)
                state.msg = string.format("Saved screenshot: %s & %s", snap_ppm, snap_png)
            elseif tonumber(k) and tonumber(k) >= 1 and tonumber(k) <= #FRACTAL_TYPES then
                reset_view(tonumber(k))
            end
        end

        -- Continuous animation for Julia morphing
        if state.animate_julia then
            state.julia_theta = state.julia_theta + dt * 0.8
            state.julia_kr = -0.8 * math.cos(state.julia_theta)
            state.julia_ki = 0.156 + 0.28 * math.sin(state.julia_theta * 1.3)
            state.color_shift = state.color_shift + dt * 0.1
        end

        -- Compute terminal canvas size
        local term_w, term_h = get_terminal_size()
        local header_rows = 4
        local footer_rows = 3
        local avail_rows = math.max(8, term_h - header_rows - footer_rows)
        local buf_w = math.min(term_w, math.floor(avail_rows * 2.3))
        local buf_h = avail_rows * 2
        if buf_h % 2 ~= 0 then buf_h = buf_h + 1 end

        local fb = Framebuffer.new(buf_w, buf_h)
        fb:render_fractal(current_fractal, state, palette_idx)

        -- Handle single frame save screenshot
        if save_screenshot_path then
            if save_screenshot_path:match("%.png$") then
                fb:save_png(save_screenshot_path)
            else
                fb:save_ppm(save_screenshot_path)
            end
            print(string.format("[+] Saved fractal screenshot to %s", save_screenshot_path))
        end

        -- Calculate FPS
        frame_count = frame_count + 1
        if now - fps_t0 >= 0.5 then
            fps = frame_count / (now - fps_t0)
            fps_t0 = now
            frame_count = 0
        end

        -- Header Banner
        local bar = string.rep("═", math.min(term_w - 2, 78))
        local title_str = string.format(
            "\27[1;35m%s\27[0m\n  \27[1;37mTERMINAL FRACTAL EXPLORER\27[0m \27[90m| Fractal: \27[1;93m[%d] %s\27[0m \27[90m| Palette: \27[96m%s\27[0m\n  \27[90m[1-5] Switch Fractal  [←/→/↑/↓] Pan  [+/-] Zoom  [C] Palette  [Space] Morph  [Q] Quit\27[0m\n\27[90m%s\27[0m",
            bar, fractal_idx, current_fractal.name, PALETTES[palette_idx].name, bar
        )

        -- Footer Stat Line
        local stat_info = state.msg or string.format("Center: (%.5f, %.5fi) | Zoom: %.2fx", state.center_r, state.center_i, state.zoom)
        state.msg = nil
        local stat_str = string.format(
            "  \27[90mResolution: \27[37m%dx%d px\27[0m | \27[90mInfo: \27[32m%s\27[0m | \27[90mSpeed: \27[1;33m%.1f FPS\27[0m\n",
            buf_w, buf_h, stat_info, fps
        )

        fb:render_ansi_screen(title_str, stat_str, term_w)

        if run_once then break end

        -- Frame rate throttle (~30 FPS)
        local frame_duration = get_time_sec() - now
        local sleep_rem = 0.033 - frame_duration
        if sleep_rem > 0.001 then
            sleep_ms(math.floor(sleep_rem * 1000))
        end
    end

    if interactive and not run_once then
        disable_raw_mode()
        print("\n\27[1;36mExited Fractal Explorer. Goodbye!\27[0m")
    end
end

main()
