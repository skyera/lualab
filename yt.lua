--[[
    yt.lua
    Cross-Platform YouTube & YouTube Music Terminal Browser & Player in LuaJIT FFI.

    Features:
    1. Cross-Platform:
       - Works on Linux (POSIX termios, ioctl, poll) & Windows (Win32 Console FFI).
    2. Account Login / Authentication (Optional):
       - Pass --browser <firefox|chrome|brave|edge> to use existing browser cookies.
       - Pass --cookies <file> to load a cookies.txt file.
       - Defaults to Guest / Public mode without requiring any login.
    3. Modes:
       - Music Mode (default with -m / --music): Searches YouTube Music (ytmsearch),
         streams audio-only via mpv --no-video.
       - Video Mode (default with -v / --video): Searches YouTube Videos (ytsearch),
         streams in terminal via mpv --vo=tct or external window with --window.
    4. Interactive TUI:
       - Interactive search with [/].
       - Navigation with ↑ / ↓ / k / j / Enter.
       - Direct URL / Playlist playback support.
       - Thumbnail preview pane via Kitty graphics protocol, chafa, or ANSI half-blocks.
]]

local ffi = require("ffi")

local is_windows = (ffi.os == "Windows")
local POPEN_READ_BIN = is_windows and "rb" or "r"

-- =========================================================================
-- 1. Platform FFI Declarations (POSIX vs. Windows)
-- =========================================================================
local get_terminal_size
local enable_raw_mode
local disable_raw_mode
local read_key
local sleep_ms
local get_now_sec
local is_stdin_tty
local safe_popen = io.popen
local safe_execute = os.execute

if is_windows then
    ffi.cdef[[
        typedef unsigned short WORD;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef void* HANDLE;
        typedef wchar_t WCHAR;

        typedef struct {
            short X;
            short Y;
        } COORD;

        typedef struct {
            short Left;
            short Top;
            short Right;
            short Bottom;
        } SMALL_RECT;

        typedef struct {
            COORD dwSize;
            COORD dwCursorPosition;
            WORD wAttributes;
            SMALL_RECT srWindow;
            COORD dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL SetConsoleOutputCP(DWORD wCodePageID);
        BOOL SetConsoleCP(DWORD wCodePageID);
        wchar_t* GetCommandLineW(void);
        void* LocalFree(void* hMem);
        int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
        int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        DWORD GetTickCount(void);
        void Sleep(DWORD dwMilliseconds);

        typedef struct FILE FILE;
        FILE* _wpopen(const wchar_t *command, const wchar_t *mode);
        int _pclose(FILE *stream);
        size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
        int _wsystem(const wchar_t *command);

        int _kbhit(void);
        int _getch(void);
        int _isatty(int fd);
    ]]

    local kernel32 = ffi.load("kernel32")
    local msvcrt = ffi.load("msvcrt")
    local STD_INPUT_HANDLE = ffi.cast("DWORD", -10)
    local STD_OUTPUT_HANDLE = ffi.cast("DWORD", -11)

    local orig_in_mode = ffi.new("DWORD[1]")
    local raw_mode_enabled = false

    -- Initialize Windows UTF-8 console output and ANSI Virtual Terminal Processing
    pcall(function()
        kernel32.SetConsoleOutputCP(65001)
        kernel32.SetConsoleCP(65001)
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        local out_mode = ffi.new("DWORD[1]")
        if kernel32.GetConsoleMode(hOut, out_mode) ~= 0 then
            local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            kernel32.SetConsoleMode(hOut, bit.bor(out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        end
    end)

    local function win_wide_to_utf8(wstr)
        if not wstr or wstr == nil then return "" end
        local len = kernel32.WideCharToMultiByte(65001, 0, wstr, -1, nil, 0, nil, nil)
        if len <= 0 then return "" end
        local buf = ffi.new("char[?]", len)
        kernel32.WideCharToMultiByte(65001, 0, wstr, -1, buf, len, nil, nil)
        return ffi.string(buf, len - 1)
    end

    local function utf8_to_wide(s)
        if not s then return nil end
        local wlen = kernel32.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
        if wlen <= 0 then return nil end
        local wbuf = ffi.new("wchar_t[?]", wlen)
        kernel32.MultiByteToWideChar(65001, 0, s, -1, wbuf, wlen)
        return wbuf
    end

    safe_popen = function(cmd, mode)
        mode = mode or "r"
        local wcmd = utf8_to_wide(cmd)
        local wmode = utf8_to_wide(mode)
        if wcmd and wmode and msvcrt._wpopen then
            local fp = msvcrt._wpopen(wcmd, wmode)
            if fp ~= nil then
                local chunks = {}
                local buf = ffi.new("char[16384]")
                while true do
                    local n = msvcrt.fread(buf, 1, 16384, fp)
                    if n <= 0 then break end
                    table.insert(chunks, ffi.string(buf, n))
                end
                msvcrt._pclose(fp)
                local full = table.concat(chunks)
                return {
                    read = function(self, fmt) return full end,
                    lines = function(self) return full:gmatch("([^\r\n]+)") end,
                    close = function(self) return true end,
                }
            end
        end
        return io.popen(cmd, mode)
    end

    safe_execute = function(cmd)
        local wcmd = utf8_to_wide(cmd)
        if wcmd and msvcrt._wsystem then
            return msvcrt._wsystem(wcmd)
        end
        return os.execute(cmd)
    end

    local function get_win_utf8_args()
        pcall(function()
            local shell32 = ffi.load("shell32")
            ffi.cdef[[
                wchar_t** CommandLineToArgvW(const wchar_t* lpCmdLine, int* pNumArgs);
            ]]
            local cmdline = kernel32.GetCommandLineW()
            if cmdline == nil then return end
            local num_args = ffi.new("int[1]")
            local argv_w = shell32.CommandLineToArgvW(cmdline, num_args)
            if argv_w == nil then return end
            local raw_argv = {}
            for i = 0, num_args[0] - 1 do
                table.insert(raw_argv, win_wide_to_utf8(argv_w[i]))
            end
            kernel32.LocalFree(argv_w)

            if arg and #arg > 0 and #raw_argv >= #arg then
                local offset = #raw_argv - #arg
                for i = 1, #arg do
                    arg[i] = raw_argv[offset + i]
                end
            end
        end)
    end
    get_win_utf8_args()

    is_stdin_tty = function()
        return ffi.C._isatty(0) ~= 0
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

        io.write("\27[?1049h\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
            kernel32.SetConsoleMode(hIn, orig_in_mode[0])
            raw_mode_enabled = false
        end
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or -1
        local start = kernel32.GetTickCount()
        while true do
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
                    elseif code == 71 then return "HOME"
                    elseif code == 79 then return "END"
                    end
                elseif ch == 27 then
                    return "ESC"
                elseif ch == 13 or ch == 10 then
                    return "ENTER"
                elseif ch == 8 then
                    return "BACKSPACE"
                elseif ch == 9 then
                    return "TAB"
                elseif ch >= 32 and ch <= 126 then
                    return string.char(ch)
                end
            end
            if timeout_ms >= 0 and (kernel32.GetTickCount() - start) >= timeout_ms then
                return nil
            end
            kernel32.Sleep(10)
        end
    end

    sleep_ms = function(ms)
        kernel32.Sleep(ms)
    end

    get_now_sec = function()
        return tonumber(kernel32.GetTickCount()) / 1000.0
    end
else
    -- POSIX (Linux, macOS, BSD)
    ffi.cdef[[
        typedef unsigned char cc_t;
        typedef unsigned int speed_t;
        typedef unsigned int tcflag_t;

        struct termios {
            tcflag_t c_iflag;
            tcflag_t c_oflag;
            tcflag_t c_cflag;
            tcflag_t c_lflag;
            cc_t c_line;
            cc_t c_cc[32];
            speed_t c_ispeed;
            speed_t c_ospeed;
        };

        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };

        struct pollfd {
            int fd;
            short events;
            short revents;
        };

        struct timespec {
            long tv_sec;
            long tv_nsec;
        };

        int ioctl(int fd, unsigned long request, ...);
        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);
        int isatty(int fd);
        int usleep(unsigned int usec);
        int clock_gettime(int clk_id, struct timespec *tp);
    ]]

    local STDIN_FILENO = 0
    local TCSANOW = 0
    local ICANON = 2
    local ECHO = 8
    local POLLIN = 1

    local TIOCGWINSZ = 0x5413
    if ffi.os == "OSX" or ffi.os == "BSD" then
        TIOCGWINSZ = 0x40087468
    end

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) ~= 0
    end

    local mono_ts = ffi.new("struct timespec")
    get_now_sec = function()
        if ffi.C.clock_gettime(1, mono_ts) == 0 then
            return tonumber(mono_ts.tv_sec) + tonumber(mono_ts.tv_nsec) * 1e-9
        end
        return os.clock()
    end

    sleep_ms = function(ms)
        ffi.C.usleep(ms * 1000)
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

        io.write("\27[?1049h\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?1049l\27[?25h\27[0m")
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
                        if c2 == 72 then return "HOME" end
                        if c2 == 70 then return "END" end
                        if c2 == 53 and n >= 4 and key_buf[3] == 126 then return "PAGE_UP" end
                        if c2 == 54 and n >= 4 and key_buf[3] == 126 then return "PAGE_DOWN" end
                    elseif n == 1 then
                        return "ESC"
                    end
                elseif c0 == 10 or c0 == 13 then
                    return "ENTER"
                elseif c0 == 9 then
                    return "TAB"
                elseif c0 == 127 or c0 == 8 then
                    return "BACKSPACE"
                elseif c0 >= 32 and c0 <= 126 then
                    return string.char(c0)
                end
            end
        end
        return nil
    end
end

-- =========================================================================
-- 2. Dependencies Detection & Utilities
-- =========================================================================
local function cmd_exists(cmd)
    local null_dev = is_windows and "nul" or "/dev/null"
    local check_cmd = is_windows and ("where " .. cmd .. " >nul 2>nul") or ("which " .. cmd .. " >/dev/null 2>&1")
    return os.execute(check_cmd) == 0
end

local HAS_YTDLP = cmd_exists("yt-dlp")
local HAS_MPV   = cmd_exists("mpv")
local HAS_CHAFA = cmd_exists("chafa")
local HAS_FFMPEG = cmd_exists("ffmpeg")
local HAS_DENO  = cmd_exists("deno")

local function get_cache_dir()
    local dir
    if is_windows then
        dir = (os.getenv("TEMP") or "C:\\Windows\\Temp") .. "\\yt_lua_cache"
        os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '" 2>nul')
    else
        dir = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/yt_lua"
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
    return dir
