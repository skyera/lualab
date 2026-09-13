--[[
    view_gallery_terminal.lua
    Professional Interactive Terminal Directory Image Viewer written in LuaJIT FFI.

    Features:
    1. Directory Scanning:
       - Scans current working directory ('.') by default, or an input directory provided via argument / prompt.
       - Level 1 scanning default, or recursive scanning via -r / --recursive.
       - Supports standard image formats: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP.
    2. Interactive File Selector & TUI:
       - Uses Terminal Alternate Screen Buffer (\27[?1049h) for clean enter and exit.
       - Live interactive substring search / filter with [/] and [Esc].
       - Sort cycle with [s] (Name -> Date -> Size) and reverse sort with [r].
       - Displays sorted list of image files with index numbers, filenames, file sizes, formats, and dates.
       - Supports arrow keys (↑ / ↓ / k / j), direct number entry, Enter/Space to view, 'q' to quit.
       - Interactive Help popup modal with [?].
       - CLI direct selection flag: --select <n> or -s <n>.
       - Non-interactive / pipe friendly fallback.
    3. Dual Graphics Rendering Engine:
       - Kitty Graphics Protocol: Auto-detected (Kitty, Ghostty, WezTerm). Renders native pixel-perfect images.
       - iTerm2 Inline Image Protocol: Auto-detected for WezTerm / iTerm2 with tmux passthrough.
       - ANSI Truecolor Half-Block: Clean fallback using 24-bit ANSI '▄' (2 vertical pixels per cell).
       - Auto-detects terminal width & height via POSIX ioctl(TIOCGWINSZ) and scales image to fit cleanly.
       - Command-line overrides: --kitty (force Kitty protocol), --iterm, --half-block (force ANSI half-block).
       - In view mode: allows browsing previous/next images with ← / → / [P] / [N] or returning to menu with [Enter] / [B].
]]

local ffi = require("ffi")
local posix_stat

-- =========================================================================
-- 1. C Declarations for Windows / POSIX, Terminal Window, Input, & Directory
-- =========================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct { uint8_t r, g, b; } PixelRGB;
]]

local get_terminal_size
local enable_raw_mode
local disable_raw_mode
local read_key
local is_stdin_tty
local scan_directory_images

local SUPPORTED_EXTENSIONS = {
    png  = true,
    jpg  = true,
    jpeg = true,
    ppm  = true,
    webp = true,
    gif  = true,
    bmp  = true,
}

local EXTENSION_ICONS = {
    unicode = {
        DIR  = "📁 ",
        PNG  = "🖼 ",
        JPG  = "📷",
        JPEG = "📷",
        PPM  = "▦ ",
        WEBP = "🌐",
        GIF  = "🎞 ",
        BMP  = "🎨",
    },
    nerd = {
        DIR  = "\238\151\191 ", -- 
        PNG  = "\238\176\169 ", -- 󰋩
        JPG  = "\238\176\132 ", -- 󰄄
        JPEG = "\238\176\132 ", -- 󰄄
        PPM  = "\238\176\174 ", -- 󰈮
        WEBP = "\238\176\159 ", -- 󰖟
        GIF  = "\238\181\184 ", -- 󰵸
        BMP  = "\238\175\152 ", -- 󰏘
    }
}

local function get_file_icon(ext, icon_mode)
    if icon_mode == "none" then return "" end
    local group = EXTENSION_ICONS[icon_mode] or EXTENSION_ICONS.unicode
    return group[ext:upper()] or (ext:upper() == "DIR" and "📁 " or "📄")
end

