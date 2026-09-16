--[[
    pix.lua
    Professional Interactive Terminal Directory Image Viewer written in LuaJIT FFI.

    Features:
    1. Directory Scanning:
       - Scans current working directory ('.') by default, or an input directory provided via argument / prompt.
       - Level 1 scanning default, or recursive scanning via -r / --recursive.
       - Supports standard image formats: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP.
    2. Interactive File Selector & TUI:
       - Hidden (dot) entries are skipped by default; [.] toggles them, or start with --hidden / -a.
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
       - In view mode: allows browsing previous/next images with ← / → / [P] / [N] or returning to menu with [Enter] / [B] / [q] / [Esc].
       - [Q] (or [Ctrl+C]) quits pix; [q] backs out of a viewer to the file list, keeping the selection.
    4. Video Playback Engines:
       - Cycle play engines with [m] inside the video player: LuaJIT FFI (libavcodec) -> FFmpeg CLI -> mpv.
       - FFI and FFmpeg CLI decode in-process inside the TUI (seek, speed, loop, frame step, playlist).
       - mpv (--vo=tct) is a hand-off engine with real audio; playback resumes in the TUI when it exits.
       - mpv dependency stderr (libvdpau/VA-API/mesa) is captured to a log and shown only on failure.
       - Default engine is the first available inline engine; override with --play-engine <auto|ffi|ffmpeg|mpv>.
]]

local ffi = require("ffi")
local posix_stat

-- =========================================================================
-- 1. C Declarations for Windows / POSIX, Terminal Window, Input, & Directory
-- =========================================================================
local is_windows = (ffi.os == "Windows")

-- POSIX popen() only accepts exactly "r" or "w" (glibc >= 2.34 rejects "rb" with EINVAL),
-- while Windows _popen needs the binary flag to avoid text-mode translation.
local POPEN_READ_BIN = is_windows and "rb" or "r"

ffi.cdef[[
    typedef struct { uint8_t r, g, b; } PixelRGB;
]]

local get_terminal_size
local enable_raw_mode
local disable_raw_mode
local read_key
local sleep_ms
local to_display_text
local is_stdin_tty
local scan_directory_images
local get_file_mtime

local SUPPORTED_EXTENSIONS = {
    png  = true,
    jpg  = true,
    jpeg = true,
    ppm  = true,
    webp = true,
    gif  = true,
    bmp  = true,
    mp4  = true,
    mkv  = true,
    webm = true,
    avi  = true,
    mov  = true,
    m4v  = true,
    flv  = true,
}

local VIDEO_EXTENSIONS = {
    mp4  = true,
    mkv  = true,
    webm = true,
    avi  = true,
    mov  = true,
    m4v  = true,
    flv  = true,
}

local function is_video_file(filepath_or_ext)
    if not filepath_or_ext then return false end
    local ext = filepath_or_ext:match("%.([^.]+)$") or filepath_or_ext
    return VIDEO_EXTENSIONS[ext:lower()] == true
end

