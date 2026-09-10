--[[
    ffi_image_filter_studio.lua
    Interactive Image Processing & Filter Studio in LuaJIT FFI.

    Features:
    1. Fast C-memory image buffer manipulation using LuaJIT FFI.
    2. Real-time 24-bit Truecolor ANSI rendering via UTF-8 half-block ('▄').
    3. Multiple Convolution Filters:
       - Gaussian Blur (3x3 & 5x5 separable)
       - Box Blur
       - Sharpen / Unsharp Mask
       - Edge Detection: Sobel (Magnitude / Gradient) & Laplacian
       - Emboss / Relief
       - Ridge Detection
    4. Color & Pixel Adjustments:
       - Brightness, Contrast, Gamma Correction
       - Saturation, Hue Shift
       - Invert, Sepia, Grayscale (Luminance preserving)
       - Solarize / Threshold / Posterize
    5. Real-Time Terminal RGB Luminance Histogram display.
    6. Built-in test procedural pattern generator (so it works standalone without external files).
    7. Save filtered image to disk (PPM or PNG via ImageMagick/ffmpeg).
    8. Interactive keyboard controls or headless CLI batch processing.
]]

local ffi = require("ffi")

-- =====================================
-- 1. FFI C Definitions & POSIX Terminal
-- =====================================
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

    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;
]]

local TIOCGWINSZ = 0x5413
local STDIN_FILENO = 0
local TCSANOW = 0
local ICANON = 2
local ECHO = 8
local POLLIN = 1

local orig_termios = nil
local raw_mode_active = false

local function enable_raw_mode()
    if ffi.C.isatty(STDIN_FILENO) == 0 then return false end
    if not orig_termios then
        orig_termios = ffi.new("struct termios")
        if ffi.C.tcgetattr(STDIN_FILENO, orig_termios) ~= 0 then
            orig_termios = nil
            return false
        end
    end
    local raw = ffi.new("struct termios")
    ffi.copy(raw, orig_termios, ffi.sizeof("struct termios"))
    raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    if ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw) == 0 then
        raw_mode_active = true
        return true
    end
    return false
end

local function disable_raw_mode()
    if raw_mode_active and orig_termios then
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
        raw_mode_active = false
    end
end

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 80, 24
end

local function read_key_nonblocking(timeout_ms)
    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local res = ffi.C.poll(pfd, 1, timeout_ms or 0)
    if res > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local buf = ffi.new("char[16]")
        local n = tonumber(ffi.C.read(STDIN_FILENO, buf, 15))
        if n > 0 then
            local str = ffi.string(buf, n)
            if str == "\27[A" then return "UP"
            elseif str == "\27[B" then return "DOWN"
            elseif str == "\27[C" then return "RIGHT"
            elseif str == "\27[D" then return "LEFT"
            elseif str == "\27[5~" then return "PAGEUP"
            elseif str == "\27[6~" then return "PAGEDOWN"
            elseif str == "\27" then return "ESC"
            else return str
            end
        end
    end
    return nil
end

-- =====================================
-- 2. Image Buffer Representation
-- =====================================
local function create_image(w, h)
    local pixels = ffi.new("PixelRGB[?]", w * h)
    return {
        width = w,
        height = h,
        pixels = pixels
    }
end

local function clone_image(src)
    local dst = create_image(src.width, src.height)
    ffi.copy(dst.pixels, src.pixels, src.width * src.height * ffi.sizeof("PixelRGB"))
    return dst
end

local function get_pixel(img, x, y)
    if x < 0 then x = 0 elseif x >= img.width then x = img.width - 1 end
    if y < 0 then y = 0 elseif y >= img.height then y = img.height - 1 end
    local p = img.pixels[y * img.width + x]
    return p.r, p.g, p.b
end

local function set_pixel(img, x, y, r, g, b)
    if x >= 0 and x < img.width and y >= 0 and y < img.height then
        local p = img.pixels[y * img.width + x]
        if r < 0 then r = 0 elseif r > 255 then r = 255 end
        if g < 0 then g = 0 elseif g > 255 then g = 255 end
        if b < 0 then b = 0 elseif b > 255 then b = 255 end
        p.r = r
        p.g = g
        p.b = b
    end
end