local function format_file_size(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.2f MB", bytes / (1024 * 1024))
    end
end

local function format_date(timestamp)
    if not timestamp or timestamp <= 0 then return "-" end
    local ok, res = pcall(os.date, "%Y-%m-%d", timestamp)
    return ok and res or "-"
end

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

        typedef struct {
            uint32_t dwLowDateTime;
            uint32_t dwHighDateTime;
        } FILETIME;

        typedef struct {
            uint32_t dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            uint32_t nFileSizeHigh;
            uint32_t nFileSizeLow;
            uint32_t dwReserved0;
            uint32_t dwReserved1;
            char     cFileName[260];
            char     cAlternateFileName[14];
        } WIN32_FIND_DATAA;

        void*    __stdcall GetStdHandle(uint32_t nStdHandle);
        int      __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int      __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int      __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int      __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        uint32_t __stdcall GetFileType(void* hFile);
        void*    __stdcall FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA* lpFindFileData);
        int      __stdcall FindNextFileA(void* hFindFile, WIN32_FIND_DATAA* lpFindFileData);
        int      __stdcall FindClose(void* hFindFile);
        void     __stdcall Sleep(uint32_t dwMilliseconds);

        int _kbhit(void);
        int _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6 -- ((uint32_t)-10)
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- ((uint32_t)-11)
    local INVALID_HANDLE_VALUE = ffi.cast("void*", -1)
    local FILE_ATTRIBUTE_DIRECTORY = 0x10

    local orig_in_mode = ffi.new("uint32_t[1]")
    local raw_mode_enabled = false

    -- Initialize Windows UTF-8 console output and ANSI Virtual Terminal Processing
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

        io.write("\27[?1049h\27[?25l") -- Alternate screen buffer + Hide cursor
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?1049l\27[?25h\27[0m") -- Restore main screen + show cursor
            io.flush()
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            raw_mode_enabled = false
        end
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or -1
        local elapsed = 0
        while timeout_ms < 0 or elapsed <= timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                local ch = ffi.C._getch()
                if ch == 0 or ch == 224 then
                    -- Extended key code
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
                elseif ch == 3 then
                    return "CTRL_C"
                else
                    return string.char(ch)
                end
            end
            if timeout_ms >= 0 then
                ffi.C.Sleep(20)
                elapsed = elapsed + 20
            else
                ffi.C.Sleep(10)
            end
        end
        return nil
    end

    local function scan_win_dir(dir_path, entries, recursive)
        local search_pattern = (dir_path == ".") and "*.*" or (dir_path .. "\\*.*")
        local find_data = ffi.new("WIN32_FIND_DATAA")
        local hFind = ffi.C.FindFirstFileA(search_pattern, find_data)

        if hFind == INVALID_HANDLE_VALUE then
            return
        end

        repeat
            local fname = ffi.string(find_data.cFileName)
            local is_dir = bit.band(find_data.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0

            if fname ~= "." and fname ~= ".." and not fname:match("^%.") then
                local full_path = (dir_path == ".") and fname or (dir_path .. "/" .. fname)
                local ft = tonumber(find_data.ftLastWriteTime.dwHighDateTime) * 4294967296 + tonumber(find_data.ftLastWriteTime.dwLowDateTime)
                local mtime = math.floor((ft - 116444736000000000) / 10000000)

                if is_dir then
                    if recursive then
                        scan_win_dir(full_path, entries, true)
                    else
                        table.insert(entries, {
                            filename = fname,
                            filepath = full_path,
                            is_dir = true,
                            extension = "DIR",
                            size = 0,
                            size_str = "<DIR>",
                            mtime = mtime,
                            date_str = format_date(mtime),
                        })
                    end
                else
                    local ext = fname:match("%.([^.]+)$")
                    if ext and SUPPORTED_EXTENSIONS[ext:lower()] then
                        local size = tonumber(find_data.nFileSizeHigh) * 4294967296 + tonumber(find_data.nFileSizeLow)
                        table.insert(entries, {
                            filename = fname,
                            filepath = full_path,
                            is_dir = false,
                            extension = ext:upper(),
                            size = size,
                            size_str = format_file_size(size),
                            mtime = mtime,
                            date_str = format_date(mtime),
                        })
                    end
                end
            end
        until ffi.C.FindNextFileA(hFind, find_data) == 0

        ffi.C.FindClose(hFind)
    end

    scan_directory_images = function(dir_path, recursive)
        dir_path = dir_path or "."
        dir_path = dir_path:gsub("[/\\]+$", "")
        if dir_path == "" then dir_path = "." end

        local entries = {}
        if not recursive and dir_path ~= "." and not dir_path:match("^[A-Za-z]:[/\\]?$") and dir_path ~= "/" then
            local parent_path = dir_path:match("^(.*)[/\\][^/\\]+$") or "."
            if parent_path == "" then parent_path = "." end
            table.insert(entries, {
                filename = "..",
                filepath = parent_path,
                is_dir = true,
                is_parent = true,
                extension = "DIR",
                size = 0,
                size_str = "<DIR>",
                mtime = 0,
                date_str = "-",
            })
        end

        scan_win_dir(dir_path, entries, recursive)
        return entries
    end
else
    -- POSIX / Linux / macOS
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

        typedef struct DIR DIR;
        struct dirent {
            unsigned long  d_ino;
            long           d_off;
            unsigned short d_reclen;
            unsigned char  d_type;
            char           d_name[256];
        };
        DIR *opendir(const char *name);
        struct dirent *readdir(DIR *dirp);
        int closedir(DIR *dirp);

        typedef long time_t;
        struct stat {
            unsigned long  st_dev;
            unsigned long  st_ino;
            unsigned long  st_nlink;
            unsigned int   st_mode;
            unsigned int   st_uid;
            unsigned int   st_gid;
            unsigned int   __pad0;
            unsigned long  st_rdev;
            long           st_size;
            long           st_blksize;
            long           st_blocks;
            time_t         st_atime;
            unsigned long  st_atime_nsec;
            time_t         st_mtime;
            unsigned long  st_mtime_nsec;
            time_t         st_ctime;
            unsigned long  st_ctime_nsec;
            long           __unused[3];
        };
        int stat(const char *pathname, struct stat *statbuf);
        int __xstat(int ver, const char *pathname, struct stat *statbuf);
    ]]

    if pcall(function() return ffi.C.__xstat end) then
        posix_stat = function(path, st)
            return ffi.C.__xstat(1, path, st)
        end
    elseif pcall(function() return ffi.C.stat end) then
        posix_stat = function(path, st)
            return ffi.C.stat(path, st)
        end
    else
        posix_stat = function(path, st) return -1 end
    end

    local TIOCGWINSZ = 0x5413
    local STDIN_FILENO = 0
    local TCSANOW = 0
    local ICANON = 2
    local ECHO = 8
    local POLLIN = 1

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if pcall(function() return ffi.C.ioctl(1, TIOCGWINSZ, ws) end) and ws.ws_col > 0 and ws.ws_row > 0 then
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

        io.write("\27[?1049h\27[?25l") -- Alternate screen buffer + Hide cursor
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?1049l\27[?25h\27[0m") -- Restore main screen + show cursor
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            raw_mode_enabled = false
        end
    end

    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local key_buf = ffi.new("char[16]")

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or -1
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
                        if c2 == 72 then return "HOME" end
                        if c2 == 70 then return "END" end
                    end
                    return "ESC"
                elseif c0 == 10 or c0 == 13 then
                    return "ENTER"
                elseif c0 == 32 then
                    return "SPACE"
                elseif c0 == 127 or c0 == 8 then
                    return "BACKSPACE"
                elseif c0 == 3 then
                    return "CTRL_C"
                else
                    return string.char(c0)
                end
            end
        end
        return nil
    end

    local function scan_posix_dir(dir_path, entries, recursive)
        local d = ffi.C.opendir(dir_path)
        if d == nil then return end

        local st = ffi.new("struct stat")
        while true do
            local ent = ffi.C.readdir(d)
            if ent == nil then break end
            local fname = ffi.string(ent.d_name)

            if fname ~= "." and fname ~= ".." and not fname:match("^%.") then
                local full_path = (dir_path == ".") and fname or (dir_path .. "/" .. fname)
                if posix_stat(full_path, st) == 0 then
                    local mode = tonumber(st.st_mode)
                    local is_dir = (bit.band(mode, 0xF000) == 0x4000)
                    local is_reg = (bit.band(mode, 0xF000) == 0x8000)
                    local mtime = tonumber(st.st_mtime)

                    if is_dir then
                        if recursive then
                            scan_posix_dir(full_path, entries, true)
                        else
                            table.insert(entries, {
                                filename = fname,
                                filepath = full_path,
                                is_dir = true,
                                extension = "DIR",
                                size = 0,
                                size_str = "<DIR>",
                                mtime = mtime,
                                date_str = format_date(mtime),
                            })
                        end
                    elseif is_reg then
                        local ext = fname:match("%.([^.]+)$")
                        if ext and SUPPORTED_EXTENSIONS[ext:lower()] then
                            local size = tonumber(st.st_size)
                            table.insert(entries, {
                                filename = fname,
                                filepath = full_path,
                                is_dir = false,
                                extension = ext:upper(),
                                size = size,
                                size_str = format_file_size(size),
                                mtime = mtime,
                                date_str = format_date(mtime),
                            })
                        end
                    end
                end
            end
        end
        ffi.C.closedir(d)
    end

    scan_directory_images = function(dir_path, recursive)
        dir_path = dir_path or "."
        if #dir_path > 1 and dir_path:sub(-1) == "/" then
            dir_path = dir_path:sub(1, -2)
        end

        local entries = {}
        if not recursive and dir_path ~= "." and dir_path ~= "/" then
            local parent_path = dir_path:match("^(.*)/[^/]+$") or "."
            if parent_path == "" then parent_path = "/" end
            table.insert(entries, {
                filename = "..",
                filepath = parent_path,
                is_dir = true,
                is_parent = true,
                extension = "DIR",
                size = 0,
                size_str = "<DIR>",
                mtime = 0,
                date_str = "-",
            })
        end

        scan_posix_dir(dir_path, entries, recursive)
        return entries
    end
end

-- =========================================================================
-- 4. Netpbm PPM & Streaming Image Decoder
-- =========================================================================
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
    if magic ~= "P6" and magic ~= "P3" then
        return nil, "Unsupported PPM magic header: " .. tostring(magic)
    end

    local width = tonumber(next_token())
    local height = tonumber(next_token())
    local max_val = tonumber(next_token())

    if not width or not height or not max_val or width <= 0 or height <= 0 then
        return nil, "Corrupted PPM header"
    end

    local pixels = ffi.new("PixelRGB[?]", width * height)

    if magic == "P6" then
        local total_bytes = width * height * 3
        local raw_bytes = f:read(total_bytes)
        if not raw_bytes or #raw_bytes < total_bytes then
            return nil, "Incomplete binary PPM pixel stream"
        end
        ffi.copy(pixels, raw_bytes, total_bytes)
    else
        local scale = 255.0 / max_val
        for i = 0, width * height - 1 do
            local r = tonumber(next_token()) or 0
            local g = tonumber(next_token()) or 0
            local b = tonumber(next_token()) or 0
            pixels[i].r = math.floor(r * scale)
            pixels[i].g = math.floor(g * scale)
            pixels[i].b = math.floor(b * scale)
        end
    end

    return {
        width = width,
        height = height,
        pixels = pixels,
        engine = "FFI (Netpbm PPM)"
    }
end

-- =========================================================================
-- 4b. Zero-Dependency & Dynamic FFI Image Decoders (BMP, PNG, JPEG, WebP)
-- =========================================================================
local function load_first_lib(names)
    for _, name in ipairs(names) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then return lib end
    end
    return nil
end

-- 1. Pure LuaJIT FFI Windows Bitmap (BMP) Decoder (Zero external dependencies)
local function decode_bmp_ffi(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil, "Cannot open file: " .. filepath end

    local header = f:read(54)
    if not header or #header < 54 then
        f:close()
        return nil, "File too small for BMP header"
    end
    if header:sub(1, 2) ~= "BM" then
        f:close()
        return nil, "Not a valid BMP header"
    end

    local function r16(pos)
        local b1, b2 = header:byte(pos, pos + 1)
        return b1 + b2 * 256
    end
    local function r32(pos)
        local b1, b2, b3, b4 = header:byte(pos, pos + 3)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    local function r32s(pos)
        local u = r32(pos)
        return (u >= 0x80000000) and (u - 0x100000000) or u
    end

    local off_bits = r32(11) -- byte offset 10 in 0-indexed
    local dib_size = r32(15)
    local w = r32s(19)
    local h = r32s(23)
    local planes = r16(27)
    local bpp = r16(29)
    local comp = r32(31)

    if w <= 0 or h == 0 or planes ~= 1 then
        f:close()
        return nil, "Invalid BMP dimensions or planes"
    end
    if comp ~= 0 and comp ~= 3 then
        f:close()
        return nil, "Compressed BMP not supported"
    end
    if bpp ~= 24 and bpp ~= 32 and bpp ~= 8 then
        f:close()
        return nil, "Unsupported BMP bit depth: " .. tostring(bpp)
    end

    local top_down = (h < 0)
    local abs_h = math.abs(h)
    local palette = nil
    if bpp == 8 then
        f:seek("set", 14 + dib_size)
        local pal_data = f:read(256 * 4)
        if pal_data and #pal_data >= 1024 then
            palette = {}
            for i = 0, 255 do
                local b, g, r = pal_data:byte(i * 4 + 1, i * 4 + 3)
                palette[i] = { r = r or 0, g = g or 0, b = b or 0 }
            end
        end
    end

    f:seek("set", off_bits)
    local bytes_per_pixel = bpp / 8
    local row_stride = math.floor((w * bytes_per_pixel + 3) / 4) * 4
    local all_rows = f:read(row_stride * abs_h)
    f:close()

    if not all_rows or #all_rows < row_stride * abs_h then
        return nil, "Incomplete BMP pixel data"
    end

    local pixels = ffi.new("PixelRGB[?]", w * abs_h)
    local raw_ptr = ffi.cast("const uint8_t*", all_rows)

    for y = 0, abs_h - 1 do
        local src_y = top_down and y or (abs_h - 1 - y)
        local row_offset = src_y * row_stride
        local dst_row_offset = y * w

        if bpp == 24 then
            for x = 0, w - 1 do
                local p = row_offset + x * 3
                local d = dst_row_offset + x
                pixels[d].b = raw_ptr[p]
                pixels[d].g = raw_ptr[p + 1]
                pixels[d].r = raw_ptr[p + 2]
            end
        elseif bpp == 32 then
            for x = 0, w - 1 do
                local p = row_offset + x * 4
                local d = dst_row_offset + x
                pixels[d].b = raw_ptr[p]
                pixels[d].g = raw_ptr[p + 1]
                pixels[d].r = raw_ptr[p + 2]
            end
        elseif bpp == 8 and palette then
            for x = 0, w - 1 do
                local idx = raw_ptr[row_offset + x]
                local d = dst_row_offset + x
                local entry = palette[idx] or { r = 0, g = 0, b = 0 }
                pixels[d].r = entry.r
                pixels[d].g = entry.g
                pixels[d].b = entry.b
            end
        end
    end

    return { width = w, height = abs_h, pixels = pixels, engine = "FFI (Native BMP)" }
end

-- 2. FFI PNG Decoder via libpng Simplified API
local libpng_instance = nil
local libpng_attempted = false

local function get_libpng()
    if libpng_attempted then return libpng_instance end
    libpng_attempted = true

    pcall(ffi.cdef, [[
        typedef struct png_color { uint8_t red, green, blue; } png_color;
        typedef struct png_image {
            void*        opaque;
            uint32_t     version;
            uint32_t     width;
            uint32_t     height;
            uint32_t     format;
            uint32_t     flags;
            uint32_t     colormap_entries;
            uint32_t     warning_or_error;
            char         message[64];
        } png_image, *png_imagep;

        int png_image_begin_read_from_file(png_imagep image, const char *file_name);
        int png_image_finish_read(png_imagep image, const png_color *background, void *buffer, int32_t row_stride, void *colormap);
        void png_image_free(png_imagep image);
    ]])

    libpng_instance = load_first_lib({
        "png", "libpng16", "libpng16.so.16", "libpng16.so", "libpng.so",
        "libpng16.dylib", "libpng.dylib", "libpng16.dll", "png.dll"
    })
    return libpng_instance
end

local function decode_png_ffi(filepath)
    local png = get_libpng()
    if not png then return nil, "libpng not found" end

    local ok, res = pcall(function()
        local img = ffi.new("png_image")
        img.version = 1 -- PNG_IMAGE_VERSION
        if png.png_image_begin_read_from_file(img, filepath) == 0 then
            local msg = ffi.string(img.message)
            png.png_image_free(img)
            return nil, msg
        end

        local PNG_FORMAT_RGB = 2
        img.format = PNG_FORMAT_RGB
        local w = tonumber(img.width)
        local h = tonumber(img.height)
        local pixels = ffi.new("PixelRGB[?]", w * h)

        local finish_ret = png.png_image_finish_read(img, nil, pixels, 0, nil)
        png.png_image_free(img)

        if finish_ret == 0 then
            return nil, "Failed to read PNG scanlines"
        end

        return { width = w, height = h, pixels = pixels, engine = "FFI (libpng)" }
    end)

    if ok and res then return res end
    return nil, tostring(res or "PNG decoding error")
end

-- 3. FFI JPEG Decoder via libturbojpeg / libjpeg
local libturbojpeg_instance = nil
local libturbojpeg_attempted = false

local function get_libturbojpeg()
    if libturbojpeg_attempted then return libturbojpeg_instance end
    libturbojpeg_attempted = true

    pcall(ffi.cdef, [[
        void* tjInitDecompress(void);
        int tjDecompressHeader3(void* handle, const unsigned char* jpegBuf, unsigned long jpegSize, int* width, int* height, int* jpegSubsamp, int* jpegColorspace);
        int tjDecompress2(void* handle, const unsigned char* jpegBuf, unsigned long jpegSize, unsigned char* dstBuf, int width, int pitch, int height, int pixelFormat, int flags);
        int tjDestroy(void* handle);
    ]])

    libturbojpeg_instance = load_first_lib({
        "turbojpeg", "libturbojpeg.so.0", "libturbojpeg.so", "turbojpeg.dylib", "turbojpeg.dll"
    })
    return libturbojpeg_instance
end

local function decode_jpeg_ffi(filepath)
    local tj = get_libturbojpeg()
    if not tj then return nil, "libturbojpeg not found" end

    local ok, res = pcall(function()
        local f = io.open(filepath, "rb")
        if not f then return nil, "Cannot open JPEG file" end
        local data = f:read("*a")
        f:close()

        if not data or #data < 4 then return nil, "Corrupt JPEG data" end

        local handle = tj.tjInitDecompress()
        if handle == nil then return nil, "Failed to initialize TurboJPEG decompressor" end

        local w = ffi.new("int[1]")
        local h = ffi.new("int[1]")
        local subsamp = ffi.new("int[1]")
        local cs = ffi.new("int[1]")

        local ret_hdr = tj.tjDecompressHeader3(handle, data, #data, w, h, subsamp, cs)
        if ret_hdr ~= 0 then
            tj.tjDestroy(handle)
            return nil, "Invalid JPEG header"
        end

        local width = w[0]
        local height = h[0]
        local TJPF_RGB = 0
        local pixels = ffi.new("PixelRGB[?]", width * height)

        local ret_dec = tj.tjDecompress2(handle, data, #data, ffi.cast("unsigned char*", pixels), width, 0, height, TJPF_RGB, 0)
        tj.tjDestroy(handle)

        if ret_dec ~= 0 then
            return nil, "Failed to decompress JPEG image"
        end

        return { width = width, height = height, pixels = pixels, engine = "FFI (TurboJPEG)" }
    end)

    if ok and res then return res end
    return nil, tostring(res or "JPEG decoding error")
end

-- 4. FFI WebP Decoder via libwebp
local libwebp_instance = nil
local libwebp_attempted = false

local function get_libwebp()
    if libwebp_attempted then return libwebp_instance end
    libwebp_attempted = true

    pcall(ffi.cdef, [[
        uint8_t* WebPDecodeRGB(const uint8_t* data, size_t data_size, int* width, int* height);
        void WebPFree(void* ptr);
    ]])

    libwebp_instance = load_first_lib({
        "webp", "libwebp.so.7", "libwebp.so", "libwebp.dylib", "libwebp.dll"
    })
    return libwebp_instance
end

local function decode_webp_ffi(filepath)
    local webp = get_libwebp()
    if not webp then return nil, "libwebp not found" end

    local ok, res = pcall(function()
        local f = io.open(filepath, "rb")
        if not f then return nil, "Cannot open WebP file" end
        local data = f:read("*a")
        f:close()

        if not data or #data < 12 then return nil, "Corrupt WebP data" end

        local w = ffi.new("int[1]")
        local h = ffi.new("int[1]")
        local raw_rgb = webp.WebPDecodeRGB(data, #data, w, h)
        if raw_rgb == nil then
            return nil, "Failed to decode WebP image"
        end

        local width = w[0]
        local height = h[0]
        local pixels = ffi.new("PixelRGB[?]", width * height)
        ffi.copy(pixels, raw_rgb, width * height * 3)
        webp.WebPFree(raw_rgb)

        return { width = width, height = height, pixels = pixels, engine = "FFI (libwebp)" }
    end)

    if ok and res then return res end
    return nil, tostring(res or "WebP decoding error")
end

local function load_image(filepath)
    local test_f = io.open(filepath, "rb")
    if not test_f then
        return nil, "Cannot open file: " .. filepath
    end
    local header = test_f:read(16) or ""
    test_f:close()

    -- 1. Built-in PPM decoder
    if header:sub(1, 2) == "P6" or header:sub(1, 2) == "P3" then
        local f = io.open(filepath, "rb")
        local img, err = parse_ppm_stream(f)
        f:close()
        if img then return img end
    end

    -- 2. Pure LuaJIT FFI Windows Bitmap (BMP)
    if header:sub(1, 2) == "BM" then
        local img, _ = decode_bmp_ffi(filepath)
        if img then return img end
    end

    -- 3. FFI PNG decoder
    if header:sub(1, 8) == "\137PNG\r\n\26\n" then
        local img, _ = decode_png_ffi(filepath)
        if img then return img end
    end

    -- 4. FFI JPEG decoder
    if header:sub(1, 2) == "\255\216" then
        local img, _ = decode_jpeg_ffi(filepath)
        if img then return img end
    end

    -- 5. FFI WebP decoder
    if header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WEBP" then
        local img, _ = decode_webp_ffi(filepath)
        if img then return img end
    end

    -- 6. Secondary fallback: CLI tools (ImageMagick / ffmpeg) if available
    local devnull = is_windows and "nul" or "/dev/null"
    local cmd
    if is_windows then
        cmd = string.format("magick %q ppm:- 2>%s || ffmpeg -v error -i %q -f image2pipe -vcodec ppm - 2>%s", filepath, devnull, filepath, devnull)
    else
        cmd = string.format("magick %q ppm:- 2>%s || convert %q ppm:- 2>%s || ffmpeg -v error -i %q -f image2pipe -vcodec ppm - 2>%s", filepath, devnull, filepath, devnull, filepath, devnull)
    end
    local pipe = io.popen(cmd, "r")
    if pipe then
        local img = parse_ppm_stream(pipe)
        pipe:close()
        if img then
            img.engine = "CLI (magick/convert/ffmpeg)"
            return img
        end
    end

    return nil, "Failed to decode image. Ensure image is valid (PNG, JPG, BMP, WEBP, PPM) and FFI libraries (libpng, libturbojpeg, libwebp) or ImageMagick/ffmpeg are available."
end

-- =========================================================================
-- 5. Kitty Graphics Protocol & Fallback Truecolor Renderer
-- =========================================================================
local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_encode(data, len)
    len = len or #data
    local t = {}
    local n = 0
    for i = 1, len, 3 do
        local b0 = data:byte(i)
        local b1 = (i + 1 <= len) and data:byte(i + 1) or 0
        local b2 = (i + 2 <= len) and data:byte(i + 2) or 0
        local n3 = bit.bor(bit.lshift(b0, 16), bit.lshift(b1, 8), b2)
        local c1 = bit.band(bit.rshift(n3, 18), 63)
        local c2 = bit.band(bit.rshift(n3, 12), 63)
        local c3 = bit.band(bit.rshift(n3, 6), 63)
        local c4 = bit.band(n3, 63)
        n = n + 1; t[n] = b64_chars:sub(c1 + 1, c1 + 1)
        n = n + 1; t[n] = b64_chars:sub(c2 + 1, c2 + 1)
        n = n + 1; t[n] = (i + 1 <= len) and b64_chars:sub(c3 + 1, c3 + 1) or "="
        n = n + 1; t[n] = (i + 2 <= len) and b64_chars:sub(c4 + 1, c4 + 1) or "="
    end
    return table.concat(t)
end

-- Check if running inside tmux
local function is_inside_tmux()
    return os.getenv("TMUX") ~= nil
end

-- Write escape sequence with tmux DCS passthrough wrapper if inside tmux
local function write_raw_terminal_seq(seq)
    if is_inside_tmux() then
        -- In tmux, graphics escape sequences need to be wrapped in DCS passthrough:
        -- \027Ptmux;\027<escaped_seq_where_esc_is_doubled>\027\\
        local escaped = seq:gsub("\027", "\027\027")
        io.write("\027Ptmux;" .. escaped .. "\027\\")
    else
        io.write(seq)
    end
end

-- Detect if Kitty graphics protocol is supported
local function detect_kitty_support(force_mode)
    if force_mode == "kitty" then return true end
    if force_mode == "halfblock" then return false end

    -- Direct environment variable checks
    local term = os.getenv("TERM") or ""
    local term_prog = os.getenv("TERM_PROGRAM") or ""
    local kitty_pid = os.getenv("KITTY_PID")
    local ghostty_res = os.getenv("GHOSTTY_RESOURCES_DIR")
    local wezterm_pane = os.getenv("WEZTERM_PANE")

    if kitty_pid or ghostty_res or wezterm_pane then
        return true
    end
    if term:lower():find("kitty") or term_prog:lower():find("ghostty") or term_prog:lower():find("wezterm") then
        return true
    end

    -- If inside tmux, query the outer terminal client type
    if is_inside_tmux() then
        local p = io.popen("tmux display-message -p '#{client_termname} #{client_termtype}' 2>/dev/null", "r")
        if p then
            local client_info = p:read("*a") or ""
            p:close()
            local cl = client_info:lower()
            if cl:find("wezterm") or cl:find("kitty") or cl:find("ghostty") then
                return true
            end
        end
    end

    return false
end

-- Clear any Kitty graphics rendered on screen
local function kitty_clear_screen()
    write_raw_terminal_seq("\27_Ga=d,d=a\27\\")
    io.flush()
end

-- Render image using Kitty Graphics Protocol
local function render_image_kitty(img_entry, current_idx, total_count, term_w, term_h)
    local ext = img_entry.extension:lower()
    local png_data = nil
    local raw_rgb_data = nil
    local rgb_w, rgb_h = 0, 0

    if ext == "png" then
        local f = io.open(img_entry.filepath, "rb")
        if f then
            png_data = f:read("*all")
            f:close()
        end
    end

    -- If not direct PNG, first try decoding with in-process FFI decoders for raw RGB transmission
    if not png_data then
        local ffi_img = load_image(img_entry.filepath)
        if ffi_img and ffi_img.pixels then
            raw_rgb_data = ffi.string(ffi_img.pixels, ffi_img.width * ffi_img.height * 3)
            rgb_w = ffi_img.width
            rgb_h = ffi_img.height
        end
    end

    -- Fallback to ImageMagick / ffmpeg conversion if FFI raw decode didn't succeed
    if not png_data and not raw_rgb_data then
        local devnull = is_windows and "nul" or "/dev/null"
        local cmd
        if is_windows then
            cmd = string.format("magick %q png:- 2>%s || ffmpeg -v error -i %q -f image2pipe -vcodec png - 2>%s", img_entry.filepath, devnull, img_entry.filepath, devnull)
        else
            cmd = string.format("magick %q png:- 2>%s || convert %q png:- 2>%s || ffmpeg -v error -i %q -f image2pipe -vcodec png - 2>%s", img_entry.filepath, devnull, img_entry.filepath, devnull, img_entry.filepath, devnull)
        end
        local pipe = io.popen(cmd, "r")
        if pipe then
            png_data = pipe:read("*all")
            pipe:close()
        end
    end

    if (not png_data or #png_data == 0) and not raw_rgb_data then
        return false, "Could not decode or convert image for Kitty protocol"
    end

    local b64
    local is_direct_png = (png_data and #png_data > 0)
    if is_direct_png then
        b64 = base64_encode(png_data)
    else
        b64 = base64_encode(raw_rgb_data)
    end

    local reserved_header_rows = 7
    local max_rows = math.max(6, term_h - reserved_header_rows - 1)
    local max_cols = math.max(10, term_w - 4)

    -- Header
    local bar_len = math.min(term_w - 2, 80)
    io.write("\27[H\27[2J") -- Clear screen & home cursor
    kitty_clear_screen()

    io.write("\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    io.write(string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m \27[1;95m(Kitty Graphics Protocol)\27[0m\n",
        current_idx, total_count, img_entry.filename))
    io.write(string.format("  \27[90mSize: %s | Max display area: %dx%d cells | Path: %s\27[0m\n",
        img_entry.size_str, max_cols, max_rows, img_entry.filepath))
    io.write(string.format("  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;92m[Enter/B]\27[0m Back to File List   \27[91m[Q]\27[0m Quit\n"))
    io.write("\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n\n")

    -- Stream chunks (4096 bytes per chunk as recommended by Kitty spec)
    local chunk_size = 4096
    local total_len = #b64
    local pos = 1

    while pos <= total_len do
        local chunk = b64:sub(pos, pos + chunk_size - 1)
        pos = pos + chunk_size
        local has_more = (pos <= total_len) and 1 or 0

        if pos - chunk_size == 1 then
            if is_direct_png then
                -- PNG transmission (f=100)
                write_raw_terminal_seq(string.format("\27_Gf=100,a=T,c=%d,r=%d,m=%d;%s\27\\", max_cols, max_rows, has_more, chunk))
            else
                -- Raw 24-bit RGB transmission (f=24)
                write_raw_terminal_seq(string.format("\27_Gf=24,s=%d,v=%d,a=T,c=%d,r=%d,m=%d;%s\27\\", rgb_w, rgb_h, max_cols, max_rows, has_more, chunk))
            end
        else
            write_raw_terminal_seq(string.format("\27_Gm=%d;%s\27\\", has_more, chunk))
        end
    end

    io.write("\n")
    io.flush()
    return true
end

-- Render image using ANSI Truecolor Half-Block (▄)
local function render_image_halfblock(img_entry, current_idx, total_count, term_w, term_h)
    local img, err = load_image(img_entry.filepath)
    if not img then
        return false, err
    end

    local out = {}
    table.insert(out, "\27[H\27[2J") -- Clear screen & home cursor

    -- Top header bar
    local bar_len = math.min(term_w - 2, 80)
    table.insert(out, "\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m \27[90m(ANSI Truecolor Half-Block)\27[0m\n",
        current_idx, total_count, img_entry.filename))
    local engine_info = img.engine and (" | Engine: " .. img.engine) or ""
    table.insert(out, string.format("  \27[90mSize: %s | Original: %dx%d pixels%s | Path: %s\27[0m\n",
        img_entry.size_str, img.width, img.height, engine_info, img_entry.filepath))
    table.insert(out, string.format("  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;92m[Enter/B]\27[0m Back to File List   \27[91m[Q]\27[0m Quit\n"))
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n\n")

    -- Calculate render scale to fit remaining terminal height while preserving original aspect ratio.
    -- Note: A terminal character cell is roughly twice as tall as it is wide (approx 1:2 ratio).
    -- Since each character cell row contains 2 vertical pixels ('▄' top & bottom),
    -- one character column horizontally corresponds to 1 character cell vertically (2 half-block pixels).
    local reserved_header_rows = 7
    local max_char_h = math.max(6, term_h - reserved_header_rows)
    local target_w = math.max(10, term_w - 4)
    local target_h = max_char_h * 2 -- 2 vertical pixels per text row

    -- Character cell aspect ratio correction: terminal font height/width ~ 2.0
    -- So in half-block space, 1 column = 1 pixel width, but represents ~2 vertical half-block pixels of optical height.
    -- To keep the physical image aspect ratio (img.width / img.height):
    local optical_aspect = (img.width / img.height) * 2.0 -- scale horizontal columns
    local scale_by_height = target_h / img.height
    local out_h = math.max(2, math.floor(img.height * scale_by_height))
    local out_w = math.max(2, math.floor((out_h / 2) * optical_aspect))

    if out_w > target_w then
        out_w = target_w
        out_h = math.max(2, math.floor((out_w / optical_aspect) * 2))
    end

    if out_h % 2 ~= 0 then out_h = out_h + 1 end

    local margin_left = math.max(0, math.floor((term_w - out_w) / 2))
    local pad = string.rep(" ", margin_left)

    local px = img.pixels
    local iw = img.width

    for y = 0, out_h - 1, 2 do
        local line = { pad }
        for x = 0, out_w - 1 do
            local src_x = math.min(img.width - 1, math.floor(x * (img.width / out_w)))
            local src_y_top = math.min(img.height - 1, math.floor(y * (img.height / out_h)))
            local src_y_bot = math.min(img.height - 1, math.floor((y + 1) * (img.height / out_h)))

            local top = px[src_y_top * iw + src_x]
            local bot = px[src_y_bot * iw + src_x]

            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                top.r, top.g, top.b,
                bot.r, bot.g, bot.b
            ))
        end
        table.insert(line, "\27[0m\n")
        table.insert(out, table.concat(line))
    end

    io.write(table.concat(out))
    io.flush()
    return true
end

-- Render image using iTerm2 Graphics Protocol (widely supported by WezTerm, iTerm2, and tmux)
local function render_image_iterm2(img_entry, current_idx, total_count, term_w, term_h)
    local f = io.open(img_entry.filepath, "rb")
    if not f then return false, "Cannot open image file" end
    local raw_data = f:read("*all")
    f:close()

    local b64 = base64_encode(raw_data)
    local reserved_header_rows = 7
    local max_rows = math.max(6, term_h - reserved_header_rows - 1)
    local max_cols = math.max(10, term_w - 4)

    local bar_len = math.min(term_w - 2, 80)
    io.write("\27[H\27[2J") -- Clear screen & home cursor
    kitty_clear_screen()

    io.write("\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    io.write(string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m \27[1;95m(Pixel Graphics - WezTerm/iTerm2/Kitty)\27[0m\n",
        current_idx, total_count, img_entry.filename))
    io.write(string.format("  \27[90mSize: %s | Max display area: %dx%d cells | Path: %s\27[0m\n",
        img_entry.size_str, max_cols, max_rows, img_entry.filepath))
    io.write(string.format("  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;92m[Enter/B]\27[0m Back to File List   \27[91m[Q]\27[0m Quit\n"))
    io.write("\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n\n")

    -- iTerm2 OSC 1337 escape sequence:
    -- In iTerm2/WezTerm specification: setting height=<rows> and width=auto with preserveAspectRatio=1
    -- fits the image within the screen height while strictly preserving its original aspect ratio!
    local iterm_seq = string.format("\27]1337;File=inline=1;height=%d;width=auto;preserveAspectRatio=1:%s\007\n",
        max_rows, b64)
    write_raw_terminal_seq(iterm_seq)
    io.flush()
    return true
end

-- Unified image renderer: Dispatches to high-res pixel protocol (Kitty or iTerm2) if supported, falls back to Half-Block
-- Unified image renderer: Dispatches to high-res pixel protocol (iTerm2 or Kitty) if supported, falls back to Half-Block
local function render_image_screen(img_entry, current_idx, total_count, force_protocol)
    local term_w, term_h = get_terminal_size()

    if force_protocol == "kitty" then
        local ok, err = render_image_kitty(img_entry, current_idx, total_count, term_w, term_h)
        if ok then return true end
    elseif force_protocol == "iterm" then
        local ok, err = render_image_iterm2(img_entry, current_idx, total_count, term_w, term_h)
        if ok then return true end
    elseif force_protocol ~= "halfblock" then
        local use_pixel = detect_kitty_support(nil)
        if use_pixel then
            -- For WezTerm (especially through tmux), iTerm2 protocol is exceptionally reliable:
            local ok_iterm, _ = render_image_iterm2(img_entry, current_idx, total_count, term_w, term_h)
            if ok_iterm then return true end

            local ok_kitty, _ = render_image_kitty(img_entry, current_idx, total_count, term_w, term_h)
            if ok_kitty then return true end
        end
    end

    return render_image_halfblock(img_entry, current_idx, total_count, term_w, term_h)
end

-- =========================================================================
-- 6. File List Selector Screen
-- =========================================================================
-- =========================================================================
-- 6. File List Selector Screen & Help Popup
-- =========================================================================
local function render_help_modal(term_w, term_h)
    local lines = {
        "┌─────────────────────────────────────────────────────────────┐",
        "│                   KEYBOARD SHORTCUTS                        │",
        "├─────────────────────────────────────────────────────────────┤",
        "│  File & Folder Navigation:                                  │",
        "│    ↑ / k, ↓ / j        Move selection up / down             │",
        "│    PgUp / PgDn         Scroll list one page up / down       │",
        "│    Home / End          Jump to first / last item            │",
        "│    Enter / Space / l   Open folder or view selected image   │",
        "│    h / Backspace       Navigate to parent folder (..)       │",
        "│    1 - 9               Quick select item by index number    │",
        "│                                                             │",
        "│  Viewer Controls:                                           │",
        "│    ← / p, → / n        Browse previous / next image         │",
        "│    PgUp / PgDn         Browse previous / next image         │",
        "│    Enter / b / Backsp  Return to file/folder list           │",
        "│                                                             │",
        "│  Search & Sorting:                                          │",
        "│    /                   Start live search / filter query     │",
        "│    Esc                 Clear active search / exit search    │",
        "│    s                   Cycle sort (Name -> Date -> Size)    │",
        "│    r                   Reverse sort direction (Asc / Desc)  │",
        "│    i                   Cycle icon mode (Unicode / Nerd / Off)│",
        "│                                                             │",
        "│  General:                                                   │",
        "│    ?                   Toggle this help window              │",
        "│    q / Ctrl+C          Quit application cleanly             │",
        "└─────────────────────────────────────────────────────────────┘",
        "                 Press any key to close help                   ",
    }

    local modal_w = 63
    local modal_h = #lines
    local start_row = math.max(1, math.floor((term_h - modal_h) / 2))
    local pad_left = math.max(0, math.floor((term_w - modal_w) / 2))
    local margin = string.rep(" ", pad_left)

    io.write("\27[H\27[2J") -- Clear screen
    io.write(string.rep("\n", start_row))
    for idx, l in ipairs(lines) do
        if idx == 1 or idx == 3 or idx == (#lines - 1) then
            io.write(margin .. "\27[1;36m" .. l .. "\27[0m\n")
        elseif idx == 2 then
            io.write(margin .. "\27[1;97;44m" .. l .. "\27[0m\n")
        elseif idx == #lines then
            io.write(margin .. "\27[1;93m" .. l .. "\27[0m\n")
        else
            io.write(margin .. "\27[37m" .. l .. "\27[0m\n")
        end
    end
    io.flush()
end

local function render_file_list(dir_path, images, total_unfiltered, selected_idx, page_offset, msg, search_mode, search_query, sort_mode, sort_desc, recursive, icon_mode)
    local term_w, term_h = get_terminal_size()
    local out = {}
    table.insert(out, "\27[H\27[2J") -- Clear screen & home

    local bar_len = math.min(term_w - 2, 90)
    table.insert(out, "\27[1;34m" .. string.rep("═", bar_len) .. "\27[0m\n")
    
    local sort_label = sort_mode:upper() .. (sort_desc and " (Desc)" or " (Asc)")
    local title_left = "  \27[1;37mTERMINAL DIRECTORY IMAGE VIEWER\27[0m \27[90m(LuaJIT FFI)\27[0m"
    local title_right = string.format("\27[90mSort: \27[1;93m%s\27[90m [s/r]\27[0m", sort_label)
    table.insert(out, string.format("%s   %s\n", title_left, title_right))

    local scan_type = recursive and "Recursive" or "Level 1"
    table.insert(out, string.format("  \27[90mDir:\27[0m \27[1;33m%s\27[0m \27[90m(%d total, %s)\27[0m\n", dir_path, total_unfiltered, scan_type))

    if search_mode then
        table.insert(out, string.format("  \27[1;97;44m SEARCH: \27[0m \27[1;93m%s_\27[0m \27[90m(Type to filter, Enter to select, Esc to cancel)\27[0m\n", search_query))
    elseif #search_query > 0 then
        table.insert(out, string.format("  \27[90mFilter: \27[1;93m'%s'\27[0m \27[90m(%d matches) [Esc/ / to clear]\27[0m   \27[93m[?]\27[0m Help   \27[91m[Q]\27[0m Quit\n", search_query, #images))
    else
        table.insert(out, string.format("  \27[93m[↑/↓/k/j]\27[0m Move   \27[1;92m[Enter/l]\27[0m Open/View   \27[93m[h/Backsp]\27[0m Up   \27[93m[/]\27[0m Filter   \27[93m[i]\27[0m Icon   \27[93m[?]\27[0m Help   \27[91m[Q]\27[0m Quit\n"))
    end
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    if msg and #msg > 0 then
        table.insert(out, string.format("  \27[1;93mℹ %s\27[0m\n\n", msg))
    else
        table.insert(out, "\n")
    end

    if #images == 0 then
        if #search_query > 0 then
            table.insert(out, string.format("  \27[1;33mNo image files match query '%s'\27[0m\n", search_query))
            table.insert(out, "  Press [Esc] to clear search filter.\n\n")
        else
            table.insert(out, string.format("  \27[1;31mNo supported images found in %s\27[0m\n", dir_path))
            table.insert(out, "  Supported formats: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP\n\n")
        end
        io.write(table.concat(out))
        io.flush()
        return
    end

    -- Pagination
    local header_rows = 9
    local max_items_per_page = math.max(4, term_h - header_rows - 3)
    local page_start = page_offset or 1
    local page_end = math.min(#images, page_start + max_items_per_page - 1)

    -- Dynamic Columns
    local col1_w = 6   -- Index
    local col3_w = 8   -- Format
    local col4_w = 12  -- Size
    local col5_w = 12  -- Date
    local col2_w = math.max(20, term_w - (col1_w + col3_w + col4_w + col5_w + 10))

    table.insert(out, string.format("  \27[1;37m%-6s %-" .. col2_w .. "s %-8s %-12s %-12s\27[0m\n",
        "INDEX", "FILENAME", "FORMAT", "SIZE", "DATE"))
    table.insert(out, "  \27[90m" .. string.rep("─", math.min(bar_len - 2, col1_w + col2_w + col3_w + col4_w + col5_w + 4)) .. "\27[0m\n")

    for i = page_start, page_end do
        local img = images[i]
        local is_sel = (i == selected_idx)
        local icon = get_file_icon(img.extension, icon_mode)
        local icon_prefix = (icon ~= "") and (icon .. " ") or ""
        local max_fn_w = (icon ~= "") and (col2_w - 3) or col2_w
        local fn = img.filename
        if #fn > max_fn_w then
            fn = fn:sub(1, max_fn_w - 3) .. "..."
        end

        local display_fn = icon_prefix .. fn
        local pad_len = math.max(0, col2_w - (fn:len() + ((icon ~= "") and 3 or 0)))
        local padded_col2 = display_fn .. string.rep(" ", pad_len)

        local line_str = string.format("%-6s %s %-8s %-12s %-12s",
            string.format("[%d]", i),
            padded_col2,
            img.extension,
            img.size_str,
            img.date_str or "-"
        )

        if is_sel then
            table.insert(out, string.format("\27[1;93m▶ \27[1;97;44m%s\27[0m\n", line_str))
        else
            table.insert(out, string.format("  \27[37m%s\27[0m\n", line_str))
        end
    end

    table.insert(out, "\n")
    if #images > max_items_per_page then
        table.insert(out, string.format("  \27[90mShowing %d-%d of %d matches. Use ↑ / ↓ or PgUp / PgDn to scroll.\27[0m\n",
            page_start, page_end, #images))
    end

    io.write(table.concat(out))
    io.flush()
end

-- =========================================================================
-- 7. Main Interactive Loop & CLI Controller
-- =========================================================================
local function sort_images(images, mode, desc)
    table.sort(images, function(a, b)
        -- '..' parent entry is always at the very top
        if a.is_parent then return true end
        if b.is_parent then return false end

        -- Directories come before regular files
        if a.is_dir ~= b.is_dir then
            return a.is_dir == true
        end

        local val_a, val_b
        if mode == "date" then
            val_a, val_b = a.mtime or 0, b.mtime or 0
        elseif mode == "size" then
            val_a, val_b = a.size or 0, b.size or 0
        else -- name
            val_a, val_b = a.filename:lower(), b.filename:lower()
        end

        if desc then
            return val_a > val_b
        else
            return val_a < val_b
        end
    end)
end

local function filter_images(all_images, query)
    if not query or #query == 0 then
        local copy = {}
        for _, img in ipairs(all_images) do table.insert(copy, img) end
        return copy
    end
    local q = query:lower()
    local res = {}
    for _, img in ipairs(all_images) do
        if img.filename:lower():find(q, 1, true) or img.filepath:lower():find(q, 1, true) then
            table.insert(res, img)
        end
    end
    return res
end

local function main()
    local args = {}
    local positional = {}
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--select" or a == "-s" then
            i = i + 1
            args["--select"] = arg[i]
        elseif a == "--sort" then
            i = i + 1
            args["--sort"] = arg[i]
        elseif a:sub(1, 2) == "--" or a:sub(1, 1) == "-" then
            args[a] = true
        else
            table.insert(positional, a)
        end
        i = i + 1
    end

    if args["-h"] or args["--help"] then
        print("\27[1;36mTerminal Directory Image Viewer (LuaJIT FFI)\27[0m")
        print("Usage:")
        print("  ./LuaJIT/src/luajit view_gallery_terminal.lua [directory] [options]")
        print("\nOptions:")
        print("  [directory]           Directory to scan (default: current directory '.')")
        print("  -r, --recursive       Recursively scan subdirectories for images")
        print("  --select, -s <id>     Directly select and display image #id")
        print("  --sort <name|date|size> Initial sort order (default: name)")
        print("  --nerd-icons          Use Nerd Font glyphs instead of standard Unicode")
        print("  --no-icons            Disable file icons")
        print("  --kitty               Force Kitty Graphics Protocol (high-res pixel rendering)")
        print("  --iterm               Force iTerm2 / WezTerm inline image protocol")
        print("  --half-block          Force ANSI Truecolor Half-Block fallback renderer")
        print("  --no-interactive      Non-interactive script/batch mode")
        print("  -h, --help            Show this help information")
        print("\nSupported formats:")
        print("  - PNG, JPG/JPEG, PPM, WEBP, GIF, BMP")
        os.exit(0)
    end

    -- Force mode flag: --kitty, --iterm, or --half-block
    local force_protocol = nil
    if args["--kitty"] then
        force_protocol = "kitty"
    elseif args["--iterm"] or args["--iterm2"] then
        force_protocol = "iterm"
    elseif args["--half-block"] or args["--halfblock"] then
        force_protocol = "halfblock"
    end

    -- Icon mode
    local icon_mode = "unicode"
    if args["--no-icons"] or args["--no-icon"] then
        icon_mode = "none"
    elseif args["--nerd-icons"] or args["--nerd-icon"] or args["--nerd"] then
        icon_mode = "nerd"
    end

    local recursive = args["-r"] or args["--recursive"]
    local target_dir = positional[1] or "."
    local cli_select = tonumber(args["--select"])
    local non_interactive = args["--no-interactive"] or (not is_stdin_tty())

    -- Initial sort mode
    local sort_mode = "name"
    if args["--sort"] and (args["--sort"] == "date" or args["--sort"] == "size" or args["--sort"] == "name") then
        sort_mode = args["--sort"]
    end
    local sort_desc = (sort_mode == "date" or sort_mode == "size")

    -- 2. Scan Directory for Images & Folders (or support direct single image file)
    local raw_images = nil
    local direct_file = io.open(target_dir, "rb")
    if direct_file then
        local file_len = direct_file:seek("end") or 0
        direct_file:close()
        local fname = target_dir:match("([^/\\]+)$") or target_dir
        local ext = fname:match("%.([^.]+)$")
        if ext and SUPPORTED_EXTENSIONS[ext:lower()] then
            local is_a_dir = false
            if not is_windows and posix_stat then
                local st = ffi.new("struct stat")
                if posix_stat(target_dir, st) == 0 then
                    is_a_dir = (bit.band(tonumber(st.st_mode), 0xF000) == 0x4000)
                end
            end
            if not is_a_dir then
                raw_images = {
                    {
                        filename = fname,
                        filepath = target_dir,
                        is_dir = false,
                        extension = ext:upper(),
                        size = file_len,
                        size_str = format_file_size(file_len),
                        mtime = 0,
                        date_str = "-",
                    }
                }
                cli_select = cli_select or 1
            end
        end
    end

    if not raw_images then
        local err
        raw_images, err = scan_directory_images(target_dir, recursive)
        if not raw_images then
            io.stderr:write(string.format("\27[1;31mError: %s\27[0m\n", tostring(err)))
            os.exit(1)
        end
    end

    if #raw_images == 0 and non_interactive then
        print(string.format("\27[1;33m[!] No files or directories found in '%s'.\27[0m", target_dir))
        os.exit(0)
    end

    sort_images(raw_images, sort_mode, sort_desc)

    -- Extract images list excluding directories for direct selection and validation
    local only_images = {}
    for _, item in ipairs(raw_images) do
        if not item.is_dir then
            table.insert(only_images, item)
        end
    end

    -- 3. If direct CLI selection is specified
    if cli_select then
        if #only_images > 0 and cli_select >= 1 and cli_select <= #only_images then
            render_image_screen(only_images[cli_select], cli_select, #only_images, force_protocol)
            return
        elseif cli_select >= 1 and cli_select <= #raw_images then
            render_image_screen(raw_images[cli_select], cli_select, #raw_images, force_protocol)
            return
        end
    end

    -- If no image files found at all, print message and exit cleanly
    if #only_images == 0 then
        render_file_list(target_dir, {}, 0, 1, 1, nil, false, "", sort_mode, sort_desc, recursive, icon_mode)
        os.exit(0)
    end

    -- 4. Non-interactive fallback (e.g., pipes or redirect)
    if non_interactive then
        while true do
            render_file_list(target_dir, raw_images, #raw_images, 1, 1, nil, false, "", sort_mode, sort_desc, recursive, icon_mode)
            io.write(string.format("\n\27[1;32mEnter item number [1-%d] to open/view, or 'q' to quit: \27[0m", #raw_images))
            io.flush()
            local line = io.read("*l")
            if not line or line == "q" or line == "Q" then
                break
            end
            local sel = tonumber(line:match("%d+"))
            if sel and sel >= 1 and sel <= #raw_images then
                local item = raw_images[sel]
                if item.is_dir then
                    target_dir = item.filepath
                    raw_images = scan_directory_images(target_dir, recursive) or {}
                    sort_images(raw_images, sort_mode, sort_desc)
                else
                    render_image_screen(item, sel, #raw_images, force_protocol)
                    break
                end
            end
        end
        return
    end

    -- 5. Interactive Mode with Alternate Screen Buffer & pcall Safety
    enable_raw_mode()

    local search_mode = false
    local search_query = ""
    local filtered_images = filter_images(raw_images, search_query)
    local selected_idx = 1
    local page_offset = 1
    local in_viewer = false
    local in_help = false
    local current_msg = nil

    local function reload_directory(new_dir)
        target_dir = new_dir or target_dir
        -- Normalize path
        target_dir = target_dir:gsub("/%./", "/"):gsub("/+$", "")
        if target_dir == "" then target_dir = "/" end

        local new_items, scan_err = scan_directory_images(target_dir, recursive)
        if not new_items then
            current_msg = "Cannot open directory: " .. tostring(scan_err)
            return false
        end

        raw_images = new_items
        sort_images(raw_images, sort_mode, sort_desc)
        search_query = ""
        search_mode = false
        filtered_images = filter_images(raw_images, search_query)
        selected_idx = 1
        page_offset = 1
        return true
    end

    local function navigate_to_parent()
        local parent_path
        if target_dir == "." or target_dir == "" then
            parent_path = ".."
        elseif target_dir == ".." or target_dir:match("^%.%.[/\\]") then
            parent_path = target_dir .. "/.."
        elseif target_dir == "/" then
            return -- already root
        else
            parent_path = target_dir:match("^(.*)[/\\][^/\\]+$") or "."
            if parent_path == "" then parent_path = "/" end
        end
        reload_directory(parent_path)
    end

    local function update_page_window()
        local _, term_h = get_terminal_size()
        local max_items = math.max(4, term_h - 12)
        if selected_idx < page_offset then
            page_offset = selected_idx
        elseif selected_idx > page_offset + max_items - 1 then
            page_offset = math.max(1, selected_idx - max_items + 1)
        end
    end

    -- Build a list of indices that correspond to actual image files (excluding directories)
    local function get_image_indices()
        local indices = {}
        for idx, item in ipairs(filtered_images) do
            if not item.is_dir then
                table.insert(indices, idx)
            end
        end
        return indices
    end

    local loop_status, loop_err = pcall(function()
        while true do
            if in_help then
                local term_w, term_h = get_terminal_size()
                render_help_modal(term_w, term_h)
                local k = read_key()
                if k then
                    in_help = false
                end
            elseif in_viewer then
                local cur_img = filtered_images[selected_idx]
                if not cur_img or cur_img.is_dir then
                    in_viewer = false
                else
                    local img_indices = get_image_indices()
                    local img_pos = 1
                    for p, idx in ipairs(img_indices) do
                        if idx == selected_idx then
                            img_pos = p
                            break
                        end
                    end

                    local ok, view_err = render_image_screen(cur_img, img_pos, #img_indices, force_protocol)
                    if not ok then
                        in_viewer = false
                        current_msg = "Failed to load image: " .. tostring(view_err)
                    else
                        local k = read_key()
                        if k == "q" or k == "ESC" or k == "CTRL_C" then
                            break
                        elseif k == "ENTER" or k == "b" or k == "BACKSPACE" or k == "h" then
                            kitty_clear_screen()
                            in_viewer = false
                        elseif k == "RIGHT" or k == "n" or k == "SPACE" or k == "PAGE_DOWN" or k == "l" then
                            kitty_clear_screen()
                            if #img_indices > 1 then
                                img_pos = (img_pos % #img_indices) + 1
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        elseif k == "LEFT" or k == "p" or k == "PAGE_UP" then
                            kitty_clear_screen()
                            if #img_indices > 1 then
                                img_pos = (img_pos - 2 + #img_indices) % #img_indices + 1
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        elseif k == "?" then
                            in_help = true
                        end
                    end
                end
            else
                update_page_window()
                render_file_list(target_dir, filtered_images, #raw_images, selected_idx, page_offset, current_msg, search_mode, search_query, sort_mode, sort_desc, recursive, icon_mode)
                current_msg = nil

                local k = read_key()
                local _, term_h = get_terminal_size()
                local page_step = math.max(4, term_h - 12)

                if search_mode then
                    if k == "ESC" or k == "CTRL_C" then
                        search_mode = false
                        search_query = ""
                        filtered_images = filter_images(raw_images, search_query)
                        selected_idx = 1
                        page_offset = 1
                    elseif k == "ENTER" then
                        search_mode = false
                        local item = filtered_images[selected_idx]
                        if item then
                            if item.is_dir then
                                reload_directory(item.filepath)
                            else
                                in_viewer = true
                            end
                        end
                    elseif k == "BACKSPACE" then
                        if #search_query > 0 then
                            search_query = search_query:sub(1, -2)
                            filtered_images = filter_images(raw_images, search_query)
                            selected_idx = 1
                            page_offset = 1
                        else
                            search_mode = false
                        end
                    elseif k == "UP" then
                        if selected_idx > 1 then selected_idx = selected_idx - 1 end
                    elseif k == "DOWN" then
                        if selected_idx < #filtered_images then selected_idx = selected_idx + 1 end
                    elseif k and #k == 1 and k:byte() >= 32 and k:byte() <= 126 then
                        search_query = search_query .. k
                        filtered_images = filter_images(raw_images, search_query)
                        selected_idx = 1
                        page_offset = 1
                    end
                else
                    if not k or k == "q" or k == "CTRL_C" then
                        break
                    elseif k == "ESC" then
                        if #search_query > 0 then
                            search_query = ""
                            filtered_images = filter_images(raw_images, search_query)
                            selected_idx = 1
                            page_offset = 1
                        else
                            break
                        end
                    elseif k == "/" then
                        search_mode = true
                    elseif k == "?" then
                        in_help = true
                    elseif k == "i" then
                        if icon_mode == "unicode" then
                            icon_mode = "nerd"
                            current_msg = "Icons: Nerd Font"
                        elseif icon_mode == "nerd" then
                            icon_mode = "none"
                            current_msg = "Icons: Disabled"
                        else
                            icon_mode = "unicode"
                            current_msg = "Icons: Standard Unicode"
                        end
                    elseif k == "s" then
                        if sort_mode == "name" then
                            sort_mode = "date"
                            sort_desc = true
                        elseif sort_mode == "date" then
                            sort_mode = "size"
                            sort_desc = true
                        else
                            sort_mode = "name"
                            sort_desc = false
                        end
                        sort_images(raw_images, sort_mode, sort_desc)
                        filtered_images = filter_images(raw_images, search_query)
                        selected_idx = 1
                        page_offset = 1
                    elseif k == "r" then
                        sort_desc = not sort_desc
                        sort_images(raw_images, sort_mode, sort_desc)
                        filtered_images = filter_images(raw_images, search_query)
                    elseif k == "UP" or k == "k" then
                        if selected_idx > 1 then selected_idx = selected_idx - 1 end
                    elseif k == "DOWN" or k == "j" then
                        if selected_idx < #filtered_images then selected_idx = selected_idx + 1 end
                    elseif k == "PAGE_DOWN" then
                        selected_idx = math.min(#filtered_images, selected_idx + page_step)
                    elseif k == "PAGE_UP" then
                        selected_idx = math.max(1, selected_idx - page_step)
                    elseif k == "HOME" then
                        selected_idx = 1
                    elseif k == "END" then
                        selected_idx = math.max(1, #filtered_images)
                    elseif k == "BACKSPACE" or k == "h" or k == "LEFT" then
                        navigate_to_parent()
                    elseif k == "ENTER" or k == "SPACE" or k == "l" or k == "RIGHT" then
                        local item = filtered_images[selected_idx]
                        if item then
                            if item.is_dir then
                                reload_directory(item.filepath)
                            else
                                in_viewer = true
                            end
                        end
                    elseif tonumber(k) and tonumber(k) >= 1 and tonumber(k) <= math.min(9, #filtered_images) then
                        local item = filtered_images[tonumber(k)]
                        if item then
                            selected_idx = tonumber(k)
                            if item.is_dir then
                                reload_directory(item.filepath)
                            else
                                in_viewer = true
                            end
                        end
                    end
                end
            end
        end
    end)

    kitty_clear_screen()
    disable_raw_mode()

    if not loop_status and loop_err then
        io.stderr:write(string.format("\n\27[1;31mViewer interrupted with error: %s\27[0m\n", tostring(loop_err)))
    end
end

main()