end

local function get_history_file()
    return get_cache_dir() .. (is_windows and "\\" or "/") .. "history.json"
end

local function codepoint_to_utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(bit.bor(0xC0, bit.rshift(cp, 6)), bit.bor(0x80, bit.band(cp, 0x3F)))
    elseif cp < 0x10000 then
        return string.char(bit.bor(0xE0, bit.rshift(cp, 12)), bit.bor(0x80, bit.band(bit.rshift(cp, 6), 0x3F)), bit.bor(0x80, bit.band(cp, 0x3F)))
    elseif cp < 0x110000 then
        return string.char(bit.bor(0xF0, bit.rshift(cp, 18)), bit.bor(0x80, bit.band(bit.rshift(cp, 12), 0x3F)), bit.bor(0x80, bit.band(bit.rshift(cp, 6), 0x3F)), bit.bor(0x80, bit.band(cp, 0x3F)))
    end
    return ""
end

local function unescape_unicode(s)
    if not s or not s:find("\\u") then return s end
    -- Handle surrogate pairs: \uD8xx\uDCxx
    s = s:gsub("\\u([dD][89a-bA-B]%x%x)\\u([dD][c-fC-F]%x%x)", function(hi_hex, lo_hex)
        local hi = tonumber(hi_hex, 16)
        local lo = tonumber(lo_hex, 16)
        local cp = 0x10000 + bit.lshift(bit.band(hi, 0x3FF), 10) + bit.band(lo, 0x3FF)
        return codepoint_to_utf8(cp)
    end)
    -- Handle standard \uXXXX
    s = s:gsub("\\u(%x%x%x%x)", function(hex)
        local cp = tonumber(hex, 16)
        return codepoint_to_utf8(cp)
    end)
    return s
end

local function sanitize_display_text(s)
    if not s or type(s) ~= "string" then return "" end
    -- 1. Strip SMP 4-byte UTF-8 emojis (U+1F000 - U+1FFFF: e.g. 🎧, 🔥, 🚀)
    s = s:gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", "")
    -- 2. Strip Dingbats, Misc Symbols (U+2600 - U+27BF: 3-byte UTF-8 e.g. ✨ \u2728, 🎵, ❤, ⚡, ★)
    s = s:gsub("[\226][\152-\158][\128-\191]", "")
    -- 3. Strip Variation Selectors (U+FE00 - U+FE0F)
    s = s:gsub("[\239][\184][\128-\143]", "")
    -- 4. Strip zero-width spaces (\226\128[\139-\141])
    s = s:gsub("[\226][\128][\139-\141]", "")
    -- 5. Normalize whitespace
    return s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function codepoint_width(cp)
    if cp < 0x1100 then return 1 end
    if (cp >= 0x1100 and cp <= 0x115F)     -- Hangul Jamo
        or (cp >= 0x2E80 and cp <= 0x303E) -- CJK Radicals, Kangxi, CJK Symbols
        or (cp >= 0x3041 and cp <= 0x33FF) -- Kana, CJK Compatibility
        or (cp >= 0x3400 and cp <= 0x4DBF) -- CJK Unified Ideographs Ext A
        or (cp >= 0x4E00 and cp <= 0x9FFF) -- CJK Unified Ideographs (Common Hanzi)
        or (cp >= 0xA000 and cp <= 0xA4CF) -- Yi
        or (cp >= 0xAC00 and cp <= 0xD7A3) -- Hangul Syllables
        or (cp >= 0xF900 and cp <= 0xFAFF) -- CJK Compatibility Ideographs
        or (cp >= 0xFE30 and cp <= 0xFE6F) -- CJK Compatibility Forms
        or (cp >= 0xFF00 and cp <= 0xFF60) -- Fullwidth Latin / Punctuation
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
        or (cp >= 0x20000 and cp <= 0x3FFFD) then -- CJK Extensions B+
        return 2
    end
    return 1