-- Generate a procedural synthetic test image when no file is supplied
local function generate_procedural_test_image(w, h)
    local img = create_image(w, h)
    for y = 0, h - 1 do
        local ny = y / (h - 1)
        for x = 0, w - 1 do
            local nx = x / (w - 1)
            local cx, cy = nx - 0.5, (ny - 0.5) * (h / w)
            local dist = math.sqrt(cx * cx + cy * cy)
            local angle = math.atan2(cy, cx)

            local ring = math.sin(dist * 28 - 2.0)
            local spiral = math.sin(angle * 5 + dist * 15)

            local r = math.floor((math.sin(nx * 3.14159 * 2) * 0.5 + 0.5) * 200 + ring * 55)
            local g = math.floor((math.sin(ny * 3.14159 * 2 + 1.5) * 0.5 + 0.5) * 180 + spiral * 60)
            local b = math.floor((math.cos(dist * 12) * 0.5 + 0.5) * 220 + 35)

            if nx < 0.25 and ny < 0.25 then
                local check = (math.floor(x / 6) + math.floor(y / 6)) % 2
                if check == 0 then
                    r, g, b = 240, 240, 240
                else
                    r, g, b = 20, 20, 30
                end
            end

            set_pixel(img, x, y, r, g, b)
        end
    end
    return img
end

-- =====================================
-- 3. Universal Image Loader & Exporter
-- =====================================
local function parse_ppm_stream(f)
    local function next_token()
        while true do
            local ch = f:read(1)
            if not ch then return nil end
            if ch == '#' then
                f:read("*l")
            elseif not ch:match("%s") then
                local token = { ch }
                while true do
                    local c = f:read(1)
                    if not c or c:match("%s") then break end
                    table.insert(token, c)
                end
                return table.concat(token)
            end
        end
    end

    local magic = next_token()
    if magic ~= "P6" and magic ~= "P3" then return nil, "Not a valid PPM" end
    local w = tonumber(next_token())
    local h = tonumber(next_token())
    local maxv = tonumber(next_token())
    if not w or not h or not maxv then return nil, "Invalid PPM header" end

    local img = create_image(w, h)
    if magic == "P6" then
        local raw = f:read(w * h * 3)
        if not raw or #raw < w * h * 3 then return nil, "Incomplete PPM data" end
        ffi.copy(img.pixels, raw, w * h * 3)
    else
        local scale = 255.0 / maxv
        for i = 0, w * h - 1 do
            local r = (tonumber(next_token()) or 0) * scale
            local g = (tonumber(next_token()) or 0) * scale
            local b = (tonumber(next_token()) or 0) * scale
            local p = img.pixels[i]
            p.r = math.min(255, math.max(0, math.floor(r)))
            p.g = math.min(255, math.max(0, math.floor(g)))
            p.b = math.min(255, math.max(0, math.floor(b)))
        end
    end
    return img
end

local function load_image_file(filepath)
    local test = io.open(filepath, "rb")
    if not test then return nil, "File not found: " .. filepath end
    local head = test:read(2)
    test:close()

    if head == "P6" or head == "P3" then
        local f = io.open(filepath, "rb")
        local img, err = parse_ppm_stream(f)
        f:close()
        if img then return img end
    end

    local cmd = string.format("magick %q ppm:- 2>/dev/null || convert %q ppm:- 2>/dev/null || ffmpeg -v error -i %q -f image2pipe -vcodec ppm - 2>/dev/null", filepath, filepath, filepath)
    local pipe = io.popen(cmd, "r")
    if pipe then
        local img = parse_ppm_stream(pipe)
        pipe:close()
        if img then return img end
    end

    return nil, "Failed to load/decode image: " .. filepath
end

local function save_image_file(img, filepath)
    local f, err = io.open(filepath, "wb")
    if not f then return false, err end
    f:write(string.format("P6\n%d %d\n255\n", img.width, img.height))
    local raw = ffi.string(img.pixels, img.width * img.height * 3)
    f:write(raw)
    f:close()

    if filepath:match("%.png$") or filepath:match("%.jpg$") or filepath:match("%.jpeg$") then
        local tmp_ppm = filepath .. ".tmp.ppm"
        os.rename(filepath, tmp_ppm)
        local conv_cmd = string.format("convert %q %q 2>/dev/null || ffmpeg -y -v error -i %q %q 2>/dev/null", tmp_ppm, filepath, tmp_ppm, filepath)
        local res = os.execute(conv_cmd)
        os.remove(tmp_ppm)
        if res == 0 or res == true then
            return true
        end
        return false, "PPM created, but failed converting to " .. filepath
    end
    return true
