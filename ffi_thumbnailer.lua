--[[
    ffi_thumbnailer.lua  —  Interactive TUI image thumbnail browser. LuaJIT FFI.

    Usage:
      luajit ffi_thumbnailer.lua [directory]           -- defaults to current dir
      luajit ffi_thumbnailer.lua portraits/ --max 64x40
      luajit ffi_thumbnailer.lua . --cols 4

    Keys:
      ↑ / k         scroll up one row
      ↓ / j         scroll down one row
      PgUp / b      scroll up one page
      PgDn / Space  scroll down one page
      g / Home      jump to top
      G / End       jump to bottom
      + / =         increase thumbnail size (zoom in)
      - / _         decrease thumbnail size (zoom out)
      /             search / filter images by name
      ?             show help overlay (keybindings & features)
      o             open image in OS default viewer
      Enter         view fullscreen
      q / Esc       quit

    Options:
      --max WxH     thumbnail pixel size  (default: 48x30)
      --cols N      force column count    (default: auto-fit terminal width)

    Lazy loading: only thumbnails visible in the current viewport are loaded.
    Cache: once loaded, thumbnails are kept in memory for instant re-display.

    Supported formats: PNG JPG JPEG PPM WEBP GIF BMP
    Requires ImageMagick (magick/convert) or FFmpeg for non-PPM formats.

    Module API (preserved for test_ffi_thumbnailer.lua):
      local t = require("ffi_thumbnailer")
      t.dimensions_for / t.resize_bilinear / t.load_ppm / t.save_ppm
]]

local ffi = require("ffi")
local bit = require("bit")
ffi.cdef[[ typedef struct { uint8_t r, g, b; } PixelRGB; ]]

local IS_WIN  = (ffi.os == "Windows")
local DEVNULL = IS_WIN and "NUL"  or "/dev/null"
local POPEN_R = IS_WIN and "rb"   or "r"