end

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

local function display_width(s)
    if not s or type(s) ~= "string" or #s == 0 then return 0 end
    local w, i = 0, 1
    local len = #s
    while i <= len do
        local cp, clen = utf8_next(s, i)
        w = w + codepoint_width(cp)
        i = i + clen
    end
    return w
end

local function utf8_truncate(s, max_cols)
    if not s or type(s) ~= "string" then return "" end
    if display_width(s) <= max_cols then return s end
    local budget = math.max(0, max_cols - 2)
    local w, i, cut = 0, 1, 0
    local len = #s
    while i <= len do
        local cp, clen = utf8_next(s, i)
        local cw = codepoint_width(cp)
        if w + cw > budget then break end
        w = w + cw
        i = i + clen
        cut = i - 1
    end
    return s:sub(1, cut) .. ".."
end

local function parse_json_field(line, key)
    local pat = '"' .. key .. '"%s*:%s*"'
    local s, e = line:find(pat)
    if s then
        local pos = e + 1
        local chars = {}
        local len = #line
        while pos <= len do
            local b = line:sub(pos, pos)
            if b == "\\" then
                pos = pos + 1
                local next_b = line:sub(pos, pos)
                if next_b == '"' then table.insert(chars, '"')
                elseif next_b == "\\" then table.insert(chars, "\\")
                elseif next_b == "/" then table.insert(chars, "/")
                elseif next_b == "n" then table.insert(chars, " ")
                elseif next_b == "u" then
                    -- Keep \uXXXX intact for unescape_unicode to parse
                    local u_part = line:sub(pos - 1, pos + 4)
                    table.insert(chars, u_part)
                    pos = pos + 4
                else table.insert(chars, next_b) end
            elseif b == '"' then
                local res = unescape_unicode(table.concat(chars))
                if key == "title" or key == "uploader" or key == "channel" then
                    res = sanitize_display_text(res)
                end
                return res
            else
                table.insert(chars, b)
            end
            pos = pos + 1
        end
    end
    local num = line:match('"' .. key .. '"%s*:%s*([%d%.]+)')
    if num then return tonumber(num) end
    return nil
end

local function save_history_item(item)
    if not item or not item.id then return end
    local hfile = get_history_file()
    local existing = {}
    local f = io.open(hfile, "r")
    if f then
        for line in f:lines() do
            local id = parse_json_field(line, "id")
            local title = parse_json_field(line, "title")
            if id and title and id ~= item.id then
                local uploader = parse_json_field(line, "uploader") or "YouTube"
                local duration = parse_json_field(line, "duration") or 0
                local duration_str = parse_json_field(line, "duration_str") or "--:--"
                table.insert(existing, {
                    id = id,
                    url = "https://www.youtube.com/watch?v=" .. id,
                    title = title,
                    uploader = uploader,
                    duration = duration,
                    duration_str = duration_str,
                })
                if #existing >= 40 then break end
            end
        end
        f:close()
    end

    local out = io.open(hfile, "w")
    if out then
        local function esc(s) return (s or ""):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' ') end
        out:write(string.format('{"id":%q,"title":%q,"uploader":%q,"duration":%d,"duration_str":%q}\n',
            item.id, esc(item.title), esc(item.uploader), item.duration or 0, esc(item.duration_str)))
        for _, it in ipairs(existing) do
            out:write(string.format('{"id":%q,"title":%q,"uploader":%q,"duration":%d,"duration_str":%q}\n',
                it.id, esc(it.title), esc(it.uploader), it.duration or 0, esc(it.duration_str)))
        end
        out:close()
    end
end

local function load_history_items()
    local hfile = get_history_file()
    local f = io.open(hfile, "r")
    if not f then return {} end
    local items = {}
    for line in f:lines() do
        local id = parse_json_field(line, "id")
        local title = parse_json_field(line, "title")
        if id and title then
            local uploader = parse_json_field(line, "uploader") or "YouTube"
            local duration = parse_json_field(line, "duration") or 0
            local duration_str = parse_json_field(line, "duration_str") or "--:--"
            table.insert(items, {
                id = id,
                url = "https://www.youtube.com/watch?v=" .. id,
                title = title,
                uploader = uploader,
                duration = duration,
                duration_str = duration_str,
            })
        end
    end
    f:close()
    return items
end

local function format_duration(sec)
    if not sec or sec <= 0 then return "--:--" end
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