local EXTENSION_ICONS = {
    unicode = {
        DIR  = "📁",
        PNG  = "🖼",
        JPG  = "📷",
        JPEG = "📷",
        PPM  = "▦ ",
        WEBP = "🌐",
        GIF  = "🎞",
        BMP  = "🎨",
        MP4  = "🎬",
        MKV  = "🎬",
        WEBM = "🎬",
        AVI  = "🎬",
        MOV  = "🎬",
        M4V  = "🎬",
        FLV  = "🎬",
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
        MP4  = "\238\180\157 ", -- 󰕼
        MKV  = "\238\180\157 ",
        WEBM = "\238\180\157 ",
        AVI  = "\238\180\157 ",
        MOV  = "\238\180\157 ",
        M4V  = "\238\180\157 ",
        FLV  = "\238\180\157 ",
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

-- -------------------------------------------------------------------------
-- Text helpers: what the OS gives us vs what the terminal expects
-- -------------------------------------------------------------------------
-- Windows hands pix ANSI filenames (CP_ACP, e.g. GBK/CP936 on a Chinese install) from the
-- FindFirstFileA/argv side, while the console output code page is switched to UTF-8 below.
-- to_display_text bridges that gap; it is assigned per platform and is the identity on POSIX
-- and on Windows installations that already run the UTF-8 code page.

-- Display width of one code point: wide glyphs (CJK, Hangul, fullwidth forms, emoji) fill two
-- terminal cells. Everything else counts as one.
local function codepoint_width(cp)
    if cp < 0x1100 then return 1 end
    if (cp >= 0x1100 and cp <= 0x115F)     -- Hangul Jamo
        or (cp >= 0x2E80 and cp <= 0x303E) -- CJK radicals, Kangxi, CJK symbols
        or (cp >= 0x3041 and cp <= 0x33FF) -- kana, CJK compatibility
        or (cp >= 0x3400 and cp <= 0x4DBF) -- CJK extension A
        or (cp >= 0x4E00 and cp <= 0x9FFF) -- CJK unified ideographs
        or (cp >= 0xA000 and cp <= 0xA4CF) -- Yi
        or (cp >= 0xAC00 and cp <= 0xD7A3) -- Hangul syllables
        or (cp >= 0xF900 and cp <= 0xFAFF) -- CJK compatibility ideographs
        or (cp >= 0xFE30 and cp <= 0xFE6F) -- CJK compatibility forms / small forms
        or (cp >= 0xFF00 and cp <= 0xFF60) -- fullwidth forms
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
        or (cp >= 0x1F300 and cp <= 0x1FAFF) -- emoji
        or (cp >= 0x20000 and cp <= 0x3FFFD) then -- CJK extensions B+
        return 2
    end
    return 1
end

-- Decode one UTF-8 sequence at byte offset i: returns code point and its byte length.
-- A stray continuation or malformed byte is reported as one single-cell character.
local function utf8_next(s, i)
    local b = s:byte(i)
    if not b then return nil end
    if b < 0x80 then return b, 1 end
    if b >= 0xF0 then
        local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
        if b2 and b3 and b4 and b2 >= 0x80 and b2 < 0xC0 and b3 >= 0x80 and b3 < 0xC0 and b4 >= 0x80 and b4 < 0xC0 then
            return (b - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80), 4
        end
    elseif b >= 0xE0 then
        local b2, b3 = s:byte(i + 1), s:byte(i + 2)
        if b2 and b3 and b2 >= 0x80 and b2 < 0xC0 and b3 >= 0x80 and b3 < 0xC0 then
            return (b - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), 3
        end
    elseif b >= 0xC0 then
        local b2 = s:byte(i + 1)
        if b2 and b2 >= 0x80 and b2 < 0xC0 then
            return (b - 0xC0) * 0x40 + (b2 - 0x80), 2
        end
    end
    return b, 1
end

-- Columns a string occupies on screen (byte length is wrong for any non-ASCII name)
local function display_width(s)
    local w, i = 0, 1
    while i <= #s do
        local cp, len = utf8_next(s, i)
        w = w + codepoint_width(cp)
        i = i + len
    end
    return w
end

-- Keep the first `max_cols` columns, ending in "..." when something had to be dropped.
-- Never splits a multi-byte sequence and never lets a wide glyph straddle the limit.
local function utf8_truncate(s, max_cols)
    if display_width(s) <= max_cols then return s end
    local budget = math.max(0, max_cols - 3)
    local w, i, cut = 0, 1, 0
    while i <= #s do
        local cp, len = utf8_next(s, i)
        local cw = codepoint_width(cp)
        if w + cw > budget then break end
        w = w + cw
        i = i + len
        cut = i - 1
    end
    return s:sub(1, cut) .. "..."
end

-- Keep the last `max_cols` columns, prefixed with "..." (used for long file paths)
local function utf8_tail(s, max_cols)
    if display_width(s) <= max_cols then return s end
    local budget = math.max(0, max_cols - 3)
    local starts = {}
    local i = 1
    while i <= #s do
        local cp, len = utf8_next(s, i)
        starts[#starts + 1] = { i, codepoint_width(cp) }
        i = i + len
    end
    local w, from = 0, 1
    for k = #starts, 1, -1 do
        local cw = starts[k][2]
        if w + cw > budget then break end
        w = w + cw
        from = starts[k][1]
    end
    return "..." .. s:sub(from)
end

if is_windows then
    local kernel32 = ffi.load("kernel32")

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
        uint32_t __stdcall GetACP(void);
        int      __stdcall MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int      __stdcall WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
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
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        kernel32.SetConsoleOutputCP(65001) -- UTF-8
        local out_mode = ffi.new("uint32_t[1]")
        if kernel32.GetConsoleMode(hOut, out_mode) ~= 0 then
            local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            kernel32.SetConsoleMode(hOut, bit.bor(out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        end
    end)

    is_stdin_tty = function()
        local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        return kernel32.GetConsoleMode(hIn, mode) ~= 0
    end

    -- Platform sleep (video player frame pacing); kernel32 stays inside this block
    sleep_ms = function(ms)
        kernel32.Sleep(ms)
    end

    -- OS text -> terminal text. Names reach us as ANSI bytes (FindFirstFileA, the CRT argv) while
    -- the console above is set to codepage 65001, so they must be transcoded before display.
    if kernel32.GetACP() == 65001 then
        to_display_text = function(s) return s end
    else
        to_display_text = function(s)
            if type(s) ~= "string" or #s == 0 then return s end
            local wlen = kernel32.MultiByteToWideChar(0, 0, s, #s, nil, 0) -- CP_ACP
            if wlen <= 0 then return s end
            local wbuf = ffi.new("wchar_t[?]", wlen + 1)
            kernel32.MultiByteToWideChar(0, 0, s, #s, wbuf, wlen)
            local ulen = kernel32.WideCharToMultiByte(65001, 0, wbuf, wlen, nil, 0, nil, nil)
            if ulen <= 0 then return s end
            local ubuf = ffi.new("char[?]", ulen + 1)
            kernel32.WideCharToMultiByte(65001, 0, wbuf, wlen, ubuf, ulen, nil, nil)
            return ffi.string(ubuf, ulen)
        end
    end

    get_terminal_size = function()
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if kernel32.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
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
        local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
        if kernel32.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end

        local ENABLE_LINE_INPUT = 0x0002
        local ENABLE_ECHO_INPUT = 0x0004
        local new_mode = bit.band(orig_in_mode[0], bit.bnot(bit.bor(ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT)))
        kernel32.SetConsoleMode(hIn, new_mode)
        raw_mode_enabled = true

        io.write("\27[?1049h\27[?25l") -- Alternate screen buffer + Hide cursor
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?1049l\27[?25h\27[0m") -- Restore main screen + show cursor
            io.flush()
            local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
            kernel32.SetConsoleMode(hIn, orig_in_mode[0])
            raw_mode_enabled = false
        end
    end

    local function parse_win_key()
        local ch = ffi.C._getch()
        if ch == 0 or ch == 224 then
            local code = ffi.C._getch()
            if code == 72 then return "UP"
            elseif code == 80 then return "DOWN"
            elseif code == 75 then return "LEFT"
            elseif code == 77 then return "RIGHT"
            elseif code == 73 then return "PAGE_UP"
            elseif code == 81 then return "PAGE_DOWN"
            elseif code == 71 then return "HOME"
            elseif code == 79 then return "END"
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
        elseif ch == 4 then
            return "CTRL_D"
        elseif ch == 21 then
            return "CTRL_U"
        elseif ch == 6 then
            return "CTRL_F"
        elseif ch == 2 then
            return "CTRL_B"
        elseif ch == 5 then
            return "CTRL_E"
        elseif ch == 25 then
            return "CTRL_Y"
        else
            if ch >= 192 and ch < 248 then
                local expected = (ch >= 240 and 4) or (ch >= 224 and 3) or 2
                local bytes = { string.char(ch) }
                for _ = 2, expected do
                    if ffi.C._kbhit() ~= 0 then
                        table.insert(bytes, string.char(ffi.C._getch()))
                    else
                        break
                    end
                end
                return table.concat(bytes)
            elseif ch >= 32 then
                return string.char(ch)
            end
        end
        return nil
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or -1
        if timeout_ms == 0 then
            if ffi.C._kbhit() ~= 0 then
                return parse_win_key()
            end
            return nil
        end

        local elapsed = 0
        while timeout_ms < 0 or elapsed <= timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                return parse_win_key()
            end
            if timeout_ms >= 0 then
                local sleep_chunk = math.min(10, math.max(1, timeout_ms - elapsed))
                kernel32.Sleep(sleep_chunk)
                elapsed = elapsed + sleep_chunk
            else
                kernel32.Sleep(10)
            end
        end
        return nil
    end

    local function scan_win_dir(dir_path, entries, recursive, show_hidden)
        local norm_dir = dir_path:gsub("/", "\\"):gsub("\\+$", "")
        if norm_dir == "" then norm_dir = "." end
        local search_pattern = (norm_dir == ".") and ".\\*" or (norm_dir .. "\\*")
        local find_data = ffi.new("WIN32_FIND_DATAA")
        local hFind = kernel32.FindFirstFileA(search_pattern, find_data)

        if hFind == INVALID_HANDLE_VALUE or hFind == nil or hFind == ffi.cast("void*", 0) then
            return
        end

        repeat
            local fname = ffi.string(find_data.cFileName)
            local is_dir = bit.band(find_data.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0

            if fname ~= "." and fname ~= ".." and (show_hidden or not fname:match("^%.")) then
                local full_path = (norm_dir == ".") and fname or (norm_dir .. "\\" .. fname)
                local ft = tonumber(find_data.ftLastWriteTime.dwHighDateTime) * 4294967296 + tonumber(find_data.ftLastWriteTime.dwLowDateTime)
                local mtime = math.floor((ft - 116444736000000000) / 10000000)

                if is_dir then
                    if recursive then
                        scan_win_dir(full_path, entries, true, show_hidden)
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
        until kernel32.FindNextFileA(hFind, find_data) == 0

        kernel32.FindClose(hFind)
    end

    get_file_mtime = function(filepath)
        local norm = filepath:gsub("/", "\\")
        local find_data = ffi.new("WIN32_FIND_DATAA")
        local hFind = kernel32.FindFirstFileA(norm, find_data)
        if hFind ~= INVALID_HANDLE_VALUE and hFind ~= nil and hFind ~= ffi.cast("void*", 0) then
            local ft = tonumber(find_data.ftLastWriteTime.dwHighDateTime) * 4294967296 + tonumber(find_data.ftLastWriteTime.dwLowDateTime)
            kernel32.FindClose(hFind)
            return math.floor((ft - 116444736000000000) / 10000000)
        end
        return 0
    end

    scan_directory_images = function(dir_path, recursive, show_hidden)
        dir_path = dir_path or "."
        dir_path = dir_path:gsub("[/\\]+$", "")
        if dir_path == "" then dir_path = "." end

        local entries = {}
        if not recursive and dir_path ~= "." and not dir_path:match("^[A-Za-z]:[/\\]?$") and dir_path ~= "/" and dir_path ~= "\\" then
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

        scan_win_dir(dir_path, entries, recursive, show_hidden)

        -- Fallback if FindFirstFileA discovered no entries (e.g. permission or shell path quirk)
        local has_content = false
        for _, e in ipairs(entries) do
            if not e.is_parent then has_content = true; break end
        end

        if not has_content then
            local win_path = dir_path:gsub("/", "\\")
            local cmd = string.format("dir /b /a %q 2>nul", (win_path == ".") and "." or win_path)
            local p = io.popen(cmd, "r")
            if p then
                for line in p:lines() do
                    local fname = line:gsub("[\r\n]+$", "")
                    if fname ~= "" and fname ~= "." and fname ~= ".." and (show_hidden or not fname:match("^%.")) then
                        local full_path = (dir_path == ".") and fname or (dir_path .. "\\" .. fname)
                        local ext = fname:match("%.([^.]+)$")
                        if ext and SUPPORTED_EXTENSIONS[ext:lower()] then
                            local f = io.open(full_path, "rb")
                            local sz = 0
                            if f then
                                sz = f:seek("end") or 0
                                f:close()
                            end
                            table.insert(entries, {
                                filename = fname,
                                filepath = full_path,
                                is_dir = false,
                                extension = ext:upper(),
                                size = sz,
                                size_str = format_file_size(sz),
                                mtime = 0,
                                date_str = "-",
                            })
                        end
                    end
                end
                p:close()
            end
        end

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

    if pcall(function() return ffi.C.stat end) then
        posix_stat = function(path, st)
            return ffi.C.stat(path, st)
        end
    elseif pcall(function() return ffi.C.__xstat end) then
        posix_stat = function(path, st)
            local res = ffi.C.__xstat(3, path, st)
            if res ~= 0 then res = ffi.C.__xstat(1, path, st) end
            return res
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

    -- Platform sleep (video player frame pacing)
    sleep_ms = function(ms)
        ffi.C.poll(nil, 0, ms)
    end

    -- POSIX filenames are already UTF-8 bytes, exactly what the terminal expects
    to_display_text = function(s) return s end

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
                local c0 = bit.band(key_buf[0], 0xFF)
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
                        -- Modifier+Arrow: \e[1;{mod}{dir}  (Shift=2, Ctrl=5)
                        if c2 == 49 and n >= 6 and key_buf[3] == 59 then
                            local mod = key_buf[4]
                            local dir = key_buf[5]
                            if mod == 50 then -- Shift
                                if dir == 65 then return "SHIFT_UP" end
                                if dir == 66 then return "SHIFT_DOWN" end
                                if dir == 67 then return "SHIFT_RIGHT" end
                                if dir == 68 then return "SHIFT_LEFT" end
                            elseif mod == 53 then -- Ctrl
                                if dir == 65 then return "CTRL_UP" end
                                if dir == 66 then return "CTRL_DOWN" end
                                if dir == 67 then return "CTRL_RIGHT" end
                                if dir == 68 then return "CTRL_LEFT" end
                            end
                        end
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
                elseif c0 == 4 then
                    return "CTRL_D"
                elseif c0 == 21 then
                    return "CTRL_U"
                elseif c0 == 6 then
                    return "CTRL_F"
                elseif c0 == 2 then
                    return "CTRL_B"
                elseif c0 == 5 then
                    return "CTRL_E"
                elseif c0 == 25 then
                    return "CTRL_Y"
                else
                    if c0 >= 192 and c0 < 248 then
                        local expected = (c0 >= 240 and 4) or (c0 >= 224 and 3) or 2
                        while n < expected do
                            local r = ffi.C.poll(pfd, 1, 15)
                            if r > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
                                local rn = ffi.C.read(STDIN_FILENO, key_buf + n, expected - n)
                                if rn > 0 then n = n + rn else break end
                            else
                                break
                            end
                        end
                        return ffi.string(key_buf, math.min(n, expected))
                    elseif c0 >= 32 then
                        return string.char(c0)
                    end
                end
            end
        end
        return nil
    end

    local function scan_posix_dir(dir_path, entries, recursive, show_hidden)
        local d = ffi.C.opendir(dir_path)
        if d == nil then return end

        local st = ffi.new("struct stat")
        while true do
            local ent = ffi.C.readdir(d)
            if ent == nil then break end
            local fname = ffi.string(ent.d_name)

            if fname ~= "." and fname ~= ".." and (show_hidden or not fname:match("^%.")) then
                local full_path = (dir_path == ".") and fname or (dir_path .. "/" .. fname)
                local d_type = ent.d_type
                local is_dir = (d_type == 4)
                local is_reg = (d_type == 8)
                local size = 0
                local mtime = 0

                if posix_stat(full_path, st) == 0 then
                    local mode = tonumber(st.st_mode)
                    if bit.band(mode, 0xF000) == 0x4000 then is_dir = true end
                    if bit.band(mode, 0xF000) == 0x8000 then is_reg = true end
                    size = tonumber(st.st_size)
                    mtime = tonumber(st.st_mtime)
                else
                    if not is_dir and not is_reg then
                        local tf = io.open(full_path, "rb")
                        if tf then
                            is_reg = true
                            size = tf:seek("end") or 0
                            tf:close()
                        end
                    elseif is_reg then
                        local tf = io.open(full_path, "rb")
                        if tf then
                            size = tf:seek("end") or 0
                            tf:close()
                        end
                    end
                end

                if is_dir then
                    if recursive then
                        scan_posix_dir(full_path, entries, true, show_hidden)
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
        ffi.C.closedir(d)
    end

    scan_directory_images = function(dir_path, recursive, show_hidden)
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

        scan_posix_dir(dir_path, entries, recursive, show_hidden)
        return entries
    end

    get_file_mtime = function(filepath)
        local st = ffi.new("struct stat")
        if posix_stat(filepath, st) == 0 then
            return tonumber(st.st_mtime)
        end
        return 0
    end
end

-- =========================================================================
-- 3b. EXIF & Timestamp Parser (Zero-dependency pure LuaJIT parser)
-- =========================================================================
local function parse_tiff_exif(data)
    if not data or #data < 14 then return nil end
    local order = data:sub(1, 2)
    local is_le
    if order == "II" then
        is_le = true
    elseif order == "MM" then
        is_le = false
    else
        return nil
    end

    local function u16(o)
        if o + 1 > #data then return 0 end
        local b1, b2 = data:byte(o, o + 1)
        return is_le and (b1 + b2 * 256) or (b1 * 256 + b2)
    end

    local function u32(o)
        if o + 3 > #data then return 0 end
        local b1, b2, b3, b4 = data:byte(o, o + 3)
        if is_le then
            return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        else
            return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        end
    end

    if u16(3) ~= 42 then return nil end

    local ifd0_off = u32(5) + 1
    if ifd0_off <= 0 or ifd0_off + 2 > #data then return nil end

    local num_entries = u16(ifd0_off)
    local dt_val, dto_val, dtd_val
    local sub_ifd_off

    local function read_tag_val(entry_off)
        if entry_off + 11 > #data then return nil end
        local tag = u16(entry_off)
        local typ = u16(entry_off + 2)
        local cnt = u32(entry_off + 4)
        local val
        if cnt <= 4 and typ ~= 2 then
            val = u32(entry_off + 8)
        else
            local voff = u32(entry_off + 8) + 1
            if voff > 0 and voff + cnt - 1 <= #data then
                val = data:sub(voff, voff + cnt - 1):gsub("%z+$", "")
            end
        end
        return tag, val
    end

    for i = 0, num_entries - 1 do
        local entry_off = ifd0_off + 2 + i * 12
        local tag, val = read_tag_val(entry_off)
        if tag == 0x0132 then
            dt_val = val
        elseif tag == 0x8769 then
            if type(val) == "number" then
                sub_ifd_off = val + 1
            else
                sub_ifd_off = u32(entry_off + 8) + 1
            end
        end
    end

    if sub_ifd_off and sub_ifd_off + 2 <= #data then
        local num_sub = u16(sub_ifd_off)
        for i = 0, num_sub - 1 do
            local entry_off = sub_ifd_off + 2 + i * 12
            local tag, val = read_tag_val(entry_off)
            if tag == 0x9003 then
                dto_val = val
            elseif tag == 0x9004 then
                dtd_val = val
            end
        end
    end

    return dto_val or dtd_val or dt_val
end

local function extract_image_exif_date(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil end
    local head = f:read(65536)
    f:close()
    if not head or #head < 12 then return nil end

    -- 1. JPEG (APP1 with Exif\0\0)
    if head:byte(1) == 0xFF and head:byte(2) == 0xD8 then
        local p = 3
        while p + 3 <= #head do
            if head:byte(p) ~= 0xFF then break end
            local m = head:byte(p + 1)
            if m == 0xDA or m == 0xD9 then break end -- SOS / EOI
            local len = head:byte(p + 2) * 256 + head:byte(p + 3)
            if len < 2 then break end
            if m == 0xE1 and p + 9 <= #head and head:sub(p + 4, p + 9) == "Exif\0\0" then
                local tiff_data = head:sub(p + 10, math.min(#head, p + 1 + len))
                local raw_date = parse_tiff_exif(tiff_data)
                if raw_date then return raw_date, "EXIF" end
            end
            p = p + 2 + len
        end

    -- 2. WebP (RIFF .... WEBP)
    elseif head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        local p = 13
        while p + 8 <= #head do
            local fourcc = head:sub(p, p + 3)
            local clen = head:byte(p + 4) + head:byte(p + 5) * 256 + head:byte(p + 6) * 65536 + head:byte(p + 7) * 16777216
            p = p + 8
            if fourcc == "EXIF" then
                local cdata = head:sub(p, math.min(#head, p + clen - 1))
                if cdata:sub(1, 6) == "Exif\0\0" then
                    cdata = cdata:sub(7)
                end
                local raw_date = parse_tiff_exif(cdata)
                if raw_date then return raw_date, "EXIF" end
            end
            p = p + clen + (clen % 2)
        end

    -- 3. PNG (\x89PNG\r\n\x1a\n)
    elseif head:sub(1, 8) == "\137PNG\r\n\026\n" then
        local p = 9
        local time_date
        while p + 8 <= #head do
            local clen = head:byte(p) * 16777216 + head:byte(p + 1) * 65536 + head:byte(p + 2) * 256 + head:byte(p + 3)
            local ctype = head:sub(p + 4, p + 7)
            local data_start = p + 8
            if ctype == "eXIf" then
                local cdata = head:sub(data_start, math.min(#head, data_start + clen - 1))
                local raw_date = parse_tiff_exif(cdata)
                if raw_date then return raw_date, "EXIF" end
            elseif ctype == "tIME" and clen >= 7 and data_start + 6 <= #head then
                local y = head:byte(data_start) * 256 + head:byte(data_start + 1)
                local mo = head:byte(data_start + 2)
                local d = head:byte(data_start + 3)
                local h = head:byte(data_start + 4)
                local mi = head:byte(data_start + 5)
                local s = head:byte(data_start + 6)
                time_date = string.format("%04d:%02d:%02d %02d:%02d:%02d", y, mo, d, h, mi, s)
            elseif ctype == "IEND" then
                break
            end
            p = data_start + clen + 4
        end
        if time_date then return time_date, "tIME" end

    -- 4. TIFF ("II*\0" or "MM\0*")
    elseif head:sub(1, 4) == "II\x2A\x00" or head:sub(1, 4) == "MM\x00\x2A" then
        local raw_date = parse_tiff_exif(head)
        if raw_date then return raw_date, "EXIF" end
    end

    return nil
end

local function normalize_timestamp(raw_date)
    if not raw_date or type(raw_date) ~= "string" then return nil end
    local y, m, d, h, min, s = raw_date:match("(%d%d%d%d)[:/-](%d%d)[:/-](%d%d)[%sT](%d%d):(%d%d):?(%d*)")
    if y and m and d and h and min then
        local sec = (s ~= "" and tonumber(s)) or 0
        local yr, mo, dy, hr, mn = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(min)
        local formatted = string.format("%04d-%02d-%02d %02d:%02d:%02d", yr, mo, dy, hr, mn, sec)
        local ok, epoch = pcall(os.time, { year = yr, month = mo, day = dy, hour = hr, min = mn, sec = sec })
        return formatted, (ok and epoch or 0)
    end
    return raw_date, 0
end

local function get_image_timestamp(img_entry)
    if not img_entry then return "-", "None", 0 end
    if img_entry.timestamp_formatted then
        return img_entry.timestamp_formatted, img_entry.timestamp_source, img_entry.timestamp_sec
    end

    if img_entry.filepath and not img_entry.is_dir then
        local raw_date, src = extract_image_exif_date(img_entry.filepath)
        if raw_date then
            local formatted, epoch = normalize_timestamp(raw_date)
            if formatted then
                img_entry.timestamp_formatted = formatted
                img_entry.timestamp_source = src or "EXIF"
                img_entry.timestamp_sec = epoch
                return formatted, img_entry.timestamp_source, epoch
            end
        end
    end

    local mtime = img_entry.mtime
    if (not mtime or mtime <= 0) and img_entry.filepath and get_file_mtime then
        mtime = get_file_mtime(img_entry.filepath)
        img_entry.mtime = mtime
    end

    if mtime and mtime > 0 then
        local ok, formatted = pcall(os.date, "%Y-%m-%d %H:%M:%S", mtime)
        if ok and formatted then
            img_entry.timestamp_formatted = formatted
            img_entry.timestamp_source = "File"
            img_entry.timestamp_sec = mtime
            return formatted, "File", mtime
        end
    end

    img_entry.timestamp_formatted = "-"
    img_entry.timestamp_source = "None"
    img_entry.timestamp_sec = 0
    return "-", "None", 0
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

-- 5. Universal FFI Image Decoder via GdkPixbuf (JPEG, PNG, WEBP, GIF, BMP, PPM, etc.)
local libgdk_pixbuf_instance = nil
local libgdk_pixbuf_attempted = false

local function get_libgdk_pixbuf()
    if libgdk_pixbuf_attempted then return libgdk_pixbuf_instance end
    libgdk_pixbuf_attempted = true

    pcall(ffi.cdef, [[
        typedef struct _GdkPixbuf GdkPixbuf;
        GdkPixbuf *gdk_pixbuf_new_from_file(const char *filename, void **error);
        int gdk_pixbuf_get_width(const GdkPixbuf *pixbuf);
        int gdk_pixbuf_get_height(const GdkPixbuf *pixbuf);
        int gdk_pixbuf_get_n_channels(const GdkPixbuf *pixbuf);
        int gdk_pixbuf_get_rowstride(const GdkPixbuf *pixbuf);
        const unsigned char *gdk_pixbuf_get_pixels(const GdkPixbuf *pixbuf);
        void g_object_unref(void *object);
    ]])

    libgdk_pixbuf_instance = load_first_lib({
        "gdk_pixbuf-2.0", "libgdk_pixbuf-2.0.so.0", "libgdk_pixbuf-2.0.so",
        "gdk_pixbuf-2.0.dylib", "libgdk_pixbuf-2.0-0.dll"
    })
    return libgdk_pixbuf_instance
end

local function decode_gdk_pixbuf_ffi(filepath)
    local pixbuf_lib = get_libgdk_pixbuf()
    if not pixbuf_lib then return nil, "gdk_pixbuf library not available" end

    local ok, res = pcall(function()
        local err_ptr = ffi.new("void*[1]")
        local pb = pixbuf_lib.gdk_pixbuf_new_from_file(filepath, err_ptr)
        if pb == nil then
            return nil, "GdkPixbuf failed to load file"
        end

        local w = pixbuf_lib.gdk_pixbuf_get_width(pb)
        local h = pixbuf_lib.gdk_pixbuf_get_height(pb)
        local channels = pixbuf_lib.gdk_pixbuf_get_n_channels(pb)
        local stride = pixbuf_lib.gdk_pixbuf_get_rowstride(pb)
        local raw_ptr = pixbuf_lib.gdk_pixbuf_get_pixels(pb)

        if w <= 0 or h <= 0 or raw_ptr == nil then
            pixbuf_lib.g_object_unref(pb)
            return nil, "Invalid GdkPixbuf dimensions or pixel data"
        end

        local pixels = ffi.new("PixelRGB[?]", w * h)
        if channels == 3 then
            if stride == w * 3 then
                ffi.copy(pixels, raw_ptr, w * h * 3)
            else
                for y = 0, h - 1 do
                    ffi.copy(pixels + y * w, raw_ptr + y * stride, w * 3)
                end
            end
            pixbuf_lib.g_object_unref(pb)
            return { width = w, height = h, pixels = pixels, engine = "FFI (GdkPixbuf)" }
        end

        for y = 0, h - 1 do
            local src_row = raw_ptr + y * stride
            local dst_offset = y * w
            if channels == 4 then
                for x = 0, w - 1 do
                    local p = src_row + x * 4
                    local d = dst_offset + x
                    pixels[d].r = p[0]
                    pixels[d].g = p[1]
                    pixels[d].b = p[2]
                end
            else
                for x = 0, w - 1 do
                    local d = dst_offset + x
                    pixels[d].r = src_row[x]
                    pixels[d].g = src_row[x]
                    pixels[d].b = src_row[x]
                end
            end
        end

        pixbuf_lib.g_object_unref(pb)
        return { width = w, height = h, pixels = pixels, engine = "FFI (GdkPixbuf)" }
    end)

    if ok and res then return res end
    return nil, tostring(res or "GdkPixbuf error")
end

-- 6. Windows GDI+ Native Image Decoder (PNG, JPEG, BMP, GIF, TIFF)
local gdiplus_instance = nil
local gdiplus_attempted = false

local function get_gdiplus()
    if gdiplus_attempted then return gdiplus_instance end
    gdiplus_attempted = true
    if not is_windows then return nil end

    local ok, lib = pcall(ffi.load, "gdiplus")
    if not (ok and lib) then return nil end

    pcall(ffi.cdef, [[
        typedef struct {
            uint32_t GdiplusVersion;
            void*    DebugEventCallback;
            int      SuppressBackgroundThread;
            int      SuppressExternalCodecs;
        } GdiplusStartupInput;

        typedef struct {
            uint32_t Width;
            uint32_t Height;
            int32_t  Stride;
            int32_t  PixelFormat;
            void*    Scan0;
            uintptr_t Reserved;
        } GdiplusBitmapData;

        typedef struct {
            int X;
            int Y;
            int Width;
            int Height;
        } GpRect;

        int __stdcall GdiplusStartup(void** token, const GdiplusStartupInput* input, void* output);
        void __stdcall GdiplusShutdown(void* token);
        int __stdcall GdipCreateBitmapFromFile(const wchar_t* filename, void** bitmap);
        int __stdcall GdipGetImageWidth(void* image, uint32_t* width);
        int __stdcall GdipGetImageHeight(void* image, uint32_t* height);
        int __stdcall GdipBitmapLockBits(void* bitmap, const GpRect* rect, uint32_t flags, int32_t format, GdiplusBitmapData* lockedBitmapData);
        int __stdcall GdipBitmapUnlockBits(void* bitmap, GdiplusBitmapData* lockedBitmapData);
        int __stdcall GdipDisposeImage(void* image);
        int __stdcall MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
    ]])

    local input = ffi.new("GdiplusStartupInput", { GdiplusVersion = 1 })
    local token = ffi.new("void*[1]")
    if lib.GdiplusStartup(token, input, nil) == 0 then
        gdiplus_instance = lib
        return lib
    end
    return nil
end

local function decode_gdiplus_ffi(filepath)
    local gdi = get_gdiplus()
    if not gdi then return nil, "GDI+ not available" end

    local ok, res = pcall(function()
        local kernel32 = ffi.load("kernel32")

        -- Paths from the Windows A-APIs/CRT argv are ANSI (e.g. GBK), but MSYS/Git-Bash style
        -- shells and UTF-8 code page installs hand us UTF-8. Try the system code page first,
        -- then UTF-8, so Chinese names decode instead of failing.
        local function to_wide(code_page)
            local len = kernel32.MultiByteToWideChar(code_page, 0, filepath, #filepath, nil, 0)
            if len <= 0 then return nil end
            local wpath = ffi.new("wchar_t[?]", len + 1)
            kernel32.MultiByteToWideChar(code_page, 0, filepath, #filepath, wpath, len)
            wpath[len] = 0
            return wpath
        end

        local wpath = to_wide(0) -- CP_ACP
        local bmp_ptr = ffi.new("void*[1]")
        if not wpath or gdi.GdipCreateBitmapFromFile(wpath, bmp_ptr) ~= 0 or bmp_ptr[0] == nil then
            wpath = to_wide(65001) -- CP_UTF8
            bmp_ptr = ffi.new("void*[1]")
            if not wpath or gdi.GdipCreateBitmapFromFile(wpath, bmp_ptr) ~= 0 or bmp_ptr[0] == nil then
                return nil, "GDI+ failed to load image file"
            end
        end
        local bmp = bmp_ptr[0]

        local w = ffi.new("uint32_t[1]")
        local h = ffi.new("uint32_t[1]")
        gdi.GdipGetImageWidth(bmp, w)
        gdi.GdipGetImageHeight(bmp, h)
        local width = tonumber(w[0])
        local height = tonumber(h[0])

        if width <= 0 or height <= 0 then
            gdi.GdipDisposeImage(bmp)
            return nil, "Invalid GDI+ image dimensions"
        end

        local rect = ffi.new("GpRect", { X = 0, Y = 0, Width = width, Height = height })
        local bdata = ffi.new("GdiplusBitmapData")
        local PixelFormat24bppRGB = 0x21808
        local ImageLockModeRead = 1

        if gdi.GdipBitmapLockBits(bmp, rect, ImageLockModeRead, PixelFormat24bppRGB, bdata) ~= 0 then
            gdi.GdipDisposeImage(bmp)
            return nil, "GDI+ failed to lock bits"
        end

        local pixels = ffi.new("PixelRGB[?]", width * height)
        local raw_ptr = ffi.cast("const uint8_t*", bdata.Scan0)
        local stride = bdata.Stride

        for y = 0, height - 1 do
            local src_row = raw_ptr + y * stride
            local dst_offset = y * width
            for x = 0, width - 1 do
                local p = src_row + x * 3
                local d = dst_offset + x
                pixels[d].b = p[0]
                pixels[d].g = p[1]
                pixels[d].r = p[2]
            end
        end

        gdi.GdipBitmapUnlockBits(bmp, bdata)
        gdi.GdipDisposeImage(bmp)
        return { width = width, height = height, pixels = pixels, engine = "FFI (Windows GDI+)" }
    end)

    if ok and res then return res end
    return nil, tostring(res or "GDI+ decode error")
end

-- =========================================================================
-- 4c. Native Video Decoding via LuaJIT FFI (libavformat, libavcodec, libswscale)
-- =========================================================================
local function format_video_time(sec)
    sec = math.max(0, math.floor(sec or 0))
    local m = math.floor(sec / 60)
    local s = sec % 60
    local h = math.floor(m / 60)
    m = m % 60
    if h > 0 then
        return string.format("%02d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

local lib_avformat = nil
local lib_avcodec = nil
local lib_swscale = nil
local lib_avutil = nil
local av_ffi_initialized = false

local function init_av_ffi()
    if av_ffi_initialized then
        return (lib_avformat and lib_avcodec and lib_swscale) ~= nil
    end
    av_ffi_initialized = true

    pcall(function()
        ffi.cdef[[
            typedef struct AVRational { int num; int den; } AVRational;
            typedef struct AVCodecParameters {
                int codec_type;
                int codec_id;
                uint32_t codec_tag;
                uint8_t *extradata;
                int extradata_size;
                int format;
                int64_t bit_rate;
                int bits_per_coded_sample;
                int bits_per_raw_sample;
                int profile;
                int level;
                int width;
                int height;
            } AVCodecParameters;

            typedef struct AVStream {
                const void *av_class;
                int index;
                int id;
                AVCodecParameters *codecpar;
                void *priv_data;
                AVRational time_base;
                int64_t start_time;
                int64_t duration;
                int64_t nb_frames;
                int disposition;
                int discard;
                AVRational sample_aspect_ratio;
                void *metadata;
                AVRational avg_frame_rate;
                AVRational r_frame_rate;
            } AVStream;

            typedef struct AVFormatContext {
                void *av_class;
                void *iformat;
                void *oformat;
                void *priv_data;
                void *pb;
                int ctx_flags;
                unsigned int nb_streams;
                AVStream **streams;
                char *url;
                int64_t start_time;
                int64_t duration;
                int64_t bit_rate;
            } AVFormatContext;

            typedef struct AVCodec AVCodec;
            typedef struct AVCodecContext AVCodecContext;
            typedef struct AVFrame {
                uint8_t *data[8];
                int linesize[8];
                uint8_t **extended_data;
                int width, height;
                int nb_samples;
                int format;
                int key_frame;
                int pict_type;
                AVRational sample_aspect_ratio;
                int64_t pts;
                int64_t pkt_dts;
            } AVFrame;
            typedef struct AVPacket {
                void *buf;
                int64_t pts;
                int64_t dts;
                uint8_t *data;
                int size;
                int stream_index;
            } AVPacket;

            int avformat_open_input(AVFormatContext **ps, const char *url, void *fmt, void *options);
            void avformat_close_input(AVFormatContext **s);
            int avformat_find_stream_info(AVFormatContext *ic, void *options);
            int av_read_frame(AVFormatContext *s, AVPacket *pkt);
            int av_seek_frame(AVFormatContext *s, int stream_index, int64_t timestamp, int flags);
            int av_find_best_stream(AVFormatContext *ic, int type, int wanted_stream_nb, int related_stream, const AVCodec **decoder_ret, int flags);

            AVCodec *avcodec_find_decoder(int id);
            AVCodecContext *avcodec_alloc_context3(const AVCodec *codec);
            int avcodec_parameters_to_context(AVCodecContext *codec, const AVCodecParameters *par);
            int avcodec_open2(AVCodecContext *avctx, const AVCodec *codec, void *options);
            void avcodec_free_context(AVCodecContext **avctx);
            void avcodec_flush_buffers(AVCodecContext *avctx);
            int avcodec_send_packet(AVCodecContext *avctx, const AVPacket *avpkt);
            int avcodec_receive_frame(AVCodecContext *avctx, AVFrame *frame);

            AVFrame *av_frame_alloc(void);
            void av_frame_free(AVFrame **frame);
            AVPacket *av_packet_alloc(void);
            void av_packet_free(AVPacket **pkt);
            void av_packet_unref(AVPacket *pkt);

            typedef struct SwsContext SwsContext;
            SwsContext *sws_getContext(int srcW, int srcH, int srcFormat,
                                       int dstW, int dstH, int dstFormat,
                                       int flags, void *srcFilter, void *dstFilter, const double *param);
            void sws_freeContext(SwsContext *swsContext);
            int sws_scale(SwsContext *c, const uint8_t *const *srcSlice,
                          const int *srcStride, int srcSliceY, int srcSliceH,
                          uint8_t *const *dst, const int *dstStride);
        ]]
    end)

    lib_avformat = load_first_lib({
        "avformat", "libavformat.so.61", "libavformat.so.60", "libavformat.so.59", "libavformat.so.58",
        "avformat-61", "avformat-60", "avformat-59", "avformat-58", "libavformat"
    })
    lib_avcodec = load_first_lib({
        "avcodec", "libavcodec.so.61", "libavcodec.so.60", "libavcodec.so.59", "libavcodec.so.58",
        "avcodec-61", "avcodec-60", "avcodec-59", "avcodec-58", "libavcodec"
    })
    lib_swscale = load_first_lib({
        "swscale", "libswscale.so.8", "libswscale.so.7", "libswscale.so.6", "libswscale.so.5",
        "swscale-8", "swscale-7", "swscale-6", "swscale-5", "libswscale"
    })
    lib_avutil = load_first_lib({
        "avutil", "libavutil.so.59", "libavutil.so.58", "libavutil.so.57", "libavutil.so.56",
        "avutil-59", "avutil-58", "avutil-57", "avutil-56", "libavutil"
    })

    return (lib_avformat and lib_avcodec and lib_swscale) ~= nil
end

local function has_ffi_video()
    return init_av_ffi()
end

local function get_video_info(filepath)
    if has_ffi_video() then
        local ps = ffi.new("AVFormatContext*[1]")
        if lib_avformat.avformat_open_input(ps, filepath, nil, nil) == 0 then
            local fmt = ps[0]
            if lib_avformat.avformat_find_stream_info(fmt, nil) == 0 then
                local total_sec = (fmt.duration > 0) and (tonumber(fmt.duration) / 1000000.0) or 0
                local width, height, fps = 0, 0, 25
                local dec = ffi.new("const AVCodec*[1]")
                local v_idx = lib_avformat.av_find_best_stream(fmt, 0, -1, -1, dec, 0)
                if v_idx >= 0 then
                    local st = fmt.streams[v_idx]
                    width = st.codecpar.width
                    height = st.codecpar.height
                    if st.avg_frame_rate and st.avg_frame_rate.den > 0 and st.avg_frame_rate.num > 0 then
                        fps = st.avg_frame_rate.num / st.avg_frame_rate.den
                    elseif st.r_frame_rate and st.r_frame_rate.den > 0 and st.r_frame_rate.num > 0 then
                        fps = st.r_frame_rate.num / st.r_frame_rate.den
                    end
                end
                lib_avformat.avformat_close_input(ps)
                return {
                    duration = total_sec,
                    duration_str = format_video_time(total_sec),
                    width = width,
                    height = height,
                    fps = (fps > 0 and fps <= 120) and fps or 25,
                }
            end
            lib_avformat.avformat_close_input(ps)
        end
    end

    -- Fallback to the CLI tools
    local devnull = is_windows and "2>nul" or "2>/dev/null"
    local p = io.popen(string.format('ffmpeg -i %q 2>&1', filepath))
    if not p then
        return { duration = 0, duration_str = "00:00", width = 0, height = 0, fps = 25 }
    end
    local info = p:read("*a") or ""
    p:close()

    local function valid_dim(v)
        return v and v >= 16 and v <= 32768
    end

    local width, height = 0, 0

    -- Prefer ffprobe: machine-readable, so no banner parsing ambiguity. Missing ffprobe just
    -- yields empty output (its stderr is discarded), and the banner parse below takes over.
    local fp = io.popen(string.format('ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 %q %s', filepath, devnull))
    if fp then
        local out = fp:read("*a") or ""
        fp:close()
        local pw, ph = out:match("(%d+)%s*,%s*(%d+)")
        pw, ph = tonumber(pw), tonumber(ph)
        if valid_dim(pw) and valid_dim(ph) then
            width, height = pw, ph
        end
    end

    -- Banner fallback. Real dimensions are `WxH` introduced by a separator, while a hex fourcc
    -- such as `(avc1 / 0x31637661)` can masquerade as one and yields width 0 - which dropped the
    -- player onto its fixed default box and distorted the aspect ratio of every MP4/MOV/AVI.
    if width == 0 then
        local bw, bh = info:match("Video:.-[,%s](%d%d+)x(%d%d+)")
        bw, bh = tonumber(bw), tonumber(bh)
        if valid_dim(bw) and valid_dim(bh) then
            width, height = bw, bh
        end
    end

    local dur_str = info:match("Duration:%s*(%d+:%d+:[%d%.]+)")
    local total_sec = 0
    if dur_str then
        local h, m, s = dur_str:match("(%d+):(%d+):([%d%.]+)")
        if h and m and s then
            total_sec = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
        end
    end

    local fps = info:match("([%d%.]+)%s*fps") or info:match("([%d%.]+)%s*tbr") or 25

    return {
        duration = total_sec,
        duration_str = dur_str and dur_str:match("(%d+:%d+:%d+)") or "00:00",
        width = width,
        height = height,
        fps = tonumber(fps) or 25,
    }
end

local function create_video_reader(filepath, out_w, out_h)
    if not has_ffi_video() then return nil end
    local ps = ffi.new("AVFormatContext*[1]")
    if lib_avformat.avformat_open_input(ps, filepath, nil, nil) ~= 0 then return nil end
    local fmt = ps[0]
    if lib_avformat.avformat_find_stream_info(fmt, nil) ~= 0 then
        lib_avformat.avformat_close_input(ps)
        return nil
    end

    local dec = ffi.new("const AVCodec*[1]")
    local v_idx = lib_avformat.av_find_best_stream(fmt, 0, -1, -1, dec, 0)
    if v_idx < 0 or dec[0] == nil then
        lib_avformat.avformat_close_input(ps)
        return nil
    end

    local stream = fmt.streams[v_idx]
    local codec_ctx = lib_avcodec.avcodec_alloc_context3(dec[0])
    if not codec_ctx or lib_avcodec.avcodec_parameters_to_context(codec_ctx, stream.codecpar) ~= 0 then
        if codec_ctx then lib_avcodec.avcodec_free_context(ffi.new("AVCodecContext*[1]", { codec_ctx })) end
        lib_avformat.avformat_close_input(ps)
        return nil
    end

    if lib_avcodec.avcodec_open2(codec_ctx, dec[0], nil) ~= 0 then
        lib_avcodec.avcodec_free_context(ffi.new("AVCodecContext*[1]", { codec_ctx }))
        lib_avformat.avformat_close_input(ps)
        return nil
    end

    local pkt = lib_avcodec.av_packet_alloc()
    local frame = lib_avcodec.av_frame_alloc()
    local sws = nil
    local rgb_buf = ffi.new("uint8_t[?]", out_w * out_h * 3 + 64)
    local dst_data = ffi.new("uint8_t*[4]", { rgb_buf, nil, nil, nil })
    local dst_linesize = ffi.new("int[4]", { out_w * 3, 0, 0, 0 })
    local is_flushing = false

    local reader = {
        width = stream.codecpar.width,
        height = stream.codecpar.height,
        time_base_num = stream.time_base.num,
        time_base_den = stream.time_base.den,
    }

    function reader:read_frame()
        while true do
            local ret = lib_avcodec.avcodec_receive_frame(codec_ctx, frame)
            if ret == 0 then
                if not sws then
                    sws = lib_swscale.sws_getContext(frame.width, frame.height, frame.format,
                                                     out_w, out_h, 2, 2, nil, nil, nil)
                end
                local src_data = ffi.cast("const uint8_t *const *", frame.data)
                lib_swscale.sws_scale(sws, src_data, frame.linesize, 0, frame.height, dst_data, dst_linesize)
                local pts_sec = -1
                if frame.pts ~= nil and frame.pts >= 0 and reader.time_base_den > 0 and reader.time_base_num > 0 then
                    pts_sec = tonumber(frame.pts) * (reader.time_base_num / reader.time_base_den)
                end
                return ffi.string(rgb_buf, out_w * out_h * 3), pts_sec
            end
            if lib_avformat.av_read_frame(fmt, pkt) ~= 0 then
                if not is_flushing then
                    is_flushing = true
                    lib_avcodec.avcodec_send_packet(codec_ctx, nil)
                else
                    return nil
                end
            else
                if pkt.stream_index == v_idx then
                    lib_avcodec.avcodec_send_packet(codec_ctx, pkt)
                end
                lib_avcodec.av_packet_unref(pkt)
            end
        end
    end

    function reader:seek(sec)
        if reader.time_base_den > 0 and reader.time_base_num > 0 then
            local target_ts = math.floor(sec / (reader.time_base_num / reader.time_base_den))
            lib_avformat.av_seek_frame(fmt, v_idx, target_ts, 1)
            lib_avcodec.avcodec_flush_buffers(codec_ctx)
            is_flushing = false
        end
    end

    function reader:close()
        if sws then lib_swscale.sws_freeContext(sws); sws = nil end
        if frame then lib_avcodec.av_frame_free(ffi.new("AVFrame*[1]", { frame })) end
        if pkt then lib_avcodec.av_packet_free(ffi.new("AVPacket*[1]", { pkt })) end
        if codec_ctx then lib_avcodec.avcodec_free_context(ffi.new("AVCodecContext*[1]", { codec_ctx })) end
        if ps[0] ~= nil then lib_avformat.avformat_close_input(ps) end
    end

    return reader
end

local image_cache = {}
local image_cache_order = {}
local MAX_IMAGE_CACHE = 8

local function load_image_uncached(filepath)
    local test_f = io.open(filepath, "rb")
    if not test_f then
        return nil, "Cannot open file: " .. filepath
    end
    local header = test_f:read(16) or ""
    test_f:close()

    -- 0. Universal GDI+ loader on Windows (built-in, zero dependencies: PNG, JPG, BMP, GIF)
    if is_windows then
        local gdi_img, _ = decode_gdiplus_ffi(filepath)
        if gdi_img then return gdi_img end
    end

    -- 0b. Universal GdkPixbuf loader if available (PNG, JPG, WEBP, GIF, BMP, PPM)
    local gdk_img, _ = decode_gdk_pixbuf_ffi(filepath)
    if gdk_img then return gdk_img end

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

    -- Video thumbnail extraction via LuaJIT FFI (libavcodec) or ffmpeg CLI
    if is_video_file(filepath) then
        if has_ffi_video() then
            local v_info = get_video_info(filepath)
            local tw = (v_info and v_info.width > 0) and v_info.width or 640
            local th = (v_info and v_info.height > 0) and v_info.height or 480
            local r = create_video_reader(filepath, tw, th)
            if r then
                local raw, _ = r:read_frame()
                r:close()
                if raw then
                    local pixels = ffi.new("PixelRGB[?]", tw * th)
                    ffi.copy(pixels, raw, tw * th * 3)
                    return {
                        width = tw,
                        height = th,
                        pixels = pixels,
                        engine = "LuaJIT FFI (libavcodec)",
                    }
                end
            end
        end

        local devnull = is_windows and "2>nul" or "2>/dev/null"
        local cmd = string.format("ffmpeg -nostdin -loglevel quiet -i %q -vframes 1 -f image2pipe -vcodec ppm - %s", filepath, devnull)
        local pipe = io.popen(cmd, POPEN_READ_BIN)
        if pipe then
            local img = parse_ppm_stream(pipe)
            pipe:close()
            if img then
                img.engine = "FFmpeg Video Thumbnail"
                return img
            end
        end
    end

    -- 6. Secondary fallback: CLI tools (ImageMagick / ffmpeg) if available
    local devnull = is_windows and "nul" or "/dev/null"
    local cmd
    if is_windows then
        cmd = string.format("magick %q ppm:- 2>%s || ffmpeg -v error -i %q -f image2pipe -vcodec ppm - 2>%s", filepath, devnull, filepath, devnull)
    else
        cmd = string.format("magick %q ppm:- 2>%s || convert %q ppm:- 2>%s || ffmpeg -v error -i %q -f image2pipe -vcodec ppm - 2>%s", filepath, devnull, filepath, devnull, filepath, devnull)
    end
    local pipe = io.popen(cmd, POPEN_READ_BIN)
    if pipe then
        local img = parse_ppm_stream(pipe)
        pipe:close()
        if img then
            img.engine = "CLI (magick/convert/ffmpeg)"
            return img
        end
    end

    return nil, "Failed to decode image. Ensure image is valid (PNG, JPG, BMP, WEBP, PPM) and FFI libraries (gdk_pixbuf, libpng, libturbojpeg, libwebp) or ImageMagick/ffmpeg are available."
end

local function load_image(filepath)
    if image_cache[filepath] then
        -- Refresh LRU position
        for i, p in ipairs(image_cache_order) do
            if p == filepath then
                table.remove(image_cache_order, i)
                break
            end
        end
        table.insert(image_cache_order, filepath)
        return image_cache[filepath]
    end

    local img, err = load_image_uncached(filepath)
    if img then
        if #image_cache_order >= MAX_IMAGE_CACHE then
            local evicted = table.remove(image_cache_order, 1)
            image_cache[evicted] = nil
        end
        table.insert(image_cache_order, filepath)
        image_cache[filepath] = img
    end
    return img, err
end

-- =========================================================================
-- 5. timg-style UnicodeBlockCanvas — Native LuaJIT Port
--    Implements timg's half-block and quarter-block rendering algorithms:
--      * framebuffer.h  → LinearColor (γ≈x²/sqrt), avd()
--      * unicode-block-canvas.cc → FindBestGlyph<1> (half), FindBestGlyph<2> (quarter)
--      * image-source.cc → CalcScaleToFitDisplay
--    Area-averaging (box filter) downscale in linear space = libswscale equivalent.
-- =========================================================================

-- ---------------------------------------------------------------------------
-- 5a.  Linear-light colour helpers  (timg: LinearColor in framebuffer.h)
--      Approximates γ=2.2 with γ=2  (v² linearize, sqrt de-gamma).
-- ---------------------------------------------------------------------------
local function lin(v)   return v * v   end          -- uint8 → linear float
local function degamma(l)
    local g = math.sqrt(l)
    return (g > 255) and 255 or math.max(0, math.floor(g + 0.5))
end
-- Squared Euclidean distance in linear space  (LinearColor::dist)
local function lin_dist2(a, b)
    local dr = a[1]-b[1]; local dg = a[2]-b[2]; local db = a[3]-b[3]
    return dr*dr + dg*dg + db*db
end
-- Average N linear-colour triples; return avg triple + sum-of-distances  (avd())
local function lin_avd(colours)
    local n = #colours
    local r, g, b = 0, 0, 0
    for i = 1, n do r=r+colours[i][1]; g=g+colours[i][2]; b=b+colours[i][3] end
    local avg = { r/n, g/n, b/n }
    local d = 0
    for i = 1, n do d = d + lin_dist2(avg, colours[i]) end
    return avg, d
end
-- Convert a linear-float triple back to an {r,g,b} uint8 table  (repack())
local function repack(lc)
    return { r=degamma(lc[1]), g=degamma(lc[2]), b=degamma(lc[3]) }
end
-- Linearise a PixelRGB cdata pixel to a triple  [r², g², b²]
local function px_to_lin(p)
    return { lin(p.r), lin(p.g), lin(p.b) }
end

-- ---------------------------------------------------------------------------
-- 5b.  Area-averaging (box-filter) downscale in linear space
--      timg uses libswscale with SWS_AREA / SWS_BILINEAR. We implement a
--      pixel-exact box-filter: for each output pixel, average all source
--      pixels whose projection overlaps the output pixel area.
-- ---------------------------------------------------------------------------
local function area_average_scale(img, out_w, out_h)
    local iw, ih = img.width, img.height
    local px     = img.pixels
    local xs = iw / out_w       -- x scale factor (src pixels per output pixel)
    local ys = ih / out_h       -- y scale factor

    local out = {}
    for oy = 0, out_h - 1 do
        local y0 = oy * ys;         local y1 = y0 + ys
        local iy0 = math.floor(y0); local iy1 = math.min(ih-1, math.ceil(y1)-1)
        for ox = 0, out_w - 1 do
            local x0 = ox * xs;         local x1 = x0 + xs
            local ix0 = math.floor(x0); local ix1 = math.min(iw-1, math.ceil(x1)-1)
            -- Accumulate linear values weighted by overlap area directly from FFI buffer
            local wr, wg, wb, wa = 0, 0, 0, 0
            for sy = iy0, iy1 do
                -- Vertical overlap fraction
                local fy0 = math.max(y0, sy);   local fy1 = math.min(y1, sy+1)
                local yw = fy1 - fy0
                local row_offset = sy * iw
                for sx = ix0, ix1 do
                    local fx0 = math.max(x0, sx); local fx1 = math.min(x1, sx+1)
                    local w = yw * (fx1 - fx0)
                    local p = px[row_offset + sx]
                    local pr, pg, pb = p.r, p.g, p.b
                    wr = wr + (pr * pr) * w
                    wg = wg + (pg * pg) * w
                    wb = wb + (pb * pb) * w
                    wa = wa + w
                end
            end
            if wa < 1e-9 then wa = 1 end
            out[oy * out_w + ox] = { wr/wa, wg/wa, wb/wa }
        end
    end
    return out  -- linear-float triples, indexed [oy*out_w + ox]  (0-based)
end

-- ---------------------------------------------------------------------------
-- 5c.  CalcScaleToFitDisplay  (timg: ImageSource::CalcScaleToFitDisplay)
--      Returns out_w, out_h in PIXELS (not character-cells).
--      For half-block:    cell_x=1, cell_y=2   → 1 pixel/col, 2 pixels/row
--      For quarter-block: cell_x=2, cell_y=2   → 2 pixels/col, 2 pixels/row
-- ---------------------------------------------------------------------------
local function calc_scale_to_fit(img_w, img_h, term_cols, term_rows, cell_x, cell_y)
    cell_x = cell_x or 1;  cell_y = cell_y or 2
    -- In quarter-block mode (2x2 subpixels in an ~8x16 char cell), each subpixel is 4x8 px (1:2 aspect).
    -- Match timg's width_stretch = 2.0 to compensate and preserve true image aspect ratio.
    local width_stretch = (cell_x == 2) and 2.0 or 1.0
    local disp_w = (term_cols * cell_x) / width_stretch
    local disp_h = term_rows * cell_y
    -- fit-in-both: use the more restrictive scale (no upscale)
    local scale = math.min(disp_w / img_w, disp_h / img_h)
    if scale > 1.0 then scale = 1.0 end
    local out_w = math.max(1, math.floor(img_w * scale * width_stretch))
    local out_h = math.max(1, math.floor(img_h * scale))
    -- Align to cell boundaries (floor to nearest cell multiple)
    out_w = math.max(cell_x, math.floor(out_w / cell_x) * cell_x)
    out_h = math.max(cell_y, math.floor(out_h / cell_y) * cell_y)
    return out_w, out_h
end

-- ---------------------------------------------------------------------------
-- 5d.  Unicode block glyph table  (timg: kBlockGlyphs[], BlockChoice enum)
--
--      Half-block (N=1): one pixel wide, two pixels tall per cell.
--        FG = bottom pixel colour  (foreground = ▄ lower half)
--        BG = top    pixel colour  (background = upper half)
--        Glyph: ▄ U+2584 (default)  or  ▀ U+2580 (TIMG_USE_UPPER_BLOCK)
--
--      Quarter-block (N=2): two pixels wide, two pixels tall per cell.
--        16 possible glyphs.  Each glyph is described by a 4-bit FG mask:
--          bit0=TL  bit1=TR  bit2=BL  bit3=BR   (1 = filled by FG colour)
-- ---------------------------------------------------------------------------
local GLYPH_LOWER = "\xE2\x96\x84"   -- ▄  U+2584  lower half block   (timg default)
local GLYPH_UPPER = "\xE2\x96\x80"   -- ▀  U+2580  upper half block

-- Quarter glyphs: { utf8_string, fg_mask }
-- (matches timg's BlockChoice enum + kBlockGlyphs array exactly)
local QUARTER_GLYPHS = {
    -- fg_mask  glyph  codepoint  name
    { "\xE2\x96\x88", 0xF },  -- █ U+2588  full block     (all FG)
    { "\xE2\x96\x84", 0xC },  -- ▄ U+2584  bottom half    (BL+BR)
    { "\xE2\x96\x80", 0x3 },  -- ▀ U+2580  top half       (TL+TR)
    { "\xE2\x96\x8C", 0x5 },  -- ▌ U+258C  left half      (TL+BL)
    { "\xE2\x96\x90", 0xA },  -- ▐ U+2590  right half     (TR+BR)
    { "\xE2\x96\x9A", 0x6 },  -- ▚ U+259A  TL+BR diagonal
    { "\xE2\x96\x9E", 0x9 },  -- ▞ U+259E  TR+BL diagonal
    { "\xE2\x96\x98", 0x1 },  -- ▘ U+2598  TL only
    { "\xE2\x96\x9D", 0x2 },  -- ▝ U+259D  TR only
    { "\xE2\x96\x96", 0x4 },  -- ▖ U+2596  BL only
    { "\xE2\x96\x97", 0x8 },  -- ▗ U+2597  BR only
    { "\xE2\x96\x9B", 0x7 },  -- ▛ U+259B  TL+TR+BL
    { "\xE2\x96\x9C", 0xB },  -- ▜ U+259C  TL+TR+BR
    { "\xE2\x96\x99", 0xD },  -- ▙ U+2599  TL+BL+BR
    { "\xE2\x96\x9F", 0xE },  -- ▟ U+259F  TR+BL+BR
    { " ",            0x0 },  -- space     all BG          (kBackground)
}

-- ---------------------------------------------------------------------------
-- 5e.  FindBestGlyph<1>  — half-block  (timg: FindBestGlyph<1>)
--      top_lin, bot_lin: linear-float triples.
--      Returns: fg_lin, bg_lin, glyph_string  (nil glyph = emit space)
-- ---------------------------------------------------------------------------
local function find_best_glyph_half(top_lin, bot_lin)
    -- If top == bottom (same colour): emit space — only BG colour needed.
    -- timg: if (*top == *bottom) return {*top, *bottom, kBackground}
    if lin_dist2(top_lin, bot_lin) < 4 then   -- small epsilon for float noise
        return bot_lin, bot_lin, nil           -- nil → space
    end
    -- Default: ▄  FG=bottom  BG=top  (timg: return {*bottom, *top, kLowerBlock})
    return bot_lin, top_lin, GLYPH_LOWER
end

-- ---------------------------------------------------------------------------
-- 5f.  FindBestGlyph<2>  — quarter-block  (timg: FindBestGlyph<2>)
--      Tries every glyph, picks the one that minimises the total sum of
--      squared perceptual distances from each quadrant pixel to its
--      assigned fg/bg average colour.  (timg: avd() minimisation loop)
--      tl, tr, bl, br: linear-float triples for the four quadrant pixels.
-- ---------------------------------------------------------------------------
local bit_at = { 0x1, 0x2, 0x4, 0x8 }   -- bit mask for TL, TR, BL, BR

-- Precomputed static partition masks (eliminates table churn in inner rendering loop)
local QUARTER_PARTITIONS = {}
for mask = 0, 15 do
    local fg_idx, bg_idx = {}, {}
    for q = 1, 4 do
        if bit.band(mask, bit_at[q]) ~= 0 then
            table.insert(fg_idx, q)
        else
            table.insert(bg_idx, q)
        end
    end
    if #fg_idx == 0 then fg_idx = bg_idx end
    if #bg_idx == 0 then bg_idx = fg_idx end
    QUARTER_PARTITIONS[mask] = { fg = fg_idx, bg = bg_idx }
end

local function find_best_glyph_quarter(tl, tr, bl, br)
    local quads = { tl, tr, bl, br }   -- TL=1, TR=2, BL=3, BR=4
    local best_dist  = math.huge
    local best_fg, best_bg, best_glyph = tl, br, GLYPH_LOWER

    for _, entry in ipairs(QUARTER_GLYPHS) do
        local glyph, fg_mask = entry[1], entry[2]
        local part = QUARTER_PARTITIONS[fg_mask]
        local f_idx = part.fg
        local b_idx = part.bg

        local fn = #f_idx
        local fr, fg, fb = 0, 0, 0
        for i = 1, fn do
            local q = quads[f_idx[i]]
            fr = fr + q[1]; fg = fg + q[2]; fb = fb + q[3]
        end
        local f_avg = { fr/fn, fg/fn, fb/fn }
        local d_fg = 0
        for i = 1, fn do d_fg = d_fg + lin_dist2(f_avg, quads[f_idx[i]]) end

        local bn = #b_idx
        local brr, bg_val, bb = 0, 0, 0
        for i = 1, bn do
            local q = quads[b_idx[i]]
            brr = brr + q[1]; bg_val = bg_val + q[2]; bb = bb + q[3]
        end
        local b_avg = { brr/bn, bg_val/bn, bb/bn }
        local d_bg = 0
        for i = 1, bn do d_bg = d_bg + lin_dist2(b_avg, quads[b_idx[i]]) end

        local total = d_fg + d_bg

        if total < best_dist then
            best_dist  = total
            best_fg    = f_avg
            best_bg    = b_avg
            best_glyph = glyph
            if total < 1 then break end   -- essentially zero → stop early
        end
    end
    return best_fg, best_bg, best_glyph
end

-- ---------------------------------------------------------------------------
-- 5g.  render_image_unicode_block  — unified timg-style renderer
--      use_quarter=false → half-block  (timg -p h)
--      use_quarter=true  → quarter-block (timg -p q)
-- ---------------------------------------------------------------------------
local function render_image_unicode_block(img_entry, current_idx, total_count, term_w, term_h, use_quarter, cur_e, total_e)
    local img, err = load_image(img_entry.filepath)
    if not img then return false, err end

    use_quarter = use_quarter or false
    local cell_x = use_quarter and 2 or 1   -- pixels per character column
    local cell_y = 2                         -- pixels per character row (always 2)

    -- Reserve rows for header banner (5 lines)
    local header_rows = 5
    local max_char_h = math.max(4, term_h - header_rows)
    local max_char_w = math.max(4, term_w - 2)

    -- CalcScaleToFitDisplay → pixel canvas dimensions
    local out_w, out_h = calc_scale_to_fit(
        img.width, img.height, max_char_w, max_char_h, cell_x, cell_y)

    -- Area-average downscale to out_w × out_h pixel canvas (linear space)
    local scaled = area_average_scale(img, out_w, out_h)

    -- Character-cell dimensions
    local char_w = out_w / cell_x
    local char_h = out_h / cell_y

    -- 2D centring
    local pad_left = math.max(0, math.floor((term_w - char_w) / 2))
    local pad_top  = math.max(0, math.floor((max_char_h - char_h) / 2))
    local pad      = string.rep(" ", pad_left)

    -- Build output buffer
    local out  = {}
    local blen = math.max(20, term_w - 4)
    table.insert(out, "\27[H\27[2J")
    table.insert(out, "\27[1;36m" .. string.rep("═", blen) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, to_display_text(img_entry.filename)))
    local date_disp, date_src = get_image_timestamp(img_entry)
    local date_info = (date_src == "EXIF" or date_src == "tIME") and (date_disp .. " (" .. date_src .. ")") or (date_src == "File" and (date_disp .. " (File)") or date_disp)
    local dpath = to_display_text(img_entry.filepath)
    local path_cols = math.max(15, term_w - 60)
    if display_width(dpath) > path_cols then dpath = utf8_tail(dpath, path_cols) end
    local eng_prefix = (cur_e and total_e) and string.format("[%d/%d] ", cur_e, total_e) or ""
    local eng = use_quarter
        and (eng_prefix .. "\27[1;93mtimg Quarter-Block ▛▜▙▟ (Native LuaJIT)\27[90m")
        or  (eng_prefix .. "\27[1;92mtimg Half-Block ▄ (Native LuaJIT)\27[90m")
    table.insert(out, string.format(
        "  \27[90mSize: %s | Original: %dx%d | Date: %s | Engine: %s | Path: %s\27[0m\n",
        img_entry.size_str, img.width, img.height, date_info, eng, dpath))
    local cycle_hint = total_e and string.format("  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine (%d available)  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n", total_e)
        or "  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n"
    table.insert(out, cycle_hint)
    table.insert(out, "\27[90m" .. string.rep("─", blen) .. "\27[0m\n")

    if pad_top > 0 then table.insert(out, string.rep("\n", pad_top)) end

    -- -----------------------------------------------------------------------
    -- Main rendering loop  (timg: AppendDoubleRow)
    -- Process two pixel rows at once → one character row.
    -- Track last fg/bg colour to avoid redundant escape sequences.
    -- (timg: last_foreground, last_bg_unknown tracking in AppendDoubleRow)
    -- -----------------------------------------------------------------------
    local last_fg = nil    -- last emitted fg colour {r,g,b} or nil
    local last_bg = nil    -- last emitted bg colour {r,g,b} or nil

    for cy = 0, char_h - 1 do
        local py_top = cy * cell_y          -- top pixel row index in scaled
        local py_bot = py_top + 1           -- bottom pixel row index

        local line = { pad }

        if use_quarter then
            -- ---------------------------------------------------------------
            -- Quarter-block mode: 2×2 pixels → 1 character cell
            -- (timg: AppendDoubleRow<N=2, colorbits=24>)
            -- ---------------------------------------------------------------
            for cx = 0, char_w - 1 do
                local px_l = cx * cell_x          -- left pixel column
                local px_r = px_l + 1             -- right pixel column

                local tl = scaled[py_top*out_w + px_l] or {0,0,0}
                local tr = scaled[py_top*out_w + px_r] or {0,0,0}
                local bl = scaled[py_bot*out_w + px_l] or {0,0,0}
                local br = scaled[py_bot*out_w + px_r] or {0,0,0}

                local fg_lin, bg_lin, glyph = find_best_glyph_quarter(tl, tr, bl, br)
                local fg = repack(fg_lin)
                local bg = repack(bg_lin)

                -- FG: emit only if changed (timg: last_fg_unknown || pick.fg != last_foreground)
                if glyph ~= " " then
                    if not last_fg or last_fg.r~=fg.r or last_fg.g~=fg.g or last_fg.b~=fg.b then
                        table.insert(line, string.format("\27[38;2;%d;%d;%dm", fg.r, fg.g, fg.b))
                        last_fg = fg
                    end
                end
                -- BG: emit only if changed
                if not last_bg or last_bg.r~=bg.r or last_bg.g~=bg.g or last_bg.b~=bg.b then
                    table.insert(line, string.format("\27[48;2;%d;%d;%dm", bg.r, bg.g, bg.b))
                    last_bg = bg
                end
                table.insert(line, glyph)
            end
        else
            -- ---------------------------------------------------------------
            -- Half-block mode  (timg: AppendDoubleRow<N=1, colorbits=24>)
            -- FG = bottom pixel (▄ lower half), BG = top pixel (upper half).
            -- ---------------------------------------------------------------
            for cx = 0, char_w - 1 do
                local top_lin = scaled[py_top*out_w + cx] or {0,0,0}
                local bot_lin = scaled[py_bot*out_w + cx] or {0,0,0}

                local fg_lin, bg_lin, glyph = find_best_glyph_half(top_lin, bot_lin)
                local fg = repack(fg_lin)
                local bg = repack(bg_lin)

                -- BG always emitted first (timg: background check before foreground)
                if not last_bg or last_bg.r~=bg.r or last_bg.g~=bg.g or last_bg.b~=bg.b then
                    table.insert(line, string.format("\27[48;2;%d;%d;%dm", bg.r, bg.g, bg.b))
                    last_bg = bg
                end
                if glyph then
                    -- Actual glyph (▄): emit FG only if changed
                    if not last_fg or last_fg.r~=fg.r or last_fg.g~=fg.g or last_fg.b~=fg.b then
                        table.insert(line, string.format("\27[38;2;%d;%d;%dm", fg.r, fg.g, fg.b))
                        last_fg = fg
                    end
                    table.insert(line, GLYPH_LOWER)
                else
                    -- Same-colour optimisation (timg: kBackground → emit ' ')
                    -- Both halves the same colour → just background + space.
                    table.insert(line, " ")
                    last_fg = nil    -- fg state unknown after kBackground
                end
            end
        end

        -- End of line: reset all attributes  (timg: SCREEN_END_OF_LINE = "\033[0m\n")
        table.insert(line, "\27[0m\n")
        last_fg, last_bg = nil, nil    -- reset colour state each row (timg also resets)

        table.insert(out, table.concat(line))
    end

    io.write(table.concat(out))
    io.flush()
    return true
end

-- =========================================================================
-- 5h. Chafa Terminal Graphics Engine (Multi-Tier Architecture)
--     Tier 1: Direct FFI binding to libchafa.so.0 / chafa.dll (SIMD accelerated)
--     Tier 2: CLI chafa pipe fallback if binary is in $PATH
--     Tier 3: Pure LuaJIT Native 2x4 Braille & Smooth-Block engine (Zero Dependencies)
-- =========================================================================

local libchafa_instance = nil
local libchafa_attempted = false

local function get_libchafa()
    if libchafa_attempted then return libchafa_instance end
    libchafa_attempted = true

    pcall(ffi.cdef, [[
        typedef struct ChafaCanvas ChafaCanvas;
        typedef struct ChafaCanvasConfig ChafaCanvasConfig;
        typedef struct ChafaSymbolMap ChafaSymbolMap;
        typedef struct ChafaTermInfo ChafaTermInfo;
        typedef struct GString { char *str; size_t len; size_t allocated_len; } GString;

        ChafaCanvasConfig *chafa_canvas_config_new(void);
        void chafa_canvas_config_unref(ChafaCanvasConfig *config);
        void chafa_canvas_config_set_geometry(ChafaCanvasConfig *config, int width, int height);
        void chafa_canvas_config_set_canvas_mode(ChafaCanvasConfig *config, int mode);

        ChafaSymbolMap *chafa_symbol_map_new(void);
        void chafa_symbol_map_unref(ChafaSymbolMap *symbol_map);
        void chafa_symbol_map_add_by_tags(ChafaSymbolMap *symbol_map, int tags);
        void chafa_canvas_config_set_symbol_map(ChafaCanvasConfig *config, const ChafaSymbolMap *symbol_map);

        ChafaCanvas *chafa_canvas_new(const ChafaCanvasConfig *config);
        void chafa_canvas_unref(ChafaCanvas *canvas);
        void chafa_canvas_draw_all_pixels(ChafaCanvas *canvas, int pixel_type, const uint8_t *src_pixels, int width, int height, int rowstride);
        GString *chafa_canvas_print(ChafaCanvas *canvas, ChafaTermInfo *term_info);
        char *g_string_free(GString *string, int free_segment);
    ]])

    libchafa_instance = load_first_lib({
        "libchafa.so.0", "chafa", "libchafa.so", "chafa.dll", "libchafa-0.dll"
    })
    return libchafa_instance
end

-- Check if /usr/bin/chafa CLI is callable
local chafa_cli_available = nil
local function is_chafa_cli_available()
    if chafa_cli_available ~= nil then return chafa_cli_available end
    local devnull = is_windows and "nul" or "/dev/null"
    local ret = os.execute("chafa --version >" .. devnull .. " 2>&1")
    chafa_cli_available = (ret == 0 or ret == true)
    return chafa_cli_available
end

-- Unicode Braille UTF-8 Generator
local function utf8_braille(mask)
    local cp = 0x2800 + mask
    return string.char(
        0xE0 + bit.rshift(cp, 12),
        0x80 + bit.band(bit.rshift(cp, 6), 0x3F),
        0x80 + bit.band(cp, 0x3F)
    )
end

-- Braille dot mapping matrix (2 cols x 4 rows = 8 subpixels per character cell):
-- (0,0)->bit 0, (0,1)->bit 1, (0,2)->bit 2, (0,3)->bit 6
-- (1,0)->bit 3, (1,1)->bit 4, (1,2)->bit 5, (1,3)->bit 7
local BRAILLE_DOTS = {
    {0, 0, 0x01}, {0, 1, 0x02}, {0, 2, 0x04}, {0, 3, 0x40},
    {1, 0, 0x08}, {1, 1, 0x10}, {1, 2, 0x20}, {1, 3, 0x80}
}

-- Tier 3: Pure LuaJIT Native Chafa-style Braille 2x4 Matrix Renderer (Zero Dependencies)
local function render_image_native_braille(img, fit_cols, fit_rows)
    local sub_w = fit_cols * 2
    local sub_h = fit_rows * 4

    -- Downscale image to (sub_w x sub_h) subpixel grid using linear area averaging
    local scaled = area_average_scale(img, sub_w, sub_h)

    local lines = {}
    local last_fg = nil
    local last_bg = nil

    for cy = 0, fit_rows - 1 do
        local line = {}
        for cx = 0, fit_cols - 1 do
            local base_x = cx * 2
            local base_y = cy * 4

            local sum_lum = 0
            local subpixels = {}
            for i = 1, 8 do
                local dot = BRAILLE_DOTS[i]
                local sx = base_x + dot[1]
                local sy = base_y + dot[2]
                local p = scaled[sy * sub_w + sx] or {0, 0, 0}
                local col = repack(p)
                local lum = 0.299 * col.r + 0.587 * col.g + 0.114 * col.b
                sum_lum = sum_lum + lum
                subpixels[i] = { r = col.r, g = col.g, b = col.b, lum = lum, bit = dot[3] }
            end

            local avg_lum = sum_lum / 8
            local mask = 0
            local fg_r, fg_g, fg_b, fg_n = 0, 0, 0, 0
            local bg_r, bg_g, bg_b, bg_n = 0, 0, 0, 0

            for i = 1, 8 do
                local sp = subpixels[i]
                if sp.lum >= avg_lum then
                    mask = bit.bor(mask, sp.bit)
                    fg_r = fg_r + sp.r; fg_g = fg_g + sp.g; fg_b = fg_b + sp.b; fg_n = fg_n + 1
                else
                    bg_r = bg_r + sp.r; bg_g = bg_g + sp.g; bg_b = bg_b + sp.b; bg_n = bg_n + 1
                end
            end

            if fg_n == 0 then fg_r, fg_g, fg_b = bg_r, bg_g, bg_b; fg_n = 1 end
            if bg_n == 0 then bg_r, bg_g, bg_b = fg_r, fg_g, fg_b; bg_n = 1 end

            local fg = { r = math.floor(fg_r / fg_n), g = math.floor(fg_g / fg_n), b = math.floor(fg_b / fg_n) }
            local bg = { r = math.floor(bg_r / bg_n), g = math.floor(bg_g / bg_n), b = math.floor(bg_b / bg_n) }

            -- BG emit if changed
            if not last_bg or last_bg.r ~= bg.r or last_bg.g ~= bg.g or last_bg.b ~= bg.b then
                table.insert(line, string.format("\27[48;2;%d;%d;%dm", bg.r, bg.g, bg.b))
                last_bg = bg
            end
            -- FG emit if changed (and not empty mask)
            if mask ~= 0 then
                if not last_fg or last_fg.r ~= fg.r or last_fg.g ~= fg.g or last_fg.b ~= fg.b then
                    table.insert(line, string.format("\27[38;2;%d;%d;%dm", fg.r, fg.g, fg.b))
                    last_fg = fg
                end
                table.insert(line, utf8_braille(mask))
            else
                table.insert(line, " ")
                last_fg = nil
            end
        end
        table.insert(line, "\27[0m")
        last_fg, last_bg = nil, nil
        table.insert(lines, table.concat(line))
    end
    return lines
end

-- Unified Chafa renderer (dispatches Tier 1 FFI -> Tier 2 CLI -> Tier 3 Pure Lua)
local function render_image_chafa(img_entry, current_idx, total_count, term_w, term_h, symbol_mode, cur_e, total_e)
    local img, err = load_image(img_entry.filepath)
    if not img then return false, err end

    symbol_mode = symbol_mode or "symbols"

    local reserved_header_rows = 6
    local max_char_h = math.max(4, term_h - reserved_header_rows)
    local max_char_w = math.max(4, term_w - 4)

    -- Optical aspect ratio correction: terminal font height/width ~ 2.0
    local optical_aspect = (img.width / img.height) * 2.0
    local fit_rows = max_char_h
    local fit_cols = math.max(2, math.floor(fit_rows * optical_aspect))
    if fit_cols > max_char_w then
        fit_cols = max_char_w
        fit_rows = math.max(2, math.floor(fit_cols / optical_aspect))
    end

    local rendered_lines = nil
    local engine_label = nil

    -- Tier 1: FFI libchafa
    local chafa = get_libchafa()
    if chafa then
        local cfg = chafa.chafa_canvas_config_new()
        chafa.chafa_canvas_config_set_geometry(cfg, fit_cols, fit_rows)
        chafa.chafa_canvas_config_set_canvas_mode(cfg, 0) -- CHAFA_CANVAS_MODE_TRUECOLOR

        local sm = chafa.chafa_symbol_map_new()
        if symbol_mode == "braille" then
            chafa.chafa_symbol_map_add_by_tags(sm, 0x0801) -- SPACE | BRAILLE
            engine_label = "\27[1;95mChafa Braille 2×4 (FFI libchafa)\27[90m"
        else
            -- Smooth blocks, quadrants, fractional bars
            chafa.chafa_symbol_map_add_by_tags(sm, 0x38F)
            engine_label = "\27[1;95mChafa Symbols (FFI libchafa)\27[90m"
        end
        chafa.chafa_canvas_config_set_symbol_map(cfg, sm)

        local canvas = chafa.chafa_canvas_new(cfg)
        local CHAFA_PIXEL_RGB8 = 8
        local raw_bytes = ffi.cast("const uint8_t*", img.pixels)
        chafa.chafa_canvas_draw_all_pixels(canvas, CHAFA_PIXEL_RGB8, raw_bytes, img.width, img.height, img.width * 3)

        local gs = chafa.chafa_canvas_print(canvas, nil)
        if gs and gs.str ~= nil and gs.len > 0 then
            local text = ffi.string(gs.str, gs.len)
            rendered_lines = {}
            for l in text:gmatch("([^\n]*)\n?") do
                local vis = l:gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("\r", "")
                if #vis > 0 then table.insert(rendered_lines, l) end
            end
        end

        if gs then chafa.g_string_free(gs, 1) end
        chafa.chafa_canvas_unref(canvas)
        chafa.chafa_symbol_map_unref(sm)
        chafa.chafa_canvas_config_unref(cfg)
    end

    -- Tier 2: CLI Fallback if FFI failed but chafa command is in PATH
    if not rendered_lines and is_chafa_cli_available() then
        local sym_flag = (symbol_mode == "braille") and "--symbols braille" or "--symbols block"
        local devnull = is_windows and "nul" or "/dev/null"
        local cmd = string.format("chafa -f symbols -s %dx%d %s %q 2>%s", fit_cols, fit_rows, sym_flag, img_entry.filepath, devnull)
        local p = io.popen(cmd, "r")
        if p then
            local text = p:read("*a")
            p:close()
            if text and #text > 0 then
                rendered_lines = {}
                for l in text:gmatch("([^\n]*)\n?") do
                    local vis = l:gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("\r", "")
                    if #vis > 0 then table.insert(rendered_lines, l) end
                end
                engine_label = (symbol_mode == "braille")
                    and "\27[1;95mChafa Braille 2×4 (CLI chafa)\27[90m"
                    or  "\27[1;95mChafa Symbols (CLI chafa)\27[90m"
            end
        end
    end

    -- Tier 3: Zero-Dependency Pure LuaJIT Native Braille Engine
    if not rendered_lines then
        rendered_lines = render_image_native_braille(img, fit_cols, fit_rows)
        engine_label = "\27[1;95mChafa Braille 2×4 (Native LuaJIT)\27[90m"
    end

    if not rendered_lines or #rendered_lines == 0 then
        return false, "Failed to render image with Chafa"
    end

    -- 2D Centering
    local pad_left = math.max(0, math.floor((term_w - fit_cols) / 2))
    local pad_top  = math.max(0, math.floor((max_char_h - #rendered_lines) / 2))
    local pad      = string.rep(" ", pad_left)

    local out = {}
    local bar_len = math.max(20, term_w - 4)
    table.insert(out, "\27[H\27[2J")
    table.insert(out, "\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, to_display_text(img_entry.filename)))
    local date_disp, date_src = get_image_timestamp(img_entry)
    local date_info = (date_src == "EXIF" or date_src == "tIME") and (date_disp .. " (" .. date_src .. ")") or (date_src == "File" and (date_disp .. " (File)") or date_disp)
    local disp_path = to_display_text(img_entry.filepath)
    local path_cols = math.max(15, term_w - 60)
    if display_width(disp_path) > path_cols then disp_path = utf8_tail(disp_path, path_cols) end
    local eng_label = engine_label or "Chafa"
    if cur_e and total_e then
        eng_label = string.format("[%d/%d] %s", cur_e, total_e, eng_label)
    end
    table.insert(out, string.format("  \27[90mSize: %s | Original: %dx%d | Date: %s | Engine: %s | Path: %s\27[0m\n",
        img_entry.size_str, img.width, img.height, date_info, eng_label, disp_path))
    local cycle_hint = total_e and string.format("  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine (%d available)  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n", total_e)
        or "  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n"
    table.insert(out, cycle_hint)
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    if pad_top > 0 then
        table.insert(out, string.rep("\n", pad_top))
    end

    for _, l in ipairs(rendered_lines) do
        table.insert(out, pad .. l .. "\27[0m\n")
    end

    io.write(table.concat(out))
    io.flush()
    return true
end

-- =========================================================================
-- 5i. External CLI Render Engines (timg & chafa)
--     Dynamically available when the respective binaries exist in $PATH.
-- =========================================================================

local function is_cmd_available(cmd)
    local devnull = is_windows and "nul" or "/dev/null"
    local ret = os.execute(cmd .. " --version >" .. devnull .. " 2>&1")
    return (ret == 0 or ret == true)
end

local has_timg_cli = nil
local function get_has_timg_cli()
    if has_timg_cli == nil then has_timg_cli = is_cmd_available("timg") end
    return has_timg_cli
end

local has_chafa_cli_direct = nil
local function get_has_chafa_cli_direct()
    if has_chafa_cli_direct == nil then has_chafa_cli_direct = is_cmd_available("chafa") end
    return has_chafa_cli_direct
end

local has_ffmpeg = nil
local function get_has_ffmpeg()
    if has_ffmpeg == nil then
        -- ffmpeg uses the single-dash `-version` form; `--version` exits non-zero on some builds,
        -- which made the ffmpeg CLI engine look missing even when it was installed.
        local devnull = is_windows and "nul" or "/dev/null"
        local ret = os.execute("ffmpeg -version >" .. devnull .. " 2>&1")
        if not (ret == 0 or ret == true) then
            ret = os.execute("ffmpeg --version >" .. devnull .. " 2>&1")
        end
        has_ffmpeg = (ret == 0 or ret == true)
    end
    return has_ffmpeg
end

local has_mpv = nil
local function get_has_mpv()
    if has_mpv == nil then has_mpv = is_cmd_available("mpv") end
    return has_mpv
end

local function render_image_timg_cli(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
    local img, err = load_image(img_entry.filepath)
    if not img then return false, err end

    local reserved_header_rows = 5
    local max_char_h = math.max(4, term_h - reserved_header_rows)
    local max_char_w = math.max(4, term_w - 4)

    local optical_aspect = (img.width / img.height) * 2.0
    local fit_rows = max_char_h
    local fit_cols = math.max(2, math.floor(fit_rows * optical_aspect))
    if fit_cols > max_char_w then
        fit_cols = max_char_w
        fit_rows = math.max(2, math.floor(fit_cols / optical_aspect))
    end

    local devnull = is_windows and "nul" or "/dev/null"
    local cmd = string.format("timg -g %dx%d --no-tmux-check %q 2>%s", fit_cols, fit_rows, img_entry.filepath, devnull)
    local p = io.popen(cmd, "r")
    local text = p and p:read("*a")
    if p then p:close() end

    if not text or #text == 0 then
        local cmd2 = string.format("timg -g %dx%d %q 2>%s", fit_cols, fit_rows, img_entry.filepath, devnull)
        local p2 = io.popen(cmd2, "r")
        if p2 then
            text = p2:read("*a")
            p2:close()
        end
    end

    if not text or #text == 0 then
        return false, "timg CLI produced empty output"
    end

    local rendered_lines = {}
    for l in text:gmatch("([^\n]*)\n?") do
        if #l > 0 then table.insert(rendered_lines, l) end
    end

    local pad_left = math.max(0, math.floor((term_w - fit_cols) / 2))
    local pad_top  = math.max(0, math.floor((max_char_h - #rendered_lines) / 2))
    local pad      = string.rep(" ", pad_left)

    local out = {}
    local bar_len = math.max(20, term_w - 4)
    table.insert(out, "\27[H\27[2J")
    table.insert(out, "\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, to_display_text(img_entry.filename)))
    local date_disp, date_src = get_image_timestamp(img_entry)
    local date_info = (date_src == "EXIF" or date_src == "tIME") and (date_disp .. " (" .. date_src .. ")") or (date_src == "File" and (date_disp .. " (File)") or date_disp)
    local disp_path = to_display_text(img_entry.filepath)
    local path_cols = math.max(15, term_w - 60)
    if display_width(disp_path) > path_cols then disp_path = utf8_tail(disp_path, path_cols) end
    local eng_prefix = (cur_e and total_e) and string.format("[%d/%d] ", cur_e, total_e) or ""
    table.insert(out, string.format("  \27[90mSize: %s | Original: %dx%d | Date: %s | Engine: %s\27[1;96mtimg (External CLI)\27[90m | Path: %s\27[0m\n",
        img_entry.size_str, img.width, img.height, date_info, eng_prefix, disp_path))
    local cycle_hint = total_e and string.format("  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine (%d available)  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n", total_e)
        or "  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n"
    table.insert(out, cycle_hint)
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    if pad_top > 0 then table.insert(out, string.rep("\n", pad_top)) end
    for _, l in ipairs(rendered_lines) do
        table.insert(out, pad .. l .. "\27[0m\n")
    end

    io.write(table.concat(out))
    io.flush()
    return true
end

local function render_image_chafa_cli_direct(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
    local img, err = load_image(img_entry.filepath)
    if not img then return false, err end

    local reserved_header_rows = 6
    local max_char_h = math.max(4, term_h - reserved_header_rows)
    local max_char_w = math.max(4, term_w - 4)

    local optical_aspect = (img.width / img.height) * 2.0
    local fit_rows = max_char_h
    local fit_cols = math.max(2, math.floor(fit_rows * optical_aspect))
    if fit_cols > max_char_w then
        fit_cols = max_char_w
        fit_rows = math.max(2, math.floor(fit_cols / optical_aspect))
    end

    local devnull = is_windows and "nul" or "/dev/null"
    local cmd = string.format("chafa -f symbols -s %dx%d -c full %q 2>%s", fit_cols, fit_rows, img_entry.filepath, devnull)
    local p = io.popen(cmd, "r")
    if not p then return false, "Failed to invoke chafa CLI" end
    local text = p:read("*a")
    p:close()

    if not text or #text == 0 then
        return false, "chafa CLI produced empty output"
    end

    local rendered_lines = {}
    for l in text:gmatch("([^\n]*)\n?") do
        local vis = l:gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("\r", "")
        if #vis > 0 then table.insert(rendered_lines, l) end
    end

    local pad_left = math.max(0, math.floor((term_w - fit_cols) / 2))
    local pad_top  = math.max(0, math.floor((max_char_h - #rendered_lines) / 2))
    local pad      = string.rep(" ", pad_left)

    local out = {}
    local bar_len = math.max(20, term_w - 4)
    table.insert(out, "\27[H\27[2J")
    table.insert(out, "\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, to_display_text(img_entry.filename)))
    local date_disp, date_src = get_image_timestamp(img_entry)
    local date_info = (date_src == "EXIF" or date_src == "tIME") and (date_disp .. " (" .. date_src .. ")") or (date_src == "File" and (date_disp .. " (File)") or date_disp)
    local disp_path = to_display_text(img_entry.filepath)
    local path_cols = math.max(15, term_w - 60)
    if display_width(disp_path) > path_cols then disp_path = utf8_tail(disp_path, path_cols) end
    local eng_prefix = (cur_e and total_e) and string.format("[%d/%d] ", cur_e, total_e) or ""
    table.insert(out, string.format("  \27[90mSize: %s | Original: %dx%d | Date: %s | Engine: %s\27[1;95mChafa (External CLI)\27[90m | Path: %s\27[0m\n",
        img_entry.size_str, img.width, img.height, date_info, eng_prefix, disp_path))
    local cycle_hint = total_e and string.format("  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine (%d available)  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n", total_e)
        or "  \27[93m[←/P]\27[0m Prev  \27[93m[→/N]\27[0m Next  \27[1;96m[t]\27[0m Cycle Engine  \27[1;92m[Enter/B]\27[0m Back  \27[91m[Q]\27[0m Quit\n"
    table.insert(out, cycle_hint)
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    if pad_top > 0 then table.insert(out, string.rep("\n", pad_top)) end
    for _, l in ipairs(rendered_lines) do
        table.insert(out, pad .. l .. "\27[0m\n")
    end

    io.write(table.concat(out))
    io.flush()
    return true
end

-- =========================================================================
-- 6. Kitty Graphics Protocol & Fallback Truecolor Renderer
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

-- Detect terminal graphics protocol support: "kitty", "iterm", "wezterm", or "halfblock"
local function detect_terminal_graphics(force_mode)
    if force_mode == "kitty" then return "kitty" end
    if force_mode == "iterm" then return "iterm" end
    if force_mode == "halfblock" then return "halfblock" end

    -- Direct environment variable checks
    local term = (os.getenv("TERM") or ""):lower()
    local term_prog = (os.getenv("TERM_PROGRAM") or ""):lower()
    local kitty_pid = os.getenv("KITTY_PID")
    local ghostty_res = os.getenv("GHOSTTY_RESOURCES_DIR")
    local wezterm_pane = os.getenv("WEZTERM_PANE")

    -- Kitty and Ghostty strictly support Kitty graphics protocol (NOT iTerm2 inline image protocol).
    if kitty_pid or term:find("kitty") or ghostty_res or term_prog:find("ghostty") then
        return "kitty"
    end

    -- WezTerm supports both Kitty protocol and iTerm2 protocol
    if wezterm_pane or term_prog:find("wezterm") then
        return "wezterm"
    end

    -- iTerm2 native inline protocol
    if term_prog:find("iterm") then
        return "iterm"
    end

    -- If inside tmux, query the outer terminal client type
    if is_inside_tmux() then
        local p = io.popen("tmux display-message -p '#{client_termname} #{client_termtype}' 2>/dev/null", "r")
        if p then
            local client_info = (p:read("*a") or ""):lower()
            p:close()
            if client_info:find("kitty") or client_info:find("ghostty") then
                return "kitty"
            elseif client_info:find("wezterm") then
                return "wezterm"
            elseif client_info:find("iterm") then
                return "iterm"
            end
        end
    end

    return "halfblock"
end

local function detect_kitty_support(force_mode)
    local g = detect_terminal_graphics(force_mode)
    return g == "kitty" or g == "wezterm"
end

-- Clear any Kitty graphics rendered on screen
local function kitty_clear_screen()
    write_raw_terminal_seq("\27_Ga=d,d=a\27\\")
    io.flush()
end

-- Render image using Kitty Graphics Protocol
local function render_image_kitty(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
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
        local pipe = io.popen(cmd, POPEN_READ_BIN)
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

    -- Quick image dimension detection for Kitty
    local img_w, img_h = rgb_w, rgb_h
    if is_direct_png and #png_data >= 24 and png_data:sub(1, 8) == "\137PNG\r\n\026\n" then
        img_w = png_data:byte(17)*16777216 + png_data:byte(18)*65536 + png_data:byte(19)*256 + png_data:byte(20)
        img_h = png_data:byte(21)*16777216 + png_data:byte(22)*65536 + png_data:byte(23)*256 + png_data:byte(24)
    end
    if img_w <= 0 or img_h <= 0 then
        local fi = load_image(img_entry.filepath)
        if fi then img_w, img_h = fi.width, fi.height end
    end
    local iw = (img_w > 0) and img_w or 800
    local ih = (img_h > 0) and img_h or 600

    local reserved_header_rows = 7
    local max_rows = math.max(4, term_h - reserved_header_rows - 1)
    local max_cols = math.max(10, term_w - 4)

    -- Calculate aspect-preserving dimensions that fit within the window
    local optical_aspect = (iw / ih) * 2.0
    local fit_rows = max_rows
    local fit_cols = math.max(2, math.floor(fit_rows * optical_aspect))
    if fit_cols > max_cols then
        fit_cols = max_cols
        fit_rows = math.max(2, math.floor(fit_cols / optical_aspect))
    end

    -- 2D Centering (Horizontal and Vertical)
    local pad_left = math.max(0, math.floor((term_w - fit_cols) / 2))
    local pad_top = math.max(0, math.floor((max_rows - fit_rows) / 2))
    local pad = string.rep(" ", pad_left)

    -- Header
    local bar_len = math.max(20, term_w - 4)
    io.write("\27[H\27[2J") -- Clear screen & home cursor
    kitty_clear_screen()

    io.write("\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    io.write(string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, to_display_text(img_entry.filename)))
    local date_disp, date_src = get_image_timestamp(img_entry)
    local date_info = (date_src == "EXIF" or date_src == "tIME") and (date_disp .. " (" .. date_src .. ")") or (date_src == "File" and (date_disp .. " (File)") or date_disp)
    local disp_path = to_display_text(img_entry.filepath)
    local path_cols = math.max(15, term_w - 60)
    if display_width(disp_path) > path_cols then disp_path = utf8_tail(disp_path, path_cols) end
    local eng_prefix = (cur_e and total_e) and string.format("[%d/%d] ", cur_e, total_e) or ""
    io.write(string.format("  \27[90mSize: %s | Original: %dx%d | Date: %s | Engine: %s\27[1;95mKitty Graphics Protocol\27[90m | Path: %s\27[0m\n",
        img_entry.size_str, iw, ih, date_info, eng_prefix, disp_path))
    local cycle_hint = total_e and string.format("  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;96m[t]\27[0m Cycle Engine (%d available)   \27[1;92m[Enter/B]\27[0m Back   \27[91m[Q]\27[0m Quit\n", total_e)
        or "  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;96m[t]\27[0m Cycle Engine   \27[1;92m[Enter/B]\27[0m Back   \27[91m[Q]\27[0m Quit\n"
    io.write(cycle_hint)
    io.write("\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")
    if pad_top > 0 then io.write(string.rep("\n", pad_top)) end

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
                write_raw_terminal_seq(pad .. string.format("\27_Gf=100,a=T,c=%d,r=%d,m=%d;%s\27\\", fit_cols, fit_rows, has_more, chunk))
            else
                -- Raw 24-bit RGB transmission (f=24)
                write_raw_terminal_seq(pad .. string.format("\27_Gf=24,s=%d,v=%d,a=T,c=%d,r=%d,m=%d;%s\27\\", rgb_w, rgb_h, fit_cols, fit_rows, has_more, chunk))
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
local function render_image_halfblock(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
    local img, err = load_image(img_entry.filepath)
    if not img then
        return false, err
    end

    local out = {}
    table.insert(out, "\27[H\27[2J") -- Clear screen & home cursor

    -- Top header bar
    local bar_len = math.max(20, term_w - 4)
    table.insert(out, "\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, to_display_text(img_entry.filename)))
    local date_disp, date_src = get_image_timestamp(img_entry)
    local date_info = (date_src == "EXIF" or date_src == "tIME") and (date_disp .. " (" .. date_src .. ")") or (date_src == "File" and (date_disp .. " (File)") or date_disp)
    local disp_path = to_display_text(img_entry.filepath)
    local path_cols = math.max(15, term_w - 60)
    if display_width(disp_path) > path_cols then disp_path = utf8_tail(disp_path, path_cols) end
    local eng_prefix = (cur_e and total_e) and string.format("[%d/%d] ", cur_e, total_e) or ""
    table.insert(out, string.format("  \27[90mSize: %s | Original: %dx%d | Date: %s | Engine: %s\27[1;92mANSI 24-bit Truecolor Half-Block (▄)\27[90m | Path: %s\27[0m\n",
        img_entry.size_str, img.width, img.height, date_info, eng_prefix, disp_path))
    local cycle_hint = total_e and string.format("  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;96m[t]\27[0m Cycle Engine (%d available)   \27[1;92m[Enter/B]\27[0m Back   \27[91m[Q]\27[0m Quit\n", total_e)
        or "  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;96m[t]\27[0m Cycle Engine   \27[1;92m[Enter/B]\27[0m Back   \27[91m[Q]\27[0m Quit\n"
    table.insert(out, cycle_hint)
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    -- Calculate render scale to fit window while preserving original aspect ratio.
    local reserved_header_rows = 7
    local max_char_h = math.max(4, term_h - reserved_header_rows)
    local target_w = math.max(10, term_w - 4)
    local target_h = max_char_h * 2 -- 2 vertical pixels per text row

    -- Character cell aspect ratio correction: terminal font height/width ~ 2.0
    local optical_aspect = (img.width / img.height) * 2.0
    local out_h, out_w
    if img.height > target_h or math.floor((img.height / 2) * optical_aspect) > target_w then
        out_h = target_h
        out_w = math.max(2, math.floor((out_h / 2) * optical_aspect))
        if out_w > target_w then
            out_w = target_w
            out_h = math.max(2, math.floor((out_w / optical_aspect) * 2))
        end
    else
        out_h = img.height
        out_w = math.max(2, math.floor((out_h / 2) * optical_aspect))
        if out_w > target_w then
            out_w = target_w
            out_h = math.max(2, math.floor((out_w / optical_aspect) * 2))
        end
    end

    if out_h > target_h then out_h = target_h end
    if out_h % 2 ~= 0 then out_h = out_h - 1 end
    if out_h < 2 then out_h = 2 end

    -- 2D Centering
    local pad_left = math.max(0, math.floor((term_w - out_w) / 2))
    local pad = string.rep(" ", pad_left)
    local pad_top = math.max(0, math.floor((max_char_h - math.floor(out_h / 2)) / 2))

    if pad_top > 0 then
        table.insert(out, string.rep("\n", pad_top))
    end

    local px = img.pixels
    local iw = img.width

    for y = 0, out_h - 1, 2 do
        local line = { pad }
        local last_top_r, last_top_g, last_top_b = -1, -1, -1
        local last_bot_r, last_bot_g, last_bot_b = -1, -1, -1
        for x = 0, out_w - 1 do
            local src_x = math.min(img.width - 1, math.floor(x * (img.width / out_w)))
            local src_y_top = math.min(img.height - 1, math.floor(y * (img.height / out_h)))
            local src_y_bot = math.min(img.height - 1, math.floor((y + 1) * (img.height / out_h)))

            local top = px[src_y_top * iw + src_x]
            local bot = px[src_y_bot * iw + src_x]
            local tr, tg, tb = top.r, top.g, top.b
            local br, bg, bb = bot.r, bot.g, bot.b

            if tr ~= last_top_r or tg ~= last_top_g or tb ~= last_top_b then
                table.insert(line, string.format("\27[48;2;%d;%d;%dm", tr, tg, tb))
                last_top_r, last_top_g, last_top_b = tr, tg, tb
            end
            if br ~= last_bot_r or bg ~= last_bot_g or bb ~= last_bot_b then
                table.insert(line, string.format("\27[38;2;%d;%d;%dm", br, bg, bb))
                last_bot_r, last_bot_g, last_bot_b = br, bg, bb
            end
            table.insert(line, "▄")
        end
        table.insert(line, "\27[0m\n")
        table.insert(out, table.concat(line))
    end

    io.write(table.concat(out))
    io.flush()
    return true
end

-- Render image using iTerm2 Graphics Protocol (widely supported by WezTerm, iTerm2, and tmux)
local function render_image_iterm2(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
    local f = io.open(img_entry.filepath, "rb")
    if not f then return false, "Cannot open image file" end
    local raw_data = f:read("*all")
    f:close()

    local ext = img_entry.extension:lower()
    if ext == "ppm" or raw_data:sub(1, 2) == "P6" or raw_data:sub(1, 2) == "P3" then
        -- iTerm2 inline image protocol does not support Netpbm PPM. Convert to PNG if possible.
        local devnull = is_windows and "nul" or "/dev/null"
        local cmd = string.format("magick %q png:- 2>%s || convert %q png:- 2>%s || ffmpeg -v error -i %q -f image2pipe -vcodec png - 2>%s",
            img_entry.filepath, devnull, img_entry.filepath, devnull, img_entry.filepath, devnull)
        local pipe = io.popen(cmd, POPEN_READ_BIN)
        if pipe then
            local converted = pipe:read("*all")
            pipe:close()
            if converted and #converted > 0 then
                raw_data = converted
            else
                return false, "PPM format not supported by iTerm2 protocol without ImageMagick/ffmpeg"
            end
        else
            return false, "PPM format not supported by iTerm2 protocol"
        end
    end

    local b64 = base64_encode(raw_data)
    local reserved_header_rows = 7
    local max_rows = math.max(4, term_h - reserved_header_rows - 1)
    local max_cols = math.max(10, term_w - 4)

    -- Quick image dimension detection
    local img_w, img_h = 0, 0
    if raw_data and #raw_data >= 24 and raw_data:sub(1, 8) == "\137PNG\r\n\026\n" then
        img_w = raw_data:byte(17)*16777216 + raw_data:byte(18)*65536 + raw_data:byte(19)*256 + raw_data:byte(20)
        img_h = raw_data:byte(21)*16777216 + raw_data:byte(22)*65536 + raw_data:byte(23)*256 + raw_data:byte(24)
    end
    if img_w <= 0 or img_h <= 0 then
        local fi = load_image(img_entry.filepath)
        if fi then img_w, img_h = fi.width, fi.height end
    end
    local iw = (img_w > 0) and img_w or 800
    local ih = (img_h > 0) and img_h or 600

    local optical_aspect = (iw / ih) * 2.0
    local fit_rows = max_rows
    local fit_cols = math.max(2, math.floor(fit_rows * optical_aspect))
    if fit_cols > max_cols then
        fit_cols = max_cols
        fit_rows = math.max(2, math.floor(fit_cols / optical_aspect))
    end

    local pad_left = math.max(0, math.floor((term_w - fit_cols) / 2))
    local pad_top = math.max(0, math.floor((max_rows - fit_rows) / 2))
    local pad = string.rep(" ", pad_left)

    local bar_len = math.max(20, term_w - 4)
    io.write("\27[H\27[2J") -- Clear screen & home cursor
    kitty_clear_screen()

    io.write("\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    io.write(string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, to_display_text(img_entry.filename)))
    local date_disp, date_src = get_image_timestamp(img_entry)
    local date_info = (date_src == "EXIF" or date_src == "tIME") and (date_disp .. " (" .. date_src .. ")") or (date_src == "File" and (date_disp .. " (File)") or date_disp)
    local disp_path = to_display_text(img_entry.filepath)
    local path_cols = math.max(15, term_w - 60)
    if display_width(disp_path) > path_cols then disp_path = utf8_tail(disp_path, path_cols) end
    local eng_prefix = (cur_e and total_e) and string.format("[%d/%d] ", cur_e, total_e) or ""
    io.write(string.format("  \27[90mSize: %s | Original: %dx%d | Date: %s | Engine: %s\27[1;94miTerm2 Inline Protocol\27[90m | Path: %s\27[0m\n",
        img_entry.size_str, iw, ih, date_info, eng_prefix, disp_path))
    local cycle_hint = total_e and string.format("  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;96m[t]\27[0m Cycle Engine (%d available)   \27[1;92m[Enter/B]\27[0m Back   \27[91m[Q]\27[0m Quit\n", total_e)
        or "  \27[93m[←/P/PgUp]\27[0m Prev   \27[93m[→/N/PgDn]\27[0m Next   \27[1;96m[t]\27[0m Cycle Engine   \27[1;92m[Enter/B]\27[0m Back   \27[91m[Q]\27[0m Quit\n"
    io.write(cycle_hint)
    io.write("\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")
    if pad_top > 0 then io.write(string.rep("\n", pad_top)) end

    local iterm_seq = string.format("\27]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1:%s\007\n",
        fit_cols, fit_rows, b64)
    write_raw_terminal_seq(pad .. iterm_seq)
    io.flush()
    return true
end

-- Available Render Engines Definition & Dynamic Detection
local RENDER_ENGINES = {
    { id = "truecolor",     name = "ANSI 24-bit Truecolor Half-Block", short_name = "Truecolor",     is_available = function() return true end },
    { id = "timg-half",     name = "timg Half-Block",                  short_name = "timg Half",     is_available = function() return true end },
    { id = "timg-quarter",  name = "timg Quarter-Block",               short_name = "timg Quarter",  is_available = function() return true end },
    { id = "timg-cli",      name = "timg CLI Engine",                  short_name = "timg CLI",      is_available = function() return get_has_timg_cli() end },
    { id = "chafa",         name = "Chafa Symbols",                    short_name = "Chafa Symbol",  is_available = function() return true end },
    { id = "chafa-braille", name = "Chafa Braille",                    short_name = "Chafa Braille", is_available = function() return true end },
    { id = "chafa-cli",     name = "Chafa CLI Engine",                 short_name = "Chafa CLI",     is_available = function() return get_has_chafa_cli_direct() end },
    { id = "kitty",         name = "Kitty Protocol",                   short_name = "Kitty Proto",   is_available = function() return detect_kitty_support() end },
    { id = "iterm",         name = "iTerm2 Protocol",                  short_name = "iTerm2 Proto",  is_available = function()
        local g = detect_terminal_graphics()
        return g == "iterm" or g == "wezterm"
    end },
}

local function normalize_protocol(protocol)
    protocol = protocol or "truecolor"
    if protocol == "halfblock" then return "truecolor" end
    if protocol == "quarter" then return "timg-quarter" end
    if protocol == "chafa-symbols" then return "chafa" end
    if protocol == "braille" then return "chafa-braille" end
    if protocol == "iterm2" then return "iterm" end
    return protocol
end

local function get_available_engines()
    local available = {}
    for _, eng in ipairs(RENDER_ENGINES) do
        if eng.is_available() then
            table.insert(available, eng)
        end
    end
    return available
end

local function get_engine_position(protocol)
    protocol = normalize_protocol(protocol)
    local avail = get_available_engines()
    for idx, eng in ipairs(avail) do
        if eng.id == protocol then
            return idx, #avail
        end
    end
    return 1, #avail
end

local function cycle_next_engine(current_protocol)
    local avail = get_available_engines()
    if #avail == 0 then return "truecolor" end
    current_protocol = normalize_protocol(current_protocol)

    local cur_idx = nil
    for idx, eng in ipairs(avail) do
        if eng.id == current_protocol then
            cur_idx = idx
            break
        end
    end

    if not cur_idx then
        return avail[1].id
    end

    local next_idx = (cur_idx % #avail) + 1
    return avail[next_idx].id
end

-- Unified image renderer: Dispatches to the selected protocol.
-- Supported protocols: "truecolor" | "timg-half" | "timg-quarter" | "timg-cli" | "chafa" | "chafa-braille" | "chafa-cli" | "kitty" | "iterm"
local function render_image_screen(img_entry, current_idx, total_count, protocol)
    local term_w, term_h = get_terminal_size()
    protocol = protocol or "truecolor"
    local cur_e, total_e = get_engine_position(protocol)

    if protocol == "kitty" then
        local ok = render_image_kitty(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
        if ok then return true end
    elseif protocol == "iterm" then
        local ok = render_image_iterm2(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
        if ok then return true end
    elseif protocol == "timg-cli" then
        if get_has_timg_cli() then
            local ok = render_image_timg_cli(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
            if ok then return true end
        end
        -- fallback to native timg
        local ok = render_image_unicode_block(img_entry, current_idx, total_count, term_w, term_h, false, cur_e, total_e)
        if ok then return true end
    elseif protocol == "chafa-cli" then
        if get_has_chafa_cli_direct() then
            local ok = render_image_chafa_cli_direct(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
            if ok then return true end
        end
        -- fallback to chafa symbols / braille
        local ok = render_image_chafa(img_entry, current_idx, total_count, term_w, term_h, "symbols", cur_e, total_e)
        if ok then return true end
    elseif protocol == "chafa-braille" or protocol == "braille" then
        local ok = render_image_chafa(img_entry, current_idx, total_count, term_w, term_h, "braille", cur_e, total_e)
        if ok then return true end
    elseif protocol == "chafa" or protocol == "chafa-symbols" then
        local ok = render_image_chafa(img_entry, current_idx, total_count, term_w, term_h, "symbols", cur_e, total_e)
        if ok then return true end
    elseif protocol == "timg-quarter" or protocol == "quarter" then
        -- timg -p q  (quarter-block, 2x2 pixels per cell, linear-space avd minimisation, aspect-corrected)
        local ok, err = render_image_unicode_block(img_entry, current_idx, total_count, term_w, term_h, true, cur_e, total_e)
        if ok then return true end
    elseif protocol == "timg-half" then
        -- timg -p h  (half-block, linear-space area-average)
        local ok, err = render_image_unicode_block(img_entry, current_idx, total_count, term_w, term_h, false, cur_e, total_e)
        if ok then return true end
    end

    -- Default: Original ANSI 24-bit Truecolor Half-Block (▄) renderer
    return render_image_halfblock(img_entry, current_idx, total_count, term_w, term_h, cur_e, total_e)
end

-- =========================================================================
-- 5j. Video Player Engine (LuaJIT FFI In-Memory & FFmpeg Stream Pipeline)
-- =========================================================================
local function render_video_progress_bar(cur_sec, total_sec, bar_w)
    bar_w = math.max(10, bar_w or 30)
    local frac = (total_sec > 0) and math.min(1.0, math.max(0.0, cur_sec / total_sec)) or 0
    local pos = math.floor(frac * (bar_w - 1)) + 1
    local bar = {}
    for i = 1, bar_w do
        if i == pos then
            table.insert(bar, "●")
        elseif i < pos then
            table.insert(bar, "━")
        else
            table.insert(bar, "─")
        end
    end
    return table.concat(bar)
end

local function render_video_frame_halfblock(raw_bytes, frame_w, frame_h, pad, row_start)
    local fit_rows = math.floor(frame_h / 2)
    local out = {}
    table.insert(out, string.format("\27[%d;1H", row_start))

    local last_fg = nil
    local last_bg = nil
    local row_stride = frame_w * 3

    for y = 0, fit_rows - 1 do
        table.insert(out, pad)
        local top_row_off = (y * 2) * row_stride
        local bot_row_off = (y * 2 + 1) * row_stride

        for x = 0, frame_w - 1 do
            local tp = top_row_off + x * 3 + 1
            local bp = bot_row_off + x * 3 + 1
            local tr, tg, tb = raw_bytes:byte(tp, tp + 2)
            local br, bg, bb = raw_bytes:byte(bp, bp + 2)

            local fg = (br * 65536) + (bg * 256) + bb
            local bg_c = (tr * 65536) + (tg * 256) + tb

            if bg_c ~= last_bg then
                table.insert(out, string.format("\27[48;2;%d;%d;%dm", tr, tg, tb))
                last_bg = bg_c
            end
            if fg ~= last_fg then
                table.insert(out, string.format("\27[38;2;%d;%d;%dm", br, bg, bb))
                last_fg = fg
            end
            table.insert(out, "▄")
        end
        if y < fit_rows - 1 then
            table.insert(out, "\27[0m\27[K\n")
        else
            table.insert(out, "\27[0m\27[K")
        end
        last_fg = nil
        last_bg = nil
    end

    io.write(table.concat(out))
    io.flush()
end

-- Video play engines, in cycle order. [m] in the video player walks the detected ones.
--   ffi    : in-process LuaJIT FFI decode (libavformat / libavcodec / libswscale)
--   ffmpeg : external ffmpeg CLI raw-frame (rgb24) pipeline
--   mpv    : hand-off to mpv's own terminal player (separate process, real audio)
local VIDEO_PLAY_ENGINES = {
    { id = "ffi",    name = "LuaJIT FFI (libavcodec)",         is_available = function() return has_ffi_video() end },
    { id = "ffmpeg", name = "FFmpeg CLI (rgb24 pipe)",         is_available = function() return get_has_ffmpeg() end },
    { id = "mpv",    name = "mpv --vo=tct (hand-off, audio)",  is_available = function() return get_has_mpv() end },
}

local function get_available_play_engines()
    local available = {}
    for _, eng in ipairs(VIDEO_PLAY_ENGINES) do
        if eng.is_available() then
            table.insert(available, eng)
        end
    end
    return available
end

local function get_play_engine_name(engine_id)
    for _, eng in ipairs(VIDEO_PLAY_ENGINES) do
        if eng.id == engine_id then return eng.name end
    end
    return "Unknown engine"
end

local function get_play_engine_position(engine_id)
    local available = get_available_play_engines()
    for idx, eng in ipairs(available) do
        if eng.id == engine_id then
            return idx, #available
        end
    end
    return 1, #available
end

local function cycle_play_engine(engine_id)
    local available = get_available_play_engines()
    if #available == 0 then return engine_id end
    for idx, eng in ipairs(available) do
        if eng.id == engine_id then
            return available[(idx % #available) + 1].id
        end
    end
    return available[1].id
end

-- In-TUI engines: prefer native FFI decode, then the ffmpeg CLI pipe. nil when neither exists.
local function resolve_inline_play_engine()
    if has_ffi_video() then return "ffi" end
    if get_has_ffmpeg() then return "ffmpeg" end
    return nil
end

-- Default: first inline engine so [m] cycling is usable right away; mpv only when it is all we have.
local function default_play_engine()
    return resolve_inline_play_engine() or "mpv"
end

local video_play_engine = default_play_engine()

-- mpv's own log is muted with --msg-level=all=no, but library dependencies (libvdpau, VA-API,
-- mesa, fontconfig) write raw diagnostics straight to stderr, e.g.
--   Failed to open VDPAU backend libvdpau_nvidia.so: cannot open shared object file
-- Those cannot be suppressed by mpv options, and they land on the main screen because the
-- alternate buffer is released while mpv owns the terminal. Capture them to a log instead and
-- surface the tail only when mpv actually fails; tct frames are drawn on stdout, so playback
-- is unaffected by the redirect.
local function get_mpv_stderr_log_path()
    local tmpdir = is_windows and (os.getenv("TEMP") or ".") or (os.getenv("TMPDIR") or "/tmp")
    return tmpdir .. (is_windows and "\\" or "/") .. "pix_mpv_stderr.log"
end

local function show_mpv_failure(log_path, status)
    io.write("\27[H\27[2J")
    io.write(string.format("\27[1;31m  ⚠ mpv exited with status %s\27[0m\n\n", tostring(status)))

    local tail = {}
    local f = io.open(log_path, "r")
    if f then
        for line in f:lines() do
            line = line:gsub("[\r\n]+$", "")
            if #line > 0 then
                table.insert(tail, line:sub(1, 200))
                if #tail > 5 then table.remove(tail, 1) end
            end
        end
        f:close()
    end

    if #tail == 0 then
        io.write("  \27[90m(no diagnostics captured)\27[0m\n")
    else
        for _, line in ipairs(tail) do
            io.write("  \27[90m" .. line .. "\27[0m\n")
        end
    end
    io.write("\n  \27[93mPress any key to return to the player...\27[0m")
    io.flush()
    read_key()
end

local function launch_mpv_tct(filepath, seek_sec)
    io.write("\27[?25h\27[0m") -- show cursor, reset attrs
    io.flush()
    local term_w, term_h = get_terminal_size()
    local seek_part = (seek_sec and seek_sec > 0) and string.format(" --start=%.2f", seek_sec) or ""
    local mpv_log = get_mpv_stderr_log_path()
    local stderr_part = is_windows and " 2>nul" or (" 2>" .. string.format("%q", mpv_log))
    local mpv_cmd = string.format(
        'mpv --vo=tct --vo-tct-width=%d --vo-tct-height=%d'
        .. ' --term-osd-bar'
        .. ' --msg-level=all=no'
        .. ' --term-status-msg="  ${filename}  ${playback-time} / ${duration} (${percent-pos}%%)  Speed: ${speed}x"'
        .. '%s %q%s',
        math.max(4, term_w), math.max(4, term_h - 3),
        seek_part, filepath, stderr_part)

    local ret
    if is_windows then
        ret = os.execute(mpv_cmd)
    else
        disable_raw_mode()
        ret = os.execute(mpv_cmd)
        enable_raw_mode()
    end
    io.write("\27[H\27[2J\27[?25l") -- clear screen, hide cursor
    io.flush()

    if not is_windows then
        if not (ret == 0 or ret == true) then
            local status = (type(ret) == "number") and math.floor(ret / 256) or ret
            show_mpv_failure(mpv_log, status)
        end
        os.remove(mpv_log)
    end
end

local function play_video_screen(img_entry, current_idx, total_count, protocol)
    local inline_engine = resolve_inline_play_engine()

    -- mpv is a hand-off engine: it owns the terminal while running, then we return to the list.
    if video_play_engine == "mpv" and get_has_mpv() then
        launch_mpv_tct(img_entry.filepath, 0)
        video_play_engine = inline_engine or "mpv"
        return "back", protocol
    end

    local use_ffi = (video_play_engine == "ffi")
    if not inline_engine then
        io.write("\27[H\27[2J")
        io.write("\n  \27[1;31m⚠ Video Player Dependencies Not Found\27[0m\n\n")
        io.write("  Video playback requires \27[1;36mmpv\27[0m, \27[1;36mlibavcodec\27[0m FFI libraries,\n")
        io.write("  or \27[1;36mffmpeg\27[0m in your system PATH.\n")
        io.write("  Install with: \27[93msudo apt install mpv\27[0m or \27[93msudo apt install ffmpeg\27[0m\n\n")
        io.write("  \27[90mPress any key to return to gallery...\27[0m")
        io.flush()
        read_key()
        return "back", protocol
    end

    local v_info = get_video_info(img_entry.filepath)
    local fps = (v_info.fps > 0 and v_info.fps <= 120) and v_info.fps or 25
    local target_dt = 1.0 / fps

    local term_w, term_h = get_terminal_size()
    local reserved_header_rows = 5
    local max_char_h = math.max(4, term_h - reserved_header_rows - 1)
    local max_char_w = math.max(4, term_w - 4)

    local fit_cols, fit_rows
    if v_info.width > 0 and v_info.height > 0 then
        local optical_aspect = (v_info.width / v_info.height) * 2.0
        fit_rows = max_char_h
        fit_cols = math.max(2, math.floor(fit_rows * optical_aspect))
        if fit_cols > max_char_w then
            fit_cols = max_char_w
            fit_rows = math.max(2, math.floor(fit_cols / optical_aspect))
        end
    else
        fit_cols = math.min(max_char_w, 80)
        fit_rows = math.min(max_char_h, 30)
    end
    fit_rows = math.floor(fit_rows)
    local frame_w = fit_cols
    local frame_h = fit_rows * 2
    local frame_bytes = frame_w * frame_h * 3

    local pad_left = math.max(0, math.floor((term_w - fit_cols) / 2))
    local pad = string.rep(" ", pad_left)
    local bar_len = math.min(term_w - 2, 90)

    local cur_time = 0
    local is_paused = false
    local is_eof = false
    local is_loop = false
    local show_osd = true
    local playback_speed = 1.0
    local stream_reader = nil
    local stream_proc = nil

    local function close_stream()
        if stream_reader then
            stream_reader:close()
            stream_reader = nil
        end
        if stream_proc then
            pcall(function() stream_proc:close() end)
            stream_proc = nil
        end
    end

    local function open_stream(seek_sec)
        close_stream()
        seek_sec = math.max(0, seek_sec or 0)
        if v_info.duration > 0 then
            seek_sec = math.min(v_info.duration, seek_sec)
        end
        cur_time = seek_sec
        is_eof = false

        if use_ffi then
            stream_reader = create_video_reader(img_entry.filepath, frame_w, frame_h)
            if stream_reader and seek_sec > 0 then
                stream_reader:seek(seek_sec)
            end
        else
            local ss_part = (seek_sec > 0) and string.format("-ss %.2f", seek_sec) or ""
            local devnull = is_windows and "nul" or "/dev/null"
            -- stderr to devnull so decode/hwaccel warnings cannot scribble across the TUI
            local cmd = string.format('ffmpeg -nostdin -loglevel quiet %s -i %q -vf "scale=%d:%d:flags=fast_bilinear" -f rawvideo -pix_fmt rgb24 - 2>%s',
                ss_part, img_entry.filepath, frame_w, frame_h, devnull)
            stream_proc = io.popen(cmd, POPEN_READ_BIN)
        end
    end

    local function read_next_frame()
        if use_ffi then
            if not stream_reader then return nil end
            local raw, pts = stream_reader:read_frame()
            if raw then
                if pts and pts >= 0 and (v_info.duration <= 0 or pts <= v_info.duration + 5) then
                    cur_time = pts
                else
                    cur_time = cur_time + target_dt
                end
            end
            return raw
        else
            if not stream_proc then return nil end
            local raw = stream_proc:read(frame_bytes)
            if raw and #raw >= frame_bytes then
                cur_time = cur_time + target_dt
                return raw
            end
            return nil
        end
    end

    local cur_e, total_e = get_engine_position(protocol)

    local function draw_static_header()
        if not show_osd then return end
        io.write("\27[H\27[2J")
        local out = {}
        table.insert(out, "\27[1;34m" .. string.rep("═", bar_len) .. "\27[0m\n")
        local dim_str = (v_info.width > 0) and string.format("%dx%d, %.1ffps", v_info.width, v_info.height, fps) or string.format("%.1ffps", fps)
        local pe_idx, pe_total = get_play_engine_position(video_play_engine)
        table.insert(out, string.format("  \27[1;37mVIDEO PLAYER\27[0m \27[1;36m[%d/%d]\27[0m: \27[1;93m%s\27[0m \27[90m(%s, %s)\27[0m  \27[90m│\27[0m \27[1;96mEngine: %s\27[0m \27[90m[%d/%d] [m] cycle\27[0m\27[K\n",
            current_idx, total_count, to_display_text(img_entry.filename), dim_str, img_entry.size_str,
            get_play_engine_name(video_play_engine), pe_idx, pe_total))
        table.insert(out, "\n")
        local play_engine_hint = string.format("  \27[1;96m[m]\27[0m Engine (%d)", #get_available_play_engines())
        table.insert(out, string.format("  \27[93m[Space/p]\27[0m Pause  \27[93m[←/→]\27[0m ±5s  \27[93m[↑/↓]\27[0m ±60s  \27[93m[0-9]\27[0m %%  \27[93m[[/]]\27[0m Spd  \27[93m[.]\27[0m Step  \27[93m[l]\27[0m Loop  \27[93m[</>]\27[0m File%s  \27[91m[q]\27[0m Back\27[K\n", play_engine_hint))
        table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\27[K\n")
        io.write(table.concat(out))
        io.flush()
    end

    local function update_dynamic_header(measured_fps)
        if not show_osd then return end
        local status_tag
        local speed_tag = (playback_speed ~= 1.0) and string.format(" %.1fx", playback_speed) or ""
        local loop_tag = is_loop and " 🔁" or ""
        if is_eof then
            status_tag = "\27[1;91m[⏹ ENDED]\27[0m"
        elseif is_paused then
            status_tag = string.format("\27[1;93m[⏸ PAUSED%s%s]\27[0m", speed_tag, loop_tag)
        else
            status_tag = string.format("\27[1;92m[▶ PLAY%s%s]\27[0m", speed_tag, loop_tag)
        end

        local pbar_w = math.min(32, math.max(10, term_w - 48))
        local pbar = render_video_progress_bar(cur_time, v_info.duration, pbar_w)
        local time_str = string.format("%s / %s", format_video_time(cur_time), format_video_time(v_info.duration))
        local fps_str = measured_fps and string.format(" \27[90m(%.1f fps)\27[0m", measured_fps) or ""
        local eng_name = use_ffi and "LuaJIT FFI (libavcodec)" or "FFmpeg CLI"
        local eng_str = string.format(" \27[90m| [%d/%d] %s (%s)\27[0m", cur_e or 1, total_e or 1, protocol, eng_name)

        io.write(string.format("\27[3;1H  %s \27[1;37m%s\27[0m \27[90m[\27[1;36m%s\27[90m]\27[0m%s%s\27[K",
            status_tag, time_str, pbar, fps_str, eng_str))
        io.flush()
    end

    draw_static_header()
    update_dynamic_header(fps)
    open_stream(0)

    local last_frame_clock = os.clock()
    local frames_rendered = 0
    local fps_timer = os.clock()
    local current_fps = fps

    while true do
        local k = is_paused and read_key(80) or read_key(0)
        if k then
            if k == "Q" or k == "CTRL_C" then
                close_stream()
                return "quit", protocol
            elseif k == "q" or k == "ESC" or k == "b" then
                -- q backs out to the file list (like b/Esc); Q / Ctrl+C quit pix
                close_stream()
                return "back", protocol
            elseif k == ">" or k == "ENTER" or k == "PAGE_DOWN" or k == "n" then
                close_stream()
                return "next", protocol
            elseif k == "<" or k == "PAGE_UP" then
                close_stream()
                return "prev", protocol
            elseif k == "SPACE" or k == "p" then
                if is_eof then
                    cur_time = 0
                    open_stream(0)
                    is_paused = false
                    is_eof = false
                else
                    is_paused = not is_paused
                end
                update_dynamic_header(current_fps)
            elseif k and #k == 1 and k >= "0" and k <= "9" then
                local pct = tonumber(k) * 0.10
                cur_time = (v_info.duration > 0) and (v_info.duration * pct) or 0
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "RIGHT" then
                cur_time = math.min(v_info.duration > 0 and v_info.duration or (cur_time + 5), cur_time + 5)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "LEFT" or k == "h" then
                cur_time = math.max(0, cur_time - 5)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "UP" or k == "k" then
                cur_time = math.min(v_info.duration > 0 and v_info.duration or (cur_time + 60), cur_time + 60)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "DOWN" or k == "j" then
                cur_time = math.max(0, cur_time - 60)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "SHIFT_RIGHT" then
                cur_time = math.min(v_info.duration > 0 and v_info.duration or (cur_time + 1), cur_time + 1)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "SHIFT_LEFT" then
                cur_time = math.max(0, cur_time - 1)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "CTRL_RIGHT" then
                cur_time = math.min(v_info.duration > 0 and v_info.duration or (cur_time + 10), cur_time + 10)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "CTRL_LEFT" then
                cur_time = math.max(0, cur_time - 10)
                open_stream(cur_time)
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "[" then
                playback_speed = math.max(0.1, math.floor((playback_speed - 0.1) * 10 + 0.5) / 10)
                update_dynamic_header(current_fps)
            elseif k == "]" then
                playback_speed = math.min(4.0, math.floor((playback_speed + 0.1) * 10 + 0.5) / 10)
                update_dynamic_header(current_fps)
            elseif k == "{" then
                playback_speed = math.max(0.1, math.floor((playback_speed * 0.5) * 10 + 0.5) / 10)
                update_dynamic_header(current_fps)
            elseif k == "}" then
                playback_speed = math.min(4.0, math.floor((playback_speed * 2.0) * 10 + 0.5) / 10)
                update_dynamic_header(current_fps)
            elseif k == "BACKSPACE" then
                playback_speed = 1.0
                update_dynamic_header(current_fps)
            elseif k == "." then
                is_paused = true
                local raw_frame = read_next_frame()
                if raw_frame and #raw_frame >= frame_bytes then
                    render_video_frame_halfblock(raw_frame, frame_w, frame_h, pad, 6)
                    update_dynamic_header(current_fps)
                else
                    is_eof = true
                    update_dynamic_header(current_fps)
                end
            elseif k == "," then
                is_paused = true
                cur_time = math.max(0, cur_time - (target_dt * 2))
                open_stream(cur_time)
                local raw_frame = read_next_frame()
                if raw_frame and #raw_frame >= frame_bytes then
                    render_video_frame_halfblock(raw_frame, frame_w, frame_h, pad, 6)
                end
                update_dynamic_header(current_fps)
            elseif k == "l" or k == "L" then
                is_loop = not is_loop
                update_dynamic_header(current_fps)
            elseif k == "o" or k == "P" then
                show_osd = not show_osd
                if show_osd then
                    draw_static_header()
                    update_dynamic_header(current_fps)
                else
                    io.write("\27[H\27[2J")
                    io.flush()
                end
            elseif k == "r" or k == "HOME" then
                cur_time = 0
                open_stream(0)
                is_paused = false
                is_eof = false
                update_dynamic_header(current_fps)
            elseif k == "END" then
                if v_info.duration > 0 then
                    cur_time = math.max(0, v_info.duration - 1)
                    open_stream(cur_time)
                    is_eof = false
                    update_dynamic_header(current_fps)
                end
            elseif k == "t" or k == "T" then
                protocol = cycle_next_engine(protocol)
                cur_e, total_e = get_engine_position(protocol)
                update_dynamic_header(current_fps)
            elseif k == "m" or k == "M" then
                local next_engine = cycle_play_engine(video_play_engine)
                if next_engine ~= video_play_engine then
                    if next_engine == "mpv" then
                        -- Hand-off engine: mpv drives the terminal, then we resume in the ring.
                        close_stream()
                        video_play_engine = "mpv"
                        draw_static_header()
                        launch_mpv_tct(img_entry.filepath, cur_time)
                        local resume_engine = cycle_play_engine("mpv")
                        video_play_engine = (resume_engine == "mpv") and "mpv" or resume_engine
                    else
                        close_stream()
                        video_play_engine = next_engine
                    end
                    use_ffi = (video_play_engine == "ffi")
                    draw_static_header()
                    update_dynamic_header(current_fps)
                    open_stream(cur_time)
                end
            elseif k == "?" then
                local tw, th = get_terminal_size()
                render_help_modal(tw, th, protocol)
                read_key()
                draw_static_header()
                update_dynamic_header(current_fps)
            end
        end

        if not is_paused and (stream_reader or stream_proc) then
            local raw_frame = read_next_frame()
            if not raw_frame or #raw_frame < frame_bytes then
                if is_loop then
                    cur_time = 0
                    open_stream(0)
                    is_paused = false
                    is_eof = false
                    update_dynamic_header(current_fps)
                else
                    is_eof = true
                    is_paused = true
                    update_dynamic_header(current_fps)
                end
            else
                render_video_frame_halfblock(raw_frame, frame_w, frame_h, pad, 6)
                frames_rendered = frames_rendered + 1

                local now = os.clock()
                if now - fps_timer >= 1.0 then
                    current_fps = frames_rendered / (now - fps_timer)
                    frames_rendered = 0
                    fps_timer = now
                    update_dynamic_header(current_fps)
                end

                local render_dur = os.clock() - last_frame_clock
                local effective_dt = target_dt / playback_speed
                local wait_dt = effective_dt - render_dur
                if wait_dt > 0.002 then
                    sleep_ms(math.floor(wait_dt * 1000))
                end
                last_frame_clock = os.clock()
            end
        end
    end
end

-- =========================================================================
-- 6. File List Selector Screen & Help Popup
-- =========================================================================
local function render_help_modal(term_w, term_h, active_protocol)
    local avail = get_available_engines()
    local cur_p = normalize_protocol(active_protocol)

    local function get_mark(eng)
        if eng.id == cur_p then
            return "[*] "
        elseif eng.is_available() then
            return "[+] "
        else
            return "[-] "
        end
    end

    local e1 = get_mark(RENDER_ENGINES[1]) .. RENDER_ENGINES[1].short_name
    local e2 = get_mark(RENDER_ENGINES[2]) .. RENDER_ENGINES[2].short_name
    local e3 = get_mark(RENDER_ENGINES[3]) .. RENDER_ENGINES[3].short_name
    local e4 = get_mark(RENDER_ENGINES[4]) .. RENDER_ENGINES[4].short_name
    local e5 = get_mark(RENDER_ENGINES[5]) .. RENDER_ENGINES[5].short_name
    local e6 = get_mark(RENDER_ENGINES[6]) .. RENDER_ENGINES[6].short_name
    local e7 = get_mark(RENDER_ENGINES[7]) .. RENDER_ENGINES[7].short_name
    local e8 = get_mark(RENDER_ENGINES[8]) .. RENDER_ENGINES[8].short_name
    local e9 = get_mark(RENDER_ENGINES[9]) .. RENDER_ENGINES[9].short_name

    local eng_header = string.format("│  %-59s│", string.format("Detected Engines: [*] Active  [+] Ready  [-] N/A (%d Avail)", #avail))
    local eng_row1   = string.format("│    %-18s%-19s%-20s│", e1, e2, e3)
    local eng_row2   = string.format("│    %-18s%-19s%-20s│", e4, e5, e6)
    local eng_row3   = string.format("│    %-18s%-19s%-20s│", e7, e8, e9)
    local cycle_line = string.format("│    t                   Cycle render engine (%d available)     │", #avail)

    local lines = {
        "┌─────────────────────────────────────────────────────────────┐",
        "│                   KEYBOARD SHORTCUTS                        │",
        "├─────────────────────────────────────────────────────────────┤",
        "│  File Navigation (Vim / Arrows):                            │",
        "│    ↑ / k, ↓ / j        Move selection up / down             │",
        "│    h, l / o / Enter    Navigate to parent / Open item       │",
        "│    g / G               Jump to first / last item            │",
        "│    Ctrl-D / Ctrl-U     Scroll half page down / up           │",
        "│    Ctrl-F / Ctrl-B     Scroll full page down / up           │",
        "│    H / M / L           Jump to top / middle / bottom visible│",
        "│    1 - 9               Quick select item by index number    │",
        "│                                                             │",
        "│  Viewer Controls:                                           │",
        "│    l / j / → / n       Next image                           │",
        "│    h / k / ← / p       Previous image                       │",
        "│    g / G               Jump to first / last image           │",
        cycle_line,
        "│    q / Esc / b         Return to file/folder list           │",
        "│                                                             │",
        "│  Video Playback (engine & mpv shortcuts):                   │",
        "│    Space / p           Play / Pause playback                │",
        "│    ← / →               Seek ±5s                             │",
        "│    Shift+← / Shift+→   Seek ±1s (exact)                     │",
        "│    Ctrl+← / Ctrl+→     Seek ±10s                            │",
        "│    ↓ / ↑               Seek ±60s                            │",
        "│    0 - 9               Seek to 0% - 90% of duration         │",
        "│    [ / ]               Speed -10% / +10% (Backspace: 1.0x)  │",
        "│    { / }               Halve / Double playback speed        │",
        "│    . / ,               Frame step forward / backward        │",
        "│    l                   Toggle loop mode (inf / off)         │",
        "│    < / >               Previous / Next video in playlist    │",
        "│    Home / r, End       Restart from start / Seek to end     │",
        "│    o                   Toggle OSD / header visibility       │",
        "│    m                   Cycle play engine (FFI/FFmpeg/mpv)   │",
        "│    q / b / Esc         Return to the file list              │",
        "│                                                             │",
        "│  Search & Sorting:                                          │",
        "│    /                   Start live search / filter query     │",
        "│    Esc                 Clear active search / exit search    │",
        "│    s                   Cycle sort (Name -> Date -> Size)    │",
        "│    r                   Reverse sort direction (Asc / Desc)  │",
        "│    i                   Cycle icons: Unicode / Nerd / Off    │",
        "│    .                   Toggle hidden files / folders (.dot) │",
        "│                                                             │",
        eng_header,
        eng_row1,
        eng_row2,
        eng_row3,
        "│                                                             │",
        "│  General:                                                   │",
        "│    ?                   Toggle this help window              │",
        "│    q / Q / Ctrl+C      Quit pix from the file list          │",
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

local function render_file_list(dir_path, images, total_unfiltered, selected_idx, page_offset, msg, search_mode, search_query, sort_mode, sort_desc, recursive, icon_mode, show_hidden)
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
    local hidden_tag = show_hidden
        and "   \27[1;96m[.]\27[0m \27[90mHidden: \27[1;92mON\27[0m"
        or "   \27[1;96m[.]\27[0m \27[90mHidden: \27[90mOFF\27[0m"
    table.insert(out, string.format("  \27[90mDir:\27[0m \27[1;33m%s\27[0m \27[90m(%d total, %s)\27[0m%s\n", to_display_text(dir_path), total_unfiltered, scan_type, hidden_tag))

    if search_mode then
        table.insert(out, string.format("  \27[1;97;44m SEARCH: \27[0m \27[1;93m%s_\27[0m \27[90m(Type to filter, Enter to select, Esc to cancel)\27[0m\n", to_display_text(search_query)))
    elseif #search_query > 0 then
        table.insert(out, string.format("  \27[90mFilter: \27[1;93m'%s'\27[0m \27[90m(%d matches) [Esc/ / to clear]\27[0m   \27[93m[?]\27[0m Help   \27[91m[Q]\27[0m Quit\n", to_display_text(search_query), #images))
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
            table.insert(out, string.format("  \27[1;33mNo image files match query '%s'\27[0m\n", to_display_text(search_query)))
            table.insert(out, "  Press [Esc] to clear search filter.\n\n")
        else
            table.insert(out, string.format("  \27[1;31mNo supported images found in %s\27[0m\n", to_display_text(dir_path)))
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

    local filename_hdr = "FILENAME" .. string.rep(" ", math.max(0, col2_w - 8))
    table.insert(out, string.format("  \27[1;37m%-6s %s %-8s %-12s %-12s\27[0m\n",
        "INDEX", filename_hdr, "FORMAT", "SIZE", "DATE"))
    table.insert(out, "  \27[90m" .. string.rep("─", math.min(bar_len - 2, col1_w + col2_w + col3_w + col4_w + col5_w + 4)) .. "\27[0m\n")

    for i = page_start, page_end do
        local img = images[i]
        local is_sel = (i == selected_idx)
        local icon = get_file_icon(img.extension, icon_mode)
        local icon_prefix = (icon ~= "") and (icon .. " ") or ""
        -- Measure the icon as well: emoji, nerd-font glyphs and the unicode set (where some
        -- entries carry their own trailing space) are not all the same width, so a fixed
        -- allowance left every PNG/DIR/GIF row one column out.
        local icon_cols = display_width(icon_prefix)
        local max_fn_w = col2_w - icon_cols
        -- Names arrive from the OS in its own encoding (ANSI on Windows) and may be wide (CJK),
        -- so transcode for the UTF-8 console and measure/cut by display columns, not bytes.
        local fn = utf8_truncate(to_display_text(img.filename), max_fn_w)

        local display_fn = icon_prefix .. fn
        local pad_len = math.max(0, col2_w - (display_width(fn) + icon_cols))
        local padded_col2 = display_fn .. string.rep(" ", pad_len)

        local date_disp, date_src = get_image_timestamp(img)
        local list_date = (date_disp and date_disp ~= "-") and date_disp:sub(1, 10) or (img.date_str or "-")
        if (date_src == "EXIF" or date_src == "tIME") and list_date ~= "-" then
            list_date = list_date .. "*"
        end

        local line_str = string.format("%-6s %s %-8s %-12s %-12s",
            string.format("[%d]", i),
            padded_col2,
            img.extension,
            img.size_str,
            list_date
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
            if not a.timestamp_sec then get_image_timestamp(a) end
            if not b.timestamp_sec then get_image_timestamp(b) end
            val_a, val_b = a.timestamp_sec or a.mtime or 0, b.timestamp_sec or b.mtime or 0
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
        local fn = to_display_text(img.filename):lower()
        local fp = to_display_text(img.filepath):lower()
        if fn:find(q, 1, true) or fp:find(q, 1, true) or img.filename:lower():find(q, 1, true) then
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
        elseif a == "--play-engine" or a == "--video-engine" then
            i = i + 1
            args["--play-engine"] = arg[i]
        elseif a:sub(1, 2) == "--" or a:sub(1, 1) == "-" then
            args[a] = true
        else
            table.insert(positional, a)
        end
        i = i + 1
    end

    if args["-h"] or args["--help"] then
        print("\27[1;36mpix — Terminal Directory Image Viewer (LuaJIT FFI)\27[0m")
        print("Usage:")
        print("  ./LuaJIT/src/luajit pix.lua [directory] [options]")
        print("\nOptions:")
        print("  [directory]           Directory to scan (default: current directory '.')")
        print("  -r, --recursive       Recursively scan subdirectories for images")
        print("  --select, -s <id>     Directly select and display image #id")
        print("  --sort <name|date|size> Initial sort order (default: name)")
        print("  --hidden, -a          Include hidden (dot) files and folders (toggle with [.])")
        print("  --play-engine <auto|ffi|ffmpeg|mpv> Video play engine (default: auto)")
        print("  --nerd-icons          Use Nerd Font glyphs instead of standard Unicode")
        print("  --no-icons            Disable file icons")
        print("  --no-interactive      Non-interactive script/batch mode")
        print("  -h, --help            Show this help information")
        print("\nRender Engines (Detected on this system):")
        local avail = get_available_engines()
        print(string.format("  System Status: %d available engine%s", #avail, #avail == 1 and "" or "s"))
        for _, eng in ipairs(RENDER_ENGINES) do
            local status = eng.is_available() and "\27[32m[Available]\27[0m" or "\27[90m[Not Detected]\27[0m"
            print(string.format("  %-17s %s %s", "--" .. eng.id, status, eng.name))
        end
        print("  --half-block          Alias for --truecolor")
        print("  --quarter-block       Alias for --timg-quarter")
        print("\nVideo Engine:")
        print("  Play engines (cycle in the player with [m]):")
        for _, eng in ipairs(VIDEO_PLAY_ENGINES) do
            local status = eng.is_available() and "\27[32m[Available]\27[0m" or "\27[90m[Not Detected]\27[0m"
            print(string.format("  --play-engine %-7s %s %s", eng.id, status, eng.name))
        end
        print(string.format("  Default (auto):       %s", get_play_engine_name(video_play_engine)))
        local mpv_status = get_has_mpv() and "\27[32m[Available]\27[0m" or "\27[90m[Not Detected]\27[0m"
        print("  mpv --vo=tct:         " .. mpv_status .. " mpv terminal player (hand-off, with audio)")
        print("\nSupported formats:")
        print("  - Images: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP")
        print("  - Videos: MP4, MKV, WEBM, AVI, MOV, M4V, FLV (via mpv, libavcodec FFI, or ffmpeg)")
        os.exit(0)
    end

    -- Graphics protocol: ANSI Truecolor (original) is the primary default
    local active_protocol = "truecolor"
    if args["--kitty"] then
        active_protocol = "kitty"
    elseif args["--iterm"] or args["--iterm2"] then
        active_protocol = "iterm"
    elseif args["--timg-cli"] or args["--timg-bin"] then
        active_protocol = "timg-cli"
    elseif args["--chafa-cli"] or args["--chafa-bin"] then
        active_protocol = "chafa-cli"
    elseif args["--chafa-braille"] or args["--braille"] then
        active_protocol = "chafa-braille"
    elseif args["--chafa"] or args["--chafa-symbols"] then
        active_protocol = "chafa"
    elseif args["--timg-quarter"] or args["--quarter-block"] or args["--quarter"] then
        active_protocol = "timg-quarter"
    elseif args["--timg-half"] or args["--timg"] then
        active_protocol = "timg-half"
    elseif args["--truecolor"] or args["--half-block"] or args["--halfblock"] then
        active_protocol = "truecolor"
    end

    -- Icon mode
    local icon_mode = "unicode"
    if args["--no-icons"] or args["--no-icon"] then
        icon_mode = "none"
    elseif args["--nerd-icons"] or args["--nerd-icon"] or args["--nerd"] then
        icon_mode = "nerd"
    end

    -- Video play engine: auto (default) or an explicitly detected engine
    if args["--play-engine"] then
        local requested = tostring(args["--play-engine"]):lower()
        if requested == "auto" then
            video_play_engine = default_play_engine()
        else
            local detected = false
            for _, eng in ipairs(get_available_play_engines()) do
                if eng.id == requested then detected = true break end
            end
            if detected then
                video_play_engine = requested
            else
                io.stderr:write(string.format("\27[1;33m[!] Video play engine '%s' not detected; using %s\27[0m\n",
                    requested, get_play_engine_name(video_play_engine)))
            end
        end
    end

    local recursive = args["-r"] or args["--recursive"]
    -- Hidden (dot) entries: off by default, toggled with [.] in the list view
    local show_hidden = args["--hidden"] or args["-a"] or false
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
            local mtime_val = 0
            if not is_windows and posix_stat then
                local st = ffi.new("struct stat")
                if posix_stat(target_dir, st) == 0 then
                    is_a_dir = (bit.band(tonumber(st.st_mode), 0xF000) == 0x4000)
                    mtime_val = tonumber(st.st_mtime)
                end
            elseif is_windows and get_file_mtime then
                mtime_val = get_file_mtime(target_dir)
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
                        mtime = mtime_val,
                        date_str = format_date(mtime_val),
                    }
                }
                cli_select = cli_select or 1
            end
        end
    end

    if not raw_images then
        local err
        raw_images, err = scan_directory_images(target_dir, recursive, show_hidden)
        if not raw_images then
            io.stderr:write(string.format("\27[1;31mError: %s\27[0m\n", to_display_text(tostring(err))))
            os.exit(1)
        end
    end

    if #raw_images == 0 and non_interactive then
        print(string.format("\27[1;33m[!] No files or directories found in '%s'.\27[0m", to_display_text(target_dir)))
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
        local target_item = nil
        local total_c = #only_images > 0 and #only_images or #raw_images
        if #only_images > 0 and cli_select >= 1 and cli_select <= #only_images then
            target_item = only_images[cli_select]
        elseif cli_select >= 1 and cli_select <= #raw_images then
            target_item = raw_images[cli_select]
        end

        if target_item then
            -- If user ran 'pix.lua my_video.mp4' directly in terminal without --select or --no-interactive
            if is_video_file(target_item.extension) and not non_interactive and not args["--select"] then
                enable_raw_mode()
                play_video_screen(target_item, cli_select, total_c, active_protocol)
                kitty_clear_screen()
                disable_raw_mode()
                return
            end
            render_image_screen(target_item, cli_select, total_c, active_protocol)
            return
        end
    end

    -- 4. Non-interactive fallback (e.g., pipes or redirect)
    if non_interactive then
        while true do
            render_file_list(target_dir, raw_images, #raw_images, 1, 1, nil, false, "", sort_mode, sort_desc, recursive, icon_mode, show_hidden)
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
                    raw_images = scan_directory_images(target_dir, recursive, show_hidden) or {}
                    sort_images(raw_images, sort_mode, sort_desc)
                else
                    if is_video_file(item.extension) then
                        play_video_screen(item, sel, #raw_images, active_protocol)
                    else
                        render_image_screen(item, sel, #raw_images, active_protocol)
                    end
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

        local new_items, scan_err = scan_directory_images(target_dir, recursive, show_hidden)
        if not new_items then
            current_msg = "Cannot open directory: " .. to_display_text(tostring(scan_err))
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
                render_help_modal(term_w, term_h, active_protocol)
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

                    if is_video_file(cur_img.extension) then
                        local action, new_protocol = play_video_screen(cur_img, img_pos, #img_indices, active_protocol)
                        if new_protocol then active_protocol = new_protocol end
                        if action == "quit" then
                            break
                        elseif action == "back" then
                            kitty_clear_screen()
                            in_viewer = false
                        elseif action == "next" then
                            kitty_clear_screen()
                            if #img_indices > 1 then
                                img_pos = (img_pos % #img_indices) + 1
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        elseif action == "prev" then
                            kitty_clear_screen()
                            if #img_indices > 1 then
                                img_pos = (img_pos - 2 + #img_indices) % #img_indices + 1
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        end
                    else
                        local ok, view_err = render_image_screen(cur_img, img_pos, #img_indices, active_protocol)
                    if not ok then
                        in_viewer = false
                        current_msg = "Failed to load image: " .. to_display_text(tostring(view_err))
                    else
                        local k = read_key()
                        if k == "Q" or k == "CTRL_C" then
                            break
                        elseif k == "q" or k == "ESC" or k == "ENTER" or k == "b" or k == "BACKSPACE" then
                            -- q / Esc return to the file list (Q / Ctrl+C still quit pix)
                            kitty_clear_screen()
                            in_viewer = false
                        elseif k == "RIGHT" or k == "n" or k == "SPACE" or k == "PAGE_DOWN" or k == "l" or k == "j" or k == "CTRL_D" or k == "CTRL_F" then
                            kitty_clear_screen()
                            if #img_indices > 1 then
                                img_pos = (img_pos % #img_indices) + 1
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        elseif k == "LEFT" or k == "p" or k == "PAGE_UP" or k == "k" or k == "h" or k == "CTRL_U" or k == "CTRL_B" then
                            kitty_clear_screen()
                            if #img_indices > 1 then
                                img_pos = (img_pos - 2 + #img_indices) % #img_indices + 1
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        elseif k == "g" or k == "HOME" then
                            kitty_clear_screen()
                            if #img_indices > 0 then
                                img_pos = 1
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        elseif k == "G" or k == "END" then
                            kitty_clear_screen()
                            if #img_indices > 0 then
                                img_pos = #img_indices
                                selected_idx = img_indices[img_pos]
                                update_page_window()
                            end
                        elseif k == "t" or k == "T" then
                            kitty_clear_screen()
                            active_protocol = cycle_next_engine(active_protocol)
                        elseif k == "?" then
                            in_help = true
                        end
                    end
                end
            end
            else
                update_page_window()
                render_file_list(target_dir, filtered_images, #raw_images, selected_idx, page_offset, current_msg, search_mode, search_query, sort_mode, sort_desc, recursive, icon_mode, show_hidden)
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
                            local cut = #search_query
                            while cut > 0 and search_query:byte(cut) >= 0x80 and search_query:byte(cut) < 0xC0 do
                                cut = cut - 1
                            end
                            if cut > 0 then cut = cut - 1 end
                            search_query = search_query:sub(1, cut)
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
                    elseif k and (#k > 1 or (k:byte() >= 32 and k:byte() ~= 127)) then
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
                    elseif k == "." then
                        -- Toggle hidden (dot) files and folders
                        show_hidden = not show_hidden
                        if reload_directory(target_dir) then
                            current_msg = show_hidden and "Hidden: ON" or "Hidden: OFF"
                        end
                    elseif k == "r" then
                        sort_desc = not sort_desc
                        sort_images(raw_images, sort_mode, sort_desc)
                        filtered_images = filter_images(raw_images, search_query)
                    elseif k == "UP" or k == "k" or k == "CTRL_Y" then
                        if selected_idx > 1 then selected_idx = selected_idx - 1 end
                    elseif k == "DOWN" or k == "j" or k == "CTRL_E" then
                        if selected_idx < #filtered_images then selected_idx = selected_idx + 1 end
                    elseif k == "PAGE_DOWN" or k == "CTRL_F" then
                        selected_idx = math.min(#filtered_images, selected_idx + page_step)
                    elseif k == "PAGE_UP" or k == "CTRL_B" then
                        selected_idx = math.max(1, selected_idx - page_step)
                    elseif k == "CTRL_D" then
                        local half_step = math.max(1, math.floor(page_step / 2))
                        selected_idx = math.min(#filtered_images, selected_idx + half_step)
                    elseif k == "CTRL_U" then
                        local half_step = math.max(1, math.floor(page_step / 2))
                        selected_idx = math.max(1, selected_idx - half_step)
                    elseif k == "g" or k == "HOME" then
                        selected_idx = 1
                    elseif k == "G" or k == "END" then
                        selected_idx = math.max(1, #filtered_images)
                    elseif k == "H" then
                        selected_idx = page_offset
                    elseif k == "M" then
                        local visible_count = math.max(4, term_h - 12)
                        selected_idx = math.min(#filtered_images, page_offset + math.floor(visible_count / 2))
                    elseif k == "L" then
                        local visible_count = math.max(4, term_h - 12)
                        selected_idx = math.min(#filtered_images, page_offset + visible_count - 1)
                    elseif k == "BACKSPACE" or k == "h" or k == "LEFT" then
                        navigate_to_parent()
                    elseif k == "ENTER" or k == "SPACE" or k == "l" or k == "RIGHT" or k == "o" then
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