-- ============================================================
-- 1. Platform: terminal size · raw mode · key reading
-- ============================================================
local get_terminal_size, enable_raw_mode, disable_raw_mode, read_key, is_stdin_tty
do
    if IS_WIN then
        pcall(ffi.cdef, [[
            typedef struct { short X; short Y; } COORD;
            typedef struct { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
            typedef struct {
                COORD      dwSize; COORD dwCursorPosition;
                uint16_t   wAttributes; SMALL_RECT srWindow; COORD dwMaximumWindowSize;
            } CONSOLE_SCREEN_BUFFER_INFO;
            void*    __stdcall GetStdHandle(uint32_t n);
            int      __stdcall GetConsoleScreenBufferInfo(void* h, CONSOLE_SCREEN_BUFFER_INFO* p);
            int      __stdcall GetConsoleMode(void* h, uint32_t* mode);
            int      __stdcall SetConsoleMode(void* h, uint32_t mode);
            int      __stdcall SetConsoleOutputCP(uint32_t cp);
            int      _kbhit(void);
            int      _getch(void);
        ]])
        local ok32, k32 = pcall(ffi.load, "kernel32")
        local STD_IN    = 0xFFFFFFF6
        local STD_OUT   = 0xFFFFFFF5
        local orig_mode = ffi.new("uint32_t[1]")
        local raw_on    = false

        pcall(function()
            if ok32 then
                k32.SetConsoleOutputCP(65001)
                local hout = k32.GetStdHandle(STD_OUT)
                local m    = ffi.new("uint32_t[1]")
                if k32.GetConsoleMode(hout, m) ~= 0 then
                    k32.SetConsoleMode(hout, bit.bor(m[0], 0x0004))  -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
                end
            end
        end)

        is_stdin_tty = function()
            if not ok32 then return false end
            local m = ffi.new("uint32_t[1]")
            return k32.GetConsoleMode(k32.GetStdHandle(STD_IN), m) ~= 0
        end

        get_terminal_size = function()
            if not ok32 then return 80, 24 end
            local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
            if k32.GetConsoleScreenBufferInfo(k32.GetStdHandle(STD_OUT), csbi) ~= 0 then
                local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
                local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
                if w > 0 and h > 0 then return w, h end
            end
            return 80, 24
        end

        enable_raw_mode = function()
            if not is_stdin_tty() then return false end
            local hin = k32.GetStdHandle(STD_IN)
            if k32.GetConsoleMode(hin, orig_mode) == 0 then return false end
            k32.SetConsoleMode(hin, bit.band(orig_mode[0], bit.bnot(bit.bor(0x0002, 0x0004))))
            raw_on = true
            io.write("\27[?1049h\27[?25l"); io.flush()
            return true
        end

        disable_raw_mode = function()
            if raw_on then
                io.write("\27[?1049l\27[?25h\27[0m"); io.flush()
                k32.SetConsoleMode(k32.GetStdHandle(STD_IN), orig_mode[0])
                raw_on = false
            end
        end

        local function parse_win_key()
            local ch = ffi.C._getch()
            if ch == 0 or ch == 224 then
                local c2 = ffi.C._getch()
                if     c2 == 72 then return "UP"
                elseif c2 == 80 then return "DOWN"
                elseif c2 == 75 then return "LEFT"
                elseif c2 == 77 then return "RIGHT"
                elseif c2 == 73 then return "PAGE_UP"
                elseif c2 == 81 then return "PAGE_DOWN"
                elseif c2 == 71 then return "HOME"
                elseif c2 == 79 then return "END"
                end
            elseif ch == 27               then return "ESC"
            elseif ch == 13 or ch == 10   then return "ENTER"
            elseif ch == 32               then return "SPACE"
            elseif ch == 3                then return "CTRL_C"
            elseif ch == 4                then return "CTRL_D"
            elseif ch >= 32               then return string.char(ch)
            end
            return nil
        end

        read_key = function(timeout_ms)
            if timeout_ms == 0 then
                if ffi.C._kbhit() ~= 0 then return parse_win_key() end
                return nil
            end
            return parse_win_key()  -- _getch blocks until a key is available
        end

    else
        -- POSIX (Linux / macOS)
        pcall(ffi.cdef, [[
            typedef long time_t;
            struct stat {
                unsigned long st_dev;
                unsigned long st_ino;
                unsigned long st_nlink;
                unsigned int  st_mode;
                unsigned int  st_uid;
                unsigned int  st_gid;
                unsigned int  __pad0;
                unsigned long st_rdev;
                long          st_size;
                long          st_blksize;
                long          st_blocks;
                time_t        st_atime;
                unsigned long st_atime_nsec;
                time_t        st_mtime;
                unsigned long st_mtime_nsec;
                time_t        st_ctime;
                unsigned long st_ctime_nsec;
                long          __unused[3];
            };
            int stat(const char *pathname, struct stat *statbuf);
            struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
            int ioctl(int fd, unsigned long request, void *argp);
            int isatty(int fd);
            typedef unsigned char cc_t;
            typedef unsigned int  speed_t;
            typedef unsigned int  tcflag_t;
            struct termios {
                tcflag_t c_iflag; tcflag_t c_oflag; tcflag_t c_cflag; tcflag_t c_lflag;
                cc_t c_line; cc_t c_cc[32]; speed_t c_ispeed; speed_t c_ospeed;
            };
            int tcgetattr(int fd, struct termios *termios_p);
            int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
            struct pollfd { int fd; short events; short revents; };
            int poll(struct pollfd *fds, unsigned long nfds, int timeout);
            long read(int fd, void *buf, size_t count);
        ]])

        local TIOCGWINSZ = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413
        local STDIN   = 0
        local TCSANOW = 0
        local ICANON  = 2
        local ECHO    = 8
        local POLLIN  = 1

        is_stdin_tty = function()
            local ok, r = pcall(function() return ffi.C.isatty(STDIN) end)
            return ok and r == 1
        end

        get_terminal_size = function()
            local ws = ffi.new("struct winsize")
            if pcall(function() return ffi.C.ioctl(1, TIOCGWINSZ, ws) end)
               and ws.ws_col > 0 and ws.ws_row > 0 then
                return tonumber(ws.ws_col), tonumber(ws.ws_row)
            end
            return 80, 24
        end

        local orig_termios = ffi.new("struct termios")
        local raw_termios  = ffi.new("struct termios")
        local raw_on       = false

        enable_raw_mode = function()
            if not is_stdin_tty() then return false end
            ffi.C.tcgetattr(STDIN, orig_termios)
            ffi.C.tcgetattr(STDIN, raw_termios)
            raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
            ffi.C.tcsetattr(STDIN, TCSANOW, raw_termios)
            raw_on = true
            io.write("\27[?1049h\27[?25l"); io.flush()
            return true
        end

        disable_raw_mode = function()
            if raw_on then
                io.write("\27[?1049l\27[?25h\27[0m"); io.flush()
                ffi.C.tcsetattr(STDIN, TCSANOW, orig_termios)
                raw_on = false
            end
        end

        local pfd  = ffi.new("struct pollfd", { fd = STDIN, events = POLLIN, revents = 0 })
        local kbuf = ffi.new("char[16]")

        read_key = function(timeout_ms)
            timeout_ms = timeout_ms or -1
            local ret = ffi.C.poll(pfd, 1, timeout_ms)
            if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
                local n = ffi.C.read(STDIN, kbuf, 16)
                if n > 0 then
                    local c0 = bit.band(kbuf[0], 0xFF)
                    if c0 == 27 then
                        if n >= 3 and kbuf[1] == 91 then
                            local c2 = kbuf[2]
                            if c2 == 65 then return "UP"   end
                            if c2 == 66 then return "DOWN"  end
                            if c2 == 67 then return "RIGHT" end
                            if c2 == 68 then return "LEFT"  end
                            if c2 == 53 and n >= 4 and kbuf[3] == 126 then return "PAGE_UP"   end
                            if c2 == 54 and n >= 4 and kbuf[3] == 126 then return "PAGE_DOWN" end
                            if c2 == 72 then return "HOME" end
                            if c2 == 70 then return "END"  end
                        end
                        return "ESC"
                    elseif c0 == 10 or c0 == 13 then return "ENTER"
                    elseif c0 == 32               then return "SPACE"
                    elseif c0 == 127 or c0 == 8   then return "BACKSPACE"
                    elseif c0 == 3                then return "CTRL_C"
                    elseif c0 == 4                then return "CTRL_D"
                    elseif c0 >= 32               then return string.char(c0)
                    end
                end
            end
            return nil
        end
    end
end

-- ============================================================
-- 2. Directory scanner — POSIX opendir/readdir + ls fallback
-- ============================================================
local IMAGE_EXTS = { png=true, jpg=true, jpeg=true, ppm=true, webp=true, gif=true, bmp=true }

local function get_file_size(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local sz = f:seek("end") or 0
    f:close()
    return sz
end

local function format_bytes(bytes)
    if not bytes or bytes <= 0 then return "0 B" end
    if bytes < 1024 then return string.format("%d B", bytes) end
    if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
    if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
end

local function open_in_viewer(path)
    local cmd
    if IS_WIN then
        cmd = string.format('start "" "%s"', path:gsub('"', '\\"'))
    elseif ffi.os == "OSX" then
        cmd = string.format("open %s >/dev/null 2>&1 &", shell_quote(path))
    else
        cmd = string.format("xdg-open %s >/dev/null 2>&1 &", shell_quote(path))
    end
    os.execute(cmd)
end

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
                        local sep = (dir:sub(-1)=="\\") and "" or "\\"
                        local fpath = dir .. sep .. fname
                        files[#files+1] = { name=fname, path=fpath, ext=ext:upper(), size=get_file_size(fpath) }
                    end
                end
                p:close()
            end
            table.sort(files, function(a,b) return a.name:lower() < b.name:lower() end)
            return files
        end
    else
        local has_opendir = pcall(ffi.cdef, [[
            typedef struct DIR DIR;
            struct dirent {
                unsigned long  d_ino; long d_off; unsigned short d_reclen;
                unsigned char  d_type; char d_name[256];
            };
            DIR           *opendir(const char *name);
            struct dirent *readdir(DIR *dirp);
            int            closedir(DIR *dirp);
        ]])

        scan_dir = function(dir)
            local files = {}
            local sep   = (dir:sub(-1) == "/") and "" or "/"

            local function collect(fname)
                local ext = fname:match("%.([^.]+)$")
                if ext and IMAGE_EXTS[ext:lower()] then
                    local fpath = dir .. sep .. fname
                    files[#files+1] = { name=fname, path=fpath, ext=ext:upper(), size=get_file_size(fpath) }
                end
            end

            if has_opendir then
                local d = ffi.C.opendir(dir)
                if d ~= nil then
                    while true do
                        local ent = ffi.C.readdir(d)
                        if ent == nil then break end
                        local fn = ffi.string(ent.d_name)
                        if fn ~= "." and fn ~= ".." then collect(fn) end
                    end
                    ffi.C.closedir(d)
                else
                    local p = io.popen("ls -1 " .. string.format("%q", dir) .. " 2>/dev/null", "r")
                    if p then for l in p:lines() do collect(l:gsub("[\r\n]+$","")) end; p:close() end
                end
            else
                local p = io.popen("ls -1 " .. string.format("%q", dir) .. " 2>/dev/null", "r")
                if p then for l in p:lines() do collect(l:gsub("[\r\n]+$","")) end; p:close() end
            end

            table.sort(files, function(a,b) return a.name:lower() < b.name:lower() end)
            return files
        end
    end
end

-- ============================================================
-- 3. Shell quoting · PPM reader · Universal image loader
-- ============================================================
local function shell_quote(v)
    if IS_WIN then return '"' .. v:gsub('"', '\\"') .. '"' end
    return "'" .. v:gsub("'", "'\"'\"'") .. "'"
end

local function read_ppm(stream)
    local function token()
        local chars, c = {}, nil
        repeat c = stream:read(1)
            if c == "#" then stream:read("*l"); c = nil end
        until c == nil or not c:match("%s")
        if not c then return nil end
        repeat chars[#chars+1] = c; c = stream:read(1) until c == nil or c:match("%s")
        return table.concat(chars)
    end
    if token() ~= "P6" then return nil, "expected P6" end
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
    local img, e = read_ppm(f); f:close(); return img, e
end

local function load_image(path)
    if path:lower():match("%.ppm$") then return load_ppm(path) end
    local q   = shell_quote(path)
    local cmd = string.format(
        "magick %s ppm:- 2>%s || convert %s ppm:- 2>%s || ffmpeg -v error -i %s -f image2pipe -vcodec ppm - 2>%s",
        q, DEVNULL, q, DEVNULL, q, DEVNULL)
    local pipe = io.popen(cmd, POPEN_R)
    if not pipe then return nil, "cannot launch decoder" end
    local img, err = read_ppm(pipe); pipe:close()
    if not img then return nil, "decode failed: " .. (err or "?") end
    return img
end

-- ============================================================
-- 4. Core image processing   (exported module API)
-- ============================================================
local function dimensions_for(sw, sh, mw, mh)
    local s = math.min(mw / sw, mh / sh, 1)
    return math.max(1, math.floor(sw * s + 0.5)),
           math.max(1, math.floor(sh * s + 0.5))
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
            local a = image.pixels[y0 * image.width + x0]
            local b = image.pixels[y0 * image.width + x1]
            local c = image.pixels[y1 * image.width + x0]
            local d = image.pixels[y1 * image.width + x1]
            local o = pixels[y * width + x]
            local fx_inv, fy_inv = 1 - fx, 1 - fy
            local w_a = fx_inv * fy_inv
            local w_b = fx * fy_inv
            local w_c = fx_inv * fy
            local w_d = fx * fy
            o.r = math.floor(a.r * w_a + b.r * w_b + c.r * w_c + d.r * w_d + 0.5)
            o.g = math.floor(a.g * w_a + b.g * w_b + c.g * w_c + d.g * w_d + 0.5)
            o.b = math.floor(a.b * w_a + b.b * w_b + c.b * w_c + d.b * w_d + 0.5)
        end
    end
    return { width=width, height=height, pixels=pixels }
end

local function save_ppm(image, path)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(string.format("P6\n%d %d\n255\n", image.width, image.height))
    f:write(ffi.string(image.pixels, image.width * image.height * ffi.sizeof("PixelRGB")))
    f:close(); return true
end

-- ============================================================
-- 5. ANSI truecolor half-block renderer
--    Each two pixel rows → one text row using '▄'
--    top pixel = BG color · bottom pixel = FG color
-- ============================================================
local function render_halfblock(image)
    local lines, px, iw = {}, image.pixels, image.width
    for y = 0, image.height - 1, 2 do
        local parts = {}
        for x = 0, image.width - 1 do
            local t = px[y * iw + x]
            local b = px[math.min(image.height - 1, y + 1) * iw + x]
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
-- 6. Helpers
-- ============================================================

-- Visual column width of a UTF-8 string (box-drawing & emoji each = 1 col here)
local function vlen(s)
    local n, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        if     b < 0x80 then n = n + 1; i = i + 1
        elseif b >= 0xF0 then n = n + 1; i = i + 4
        elseif b >= 0xE0 then n = n + 1; i = i + 3
        elseif b >= 0xC0 then n = n + 1; i = i + 2
        else                             i = i + 1  -- continuation byte
        end
    end
    return n
end

-- Truncate to at most max_cols visual columns (uses ASCII "..." so #result = visual width)
local function trunc(s, max_cols)
    if #s <= max_cols then return s end
    return s:sub(1, math.max(0, max_cols - 3)) .. "..."
end

local function pad_right(s, w)
    local p = w - #s; return p > 0 and s .. string.rep(" ", p) or s
end

-- Checkerboard placeholder for thumbnails that failed to load
local function make_error_thumb(tw, th)
    local px = ffi.new("PixelRGB[?]", tw * th)
    for y = 0, th - 1 do
        for x = 0, tw - 1 do
            local v = ((math.floor(x/4) + math.floor(y/4)) % 2 == 0) and 55 or 35
            local p = px[y * tw + x]; p.r, p.g, p.b = v, v, v
        end
    end
    return { width=tw, height=th, pixels=px }
end

local function parse_size(s)
    local w, h = s:match("^(%d+)[xX](%d+)$"); return tonumber(w), tonumber(h)
end

-- Extension badge colors
local EXT_COLORS = {
    PNG  = "\27[1;34m",  -- bright blue
    JPG  = "\27[1;33m",  -- bright yellow/orange
    JPEG = "\27[1;33m",
    WEBP = "\27[1;35m",  -- bright magenta/purple
    GIF  = "\27[1;32m",  -- bright green
    BMP  = "\27[1;36m",  -- bright cyan
    PPM  = "\27[1;97m",  -- bright white
}

-- ============================================================
-- 7. Card row renderer  (shared by TUI + flat fallback)
--
--   row_cards  = list of { idx, file={name,ext,path,size} }
--   cache[i]   = nil (unloaded) | { lines, cw, ch, orig_w, orig_h, ok }
--   out        = string accumulator table
-- ============================================================
local function render_card_row(out, row_cards, cache, tw, th, margin, gap, selected_idx)
    local trows = math.floor(th / 2)  -- target text rows for pixel canvas

    -- ── top border ────────────────────────────────────────────
    local top = { string.rep(" ", margin) }
    for ri, rc in ipairs(row_cards) do
        local is_sel = (rc.idx == selected_idx)
        local card   = cache[rc.idx]
        local ns     = tostring(rc.idx)
        local ext    = rc.file.ext
        local ext_color = EXT_COLORS[ext] or "\27[97m"

        -- Badge "[EXT]" width = #ext + 2
        local badge_w = #ext + 2
        -- Left badge "[#1]" width = #ns + 3
        local left_w = #ns + 3
        -- Max room for filename in title
        local max_name = math.max(0, tw - left_w - badge_w - 4)
        local nt = trunc(rc.file.name, max_name)
        local fill = math.max(0, tw - left_w - vlen(nt) - badge_w - 4)

        local b_h    = is_sel and "━" or "─"
        local c_tl   = is_sel and "┏" or "┌"
        local c_tr   = is_sel and "┓" or "┐"
        local bcolor = is_sel and "\27[1;36m" or "\27[90m"
        local title_color = is_sel and "\27[1;97m" or
                            ((card and card.ok) and "\27[97m" or
                            (card and "\27[31m" or "\27[90m"))

        local inner = b_h .. " [" .. (is_sel and "\27[1;36m#" or "\27[90m#") .. ns .. title_color .. "] " ..
                      nt .. " " .. string.rep(b_h, fill) .. " [" .. ext_color .. ext .. title_color .. "] " .. b_h
        top[#top+1] = bcolor .. c_tl .. title_color .. inner .. bcolor .. c_tr .. "\27[0m"
        if ri < #row_cards then top[#top+1] = string.rep(" ", gap) end
    end
    out[#out+1] = table.concat(top) .. "\27[K\n"

    -- ── pixel rows (centered in tw x trows) ────────────────────
    for tr = 1, trows do
        local pix = { string.rep(" ", margin) }
        for ri, rc in ipairs(row_cards) do
            local is_sel = (rc.idx == selected_idx)
            local card   = cache[rc.idx]
            local b_v    = is_sel and "┃" or "│"
            local bcolor = is_sel and "\27[1;36m" or "\27[90m"
            local prow

            if card then
                local img_lines = card.lines
                local img_h = #img_lines
                local img_w = card.cw
                -- vertical letterbox offset
                local y_offset = math.max(0, math.floor((trows - img_h) / 2))
                local img_tr = tr - y_offset

                if img_tr >= 1 and img_tr <= img_h then
                    local line = img_lines[img_tr] or ""
                    -- horizontal letterbox padding
                    local pad_left = math.max(0, math.floor((tw - img_w) / 2))
                    local pad_right = math.max(0, tw - img_w - pad_left)
                    local pad_l_str = pad_left > 0 and ("\27[48;2;16;18;24m" .. string.rep(" ", pad_left) .. "\27[0m") or ""
                    local pad_r_str = pad_right > 0 and ("\27[48;2;16;18;24m" .. string.rep(" ", pad_right) .. "\27[0m") or ""
                    prow = pad_l_str .. line .. pad_r_str
                else
                    prow = "\27[48;2;16;18;24m" .. string.rep(" ", tw) .. "\27[0m"
                end
            else
                prow = "\27[48;2;24;28;38m" .. string.rep(" ", tw) .. "\27[0m"
            end

            pix[#pix+1] = bcolor .. b_v .. "\27[0m" .. prow .. bcolor .. b_v .. "\27[0m"
            if ri < #row_cards then pix[#pix+1] = string.rep(" ", gap) end
        end
        out[#out+1] = table.concat(pix) .. "\27[K\n"
    end

    -- ── bottom border (with resolution & file size metadata) ───
    local bot = { string.rep(" ", margin) }
    for ri, rc in ipairs(row_cards) do
        local is_sel = (rc.idx == selected_idx)
        local card   = cache[rc.idx]
        local b_h    = is_sel and "━" or "─"
        local c_bl   = is_sel and "┗" or "└"
        local c_br   = is_sel and "┛" or "┘"
        local bcolor = is_sel and "\27[1;36m" or "\27[90m"

        if card and not card.ok then
            local msg  = " \27[31m\xe2\x9a\xa0 error" .. bcolor .. " "
            local fill = math.max(0, tw - 9)
            bot[#bot+1] = bcolor .. c_bl .. msg .. string.rep(b_h, fill) .. c_br .. "\27[0m"
        else
            local size_str = format_bytes(rc.file.size)
            local dim_str = (card and card.orig_w) and string.format("%d×%d", card.orig_w, card.orig_h) or ""
            local meta_left = dim_str ~= "" and (" " .. dim_str .. " ") or ""
            local meta_right = " " .. size_str .. " "
            local fill = math.max(0, tw - vlen(meta_left) - vlen(meta_right))

            bot[#bot+1] = bcolor .. c_bl ..
                          "\27[90m" .. meta_left .. bcolor ..
                          string.rep(b_h, fill) ..
                          "\27[90m" .. meta_right .. bcolor ..
                          c_br .. "\27[0m"
        end
        if ri < #row_cards then bot[#bot+1] = string.rep(" ", gap) end
    end
    out[#out+1] = table.concat(bot) .. "\27[K\n"

    -- ── filename label ────────────────────────────────────────
    local lbl = { string.rep(" ", margin) }
    for ri, rc in ipairs(row_cards) do
        local is_sel = (rc.idx == selected_idx)
        local cw     = tw + 2
        if is_sel then
            local text = "► " .. trunc(rc.file.name, math.max(0, cw - 2))
            lbl[#lbl+1] = "\27[1;36m" .. pad_right(text, cw) .. "\27[0m"
        else
            lbl[#lbl+1] = "  \27[90m" .. pad_right(trunc(rc.file.name, cw - 2), cw - 2) .. "\27[0m"
        end
        if ri < #row_cards then lbl[#lbl+1] = string.rep(" ", gap) end
    end
    out[#out+1] = table.concat(lbl) .. "\27[K\n"
end

-- ============================================================
-- 8. Layout calculator
-- ============================================================
local function compute_layout(files, tw, th, force_cols, term_w, term_h)
    local gap      = 2
    local margin   = 2
    local cols     = force_cols or
                     math.max(1, math.floor((term_w - margin + gap) / (tw + 2 + gap)))
    local trows    = math.floor(th / 2)
    -- row_h: top_border(1) + pixel_rows(trows) + bot_border(1) + label(1) + blank(1)
    local row_h    = trows + 4
    -- header: 3 lines; footer: 2 lines (file info + scroll bar)
    local vis_rows = math.max(1, math.floor((term_h - 3 - 2) / row_h))
    local tot_rows = math.ceil(#files / cols)
    return { cols=cols, gap=gap, margin=margin,
             trows=trows, row_h=row_h,
             vis_rows=vis_rows, tot_rows=tot_rows }
end

-- ============================================================
-- 9. Help overlay modal (? key)
-- ============================================================
local function show_help()
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(68, math.max(40, term_w - 4))
    local inner_w = box_w - 4

    local help_lines = {
        { "\27[1;36mNAVIGATION\27[0m", "" },
        { "  ↑ / k, ↓ / j", "Scroll up / down one row" },
        { "  ← / h, → / l", "Select left / right image" },
        { "  PgUp / b, PgDn / Space", "Page up / down" },
        { "  g / Home, G / End", "Jump to first / last image" },
        { "", "" },
        { "\27[1;36mVIEWING & SIZING\27[0m", "" },
        { "  Enter", "Open selected image fullscreen" },
        { "  + / =", "Increase thumbnail size (zoom in)" },
        { "  - / _", "Decrease thumbnail size (zoom out)" },
        { "  o", "Open in OS default image viewer" },
        { "", "" },
        { "\27[1;36mFILTERING & SEARCH\27[0m", "" },
        { "  /", "Live search filter by name or extension" },
        { "  Esc", "Clear active filter / dismiss modal" },
        { "", "" },
        { "\27[1;36mGENERAL\27[0m", "" },
        { "  ?, F1", "Toggle this help dialog" },
        { "  q, Esc, Ctrl+C", "Quit application" },
    }

    local pad_top = math.max(1, math.floor((term_h - (#help_lines + 4)) / 2))
    local pad_left = math.max(0, math.floor((term_w - box_w) / 2))
    local pleft_str = string.rep(" ", pad_left)

    local out = { "\27[H" }
    for _ = 1, pad_top do out[#out+1] = "\27[K\n" end

    -- Dialog Top Border
    local title = " ❓ Help & Keybindings "
    local top_fill = math.max(0, box_w - 2 - vlen(title))
    out[#out+1] = pleft_str .. "\27[1;36m┏━" .. title .. string.rep("━", top_fill) .. "┓\27[0m\27[K\n"

    -- Dialog Content Lines
    for _, item in ipairs(help_lines) do
        local lcol, rcol = item[1], item[2]
        local row_str
        if rcol == "" then
            local fill = math.max(0, inner_w - vlen(lcol))
            row_str = " " .. lcol .. string.rep(" ", fill) .. " "
        else
            local lfill = math.max(0, 26 - vlen(lcol))
            local left = lcol .. string.rep(" ", lfill)
            local right = trunc(rcol, math.max(0, inner_w - 26))
            local fill = math.max(0, inner_w - vlen(left) - vlen(right))
            row_str = " " .. "\27[1;37m" .. left .. "\27[90m" .. right .. string.rep(" ", fill) .. "\27[0m "
        end
        out[#out+1] = pleft_str .. "\27[1;36m┃\27[0m" .. row_str .. "\27[1;36m┃\27[0m\27[K\n"
    end

    -- Dialog Bottom Border
    local dismiss = " [Press any key to close] "
    local bot_fill = math.max(0, box_w - 2 - vlen(dismiss))
    out[#out+1] = pleft_str .. "\27[1;36m┗" .. string.rep("━", bot_fill) .. "\27[93m" .. dismiss .. "\27[1;36m━┛\27[0m\27[K\n"

    out[#out+1] = "\27[J"
    io.write(table.concat(out))
    io.flush()

    -- Wait for dismissal keypress
    read_key(-1)
end

-- ============================================================
-- 10. Full-screen image viewer (Enter key from thumbnail browser)
-- ============================================================
local function view_fullscreen(files, initial_idx)
    local cur_idx = initial_idx
    local loaded_idx, full_lines, img_info = nil, nil, nil

    while true do
        local term_w, term_h = get_terminal_size()
        local cur_f = files[cur_idx]

        if cur_idx ~= loaded_idx then
            io.write("\27[H\27[2K\27[90m  Loading " .. trunc(cur_f.name, 45) .. "\xe2\x80\xa6\27[0m")
            io.flush()

            local img, err = load_image(cur_f.path)
            if img then
                local max_w = math.max(1, term_w)
                local max_h = math.max(2, (term_h - 2) * 2)
                local rw, rh = dimensions_for(img.width, img.height, max_w, max_h)
                if rh % 2 ~= 0 then rh = rh + 1 end
                local scaled = resize_bilinear(img, rw, rh)
                full_lines = render_halfblock(scaled)
                img_info = {
                    w = img.width, h = img.height,
                    rw = rw, rh = rh,
                    pad = math.max(0, math.floor((term_w - rw) / 2))
                }
            else
                full_lines = nil
                img_info = { err = err or "decode failed" }
            end
            loaded_idx = cur_idx
        end

        local out = { "\27[H" }
        local size_str = format_bytes(cur_f.size)
        local dim_str = (img_info and img_info.w) and string.format("%d×%d px", img_info.w, img_info.h) or ""
        local ext_color = EXT_COLORS[cur_f.ext] or "\27[97m"

        out[#out+1] = string.format(
            "\27[1;36m 🖼  [%d/%d]\27[0m \27[1;37m%s\27[0m  [%s%s\27[0m]  \27[90m%s%s%s\27[0m  \27[93m[?] \27[90mHelp  \27[93m[o] \27[90mOpen  \27[93m[Esc/Enter/q] \27[90mBack  \27[93m[←/→/h/l] \27[90mMove\27[K\n",
            cur_idx, #files, cur_f.name,
            ext_color, cur_f.ext,
            dim_str ~= "" and (dim_str .. " · ") or "",
            size_str,
            cur_f.path and (" · " .. trunc(cur_f.path, 35)) or ""
        )

        if full_lines and img_info then
            local pad_str = string.rep(" ", img_info.pad)
            for _, line in ipairs(full_lines) do
                out[#out+1] = pad_str .. line .. "\27[K\n"
            end
        else
            out[#out+1] = string.format("\n\n\27[31m  Error: %s\27[0m\27[K\n", img_info and img_info.err or "unknown")
        end
        out[#out+1] = "\27[J"
        io.write(table.concat(out))
        io.flush()

        local key = read_key(-1)
        if key == "q" or key == "Q" or key == "ESC" or key == "ENTER" or key == "BACKSPACE" then
            break
        elseif key == "CTRL_C" or key == "CTRL_D" then
            return nil
        elseif key == "?" or key == "F1" then
            show_help()
        elseif key == "o" or key == "O" then
            open_in_viewer(cur_f.path)
        elseif key == "LEFT" or key == "h" or key == "UP" or key == "k" then
            cur_idx = math.max(1, cur_idx - 1)
        elseif key == "RIGHT" or key == "l" or key == "DOWN" or key == "j" then
            cur_idx = math.min(#files, cur_idx + 1)
        elseif key == "PAGE_UP" or key == "b" then
            cur_idx = math.max(1, cur_idx - 10)
        elseif key == "PAGE_DOWN" or key == "SPACE" or key == "f" then
            cur_idx = math.min(#files, cur_idx + 10)
        elseif key == "HOME" or key == "g" then
            cur_idx = 1
        elseif key == "END" or key == "G" then
            cur_idx = #files
        end
    end
    return cur_idx
end

-- ============================================================
-- 10. TUI thumbnail browser  (interactive, lazy-load + cache)
-- ============================================================
local function browse_tui(dir_path, tw, th, force_cols)
    dir_path = (dir_path or "."):gsub("[/\\]+$", "")
    if dir_path == "" then dir_path = "." end
    if th % 2 ~= 0 then th = th + 1 end

    -- ── Scan ─────────────────────────────────────────────────
    local all_files = scan_dir(dir_path)
    if #all_files == 0 then
        io.write("\27[33mNo images found in: " .. dir_path .. "\27[0m\n")
        return false
    end

    -- ── State ─────────────────────────────────────────────────
    local filter_query = ""
    local files        = all_files
    local cache        = {}   -- cache[path] = { lines, cw, ch, orig_w, orig_h, ok, err }
    local cached_n     = 0
    local scroll_row   = 0    -- 0-indexed topmost visible grid row
    local selected_idx = 1    -- 1-based index in current 'files' list
    local running      = true

    local function apply_filter(q)
        filter_query = q
        if q == "" then
            files = all_files
        else
            local lq = q:lower()
            local filtered = {}
            for _, f in ipairs(all_files) do
                if f.name:lower():find(lq, 1, true) or f.ext:lower():find(lq, 1, true) then
                    filtered[#filtered+1] = f
                end
            end
            files = filtered
        end
        selected_idx = math.max(1, math.min(#files, selected_idx))
        scroll_row = 0
    end

    -- ── Lazy loader: decode & cache a range of card indices ───
    local function load_range(vis_start, vis_end)
        local needed = {}
        for i = vis_start, vis_end do
            local f = files[i]
            if f and not cache[f.path] then needed[#needed+1] = f end
        end
        if #needed == 0 then return end

        for ni, f in ipairs(needed) do
            io.write(string.format(
                "\27[H\27[2K  \27[90mLoading [%d/%d]  %s\xe2\x80\xa6\27[0m",
                ni, #needed, trunc(f.name, 50)))
            io.flush()

            local img, err = load_image(f.path)
            local ok, thumb = false, nil
            local orig_w, orig_h = nil, nil
            if img then
                orig_w, orig_h = img.width, img.height
                local rw, rh = dimensions_for(img.width, img.height, tw, th)
                if rh % 2 ~= 0 then rh = rh + 1 end
                thumb = resize_bilinear(img, rw, rh)
                ok    = true
            end
            cache[f.path] = {
                lines  = render_halfblock(ok and thumb or make_error_thumb(tw, th)),
                cw     = ok and thumb.width  or tw,
                ch     = ok and thumb.height or th,
                orig_w = orig_w,
                orig_h = orig_h,
                ok     = ok, err = err,
            }
            cached_n = cached_n + 1
        end
        io.write("\27[H\27[2K"); io.flush()
    end

    -- ── Enter alternate screen ─────────────────────────────────
    if not enable_raw_mode() then return nil end

    local ok_loop, err_loop = pcall(function()
        while running do
            local term_w, term_h = get_terminal_size()
            local L = compute_layout(files, tw, th, force_cols, term_w, term_h)

            if #files > 0 then
                -- Keep scroll in sync with selected_idx
                local sel_row = math.floor((selected_idx - 1) / L.cols)
                if sel_row < scroll_row then
                    scroll_row = sel_row
                elseif sel_row >= scroll_row + L.vis_rows then
                    scroll_row = sel_row - L.vis_rows + 1
                end
                scroll_row = math.max(0, math.min(scroll_row,
                    math.max(0, L.tot_rows - L.vis_rows)))

                local vis_start = scroll_row * L.cols + 1
                local vis_end   = math.min(#files, (scroll_row + L.vis_rows) * L.cols)
                load_range(vis_start, vis_end)
            else
                scroll_row = 0
            end

            -- ── Build frame ───────────────────────────────────
            local out = { "\27[H" }

            -- Header line 1
            local q_badge = filter_query ~= ""
                and ("  \27[1;33m[Filter: /" .. filter_query .. "]\27[0m")
                or ""
            out[#out+1] = string.format(
                "\27[1;36m 🖼  ffi_thumbnailer\27[0m  \27[33m📁 %s\27[0m" ..
                "  \27[90m%d/%d images · %d cols · %d×%d px\27[0m%s\27[K\n",
                dir_path, #files, #all_files, L.cols, tw, th, q_badge)

            -- Header line 2 (key hint badge)
            out[#out+1] =
                "\27[90m [?] Help · [Enter] Full · [o] Open · [/] Find · [+/-] Zoom · [↑↓←→/hjkl] Move · [PgUp/PgDn] Page · [q] Quit\27[0m\27[K\n"
            out[#out+1] = "\27[K\n"

            -- Visible grid rows
            if #files == 0 then
                out[#out+1] = string.format("\n\27[33m    No images match filter: '%s'\27[0m\27[K\n\n", filter_query)
                for _ = 1, math.max(1, L.vis_rows * L.row_h - 4) do out[#out+1] = "\27[K\n" end
            else
                for gr = scroll_row, scroll_row + L.vis_rows - 1 do
                    if gr >= L.tot_rows then
                        for _ = 1, L.row_h do out[#out+1] = "\27[K\n" end
                    else
                        local row_cards = {}
                        local row_cache = {}
                        for ci = gr * L.cols + 1, math.min(#files, (gr + 1) * L.cols) do
                            local f = files[ci]
                            row_cards[#row_cards+1] = { idx=ci, file=f }
                            row_cache[ci] = cache[f.path]
                        end
                        render_card_row(out, row_cards, row_cache, tw, th, L.margin, L.gap, selected_idx)
                        out[#out+1] = "\27[K\n"
                    end
                end
            end

            -- Footer line 1: selected image info
            local cur_f = files[selected_idx]
            local card  = cur_f and cache[cur_f.path]
            local res_info = (card and card.orig_w) and string.format(" \xc2\xb7 %d×%d px", card.orig_w, card.orig_h) or ""
            local size_info = cur_f and string.format(" \xc2\xb7 %s", format_bytes(cur_f.size)) or ""
            local ext_color = cur_f and (EXT_COLORS[cur_f.ext] or "\27[97m") or ""

            out[#out+1] = string.format(
                "\27[K\27[90m  Selected \27[1;36m[%d/%d]\27[0m \27[1;37m%s\27[0m  [%s%s\27[0m]%s%s  \27[93m[Enter]\27[90m View  \27[93m[o]\27[90m Open\27[0m\n",
                selected_idx, #files, cur_f and cur_f.name or "",
                ext_color, cur_f and cur_f.ext or "",
                res_info, size_info)

            -- Footer line 2: scroll progress bar & cache status
            local pct = L.tot_rows <= L.vis_rows and 100 or
                math.floor(scroll_row / math.max(1, L.tot_rows - L.vis_rows) * 100)
            local bar_w  = 20
            local filled = math.floor(pct / 100 * bar_w)
            local bar    = string.rep("\xe2\x96\x88", filled) ..
                           string.rep("\xe2\x96\x91", bar_w - filled)
            out[#out+1] = string.format(
                "\27[K\27[90m  \27[93m%s\27[90m  rows %d\xe2\x80\x93%d/%d" ..
                "  cache %d/%d\27[0m",
                bar,
                #files > 0 and (scroll_row + 1) or 0,
                math.min(scroll_row + L.vis_rows, L.tot_rows),
                L.tot_rows, cached_n, #all_files)

            out[#out+1] = "\27[J"
            io.write(table.concat(out)); io.flush()

            -- ── Wait for keypress ─────────────────────────────
            local key = read_key(-1)

            if key == "q" or key == "Q" or key == "ESC"
            or key == "CTRL_C" or key == "CTRL_D" then
                if filter_query ~= "" and key == "ESC" then
                    apply_filter("")
                else
                    running = false
                end
            elseif key == "ENTER" and #files > 0 then
                local next_idx = view_fullscreen(files, selected_idx)
                if next_idx == nil then
                    running = false
                else
                    selected_idx = next_idx
                end
            elseif key == "?" or key == "F1" then
                show_help()
            elseif (key == "o" or key == "O") and cur_f then
                open_in_viewer(cur_f.path)
            elseif key == "+" or key == "=" then
                -- Zoom in
                if tw + 8 <= 128 and th + 5 <= 80 then
                    tw = tw + 8
                    th = th + 5
                    if th % 2 ~= 0 then th = th + 1 end
                    cache = {}  -- invalidate cache on resolution change
                    cached_n = 0
                end
            elseif key == "-" or key == "_" then
                -- Zoom out
                if tw - 8 >= 16 and th - 5 >= 10 then
                    tw = tw - 8
                    th = th - 5
                    if th % 2 ~= 0 then th = th + 1 end
                    cache = {}  -- invalidate cache on resolution change
                    cached_n = 0
                end
            elseif key == "/" then
                -- Interactive prompt for filter
                io.write("\27[H\27[2K\27[1;33m/ Search filter (Enter to submit, Esc to clear): \27[0m")
                io.flush()
                local qchars = {}
                while true do
                    local fk = read_key(-1)
                    if fk == "ENTER" then
                        apply_filter(table.concat(qchars))
                        break
                    elseif fk == "ESC" then
                        apply_filter("")
                        break
                    elseif fk == "CTRL_C" or fk == "CTRL_D" then
                        break
                    elseif fk == "BACKSPACE" then
                        if #qchars > 0 then
                            qchars[#qchars] = nil
                            io.write("\8 \8")
                            io.flush()
                        end
                    elseif fk and #fk == 1 and fk:byte(1) >= 32 and fk:byte(1) <= 126 then
                        qchars[#qchars+1] = fk
                        io.write(fk)
                        io.flush()
                    end
                end
            elseif key == "LEFT"  or key == "h" then
                selected_idx = math.max(1, selected_idx - 1)
            elseif key == "RIGHT" or key == "l" then
                selected_idx = math.min(#files, selected_idx + 1)
            elseif key == "DOWN"  or key == "j" then
                selected_idx = math.min(#files, selected_idx + L.cols)
            elseif key == "UP"    or key == "k" then
                selected_idx = math.max(1, selected_idx - L.cols)
            elseif key == "PAGE_DOWN" or key == "SPACE" or key == "f" then
                local page_step = L.cols * math.max(2, L.vis_rows)
                selected_idx = math.min(#files, selected_idx + page_step)
            elseif key == "PAGE_UP" or key == "b" then
                local page_step = L.cols * math.max(2, L.vis_rows)
                selected_idx = math.max(1, selected_idx - page_step)
            elseif key == "HOME" or key == "g" then
                selected_idx = 1
            elseif key == "END"  or key == "G" then
                selected_idx = #files
            end
        end
    end)

    disable_raw_mode()

    if not ok_loop then
        io.stderr:write("TUI error: " .. tostring(err_loop) .. "\n")
        return false
    end
    return true
end

-- ============================================================
-- 11. Flat browser  (non-TTY fallback: load all, print grid)
-- ============================================================
local function browse_flat(dir_path, tw, th, force_cols)
    dir_path = (dir_path or "."):gsub("[/\\]+$", "")
    if dir_path == "" then dir_path = "." end
    if th % 2 ~= 0 then th = th + 1 end

    io.write(string.format("\27[90mScanning %s ...\27[0m\r", dir_path)); io.flush()
    local files = scan_dir(dir_path)
    io.write("\27[2K"); io.flush()

    if #files == 0 then
        io.write("\27[33mNo images found in: " .. dir_path .. "\27[0m\n"); return false
    end

    local term_w = get_terminal_size()
    local L = compute_layout(files, tw, th, force_cols, term_w, 999)

    io.write(string.format(
        "\n\27[1;36m  ffi_thumbnailer\27[0m  \27[33m%s\27[0m" ..
        "  \27[90m[%d images · %d cols · %dx%d px]\27[0m\n\n",
        dir_path, #files, L.cols, tw, th))

    -- load all images up front
    local cache = {}
    for i, f in ipairs(files) do
        io.write(string.format(
            "\27[90m  Loading [%d/%d]  %-45s\27[0m\r", i, #files, trunc(f.name, 45)))
        io.flush()
        local img, err = load_image(f.path)
        local ok, thumb = false, nil
        local orig_w, orig_h = nil, nil
        if img then
            orig_w, orig_h = img.width, img.height
            local rw, rh = dimensions_for(img.width, img.height, tw, th)
            if rh % 2 ~= 0 then rh = rh + 1 end
            thumb = resize_bilinear(img, rw, rh); ok = true
        end
        cache[i] = { lines = render_halfblock(ok and thumb or make_error_thumb(tw, th)),
                     cw = ok and thumb.width or tw, ch = ok and thumb.height or th,
                     orig_w = orig_w, orig_h = orig_h,
                     ok = ok, err = err }
    end
    io.write("\27[2K"); io.flush()

    for row_start = 1, #files, L.cols do
        local row_cards = {}
        for ci = row_start, math.min(#files, row_start + L.cols - 1) do
            row_cards[#row_cards+1] = { idx=ci, file=files[ci] }
        end
        local out = {}
        render_card_row(out, row_cards, cache, tw, th, L.margin, L.gap)
        out[#out+1] = "\n"
        io.write(table.concat(out))
    end

    io.write(string.format(
        "\27[90m  \xe2\x9c\x93  %d image%s  \xc2\xb7  %s\27[0m\n\n",
        #files, #files == 1 and "" or "s", dir_path))
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
local thumb_w    = 48
local thumb_h    = 30
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

-- Try interactive TUI first; if not a TTY, fall back to flat output
local result = browse_tui(dir_path, thumb_w, thumb_h, force_cols)
if result == nil then
    result = browse_flat(dir_path, thumb_w, thumb_h, force_cols)
end
os.exit(result and 0 or 1)