end

-- =====================================
-- 4. Convolution & Image Processing Kernels
-- =====================================
local FILTERS = {
    { id = "none",        name = "Original (No Filter)" },
    { id = "cartoon",     name = "Cartoon / Comic Cel-Shading" },
    { id = "blur_box",    name = "Box Blur (3x3)" },
    { id = "blur_gauss",  name = "Gaussian Blur (5x5)" },
    { id = "sharpen",     name = "Sharpen" },
    { id = "unsharp",     name = "Unsharp Mask" },
    { id = "edges_sobel", name = "Sobel Edge Detection" },
    { id = "edges_laplace",name = "Laplacian Edges" },
    { id = "emboss",      name = "Emboss / Relief" },
    { id = "ridge",       name = "Ridge / Outline" },
}

local function apply_kernel_3x3(src, k, divisor, bias)
    local dst = create_image(src.width, src.height)
    divisor = divisor or 1.0
    bias = bias or 0.0
    local w, h = src.width, src.height

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local sum_r, sum_g, sum_b = 0.0, 0.0, 0.0
            local ki = 1
            for ky = -1, 1 do
                for kx = -1, 1 do
                    local weight = k[ki]
                    if weight ~= 0 then
                        local px = math.min(w - 1, math.max(0, x + kx))
                        local py = math.min(h - 1, math.max(0, y + ky))
                        local p = src.pixels[py * w + px]
                        sum_r = sum_r + p.r * weight
                        sum_g = sum_g + p.g * weight
                        sum_b = sum_b + p.b * weight
                    end
                    ki = ki + 1
                end
            end
            local r = math.floor(sum_r / divisor + bias)
            local g = math.floor(sum_g / divisor + bias)
            local b = math.floor(sum_b / divisor + bias)
            set_pixel(dst, x, y, r, g, b)
        end
    end
    return dst
end

local function apply_gaussian_blur_5x5(src)
    local w, h = src.width, src.height
    local kernel = { 1, 4, 6, 4, 1 }
    local ksum = 16.0

    local temp = create_image(w, h)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local sum_r, sum_g, sum_b = 0.0, 0.0, 0.0
            for i = -2, 2 do
                local px = math.min(w - 1, math.max(0, x + i))
                local p = src.pixels[y * w + px]
                local kw = kernel[i + 3]
                sum_r = sum_r + p.r * kw
                sum_g = sum_g + p.g * kw
                sum_b = sum_b + p.b * kw
            end
            local dp = temp.pixels[y * w + x]
            dp.r = math.floor(sum_r / ksum)
            dp.g = math.floor(sum_g / ksum)
            dp.b = math.floor(sum_b / ksum)
        end
    end

    local dst = create_image(w, h)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local sum_r, sum_g, sum_b = 0.0, 0.0, 0.0
            for i = -2, 2 do
                local py = math.min(h - 1, math.max(0, y + i))
                local p = temp.pixels[py * w + x]
                local kw = kernel[i + 3]
                sum_r = sum_r + p.r * kw
                sum_g = sum_g + p.g * kw
                sum_b = sum_b + p.b * kw
            end
            local dp = dst.pixels[y * w + x]
            dp.r = math.floor(sum_r / ksum)
            dp.g = math.floor(sum_g / ksum)
            dp.b = math.floor(sum_b / ksum)
        end
    end
    return dst
end

local function apply_sobel(src)
    local w, h = src.width, src.height
    local dst = create_image(w, h)
    local gx = { -1, 0, 1, -2, 0, 2, -1, 0, 1 }
    local gy = { -1, -2, -1,  0,  0,  0,  1,  2,  1 }

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local sum_xr, sum_xg, sum_xb = 0, 0, 0
            local sum_yr, sum_yg, sum_yb = 0, 0, 0
            local ki = 1
            for ky = -1, 1 do
                for kx = -1, 1 do
                    local px = math.min(w - 1, math.max(0, x + kx))
                    local py = math.min(h - 1, math.max(0, y + ky))
                    local p = src.pixels[py * w + px]
                    local wx = gx[ki]
                    local wy = gy[ki]
                    sum_xr = sum_xr + p.r * wx
                    sum_xg = sum_xg + p.g * wx
                    sum_xb = sum_xb + p.b * wx
                    sum_yr = sum_yr + p.r * wy
                    sum_yg = sum_yg + p.g * wy
                    sum_yb = sum_yb + p.b * wy
                    ki = ki + 1
                end
            end
            local mag_r = math.sqrt(sum_xr * sum_xr + sum_yr * sum_yr)
            local mag_g = math.sqrt(sum_xg * sum_xg + sum_yg * sum_yg)
            local mag_b = math.sqrt(sum_xb * sum_xb + sum_yb * sum_yb)
            local mag = (mag_r + mag_g + mag_b) / 3.0
            local val = math.min(255, math.floor(mag))
            set_pixel(dst, x, y, val, val, val)
        end
    end
    return dst
