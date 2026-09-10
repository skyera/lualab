--[[
    gallery_portrait.lua
    Dynamic Lady Portrait Gallery & Interactive Terminal Truecolor Viewer
    Built with LuaJIT FFI.

    Features:
    1. Portraits of Ladies:
       - Supports curated photo/art portraits of ladies (Traditional Hanfu, Silk Pavilion,
         Cyberpunk Neon, Renaissance Emerald, Modern Studio, Bohemian Floral).
       - Dynamic procedural lady portrait generation with randomized hairstyles,
         jewelry, hairpins, dresses, skin tones, and lighting.
    2. Dynamic Side-by-Side Gallery Grid:
       - Multi-column layout scaled to terminal width using 24-bit truecolor half-blocks ('▄').
       - Highlights active selection with glowing focus frame and badge.
    3. Interactive Selector & Full High-Resolution Display:
       - Browse with arrow keys (← / → / ↑ / ↓) or direct numbers (1-6).
       - Press Enter to inspect selected lady portrait enlarged with dominant color palette analysis.
       - Re-roll procedural variations ('R'), save image to disk ('S'), export HTML ('H').
    4. POSIX Raw Mode & CLI fallbacks:
       - Instant keystrokes via tcsetattr/poll when interactive.
       - Graceful fallback for non-interactive / piped environments and CLI flags.
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. C Declarations for Terminal, POSIX I/O, Clock, and Pixel Buffers
-- =========================================================================
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
local CLOCK_MONOTONIC = 1

local function get_time_ms()
    local ts = ffi.new("timespec_t")
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 80, 24
end

-- =========================================================================
-- 2. Terminal Raw Mode Management
-- =========================================================================
local orig_termios = ffi.new("struct termios")
local raw_termios = ffi.new("struct termios")
local raw_mode_enabled = false

local function enable_raw_mode()
    if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
    ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
    ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

    raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
    raw_mode_enabled = true

    io.write("\27[?25l") -- Hide cursor
    io.flush()
    return true
end

local function disable_raw_mode()
    if raw_mode_enabled then
        io.write("\27[?25h\27[0m\n") -- Restore cursor and reset color
        io.flush()
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
        raw_mode_enabled = false
    end
end

local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
local key_buf = ffi.new("char[16]")

local function read_key(timeout_ms)
    timeout_ms = timeout_ms or -1
    local ret = ffi.C.poll(pfd, 1, timeout_ms)
    if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local n = ffi.C.read(STDIN_FILENO, key_buf, 16)
        if n > 0 then
            local c0 = key_buf[0]
            if c0 == 27 then -- ESC
                if n >= 3 and key_buf[1] == 91 then -- '['
                    local c2 = key_buf[2]
                    if c2 == 65 then return "UP" end
                    if c2 == 66 then return "DOWN" end
                    if c2 == 67 then return "RIGHT" end
                    if c2 == 68 then return "LEFT" end
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

-- =========================================================================
-- 3. Image Class (C Pixel Memory & Resampling)
-- =========================================================================
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
        self.pixels[idx].r = math.min(255, math.max(0, math.floor(r)))
        self.pixels[idx].g = math.min(255, math.max(0, math.floor(g)))
        self.pixels[idx].b = math.min(255, math.max(0, math.floor(b)))
    end
end

function Image:get_pixel(x, y)
    if x >= 0 and x < self.width and y >= 0 and y < self.height then
        return self.pixels[y * self.width + x]
    end
    return nil
end

function Image:blend_pixel(x, y, r, g, b, alpha)
    if alpha <= 0 then return end
    if alpha >= 1.0 then self:set_pixel(x, y, r, g, b) return end
    if x >= 0 and x < self.width and y >= 0 and y < self.height then
        local p = self.pixels[y * self.width + x]
        p.r = math.min(255, math.max(0, math.floor(p.r * (1 - alpha) + r * alpha)))
        p.g = math.min(255, math.max(0, math.floor(p.g * (1 - alpha) + g * alpha)))
        p.b = math.min(255, math.max(0, math.floor(p.b * (1 - alpha) + b * alpha)))
    end
end

function Image:fill(r, g, b)
    for i = 0, self.width * self.height - 1 do
        self.pixels[i].r = r
        self.pixels[i].g = g
        self.pixels[i].b = b
    end
end

function Image:fill_circle(cx, cy, radius, r, g, b, alpha)
    alpha = alpha or 1.0
    local r2 = radius * radius
    for y = math.floor(cy - radius), math.ceil(cy + radius) do
        for x = math.floor(cx - radius), math.ceil(cx + radius) do
            local dx = x - cx
            local dy = y - cy
            if dx * dx + dy * dy <= r2 then
                self:blend_pixel(x, y, r, g, b, alpha)
            end
        end
    end
end

-- Renders a character row of the image using ANSI half-blocks
function Image:render_row_ansi(y_top)
    local y_bot = y_top + 1
    local w = self.width
    local line = {}

    for x = 0, w - 1 do
        local top = self:get_pixel(x, y_top)
        local bot = (y_bot < self.height) and self:get_pixel(x, y_bot) or top
        table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
            top.r, top.g, top.b,
            bot.r, bot.g, bot.b
        ))
    end
    table.insert(line, "\27[0m")
    return table.concat(line)
end

-- Fast bilinear or nearest-neighbor resampling
function Image:resample(target_w, target_h)
    local out = Image.new(target_w, target_h)
    local scale_x = self.width / target_w
    local scale_y = self.height / target_h

    for y = 0, target_h - 1 do
        local src_y = math.min(self.height - 1, math.floor(y * scale_y))
        for x = 0, target_w - 1 do
            local src_x = math.min(self.width - 1, math.floor(x * scale_x))
            local p = self:get_pixel(src_x, src_y)
            out:set_pixel(x, y, p.r, p.g, p.b)
        end
    end
    return out
end

