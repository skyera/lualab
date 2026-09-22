--[[
    ffi_thumbnailer.lua
    In-terminal image thumbnail browser. LuaJIT FFI.

    Usage (browser):
      luajit ffi_thumbnailer.lua [directory]           -- defaults to current dir
      luajit ffi_thumbnailer.lua portraits/ --max 64x40
      luajit ffi_thumbnailer.lua . --cols 4

    Options:
      --max WxH   Thumbnail pixel size  (default: 48x30)
      --cols N    Force number of columns (default: auto-fit terminal width)

    Supported formats: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP
    Requires: ImageMagick (magick/convert) or FFmpeg for non-PPM images.

    Module API (for test_ffi_thumbnailer.lua):
      local t = require("ffi_thumbnailer")
      t.dimensions_for(sw, sh, mw, mh)
      t.resize_bilinear(image, w, h)
      t.load_ppm(path)
      t.save_ppm(image, path)
]]

local ffi = require("ffi")
ffi.cdef[[ typedef struct { uint8_t r, g, b; } PixelRGB; ]]

-- ============================================================
-- 0. Platform constants
-- ============================================================
local IS_WIN   = (ffi.os == "Windows")
local DEVNULL  = IS_WIN and "NUL"  or "/dev/null"
local POPEN_R  = IS_WIN and "rb"   or "r"