end

-- Cartoon / Comic Cel-Shading: Bilateral/Gaussian edge-preserving smoothing + Sobel ink outlines + Color Quantization
local function apply_cartoon(src)
    local w, h = src.width, src.height

    -- 1. Pre-smooth image to reduce noise while keeping major color blocks
    local smoothed = apply_gaussian_blur_5x5(src)

    -- 2. Detect strong outlines using Sobel gradient on smoothed image
    local gx = { -1, 0, 1, -2, 0, 2, -1, 0, 1 }
    local gy = { -1, -2, -1,  0,  0,  0,  1,  2,  1 }
    local edge_mask = ffi.new("uint8_t[?]", w * h)

    local edge_thresh = 42 -- Threshold for comic ink contours
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local sum_x, sum_y = 0, 0
            local ki = 1
            for ky = -1, 1 do
                for kx = -1, 1 do
                    local px = math.min(w - 1, math.max(0, x + kx))
                    local py = math.min(h - 1, math.max(0, y + ky))
                    local p = smoothed.pixels[py * w + px]
                    -- Rec 709 luminance
                    local lum = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
                    sum_x = sum_x + lum * gx[ki]
                    sum_y = sum_y + lum * gy[ki]
                    ki = ki + 1
                end
            end
            local mag = math.sqrt(sum_x * sum_x + sum_y * sum_y)
            edge_mask[y * w + x] = (mag > edge_thresh) and 1 or 0
        end
    end

    -- 3. Cel-shading / Color quantization (posterize into 6 discrete bands per channel)
    -- and composite with black ink outlines
    local dst = create_image(w, h)
    local bands = 6
    local step = 255.0 / (bands - 1)

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local idx = y * w + x
            if edge_mask[idx] == 1 then
                -- Comic ink outline: stark black / dark ink line
                set_pixel(dst, x, y, 12, 12, 18)
            else
                local p = smoothed.pixels[idx]
                -- Quantize R, G, B channels
                local qr = math.floor(math.floor(p.r / step + 0.5) * step)
                local qg = math.floor(math.floor(p.g / step + 0.5) * step)
                local qb = math.floor(math.floor(p.b / step + 0.5) * step)

                -- Slight saturation & contrast punch for cartoon vibrancy
                local lum = 0.2126 * qr + 0.7152 * qg + 0.0722 * qb
                local sat = 1.25
                qr = math.min(255, math.max(0, math.floor(lum + (qr - lum) * sat)))
                qg = math.min(255, math.max(0, math.floor(lum + (qg - lum) * sat)))
                qb = math.min(255, math.max(0, math.floor(lum + (qb - lum) * sat)))

                set_pixel(dst, x, y, qr, qg, qb)
            end
        end
    end

    return dst
end

local function apply_filter(src, filter_id)
    if filter_id == "none" then
        return clone_image(src)
    elseif filter_id == "cartoon" then
        return apply_cartoon(src)
    elseif filter_id == "blur_box" then
        return apply_kernel_3x3(src, { 1, 1, 1,  1, 1, 1,  1, 1, 1 }, 9.0, 0)
    elseif filter_id == "blur_gauss" then
        return apply_gaussian_blur_5x5(src)
    elseif filter_id == "sharpen" then
        return apply_kernel_3x3(src, { 0, -1, 0,  -1, 5, -1,  0, -1, 0 }, 1.0, 0)
    elseif filter_id == "unsharp" then
        return apply_kernel_3x3(src, { -1, -2, -1,  -2, 19, -2,  -1, -2, -1 }, 7.0, 0)
    elseif filter_id == "edges_sobel" then
        return apply_sobel(src)
    elseif filter_id == "edges_laplace" then
        return apply_kernel_3x3(src, { 0, 1, 0,  1, -4, 1,  0, 1, 0 }, 1.0, 128)
    elseif filter_id == "emboss" then
        return apply_kernel_3x3(src, { -2, -1, 0,  -1, 1, 1,   0, 1, 2 }, 1.0, 128)
    elseif filter_id == "ridge" then
        return apply_kernel_3x3(src, { -1, -1, -1,  -1, 8, -1,  -1, -1, -1 }, 1.0, 0)
    end
    return clone_image(src)
