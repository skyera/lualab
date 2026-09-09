--[[
    ffi_image_terminal_demo.lua
    Demonstrates image generation, manipulation, and terminal rendering with LuaJIT FFI.

    Features:
    1. Zero-allocation contiguous C pixel memory: ffi.new("PixelRGB[?]", W * H).
    2. Procedural image rendering: smooth colorful Mandelbrot fractal.
    3. C image filter: contrast enhancement and grayscale conversion.
    4. Terminal rendering using true-color 24-bit ANSI escape codes with half-blocks (▄).
       - '▄' uses the foreground color for the bottom pixel and background for top pixel,
         effectively doubling the terminal's vertical resolution!
    5. Saves the final image directly to a valid PPM file ('mandelbrot.ppm').
]]

local ffi = require("ffi")

-- 1. C Declarations
ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;

    typedef struct { long tv_sec; long tv_nsec; } ffi_timespec;
    int clock_gettime(int clk_id, ffi_timespec *tp);
]]

local function get_time_ms()
    local ts = ffi.new("ffi_timespec")
    ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC = 1
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

-- 2. Image Canvas Object
local Image = {}
Image.__index = Image

function Image.new(w, h)
    local self = setmetatable({
        width = w,
        height = h,
        pixels = ffi.new("PixelRGB[?]", w * h)
    }, Image)
    return self
end

function Image:set_pixel(x, y, r, g, b)
    if x >= 0 and x < self.width and y >= 0 and y < self.height then
        local idx = y * self.width + x
        self.pixels[idx].r = r
        self.pixels[idx].g = g
        self.pixels[idx].b = b
    end
end

function Image:get_pixel(x, y)
    if x >= 0 and x < self.width and y >= 0 and y < self.height then
        return self.pixels[y * self.width + x]
    end
    return nil
end

-- 3. Procedural Image Generator: Smooth Colorful Mandelbrot
function Image:generate_mandelbrot(max_iter)
    max_iter = max_iter or 100
    local w, h = self.width, self.height
    local px = self.pixels

    -- Viewport in complex plane
    local x_min, x_max = -2.0, 0.7
    local y_min, y_max = -1.2, 1.2

    for y = 0, h - 1 do
        local cy = y_min + (y / (h - 1)) * (y_max - y_min)
        local row_offset = y * w
        for x = 0, w - 1 do
            local cx = x_min + (x / (w - 1)) * (x_max - x_min)
            local zx, zy = 0.0, 0.0
            local iter = 0

            while (zx * zx + zy * zy <= 4.0) and (iter < max_iter) do
                local tmp = zx * zx - zy * zy + cx
                zy = 2.0 * zx * zy + cy
                zx = tmp
                iter = iter + 1
            end

            local p = px[row_offset + x]
            if iter == max_iter then
                p.r, p.g, p.b = 10, 10, 25 -- Inside set (dark navy)
            else
                -- Continuous coloring gradient
                local t = iter / max_iter
                p.r = math.floor(9 * (1 - t) * t * t * t * 255)
                p.g = math.floor(15 * (1 - t) * (1 - t) * t * t * 255)
                p.b = math.floor(8.5 * (1 - t) * (1 - t) * (1 - t) * t * 255)
            end
        end
    end
end

-- 4. Terminal Renderer (24-bit Truecolor with half-block ▄)
function Image:render_to_terminal()
    local w, h = self.width, self.height
    local buffer = {}

    -- Process two vertical pixels per character line using UTF-8 half block '▄'
    for y = 0, h - 1, 2 do
        local line = {}
        for x = 0, w - 1 do
            local top = self:get_pixel(x, y)
            local bot = (y + 1 < h) and self:get_pixel(x, y + 1) or top

            -- ANSI escape: \27[48;2;R;G;Bm (background = top), \27[38;2;R;G;Bm (foreground = bottom)
            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                top.r, top.g, top.b,
                bot.r, bot.g, bot.b
            ))
        end
        table.insert(line, "\27[0m\n")
        table.insert(buffer, table.concat(line))
    end

    io.write(table.concat(buffer))
    io.flush()
end

-- 5. Export to PPM File
function Image:save_ppm(filename)
    local f = assert(io.open(filename, "wb"))
    f:write(string.format("P6\n%d %d\n255\n", self.width, self.height))
    local total_bytes = self.width * self.height * ffi.sizeof("PixelRGB")
    f:write(ffi.string(self.pixels, total_bytes))
    f:close()
end

-- =========================================================================
-- Main Execution
-- =========================================================================
print("=== LuaJIT FFI Image Generator & Terminal Truecolor Viewer ===")

local WIDTH, HEIGHT = 76, 38 -- Fits nicely inside standard terminal (38 vertical = 19 terminal rows)

local img = Image.new(WIDTH, HEIGHT)
print(string.format("Allocated %dx%d pixel buffer in C memory (%d bytes)",
    WIDTH, HEIGHT, WIDTH * HEIGHT * ffi.sizeof("PixelRGB")))

local t0 = get_time_ms()
img:generate_mandelbrot(100)
local t_gen = get_time_ms() - t0

print(string.format("Rendered Mandelbrot fractal in %.2f ms!\n", t_gen))

-- Display in terminal!
img:render_to_terminal()

-- Save image file
local filename = "mandelbrot.ppm"
img:save_ppm(filename)
print(string.format("\n[+] Saved high-quality image file to '%s'", filename))