-- Extract dominant representative color palette
function Image:extract_palette(count)
    count = count or 6
    local buckets = {}
    local step_x = math.max(1, math.floor(self.width / 20))
    local step_y = math.max(1, math.floor(self.height / 20))

    for y = 0, self.height - 1, step_y do
        for x = 0, self.width - 1, step_x do
            local p = self:get_pixel(x, y)
            local qr = math.floor(p.r / 32) * 32 + 16
            local qg = math.floor(p.g / 32) * 32 + 16
            local qb = math.floor(p.b / 32) * 32 + 16
            local key = string.format("%d,%d,%d", qr, qg, qb)
            if not buckets[key] then
                buckets[key] = {r = qr, g = qg, b = qb, count = 0}
            end
            buckets[key].count = buckets[key].count + 1
        end
    end

    local list = {}
    for _, b in pairs(buckets) do table.insert(list, b) end
    table.sort(list, function(a, b) return a.count > b.count end)

    local result = {}
    for i = 1, math.min(count, #list) do
        table.insert(result, list[i])
    end
    return result
end

function Image:save_ppm(filename)
    local f = io.open(filename, "wb")
    if not f then return false, "Cannot write to " .. filename end
    f:write(string.format("P6\n%d %d\n255\n", self.width, self.height))
    f:write(ffi.string(self.pixels, self.width * self.height * 3))
    f:close()
    return true
end

function Image:save_png(png_path)
    local ppm_temp = png_path:gsub("%.png$", "") .. "_temp.ppm"
    self:save_ppm(ppm_temp)
    local cmd = string.format("convert %q %q 2>/dev/null || ffmpeg -y -i %q %q 2>/dev/null",
        ppm_temp, png_path, ppm_temp, png_path)
    local ret = os.execute(cmd)
    os.remove(ppm_temp)
    if ret == 0 then return true end
    os.rename(ppm_temp, png_path:gsub("%.png$", ".ppm"))
    return false, "ImageMagick/ffmpeg not found; saved as PPM format instead."
end

-- =========================================================================
-- 4. Universal Image File Loader (Netpbm PPM, PNG, JPG, WEBP)
-- =========================================================================
local function parse_ppm_stream(f)
    local function next_token()
        while true do
            local ch = f:read(1)
            if not ch then return nil end
            if ch == "#" then
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
    if magic ~= "P6" and magic ~= "P3" then return nil, "Unsupported PPM magic" end
    local width = tonumber(next_token())
    local height = tonumber(next_token())
    local max_val = tonumber(next_token())
    if not width or not height or not max_val then return nil, "Corrupted PPM header" end

    local img = Image.new(width, height)
    if magic == "P6" then
        local total_bytes = width * height * 3
        local raw = f:read(total_bytes)
        if not raw or #raw < total_bytes then return nil, "Incomplete PPM stream" end
        ffi.copy(img.pixels, raw, total_bytes)
    else
        local scale = 255.0 / max_val
        for i = 0, width * height - 1 do
            local r = tonumber(next_token()) or 0
            local g = tonumber(next_token()) or 0
            local b = tonumber(next_token()) or 0
            img.pixels[i].r = math.floor(r * scale)
            img.pixels[i].g = math.floor(g * scale)
            img.pixels[i].b = math.floor(b * scale)
        end
    end
    return img
end

local function load_resized_image(filepath, target_w, target_h)
    local test = io.open(filepath, "rb")
    if not test then return nil end
    test:close()

    local cmd = string.format("convert -resize %dx%d\\! %q ppm:- 2>/dev/null || ffmpeg -v error -i %q -vf scale=%d:%d -f image2pipe -vcodec ppm - 2>/dev/null",
        target_w, target_h, filepath, filepath, target_w, target_h)
    local pipe = io.popen(cmd, "r")
    if pipe then
        local img = parse_ppm_stream(pipe)
        pipe:close()
        if img then return img end
    end
    return nil
end

-- =========================================================================
-- 5. Procedural Lady Portrait Generators (Dynamic Variety)
-- =========================================================================

-- Procedural Lady 1: Traditional Hanfu Lady (Updo, hairpins, porcelain skin, silk collar)
local function gen_lady_hanfu(img, seed)
    math.randomseed(seed)
    local w, h = img.width, img.height
    local cx, cy = w / 2, h * 0.40

    -- Background: soft Chinese watercolor garden / bamboo wash
    local bg_top = {math.random(220, 240), math.random(225, 245), math.random(220, 235)}
    local bg_bot = {math.random(180, 210), math.random(200, 225), math.random(190, 215)}
    for y = 0, h - 1 do
        local t = y / (h - 1)
        for x = 0, w - 1 do
            local r = bg_top[1] * (1 - t) + bg_bot[1] * t
            local g = bg_top[2] * (1 - t) + bg_bot[2] * t
            local b = bg_top[3] * (1 - t) + bg_bot[3] * t
            img:set_pixel(x, y, r, g, b)
        end
    end

    -- Soft halo circle
    img:fill_circle(cx, cy, math.min(w, h) * 0.38, 255, 255, 255, 0.35)

    -- Silk Robe / Hanfu
    local shoulder_y = h * 0.65
    local robe_col = {math.random(230, 250), math.random(215, 240), math.random(210, 235)}
    for y = math.floor(shoulder_y), h - 1 do
        local dy = (y - shoulder_y) / (h - shoulder_y)
        local sw = (w * 0.28) + dy * (w * 0.48)
        for x = math.floor(cx - sw), math.ceil(cx + sw) do
            local edge = math.abs(x - cx) / sw
            local sh = 1.0 - edge * 0.2 - (1 - dy) * 0.1
            img:set_pixel(x, y, robe_col[1] * sh, robe_col[2] * sh, robe_col[3] * sh)
        end
    end

    -- Crossed silk lapel
    for y = math.floor(shoulder_y), h - 1 do
        local lx = cx + (y - shoulder_y) * 0.35
        img:set_pixel(math.floor(lx), y, 210, 185, 175)
        img:set_pixel(math.floor(lx) + 1, y, 220, 195, 185)
    end

    -- Slender Neck
    local neck_w = w * 0.11
    for y = math.floor(h * 0.50), math.floor(shoulder_y + 1) do
        for x = math.floor(cx - neck_w), math.ceil(cx + neck_w) do
            img:set_pixel(x, y, 248, 226, 215)
        end
    end

    -- Face
    local rx = w * 0.20
    local ry = h * 0.18
    for y = math.floor(cy - ry), math.ceil(cy + ry) do
        for x = math.floor(cx - rx), math.ceil(cx + rx) do
            local dx = (x - cx) / rx
            local dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1.0 then
                -- Porcelain skin with delicate blush on cheeks
                local blush = (dy > 0.0 and dy < 0.4 and math.abs(dx) > 0.4) and 0.12 or 0
                img:set_pixel(x, y, 250, 228 - blush * 40, 218 - blush * 30)
            end
        end
    end

    -- Eyes & gentle eyeliner
    local eye_y = math.floor(cy - ry * 0.05)
    local eye_dx = math.floor(rx * 0.45)
    for _, sign in ipairs({-1, 1}) do
        local ex = cx + sign * eye_dx
        img:set_pixel(ex - 1, eye_y, 255, 255, 255)
        img:set_pixel(ex, eye_y, 75, 45, 30)
        img:set_pixel(ex + 1, eye_y, 255, 255, 255)
        img:set_pixel(ex, eye_y, 25, 15, 10)
        -- Subtle arched eyebrow
        img:set_pixel(ex - 1, eye_y - 2, 80, 60, 55)
        img:set_pixel(ex, eye_y - 2, 80, 60, 55)
        img:set_pixel(ex + 1, eye_y - 2, 80, 60, 55)
    end

    -- Soft rosy lips
    local mouth_y = math.floor(cy + ry * 0.58)
    for x = math.floor(cx - 2), math.ceil(cx + 2) do
        img:set_pixel(x, mouth_y, 225, 105, 115)
    end

    -- Elegant black updo bun
    local bun_r = rx * 1.05
    local bun_cy = cy - ry * 0.75
    for y = math.floor(bun_cy - bun_r), math.ceil(cy - ry * 0.3) do
        for x = math.floor(cx - bun_r), math.ceil(cx + bun_r) do
            local d = math.sqrt((x - cx)^2 + (y - bun_cy)^2)
            if d <= bun_r then
                img:set_pixel(x, y, 25, 20, 25)
            end
        end
    end

    -- Hair framing sides
    for y = math.floor(cy - ry * 0.7), math.floor(shoulder_y) do
        for _, sign in ipairs({-1, 1}) do
            local hx = cx + sign * (rx + 1)
            img:set_pixel(math.floor(hx), y, 28, 22, 28)
        end
    end

    -- Pearl / Jade hairpin ornament with dangling pearls
    local pin_x = cx + rx * 0.65
    local pin_y = cy - ry * 0.7
    img:set_pixel(math.floor(pin_x), math.floor(pin_y), 220, 240, 210)
    img:set_pixel(math.floor(pin_x) + 1, math.floor(pin_y) - 1, 245, 245, 230)
    img:set_pixel(math.floor(pin_x) + 2, math.floor(pin_y) - 2, 220, 240, 210)
    -- Dangling pearls
    for dy = 1, 4 do
        img:set_pixel(math.floor(pin_x) + 1, math.floor(pin_y + dy), 245, 245, 240)
    end
end

-- Procedural Lady 2: Cyberpunk Neon Lady (Neon violet bob, cyber earring, leather collar)
local function gen_lady_cyberpunk(img, seed)
    math.randomseed(seed)
    local w, h = img.width, img.height
    local cx, cy = w / 2, h * 0.40

    -- Dark neon city backdrop
    for y = 0, h - 1 do
        local t = y / (h - 1)
        for x = 0, w - 1 do
            img:set_pixel(x, y, 15 * (1 - t) + 45 * t, 10 * (1 - t) + 15 * t, 35 * (1 - t) + 70 * t)
        end
    end
    -- City neon bokeh circles
    img:fill_circle(w * 0.25, h * 0.25, 4, 255, 40, 180, 0.4)
    img:fill_circle(w * 0.75, h * 0.35, 5, 40, 220, 255, 0.35)

    -- High-collar leather jacket
    local shoulder_y = h * 0.65
    for y = math.floor(shoulder_y), h - 1 do
        local dy = (y - shoulder_y) / (h - shoulder_y)
        local sw = (w * 0.3) + dy * (w * 0.48)
        for x = math.floor(cx - sw), math.ceil(cx + sw) do
            img:set_pixel(x, y, 22, 20, 28)
        end
    end
    -- Neon cyan jacket piping
    for y = math.floor(shoulder_y + 2), h - 1 do
        local lx = cx - w * 0.18 + (y - shoulder_y) * 0.15
        local rx = cx + w * 0.18 - (y - shoulder_y) * 0.15
        img:set_pixel(math.floor(lx), y, 0, 240, 255)
        img:set_pixel(math.floor(rx), y, 0, 240, 255)
    end

    -- Neck & Face
    for y = math.floor(h * 0.50), math.floor(shoulder_y + 1) do
        for x = math.floor(cx - w * 0.12), math.ceil(cx + w * 0.12) do
            img:set_pixel(x, y, 235, 195, 175)
        end
    end
    local rx = w * 0.21
    local ry = h * 0.18
    for y = math.floor(cy - ry), math.ceil(cy + ry) do
        for x = math.floor(cx - rx), math.ceil(cx + rx) do
            local dx = (x - cx) / rx
            local dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1.0 then
                img:set_pixel(x, y, 242, 202, 182)
            end
        end
    end

    -- Eyes: winged eyeliner & dark irises
    local eye_y = math.floor(cy - ry * 0.05)
    local eye_dx = math.floor(rx * 0.46)
    for _, sign in ipairs({-1, 1}) do
        local ex = cx + sign * eye_dx
        img:set_pixel(ex - 1, eye_y, 250, 250, 250)
        img:set_pixel(ex, eye_y, 40, 30, 25)
        img:set_pixel(ex + 1, eye_y, 250, 250, 250)
        img:set_pixel(ex + sign * 2, eye_y - 1, 20, 15, 25) -- wing
        img:set_pixel(ex, eye_y - 2, 45, 35, 30)
    end
    -- Lips
    local mouth_y = math.floor(cy + ry * 0.58)
    for x = math.floor(cx - 2), math.ceil(cx + 2) do
        img:set_pixel(x, mouth_y, 185, 80, 95)
    end

    -- Hair: Sleek asymmetrical bob with neon violet streaks
    for y = math.floor(cy - ry * 0.9), math.floor(shoulder_y + 2) do
        for x = math.floor(cx - rx * 1.25), math.ceil(cx + rx * 1.25) do
            local dx = (x - cx) / rx
            local dy = (y - cy) / ry
            if (math.abs(dx) > 0.75 and dy < 0.9) or (dy < -0.3 and dx * dx + dy * dy <= 1.5) then
                local is_streak = (x % 3 == 0)
                if is_streak then
                    img:set_pixel(x, y, 210, 45, 230) -- neon violet
                else
                    img:set_pixel(x, y, 35, 25, 45) -- dark purple/black
                end
            end
        end
    end

    -- Glowing cybernetic ear cuff / earring
    local ex = cx - rx - 1
    local ey = cy
    img:set_pixel(math.floor(ex), math.floor(ey), 0, 240, 255)
    img:set_pixel(math.floor(ex), math.floor(ey) + 1, 0, 240, 255)
end

-- Procedural Lady 3: Renaissance Lady (Golden curls, pearl necklace, emerald velvet dress)
local function gen_lady_renaissance(img, seed)
    math.randomseed(seed)
    local w, h = img.width, img.height
    local cx, cy = w / 2, h * 0.40

    -- Warm chiaroscuro background
    for y = 0, h - 1 do
        local t = y / (h - 1)
        for x = 0, w - 1 do
            local light = math.max(0, 1.0 - math.sqrt((x - w*0.3)^2 + (y - h*0.3)^2) / (w * 0.8))
            img:set_pixel(x, y, 20 + light * 40, 15 + light * 25, 10 + light * 15)
        end
    end

    -- Emerald Velvet Dress
    local shoulder_y = h * 0.65
    for y = math.floor(shoulder_y), h - 1 do
        local dy = (y - shoulder_y) / (h - shoulder_y)
        local sw = (w * 0.28) + dy * (w * 0.48)
        for x = math.floor(cx - sw), math.ceil(cx + sw) do
            local sh = 1.0 - math.abs(x - cx) / sw * 0.3
            img:set_pixel(x, y, 10 * sh, 65 * sh, 40 * sh)
        end
    end

    -- Gold embroidered lace neckline
    for x = math.floor(cx - w * 0.22), math.ceil(cx + w * 0.22) do
        img:set_pixel(x, math.floor(shoulder_y + 1), 220, 190, 90)
    end

    -- Neck & Face
    for y = math.floor(h * 0.48), math.floor(shoulder_y + 1) do
        for x = math.floor(cx - w * 0.12), math.ceil(cx + w * 0.12) do
            img:set_pixel(x, y, 245, 210, 185)
        end
    end
    -- Pearl necklace
    local neck_y = math.floor(shoulder_y - 2)
    for px = math.floor(cx - 5), math.ceil(cx + 5), 2 do
        img:set_pixel(px, neck_y, 250, 248, 240)
    end

    local rx = w * 0.21
    local ry = h * 0.19
    for y = math.floor(cy - ry), math.ceil(cy + ry) do
        for x = math.floor(cx - rx), math.ceil(cx + rx) do
            local dx = (x - cx) / rx
            local dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1.0 then
                -- Warm Rembrandt lighting from top-left
                local sh = 0.85 + (-dx * 0.15 - dy * 0.1)
                img:set_pixel(x, y, 245 * sh, 210 * sh, 185 * sh)
            end
        end
    end

    -- Eyes & Eyebrows
    local eye_y = math.floor(cy - ry * 0.05)
    local eye_dx = math.floor(rx * 0.46)
    for _, sign in ipairs({-1, 1}) do
        local ex = cx + sign * eye_dx
        img:set_pixel(ex - 1, eye_y, 250, 245, 240)
        img:set_pixel(ex, eye_y, 65, 45, 30)
        img:set_pixel(ex + 1, eye_y, 250, 245, 240)
        img:set_pixel(ex, eye_y - 2, 110, 75, 40)
    end
    -- Lips
    local mouth_y = math.floor(cy + ry * 0.58)
    for x = math.floor(cx - 2), math.ceil(cx + 2) do
        img:set_pixel(x, mouth_y, 205, 95, 105)
    end

    -- Golden cascading curls
    for y = math.floor(cy - ry * 0.85), math.floor(shoulder_y + 4) do
        for _, sign in ipairs({-1, 1}) do
            local hx0 = cx + sign * (rx * 0.8)
            local hx1 = cx + sign * (rx * 1.35)
            for x = math.floor(math.min(hx0, hx1)), math.ceil(math.max(hx0, hx1)) do
                local curl = math.sin(y * 0.6 + x * 0.5) * 20
                img:set_pixel(x, y, 200 + curl, 150 + curl, 70 + curl * 0.5)
            end
        end
    end

    -- Pearl Drop Earring
    for _, sign in ipairs({-1, 1}) do
        local ex = cx + sign * (rx + 1)
        img:set_pixel(math.floor(ex), math.floor(cy + 1), 245, 245, 235)
        img:set_pixel(math.floor(ex), math.floor(cy + 2), 255, 255, 250)
    end
end

-- Procedural Lady 4: Bohemian Floral Lady (Flower crown, wavy locks, sunlit glow)
local function gen_lady_boho(img, seed)
    math.randomseed(seed)
    local w, h = img.width, img.height
    local cx, cy = w / 2, h * 0.40

    -- Sunlit meadow sunset gradient
    for y = 0, h - 1 do
        local t = y / (h - 1)
        for x = 0, w - 1 do
            img:set_pixel(x, y, 245 * (1 - t) + 180 * t, 200 * (1 - t) + 210 * t, 160 * (1 - t) + 140 * t)
        end
    end

    -- White lace sundress
    local shoulder_y = h * 0.65
    for y = math.floor(shoulder_y), h - 1 do
        local dy = (y - shoulder_y) / (h - shoulder_y)
        local sw = (w * 0.28) + dy * (w * 0.48)
        for x = math.floor(cx - sw), math.ceil(cx + sw) do
            img:set_pixel(x, y, 245, 245, 242)
        end
    end

    -- Neck & Face
    for y = math.floor(h * 0.48), math.floor(shoulder_y + 1) do
        for x = math.floor(cx - w * 0.12), math.ceil(cx + w * 0.12) do
            img:set_pixel(x, y, 242, 205, 180)
        end
    end
    local rx = w * 0.21
    local ry = h * 0.19
    for y = math.floor(cy - ry), math.ceil(cy + ry) do
        for x = math.floor(cx - rx), math.ceil(cx + rx) do
            local dx = (x - cx) / rx
            local dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1.0 then
                img:set_pixel(x, y, 245, 208, 182)
            end
        end
    end

    -- Eyes & Warm Smile
    local eye_y = math.floor(cy - ry * 0.05)
    local eye_dx = math.floor(rx * 0.46)
    for _, sign in ipairs({-1, 1}) do
        local ex = cx + sign * eye_dx
        img:set_pixel(ex - 1, eye_y, 250, 250, 245)
        img:set_pixel(ex, eye_y, 75, 95, 60) -- hazel-green
        img:set_pixel(ex + 1, eye_y, 250, 250, 245)
        img:set_pixel(ex, eye_y - 2, 120, 90, 50)
    end
    -- Smiling lips
    local mouth_y = math.floor(cy + ry * 0.58)
    for x = math.floor(cx - 3), math.ceil(cx + 3) do
        img:set_pixel(x, mouth_y, 215, 110, 115)
    end
    img:set_pixel(math.floor(cx - 3), mouth_y - 1, 215, 110, 115)
    img:set_pixel(math.floor(cx + 3), mouth_y - 1, 215, 110, 115)

    -- Cascading wavy hair
    for y = math.floor(cy - ry * 0.7), math.floor(shoulder_y + 4) do
        for _, sign in ipairs({-1, 1}) do
            local hx0 = cx + sign * (rx * 0.8)
            local hx1 = cx + sign * (rx * 1.3)
            for x = math.floor(math.min(hx0, hx1)), math.ceil(math.max(hx0, hx1)) do
                img:set_pixel(x, y, 195, 155, 100)
            end
        end
    end

    -- Wildflower Crown Wreath (White Daisies & Purple Lavender)
    local crown_y = cy - ry * 0.8
    for x = math.floor(cx - rx * 1.15), math.ceil(cx + rx * 1.15), 2 do
        local is_flower = (x % 3 == 0)
        if is_flower then
            img:set_pixel(x, math.floor(crown_y), 255, 255, 255) -- white daisy
            img:set_pixel(x, math.floor(crown_y) - 1, 255, 220, 50) -- yellow center
        else
            img:set_pixel(x, math.floor(crown_y), 160, 120, 210) -- purple lavender
        end
    end
end

local PROCEDURAL_LADY_STYLES = {
    {id = "hanfu",       name = "Traditional Hanfu Lady",       gen = gen_lady_hanfu,       desc = "Guzheng & Silk Attire with Pearl Hairpin"},
    {id = "cyberpunk",   name = "Cyberpunk Neon Lady",           gen = gen_lady_cyberpunk,   desc = "Futuristic Violet Streaks & Cyber Earring"},
    {id = "renaissance", name = "Renaissance Emerald Lady",      gen = gen_lady_renaissance, desc = "Golden Curls, Pearl Drop & Emerald Velvet"},
    {id = "boho",        name = "Bohemian Floral Lady",          gen = gen_lady_boho,        desc = "Wildflower Daisy Crown & Sunset Meadows"},
}

-- =========================================================================
-- 6. Lady Portrait Catalog & Items Setup
-- =========================================================================
local THUMB_W = 20
local THUMB_H = 28 -- 14 terminal character rows
local DETAIL_W = 44
local DETAIL_H = 62 -- 31 terminal character rows

-- Known lady portrait image files
local LADY_IMAGE_FILES = {
    {
        id = 1,
        title = "Traditional Hanfu Lady",
        file = "portraits/01_traditional_hanfu_lady.png",
        desc = "Graceful Hanfu artist with guzheng & intricate floral hairpin",
        category = "Classical East Asian"
    },
    {
        id = 2,
        title = "Silk Pavilion Lady",
        file = "portraits/02_silk_pavilion_lady.jpg",
        desc = "Embroidered silk gown with delicate pearl dangling hairpins",
        category = "Classical Silk Heritage"
    },
    {
        id = 3,
        title = "Cyberpunk Neon Lady",
        file = "portraits/03_cyberpunk_neon_lady.jpg",
        desc = "Chic futuristic leather jacket with violet & cyan highlights",
        category = "Cyberpunk Streetwear"
    },
    {
        id = 4,
        title = "Renaissance Emerald Lady",
        file = "portraits/04_renaissance_emerald_lady.jpg",
        desc = "Golden curls, pearl necklace & royal emerald velvet gown",
        category = "Fine Art Oil Painting"
    },
    {
        id = 5,
        title = "Modern Studio Lady",
        file = "portraits/05_modern_studio_lady.jpg",
        desc = "Warm natural smile, cozy cream knit sweater & golden bokeh",
        category = "Contemporary Studio"
    },
    {
        id = 6,
        title = "Bohemian Floral Lady",
        file = "portraits/06_boho_floral_lady.jpg",
        desc = "Wildflower daisy & lavender wreath in sun-kissed blonde hair",
        category = "Bohemian Sunset"
    },
}

local function load_lady_catalog(force_procedural)
    local items = {}

    if not force_procedural then
        for i, entry in ipairs(LADY_IMAGE_FILES) do
            local t0 = get_time_ms()
            local thumb = load_resized_image(entry.file, THUMB_W, THUMB_H)
            local dt = get_time_ms() - t0

            if thumb then
                table.insert(items, {
                    id = entry.id,
                    title = entry.title,
                    desc = entry.desc,
                    category = entry.category,
                    file = entry.file,
                    thumb = thumb,
                    is_image_file = true,
                    gen_time = dt,
                })
            end
        end
    end

    -- If no image files found or procedural forced, generate procedural lady portraits
    if #items == 0 then
        for i = 1, 6 do
            local style = PROCEDURAL_LADY_STYLES[((i - 1) % #PROCEDURAL_LADY_STYLES) + 1]
            local seed = math.random(1000, 99999)
            local thumb = Image.new(THUMB_W, THUMB_H)
            local t0 = get_time_ms()
            style.gen(thumb, seed)
            local dt = get_time_ms() - t0

            table.insert(items, {
                id = i,
                title = style.name,
                desc = style.desc,
                category = "Procedural Algorithm",
                seed = seed,
                style = style,
                thumb = thumb,
                is_image_file = false,
                gen_time = dt,
            })
        end
    end

    return items
end

-- =========================================================================
-- 7. Gallery Grid Renderer
-- =========================================================================
local function render_gallery_screen(portraits, selected_idx, msg)
    local term_w, term_h = get_terminal_size()
    local card_inner_w = THUMB_W
    local card_box_w = card_inner_w + 2
    local gap = 3
    local margin_left = 2

    local cols = math.floor((term_w - margin_left * 2) / (card_box_w + gap))
    cols = math.max(1, math.min(cols, 4))

    local out = {}
    table.insert(out, "\27[H\27[2J") -- Clear screen & home cursor

    -- Header Banner
    local bar_len = math.min(term_w - 2, 86)
    table.insert(out, "\27[1;35m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mPORTRAIT GALLERY OF LADIES\27[0m  \27[90m(LuaJIT FFI Truecolor)\27[0m\n"))
    table.insert(out, string.format("  \27[93m[←/→/↑/↓]\27[0m Move Focus   \27[93m[1-%d]\27[0m Direct Pick   \27[1;92m[Enter]\27[0m Select & Inspect\n", #portraits))
    table.insert(out, string.format("  \27[96m[R]\27[0m Re-roll Seeds   \27[96m[S]\27[0m Save All   \27[96m[H]\27[0m Export HTML   \27[91m[Q]\27[0m Quit\n"))
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    if msg and #msg > 0 then
        table.insert(out, string.format("  \27[1;93mℹ %s\27[0m\n\n", msg))
    else
        table.insert(out, "\n")
    end

    local num_items = #portraits
    local num_rows = math.ceil(num_items / cols)

    for r = 1, num_rows do
        local row_items = {}
        for c = 1, cols do
            local idx = (r - 1) * cols + c
            if idx <= num_items then
                table.insert(row_items, {idx = idx, item = portraits[idx]})
            end
        end

        -- 1. Card Top Borders & Titles
        local top_line = {string.rep(" ", margin_left)}
        for _, entry in ipairs(row_items) do
            local is_sel = (entry.idx == selected_idx)
            local title = string.format("[%d] %s", entry.idx, entry.item.title)
            if #title > card_inner_w - 2 then
                title = title:sub(1, card_inner_w - 2)
            end
            local rem_dash = card_inner_w - #title - 2
            local l_dash = math.floor(rem_dash / 2)
            local r_dash = rem_dash - l_dash

            if is_sel then
                table.insert(top_line, string.format("\27[1;93m┏%s▶ %s ◀%s┓\27[0m",
                    string.rep("━", math.max(0, l_dash - 1)),
                    title,
                    string.rep("━", math.max(0, r_dash - 1))
                ))
            else
                table.insert(top_line, string.format("\27[90m┌%s %s %s┐\27[0m",
                    string.rep("─", math.max(0, l_dash)),
                    title,
                    string.rep("─", math.max(0, r_dash))
                ))
            end
            table.insert(top_line, string.rep(" ", gap))
        end
        table.insert(out, table.concat(top_line) .. "\n")

        -- 2. Card Thumbnail Pixel Rows
        local thumb_rows = math.floor(THUMB_H / 2)
        for tr = 0, thumb_rows - 1 do
            local pix_line = {string.rep(" ", margin_left)}
            for _, entry in ipairs(row_items) do
                local is_sel = (entry.idx == selected_idx)
                local border_char = is_sel and "\27[1;93m┃\27[0m" or "\27[90m│\27[0m"
                local row_ansi = entry.item.thumb:render_row_ansi(tr * 2)

                table.insert(pix_line, border_char .. row_ansi .. border_char)
                table.insert(pix_line, string.rep(" ", gap))
            end
            table.insert(out, table.concat(pix_line) .. "\n")
        end

        -- 3. Card Bottom Borders
        local bot_line = {string.rep(" ", margin_left)}
        for _, entry in ipairs(row_items) do
            local is_sel = (entry.idx == selected_idx)
            if is_sel then
                table.insert(bot_line, string.format("\27[1;93m┗%s┛\27[0m", string.rep("━", card_inner_w)))
            else
                table.insert(bot_line, string.format("\27[90m└%s┘\27[0m", string.rep("─", card_inner_w)))
            end
            table.insert(bot_line, string.rep(" ", gap))
        end
        table.insert(out, table.concat(bot_line) .. "\n")

        -- 4. Card Status / Badge Labels
        local meta_line = {string.rep(" ", margin_left)}
        for _, entry in ipairs(row_items) do
            local is_sel = (entry.idx == selected_idx)
            local label
            if is_sel then
                label = string.format("\27[1;92m★ SELECTED ★\27[0m")
                local pad = math.floor((card_box_w - 12) / 2)
                label = string.rep(" ", math.max(0, pad)) .. label .. string.rep(" ", math.max(0, card_box_w - 12 - pad))
            else
                local cat = entry.item.category or "Portrait"
                if #cat > card_box_w - 2 then cat = cat:sub(1, card_box_w - 2) end
                local pad = math.floor((card_box_w - #cat) / 2)
                label = string.format("\27[90m%s%s%s\27[0m",
                    string.rep(" ", math.max(0, pad)),
                    cat,
                    string.rep(" ", math.max(0, card_box_w - #cat - pad))
                )
            end
            table.insert(meta_line, label .. string.rep(" ", gap))
        end
        table.insert(out, table.concat(meta_line) .. "\n\n")
    end

    io.write(table.concat(out))
    io.flush()
end

-- =========================================================================
-- 8. Detail View Renderer ("Select one and display")
-- =========================================================================
local function render_detail_screen(item, msg)
    local term_w, term_h = get_terminal_size()
    local out = {}
    table.insert(out, "\27[H\27[2J") -- Clear screen

    local detail_w = DETAIL_W
    local detail_h = DETAIL_H
    local high_res = nil
    local dt_hires = 0

    local t0 = get_time_ms()
    if item.is_image_file and item.file then
        high_res = load_resized_image(item.file, detail_w, detail_h)
    elseif item.style and item.seed then
        high_res = Image.new(detail_w, detail_h)
        item.style.gen(high_res, item.seed)
    end
    if not high_res then
        high_res = item.thumb:resample(detail_w, detail_h)
    end
    dt_hires = get_time_ms() - t0

    local palette = high_res:extract_palette(6)

    -- Header Banner
    local bar_len = math.min(term_w - 2, 86)
    table.insert(out, "\27[1;35m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mLADY PORTRAIT INSPECTOR #%d: \27[1;93m%s\27[0m\n", item.id, item.title:upper()))
    table.insert(out, string.format("  \27[93m[←/→/P/N]\27[0m Prev/Next Portrait   \27[1;92m[Enter/G]\27[0m Back to Gallery\n"))
    table.insert(out, string.format("  \27[96m[S]\27[0m Save Image to Disk   \27[96m[H]\27[0m Export HTML   \27[91m[Q]\27[0m Quit\n"))
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    if msg and #msg > 0 then
        table.insert(out, string.format("  \27[1;93mℹ %s\27[0m\n\n", msg))
    else
        table.insert(out, "\n")
    end

    -- Side-by-side Layout: Image on Left (detail_w chars), Info Card on Right
    local num_char_rows = math.floor(detail_h / 2)

    local info_lines = {
        string.format("\27[1;37m═══ Portrait Metadata ═══\27[0m"),
        string.format("  \27[90m• Subject:\27[0m      \27[1;35m%s\27[0m", item.title),
        string.format("  \27[90m• Category:\27[0m     \27[1;36m%s\27[0m", item.category or "Portrait of Lady"),
        string.format("  \27[90m• Dimensions:\27[0m   \27[37m%dx%d pixels (portrait 2:3 / 3:4)\27[0m", detail_w, detail_h),
        string.format("  \27[90m• Processing:\27[0m   \27[32m%.2f ms (FFI Pixel Stream)\27[0m", dt_hires),
        string.format("  \27[90m• Description:\27[0m  \27[37m%s\27[0m", item.desc or "Portrait of a lady"),
        "",
        string.format("\27[1;37m═══ Dominant Color Palette ═══\27[0m"),
    }

    local swatch_line = {"  "}
    for _, col in ipairs(palette) do
        table.insert(swatch_line, string.format("\27[48;2;%d;%d;%dm    \27[0m ", col.r, col.g, col.b))
    end
    table.insert(info_lines, table.concat(swatch_line))

    local hex_line = {"  "}
    for _, col in ipairs(palette) do
        table.insert(hex_line, string.format("\27[90m#%02X%02X%02X \27[0m", col.r, col.g, col.b))
    end
    table.insert(info_lines, table.concat(hex_line))

    table.insert(info_lines, "")
    table.insert(info_lines, string.format("\27[1;37m═══ Quick Actions ═══\27[0m"))
    table.insert(info_lines, string.format("  \27[1;92m[Enter / G]\27[0m Return to Grid Gallery"))
    table.insert(info_lines, string.format("  \27[96m[S]\27[0m         Save as PNG / PPM to disk"))
    table.insert(info_lines, string.format("  \27[93m[← / →]\27[0m     Browse previous / next lady portrait"))
    table.insert(info_lines, string.format("  \27[96m[H]\27[0m         Export HTML Gallery"))
    table.insert(info_lines, string.format("  \27[91m[Q]\27[0m         Quit application"))

    -- Top border for image box
    table.insert(out, string.format("  \27[1;93m┌%s┐\27[0m\n", string.rep("─", detail_w)))

    for tr = 0, num_char_rows - 1 do
        local line_img = string.format("  \27[1;93m│\27[0m%s\27[1;93m│\27[0m", high_res:render_row_ansi(tr * 2))
        local info = info_lines[tr + 1] or ""
        table.insert(out, line_img .. "   " .. info .. "\n")
    end

    -- Bottom border
    table.insert(out, string.format("  \27[1;93m└%s┘\27[0m\n", string.rep("─", detail_w)))

    io.write(table.concat(out))
    io.flush()
    return high_res
end

-- =========================================================================
-- 9. HTML Export Function
-- =========================================================================
local function export_html_gallery(portraits, filename)
    filename = filename or "gallery.html"
    local f = io.open(filename, "w")
    if not f then return false, "Cannot write to " .. filename end

    f:write([[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Portrait Gallery of Ladies</title>
<style>
  body {
    background: #0f111a;
    color: #e6edf3;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    margin: 0;
    padding: 28px;
    display: flex;
    flex-direction: column;
    align-items: center;
  }
  h1 { margin-bottom: 6px; color: #f472b6; font-size: 28px; }
  p.subtitle { color: #9ca3af; margin-top: 0; margin-bottom: 28px; font-size: 15px; }
  .gallery {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
    gap: 24px;
    max-width: 1100px;
    width: 100%;
  }
  .card {
    background: #181b28;
    border: 1px solid #2d3348;
    border-radius: 12px;
    padding: 16px;
    display: flex;
    flex-direction: column;
    align-items: center;
    transition: transform 0.25s ease, border-color 0.25s ease, box-shadow 0.25s ease;
    cursor: pointer;
  }
  .card:hover {
    transform: translateY(-6px);
    border-color: #f472b6;
    box-shadow: 0 10px 28px rgba(244, 114, 182, 0.22);
  }
  canvas {
    border-radius: 8px;
    image-rendering: pixelated;
    box-shadow: 0 4px 16px rgba(0,0,0,0.6);
  }
  .title { font-weight: 600; margin-top: 12px; font-size: 16px; color: #fdf2f8; text-align: center; }
  .badge { font-size: 11px; background: #372847; color: #f472b6; padding: 2px 8px; border-radius: 12px; margin-top: 4px; }
  .desc { font-size: 12px; color: #9ca3af; margin-top: 6px; text-align: center; line-height: 1.4; }
  /* Modal */
  .modal {
    display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%;
    background: rgba(0,0,0,0.88); align-items: center; justify-content: center;
  }
  .modal.active { display: flex; }
  .modal-content {
    background: #181b28; border: 1px solid #f472b6; border-radius: 14px;
    padding: 28px; max-width: 520px; text-align: center; box-shadow: 0 16px 40px rgba(0,0,0,0.8);
  }
  .close-btn {
    background: #db2777; color: white; border: none; padding: 10px 22px;
    border-radius: 8px; cursor: pointer; margin-top: 18px; font-weight: 600; font-size: 14px;
  }
  .close-btn:hover { background: #be185d; }
</style>
</head>
<body>
<h1>Portrait Gallery of Ladies</h1>
<p class="subtitle">Dynamic portrait collection rendered via LuaJIT FFI truecolor pixel engine. Click any portrait to inspect.</p>
<div class="gallery">
]])

    for _, p in ipairs(portraits) do
        local w, h = p.thumb.width, p.thumb.height
        f:write(string.format([[
  <div class="card" onclick="openModal('%s', '%s', '%s', '%s')">
    <canvas id="cv_%d" width="%d" height="%d" style="width: 150px; height: 210px;"></canvas>
    <div class="title">#%d %s</div>
    <div class="badge">%s</div>
    <div class="desc">%s</div>
  </div>
  <script>
    (function() {
      var cv = document.getElementById('cv_%d');
      var ctx = cv.getContext('2d');
      var imgData = ctx.createImageData(%d, %d);
      var data = imgData.data;
]], p.title, p.category, p.desc, p.id, p.id, w, h, p.id, p.title, p.category, p.desc, p.id, w, h))

        local px_bytes = {}
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local px = p.thumb:get_pixel(x, y)
                table.insert(px_bytes, string.format("%d,%d,%d,255", px.r, px.g, px.b))
            end
        end
        f:write("      var raw = [" .. table.concat(px_bytes, ",") .. "];\n")
        f:write([[
      for (var i = 0; i < raw.length; i++) data[i] = raw[i];
      ctx.putImageData(imgData, 0, 0);
    })();
  </script>
]])
    end

    f:write([[
</div>
<div id="modal" class="modal" onclick="closeModal()">
  <div class="modal-content" onclick="event.stopPropagation()">
    <h2 id="m_title" style="margin-top:0; color:#f472b6;"></h2>
    <div id="m_badge" style="margin-bottom:12px; font-size:12px; color:#a78bfa;"></div>
    <canvas id="m_canvas" width="44" height="62" style="width: 240px; height: 338px;"></canvas>
    <p id="m_desc" style="color:#d1d5db; line-height: 1.5; font-size: 14px; margin-top: 14px;"></p>
    <button class="close-btn" onclick="closeModal()">Close Inspector</button>
  </div>
</div>
<script>
  function openModal(title, category, desc, id) {
    document.getElementById('m_title').innerText = title;
    document.getElementById('m_badge').innerText = category;
    document.getElementById('m_desc').innerText = desc;
    var src = document.getElementById('cv_' + id);
    var dst = document.getElementById('m_canvas');
    var ctx = dst.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(src, 0, 0, dst.width, dst.height);
    document.getElementById('modal').classList.add('active');
  }
  function closeModal() {
    document.getElementById('modal').classList.remove('active');
  }
</script>
</body>
</html>
]])
    f:close()
    return true
end

-- =========================================================================
-- 10. Main Controller & CLI Loop
-- =========================================================================
local function main()
    local args = {}
    local i = 1
    while i <= #(arg or {}) do
        local a = arg[i]
        if a:sub(1, 1) == "-" then
            if (arg[i + 1] and arg[i + 1]:sub(1, 1) ~= "-") then
                args[a] = arg[i + 1]
                i = i + 1
            else
                args[a] = true
            end
        end
        i = i + 1
    end

    if args["-h"] or args["--help"] then
        print("\27[1;35mPortrait Gallery of Ladies (LuaJIT FFI Truecolor)\27[0m")
        print("Usage:")
        print("  ./LuaJIT/src/luajit gallery_portrait.lua [options]")
        print("\nOptions:")
        print("  --select <id>         Directly select and display lady portrait #id in detail view")
        print("  --procedural          Force dynamic algorithmic procedural lady generation")
        print("  --save-all            Export all lady portraits to ./portraits/")
        print("  --html [file]         Export interactive web gallery HTML (default: gallery.html)")
        print("  --no-interactive      Run in non-interactive batch/script mode")
        print("  -h, --help            Show this help documentation")
        os.exit(0)
    end

    local cli_select = tonumber(args["--select"] or args["-s"])
    local do_save_all = args["--save-all"] ~= nil
    local do_html = args["--html"] or (args["-H"] ~= nil)
    local force_procedural = args["--procedural"] ~= nil
    local non_interactive = args["--no-interactive"] or (ffi.C.isatty(STDIN_FILENO) ~= 1)

    -- Load Portraits of Ladies
    local portraits = load_lady_catalog(force_procedural)

    -- Batch Operations
    if do_save_all then
        os.execute("mkdir -p portraits")
        for idx, p in ipairs(portraits) do
            local ppm_fn = string.format("portraits/portrait_%d_lady.ppm", idx)
            local png_fn = string.format("portraits/portrait_%d_lady.png", idx)
            p.thumb:save_ppm(ppm_fn)
            p.thumb:save_png(png_fn)
            print(string.format("[+] Saved %s & %s", ppm_fn, png_fn))
        end
    end

    if do_html then
        local html_name = type(args["--html"]) == "string" and args["--html"] or "gallery.html"
        export_html_gallery(portraits, html_name)
        print(string.format("[+] Exported interactive HTML gallery to '%s'", html_name))
    end

    -- If CLI directly requested selection (e.g. --select 1)
    if cli_select and cli_select >= 1 and cli_select <= #portraits then
        render_gallery_screen(portraits, cli_select)
        print("\n\27[1;36m[+] Automatically displaying selected lady portrait #" .. cli_select .. ":\27[0m\n")
        render_detail_screen(portraits[cli_select])
        return
    end

    -- Non-interactive prompt fallback (e.g. piped stdin)
    if non_interactive then
        local current_sel = 1
        while true do
            render_gallery_screen(portraits, current_sel)
            io.write(string.format("\n\27[1;32mEnter lady portrait [1-%d] to inspect, [r]egenerate, [s]ave all, [h]tml, or [q]uit: \27[0m", #portraits))
            io.flush()
            local line = io.read("*l")
            if not line or line == "q" or line == "Q" then break end
            line = line:gsub("^%s*(.-)%s*$", "%1")
            local choice = tonumber(line)
            if choice and choice >= 1 and choice <= #portraits then
                current_sel = choice
                local hires = render_detail_screen(portraits[choice])
                io.write(string.format("\n\27[1;32mDetail View Options: [b]ack to gallery, [s]ave image, [1-%d] jump, [q]uit: \27[0m", #portraits))
                io.flush()
                local sub_line = io.read("*l")
                if not sub_line or sub_line == "q" or sub_line == "Q" then break end
                sub_line = sub_line:gsub("^%s*(.-)%s*$", "%1")
                if sub_line == "s" or sub_line == "S" then
                    local png_name = string.format("selected_lady_portrait_%d.png", choice)
                    local ppm_name = string.format("selected_lady_portrait_%d.ppm", choice)
                    hires:save_ppm(ppm_name)
                    hires:save_png(png_name)
                    print(string.format("\n[+] Saved '%s' and '%s'!\n", png_name, ppm_name))
                elseif tonumber(sub_line) and tonumber(sub_line) >= 1 and tonumber(sub_line) <= #portraits then
                    current_sel = tonumber(sub_line)
                end
            elseif line == "r" or line == "R" then
                portraits = load_lady_catalog(true)
            elseif line == "s" or line == "S" then
                os.execute("mkdir -p portraits")
                for idx, p in ipairs(portraits) do
                    local ppm_fn = string.format("portraits/portrait_%d_lady.ppm", idx)
                    local png_fn = string.format("portraits/portrait_%d_lady.png", idx)
                    p.thumb:save_ppm(ppm_fn)
                    p.thumb:save_png(png_fn)
                    print(string.format("[+] Saved %s & %s", ppm_fn, png_fn))
                end
            elseif line == "h" or line == "H" then
                export_html_gallery(portraits, "gallery.html")
                print("[+] Exported gallery.html")
            end
        end
        return
    end

    -- Interactive TUI Loop
    enable_raw_mode()

    local state = "GALLERY"
    local selected_idx = 1
    local status_msg = "Use Arrow keys to browse. Press [Enter] to inspect selected lady portrait."
    local current_hires_img = nil

    local function cleanup_and_exit()
        disable_raw_mode()
        print("\n\27[1;35mExited Portrait Gallery of Ladies. Thanks for viewing!\27[0m")
        os.exit(0)
    end

    while true do
        if state == "GALLERY" then
            render_gallery_screen(portraits, selected_idx, status_msg)
            status_msg = ""

            local key = read_key()
            if key == "q" or key == "ESC" then
                cleanup_and_exit()
            elseif key == "RIGHT" or key == "l" then
                selected_idx = (selected_idx % #portraits) + 1
            elseif key == "LEFT" or key == "h" then
                selected_idx = selected_idx - 1
                if selected_idx < 1 then selected_idx = #portraits end
            elseif key == "DOWN" or key == "j" then
                local term_w = get_terminal_size()
                local cols = math.max(1, math.min(math.floor((term_w - 4) / 25), 4))
                selected_idx = math.min(#portraits, selected_idx + cols)
            elseif key == "UP" or key == "k" then
                local term_w = get_terminal_size()
                local cols = math.max(1, math.min(math.floor((term_w - 4) / 25), 4))
                selected_idx = math.max(1, selected_idx - cols)
            elseif tonumber(key) and tonumber(key) >= 1 and tonumber(key) <= #portraits then
                selected_idx = tonumber(key)
            elseif key == "ENTER" or key == "SPACE" then
                state = "DETAIL"
                status_msg = "Viewing Lady Portrait #" .. selected_idx .. " in full detail."
            elseif key == "r" then
                portraits = load_lady_catalog(true)
                status_msg = "Regenerated procedural lady portraits with dynamic seeds!"
            elseif key == "s" then
                os.execute("mkdir -p portraits")
                for k, p in ipairs(portraits) do
                    p.thumb:save_ppm(string.format("portraits/portrait_%d_lady.ppm", k))
                end
                status_msg = string.format("Saved all %d lady portraits to ./portraits/", #portraits)
            elseif key == "h" then
                export_html_gallery(portraits, "gallery.html")
                status_msg = "Exported interactive HTML gallery to './gallery.html'!"
            end

        elseif state == "DETAIL" then
            current_hires_img = render_detail_screen(portraits[selected_idx], status_msg)
            status_msg = ""

            local key = read_key()
            if key == "q" then
                cleanup_and_exit()
            elseif key == "ESC" or key == "g" or key == "ENTER" or key == "BACKSPACE" then
                state = "GALLERY"
                status_msg = "Returned to Gallery view."
            elseif key == "RIGHT" or key == "n" or key == "l" then
                selected_idx = (selected_idx % #portraits) + 1
            elseif key == "LEFT" or key == "p" or key == "h" then
                selected_idx = selected_idx - 1
                if selected_idx < 1 then selected_idx = #portraits end
            elseif key == "r" and portraits[selected_idx].style then
                portraits[selected_idx].seed = math.random(1000, 99999)
                portraits[selected_idx].style.gen(portraits[selected_idx].thumb, portraits[selected_idx].seed)
                status_msg = "Re-rolled seed for Lady Portrait #" .. selected_idx .. "!"
            elseif key == "s" then
                local ppm_name = string.format("selected_lady_portrait_%d.ppm", selected_idx)
                local png_name = string.format("selected_lady_portrait_%d.png", selected_idx)
                if current_hires_img then
                    current_hires_img:save_ppm(ppm_name)
                    current_hires_img:save_png(png_name)
                    status_msg = string.format("Saved selected lady portrait to '%s' and '%s'!", png_name, ppm_name)
                end
            end
        end
    end
end

main()