-- =========================================================================
-- 3. YouTube Search & Extraction Engine
-- =========================================================================
local function scrape_youtube_search(query, max_results, proxy, insecure)
    max_results = max_results or 20
    local encoded = query:gsub("([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local proxy_opt = (proxy and #proxy > 0) and string.format(" -x %q", proxy) or ""
    local sec_opt = insecure and " -k" or ""
    local url = "https://www.youtube.com/results?search_query=" .. encoded
    local cmd = string.format('curl -s -L --max-time 8%s%s -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" %q',
        sec_opt, proxy_opt, url)
    local p = safe_popen(cmd, POPEN_READ_BIN)
    if not p then return nil end
    local html = p:read("*a")
    p:close()
    if not html or #html < 500 then return nil end

    local items = {}
    local seen = {}
    for block in html:gmatch('"videoRenderer":%b{}') do
        local id = block:match('"videoId"%s*:%s*"([%w%-_]+)"')
        local title_part = block:match('"title"%s*:%s*%b{}')
        local title = title_part and title_part:match('"text"%s*:%s*"(.-)"')
        local owner_part = block:match('"ownerText"%s*:%s*%b{}') or block:match('"longBylineText"%s*:%s*%b{}')
        local channel = owner_part and owner_part:match('"text"%s*:%s*"(.-)"') or "YouTube"
        local len_part = block:match('"lengthText"%s*:%s*%b{}')
        local duration_str = len_part and len_part:match('"simpleText"%s*:%s*"(.-)"') or "--:--"

        if id and title and not seen[id] then
            seen[id] = true
            table.insert(items, {
                id = id,
                url = "https://www.youtube.com/watch?v=" .. id,
                title = sanitize_display_text(unescape_unicode(title)),
                uploader = sanitize_display_text(unescape_unicode(channel)),
                duration = 0,
                duration_str = duration_str,
                thumbnail = string.format("https://i.ytimg.com/vi/%s/hqdefault.jpg", id),
            })
            if #items >= max_results then break end
        end
    end
    return items
end

local function fetch_youtube_results(query, mode, browser, cookies_file, max_results, is_liked, proxy, insecure)
    max_results = max_results or 20
    local is_direct_url = query:match("^https?://") or query:match("^www%.") or query:match("^youtu%.be/")
    local term = query

    if not is_liked and not is_direct_url then
        if mode == "music" and not query:lower():find("music") and not query:lower():find("song") and not query:lower():find("audio") then
            term = query .. " music"
        end
    end

    local items = {}
    local err_lines = {}

    if HAS_YTDLP then
        local search_spec
        if is_liked then
            if mode == "music" then
                search_spec = '"https://music.youtube.com/playlist?list=LM"'
            else
                search_spec = '":ytfavorites"'
            end
        elseif is_direct_url then
            search_spec = string.format("%q", query)
        else
            search_spec = string.format('"ytsearch%d:%s"', max_results, term:gsub('"', '\\"'))
        end

        local extra_opts = " --extractor-args=\"youtube:player_client=android\""
        if browser and #browser > 0 then
            extra_opts = extra_opts .. string.format(" --cookies-from-browser %s", browser)
        elseif cookies_file and #cookies_file > 0 then
            extra_opts = extra_opts .. string.format(" --cookies %q", cookies_file)
        end
        if insecure then
            extra_opts = extra_opts .. " --no-check-certificates"
        end
        if proxy and #proxy > 0 then
            extra_opts = extra_opts .. string.format(" --proxy %q", proxy)
        end

        local redirect = "2>&1"
        local cmd = string.format(
            'yt-dlp --dump-json --flat-playlist --skip-download%s %s %s',
            extra_opts, search_spec, redirect
        )

        local p = safe_popen(cmd, POPEN_READ_BIN)
        if p then
            for line in p:lines() do
                if line:sub(1, 1) == "{" then
                    local id = parse_json_field(line, "id")
                    local title = parse_json_field(line, "title")
                    if id and title then
                        local uploader = parse_json_field(line, "uploader") or parse_json_field(line, "channel") or "YouTube"
                        local duration = parse_json_field(line, "duration") or 0
                        local thumb = parse_json_field(line, "thumbnail")
                        table.insert(items, {
                            id = id,
                            url = "https://www.youtube.com/watch?v=" .. id,
                            title = title,
                            uploader = uploader,
                            duration = duration,
                            duration_str = format_duration(duration),
                            thumbnail = thumb,
                        })
                    end
                else
                    if line:find("ERROR") or line:find("WARNING") or line:find("SSL") or line:find("bot") then
                        table.insert(err_lines, line)
                    end
                end
            end
            p:close()
        end
    end

    if #items > 0 then
        return items, nil, insecure
    end

    -- Check if SSL verification failed and auto-retry in insecure mode
    local err_text = table.concat(err_lines, "\n")
    if not insecure and (err_text:find("CERTIFICATE_VERIFY_FAILED") or err_text:find("certificate verify failed") or err_text:find("SSL") or err_text:find("certificate problem")) then
        io.stderr:write("\n\27[33m[yt] Corporate SSL inspection detected -- retrying in insecure mode...\27[0m\n")
        local retry_items, retry_err = fetch_youtube_results(query, mode, browser, cookies_file, max_results, is_liked, proxy, true)
        if retry_items and #retry_items > 0 then
            return retry_items, nil, true
        end
        if retry_err then err_text = retry_err end
    end

    -- Automatic Fallback: Direct Web Scrape via curl (works even if yt-dlp is blocked or broken)
    if not is_liked and not is_direct_url then
        local fallback_items = scrape_youtube_search(term, max_results, proxy, insecure)
        if fallback_items and #fallback_items > 0 then
            return fallback_items, nil, insecure
        elseif not insecure then
            local fallback_insecure = scrape_youtube_search(term, max_results, proxy, true)
            if fallback_insecure and #fallback_insecure > 0 then
                io.stderr:write("\n\27[33m[yt] Corporate SSL inspection detected (curl) -- retrying in insecure mode...\27[0m\n")
                return fallback_insecure, nil, true
            end
        end
    end

    -- If both engines failed, produce helpful actionable error
    if err_text:find("CERTIFICATE_VERIFY_FAILED") or err_text:find("certificate verify failed") then
        return nil, "SSL certificate failed (corporate network?). Try: --insecure or set YT_INSECURE=1", insecure
    elseif err_text:find("Sign in to confirm") or err_text:find("bot") then
        return nil, "YouTube blocked request (anti-bot). Try: --browser <chrome|edge|firefox> or --cookies <file>", insecure
    elseif err_text:find("429") or err_text:find("Too Many Requests") then
        return nil, "Rate limited by YouTube (429). Try: --browser or --proxy <url>", insecure
    elseif err_text:find("ProxyError") or err_text:find("Connection refused") or err_text:find("timed out") then
        return nil, "Connection failed. Check network or try: --proxy <url>", insecure
    elseif #err_lines > 0 then
        local first_err = err_lines[1]:gsub("^ERROR:%s*", ""):gsub("^%[.-%]%s*", "")
        return nil, "yt-dlp error: " .. first_err:sub(1, 70), insecure
    elseif not HAS_YTDLP then
        return nil, "yt-dlp is not installed and web fallback returned 0 items.", insecure
    end

    return nil, "No results found for '" .. query .. "'.", insecure
end

-- =========================================================================
-- 4. Thumbnail & Preview Renderer
-- =========================================================================
local function render_thumbnail_art(thumb_url, box_w, box_h)
    if not thumb_url or box_w < 10 or box_h < 4 then return nil end
    local cache_dir = get_cache_dir()
    local thumb_id = thumb_url:match("vi/([^/]+)/") or thumb_url:match("([%w%-_]+)%.[a-z]+$") or "thumb"
    local thumb_file = cache_dir .. (is_windows and "\\" or "/") .. thumb_id .. ".jpg"

    -- Download if not cached
    local f = io.open(thumb_file, "rb")
    if f then
        f:close()
    else
        local null_out = is_windows and ">nul 2>nul" or ">/dev/null 2>&1"
        os.execute(string.format('curl -s -L --max-time 3 -o %q %q %s', thumb_file, thumb_url, null_out))
    end

    if HAS_CHAFA then
        local p = safe_popen(string.format('chafa --size=%dx%d --format=symbols --symbols=block %q 2>/dev/null',
            box_w, box_h, thumb_file), "r")
        if p then
            local lines = {}
            for l in p:lines() do table.insert(lines, l) end
            p:close()
            return lines
        end
    end
    return nil
end

local function build_mpv_status_msg(mode, show_cc)
    if mode == "music" then
        local msg = "  ${media-title}  [${playback-time} / ${duration}]  Vol: ${volume}%"
        if show_cc then
            msg = msg .. "${sub-text?\\n  >> CC/Lyrics: ${sub-text}}"
        end
        return msg
    else
        local msg = "  ${media-title}  [${playback-time} / ${duration}]"
        if show_cc then
            msg = msg .. "${sub-text?\\n  >> CC: ${sub-text}}"
        end
        return msg
    end
end

-- =========================================================================
-- 5. Playback Controller
-- =========================================================================
local function play_item(item, mode, browser, cookies_file, use_external_window, proxy, insecure, show_cc, sub_lang)
    if not HAS_MPV then
        io.write("\27[H\27[2J\27[1;31mError: mpv is not installed.\27[0m\n\nPlease install mpv to play audio/video streams.\nPress any key to return...")
        io.flush()
        read_key()
        return
    end

    local raw_opts = { "extractor-args=youtube:player_client=android" }
    if show_cc then
        table.insert(raw_opts, "write-subs=")
        table.insert(raw_opts, "write-auto-subs=")
        table.insert(raw_opts, string.format("sub-langs=%s", sub_lang or "en.*"))
    end
    if browser and #browser > 0 then
        table.insert(raw_opts, string.format("cookies-from-browser=%s", browser))
    elseif cookies_file and #cookies_file > 0 then
        table.insert(raw_opts, string.format("cookies=%s", cookies_file))
    end
    if insecure then
        table.insert(raw_opts, "no-check-certificates=")
    end
    if proxy and #proxy > 0 then
        table.insert(raw_opts, string.format("proxy=%s", proxy))
    end
    local ytdl_raw_opts = string.format(' --ytdl-raw-options=%q', table.concat(raw_opts, ","))

    local extra_mpv_opts = ""
    if insecure then
        extra_mpv_opts = extra_mpv_opts .. " --tls-verify=no"
    end
    if proxy and #proxy > 0 then
        extra_mpv_opts = extra_mpv_opts .. string.format(" --http-proxy=%q", proxy)
    end
    if show_cc then
        local lang_pref = sub_lang or "en,eng"
        extra_mpv_opts = extra_mpv_opts .. string.format(" --sub-auto=all --sub-visibility=yes --slang=%s", lang_pref)
    end

    local term_w, term_h = get_terminal_size()
    local status_msg = build_mpv_status_msg(mode, show_cc)
    local mpv_cmd

    if mode == "music" then
        -- Audio-only streaming with OSD status
        mpv_cmd = string.format(
            'mpv --no-video --hwdec=auto --term-osd-bar --ytdl-format="bestaudio/best" '
            .. '--term-status-msg="%s" '
            .. '%s%s %q',
            status_msg, ytdl_raw_opts, extra_mpv_opts, item.url
        )
    else
        -- Video playback
        if use_external_window then
            mpv_cmd = string.format('mpv --hwdec=auto --term-status-msg="%s" %s%s %q', status_msg, ytdl_raw_opts, extra_mpv_opts, item.url)
        else
            -- Terminal ASCII/Half-block video (capped to 480p for performance & bandwidth efficiency)
            local h_offset = show_cc and 2 or 1
            mpv_cmd = string.format(
                'mpv --vo=tct --vo-tct-width=%d --vo-tct-height=%d --hwdec=auto --term-osd-bar '
                .. '--ytdl-format="bestvideo[height<=480]+bestaudio/best[height<=480]/best" '
                .. '--term-status-msg="%s" '
                .. '%s%s %q',
                math.max(10, term_w), math.max(6, term_h - h_offset),
                status_msg,
                ytdl_raw_opts, extra_mpv_opts, item.url
            )
        end
    end

    disable_raw_mode()
    io.write("\27[H\27[2J\27[1;36m> Connecting to YouTube stream: \27[1;33m" .. item.title .. "\27[0m\n\n")
    io.flush()

    local exit_code = safe_execute(mpv_cmd)

    enable_raw_mode()
    return exit_code
end

-- =========================================================================
-- 6. Interactive Modals (Search & Shortcut Help)
-- =========================================================================
local function prompt_search_query(current_query)
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(60, term_w - 4)
    local box_x = math.max(1, math.floor((term_w - box_w) / 2))
    local box_y = math.max(2, math.floor(term_h / 3))

    local input_str = ""

    local function draw_modal()
        io.write(string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", box_y, box_x, string.rep("-", box_w - 2)))
        io.write(string.format("\27[%d;%dH\27[1;36m| \27[1;37mSearch YouTube / URL:\27[0m%s\27[1;36m|\27[0m",
            box_y + 1, box_x, string.rep(" ", box_w - 24)))
        
        local display_input = input_str
        if #display_input > box_w - 6 then
            display_input = display_input:sub(#display_input - (box_w - 9))
        end
        local pad = math.max(0, box_w - 6 - #display_input)
        io.write(string.format("\27[%d;%dH\27[1;36m| \27[93m> %s\27[7m \27[0m%s\27[1;36m|\27[0m",
            box_y + 2, box_x, display_input, string.rep(" ", pad)))
        io.write(string.format("\27[%d;%dH\27[1;36m| \27[90m[Enter] Search   [Esc] Cancel\27[0m%s\27[1;36m|\27[0m",
            box_y + 3, box_x, string.rep(" ", box_w - 32)))
        io.write(string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", box_y + 4, box_x, string.rep("-", box_w - 2)))
        io.flush()
    end

    draw_modal()

    while true do
        local k = read_key(50)
        if k == "ESC" then
            return nil
        elseif k == "ENTER" then
            if #input_str > 0 then
                return input_str
            else
                return nil
            end
        elseif k == "BACKSPACE" then
            if #input_str > 0 then
                input_str = input_str:sub(1, #input_str - 1)
                draw_modal()
            end
        elseif k and #k == 1 then
            input_str = input_str .. k
            draw_modal()
        end
    end
end

local function show_help_modal()
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(68, term_w - 4)
    local box_x = math.max(1, math.floor((term_w - box_w) / 2))
    local box_y = math.max(2, math.floor((term_h - 20) / 2))

    local function line_pad(text, visual_len)
        local pad = math.max(0, box_w - 2 - visual_len)
        return text .. string.rep(" ", pad) .. "|"
    end

    local help_lines = {
        "+" .. string.rep("-", box_w - 2) .. "+",
        line_pad("|  \27[1;36mYouTube Terminal Viewer -- Shortcut Cheat Sheet\27[0m", 47),
        "+" .. string.rep("-", box_w - 2) .. "+",
        line_pad("|  \27[1;33mTerminal Navigation & Controls:\27[0m", 32),
        line_pad("|    \27[93m[Enter]\27[0m       Play selected video or music track", 45),
        line_pad("|    \27[93m[/]\27[0m           Open search modal or paste direct URL", 48),
        line_pad("|    \27[93m[a]\27[0m           Toggle continuous Auto-Play (Radio mode)", 51),
        line_pad("|    \27[93m[c]\27[0m           Toggle Closed Captions (CC / Lyrics)", 48),
        line_pad("|    \27[93m[h]\27[0m           Toggle Playback History (recent tracks)", 50),
        line_pad("|    \27[93m[m]\27[0m           Toggle between Music and Video mode", 46),
        line_pad("|    \27[93m[L]\27[0m           Toggle Liked Songs playlist", 38),
        line_pad("|    \27[93m[Up/Dn, k/j]\27[0m  Navigate results list", 33),
        line_pad("|    \27[93m[PgUp/PgDn]\27[0m   Scroll 10 tracks up or down", 38),
        line_pad("|  \27[1;33mIn-Playback Controls (mpv):\27[0m", 28),
        line_pad("|    \27[93m[Space]\27[0m       Pause / Resume playback", 34),
        line_pad("|    \27[93m[<- / ->]\27[0m     Seek backward / forward 5 seconds", 44),
        line_pad("|    \27[93m[9 / 0]\27[0m       Volume down / Volume up", 34),
        line_pad("|    \27[93m[[ / ]]\27[0m       Speed down / Speed up (+/-10%)", 39),
        line_pad("|    \27[93m[j / J]\27[0m       Cycle next / prev subtitle track", 43),
        line_pad("|    \27[93m[v]\27[0m           Toggle subtitle visibility on/off", 44),
        line_pad("|    \27[93m[q]\27[0m           Stop playing and return to browser", 45),
        "+" .. string.rep("-", box_w - 2) .. "+",
        line_pad("|  \27[90mPress any key to close this help modal...\27[0m", 41),
        "+" .. string.rep("-", box_w - 2) .. "+",
    }

    for idx, line in ipairs(help_lines) do
        io.write(string.format("\27[%d;%dH\27[0m%s", box_y + idx - 1, box_x, line))
    end
    io.flush()
    read_key()
end

-- =========================================================================
-- 7. Main Interactive TUI Application
-- =========================================================================
local function run_app(init_query, init_mode, browser, cookies_file, is_liked, use_window, proxy, insecure, init_show_cc, init_sub_lang)
    local current_query = init_query or "lofi beats"
    local mode = init_mode or "music"
    local show_cc = init_show_cc or false
    local sub_lang = init_sub_lang or "en.*"
    local selected_idx = 1
    local scroll_offset = 0
    local auto_play = false
    local is_history = false

    enable_raw_mode()

    local items = {}
    local is_loading = true
    local status_msg = "Loading..."

    local function refresh_results()
        items = {}
        selected_idx = 1
        scroll_offset = 0
        is_loading = true

        local term_w, term_h = get_terminal_size()
        io.write("\27[H\27[2J")
        io.write(string.format("\n  \27[1;36m* Searching YouTube (%s mode): \27[1;93m%s\27[0m ...\n",
            mode:upper(), is_liked and "Liked Songs" or current_query))
        io.flush()

        local res, err, used_insecure = fetch_youtube_results(current_query, mode, browser, cookies_file, 25, is_liked, proxy, insecure)
        if used_insecure then
            insecure = true
        end
        is_loading = false
        if res and #res > 0 then
            items = res
            status_msg = string.format("Found %d results", #items)
        else
            status_msg = err or "No results found."
        end
    end

    refresh_results()

    local function draw_tui()
        local term_w, term_h = get_terminal_size()
        local max_list_h = math.max(4, term_h - 7)

        -- Clamp selection
        if #items > 0 then
            selected_idx = math.max(1, math.min(#items, selected_idx))
            if selected_idx <= scroll_offset then
                scroll_offset = selected_idx - 1
            elseif selected_idx > scroll_offset + max_list_h then
                scroll_offset = selected_idx - max_list_h
            end
        end

        local buf = {}
        table.insert(buf, "\27[H")

        -- 1. Header Bar
        local auth_label = browser and ("Logged in: " .. browser) or (cookies_file and "Cookies file" or "Guest / Public")
        local mode_badge = (mode == "music") and "\27[1;92m[MUSIC / AUDIO]\27[0m" or "\27[1;93m[VIDEO]\27[0m"
        local auto_badge = auto_play and "\27[1;92m[AUTO: ON]\27[0m" or "\27[90m[AUTO: OFF]\27[0m"
        local cc_badge = show_cc and "\27[1;92m[CC: ON]\27[0m" or "\27[90m[CC: OFF]\27[0m"
        local sec_badge = insecure and " | \27[1;33m[CORP SSL]\27[0m" or ""
        local header = string.format(" \27[1;36mYouTube Terminal Viewer\27[0m | %s | %s | %s | \27[90m%s\27[0m%s", mode_badge, auto_badge, cc_badge, auth_label, sec_badge)
        table.insert(buf, "\27[1;34m" .. string.rep("=", term_w) .. "\27[0m\n")
        table.insert(buf, header .. "\27[K\n")

        -- 2. Query / Search Subheader
        local q_display
        if is_history then
            q_display = "\27[1;95m[History] Playback History\27[0m"
        elseif is_liked then
            q_display = "\27[1;95m[Liked] Liked Songs Playlist\27[0m"
        else
            q_display = '"' .. current_query .. '"'
        end
        table.insert(buf, string.format("  \27[90mSearch:\27[0m %s  \27[90m(%s)\27[0m\27[K\n", q_display, status_msg))
        table.insert(buf, "\27[1;34m" .. string.rep("-", term_w) .. "\27[0m\n")

        -- 3. Results List
        if #items == 0 then
            table.insert(buf, string.format("\n   \27[1;33m%s\27[0m\n", status_msg))
            for _ = 1, max_list_h - 2 do table.insert(buf, "\27[K\n") end
        else
            for r = 1, max_list_h do
                local idx = scroll_offset + r
                if idx <= #items then
                    local it = items[idx]
                    local is_sel = (idx == selected_idx)
                    local cursor = is_sel and "\27[1;92m> " or "  "
                    
                    local max_title_w = math.max(15, term_w - 38)
                    local t = utf8_truncate(it.title, max_title_w)
                    local title_pad = string.rep(" ", math.max(0, max_title_w - display_width(t)))

                    local max_up_w = 18
                    local up = utf8_truncate(it.uploader, max_up_w)
                    local up_pad = string.rep(" ", math.max(0, max_up_w - display_width(up)))

                    local row_str
                    if is_sel then
                        row_str = string.format("%s\27[1;37;44m%02d. %s%s \27[1;96;44m%s%s \27[1;93;44m%s\27[0m\27[K\n",
                            cursor, idx, t, title_pad, up, up_pad, it.duration_str)
                    else
                        row_str = string.format("%s\27[90m%02d.\27[0m \27[37m%s%s\27[0m \27[90m%s%s\27[0m \27[33m%s\27[0m\27[K\n",
                            cursor, idx, t, title_pad, up, up_pad, it.duration_str)
                    end
                    table.insert(buf, row_str)
                else
                    table.insert(buf, "\27[K\n")
                end
            end
        end

        -- 4. Footer Help
        local auto_footer = auto_play and "\27[1;92mON\27[0m" or "\27[90mOFF\27[0m"
        local cc_footer = show_cc and "\27[1;92mON\27[0m" or "\27[90mOFF\27[0m"
        table.insert(buf, "\27[1;34m" .. string.rep("-", term_w) .. "\27[0m\n")
        table.insert(buf, string.format(" \27[93m[Enter]\27[0m Play  \27[93m[/]\27[0m Search  \27[93m[a]\27[0m Auto:%s  \27[93m[c]\27[0m CC:%s  \27[93m[h]\27[0m History  \27[93m[m]\27[0m Mode  \27[93m[?]\27[0m Help  \27[91m[q]\27[0m Quit\27[K", auto_footer, cc_footer))
        
        io.write(table.concat(buf))
        io.flush()
    end

    draw_tui()

    while true do
        local k = read_key(50)
        if k == "q" or k == "Q" then
            break
        elseif k == "UP" or k == "k" then
            if selected_idx > 1 then
                selected_idx = selected_idx - 1
                draw_tui()
            end
        elseif k == "DOWN" or k == "j" then
            if selected_idx < #items then
                selected_idx = selected_idx + 1
                draw_tui()
            end
        elseif k == "PAGE_UP" then
            selected_idx = math.max(1, selected_idx - 10)
            draw_tui()
        elseif k == "PAGE_DOWN" then
            selected_idx = math.min(#items, selected_idx + 10)
            draw_tui()
        elseif k == "m" or k == "M" then
            mode = (mode == "music") and "video" or "music"
            refresh_results()
            draw_tui()
        elseif k == "L" or k == "l" then
            is_liked = not is_liked
            is_history = false
            refresh_results()
            draw_tui()
        elseif k == "a" or k == "A" then
            auto_play = not auto_play
            draw_tui()
        elseif k == "c" or k == "C" then
            show_cc = not show_cc
            draw_tui()
        elseif k == "h" or k == "H" then
            is_history = not is_history
            if is_history then
                is_liked = false
                items = load_history_items()
                selected_idx = 1
                scroll_offset = 0
                status_msg = string.format("Loaded %d history items", #items)
            else
                refresh_results()
            end
            draw_tui()
        elseif k == "?" then
            show_help_modal()
            draw_tui()
        elseif k == "/" then
            local new_q = prompt_search_query(current_query)
            if new_q and #new_q > 0 then
                current_query = new_q
                is_liked = false
                is_history = false
                refresh_results()
            end
            draw_tui()
        elseif k == "ENTER" then
            while #items > 0 and selected_idx >= 1 and selected_idx <= #items do
                local sel = items[selected_idx]
                save_history_item(sel)
                local exit_code = play_item(sel, mode, browser, cookies_file, use_window, proxy, insecure, show_cc, sub_lang)
                draw_tui()
                if auto_play and (exit_code == 0 or exit_code == true) and selected_idx < #items then
                    selected_idx = selected_idx + 1
                else
                    break
                end
            end
        end
    end

    disable_raw_mode()
end

-- =========================================================================
-- 8. CLI Entrypoint & Argument Parsing
-- =========================================================================
local function run_self_tests()
    print("=== Running yt.lua Internal Self-Tests ===")
    -- 1. codepoint_to_utf8
    assert(codepoint_to_utf8(65) == "A", "codepoint_to_utf8 ASCII failed")
    assert(codepoint_to_utf8(0x4E2D) == "\228\184\173", "codepoint_to_utf8 CJK failed")
    print("  [✓] codepoint_to_utf8 passed")

    -- 2. unescape_unicode
    assert(unescape_unicode("Hello \\u0057orld") == "Hello World", "unescape_unicode basic failed")
    assert(unescape_unicode("\\ud83d\\ude00") == "\240\159\152\128", "unescape_unicode surrogate pair failed")
    print("  [✓] unescape_unicode passed")

    -- 3. parse_json_field
    local sample_json = '{"id":"test12345","title":"Test \\u0026 Demo \\"Video\\"","uploader":"Test Artist","duration":185,"duration_str":"03:05"}'
    assert(parse_json_field(sample_json, "id") == "test12345", "parse_json_field id failed")
    assert(parse_json_field(sample_json, "title") == 'Test & Demo "Video"', "parse_json_field title unescape failed")
    assert(parse_json_field(sample_json, "uploader") == "Test Artist", "parse_json_field uploader failed")
    assert(parse_json_field(sample_json, "duration") == 185, "parse_json_field duration failed")
    assert(parse_json_field(sample_json, "duration_str") == "03:05", "parse_json_field duration_str failed")
    print("  [✓] parse_json_field passed")

    -- 4. format_duration
    assert(format_duration(nil) == "--:--", "format_duration nil failed")
    assert(format_duration(0) == "--:--", "format_duration 0 failed")
    assert(format_duration(75) == "01:15", "format_duration mm:ss failed")
    assert(format_duration(3661) == "1:01:01", "format_duration h:mm:ss failed")
    print("  [✓] format_duration passed")

    -- 5. sanitize_display_text
    local raw_title = "Best of lofi hip hop 2021 \226\156\168 [beats to relax/study to]" -- contains ✨
    local sanitized = sanitize_display_text(raw_title)
    assert(sanitized == "Best of lofi hip hop 2021 [beats to relax/study to]", "sanitize_display_text failed: " .. sanitized)
    local emoji_title = "\240\159\148\165 HOT HITS \240\159\142\167 Pop" -- 🔥, 🎧
    assert(sanitize_display_text(emoji_title) == "HOT HITS Pop", "sanitize_display_text failed on emojis")
    print("  [✓] sanitize_display_text passed")

    -- 6. display_width & utf8_truncate (East Asian Full-Width CJK Support)
    local cjk_sample = "周杰倫 Jay Chou"
    assert(display_width(cjk_sample) == 15, "display_width for CJK failed, expected 15, got " .. display_width(cjk_sample))
    local trunc_cjk = utf8_truncate(cjk_sample, 10)
    assert(display_width(trunc_cjk) <= 10, "utf8_truncate exceeded max_cols")
    assert(trunc_cjk:sub(-2) == "..", "utf8_truncate missing .. ending")
    print("  [✓] display_width & utf8_truncate passed")

    -- 7. save_history_item & load_history_items
    local test_item = {
        id = "selftest_" .. tostring(os.time()),
        title = "Self Test Video - " .. tostring(os.time()),
        uploader = "SelfTest Channel",
        duration = 120,
        duration_str = "02:00",
    }
    local ok_save, err_save = pcall(save_history_item, test_item)
    assert(ok_save, "save_history_item threw error: " .. tostring(err_save))
    local ok_load, loaded = pcall(load_history_items)
    assert(ok_load, "load_history_items threw error: " .. tostring(loaded))
    assert(type(loaded) == "table", "load_history_items returned non-table")
    local found_test_item = false
    for _, it in ipairs(loaded) do
        if it.id == test_item.id then
            found_test_item = true
            assert(it.title == test_item.title, "History item title mismatch")
            assert(it.uploader == test_item.uploader, "History item uploader mismatch")
            break
        end
    end
    assert(found_test_item, "Saved history item not found in loaded history items")
    print("  [✓] save_history_item & load_history_items passed")

    -- 8. CC / Lyrics status message formatting
    local status_music = build_mpv_status_msg("music", true)
    assert(status_music:find("sub-text", 1, true), "Music CC status format missing sub-text")
    assert(status_music:find("CC/Lyrics:", 1, true), "Music CC status format missing label")
    local status_video = build_mpv_status_msg("video", true)
    assert(status_video:find("sub-text", 1, true), "Video CC status format missing sub-text")
    assert(status_video:find("CC:", 1, true), "Video CC status format missing label")
    local status_no_cc = build_mpv_status_msg("music", false)
    assert(not status_no_cc:find("sub-text", 1, true), "Non-CC status should not contain sub-text")
    print("  [✓] CC / Lyrics status formatting passed")

    print("=== All Internal Self-Tests Passed Successfully ===")
    return true
end

local function print_help()
    print("\27[1;36myt.lua -- Cross-Platform YouTube & Music Terminal Player (LuaJIT FFI)\27[0m")
    print("\nUsage:")
    print("  ./LuaJIT/src/luajit yt.lua [query | url] [options]")
    print("\nOptions:")
    print("  -m, --music           Music mode: audio-only streaming via mpv (default)")
    print("  -v, --video           Video mode: video streaming in terminal via mpv --vo=tct")
    print("  --window              In video mode, play in external MPV GUI window instead of terminal")
    print("  -c, --cc, --lyrics    Show Closed Captions (CC) / lyrics in terminal characters")
    print("  --sub-lang <lang>     Preferred subtitle/lyrics language pattern (default: en.*)")
    print("  --browser <name>      Extract session cookies from browser (firefox, chrome, brave, edge)")
    print("  --no-interactive      Non-interactive script/batch mode (print results and exit)")
    print("  --cookies <file>      Use Netscape format cookies.txt file")
    print("  --proxy <url>         Use HTTP/HTTPS/SOCKS proxy for search and streaming (or $HTTPS_PROXY)")
    print("  --insecure            Disable SSL certificate checks (or $YT_INSECURE=1; auto-retried on SSL fail)")
    print("  --liked               Load user's Liked Music or Liked Videos playlist")
    print("  --test                Run automated self-tests and exit")
    print("  -h, --help            Show this help message")
    print("\nSystem Status:")
    print(string.format("  yt-dlp:    %s", HAS_YTDLP and "\27[32m[Installed]\27[0m" or "\27[31m[Missing - Required for search/streams]\27[0m"))
    print(string.format("  mpv:       %s", HAS_MPV and "\27[32m[Installed]\27[0m" or "\27[31m[Missing - Required for playback]\27[0m"))
    print(string.format("  chafa:     %s", HAS_CHAFA and "\27[32m[Installed]\27[0m" or "\27[90m[Not Detected - Optional for thumbnails]\27[0m"))
    print(string.format("  ffmpeg:    %s", HAS_FFMPEG and "\27[32m[Installed]\27[0m" or "\27[90m[Not Detected]\27[0m"))
    print(string.format("  deno:      %s", HAS_DENO and "\27[32m[Installed - Fast JS solver for yt-dlp]\27[0m" or "\27[90m[Not Detected - Optional for yt-dlp]\27[0m"))
    print("\nExamples:")
    print("  luajit yt.lua \"synthwave radio\"")
    print("  luajit yt.lua --music --lyrics \"never gonna give you up\"")
    print("  luajit yt.lua --music --browser firefox")
    print("  luajit yt.lua --insecure \"lofi hip hop\"")
    print("  luajit yt.lua --proxy http://proxy:8080 \"jazz lounge\"")
    print("  luajit yt.lua --liked --browser chrome")
    print("  luajit yt.lua \"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"")
end

local function main()
    local mode = "music"
    local browser = nil
    local cookies_file = nil
    local is_liked = false
    local use_window = false
    local non_interactive = false
    local show_cc = false
    local sub_lang = "en.*"

    local env_proxy = os.getenv("YT_PROXY") or os.getenv("HTTPS_PROXY") or os.getenv("HTTP_PROXY") or os.getenv("https_proxy") or os.getenv("http_proxy")
    local proxy = (env_proxy and #env_proxy > 0) and env_proxy or nil

    local env_insecure = os.getenv("YT_INSECURE")
    local insecure = (env_insecure == "1" or (env_insecure and env_insecure:lower() == "true"))

    local max_results = 20
    local query_parts = {}

    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "-h" or a == "--help" then
            print_help()
            return
        elseif a == "--test" then
            run_self_tests()
            return
        elseif a == "-m" or a == "--music" then
            mode = "music"
        elseif a == "-v" or a == "--video" then
            mode = "video"
        elseif a == "--window" then
            use_window = true
        elseif a == "-c" or a == "--cc" or a == "--lyrics" or a == "--subtitles" then
            show_cc = true
        elseif a == "--sub-lang" or a == "--sub-langs" or a == "--slang" then
            i = i + 1
            sub_lang = arg[i]
        elseif a == "--liked" then
            is_liked = true
        elseif a == "--no-interactive" then
            non_interactive = true
        elseif a == "--insecure" or a == "--no-check-certificates" or a == "--no-check-certificate" then
            insecure = true
        elseif a == "--proxy" then
            i = i + 1
            proxy = arg[i]
        elseif a == "--max-results" then
            i = i + 1
            max_results = tonumber(arg[i]) or 20
        elseif a == "--browser" then
            i = i + 1
            browser = arg[i]
        elseif a == "--cookies" then
            i = i + 1
            cookies_file = arg[i]
        elseif a:sub(1, 1) ~= "-" then
            table.insert(query_parts, a)
        end
        i = i + 1
    end

    local query = #query_parts > 0 and table.concat(query_parts, " ") or nil

    if non_interactive or (not is_stdin_tty()) then
        local q = query or "lofi hip hop"
        local res, err, used_insecure = fetch_youtube_results(q, mode, browser, cookies_file, max_results, is_liked, proxy, insecure)
        if not res then
            io.stderr:write("Error: " .. tostring(err) .. "\n")
            os.exit(1)
        end
        local sec_note = (used_insecure or insecure) and " [CORP SSL/INSECURE]" or ""
        print(string.format("\27[1;36m=== YouTube Results for '%s' (%s mode)%s ===\27[0m", q, mode:upper(), sec_note))
        for idx, item in ipairs(res) do
            local t_disp = utf8_truncate(item.title, 50)
            local t_pad = string.rep(" ", math.max(0, 50 - display_width(t_disp)))
            local up_disp = utf8_truncate(item.uploader, 22)
            local up_pad = string.rep(" ", math.max(0, 22 - display_width(up_disp)))
            print(string.format("  %02d. %s%s | %s%s | %s", idx, t_disp, t_pad, up_disp, up_pad, item.duration_str))
        end
        return
    end

    run_app(query, mode, browser, cookies_file, is_liked, use_window, proxy, insecure, show_cc, sub_lang)
end

main()