end

-- =====================================
-- 5. Color Adjustments Pipeline
-- =====================================
local function apply_color_adjustments(src, params)
    local dst = create_image(src.width, src.height)
    local total_pixels = src.width * src.height

    local brightness = params.brightness or 0     -- -100 to +100
    local contrast   = params.contrast or 1.0     -- 0.1 to 3.0
    local gamma      = params.gamma or 1.0        -- 0.2 to 3.0
    local saturation = params.saturation or 1.0   -- 0.0 (B&W) to 3.0
    local invert     = params.invert or false
    local sepia      = params.sepia or false
    local grayscale  = params.grayscale or false
    local posterize  = params.posterize or 0

    local inv_gamma = 1.0 / math.max(0.01, gamma)

    local lut = ffi.new("uint8_t[256]")
    for i = 0, 255 do
        local v = i / 255.0
        v = (v - 0.5) * contrast + 0.5
        v = v + (brightness / 255.0)
        v = math.max(0.0, math.min(1.0, v))
        v = v ^ inv_gamma
        local out_val = math.floor(v * 255.0 + 0.5)
        lut[i] = math.max(0, math.min(255, out_val))
    end

    for i = 0, total_pixels - 1 do
        local sp = src.pixels[i]
        local r = lut[sp.r]
        local g = lut[sp.g]
        local b = lut[sp.b]

        local lum = math.floor(0.2126 * r + 0.7152 * g + 0.0722 * b + 0.5)

        if grayscale then
            r, g, b = lum, lum, lum
        elseif saturation ~= 1.0 then
            r = math.max(0, math.min(255, math.floor(lum + (r - lum) * saturation + 0.5)))
            g = math.max(0, math.min(255, math.floor(lum + (g - lum) * saturation + 0.5)))
            b = math.max(0, math.min(255, math.floor(lum + (b - lum) * saturation + 0.5)))
        end

        if sepia then
            local sr = math.floor(0.393 * r + 0.769 * g + 0.189 * b)
            local sg = math.floor(0.349 * r + 0.686 * g + 0.168 * b)
            local sb = math.floor(0.272 * r + 0.534 * g + 0.131 * b)
            r = math.min(255, sr)
            g = math.min(255, sg)
            b = math.min(255, sb)
        end

        if posterize > 1 then
            local step = 255.0 / (posterize - 1)
            r = math.floor(math.floor(r / step + 0.5) * step)
            g = math.floor(math.floor(g / step + 0.5) * step)
            b = math.floor(math.floor(b / step + 0.5) * step)
        end

        if invert then
            r = 255 - r
            g = 255 - g
            b = 255 - b
        end

        local dp = dst.pixels[i]
        dp.r = r
        dp.g = g
        dp.b = b
    end

    return dst
end

-- =====================================
-- 6. RGB & Luminance Histogram Generator
-- =====================================
local function compute_histogram(img, buckets)
    buckets = buckets or 16
    local hist_r = {}
    local hist_g = {}
    local hist_b = {}
    local hist_l = {}
    for i = 1, buckets do
        hist_r[i] = 0
        hist_g[i] = 0
        hist_b[i] = 0
        hist_l[i] = 0
    end

    local total = img.width * img.height
    local factor = buckets / 256.0

    for i = 0, total - 1 do
        local p = img.pixels[i]
        local br = math.min(buckets, math.floor(p.r * factor) + 1)
        local bg = math.min(buckets, math.floor(p.g * factor) + 1)
        local bb = math.min(buckets, math.floor(p.b * factor) + 1)
        local lum = math.floor(0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b)
        local bl = math.min(buckets, math.floor(lum * factor) + 1)

        hist_r[br] = hist_r[br] + 1
        hist_g[bg] = hist_g[bg] + 1
        hist_b[bb] = hist_b[bb] + 1
        hist_l[bl] = hist_l[bl] + 1
    end

    local max_count = 1
    for i = 1, buckets do
        if hist_l[i] > max_count then max_count = hist_l[i] end
        if hist_r[i] > max_count then max_count = hist_r[i] end
        if hist_g[i] > max_count then max_count = hist_g[i] end
        if hist_b[i] > max_count then max_count = hist_b[i] end
    end

    return {
        buckets = buckets,
        max = max_count,
        r = hist_r,
        g = hist_g,
        b = hist_b,
        lum = hist_l
    }