-- ============================================================
-- 1. Terminal size detection
-- ============================================================
local get_terminal_size
do
    if IS_WIN then
        pcall(ffi.cdef, [[
            typedef struct { short X; short Y; } COORD;
            typedef struct { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
            typedef struct {
                COORD      dwSize;
                COORD      dwCursorPosition;
                uint16_t   wAttributes;
                SMALL_RECT srWindow;
                COORD      dwMaximumWindowSize;
            } CONSOLE_SCREEN_BUFFER_INFO;
            void* __stdcall GetStdHandle(uint32_t n);
            int   __stdcall GetConsoleScreenBufferInfo(void* h, CONSOLE_SCREEN_BUFFER_INFO* p);
        ]])
        local ok, k32 = pcall(ffi.load, "kernel32")
        get_terminal_size = function()
            if ok then
                local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
                local h = k32.GetStdHandle(0xFFFFFFF5)
                if k32.GetConsoleScreenBufferInfo(h, csbi) ~= 0 then
                    local w = csbi.srWindow.Right  - csbi.srWindow.Left + 1
                    local r = csbi.srWindow.Bottom - csbi.srWindow.Top  + 1
                    if w > 0 and r > 0 then return w, r end
                end
            end
            return 80, 24
        end
    else
        pcall(ffi.cdef, [[
            struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
            int ioctl(int fd, unsigned long request, void *argp);
        ]])
        local TIOCGWINSZ = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413
        get_terminal_size = function()
            local ws = ffi.new("struct winsize")
            if pcall(function() return ffi.C.ioctl(1, TIOCGWINSZ, ws) end)
               and ws.ws_col > 0 and ws.ws_row > 0 then
                return tonumber(ws.ws_col), tonumber(ws.ws_row)
            end
            return 80, 24
        end
    end
end

-- ============================================================
-- 2. Directory scanner — POSIX opendir/readdir + ls fallback
-- ============================================================
local IMAGE_EXTS = {
    png=true, jpg=true, jpeg=true, ppm=true, webp=true, gif=true, bmp=true,
}

local scan_dir
do
    if IS_WIN then
        scan_dir = function(dir)
            local files = {}
            local p = io.popen(string.format('dir /b /a-d "%s" 2>nul', dir), "r")
            if p then
                for line in p:lines() do
                    local fname = line:gsub("[\r\n]+$", "")
                    local ext   = fname:match("%.([^.]+)$")
                    if ext and IMAGE_EXTS[ext:lower()] then
                        local sep = (dir:sub(-1) == "\\" or dir:sub(-1) == "/") and "" or "\\"
                        files[#files+1] = { name=fname, path=dir..sep..fname, ext=ext:upper() }
                    end
                end
                p:close()
            end
            table.sort(files, function(a,b) return a.name:lower() < b.name:lower() end)
            return files
        end
    else
        -- Try to use opendir/readdir directly; fall back to ls pipe
        local has_opendir = pcall(ffi.cdef, [[
            typedef struct DIR DIR;
            struct dirent {
                unsigned long  d_ino;
                long           d_off;
                unsigned short d_reclen;
                unsigned char  d_type;
                char           d_name[256];
            };
            DIR           *opendir(const char *name);
            struct dirent *readdir(DIR *dirp);
            int            closedir(DIR *dirp);
        ]])

        scan_dir = function(dir)
            local files = {}
            local sep   = (dir:sub(-1) == "/") and "" or "/"

            local function collect_fname(fname)
                local ext = fname:match("%.([^.]+)$")
                if ext and IMAGE_EXTS[ext:lower()] then
                    files[#files+1] = { name=fname, path=dir..sep..fname, ext=ext:upper() }
                end
            end

            if has_opendir then
                local d = ffi.C.opendir(dir)
                if d ~= nil then
                    while true do
                        local ent = ffi.C.readdir(d)
                        if ent == nil then break end
                        local fname = ffi.string(ent.d_name)
                        if fname ~= "." and fname ~= ".." then
                            collect_fname(fname)
                        end
                    end
                    ffi.C.closedir(d)
                else
                    -- opendir returned nil, try ls fallback
                    local p = io.popen(string.format("ls -1 %q 2>/dev/null", dir), "r")
                    if p then
                        for line in p:lines() do collect_fname(line:gsub("[\r\n]+$","")) end
                        p:close()
                    end
                end
            else
                local p = io.popen(string.format("ls -1 %q 2>/dev/null", dir), "r")
                if p then
                    for line in p:lines() do collect_fname(line:gsub("[\r\n]+$","")) end
                    p:close()
                end
            end

            table.sort(files, function(a,b) return a.name:lower() < b.name:lower() end)
            return files
        end
    end
end

-- ============================================================
-- 3. Shell quoting
-- ============================================================
local function shell_quote(v)
    if IS_WIN then return '"' .. v:gsub('"', '\\"') .. '"' end
    return "'" .. v:gsub("'", "'\"'\"'") .. "'"
end

-- ============================================================
-- 4. PPM stream reader
-- ============================================================
local function read_ppm(stream)
    local function token()
        local chars, c = {}, nil
        repeat
            c = stream:read(1)
            if c == "#" then stream:read("*l"); c = nil end
        until c == nil or not c:match("%s")
        if not c then return nil end
        repeat chars[#chars+1] = c; c = stream:read(1) until c == nil or c:match("%s")
        return table.concat(chars)
    end
    if token() ~= "P6" then return nil, "expected binary PPM (P6)" end
    local w, h, mv = tonumber(token()), tonumber(token()), tonumber(token())
    if not w or not h or not mv or w < 1 or h < 1 or mv ~= 255 then
        return nil, "invalid PPM header"
    end
    local data = stream:read(w * h * 3)
    if not data or #data ~= w * h * 3 then return nil, "truncated PPM data" end
    local px = ffi.new("PixelRGB[?]", w * h)
    ffi.copy(px, data, #data)
    return { width=w, height=h, pixels=px }
end

local function load_ppm(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local img, e = read_ppm(f); f:close()
    return img, e
end

-- ============================================================
-- 5. Universal image loader (PPM native, else magick/ffmpeg)
-- ============================================================
local function load_image(path)
    if path:lower():match("%.ppm$") then return load_ppm(path) end
    local q   = shell_quote(path)
    local cmd = string.format(
        "magick %s ppm:- 2>%s || convert %s ppm:- 2>%s || ffmpeg -v error -i %s -f image2pipe -vcodec ppm - 2>%s",
        q, DEVNULL, q, DEVNULL, q, DEVNULL)
    local pipe = io.popen(cmd, POPEN_R)
    if not pipe then return nil, "cannot launch decoder" end
    local img, err = read_ppm(pipe); pipe:close()
    if not img then
        return nil, "decode failed (install ImageMagick or FFmpeg): " .. (err or "?")
    end
    return img
end

-- ============================================================
-- 6. Core image processing  (exported module API)
-- ============================================================
local function dimensions_for(source_w, source_h, max_w, max_h)
    local scale = math.min(max_w / source_w, max_h / source_h, 1)
    return math.max(1, math.floor(source_w * scale + 0.5)),
           math.max(1, math.floor(source_h * scale + 0.5))
end

local function resize_bilinear(image, width, height)
    local pixels = ffi.new("PixelRGB[?]", width * height)
    local xs, ys = image.width / width, image.height / height
    for y = 0, height - 1 do
        local sy = (y + 0.5) * ys - 0.5
        local y0 = math.max(0, math.floor(sy))
        local y1 = math.min(image.height - 1, y0 + 1)
        local fy = sy - math.floor(sy)
        for x = 0, width - 1 do
            local sx = (x + 0.5) * xs - 0.5
            local x0 = math.max(0, math.floor(sx))
            local x1 = math.min(image.width - 1, x0 + 1)
            local fx = sx - math.floor(sx)
            local a  = image.pixels[y0 * image.width + x0]
            local b  = image.pixels[y0 * image.width + x1]
            local c  = image.pixels[y1 * image.width + x0]
            local d  = image.pixels[y1 * image.width + x1]
            local o  = pixels[y * width + x]
            for _, ch in ipairs({"r","g","b"}) do
                local top = a[ch] + (b[ch] - a[ch]) * fx
                o[ch] = math.floor(top + (c[ch] + (d[ch]-c[ch])*fx - top) * fy + 0.5)
            end
        end
    end
    return { width=width, height=height, pixels=pixels }
end

local function save_ppm(image, path)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(string.format("P6\n%d %d\n255\n", image.width, image.height))
    f:write(ffi.string(image.pixels, image.width * image.height * ffi.sizeof("PixelRGB")))
    f:close()
    return true
end

-- ============================================================
-- 7. ANSI truecolor half-block renderer
--    Each pair of pixel rows → one text row using '▄'
--    BG colour = top pixel, FG colour = bottom pixel
-- ============================================================
local function render_halfblock(image)
    local lines = {}
    local px, iw = image.pixels, image.width
    for y = 0, image.height - 1, 2 do
        local parts = {}
        for x = 0, image.width - 1 do
            local t = px[y * iw + x]
            local b = px[math.min(image.height-1, y+1) * iw + x]
            parts[#parts+1] = string.format(
                "\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm\xe2\x96\x84",
                t.r, t.g, t.b, b.r, b.g, b.b)
        end
        parts[#parts+1] = "\27[0m"
        lines[#lines+1] = table.concat(parts)
    end
    return lines
end

-- ============================================================
-- 8. String helpers
-- ============================================================
local function trunc(s, max_len, ellipsis)
    ellipsis = ellipsis or "…"
    if #s <= max_len then return s end
    return s:sub(1, max_len - #ellipsis) .. ellipsis
end

local function pad_right(s, width)
    local pad = width - #s
    if pad <= 0 then return s end
    return s .. string.rep(" ", pad)
end

-- ============================================================
-- 9. Error placeholder thumbnail  (dark grey grid pattern)
-- ============================================================
local function make_error_thumb(tw, th)
    local px = ffi.new("PixelRGB[?]", tw * th)
    for y = 0, th - 1 do
        for x = 0, tw - 1 do
            local checker = (math.floor(x/4) + math.floor(y/4)) % 2 == 0
            local v = checker and 55 or 35
            local p = px[y * tw + x]
            p.r, p.g, p.b = v, v, v
        end
    end
    return { width=tw, height=th, pixels=px }
end

-- ============================================================
-- 10. CLI argument parser
-- ============================================================
local function parse_size(s)
    local w, h = s:match("^(%d+)[xX](%d+)$")
    return tonumber(w), tonumber(h)
end

-- ============================================================
-- 11. Main thumbnail browser
-- ============================================================
local function browse(dir_path, thumb_px_w, thumb_px_h, force_cols)
    dir_path = (dir_path or "."):gsub("[/\\]+$", "")
    if dir_path == "" then dir_path = "." end

    -- ── Scan ─────────────────────────────────────────────────
    io.write(string.format("\27[90mScanning %s …\27[0m\r", dir_path))
    io.flush()
    local files = scan_dir(dir_path)
    io.write("\27[2K")  -- erase scanning line
    io.flush()

    if #files == 0 then
        io.write(string.format("\27[33mNo images found in: %s\27[0m\n", dir_path))
        return false
    end

    -- ── Layout constants ─────────────────────────────────────
    local term_w = get_terminal_size()
    local tw = thumb_px_w or 48            -- thumb pixel width
    local th = thumb_px_h or 30            -- thumb pixel height
    if th % 2 ~= 0 then th = th + 1 end   -- must be even for half-blocks

    -- card = border(1) + thumb_pixels(tw) + border(1) = tw+2 chars wide
    local card_w = tw + 2
    local gap    = 2   -- spaces between cards
    local margin = 2   -- left margin

    local cols
    if force_cols and force_cols >= 1 then
        cols = force_cols
    else
        -- how many cards fit: margin + cols*(card_w+gap) - gap <= term_w
        cols = math.max(1, math.floor((term_w - margin + gap) / (card_w + gap)))
    end

    local thumb_rows = math.floor(th / 2)  -- text rows for pixel content

    -- ── Header ───────────────────────────────────────────────
    io.write(string.format(
        "\n\27[1;36m  ffi_thumbnailer\27[0m  \27[33m%s\27[0m" ..
        "  \27[90m[%d image%s · %d col%s · %dx%d px]\27[0m\n\n",
        dir_path,
        #files, (#files == 1) and "" or "s",
        cols,   (cols  == 1) and "" or "s",
        tw, th))

    -- ── Load, resize, render all thumbnails ──────────────────
    local cards = {}
    for i, f in ipairs(files) do
        io.write(string.format(
            "\27[90m  Loading [%d/%d]  %-40s\27[0m\r",
            i, #files, trunc(f.name, 40)))
        io.flush()

        local img, err   = load_image(f.path)
        local thumb, ok  = nil, false

        if img then
            local rw, rh = dimensions_for(img.width, img.height, tw, th)
            if rh % 2 ~= 0 then rh = rh + 1 end
            thumb = resize_bilinear(img, rw, rh)
            ok    = true
        end

        cards[#cards+1] = {
            idx    = i,
            name   = f.name,
            ext    = f.ext,
            ok     = ok,
            err    = err,
            lines  = render_halfblock(ok and thumb or make_error_thumb(tw, th)),
            cw     = ok and thumb.width  or tw,   -- actual pixel cols rendered
            ch     = ok and thumb.height or th,   -- actual pixel rows rendered
        }
    end

    -- Erase loading line
    io.write("\27[2K")
    io.flush()

    -- ── Render grid ──────────────────────────────────────────
    for row_start = 1, #cards, cols do
        local row = {}
        for ci = row_start, math.min(row_start + cols - 1, #cards) do
            row[#row+1] = cards[ci]
        end

        -- ·· Top border + title ··
        local top_buf = {string.rep(" ", margin)}
        for ri, card in ipairs(row) do
            -- inner width = card.cw (may be < tw due to AR)
            local iw      = card.cw  -- pixel columns = char columns
            local border  = iw + 2   -- │ content │
            -- compose title: "[N] name" then fill dashes up to ext badge
            local title   = string.format("[%d] %s", card.idx, card.name)
            local badge   = " " .. card.ext .. " "   -- e.g. " JPG "
            -- available dash space: border - 2(corners) - 2(spaces) - #title - #badge
            local dashes  = border - 2 - 2 - #title - #badge
            if dashes < 0 then
                title  = trunc(title, #title + dashes, "…")
                dashes = 0
            end
            if card.ok then
                top_buf[#top_buf+1] = string.format(
                    "\27[90m┌─ \27[0;97m%s\27[90m %s%s─┐\27[0m",
                    title, string.rep("─", math.max(0, dashes)), badge)
            else
                top_buf[#top_buf+1] = string.format(
                    "\27[90m┌─ \27[0;31m%s\27[90m %s%s─┐\27[0m",
                    title, string.rep("─", math.max(0, dashes)), badge)
            end
            if ri < #row then top_buf[#top_buf+1] = string.rep(" ", gap) end
        end
        io.write(table.concat(top_buf) .. "\n")

        -- ·· Pixel rows ··
        local max_hrows = 0
        for _, card in ipairs(row) do
            if #card.lines > max_hrows then max_hrows = #card.lines end
        end

        for tr = 1, max_hrows do
            local pix_buf = {string.rep(" ", margin)}
            for ri, card in ipairs(row) do
                local pixel_row = card.lines[tr]
                if not pixel_row then
                    -- shorter card: fill with blank pixels
                    pixel_row = string.rep(" ", card.cw) .. "\27[0m"
                end
                pix_buf[#pix_buf+1] = "\27[90m│\27[0m" .. pixel_row .. "\27[90m│\27[0m"
                if ri < #row then pix_buf[#pix_buf+1] = string.rep(" ", gap) end
            end
            io.write(table.concat(pix_buf) .. "\n")
        end

        -- ·· Bottom border ··
        local bot_buf = {string.rep(" ", margin)}
        for ri, card in ipairs(row) do
            if card.ok then
                bot_buf[#bot_buf+1] = string.format(
                    "\27[90m└%s┘\27[0m", string.rep("─", card.cw))
            else
                local errmsg = " \27[31m⚠ decode error\27[90m "
                local fill   = math.max(0, card.cw - 16)  -- 16 ≈ visible width of errmsg
                bot_buf[#bot_buf+1] = string.format(
                    "\27[90m└%s%s%s┘\27[0m",
                    errmsg, string.rep("─", fill), "")
            end
            if ri < #row then bot_buf[#bot_buf+1] = string.rep(" ", gap) end
        end
        io.write(table.concat(bot_buf) .. "\n")

        -- ·· Filename label row ··
        local lbl_buf = {string.rep(" ", margin)}
        for ri, card in ipairs(row) do
            local col_w   = card.cw + 2    -- match card width
            local name_d  = trunc(card.name, col_w)
            lbl_buf[#lbl_buf+1] = string.format("  \27[90m%s\27[0m", pad_right(name_d, col_w))
            if ri < #row then lbl_buf[#lbl_buf+1] = string.rep(" ", gap) end
        end
        io.write(table.concat(lbl_buf) .. "\n\n")
    end

    -- ── Footer ────────────────────────────────────────────────
    io.write(string.format(
        "\27[90m  ✓  %d image%s  ·  %s\27[0m\n\n",
        #files, (#files == 1) and "" or "s", dir_path))

    return true
end

-- ============================================================
-- 12. Module API  (preserved for test_ffi_thumbnailer.lua)
-- ============================================================
local module = {
    dimensions_for  = dimensions_for,
    resize_bilinear = resize_bilinear,
    load_ppm        = load_ppm,
    save_ppm        = save_ppm,
}
if ... == "ffi_thumbnailer" then return module end

-- ============================================================
-- 13. CLI entry point
-- ============================================================
local dir_path   = nil
local thumb_w    = nil
local thumb_h    = nil
local force_cols = nil

local i = 1
while i <= #arg do
    local a = arg[i]
    if (a == "--max" or a == "-m") and arg[i+1] then
        local w, h = parse_size(arg[i+1])
        if w and h then thumb_w, thumb_h = w, h end
        i = i + 2
    elseif (a == "--cols" or a == "-c") and arg[i+1] then
        force_cols = tonumber(arg[i+1])
        i = i + 2
    elseif a == "--help" or a == "-h" then
        print("Usage: luajit ffi_thumbnailer.lua [directory] [--max WxH] [--cols N]")
        print("  --max WxH   thumbnail pixel size (default: 48x30)")
        print("  --cols N    force column count  (default: auto)")
        os.exit(0)
    elseif not a:match("^%-%-") then
        if not dir_path then dir_path = a end
        i = i + 1
    else
        i = i + 1
    end
end

os.exit(browse(dir_path, thumb_w, thumb_h, force_cols) and 0 or 1)