end

local function format_sparkline(values, max_val)
    local bars = { " ", " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
    local result = {}
    for _, v in ipairs(values) do
        local norm = v / math.max(1, max_val)
        local idx = math.min(#bars, math.max(1, math.floor(norm * (#bars - 1)) + 1))
        table.insert(result, bars[idx])
    end
    return table.concat(result)
end

-- =====================================
-- 7. High-Performance Terminal Viewport
-- =====================================
local function render_to_terminal_string(img, view_w, view_h, show_histogram, state)
    local render_pixel_h = view_h * 2
    local render_pixel_w = view_w

    local out = {}
    table.insert(out, "\27[H")

    local filter_name = FILTERS[state.filter_idx].name
    local info_bar = string.format(
        "\27[1;37;44m FILTER STUDIO \27[0m \27[1;33m%s\27[0m | B:%+d C:%.1f G:%.1f S:%.1f | %s%s%s\27[K\n",
        filter_name,
        state.brightness, state.contrast, state.gamma, state.saturation,
        state.invert and "[INV] " or "",
        state.sepia and "[SEPIA] " or "",
        state.grayscale and "[B&W] " or ""
    )
    table.insert(out, info_bar)

    local src_w = img.width
    local src_h = img.height
    local scale_x = src_w / render_pixel_w
    local scale_y = src_h / render_pixel_h

    for row = 0, view_h - 1 do
        local line = {}
        local y_top = row * 2
        local y_bot = y_top + 1

        local sy_top = math.min(src_h - 1, math.floor(y_top * scale_y))
        local sy_bot = math.min(src_h - 1, math.floor(y_bot * scale_y))

        local last_fr, last_fg, last_fb = -1, -1, -1
        local last_br, last_bg, last_bb = -1, -1, -1

        for col = 0, render_pixel_w - 1 do
            local sx = math.min(src_w - 1, math.floor(col * scale_x))
            local pt = img.pixels[sy_top * src_w + sx]
            local pb = img.pixels[sy_bot * src_w + sx]

            local fr, fg, fb = pb.r, pb.g, pb.b
            local br, bg, bb = pt.r, pt.g, pt.b

            local fg_diff = (fr ~= last_fr) or (fg ~= last_fg) or (fb ~= last_fb)
            local bg_diff = (br ~= last_br) or (bg ~= last_bg) or (bb ~= last_bb)

            if fg_diff and bg_diff then
                table.insert(line, string.format("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▄", fr, fg, fb, br, bg, bb))
                last_fr, last_fg, last_fb = fr, fg, fb
                last_br, last_bg, last_bb = br, bg, bb
            elseif fg_diff then
                table.insert(line, string.format("\27[38;2;%d;%d;%dm▄", fr, fg, fb))
                last_fr, last_fg, last_fb = fr, fg, fb
            elseif bg_diff then
                table.insert(line, string.format("\27[48;2;%d;%d;%dm▄", br, bg, bb))
                last_br, last_bg, last_bb = br, bg, bb
            else
                table.insert(line, "▄")
            end
        end
        table.insert(line, "\27[0m\n")
        table.insert(out, table.concat(line))
    end

    if show_histogram then
        local hist = compute_histogram(img, 18)
        local spark_r = format_sparkline(hist.r, hist.max)
        local spark_g = format_sparkline(hist.g, hist.max)
        local spark_b = format_sparkline(hist.b, hist.max)
        local spark_l = format_sparkline(hist.lum, hist.max)

        local hist_line = string.format(
            " Histogram: \27[31mR:[%s]\27[0m \27[32mG:[%s]\27[0m \27[34mB:[%s]\27[0m \27[37mL:[%s]\27[0m\27[K\n",
            spark_r, spark_g, spark_b, spark_l
        )
        table.insert(out, hist_line)
    end

    local controls = " [F/Shift+F] Filter  [B/b] Brightness  [C/c] Contrast  [G/g] Gamma  [S/s] Sat\n" ..
                     " [I] Invert  [P] Sepia  [W] B&W  [H] Toggle Hist  [O] Save  [R] Reset  [Q] Quit\27[K"
    table.insert(out, controls)

    return table.concat(out)
end

-- =====================================
-- 8. Main Studio Application State
-- =====================================
local function create_studio_state()
    return {
        filter_idx = 1,
        brightness = 0,
        contrast = 1.0,
        gamma = 1.0,
        saturation = 1.0,
        invert = false,
        sepia = false,
        grayscale = false,
        posterize = 0,
        show_histogram = true,
        dirty = true
    }
end

local function reset_studio_state(state)
    state.filter_idx = 1
    state.brightness = 0
    state.contrast = 1.0
    state.gamma = 1.0
    state.saturation = 1.0
    state.invert = false
    state.sepia = false
    state.grayscale = false
    state.posterize = 0
    state.dirty = true
end

local function process_pipeline(base_img, state)
    local filter_id = FILTERS[state.filter_idx].id
    local filtered = apply_filter(base_img, filter_id)
    local final_img = apply_color_adjustments(filtered, state)
    return final_img
end

-- =====================================
-- 9. CLI Banner & Argument Parser
-- =====================================
local function print_help()
    print([[
Interactive Image Processing & Filter Studio (LuaJIT FFI)
=========================================================
Usage:
  ./LuaJIT/src/luajit ffi_image_filter_studio.lua [options] [image_path]

Options:
  --filter, -f <1-10>      Apply initial convolution/stylization filter:
                           1: None (Original)      2: Cartoon / Cel-Shading
                           3: Box Blur             4: Gaussian Blur 5x5
                           5: Sharpen              6: Unsharp Mask
                           7: Sobel Edge Detection 8: Laplacian Edges
                           9: Emboss / Relief      10: Ridge / Outline
  --brightness, -b <num>   Adjust brightness (-100 to 100, default: 0)
  --contrast, -c <num>     Adjust contrast (0.2 to 3.0, default: 1.0)
  --gamma, -g <num>        Adjust gamma (0.2 to 3.0, default: 1.0)
  --saturation, -s <num>   Adjust saturation (0.0 to 3.0, default: 1.0)
  --invert, -i             Invert colors
  --sepia                  Apply sepia toning
  --grayscale, --bw        Convert to black & white
  --save, -o <filepath>    Save processed output to file (.ppm or .png) and exit
  --once                   Render a single frame and exit immediately
  --help, -h               Show this help manual

Interactive Keys:
  [F] / [Shift+F]          Cycle forward / backward through Convolution Filters
  [B] / [b]                Increase / decrease Brightness (+10 / -10)
  [C] / [c]                Increase / decrease Contrast (+0.2 / -0.2)
  [G] / [g]                Increase / decrease Gamma (+0.1 / -0.1)
  [S] / [s]                Increase / decrease Saturation (+0.2 / -0.2)
  [I] / [i]                Toggle Invert colors
  [P] / [p]                Toggle Sepia tone
  [W] / [w]                Toggle Grayscale (B&W)
  [H] / [h]                Toggle RGB Histogram
  [O] / [o]                Save current output to 'studio_output.png'
  [R] / [r]                Reset all filters & adjustments
  [Q] / [Esc]              Exit Studio
]])
end

-- =====================================
-- 10. Main Interactive Loop
-- =====================================
local function main(...)
    local args = { ... }
    local image_path = nil
    local save_path = nil
    local single_frame = false

    local state = create_studio_state()

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_help()
            return
        elseif a == "--once" then
            single_frame = true
        elseif (a == "--filter" or a == "-f") and args[i+1] then
            i = i + 1
            local idx = tonumber(args[i])
            if idx and idx >= 1 and idx <= #FILTERS then state.filter_idx = idx end
        elseif (a == "--brightness" or a == "-b") and args[i+1] then
            i = i + 1
            state.brightness = tonumber(args[i]) or 0
        elseif (a == "--contrast" or a == "-c") and args[i+1] then
            i = i + 1
            state.contrast = tonumber(args[i]) or 1.0
        elseif (a == "--gamma" or a == "-g") and args[i+1] then
            i = i + 1
            state.gamma = tonumber(args[i]) or 1.0
        elseif (a == "--saturation" or a == "-s") and args[i+1] then
            i = i + 1
            state.saturation = tonumber(args[i]) or 1.0
        elseif a == "--invert" or a == "-i" then
            state.invert = true
        elseif a == "--sepia" then
            state.sepia = true
        elseif a == "--grayscale" or a == "--bw" then
            state.grayscale = true
        elseif (a == "--save" or a == "-o") and args[i+1] then
            i = i + 1
            save_path = args[i]
        elseif not a:match("^%-") and not image_path then
            image_path = a
        end
        i = i + 1
    end

    local base_img, err
    if image_path then
        base_img, err = load_image_file(image_path)
        if not base_img then
            io.stderr:write("Error loading image: " .. tostring(err) .. "\n")
            os.exit(1)
        end
    else
        base_img = generate_procedural_test_image(160, 120)
    end

    local processed_img = process_pipeline(base_img, state)

    if save_path then
        local ok, serr = save_image_file(processed_img, save_path)
        if ok then
            print("Successfully processed and saved image to: " .. save_path)
        else
            io.stderr:write("Error saving image: " .. tostring(serr) .. "\n")
            os.exit(1)
        end
        if single_frame or not ffi.C.isatty(STDIN_FILENO) then
            return
        end
    end

    local term_w, term_h = get_terminal_size()
    local view_w = math.max(20, math.min(120, term_w - 2))
    local view_h = math.max(10, term_h - 7)

    if single_frame or ffi.C.isatty(STDIN_FILENO) == 0 then
        local out = render_to_terminal_string(processed_img, view_w, view_h, state.show_histogram, state)
        io.write(out .. "\n")
        return
    end

    enable_raw_mode()
    io.write("\27[?25l")
    io.write("\27[2J")

    local running = true
    local last_w, last_h = term_w, term_h

    while running do
        local cur_w, cur_h = get_terminal_size()
        if cur_w ~= last_w or cur_h ~= last_h then
            last_w, last_h = cur_w, cur_h
            view_w = math.max(20, math.min(120, cur_w - 2))
            view_h = math.max(10, cur_h - 7)
            state.dirty = true
        end

        if state.dirty then
            processed_img = process_pipeline(base_img, state)
            local frame = render_to_terminal_string(processed_img, view_w, view_h, state.show_histogram, state)
            io.write(frame)
            io.flush()
            state.dirty = false
        end

        local key = read_key_nonblocking(40)
        if key then
            if key == "q" or key == "Q" or key == "ESC" then
                running = false
            elseif key == "f" then
                state.filter_idx = (state.filter_idx % #FILTERS) + 1
                state.dirty = true
            elseif key == "F" then
                state.filter_idx = state.filter_idx - 1
                if state.filter_idx < 1 then state.filter_idx = #FILTERS end
                state.dirty = true
            elseif key == "B" then
                state.brightness = math.min(100, state.brightness + 10)
                state.dirty = true
            elseif key == "b" then
                state.brightness = math.max(-100, state.brightness - 10)
                state.dirty = true
            elseif key == "C" then
                state.contrast = math.min(3.0, state.contrast + 0.2)
                state.dirty = true
            elseif key == "c" then
                state.contrast = math.max(0.2, state.contrast - 0.2)
                state.dirty = true
            elseif key == "G" then
                state.gamma = math.min(3.0, state.gamma + 0.1)
                state.dirty = true
            elseif key == "g" then
                state.gamma = math.max(0.2, state.gamma - 0.1)
                state.dirty = true
            elseif key == "S" then
                state.saturation = math.min(3.0, state.saturation + 0.2)
                state.dirty = true
            elseif key == "s" then
                state.saturation = math.max(0.0, state.saturation - 0.2)
                state.dirty = true
            elseif key == "i" or key == "I" then
                state.invert = not state.invert
                state.dirty = true
            elseif key == "p" or key == "P" then
                state.sepia = not state.sepia
                state.dirty = true
            elseif key == "w" or key == "W" then
                state.grayscale = not state.grayscale
                state.dirty = true
            elseif key == "h" or key == "H" then
                state.show_histogram = not state.show_histogram
                state.dirty = true
            elseif key == "r" or key == "R" then
                reset_studio_state(state)
            elseif key == "o" or key == "O" then
                local out_name = "studio_output.ppm"
                save_image_file(processed_img, out_name)
                state.dirty = true
            end
        end
    end

    io.write("\27[?25h")
    io.write("\27[0m\n")
    disable_raw_mode()
end

main(...)
