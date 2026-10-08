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
       - Music Mode (default with -m / --music): Searches YouTube & streams audio-only
         via mpv --no-video.
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
local raw_mode_enabled = false
local safe_popen = io.popen
local safe_execute = os.execute
local kernel32
local msvcrt
local pending_keys = {}
local enqueue_pending_bytes

enqueue_pending_bytes = function(buf, start_idx, len)
    for i = start_idx, len - 1 do
        local b
        if type(buf) == "string" then
            b = buf:byte(i + 1)
        else
            b = bit.band(buf[i], 0xFF)
        end
        if b == 10 or b == 13 then
            table.insert(pending_keys, "ENTER")
        elseif b == 9 then
            table.insert(pending_keys, "TAB")
        elseif b == 127 or b == 8 then
            table.insert(pending_keys, "BACKSPACE")
        elseif b == 21 then
            table.insert(pending_keys, "CTRL_U")
        elseif (b >= 32 and b <= 126) or b >= 128 then
            table.insert(pending_keys, string.char(b))
        end
    end
end


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

        HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
        BOOL WriteFile(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
        BOOL ReadFile(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
        BOOL CloseHandle(HANDLE hObject);
        BOOL PeekNamedPipe(HANDLE hNamedPipe, void* lpBuffer, DWORD nBufferSize, DWORD* lpBytesRead, DWORD* lpTotalBytesAvail, DWORD* lpBytesLeftThisMessage);
    ]]

    kernel32 = ffi.load("kernel32")
    msvcrt = ffi.load("msvcrt")
    local STD_INPUT_HANDLE = ffi.cast("DWORD", -10)
    local STD_OUTPUT_HANDLE = ffi.cast("DWORD", -11)

    local orig_in_mode = ffi.new("DWORD[1]")
    raw_mode_enabled = false

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
        if #pending_keys > 0 then
            return table.remove(pending_keys, 1)
        end
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
                elseif ch == 4 then
                    return "CTRL_D"
                elseif ch == 21 then
                    return "CTRL_U"
                elseif (ch >= 32 and ch <= 126) or ch >= 128 then
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
    -- macOS/BSD declare tcflag_t/speed_t as 64-bit and set NCCS to 20, while Linux
-- uses 32-bit and NCCS=32.  Picking the wrong layout shifts every field offset
-- and makes tcgetattr overrun the LuaJIT buffer, so select it at cdef time.
-- On Linux the definition below passes through byte-for-byte unchanged.
local function posix_termios_cdef(def)
    if ffi.os == "OSX" or ffi.os == "BSD" then
        def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
        def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
        def = def:gsub("c_cc%[32%]", "c_cc[20]")
        def = def:gsub("unsigned%s+short%s+sun_family;", "unsigned char sun_len; unsigned char sun_family;")
        def = def:gsub("sun_path%[108%]", "sun_path[104]")
    end
    return def
end

ffi.cdef(posix_termios_cdef[[
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
        long write(int fd, const void *buf, size_t count);
        int close(int fd);
        int socket(int domain, int type, int protocol);
        int connect(int sockfd, const void *addr, unsigned int addrlen);
        int unlink(const char *pathname);
        struct sockaddr_un {
            unsigned short sun_family;
            char sun_path[108];
        };
        int isatty(int fd);
        int usleep(unsigned int usec);
        int clock_gettime(int clk_id, struct timespec *tp);
]])


    local STDIN_FILENO = 0
    local TCSANOW = 0
    local ICANON = 2
    local ECHO = 8
    local POLLIN = 1

    local TIOCGWINSZ = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413
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
    raw_mode_enabled = false

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
        if #pending_keys > 0 then
            return table.remove(pending_keys, 1)
        end
        timeout_ms = timeout_ms or -1
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 16)
            if n > 0 then
                local c0 = bit.band(key_buf[0], 0xFF)
                if c0 == 27 then
                    if n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 65 then enqueue_pending_bytes(key_buf, 3, n); return "UP" end
                        if c2 == 66 then enqueue_pending_bytes(key_buf, 3, n); return "DOWN" end
                        if c2 == 67 then enqueue_pending_bytes(key_buf, 3, n); return "RIGHT" end
                        if c2 == 68 then enqueue_pending_bytes(key_buf, 3, n); return "LEFT" end
                        if c2 == 72 then enqueue_pending_bytes(key_buf, 3, n); return "HOME" end
                        if c2 == 70 then enqueue_pending_bytes(key_buf, 3, n); return "END" end
                        if c2 == 53 and n >= 4 and key_buf[3] == 126 then enqueue_pending_bytes(key_buf, 4, n); return "PAGE_UP" end
                        if c2 == 54 and n >= 4 and key_buf[3] == 126 then enqueue_pending_bytes(key_buf, 4, n); return "PAGE_DOWN" end
                    elseif n == 1 then
                        return "ESC"
                    end
                elseif c0 == 10 or c0 == 13 then
                    enqueue_pending_bytes(key_buf, 1, n)
                    return "ENTER"
                elseif c0 == 9 then
                    enqueue_pending_bytes(key_buf, 1, n)
                    return "TAB"
                elseif c0 == 127 or c0 == 8 then
                    enqueue_pending_bytes(key_buf, 1, n)
                    return "BACKSPACE"
                elseif c0 == 4 then
                    enqueue_pending_bytes(key_buf, 1, n)
                    return "CTRL_D"
                elseif c0 == 21 then
                    enqueue_pending_bytes(key_buf, 1, n)
                    return "CTRL_U"
                elseif (c0 >= 32 and c0 <= 126) or c0 >= 128 then
                    enqueue_pending_bytes(key_buf, 1, n)
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

local function copy_to_clipboard(text)
    if not text or #text == 0 then return false end
    if is_windows then
        local p = io.popen("clip", "w")
        if p then
            p:write(text)
            p:close()
            return true
        end
    else
        local p = io.popen("wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null || xsel -b 2>/dev/null || pbcopy 2>/dev/null", "w")
        if p then
            p:write(text)
            p:close()
            return true
        end
    end
    return false
end

local function open_in_browser(url)
    if not url or #url == 0 then return false end
    if is_windows then
        local cmd = string.format('start "" %q', url)
        local ok = safe_execute(cmd)
        return (ok == 0 or ok == true)
    else
        local cmd = string.format('(xdg-open %q || open %q) 2>/dev/null &', url, url)
        local ok = safe_execute(cmd)
        return (ok == 0 or ok == true)
    end
end

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

local function get_search_history_file()
    return get_cache_dir() .. (is_windows and "\\" or "/") .. "search_history.json"
end

-- Resume playback position: mpv's native watch-later store, kept in our cache dir.
-- Each file holds "# <url>" and "start=<seconds>", so positions can be looked up by URL.
local resume_cfg = { enabled = true, opts = nil }
local RESUME_MIN_SEC = 5

local function get_resume_dir()
    local dir = get_cache_dir() .. (is_windows and "\\" or "/") .. "watch_later"
    if is_windows then
        os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
    return dir
end

local function get_resume_mpv_opts()
    if not resume_cfg.enabled then
        return " --no-resume-playback"
    end
    if not resume_cfg.opts then
        local opts = string.format(' --resume-playback --save-position-on-quit --write-filename-in-watch-later-config --watch-later-directory="%s"', get_resume_dir())
        -- Restore only the position (not sid/aid/volume), when this mpv supports the option.
        local p = safe_popen("mpv --list-options", POPEN_READ_BIN)
        if p then
            local listing = p:read("*a") or ""
            p:close()
            if listing:find("watch-later-options", 1, true) then
                opts = opts .. " --watch-later-options=start"
            end
        end
        resume_cfg.opts = opts
    end
    return resume_cfg.opts
end

local function get_resume_position(url)
    if not resume_cfg.enabled or not url or #url == 0 then return nil end
    local dir = get_resume_dir()
    local list_cmd = is_windows and ('dir /b "' .. dir .. '" 2>nul') or ('ls -1 "' .. dir .. '" 2>/dev/null')
    local p = safe_popen(list_cmd, POPEN_READ_BIN)
    if not p then return nil end
    local names = {}
    for name in p:lines() do
        name = name:gsub("%s+$", "")
        if #name > 0 then table.insert(names, name) end
        if #names >= 500 then break end
    end
    p:close()
    for _, name in ipairs(names) do
        local f = io.open(dir .. (is_windows and "\\" or "/") .. name, "r")
        if f then
            local first = (f:read("*l") or ""):gsub("\r$", "")
            if first == "# " .. url then
                local body = f:read("*a") or ""
                f:close()
                local start = body:match("start=([%d%.]+)")
                local secs = start and tonumber(start)
                if secs and secs >= RESUME_MIN_SEC then
                    return math.floor(secs)
                end
                return nil
            end
            f:close()
        end
    end
    return nil
end

local function delete_resume_position(url)
    if not url or #url == 0 then return false end
    local dir = get_resume_dir()
    local list_cmd = is_windows and ('dir /b "' .. dir .. '" 2>nul') or ('ls -1 "' .. dir .. '" 2>/dev/null')
    local p = safe_popen(list_cmd, POPEN_READ_BIN)
    if not p then return false end
    local names = {}
    for name in p:lines() do
        name = name:gsub("%s+$", "")
        if #name > 0 then table.insert(names, name) end
        if #names >= 500 then break end
    end
    p:close()
    for _, name in ipairs(names) do
        local path = dir .. (is_windows and "\\" or "/") .. name
        local f = io.open(path, "r")
        if f then
            local first = (f:read("*l") or ""):gsub("\r$", "")
            f:close()
            if first == "# " .. url then
                os.remove(path)
                return true
            end
        end
    end
    return false
end

local function normalize_caption_token(w)
    return (w or ""):lower():gsub("[%p%c%s]", "")
end

local function clean_rolling_caption(raw, state)
    if not raw or raw == "" then
        return ""
    end
    -- Unescape HTML entities while preserving newline structure
    raw = raw:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    raw = raw:gsub("&#([0-9]+);", function(code)
        local n = tonumber(code)
        if n and n > 0 and n < 128 then return string.char(n) end
        return ""
    end)
    state = state or {}
    local prev_last = state.prev_last_line or ""
    local prev_disp = state.prev_displayed or ""

    local lines = {}
    for l in raw:gmatch("[^\r\n]+") do
        l = l:gsub("<[^>]+>", ""):gsub("^%s*>>%s*", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
        if #l > 0 then
            table.insert(lines, l)
        end
    end
    if #lines == 0 then return "" end

    -- 1. Multi-line roll-up deduplication
    local new_lines = {}
    for i, line in ipairs(lines) do
        local is_dup = false
        if i == 1 and #lines > 1 then
            local norm_line = normalize_caption_token(line)
            local norm_last = normalize_caption_token(prev_last)
            local norm_disp = normalize_caption_token(prev_disp)
            if norm_line == norm_last or norm_line == norm_disp or (norm_disp ~= "" and norm_disp:sub(-#norm_line) == norm_line) then
                is_dup = true
            end
        end
        if not is_dup then
            table.insert(new_lines, line)
        end
    end
    if #new_lines == 0 then
        return prev_disp
    end

    local candidate = table.concat(new_lines, " ")

    -- 2. 1-line exact duplicate check (suppresses 10ms transition cues)
    if #lines == 1 then
        local norm_c = normalize_caption_token(candidate)
        if norm_c == normalize_caption_token(prev_last) or norm_c == normalize_caption_token(prev_disp) then
            return prev_disp
        end
    end

    -- 3. Word-level prefix-suffix overlap deduplication (for sliding window / word-level roll-up)
    if prev_disp ~= "" and #candidate > 0 then
        local c_words = {}
        for w in candidate:gmatch("%S+") do table.insert(c_words, w) end
        local p_words = {}
        for w in prev_disp:gmatch("%S+") do table.insert(p_words, w) end

        local max_overlap = math.min(#c_words - 1, #p_words)
        for k = max_overlap, 1, -1 do
            if k >= 2 or (#candidate > 5 and #lines > 1) then
                local match = true
                for j = 1, k do
                    if normalize_caption_token(p_words[#p_words - k + j]) ~= normalize_caption_token(c_words[j]) then
                        match = false
                        break
                    end
                end
                if match then
                    local stripped = {}
                    for j = k + 1, #c_words do table.insert(stripped, c_words[j]) end
                    candidate = table.concat(stripped, " ")
                    break
                end
            end
        end
    end

    if #candidate == 0 then
        return prev_disp
    end

    state.prev_last_line = lines[#lines]
    state.prev_displayed = candidate
    return candidate
end

local function get_mpv_cc_script()
    local script_file = get_cache_dir() .. (is_windows and "\\" or "/") .. "yt_cc.lua"
    local f, err = io.open(script_file, "w")
    if not f then
        return nil, "Unable to create MPV CC helper: " .. tostring(err)
    end
    f:write([[
local mp = require "mp"

local function normalize_caption_token(w)
    return (w or ""):lower():gsub("[%p%c%s]", "")
end

local cc_state = { prev_last_line = "", prev_displayed = "" }

local function clean_rolling_caption(raw, state)
    if not raw or raw == "" then
        return ""
    end
    state = state or {}
    local prev_last = state.prev_last_line or ""
    local prev_disp = state.prev_displayed or ""

    local lines = {}
    for l in raw:gmatch("[^\r\n]+") do
        l = l:gsub("<[^>]+>", ""):gsub("^%s*>>%s*", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
        if #l > 0 then
            table.insert(lines, l)
        end
    end
    if #lines == 0 then return "" end

    local new_lines = {}
    for i, line in ipairs(lines) do
        local is_dup = false
        if i == 1 and #lines > 1 then
            local norm_line = normalize_caption_token(line)
            local norm_last = normalize_caption_token(prev_last)
            local norm_disp = normalize_caption_token(prev_disp)
            if norm_line == norm_last or norm_line == norm_disp or (norm_disp ~= "" and norm_disp:sub(-#norm_line) == norm_line) then
                is_dup = true
            end
        end
        if not is_dup then
            table.insert(new_lines, line)
        end
    end
    if #new_lines == 0 then
        return prev_disp
    end

    local candidate = table.concat(new_lines, " ")

    if #lines == 1 then
        local norm_c = normalize_caption_token(candidate)
        if norm_c == normalize_caption_token(prev_last) or norm_c == normalize_caption_token(prev_disp) then
            return prev_disp
        end
    end

    if prev_disp ~= "" and #candidate > 0 then
        local c_words = {}
        for w in candidate:gmatch("%S+") do table.insert(c_words, w) end
        local p_words = {}
        for w in prev_disp:gmatch("%S+") do table.insert(p_words, w) end

        local max_overlap = math.min(#c_words - 1, #p_words)
        for k = max_overlap, 1, -1 do
            if k >= 2 or (#candidate > 5 and #lines > 1) then
                local match = true
                for j = 1, k do
                    if normalize_caption_token(p_words[#p_words - k + j]) ~= normalize_caption_token(c_words[j]) then
                        match = false
                        break
                    end
                end
                if match then
                    local stripped = {}
                    for j = k + 1, #c_words do table.insert(stripped, c_words[j]) end
                    candidate = table.concat(stripped, " ")
                    break
                end
            end
        end
    end

    if #candidate == 0 then
        return prev_disp
    end

    state.prev_last_line = lines[#lines]
    state.prev_displayed = candidate
    return candidate
end

mp.register_event("seek", function()
    cc_state.prev_last_line = ""
    cc_state.prev_displayed = ""
    mp.set_property("user-data/yt-cc", "")
end)

mp.observe_property("sub-text", "string", function(_, value)
    if not value or value == "" then
        mp.set_property("user-data/yt-cc", "")
        return
    end
    local cleaned = clean_rolling_caption(value, cc_state)
    if cleaned and #cleaned > 0 then
        mp.set_property("user-data/yt-cc", cleaned)
    end
end)

local cc_styles = {
    { name = "White (High Contrast)", color = "#FFFFFFFF", back = "#000000E6", outline = 2 },
    { name = "Yellow (BBC/Netflix Standard)", color = "#FFFF00FF", back = "#000000F0", outline = 2 },
    { name = "Cyan (Cool)", color = "#00FFFFFF", back = "#000000F0", outline = 2 },
}
local cur_style_idx = 1
mp.add_forced_key_binding("Alt+c", "cycle_cc_style", function()
    cur_style_idx = (cur_style_idx % #cc_styles) + 1
    local s = cc_styles[cur_style_idx]
    mp.set_property("sub-color", s.color)
    mp.set_property("sub-back-color", s.back)
    mp.set_property("sub-outline-size", s.outline)
    mp.osd_message("CC Style: " .. s.name, 2)
end)

mp.observe_property("track-list", "native", function(_, tracks)
    if not tracks then return end
    for _, track in ipairs(tracks) do
        if track.type == "sub" and ((track.lang and track.lang:find("%%-orig")) or (track.title and track.title:find("Original"))) then
            if not track.selected then
                mp.set_property("sid", track.id)
                break
            end
        end
    end
end)
]])
    f:close()
    return script_file
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
    -- HTML entity unescaping (e.g. &#39; in YouTube captions)
    s = s:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&#([0-9]+);", function(code)
        local n = tonumber(code)
        if n and n > 0 and n < 128 then return string.char(n) end
        return ""
    end)
    -- Strip ASS style tags {\...} and HTML tags <...>
    s = s:gsub("{[^}]-}", ""):gsub("<[^>]->", "")
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

local function strip_ansi(str)
    return (str or ""):gsub("\27%[[0-9;]*[a-zA-Z]", "")
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
                elseif next_b == "n" then table.insert(chars, "\n")
                elseif next_b == "r" then table.insert(chars, "\r")
                elseif next_b == "t" then table.insert(chars, "\t")
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
    local bool = line:match('"' .. key .. '"%s*:%s*(true)') or line:match('"' .. key .. '"%s*:%s*(false)')
    if bool == "true" then return true end
    if bool == "false" then return false end
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

-- =========================================================================
-- Local Starred Favorites & Audio EQ Presets
-- =========================================================================
local function get_favorites_file()
    return get_cache_dir() .. (is_windows and "\\" or "/") .. "favorites.json"
end

local function load_favorites()
    local fav_file = get_favorites_file()
    local f = io.open(fav_file, "r")
    if not f then return {} end
    local items = {}
    for line in f:lines() do
        local id = parse_json_field(line, "id")
        local title = parse_json_field(line, "title")
        if (id or line:find('"url"')) and title then
            local uploader = parse_json_field(line, "uploader") or "YouTube"
            local duration = parse_json_field(line, "duration") or 0
            local duration_str = parse_json_field(line, "duration_str") or "--:--"
            local url = parse_json_field(line, "url") or (id and ("https://www.youtube.com/watch?v=" .. id))
            table.insert(items, {
                id = id or url,
                url = url,
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

local function is_favorite(item_or_id)
    if not item_or_id then return false end
    local key = type(item_or_id) == "table" and (item_or_id.id or item_or_id.url) or item_or_id
    if not key or #key == 0 then return false end
    local favs = load_favorites()
    for _, it in ipairs(favs) do
        if it.id == key or it.url == key then return true end
    end
    return false
end

local function save_favorite_item(item)
    if not item or not (item.id or item.url) then return false end
    local fav_file = get_favorites_file()
    local existing = load_favorites()
    local key = item.id or item.url
    local filtered = {}
    for _, it in ipairs(existing) do
        if it.id ~= key and it.url ~= key then
            table.insert(filtered, it)
        end
    end
    table.insert(filtered, 1, item)
    if #filtered > 500 then table.remove(filtered) end
    local out = io.open(fav_file, "w")
    if out then
        local function esc(s) return (s or ""):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' ') end
        for _, it in ipairs(filtered) do
            local item_id = it.id or it.url
            local item_url = it.url or (it.id and ("https://www.youtube.com/watch?v=" .. it.id))
            out:write(string.format('{"id":%q,"url":%q,"title":%q,"uploader":%q,"duration":%d,"duration_str":%q}\n',
                item_id, item_url, esc(it.title), esc(it.uploader), it.duration or 0, esc(it.duration_str)))
        end
        out:close()
        return true
    end
    return false
end

local function remove_favorite_item(item_or_id)
    if not item_or_id then return false end
    local key = type(item_or_id) == "table" and (item_or_id.id or item_or_id.url) or item_or_id
    if not key or #key == 0 then return false end
    local fav_file = get_favorites_file()
    local existing = load_favorites()
    local filtered = {}
    local removed = false
    for _, it in ipairs(existing) do
        if it.id == key or it.url == key then
            removed = true
        else
            table.insert(filtered, it)
        end
    end
    if removed then
        local out = io.open(fav_file, "w")
        if out then
            local function esc(s) return (s or ""):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' ') end
            for _, it in ipairs(filtered) do
                local item_id = it.id or it.url
                local item_url = it.url or (it.id and ("https://www.youtube.com/watch?v=" .. it.id))
                out:write(string.format('{"id":%q,"url":%q,"title":%q,"uploader":%q,"duration":%d,"duration_str":%q}\n',
                    item_id, item_url, esc(it.title), esc(it.uploader), it.duration or 0, esc(it.duration_str)))
            end
            out:close()
        end
    end
    return removed
end

local function toggle_favorite_item(item)
    if not item or not (item.id or item.url) then return false end
    if is_favorite(item) then
        remove_favorite_item(item)
        return false
    else
        save_favorite_item(item)
        return true
    end
end

local EQ_PRESETS = {
    { key = "flat",  name = "Flat / Bypass (Original Audio)",             filter = "" },
    { key = "night", name = "Night Mode (Dynamic Range Normalizer)",      filter = "dynaudnorm=f=150:g=15" },
    { key = "bass",  name = "Bass Boost (+6dB Low End)",                  filter = "equalizer=f=64:t=q:w=1:g=6:f=125:t=q:w=1:g=4" },
    { key = "vocal", name = "Vocal Clarity (Podcasts & Interviews)",      filter = "equalizer=f=1000:t=q:w=1:g=3:f=3000:t=q:w=1:g=4:f=100:t=q:w=1:g=-4" },
    { key = "lofi",  name = "Lo-Fi Warmth (Analog High-Cut)",             filter = "lowpass=f=4500" },
}

local function get_eq_filter(key)
    for _, p in ipairs(EQ_PRESETS) do
        if p.key == key then return p.filter end
    end
    return ""
end

local function get_eq_name(key)
    for _, p in ipairs(EQ_PRESETS) do
        if p.key == key then return p.name end
    end
    return "Flat / Bypass"
end

local function is_valid_eq_preset(key)
    if not key then return false end
    for _, p in ipairs(EQ_PRESETS) do
        if p.key == key then return true end
    end
    return false
end

local function save_search_history(query)
    if not query or type(query) ~= "string" then return false end
    query = query:match("^%s*(.-)%s*$")
    if #query == 0 then return false end

    local sfile = get_search_history_file()
    local existing = {}
    local f = io.open(sfile, "r")
    if f then
        for line in f:lines() do
            local q = parse_json_field(line, "query")
            if q and #q > 0 and q ~= query then
                table.insert(existing, q)
                if #existing >= 50 then break end
            end
        end
        f:close()
    end

    local out = io.open(sfile, "w")
    if out then
        local function esc(s) return (s or ""):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' ') end
        out:write(string.format('{"query":%q}\n', esc(query)))
        for _, q in ipairs(existing) do
            out:write(string.format('{"query":%q}\n', esc(q)))
        end
        out:close()
        return true
    end
    return false
end

local function load_search_history()
    local sfile = get_search_history_file()
    local f = io.open(sfile, "r")
    if not f then return {} end
    local queries = {}
    for line in f:lines() do
        local q = parse_json_field(line, "query")
        if q and #q > 0 then
            table.insert(queries, q)
        end
    end
    f:close()
    return queries
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
    query = tostring(query or "")
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

local SITE_SEARCH_PREFIXES = {
    youtube = "ytsearch",
    soundcloud = "scsearch",
    twitch = "twsearch",
}

local function normalize_site(site)
    site = (site or "youtube"):lower():gsub("^https?://", ""):gsub("^www%.", "")
    if site == "youtube.com" or site == "music.youtube.com" then return "youtube" end
    if site == "soundcloud.com" then return "soundcloud" end
    if site == "twitch.tv" then return "twitch" end
    return site
end

local function build_search_spec(query, mode, max_results, is_liked, filters, site)
    site = normalize_site(site)
    local is_direct_url = query:match("^https?://") or query:match("^www%.") or query:match("^youtu%.be/")
    if is_liked then
        if mode == "music" then
            return '"https://music.youtube.com/playlist?list=LM"'
        else
            return '":ytfavorites"'
        end
    elseif is_direct_url then
        return string.format("%q", query)
    elseif site == "youtube" and filters and filters.sort and filters.sort ~= "relevance" then
        local sp_map = {
            views = "CAM%253D",
            date = "CAI%253D",
            rating = "CAE%253D"
        }
        local sp = sp_map[filters.sort]
        if sp then
            local enc_term = query:gsub("%s+", "+")
            return string.format('"https://www.youtube.com/results?search_query=%s&sp=%s"', enc_term, sp)
        else
            return string.format('"ytsearch%d:%s"', max_results, query:gsub('"', '\\"'))
        end
    elseif SITE_SEARCH_PREFIXES[site] then
        return string.format('"%s%d:%s"', SITE_SEARCH_PREFIXES[site], max_results, query:gsub('"', '\\"'))
    else
        return string.format('"ytsearch%d:%s"', max_results, query:gsub('"', '\\"'))
    end
end

local function fetch_youtube_results(query, mode, browser, cookies_file, max_results, is_liked, proxy, insecure, filters, site)
    max_results = max_results or 20
    site = normalize_site(site)
    local is_direct_url = query:match("^https?://") or query:match("^www%.") or query:match("^youtu%.be/")

    local items = {}
    local err_lines = {}

    if HAS_YTDLP then
        local search_spec = build_search_spec(query, mode, max_results, is_liked, filters, site)

        if not is_direct_url and not SITE_SEARCH_PREFIXES[site] and not is_liked then
            return nil, "Text search is not supported for site '" .. site .. "'. Use a direct URL or a supported site (youtube, soundcloud, twitch).", insecure
        end

        local extra_opts = ""
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
                        local uploader = parse_json_field(line, "uploader") or parse_json_field(line, "channel") or site
                        local duration = parse_json_field(line, "duration") or 0
                        local thumb = parse_json_field(line, "thumbnail")
                        local item_url = parse_json_field(line, "webpage_url") or parse_json_field(line, "url")
                        if not item_url and site == "youtube" then
                            item_url = "https://www.youtube.com/watch?v=" .. id
                        end
                        if item_url then
                            table.insert(items, {
                                id = id,
                                url = item_url,
                                title = title,
                                uploader = uploader,
                                duration = duration,
                                duration_str = format_duration(duration),
                                thumbnail = thumb,
                            })
                        end
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

    if filters and filters.duration and filters.duration ~= "all" then
        local filtered = {}
        for _, it in ipairs(items) do
            local d = it.duration or 0
            if filters.duration == "short" and (d == 0 or d < 240) then
                table.insert(filtered, it)
            elseif filters.duration == "medium" and d >= 240 and d <= 1200 then
                table.insert(filtered, it)
            elseif filters.duration == "long" and d > 1200 then
                table.insert(filtered, it)
            end
        end
        items = filtered
    end

    if #items > 0 then
        return items, nil, insecure
    end

    -- Check if SSL verification failed and auto-retry in insecure mode
    local err_text = table.concat(err_lines, "\n")
    if not insecure and (err_text:find("CERTIFICATE_VERIFY_FAILED") or err_text:find("certificate verify failed") or err_text:find("SSL") or err_text:find("certificate problem")) then
        io.stderr:write("\n\27[33m[yt] Corporate SSL inspection detected -- retrying in insecure mode...\27[0m\n")
        local retry_items, retry_err = fetch_youtube_results(query, mode, browser, cookies_file, max_results, is_liked, proxy, true, filters, site)
        if retry_items and #retry_items > 0 then
            return retry_items, nil, true
        end
        if retry_err then err_text = retry_err end
    end

    -- Automatic Fallback: Direct Web Scrape via curl (works even if yt-dlp is blocked or broken)
    if site == "youtube" and not is_liked and not is_direct_url then
        local fallback_items = scrape_youtube_search(query, max_results, proxy, insecure)
        if fallback_items and #fallback_items > 0 then
            return fallback_items, nil, insecure
        elseif not insecure then
            local fallback_insecure = scrape_youtube_search(query, max_results, proxy, true)
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
    elseif not is_direct_url and not SITE_SEARCH_PREFIXES[site] then
        return nil, "Text search is not supported for site '" .. site .. "'. Use a direct URL or a supported site (youtube, soundcloud, twitch).", insecure
    end

    return nil, "No results found for '" .. query .. "'.", insecure
end

local function fetch_radio_recommendations(item, browser, cookies_file, proxy, insecure)
    if not item then return {} end
    local vid = item.id
    if not vid and item.url then
        vid = item.url:match("v=([%w_%-]+)") or item.url:match("youtu%.be/([%w_%-]+)")
    end
    local recs = {}
    if vid and #vid > 0 then
        local mix_url = string.format("https://www.youtube.com/watch?v=%s&list=RD%s", vid, vid)
        local results = fetch_youtube_results(mix_url, "music", browser, cookies_file, 8, false, proxy, insecure, { sort = "relevance", duration = "all" }, "youtube")
        if results and #results > 0 then
            for _, r in ipairs(results) do
                if r.id ~= vid and (not item.url or r.url ~= item.url) then
                    table.insert(recs, r)
                    if #recs >= 5 then break end
                end
            end
        end
    end
    if #recs == 0 and item.uploader and #item.uploader > 0 and item.uploader ~= "YouTube" then
        local search_term = item.uploader .. " music"
        local results = fetch_youtube_results(search_term, "music", browser, cookies_file, 6, false, proxy, insecure, { sort = "relevance", duration = "all" }, "youtube")
        if results and #results > 0 then
            for _, r in ipairs(results) do
                if r.id ~= vid and (not item.url or r.url ~= item.url) then
                    table.insert(recs, r)
                    if #recs >= 5 then break end
                end
            end
        end
    end
    return recs
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
            msg = msg .. "${?user-data/yt-cc:\\n  >> CC/Lyrics: ${user-data/yt-cc}}"
        end
        return msg
    else
        -- Keep progress immediately below the frame and render normalized CC beneath it.
        if show_cc then
            return "\27[s\27[1B\27[2K\27[1B\27[2K\27[1B\27[2K\27[2A\27[1B[${playback-time} / ${duration}]\27[1B${?user-data/yt-cc:  >> CC: ${user-data/yt-cc}}\27[u"
        end
        return "\27[s\27[1B\27[2K\27[1B\27[2K\27[1B\27[2K\27[2A\27[1B[${playback-time} / ${duration}]\27[u"
    end
end

local function to_mpv_slang(sub_lang)
    if not sub_lang or sub_lang == "" or sub_lang == "en.*" or sub_lang == "en" then
        return "en-orig,en,eng,en-US,en-GB"
    end
    local parts = {}
    for lang in sub_lang:gmatch("[^,]+") do
        local clean = lang:gsub("%.%*", ""):gsub("%*", ""):match("^%s*(.-)%s*$")
        if #clean > 0 then
            table.insert(parts, clean .. "-orig")
            table.insert(parts, clean)
            if clean == "en" then
                table.insert(parts, "eng")
                table.insert(parts, "en-US")
                table.insert(parts, "en-GB")
            elseif clean == "zh" then
                table.insert(parts, "chi")
                table.insert(parts, "zho")
                table.insert(parts, "zh-Hans")
                table.insert(parts, "zh-Hant")
            end
        end
    end
    return #parts > 0 and table.concat(parts, ",") or "en-orig,en,eng,en-US,en-GB"
end

local function render_mini_player_lines(cur, is_paused, volume, pos, dur, sub_text, show_cc, term_w, track_idx, total_tracks, has_sub_track, last_sub_text, speed, eq_preset)
    term_w = math.max(30, term_w or 80)
    dur = (dur and dur > 0) and dur or (cur and cur.duration or 0)
    pos = pos or 0
    sub_text = sub_text or ""
    last_sub_text = last_sub_text or ""
    local lines = {}

    local st_badge = is_paused and "\27[1;93m[PAUSED]\27[0m" or "\27[1;92m[PLAYING]\27[0m"
    local vol_str = string.format("\27[96mVol: %d%%\27[0m", volume or 100)
    local spd_badge = (speed and speed ~= 1.0) and string.format(" \27[1;36m[%.2fx]\27[0m", speed) or ""
    local eq_badge = (eq_preset and eq_preset ~= "flat") and string.format(" \27[1;35m[%s]\27[0m", eq_preset:upper()) or ""
    local title = cur and cur.title or "Unknown"
    local title_part = utf8_truncate(title, math.max(10, term_w - 52))
    
    -- Border 1 (Top Border)
    local prefix1 = string.format("+-- > Now Playing: %s --- %s%s%s --- %s ", title_part, vol_str, spd_badge, eq_badge, st_badge)
    local pad1 = math.max(0, term_w - display_width(strip_ansi(prefix1)) - 1)
    table.insert(lines, string.format("\27[1;36m%s%s+\27[0m\27[K\n", prefix1, string.rep("-", pad1)))

    -- Progress Line (Row 2)
    local cur_fmt = (pos and pos > 0) and format_duration(pos) or "00:00"
    local dur_fmt = (dur and dur > 0) and format_duration(dur) or "--:--"
    local bar_w = math.max(10, math.min(30, term_w - 50))
    local pct = (dur > 0) and math.min(1.0, math.max(0.0, pos / dur)) or 0
    local filled = math.floor(pct * bar_w)
    local prog_bar = string.rep("=", filled) .. (filled < bar_w and ">" or "") .. string.rep("-", math.max(0, bar_w - 1 - filled))
    local track_info = (track_idx and total_tracks and total_tracks > 0) and string.format("  \27[90m(Track %d/%d)\27[0m", track_idx, total_tracks) or ""
    local prog_content = string.format(" \27[1;36m|\27[0m \27[1;33m%s/%s\27[0m [\27[1;32m%s\27[0m]%s", cur_fmt, dur_fmt, prog_bar, track_info)
    local pad_prog = math.max(0, term_w - display_width(strip_ansi(prog_content)) - 1)
    table.insert(lines, string.format("%s%s\27[1;36m|\27[0m\27[K\n", prog_content, string.rep(" ", pad_prog)))

    -- Dedicated CC / Subtitles Row (Row 3)
    if show_cc then
        local max_cc_w = math.max(10, term_w - 14)
        local cc_content
        if has_sub_track == false then
            cc_content = "\27[90m[CC] (No subtitles available for this track)\27[0m"
        elseif #sub_text > 0 then
            local clean_sub = sanitize_display_text(sub_text)
            cc_content = string.format("\27[1;93m[CC]\27[0m \27[1;97m\"%s\"\27[0m", utf8_truncate(clean_sub, max_cc_w))
        elseif #last_sub_text > 0 then
            local clean_sub = sanitize_display_text(last_sub_text)
            cc_content = string.format("\27[1;93m[CC]\27[0m \27[90m\"%s\"\27[0m", utf8_truncate(clean_sub, max_cc_w))
        else
            cc_content = "\27[90m[CC] (Listening for speech / instrumental...)\27[0m"
        end
        local cc_line = string.format(" \27[1;36m|\27[0m %s", cc_content)
        local pad_cc = math.max(0, term_w - display_width(strip_ansi(cc_line)) - 1)
        table.insert(lines, string.format("%s%s\27[1;36m|\27[0m\27[K\n", cc_line, string.rep(" ", pad_cc)))
    end

    -- Border 2 (Controls / Bottom Border)
    local ctrl_hint_text = (term_w >= 96)
        and "[Space] Pause  [c] CC  [s] Skip  [x] Stop  [<-/->] Seek  [9/0] Vol  [[/]] Spd  [e] EQ"
        or ((term_w >= 85)
            and "[Space] Pause  [c] CC  [s] Skip  [x] Stop  [<-/->] Seek  [9/0] Vol  [[/]] Spd"
            or ((term_w >= 70)
                and "[Space] Pause  [c] CC  [s] Skip  [x] Stop  [<-/->] Seek  [9/0] Vol"
                or "[Space] Pause  [c] CC  [s] Skip  [x] Stop"))
    local max_hint_w = math.max(10, term_w - 6)
    if display_width(ctrl_hint_text) > max_hint_w then
        ctrl_hint_text = utf8_truncate(ctrl_hint_text, max_hint_w)
    end
    local ctrl_hint = "\27[90m" .. ctrl_hint_text .. "\27[0m"
    local prefix2 = string.format("+-- %s ", ctrl_hint)
    local pad2 = math.max(0, term_w - display_width(strip_ansi(prefix2)) - 1)
    table.insert(lines, string.format("\27[1;36m+-- %s %s+\27[0m\27[K\n", ctrl_hint, string.rep("-", pad2)))

    return lines
end

-- =========================================================================
-- 5. Background Mini-Player & Foreground Playback Controller
-- =========================================================================
local function make_sockaddr_un(path)
    local addr = ffi.new("struct sockaddr_un")
    if ffi.os == "OSX" or ffi.os == "BSD" then
        pcall(function() addr.sun_len = ffi.sizeof(addr) end)
    end
    addr.sun_family = 1 -- AF_UNIX
    ffi.copy(addr.sun_path, path)
    return addr
end

local MpvController = {
    is_playing = false,
    current_item = nil,
    time_pos = 0,
    duration = 0,
    volume = 100,
    is_paused = false,
    sub_text = "",
    last_sub_text = "",
    has_sub_track = nil,
    has_switched_orig = false,
    is_eof = false,
    pipe_handle = nil,
    sock_fd = nil,
    pipe_name = nil,
    read_buf = "",
    cc_state = { prev_last_line = "", prev_displayed = "" },
    speed = 1.0,
    eq_preset = "flat",
}

function MpvController:init_observers()
    self:send_command('{"command": ["observe_property", 1, "time-pos"]}')
    self:send_command('{"command": ["observe_property", 2, "duration"]}')
    self:send_command('{"command": ["observe_property", 3, "pause"]}')
    self:send_command('{"command": ["observe_property", 4, "sub-text"]}')
    self:send_command('{"command": ["observe_property", 5, "volume"]}')
    self:send_command('{"command": ["observe_property", 6, "eof-reached"]}')
    self:send_command('{"command": ["observe_property", 7, "sub"]}')
    self:send_command('{"command": ["observe_property", 8, "track-list"]}')
    self:send_command('{"command": ["observe_property", 9, "speed"]}')
end

function MpvController:send_command(json_str)
    if is_windows and self.pipe_handle then
        local data = json_str .. "\n"
        local written = ffi.new("DWORD[1]")
        kernel32.WriteFile(self.pipe_handle, data, #data, written, nil)
    elseif not is_windows and self.sock_fd and self.sock_fd >= 0 then
        local data = json_str .. "\n"
        ffi.C.write(self.sock_fd, data, #data)
    end
end

function MpvController:start(item, show_cc, sub_lang, browser, cookies_file, proxy, insecure, sub_font_size)
    self:stop()

    local pipe_id = tostring(math.floor(get_now_sec() * 1000))
    local pipe_path = is_windows and ("\\\\.\\pipe\\yt_mpv_" .. pipe_id) or ("/tmp/yt_mpv_" .. pipe_id .. ".sock")
    self.pipe_name = pipe_path

    local raw_opts = {}
    table.insert(raw_opts, "write-subs=")
    table.insert(raw_opts, "write-auto-subs=")
    table.insert(raw_opts, string.format("sub-langs=%s", sub_lang or "en.*"))

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
    local ytdl_raw_opts = #raw_opts > 0 and string.format(' --ytdl-raw-options=%q', table.concat(raw_opts, ",")) or ""

    local extra_mpv_opts = ""
    if insecure then
        extra_mpv_opts = extra_mpv_opts .. " --tls-verify=no"
    end
    if proxy and #proxy > 0 then
        extra_mpv_opts = extra_mpv_opts .. string.format(" --http-proxy=%q", proxy)
    end
    local font_opt = (sub_font_size and sub_font_size > 0) and string.format(" --sub-font-size=%d", sub_font_size) or ""
    extra_mpv_opts = extra_mpv_opts .. string.format(" --subs-fallback=yes --sub-auto=all --sub-visibility=yes%s --slang=%s", font_opt, to_mpv_slang(sub_lang))
    extra_mpv_opts = extra_mpv_opts .. get_resume_mpv_opts()
    if self.speed and self.speed ~= 1.0 then
        extra_mpv_opts = extra_mpv_opts .. string.format(" --speed=%.2f", self.speed)
    end
    if self.eq_preset and self.eq_preset ~= "flat" then
        local af_filter = get_eq_filter(self.eq_preset)
        if #af_filter > 0 then
            extra_mpv_opts = extra_mpv_opts .. string.format(" --af=%q", af_filter)
        end
    end

    local cmd
    if is_windows then
        cmd = string.format('start /B "" mpv --no-video --load-scripts=no --idle=yes --input-ipc-server=%s --ytdl-format="bestaudio/best" %s%s %q >nul 2>&1',
            pipe_path, ytdl_raw_opts, extra_mpv_opts, item.url)
    else
        cmd = string.format('mpv --no-video --load-scripts=no --idle=yes --input-ipc-server=%s --ytdl-format="bestaudio/best" %s%s %q >/dev/null 2>&1 &',
            pipe_path, ytdl_raw_opts, extra_mpv_opts, item.url)
    end
    safe_execute(cmd)

    if is_windows then
        local GENERIC_READ = 0x80000000
        local GENERIC_WRITE = 0x40000000
        local OPEN_EXISTING = 3
        local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)
        for _ = 1, 50 do
            sleep_ms(100)
            local h = kernel32.CreateFileA(pipe_path, bit.bor(GENERIC_READ, GENERIC_WRITE), 0, nil, OPEN_EXISTING, 0, nil)
            if h ~= INVALID_HANDLE_VALUE then
                self.pipe_handle = h
                break
            end
        end
    else
        for _ = 1, 30 do
            sleep_ms(20)
            local fd = ffi.C.socket(1, 1, 0) -- AF_UNIX=1, SOCK_STREAM=1
            if fd >= 0 then
                local addr = make_sockaddr_un(pipe_path)
                if ffi.C.connect(fd, addr, ffi.sizeof(addr)) == 0 then
                    self.sock_fd = fd
                    break
                end
                ffi.C.close(fd)
            end
        end
    end

    self.is_playing = true
    self.current_item = item
    self.time_pos = 0
    self.duration = item.duration or 0
    self.volume = 100
    self.is_paused = false
    self.sub_text = ""
    self.last_sub_text = ""
    self.has_sub_track = nil
    self.has_switched_orig = false
    self.is_eof = false
    self.read_buf = ""
    self.cc_state = { prev_last_line = "", prev_displayed = "" }

    self:init_observers()
end

function MpvController:poll()
    if not self.is_playing then return nil end

    if is_windows and self.pipe_handle then
        local avail = ffi.new("DWORD[1]")
        if kernel32.PeekNamedPipe(self.pipe_handle, nil, 0, nil, avail, nil) ~= 0 and avail[0] > 0 then
            local buf = ffi.new("char[?]", avail[0] + 1)
            local read_bytes = ffi.new("DWORD[1]")
            if kernel32.ReadFile(self.pipe_handle, buf, avail[0], read_bytes, nil) ~= 0 and read_bytes[0] > 0 then
                self.read_buf = self.read_buf .. ffi.string(buf, read_bytes[0])
            end
        end
    elseif not is_windows then
        if not self.sock_fd and self.pipe_name then
            local fd = ffi.C.socket(1, 1, 0)
            if fd >= 0 then
                local addr = make_sockaddr_un(self.pipe_name)
                if ffi.C.connect(fd, addr, ffi.sizeof(addr)) == 0 then
                    self.sock_fd = fd
                    self:init_observers()
                else
                    ffi.C.close(fd)
                end
            end
        end
        if self.sock_fd and self.sock_fd >= 0 then
            local pfd = ffi.new("struct pollfd", { fd = self.sock_fd, events = 1, revents = 0 })
            while true do
                local ret = ffi.C.poll(pfd, 1, 0)
                if ret > 0 and bit.band(pfd.revents, 1) ~= 0 then
                    local buf = ffi.new("char[4096]")
                    local n = ffi.C.read(self.sock_fd, buf, 4096)
                    if n > 0 then
                        self.read_buf = self.read_buf .. ffi.string(buf, n)
                    else
                        self.is_eof = true
                        break
                    end
                elseif ret > 0 and (bit.band(pfd.revents, 0x0010) ~= 0 or bit.band(pfd.revents, 0x0008) ~= 0) then
                    self.is_eof = true
                    break
                else
                    break
                end
            end
        end
    end

    while true do
        local nl = self.read_buf:find("\n")
        if not nl then break end
        local line = self.read_buf:sub(1, nl - 1)
        self.read_buf = self.read_buf:sub(nl + 1)

        local prop = parse_json_field(line, "name")
        if line:find('"event":"end-file"') or (prop == "eof-reached" and parse_json_field(line, "data") == true) then
            self.is_eof = true
        elseif prop == "time-pos" then
            local t = parse_json_field(line, "data")
            if t then self.time_pos = math.floor(t) end
        elseif prop == "duration" then
            local d = parse_json_field(line, "data")
            if d then self.duration = math.floor(d) end
        elseif prop == "pause" then
            local p = parse_json_field(line, "data") == true
            self.is_paused = p
        elseif prop == "volume" then
            local v = parse_json_field(line, "data")
            if v then self.volume = math.floor(v) end
        elseif prop == "speed" then
            local sp = parse_json_field(line, "data")
            if sp and tonumber(sp) then self.speed = tonumber(sp) end
        elseif prop == "sub-text" then
            local s = parse_json_field(line, "data") or ""
            if #s > 0 then
                local cleaned = clean_rolling_caption(s, self.cc_state)
                if cleaned and #cleaned > 0 then
                    self.sub_text = cleaned
                    self.last_sub_text = cleaned
                end
                self.has_sub_track = true
            else
                self.sub_text = ""
            end
        elseif prop == "sub" then
            local d = parse_json_field(line, "data")
            if d == false or d == nil or line:find('"data":null') or line:find('"data":"no"') then
                self.has_sub_track = false
            else
                self.has_sub_track = true
            end
        elseif prop == "track-list" then
            if not self.has_switched_orig then
                for obj in line:gmatch("{([^{}]+)}") do
                    local t_type = obj:match('"type":"([^"]+)"')
                    if t_type == "sub" then
                        local t_id = obj:match('"id":(%d+)')
                        local t_lang = obj:match('"lang":"([^"]+)"') or ""
                        local t_title = obj:match('"title":"([^"]+)"') or ""
                        local t_sel = obj:match('"selected":true') ~= nil
                        if (t_lang:find("%%-orig") or t_title:find("Original")) and t_id then
                            if not t_sel then
                                self:send_command(string.format('{"command": ["set_property", "sid", %d]}', tonumber(t_id)))
                            end
                            self.has_switched_orig = true
                            break
                        end
                    end
                end
            end
        end
    end

    return {
        is_playing = self.is_playing,
        item = self.current_item,
        time_pos = self.time_pos,
        duration = self.duration,
        volume = self.volume,
        is_paused = self.is_paused,
        sub_text = self.sub_text,
        is_eof = self.is_eof
    }
end

function MpvController:toggle_pause()
    self:send_command('{"command": ["cycle", "pause"]}')
    self.is_paused = not self.is_paused
end

function MpvController:seek(delta)
    self:send_command(string.format('{"command": ["seek", %d, "relative"]}', delta))
    self.cc_state = { prev_last_line = "", prev_displayed = "" }
    self.sub_text = ""
end

function MpvController:change_volume(delta)
    self:send_command(string.format('{"command": ["add", "volume", %d]}', delta))
end

function MpvController:set_sub_font_size(size)
    self:send_command(string.format('{"command": ["set_property", "sub-font-size", %d]}', size))
end

function MpvController:cycle_sub()
    self.has_switched_orig = true
    self:send_command('{"command": ["cycle", "sub"]}')
    self.cc_state = { prev_last_line = "", prev_displayed = "" }
    self.sub_text = ""
    self.last_sub_text = ""
end

function MpvController:set_speed(speed)
    speed = math.max(0.5, math.min(2.5, speed))
    self.speed = speed
    self:send_command(string.format('{"command": ["set_property", "speed", %.2f]}', speed))
end

function MpvController:set_eq(preset_key)
    self.eq_preset = preset_key or "flat"
    local filter = get_eq_filter(self.eq_preset)
    self:send_command(string.format('{"command": ["set_property", "af", %q]}', filter))
end

function MpvController:quit_command()
    -- Save the position when stopped mid-track; drop a stale entry when stopped near the end.
    if resume_cfg.enabled and self.is_playing and not self.is_eof and (self.time_pos or 0) > 0 then
        local dur = (self.duration and self.duration > 0) and self.duration or (self.current_item and self.current_item.duration or 0)
        if dur > 0 and self.time_pos >= dur - 10 then
            if self.current_item and self.current_item.url then
                delete_resume_position(self.current_item.url)
            end
            self:send_command('{"command": ["delete-watch-later-config"]}')
            return '{"command": ["quit"]}'
        end
        return '{"command": ["quit-watch-later"]}'
    end
    return '{"command": ["quit"]}'
end

function MpvController:stop()
    if is_windows and self.pipe_handle then
        self:send_command(self:quit_command())
        sleep_ms(50)
        kernel32.CloseHandle(self.pipe_handle)
        self.pipe_handle = nil
    elseif not is_windows and self.sock_fd then
        self:send_command(self:quit_command())
        sleep_ms(50)
        ffi.C.close(self.sock_fd)
        self.sock_fd = nil
    end
    if not is_windows and self.pipe_name then
        pcall(function() ffi.C.unlink(self.pipe_name) end)
    end
    self.pipe_name = nil
    self.is_playing = false
    self.current_item = nil
    self.time_pos = 0
    self.duration = 0
    self.volume = 100
    self.is_paused = false
    self.sub_text = ""
    self.last_sub_text = ""
    self.has_sub_track = nil
    self.has_switched_orig = false
    self.is_eof = false
    self.read_buf = ""
    self.cc_state = { prev_last_line = "", prev_displayed = "" }
end
local function play_item(item, mode, browser, cookies_file, use_external_window, proxy, insecure, show_cc, sub_lang, sub_font_size, sub_color)
    if not HAS_MPV then
        io.write("\27[H\27[2J\27[1;31mError: mpv is not installed.\27[0m\n\nPlease install mpv to play audio/video streams.\nPress any key to return...")
        io.flush()
        read_key()
        return
    end

    local raw_opts = {}
    if show_cc or mode == "video" then
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
    local ytdl_raw_opts = #raw_opts > 0 and string.format(' --ytdl-raw-options=%q', table.concat(raw_opts, ",")) or ""

    local extra_mpv_opts = ""
    if insecure then
        extra_mpv_opts = extra_mpv_opts .. " --tls-verify=no"
    end
    if proxy and #proxy > 0 then
        extra_mpv_opts = extra_mpv_opts .. string.format(" --http-proxy=%q", proxy)
    end
    local use_native_window_subtitles = mode == "video" and use_external_window
    local cc_script
    if mode == "video" then
        local script_err
        cc_script, script_err = get_mpv_cc_script()
        if not cc_script then
            io.stderr:write(script_err .. "\n")
            return 1
        end
        extra_mpv_opts = extra_mpv_opts .. string.format(" --script=%q", cc_script)
    end
    if show_cc or mode == "video" then
        -- Terminal video uses the status line for CC; GUI video uses normal subtitle rendering.
        local sub_vis = (mode == "video" and not use_external_window) and "no" or (show_cc and "yes" or "no")
        local font_opt = (sub_font_size and sub_font_size > 0) and string.format(" --sub-font-size=%d", sub_font_size) or ""
        local yt_style_opts = ""
        if mode == "video" and use_external_window then
            -- Replicate YouTube.com subtitle appearance with high contrast against white backgrounds:
            -- 90% opaque dark box (#000000E6), crisp 2px black outline, and subtle drop shadow.
            local text_color = (sub_color == "yellow") and "#FFFF00FF" or ((sub_color == "cyan") and "#00FFFFFF" or "#FFFFFFFF")
            yt_style_opts = string.format(' --sub-border-style=background-box --sub-back-color="#000000E6" --sub-color=%q --sub-outline-size=2 --sub-outline-color="#FF000000" --sub-shadow-offset=1.5 --sub-shadow-color="#FF000000" --sub-font="Roboto,Arial,sans-serif" --sub-bold=yes --sub-ass-override=force --sub-margin-y=36', text_color)
        end
        extra_mpv_opts = extra_mpv_opts .. string.format(" --subs-fallback=yes --sub-auto=all --sub-visibility=%s%s%s --slang=%s", sub_vis, font_opt, yt_style_opts, to_mpv_slang(sub_lang))
    end

    local term_w, term_h = get_terminal_size()
    extra_mpv_opts = extra_mpv_opts .. get_resume_mpv_opts()
    if MpvController.speed and MpvController.speed ~= 1.0 then
        extra_mpv_opts = extra_mpv_opts .. string.format(" --speed=%.2f", MpvController.speed)
    end
    if MpvController.eq_preset and MpvController.eq_preset ~= "flat" then
        local af_filter = get_eq_filter(MpvController.eq_preset)
        if #af_filter > 0 then
            extra_mpv_opts = extra_mpv_opts .. string.format(" --af=%q", af_filter)
        end
    end
    local resume_pos = get_resume_position(item.url)
    local status_msg = build_mpv_status_msg(mode, (show_cc or mode == "video") and not use_native_window_subtitles)
    -- Unix shells expand ${...} before mpv sees it; preserve MPV property syntax.
    local command_status_msg = is_windows and status_msg or status_msg:gsub("%$", "\\$")
    local mpv_cmd

    if mode == "music" then
        -- Audio-only streaming with OSD status (terminal mode: load-scripts=no)
        mpv_cmd = string.format(
            'mpv --no-video --load-scripts=no --hwdec=auto --msg-level=ffmpeg=fatal --term-osd-bar --ytdl-format="bestaudio/best" '
            .. '--term-status-msg="%s" '
            .. '%s%s %q',
            command_status_msg, ytdl_raw_opts, extra_mpv_opts, item.url
        )
    else
        -- Video playback
        if use_external_window then
            -- GUI window mode: keep scripts enabled (mpv-cut, shaders, OSC, etc. work in GUI window)
            mpv_cmd = string.format('mpv --hwdec=auto --term-status-msg="%s" %s%s %q', command_status_msg, ytdl_raw_opts, extra_mpv_opts, item.url)
        else
            -- Terminal ASCII/Half-block video:
            -- 1. vo-tct-buffering=frame eliminates redraw tearing
            -- 2. Keep a fixed bottom area for the short CC-only status line
            -- 3. Avoid title/time wrapping, which leaves stale rows on Windows consoles
            local h_offset = 5
            mpv_cmd = string.format(
                'mpv --vo=tct --vo-tct-buffering=frame --msg-level=ffmpeg=fatal --sub-visibility=no --video-margin-ratio-bottom=0.15 --vo-tct-width=%d --vo-tct-height=%d --load-scripts=no --hwdec=auto --term-osd=no '
                .. '--ytdl-format="bestvideo[height<=480]+bestaudio/best[height<=480]/best" '
                .. '--term-status-msg="%s" '
                .. '%s%s %q',
                math.max(10, term_w), math.max(6, term_h - h_offset),
                command_status_msg,
                ytdl_raw_opts, extra_mpv_opts, item.url
            )
        end
    end

    disable_raw_mode()
    io.write("\27[H\27[2J\27[1;36m> Connecting to YouTube stream: \27[1;33m" .. item.title .. "\27[0m\n")
    if resume_pos then
        io.write(string.format("\27[1;92m> Resuming from %s\27[0m\n", format_duration(resume_pos)))
    end
    io.write("\n")
    io.flush()

    local exit_code = safe_execute(mpv_cmd)
    if exit_code ~= 0 and exit_code ~= true then
        io.write("\n\27[1;31m[Playback Error] mpv exited with code: " .. tostring(exit_code) .. "\27[0m\n")
        io.write("\27[1;33mTroubleshooting Tips:\27[0m\n")
        io.write("  * Ensure yt-dlp is updated (run: pip install -U yt-dlp or yt-dlp -U)\n")
        io.write("  * If YouTube blocked the stream, try: --browser <chrome|firefox|edge>\n")
        io.write("  * In video mode, try external window player: --window\n")
        io.write("  * For corporate networks or SSL issues: --insecure\n")
        io.write("\nPress any key to return to menu...")
        io.flush()
        read_key()
    end

    enable_raw_mode()
    return exit_code
end

-- =========================================================================
-- 6. Interactive Modals (Download, Queue, Filters, Search & Help)
-- =========================================================================
local function ensure_downloads_dir()
    if is_windows then
        safe_execute('if not exist downloads mkdir downloads')
    else
        safe_execute('mkdir -p downloads')
    end
end

local function download_item(item, mode, browser, cookies_file, proxy, insecure)
    if not HAS_YTDLP then
        io.write("\27[H\27[2J\27[1;31mError: yt-dlp is not installed.\27[0m\n\nPlease install yt-dlp to download tracks.\nPress any key to return...")
        io.flush()
        read_key()
        return
    end

    ensure_downloads_dir()
    local was_raw = raw_mode_enabled
    disable_raw_mode()
    io.write("\27[H\27[2J")
    io.write(string.format("\27[1;36m=== Downloading to ./downloads/ (%s mode) ===\27[0m\n\n", mode:upper()))
    io.write(string.format("  \27[1;37mTitle:\27[0m    %s\n", item.title or "Unknown"))
    io.write(string.format("  \27[1;37mUploader:\27[0m %s\n", item.uploader or "YouTube"))
    io.write(string.format("  \27[1;37mURL:\27[0m      %s\n\n", item.url))
    io.flush()

    local extra_args = ""
    if browser and #browser > 0 then
        extra_args = extra_args .. string.format(" --cookies-from-browser %s", browser)
    elseif cookies_file and #cookies_file > 0 then
        extra_args = extra_args .. string.format(" --cookies %q", cookies_file)
    end
    if insecure then
        extra_args = extra_args .. " --no-check-certificates"
    end
    if proxy and #proxy > 0 then
        extra_args = extra_args .. string.format(" --proxy %q", proxy)
    end

    local out_tmpl = "downloads/%(title)s.%(ext)s"
    local dl_cmd
    if mode == "music" then
        if HAS_FFMPEG then
            dl_cmd = string.format('yt-dlp -x --audio-format mp3 --add-metadata --embed-thumbnail -o %q%s %q',
                out_tmpl, extra_args, item.url)
        else
            dl_cmd = string.format('yt-dlp -f "bestaudio/best" -o %q%s %q',
                out_tmpl, extra_args, item.url)
        end
    else
        if HAS_FFMPEG then
            dl_cmd = string.format('yt-dlp -f "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" --merge-output-format mp4 -o %q%s %q',
                out_tmpl, extra_args, item.url)
        else
            dl_cmd = string.format('yt-dlp -f "best[height<=1080]/best" -o %q%s %q',
                out_tmpl, extra_args, item.url)
        end
    end

    local exit_code = safe_execute(dl_cmd)
    if exit_code == 0 then
        io.write("\n\27[1;32m[✓] Download completed successfully to ./downloads/\27[0m\n")
    else
        io.write(string.format("\n\27[1;31m[!] Download exited with code %s\27[0m\n", tostring(exit_code)))
    end

    if was_raw then
        io.write("\n\27[90mPress any key to return to viewer...\27[0m")
        io.flush()
        read_key()
        enable_raw_mode()
    end
end

local function show_queue_modal(queue)
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(74, term_w - 4)
    local box_x = math.max(1, math.floor((term_w - box_w) / 2))

    local function line_pad(text)
        local vis_len = display_width(strip_ansi(text))
        local pad = math.max(0, box_w - 2 - vis_len)
        return text .. string.rep(" ", pad) .. "\27[1;36m|\27[0m"
    end

    if #queue == 0 then
        local empty_box_h = 6
        local empty_box_y = math.max(2, math.floor((term_h - empty_box_h) / 2))
        local buf = {
            string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", empty_box_y, box_x, string.rep("-", box_w - 2)),
            string.format("\27[%d;%dH%s", empty_box_y + 1, box_x, line_pad("\27[1;36m|  \27[1;37mUp-Next Playback Queue (Empty)\27[0m")),
            string.format("\27[%d;%dH%s", empty_box_y + 2, box_x, line_pad("\27[1;36m|  \27[90mNo tracks queued. Press [Tab] on any search result to add.\27[0m")),
            string.format("\27[%d;%dH%s", empty_box_y + 3, box_x, line_pad("\27[1;36m|  \27[90mPress any key to close...\27[0m")),
            string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", empty_box_y + 4, box_x, string.rep("-", box_w - 2)),
        }
        io.write(table.concat(buf))
        io.flush()
        read_key()
        return nil
    end

    local max_items = math.min(10, math.max(3, term_h - 10))
    local box_h = max_items + 6
    local box_y = math.max(2, math.floor((term_h - box_h) / 2))

    local q_sel = 1
    local q_scroll = 0

    local function draw_queue()
        q_sel = math.max(1, math.min(#queue, q_sel))
        if q_sel <= q_scroll then
            q_scroll = q_sel - 1
        elseif q_sel > q_scroll + max_items then
            q_scroll = q_sel - max_items
        end

        local buf = {}
        table.insert(buf, string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", box_y, box_x, string.rep("-", box_w - 2)))
        table.insert(buf, string.format("\27[%d;%dH%s", box_y + 1, box_x,
            line_pad(string.format("\27[1;36m|  \27[1;37mUp-Next Playback Queue (%d track%s)\27[0m", #queue, (#queue == 1 and "" or "s")))))
        table.insert(buf, string.format("\27[%d;%dH+%s+\27[0m", box_y + 2, box_x, string.rep("-", box_w - 2)))

        for r = 1, max_items do
            local idx = q_scroll + r
            local line_y = box_y + 2 + r
            if idx <= #queue then
                local it = queue[idx]
                local is_s = (idx == q_sel)
                local prefix = is_s and "\27[1;92m> \27[1;37;44m" or "  \27[90m"
                local num_str = string.format("%02d. ", idx)
                local max_t = box_w - 24
                local t = utf8_truncate(it.title, max_t)
                local t_pad = string.rep(" ", math.max(0, max_t - display_width(t)))
                local dur = it.duration_str or "--:--"
                local dur_pad = string.rep(" ", math.max(0, 7 - #dur))
                
                local line_content
                if is_s then
                    line_content = string.format("%s%s%s%s %s%s\27[0m", prefix, num_str, t, t_pad, dur, dur_pad)
                else
                    line_content = string.format("%s%s\27[37m%s%s \27[33m%s%s\27[0m", prefix, num_str, t, t_pad, dur, dur_pad)
                end
                table.insert(buf, string.format("\27[%d;%dH%s", line_y, box_x, line_pad(string.format("\27[1;36m| \27[0m%s", line_content))))
            else
                table.insert(buf, string.format("\27[%d;%dH%s", line_y, box_x, line_pad("\27[1;36m| ")))
            end
        end

        local foot_y = box_y + 3 + max_items
        table.insert(buf, string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", foot_y, box_x, string.rep("-", box_w - 2)))
        table.insert(buf, string.format("\27[%d;%dH%s", foot_y + 1, box_x,
            line_pad("\27[1;36m| \27[93m[Enter]\27[0m Play  \27[93m[o]\27[0m Open  \27[93m[y]\27[0m Copy  \27[93m[d/Bksp]\27[0m Del  \27[93m[c]\27[0m Clear  \27[90m[Esc/q] Close\27[0m")))
        table.insert(buf, string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", foot_y + 2, box_x, string.rep("-", box_w - 2)))

        io.write(table.concat(buf))
        io.flush()
    end

    draw_queue()

    while true do
        local k = read_key(50)
        if k == "ESC" or k == "q" then
            return nil
        elseif k == "UP" or k == "k" then
            if q_sel > 1 then
                q_sel = q_sel - 1
                draw_queue()
            end
        elseif k == "DOWN" or k == "j" then
            if q_sel < #queue then
                q_sel = q_sel + 1
                draw_queue()
            end
        elseif k == "ENTER" then
            return q_sel
        elseif k == "o" or k == "O" or k == "b" or k == "B" then
            if #queue > 0 and q_sel >= 1 and q_sel <= #queue then
                local sel = queue[q_sel]
                local url = sel.url or (sel.id and ("https://www.youtube.com/watch?v=" .. sel.id))
                if url and open_in_browser(url) then
                    status_msg = "\27[1;92m✓ Opened in browser: \27[0m" .. utf8_truncate(sel.title, 28)
                    draw_queue()
                end
            end
        elseif k == "y" or k == "Y" then
            if #queue > 0 and q_sel >= 1 and q_sel <= #queue then
                local sel = queue[q_sel]
                local url = sel.url or (sel.id and ("https://www.youtube.com/watch?v=" .. sel.id))
                if url and copy_to_clipboard(url) then
                    status_msg = "\27[1;92m✓ Copied URL: \27[0m" .. utf8_truncate(sel.title, 28)
                    draw_queue()
                end
            end
        elseif k == "d" or k == "D" or k == "BACKSPACE" then
            if #queue > 0 and q_sel >= 1 and q_sel <= #queue then
                table.remove(queue, q_sel)
                if #queue == 0 then
                    return nil
                end
                if q_sel > #queue then q_sel = #queue end
                draw_queue()
            end
        elseif k == "c" or k == "C" then
            for i = #queue, 1, -1 do
                table.remove(queue, i)
            end
            return nil
        end
    end
end

local function show_filter_modal(filters)
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(66, term_w - 4)
    local box_h = 17
    local box_x = math.max(1, math.floor((term_w - box_w) / 2))
    local box_y = math.max(2, math.floor((term_h - box_h) / 2))

    local sort_val = filters.sort or "relevance"
    local dur_val = filters.duration or "all"
    local initial_sort = sort_val
    local initial_dur = dur_val

    local function line_pad(text)
        local vis_len = display_width(strip_ansi(text))
        local pad = math.max(0, box_w - 2 - vis_len)
        return text .. string.rep(" ", pad) .. "\27[1;36m|\27[0m"
    end

    local function draw_modal()
        local lines = {
            string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
            line_pad("\27[1;36m|  \27[1;37mSearch Filters & Sorting Options\27[0m"),
            string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
            line_pad("\27[1;36m|  \27[1;33mSort By:\27[0m"),
            line_pad(string.format("\27[1;36m|    %s", (sort_val == "relevance" and "\27[1;92m[1] (*) Relevance\27[0m" or "\27[90m[1] ( ) Relevance\27[0m"))),
            line_pad(string.format("\27[1;36m|    %s", (sort_val == "views" and "\27[1;92m[2] (*) View Count (Popular)\27[0m" or "\27[90m[2] ( ) View Count (Popular)\27[0m"))),
            line_pad(string.format("\27[1;36m|    %s", (sort_val == "date" and "\27[1;92m[3] (*) Upload Date (Latest)\27[0m" or "\27[90m[3] ( ) Upload Date (Latest)\27[0m"))),
            line_pad(string.format("\27[1;36m|    %s", (sort_val == "rating" and "\27[1;92m[4] (*) Rating (High to Low)\27[0m" or "\27[90m[4] ( ) Rating (High to Low)\27[0m"))),
            line_pad("\27[1;36m|"),
            line_pad("\27[1;36m|  \27[1;33mDuration:\27[0m"),
            line_pad(string.format("\27[1;36m|    %s", (dur_val == "all" and "\27[1;92m[5] (*) All Durations\27[0m" or "\27[90m[5] ( ) All Durations\27[0m"))),
            line_pad(string.format("\27[1;36m|    %s", (dur_val == "short" and "\27[1;92m[6] (*) Short (< 4 minutes)\27[0m" or "\27[90m[6] ( ) Short (< 4 minutes)\27[0m"))),
            line_pad(string.format("\27[1;36m|    %s", (dur_val == "medium" and "\27[1;92m[7] (*) Medium (4 - 20 minutes)\27[0m" or "\27[90m[7] ( ) Medium (4 - 20 minutes)\27[0m"))),
            line_pad(string.format("\27[1;36m|    %s", (dur_val == "long" and "\27[1;92m[8] (*) Long (> 20 minutes)\27[0m" or "\27[90m[8] ( ) Long (> 20 minutes)\27[0m"))),
            string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
            line_pad("\27[1;36m|  \27[90m[1-4] Set Sort   [5-8] Set Duration   [Enter/Esc] Done\27[0m"),
            string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
        }

        for idx, line in ipairs(lines) do
            io.write(string.format("\27[%d;%dH%s", box_y + idx - 1, box_x, line))
        end
        io.flush()
    end

    draw_modal()

    while true do
        local k = read_key(50)
        if k == "ESC" or k == "ENTER" or k == "q" then
            break
        elseif k == "1" then
            sort_val = "relevance"
            draw_modal()
        elseif k == "2" then
            sort_val = "views"
            draw_modal()
        elseif k == "3" then
            sort_val = "date"
            draw_modal()
        elseif k == "4" then
            sort_val = "rating"
            draw_modal()
        elseif k == "5" then
            dur_val = "all"
            draw_modal()
        elseif k == "6" then
            dur_val = "short"
            draw_modal()
        elseif k == "7" then
            dur_val = "medium"
            draw_modal()
        elseif k == "8" then
            dur_val = "long"
            draw_modal()
        end
    end

    local changed = (sort_val ~= initial_sort or dur_val ~= initial_dur)
    filters.sort = sort_val
    filters.duration = dur_val
    return changed
end

local function show_eq_modal(current_preset)
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(66, term_w - 4)
    local box_h = #EQ_PRESETS + 6
    local box_x = math.max(1, math.floor((term_w - box_w) / 2))
    local box_y = math.max(2, math.floor((term_h - box_h) / 2))

    local selected_idx = 1
    for i, p in ipairs(EQ_PRESETS) do
        if p.key == current_preset then
            selected_idx = i
            break
        end
    end

    local function line_pad(text)
        local vis_len = display_width(strip_ansi(text))
        local pad = math.max(0, box_w - 2 - vis_len)
        return text .. string.rep(" ", pad) .. "\27[1;36m|\27[0m"
    end

    local function draw_modal()
        local lines = {
            string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
            line_pad("\27[1;36m|  \27[1;37mAudio Equalizer & Sound Enhancement\27[0m"),
            string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
        }

        for i, p in ipairs(EQ_PRESETS) do
            local is_active = (p.key == current_preset)
            local is_cursor = (i == selected_idx)
            local radio = is_active and "\27[1;92m(*)\27[0m" or "\27[90m( )\27[0m"
            local cursor = is_cursor and "\27[1;93m> \27[0m" or "  "
            local num_key = string.format("\27[93m[%d]\27[0m", i)
            local name_str = is_cursor and ("\27[1;37;44m " .. p.name .. " \27[0m") or p.name
            local item_text = string.format("\27[1;36m| %s%s %s %s", cursor, num_key, radio, name_str)
            table.insert(lines, line_pad(item_text))
        end

        table.insert(lines, string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)))
        table.insert(lines, line_pad("\27[1;36m|  \27[90m[1-5/Up/Dn] Select   [Enter] Apply   [Esc] Dismiss\27[0m"))
        table.insert(lines, string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)))

        for idx, line in ipairs(lines) do
            io.write(string.format("\27[%d;%dH%s", box_y + idx - 1, box_x, line))
        end
        io.flush()
    end

    draw_modal()

    while true do
        local k = read_key(50)
        if k == "ESC" or k == "q" then
            return nil
        elseif k == "ENTER" then
            return EQ_PRESETS[selected_idx].key
        elseif k == "UP" or k == "k" then
            if selected_idx > 1 then
                selected_idx = selected_idx - 1
                draw_modal()
            end
        elseif k == "DOWN" or k == "j" then
            if selected_idx < #EQ_PRESETS then
                selected_idx = selected_idx + 1
                draw_modal()
            end
        else
            local n = tonumber(k)
            if n and n >= 1 and n <= #EQ_PRESETS then
                selected_idx = n
                return EQ_PRESETS[selected_idx].key
            end
        end
    end
end

local function prompt_search_query(current_query)
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(64, term_w - 4)
    local box_x = math.max(1, math.floor((term_w - box_w) / 2))
    local box_y = math.max(2, math.floor(term_h / 3))

    local input_str = current_query or ""
    local search_history = load_search_history()
    local history_idx = 0
    local draft_input = input_str

    local function draw_modal()
        io.write(string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", box_y, box_x, string.rep("-", box_w - 2)))
        
        local title_str = (history_idx > 0)
            and string.format("Search YouTube / URL [Hist %d/%d]:", history_idx, #search_history)
            or "Search YouTube / URL:"
        local title_pad = math.max(0, box_w - 3 - #title_str)
        io.write(string.format("\27[%d;%dH\27[1;36m| \27[1;37m%s\27[0m%s\27[1;36m|\27[0m",
            box_y + 1, box_x, title_str, string.rep(" ", title_pad)))
        
        local display_input = input_str
        if #display_input > box_w - 6 then
            display_input = display_input:sub(#display_input - (box_w - 9))
        end
        local pad = math.max(0, box_w - 6 - #display_input)
        io.write(string.format("\27[%d;%dH\27[1;36m| \27[93m> %s\27[7m \27[0m%s\27[1;36m|\27[0m",
            box_y + 2, box_x, display_input, string.rep(" ", pad)))
        
        local hint_str
        if history_idx > 0 then
            hint_str = string.format("History %d of %d (press [Down] to return)", history_idx, #search_history)
        elseif #search_history > 0 then
            local recents = {}
            for idx = 1, math.min(3, #search_history) do
                table.insert(recents, search_history[idx])
            end
            hint_str = "Recent: " .. table.concat(recents, " | ")
        else
            hint_str = "Type a search term, song title, or video URL"
        end
        if #hint_str > box_w - 4 then
            hint_str = hint_str:sub(1, box_w - 7) .. "..."
        end
        local hint_pad = math.max(0, box_w - 3 - #hint_str)
        io.write(string.format("\27[%d;%dH\27[1;36m| \27[90m%s\27[0m%s\27[1;36m|\27[0m",
            box_y + 3, box_x, hint_str, string.rep(" ", hint_pad)))

        local help_str = (box_w >= 56) and "[Enter] Search  [Up/Dn] Hist  [Ctrl+U] Clear  [Esc] Cancel"
            or ((box_w >= 44) and "[Enter] Search  [Up/Dn] Hist  [Esc] Cancel" or "[Enter] OK  [Esc] Cancel")
        local help_pad = math.max(0, box_w - 3 - #help_str)
        io.write(string.format("\27[%d;%dH\27[1;36m| \27[90m%s\27[0m%s\27[1;36m|\27[0m",
            box_y + 4, box_x, help_str, string.rep(" ", help_pad)))
        io.write(string.format("\27[%d;%dH\27[1;36m+%s+\27[0m", box_y + 5, box_x, string.rep("-", box_w - 2)))
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
        elseif k == "UP" then
            if #search_history > 0 and history_idx < #search_history then
                if history_idx == 0 then
                    draft_input = input_str
                end
                history_idx = history_idx + 1
                input_str = search_history[history_idx]
                draw_modal()
            end
        elseif k == "DOWN" then
            if history_idx > 1 then
                history_idx = history_idx - 1
                input_str = search_history[history_idx]
                draw_modal()
            elseif history_idx == 1 then
                history_idx = 0
                input_str = draft_input
                draw_modal()
            end
        elseif k == "BACKSPACE" then
            history_idx = 0
            if #input_str > 0 then
                input_str = input_str:sub(1, #input_str - 1)
                draw_modal()
            end
        elseif k == "CTRL_U" then
            history_idx = 0
            if #input_str > 0 then
                input_str = ""
                draw_modal()
            end
        elseif k and #k == 1 then
            history_idx = 0
            input_str = input_str .. k
            draw_modal()
        end
    end
end

local function show_help_modal()
    local term_w, term_h = get_terminal_size()
    local box_w = math.min(74, term_w - 4)
    local box_x = math.max(1, math.floor((term_w - box_w) / 2))

    local function line_pad(text)
        local vis_len = display_width(strip_ansi(text))
        local pad = math.max(0, box_w - 2 - vis_len)
        return text .. string.rep(" ", pad) .. "\27[1;36m|\27[0m"
    end

    local help_lines = {
        string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
        line_pad("\27[1;36m|  \27[1;36mYouTube Terminal Viewer -- Shortcut Cheat Sheet\27[0m"),
        string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
        line_pad("\27[1;36m|  \27[1;33mTerminal Navigation & Controls:\27[0m"),
        line_pad("\27[1;36m|    \27[93m[Enter]\27[0m       Play (Mini-Player in Music; Terminal/GUI in Video)"),
        line_pad("\27[1;36m|    \27[93m[P]\27[0m           Full-screen foreground playback"),
        line_pad("\27[1;36m|    \27[93m[Tab]\27[0m         Add selected track to Up-Next queue"),
        line_pad("\27[1;36m|    \27[93m[Q]\27[0m           Open Up-Next queue modal (view/delete/clear)"),
        line_pad("\27[1;36m|    \27[93m[d]\27[0m           Download offline to ./downloads/ (MP3/MP4)"),
        line_pad("\27[1;36m|    \27[93m[o]\27[0m           Open video in default web browser"),
        line_pad("\27[1;36m|    \27[93m[y]\27[0m           Yank (copy) video URL to clipboard"),
        line_pad("\27[1;36m|    \27[93m[f]\27[0m           Search filters (Sort by Views/Date, Duration)"),
        line_pad("\27[1;36m|    \27[93m[/]\27[0m           Open search modal or paste direct URL"),
        line_pad("\27[1;36m|    \27[93m[a]\27[0m           Toggle continuous Auto-Play"),
        line_pad("\27[1;36m|    \27[93m[r]\27[0m           Toggle infinite Radio mode (YouTube Mix)"),
        line_pad("\27[1;36m|    \27[93m[e]\27[0m           Open Audio Equalizer & Sound Enhancements"),
        line_pad("\27[1;36m|    \27[93m[*]\27[0m           Toggle Favorite (Star / Un-star track)"),
        line_pad("\27[1;36m|    \27[93m[F]\27[0m           Toggle Starred Favorites playlist"),
        line_pad("\27[1;36m|    \27[93m[[] / []]\27[0m     Adjust playback speed (-/+0.25x)  [{] Reset"),
        line_pad("\27[1;36m|    \27[93m[c]\27[0m           Toggle Closed Captions (CC / Lyrics)"),
        line_pad("\27[1;36m|    \27[93m[C]\27[0m           Cycle subtitle track (Mini-Player)"),
        line_pad("\27[1;36m|    \27[93m[+ / -]\27[0m       Increase / Decrease CC font size (+/-5 pt)"),
        line_pad("\27[1;36m|    \27[93m[h]\27[0m           Toggle Playback History (recent tracks)"),
        line_pad("\27[1;36m|    \27[93m[m]\27[0m           Toggle between Music and Video mode"),
        line_pad("\27[1;36m|    \27[93m[L]\27[0m           Toggle Liked Songs playlist"),
        line_pad("\27[1;36m|    \27[93m[Up/Dn, k/j]\27[0m  Navigate results list"),
        line_pad("\27[1;36m|    \27[93m[g/G]\27[0m         First / last result   \27[93m[Ctrl-U/D]\27[0m Page up / down"),
        line_pad("\27[1;36m|    \27[93m[M]\27[0m           Load 25 more search results"),
        line_pad("\27[1;36m|    \27[93m[PgUp/PgDn]\27[0m   Scroll 10 tracks up or down"),
        line_pad("\27[1;36m|  \27[1;33mIn-Playback / Mini-Player Controls:\27[0m"),
        line_pad("\27[1;36m|    \27[93m[Space]\27[0m       Pause / Resume playback"),
        line_pad("\27[1;36m|    \27[93m[s]\27[0m           Skip to next track in queue"),
        line_pad("\27[1;36m|    \27[93m[x]\27[0m           Stop playback / mini-player"),
        line_pad("\27[1;36m|    \27[93m[<- / ->]\27[0m     Seek backward / forward 5 seconds"),
        line_pad("\27[1;36m|    \27[93m[9 / 0]\27[0m       Volume down / Volume up (-/+10%)"),
        line_pad("\27[1;36m|    \27[93m[q]\27[0m           Quit application"),
        line_pad("\27[1;36m|  \27[1;33mMPV Video Window Controls:\27[0m"),
        line_pad("\27[1;36m|    \27[93m[v]\27[0m           Toggle subtitle visibility (Show/Hide CC)"),
        line_pad("\27[1;36m|    \27[93m[j / J]\27[0m       Cycle subtitle tracks / languages"),
        line_pad("\27[1;36m|    \27[93m[Alt+c]\27[0m       Cycle CC style (White, Yellow, Cyan)"),
        string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
        line_pad("\27[1;36m|  \27[90mPress any key to close this help modal...\27[0m"),
        string.format("\27[1;36m+%s+\27[0m", string.rep("-", box_w - 2)),
    }

    local box_y = math.max(1, math.floor((term_h - #help_lines) / 2))
    for idx, line in ipairs(help_lines) do
        io.write(string.format("\27[%d;%dH\27[0m%s", box_y + idx - 1, box_x, line))
    end
    io.flush()
    read_key()
end

-- =========================================================================
-- 7. Main Interactive TUI Application
-- =========================================================================
local function run_app(init_query, init_mode, browser, cookies_file, is_liked, use_window, proxy, insecure, init_show_cc, init_sub_lang, init_filters, init_site, init_sub_font_size, init_sub_color, init_radio, init_speed, init_eq, init_favorites)
    local current_query = init_query or ""
    local mode = init_mode or "music"
    local show_cc = (init_show_cc ~= nil) and init_show_cc or true
    local sub_lang = init_sub_lang or "en.*"
    local cc_font_size = (init_sub_font_size and init_sub_font_size > 0) and math.max(10, math.min(120, init_sub_font_size)) or 55
    local sub_color = init_sub_color or "white"
    local site = normalize_site(init_site)
    local selected_idx = 1
    local scroll_offset = 0
    local auto_play = false
    local radio_mode = (init_radio == true)
    local is_history = false
    local is_favorites_view = (init_favorites == true)
    local queue = {}
    local active_filters = init_filters or { sort = "relevance", duration = "all" }
    local result_limit = 25

    if init_speed and tonumber(init_speed) then
        MpvController:set_speed(tonumber(init_speed))
    end
    if init_eq and #init_eq > 0 then
        MpvController:set_eq(init_eq)
    end

    enable_raw_mode()

    local items = {}
    local is_loading = true
    local status_msg = "Loading..."

    local function refresh_results(load_more)
        local old_count = #items
        if not load_more then
            items = {}
            selected_idx = 1
            scroll_offset = 0
            result_limit = 25
        end
        is_loading = true

        local term_w, term_h = get_terminal_size()
        io.write("\27[H\27[2J")
        local filter_tag = ""
        if active_filters.sort ~= "relevance" or active_filters.duration ~= "all" then
            filter_tag = string.format(" [Sort: %s, Dur: %s]", active_filters.sort, active_filters.duration)
        end
        io.write(string.format("\n  \27[1;36m* Searching %s (%s mode%s): \27[1;93m%s\27[0m ...\n",
            site:upper(), mode:upper(), filter_tag, is_liked and "Liked Songs" or current_query))
        io.flush()

        local requested_limit = load_more and (result_limit + 25) or result_limit
        local res, err, used_insecure = fetch_youtube_results(current_query, mode, browser, cookies_file, requested_limit, is_liked, proxy, insecure, active_filters, site)
        if used_insecure then
            insecure = true
        end
        is_loading = false
        if res and #res > 0 then
            if not is_liked and not is_history and current_query and #current_query > 0 then
                save_search_history(current_query)
            end
            if load_more then
                local seen = {}
                for _, item in ipairs(items) do
                    seen[item.url or item.id] = true
                end
                local added = 0
                for _, item in ipairs(res) do
                    local key = item.url or item.id
                    if not seen[key] then
                        table.insert(items, item)
                        seen[key] = true
                        added = added + 1
                    end
                end
                if added > 0 then
                    result_limit = requested_limit
                    status_msg = string.format("Loaded %d more (%d total)", added, #items)
                else
                    status_msg = string.format("No more results (%d loaded)", #items)
                end
            else
                items = res
                status_msg = string.format("Found %d results", #items)
            end
        else
            status_msg = load_more and string.format("No more results (%d loaded)", old_count) or (err or "No results found.")
        end
    end

    local function make_playing_status(item)
        local pos = get_resume_position(item and item.url)
        if pos then
            return string.format("Playing (resumed from %s): %s", format_duration(pos), utf8_truncate(item and item.title or "", 25))
        end
        return "Playing: " .. utf8_truncate(item and item.title or "", 30)
    end

    if is_favorites_view then
        items = load_favorites()
        status_msg = string.format("Loaded %d starred favorites", #items)
    elseif #current_query > 0 or is_liked then
        refresh_results()
    else
        current_query = prompt_search_query(current_query)
        if current_query and #current_query > 0 then
            refresh_results()
        else
            current_query = ""
            status_msg = "Enter a search query with [/]"
        end
    end

    local last_rendered_pos = -1
    local last_rendered_sub = ""
    local last_rendered_pause = nil
    local last_rendered_has_sub = nil
    local last_rendered_last_sub = ""
    local max_list_h = 10
    local last_term_w, last_term_h = get_terminal_size()

    local function draw_tui(full_clear)
        if full_clear then
            io.write("\27[2J\27[H")
            io.flush()
        end
        local term_w, term_h = get_terminal_size()
        local has_cc_row = (MpvController.is_playing and MpvController.current_item and show_cc)
        local player_h = (MpvController.is_playing and MpvController.current_item) and (has_cc_row and 4 or 3) or 0
        max_list_h = math.max(4, term_h - 7 - player_h)

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
        local auto_badge
        if radio_mode then
            auto_badge = "\27[1;92m[RADIO: ON]\27[0m"
        elseif auto_play then
            auto_badge = "\27[1;92m[AUTO: ON]\27[0m"
        else
            auto_badge = "\27[90m[AUTO: OFF]\27[0m"
        end
        local cc_badge = show_cc and "\27[1;92m[CC: ON]\27[0m" or "\27[90m[CC: OFF]\27[0m"
        local q_badge = (#queue > 0) and string.format("\27[1;95m[QUEUE: %d]\27[0m", #queue) or "\27[90m[QUEUE: 0]\27[0m"
        local spd_badge = (MpvController.speed and MpvController.speed ~= 1.0) and string.format(" | \27[1;36m[%.2fx]\27[0m", MpvController.speed) or ""
        local eq_badge = (MpvController.eq_preset and MpvController.eq_preset ~= "flat") and string.format(" | \27[1;35m[EQ: %s]\27[0m", MpvController.eq_preset:upper()) or ""
        local sec_badge = insecure and " | \27[1;33m[CORP SSL]\27[0m" or ""
        local header = string.format(" \27[1;36mYouTube Terminal Viewer\27[0m | %s | %s | %s | %s%s%s | \27[90m%s\27[0m%s",
            mode_badge, auto_badge, cc_badge, q_badge, spd_badge, eq_badge, auth_label, sec_badge)
        table.insert(buf, "\27[1;34m" .. string.rep("=", term_w) .. "\27[0m\n")
        table.insert(buf, header .. "\27[K\n")

        -- 2. Query / Search Subheader with active filters
        local q_display
        if is_favorites_view then
            q_display = "\27[1;93m[Favorites] Starred Tracks (" .. #items .. ")\27[0m"
        elseif is_history then
            q_display = "\27[1;95m[History] Playback History\27[0m"
        elseif is_liked then
            q_display = "\27[1;95m[Liked] Liked Songs Playlist\27[0m"
        else
            q_display = '"' .. current_query .. '"'
        end
        local filter_info = ""
        if active_filters.sort ~= "relevance" or active_filters.duration ~= "all" then
            filter_info = string.format(" \27[35m[Sort: %s | Dur: %s]\27[0m", active_filters.sort, active_filters.duration)
        end
        table.insert(buf, string.format("  \27[90mSearch:\27[0m %s%s  \27[90m(%s)\27[0m\27[K\n", q_display, filter_info, status_msg))
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
                    
                    local is_fav = is_favorite(it)
                    local fav_star = is_fav and "\27[1;93m★ \27[0m" or ""
                    local max_title_w = math.max(15, term_w - (is_fav and 40 or 38))
                    local t = utf8_truncate(it.title, max_title_w)
                    local title_pad = string.rep(" ", math.max(0, max_title_w - display_width(t)))

                    local max_up_w = 18
                    local up = utf8_truncate(it.uploader, max_up_w)
                    local up_pad = string.rep(" ", math.max(0, max_up_w - display_width(up)))

                    local row_str
                    if is_sel then
                        row_str = string.format("%s\27[1;37;44m%02d. %s%s%s \27[1;96;44m%s%s \27[1;93;44m%s\27[0m\27[K\n",
                            cursor, idx, fav_star, t, title_pad, up, up_pad, it.duration_str)
                    else
                        row_str = string.format("%s\27[90m%02d.\27[0m %s\27[37m%s%s\27[0m \27[90m%s%s\27[0m \27[33m%s\27[0m\27[K\n",
                            cursor, idx, fav_star, t, title_pad, up, up_pad, it.duration_str)
                    end
                    table.insert(buf, row_str)
                else
                    table.insert(buf, "\27[K\n")
                end
            end
        end

        -- 4. Mini-Player Box (when playing)
        if MpvController.is_playing and MpvController.current_item then
            local p_lines = render_mini_player_lines(
                MpvController.current_item,
                MpvController.is_paused,
                MpvController.volume,
                MpvController.time_pos,
                MpvController.duration,
                MpvController.sub_text,
                show_cc,
                term_w,
                selected_idx,
                #items,
                MpvController.has_sub_track,
                MpvController.last_sub_text,
                MpvController.speed,
                MpvController.eq_preset
            )
            for _, l in ipairs(p_lines) do
                table.insert(buf, l)
            end
        end

        -- 5. Footer Help
        local auto_footer = auto_play and "\27[1;92mON\27[0m" or "\27[90mOFF\27[0m"
        local cc_footer = show_cc and "\27[1;92mON\27[0m" or "\27[90mOFF\27[0m"
        local q_footer = string.format("\27[93m[Tab]\27[0m Q(%d)  \27[93m[Q]\27[0m View", #queue)
        if not (MpvController.is_playing and MpvController.current_item) then
            table.insert(buf, "\27[1;34m" .. string.rep("-", term_w) .. "\27[0m\n")
        end
        table.insert(buf, string.format(" \27[93m[Enter]\27[0m Play  %s  \27[93m[r]\27[0m Radio  \27[93m[e]\27[0m EQ  \27[93m[*]\27[0m Fav  \27[93m[F]\27[0m Favs  \27[93m[[]/[]]\27[0m Spd  \27[93m[f]\27[0m Filter  \27[93m[/]\27[0m Find  \27[93m[?]\27[0m Help  \27[91m[q]\27[0m Quit\27[K\27[J", q_footer))
        
        io.write(table.concat(buf))
        io.flush()

        last_rendered_pos = MpvController.time_pos
        last_rendered_sub = MpvController.sub_text
        last_rendered_pause = MpvController.is_paused
        last_rendered_has_sub = MpvController.has_sub_track
        last_rendered_last_sub = MpvController.last_sub_text
    end

    draw_tui()

    while true do
        local cur_w, cur_h = get_terminal_size()
        if cur_w ~= last_term_w or cur_h ~= last_term_h then
            last_term_w = cur_w
            last_term_h = cur_h
            draw_tui(true)
        end

        local k = read_key(50)

        -- Check background MPV status every 50ms
        local st = MpvController:poll()
        if st then
            if st.is_eof then
                -- Track finished playing: purge any saved resume position so replay starts from beginning
                local finished_item = MpvController.current_item
                if finished_item and finished_item.url then
                    delete_resume_position(finished_item.url)
                end
                -- Track finished playing: advance queue, replenish radio, or auto-play
                if #queue > 0 then
                    local next_item = table.remove(queue, 1)
                    save_history_item(next_item)
                    MpvController:start(next_item, show_cc, sub_lang, browser, cookies_file, proxy, insecure, cc_font_size)
                    status_msg = make_playing_status(next_item)
                    draw_tui()
                elseif radio_mode and finished_item then
                    status_msg = "\27[1;92m* Radio: Discovering next tracks...\27[0m"
                    draw_tui()
                    local recs = fetch_radio_recommendations(finished_item, browser, cookies_file, proxy, insecure)
                    if recs and #recs > 0 then
                        local next_item = table.remove(recs, 1)
                        for _, r in ipairs(recs) do table.insert(queue, r) end
                        save_history_item(next_item)
                        MpvController:start(next_item, show_cc, sub_lang, browser, cookies_file, proxy, insecure, cc_font_size)
                        status_msg = string.format("Radio playing: %s (+%d queued)", utf8_truncate(next_item.title, 25), #queue)
                        draw_tui()
                    else
                        MpvController:stop()
                        status_msg = "Radio: End of playlist"
                        draw_tui()
                    end
                elseif auto_play and selected_idx < #items then
                    selected_idx = selected_idx + 1
                    local next_item = items[selected_idx]
                    save_history_item(next_item)
                    MpvController:start(next_item, show_cc, sub_lang, browser, cookies_file, proxy, insecure, cc_font_size)
                    status_msg = make_playing_status(next_item)
                    draw_tui()
                else
                    MpvController:stop()
                    draw_tui()
                end
            elseif (st.time_pos ~= last_rendered_pos or st.sub_text ~= last_rendered_sub or st.is_paused ~= last_rendered_pause or MpvController.has_sub_track ~= last_rendered_has_sub or MpvController.last_sub_text ~= last_rendered_last_sub) then
                draw_tui()
            end
        end

        if k then
            if k == "q" then
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
            elseif k == "CTRL_U" then
                selected_idx = math.max(1, selected_idx - max_list_h)
                draw_tui()
            elseif k == "CTRL_D" then
                selected_idx = math.min(#items, selected_idx + max_list_h)
                draw_tui()
            elseif k == "g" then
                selected_idx = 1
                scroll_offset = 0
                draw_tui()
            elseif k == "G" then
                selected_idx = math.max(1, #items)
                draw_tui()
            elseif k == "TAB" then
                if #items > 0 and selected_idx >= 1 and selected_idx <= #items then
                    local sel = items[selected_idx]
                    table.insert(queue, sel)
                    status_msg = string.format("Added to queue: %s (#%d)", utf8_truncate(sel.title, 25), #queue)
                    draw_tui()
                end
            elseif k == "Q" then
                local chosen_idx = show_queue_modal(queue)
                if chosen_idx then
                    local chosen_item = table.remove(queue, chosen_idx)
                    save_history_item(chosen_item)
                    if mode == "music" then
                        MpvController:start(chosen_item, show_cc, sub_lang, browser, cookies_file, proxy, insecure, cc_font_size)
                        status_msg = make_playing_status(chosen_item)
                    else
                        MpvController:stop()
                        play_item(chosen_item, mode, browser, cookies_file, use_window, proxy, insecure, show_cc, sub_lang, cc_font_size)
                    end
                end
            elseif k == "o" or k == "O" or k == "b" or k == "B" then
                local sel = (#items > 0 and selected_idx >= 1 and selected_idx <= #items and items[selected_idx])
                    or (MpvController.is_playing and MpvController.current_item)
                if sel then
                    local url = sel.url or (sel.id and ("https://www.youtube.com/watch?v=" .. sel.id))
                    if url and open_in_browser(url) then
                        status_msg = "\27[1;92m✓ Opened in browser: \27[0m" .. utf8_truncate(sel.title, 32)
                    else
                        status_msg = "\27[1;31m✗ Failed to open browser\27[0m"
                    end
                    draw_tui()
                end
            elseif k == "y" or k == "Y" then
                local sel = (#items > 0 and selected_idx >= 1 and selected_idx <= #items and items[selected_idx])
                    or (MpvController.is_playing and MpvController.current_item)
                if sel then
                    local url = sel.url or (sel.id and ("https://www.youtube.com/watch?v=" .. sel.id))
                    if url and copy_to_clipboard(url) then
                        status_msg = "\27[1;92m✓ Copied URL: \27[0m" .. utf8_truncate(sel.title, 32)
                    else
                        status_msg = "\27[1;31m✗ Failed to copy URL\27[0m"
                    end
                    draw_tui()
                end
            elseif k == "d" or k == "D" then
                if #items > 0 and selected_idx >= 1 and selected_idx <= #items then
                    local sel = items[selected_idx]
                    download_item(sel, mode, browser, cookies_file, proxy, insecure)
                    draw_tui()
                end
            elseif k == "f" then
                local changed = show_filter_modal(active_filters)
                if changed then
                    refresh_results()
                end
                draw_tui()
            elseif k == "F" then
                is_favorites_view = not is_favorites_view
                if is_favorites_view then
                    is_history = false
                    is_liked = false
                    items = load_favorites()
                    selected_idx = 1
                    scroll_offset = 0
                    status_msg = string.format("Loaded %d starred favorites", #items)
                else
                    refresh_results()
                end
                draw_tui()
            elseif k == "*" then
                local sel = (#items > 0 and selected_idx >= 1 and selected_idx <= #items and items[selected_idx])
                    or (MpvController.is_playing and MpvController.current_item)
                if sel then
                    local added = toggle_favorite_item(sel)
                    if is_favorites_view and not added then
                        items = load_favorites()
                        selected_idx = math.max(1, math.min(#items, selected_idx))
                    end
                    status_msg = added and ("\27[1;93m★ Starred: \27[0m" .. utf8_truncate(sel.title, 25))
                        or ("\27[90m☆ Unstarred: \27[0m" .. utf8_truncate(sel.title, 25))
                    draw_tui()
                end
            elseif k == "[" then
                local cur_spd = MpvController.speed or 1.0
                local new_spd = math.max(0.5, cur_spd - 0.25)
                MpvController:set_speed(new_spd)
                status_msg = string.format("Playback Speed: %.2fx", new_spd)
                draw_tui()
            elseif k == "]" then
                local cur_spd = MpvController.speed or 1.0
                local new_spd = math.min(2.5, cur_spd + 0.25)
                MpvController:set_speed(new_spd)
                status_msg = string.format("Playback Speed: %.2fx", new_spd)
                draw_tui()
            elseif k == "{" or k == "}" then
                MpvController:set_speed(1.0)
                status_msg = "Playback Speed: 1.00x (Reset)"
                draw_tui()
            elseif k == "e" or k == "E" then
                local chosen_eq = show_eq_modal(MpvController.eq_preset or "flat")
                if chosen_eq then
                    MpvController:set_eq(chosen_eq)
                    status_msg = string.format("EQ Applied: %s", get_eq_name(chosen_eq))
                end
                draw_tui()
            elseif k == "r" or k == "R" then
                radio_mode = not radio_mode
                if radio_mode then
                    auto_play = true
                    status_msg = "\27[1;92m✓ Radio Mode: ON (Infinite YouTube Mix)\27[0m"
                    if MpvController.is_playing and MpvController.current_item and #queue == 0 then
                        draw_tui()
                        local recs = fetch_radio_recommendations(MpvController.current_item, browser, cookies_file, proxy, insecure)
                        if recs and #recs > 0 then
                            for _, r in ipairs(recs) do table.insert(queue, r) end
                            status_msg = string.format("Radio: Queued %d similar tracks", #recs)
                        end
                    end
                else
                    status_msg = "\27[90mRadio Mode: OFF\27[0m"
                end
                draw_tui()
            elseif k == " " then
                if MpvController.is_playing then
                    MpvController:toggle_pause()
                    draw_tui()
                end
            elseif k == "s" or k == "S" then
                if MpvController.is_playing or #queue > 0 then
                    if #queue > 0 then
                        local next_item = table.remove(queue, 1)
                        save_history_item(next_item)
                        MpvController:start(next_item, show_cc, sub_lang, browser, cookies_file, proxy, insecure, cc_font_size)
                        status_msg = make_playing_status(next_item)
                    elseif auto_play and selected_idx < #items then
                        selected_idx = selected_idx + 1
                        local next_item = items[selected_idx]
                        save_history_item(next_item)
                        MpvController:start(next_item, show_cc, sub_lang, browser, cookies_file, proxy, insecure, cc_font_size)
                        status_msg = make_playing_status(next_item)
                    else
                        MpvController:stop()
                        status_msg = "Playback stopped"
                    end
                    draw_tui()
                end
            elseif k == "x" or k == "X" then
                if MpvController.is_playing then
                    MpvController:stop()
                    status_msg = "Playback stopped"
                    draw_tui()
                end
            elseif k == "LEFT" then
                if MpvController.is_playing then
                    MpvController:seek(-5)
                end
            elseif k == "RIGHT" then
                if MpvController.is_playing then
                    MpvController:seek(5)
                end
            elseif k == "9" then
                if MpvController.is_playing then
                    MpvController:change_volume(-10)
                end
            elseif k == "0" then
                if MpvController.is_playing then
                    MpvController:change_volume(10)
                end
            elseif k == "P" then
                if #items > 0 and selected_idx >= 1 and selected_idx <= #items then
                    MpvController:stop()
                    local sel = items[selected_idx]
                    save_history_item(sel)
                    play_item(sel, mode, browser, cookies_file, use_window, proxy, insecure, show_cc, sub_lang, cc_font_size, sub_color)
                    draw_tui()
                end
            elseif k == "m" then
                mode = (mode == "music") and "video" or "music"
                refresh_results()
                draw_tui()
            elseif k == "M" then
                if is_history or is_liked or #current_query == 0 then
                    status_msg = "Load more is available for search results only."
                else
                    refresh_results(true)
                end
                draw_tui()
            elseif k == "L" or k == "l" then
                is_liked = not is_liked
                is_history = false
                refresh_results()
                draw_tui()
            elseif k == "a" or k == "A" then
                auto_play = not auto_play
                draw_tui()
            elseif k == "c" then
                show_cc = not show_cc
                draw_tui()
            elseif k == "C" then
                if MpvController.is_playing then
                    MpvController:cycle_sub()
                    status_msg = "Cycled subtitle track"
                    draw_tui()
                end
            elseif k == "+" or k == "=" then
                cc_font_size = math.min(120, cc_font_size + 5)
                MpvController:set_sub_font_size(cc_font_size)
                status_msg = string.format("CC font size: %d pt", cc_font_size)
                draw_tui()
            elseif k == "-" or k == "_" then
                cc_font_size = math.max(10, cc_font_size - 5)
                MpvController:set_sub_font_size(cc_font_size)
                status_msg = string.format("CC font size: %d pt", cc_font_size)
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
                    save_search_history(new_q)
                    is_liked = false
                    is_history = false
                    refresh_results()
                end
                draw_tui()
            elseif k == "ENTER" then
                if #items > 0 and selected_idx >= 1 and selected_idx <= #items then
                    local sel = items[selected_idx]
                    save_history_item(sel)
                    if mode == "music" then
                        MpvController:start(sel, show_cc, sub_lang, browser, cookies_file, proxy, insecure, cc_font_size)
                        status_msg = make_playing_status(sel)
                        draw_tui()
                    else
                        MpvController:stop()
                        local exit_code = play_item(sel, mode, browser, cookies_file, use_window, proxy, insecure, show_cc, sub_lang, cc_font_size, sub_color)
                        draw_tui()
                        if auto_play and (exit_code == 0 or exit_code == true) and selected_idx < #items then
                            selected_idx = selected_idx + 1
                        end
                    end
                end
            end
        end
    end

    MpvController:stop()
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
    assert(status_music:find("${?user-data/yt-cc:", 1, true), "Music CC status format missing conditional CC property")
    assert(status_music:find("CC/Lyrics:", 1, true), "Music CC status format missing label")
    local status_video = build_mpv_status_msg("video", true)
    assert(status_video:find("\27[1B", 1, true), "Video CC status must move below the video frame")
    assert(status_video:find("\27[2A", 1, true), "Video CC status must return to the CC row after clearing three rows")
    assert(status_video:find("\27[2K", 1, true), "Video status must clear each dedicated output row")
    assert(status_video:find("\27[1A", 1, true) == nil, "Video status must not use embedded newlines")
    assert(status_video:find("\27%[u") or status_video:find("\27[u", 1, true), "Video CC status must restore the original cursor")
    assert(status_video:find("${?user-data/yt-cc:", 1, true), "Video CC status format missing conditional CC property")
    assert(status_video:find("CC:", 1, true), "Video CC status format missing label")
    assert(status_video:find("${playback-time}", 1, true), "Video status format missing playback time")
    assert(status_video:find("${duration}", 1, true), "Video status format missing duration")
    local progress_pos = status_video:find("[${playback-time}", 1, true)
    local cc_pos = status_video:find("${?user-data/yt-cc:", 1, true)
    assert(progress_pos and cc_pos and progress_pos < cc_pos, "Video status should place progress before CC")
    local status_no_cc = build_mpv_status_msg("music", false)
    assert(not status_no_cc:find("sub-text", 1, true), "Non-CC status should not contain sub-text")
    print("  [✓] CC / Lyrics status formatting passed")

    -- 8b. CC rolling caption deduplication
    local s1 = {}
    local u1 = clean_rolling_caption("France is now spending a\nthird of its national budget", s1)
    assert(u1 == "France is now spending a third of its national budget", "User case cue 1 mismatch: " .. tostring(u1))
    local u2 = clean_rolling_caption("third of its national budget\non defense", s1)
    assert(u2 == "on defense", "User case cue 2 mismatch: " .. tostring(u2))

    local s2 = {}
    local t1 = clean_rolling_caption("love. You know the rules and so do", s2)
    local t2 = clean_rolling_caption("love. You know the rules and so do\nI. I feel commitments from what I'm", s2)
    assert(t2 == "I. I feel commitments from what I'm", "Transition cue line 2 mismatch: " .. tostring(t2))
    local t3 = clean_rolling_caption("I. I feel commitments from what I'm", s2)
    assert(t3 == "I. I feel commitments from what I'm", "Transition cue duplicate mismatch: " .. tostring(t3))

    local s3 = {}
    local m1 = clean_rolling_caption("To be, or not to be,\nthat is the question:", s3)
    assert(m1 == "To be, or not to be, that is the question:", "Movie subtitle 1 mismatch: " .. tostring(m1))
    local m2 = clean_rolling_caption("Whether 'tis nobler in the mind to suffer\nThe slings and arrows of outrageous fortune,", s3)
    assert(m2 == "Whether 'tis nobler in the mind to suffer The slings and arrows of outrageous fortune,", "Movie subtitle 2 mismatch: " .. tostring(m2))

    local s4 = {}
    local w1 = clean_rolling_caption("France is now spending a third of its national budget", s4)
    local w2 = clean_rolling_caption("third of its national budget on defense", s4)
    assert(w2 == "on defense", "Sliding window overlap mismatch: " .. tostring(w2))
    print("  [✓] CC rolling caption deduplication passed")

    -- 9. Download Directory Naming Convention
    local ok_dir, err_dir = pcall(ensure_downloads_dir)
    assert(ok_dir, "ensure_downloads_dir threw error: " .. tostring(err_dir))
    print("  [✓] Download directory validation passed (compliant: ./downloads/)")

    -- 10. Playback Queue Operations
    local test_q = {}
    table.insert(test_q, { id = "q1", title = "Track 1" })
    table.insert(test_q, { id = "q2", title = "Track 2" })
    assert(#test_q == 2, "Queue insert failed")
    local popped = table.remove(test_q, 1)
    assert(popped.id == "q1", "Queue FIFO pop failed")
    assert(#test_q == 1, "Queue length after pop mismatch")
    print("  [✓] Up-Next Playback Queue FIFO logic passed")

    -- 11. Search Filters & Sorting SP Codes
    local sp_map = { views = "CAM%253D", date = "CAI%253D", rating = "CAE%253D" }
    assert(sp_map.views == "CAM%253D", "Filter sort views SP code mismatch")
    assert(sp_map.date == "CAI%253D", "Filter sort date SP code mismatch")
    assert(sp_map.rating == "CAE%253D", "Filter sort rating SP code mismatch")
    local test_dur_items = {
        { id = "1", duration = 120 },
        { id = "2", duration = 600 },
        { id = "3", duration = 1800 },
    }
    local short_items = {}
    for _, it in ipairs(test_dur_items) do
        if it.duration < 240 then table.insert(short_items, it) end
    end
    assert(#short_items == 1 and short_items[1].id == "1", "Duration filter short logic failed")
    print("  [✓] Search Filters & Sorting validation passed")

    -- 12. Site search adapters
    assert(normalize_site(nil) == "youtube", "Default site normalization failed")
    assert(normalize_site("youtube.com") == "youtube", "YouTube site normalization failed")
    assert(normalize_site("https://soundcloud.com") == "soundcloud", "SoundCloud site normalization failed")
    assert(SITE_SEARCH_PREFIXES.youtube == "ytsearch", "YouTube search adapter missing")
    assert(SITE_SEARCH_PREFIXES.soundcloud == "scsearch", "SoundCloud search adapter missing")
    assert(SITE_SEARCH_PREFIXES.twitch == "twsearch", "Twitch search adapter missing")
    print("  [✓] Site search adapters passed")

    -- 13. Platform IPC FFI bindings (Win32 Named Pipe / POSIX UNIX Domain Socket)
    if is_windows then
        assert(kernel32 ~= nil, "kernel32 library handle must be initialized")
        assert(kernel32.CreateFileA ~= nil, "kernel32.CreateFileA must be defined")
        assert(kernel32.WriteFile ~= nil, "kernel32.WriteFile must be defined")
        assert(kernel32.ReadFile ~= nil, "kernel32.ReadFile must be defined")
        assert(kernel32.PeekNamedPipe ~= nil, "kernel32.PeekNamedPipe must be defined")
        assert(kernel32.CloseHandle ~= nil, "kernel32.CloseHandle must be defined")
        print("  [✓] Win32 Named Pipe FFI bindings validated")
    else
        assert(ffi.C.socket ~= nil, "ffi.C.socket must be defined")
        assert(ffi.C.connect ~= nil, "ffi.C.connect must be defined")
        assert(ffi.C.write ~= nil, "ffi.C.write must be defined")
        assert(ffi.C.read ~= nil, "ffi.C.read must be defined")
        assert(ffi.C.close ~= nil, "ffi.C.close must be defined")
        assert(ffi.C.unlink ~= nil, "ffi.C.unlink must be defined")
        local test_addr = make_sockaddr_un("/tmp/test_ipc.sock")
        assert(test_addr.sun_family == 1, "sockaddr_un sun_family must be AF_UNIX (1)")
        assert(ffi.string(test_addr.sun_path) == "/tmp/test_ipc.sock", "sockaddr_un path mismatch")
        print("  [✓] POSIX UNIX domain socket FFI bindings validated")
    end

    -- 14. Subtitle / slang language expansion (prioritizing -orig authentic subtitles)
    assert(to_mpv_slang("en.*") == "en-orig,en,eng,en-US,en-GB", "to_mpv_slang default expansion failed")
    assert(to_mpv_slang("en") == "en-orig,en,eng,en-US,en-GB", "to_mpv_slang en expansion failed")
    assert(to_mpv_slang("zh.*") == "zh-orig,zh,chi,zho,zh-Hans,zh-Hant", "to_mpv_slang zh expansion failed")
    assert(to_mpv_slang("es.*") == "es-orig,es", "to_mpv_slang es strip wildcard failed")
    assert(to_mpv_slang("fr,de") == "fr-orig,fr,de-orig,de", "to_mpv_slang multiple list failed")
    print("  [✓] to_mpv_slang language expansion passed")

    -- 14. CC font size bounding & adjustment
    local function clamp_font_size(size)
        return math.max(10, math.min(120, math.floor(size)))
    end
    assert(clamp_font_size(55) == 55, "Default font size failed")
    assert(clamp_font_size(5) == 10, "Min font size clamping failed")
    assert(clamp_font_size(200) == 120, "Max font size clamping failed")
    assert(clamp_font_size(55 + 5) == 60, "Font size increment failed")
    assert(clamp_font_size(55 - 5) == 50, "Font size decrement failed")
    print("  [✓] CC / subtitle font size bounding logic passed")

    -- 15. Search spec generation & verbatim query preservation (audio/music mode video search)
    assert(build_search_spec("lex fridman podcast", "music", 20, false, nil, "youtube") == '"ytsearch20:lex fridman podcast"',
        "Search spec in music mode must preserve video query verbatim without forced suffix")
    assert(build_search_spec("veritasium", "video", 15, false, nil, "youtube") == '"ytsearch15:veritasium"',
        "Search spec in video mode failed")
    assert(build_search_spec("https://youtu.be/dQw4w9WgXcQ", "music", 20, false, nil, "youtube") == '"https://youtu.be/dQw4w9WgXcQ"',
        "Direct URL search spec failed")
    assert(build_search_spec("", "music", 20, true, nil, "youtube") == '"https://music.youtube.com/playlist?list=LM"',
        "Liked music playlist spec failed")
    assert(build_search_spec("", "video", 20, true, nil, "youtube") == '":ytfavorites"',
        "Liked video favorites spec failed")
    assert(build_search_spec("chillhop", "music", 10, false, nil, "soundcloud") == '"scsearch10:chillhop"',
        "Soundcloud site adapter failed")
    assert(build_search_spec("piano relax", "music", 20, false, { sort = "views" }, "youtube") == '"https://www.youtube.com/results?search_query=piano+relax&sp=CAM%253D"',
        "Search spec sort by views failed")
    assert(build_search_spec("piano relax", "music", 20, false, { sort = "date" }, "youtube") == '"https://www.youtube.com/results?search_query=piano+relax&sp=CAI%253D"',
        "Search spec sort by date failed")
    assert(build_search_spec("piano relax", "music", 20, false, { sort = "rating" }, "youtube") == '"https://www.youtube.com/results?search_query=piano+relax&sp=CAE%253D"',
        "Search spec sort by rating failed")
    print("  [✓] Search spec generation & audio-mode video search query preservation passed")

    -- 16. Mini-player dedicated CC layout & renderer invariant tests
    local sample_item = { title = "Lex Fridman Podcast #418 - Sam Altman", duration = 6734 }
    local lines_cc_on = render_mini_player_lines(sample_item, false, 90, 252, 6734, "The pace of progress is extraordinary.", true, 100, 1, 20, true, "The pace of progress is extraordinary.")
    assert(#lines_cc_on == 4, "Mini-player with CC ON must render exactly 4 lines")
    assert(lines_cc_on[3]:find("%[CC%]") ~= nil, "Line 3 must contain [CC] badge")
    assert(lines_cc_on[3]:find("The pace of progress is extraordinary%.") ~= nil, "Line 3 must contain active subtitle text")

    -- Lingering subtitles during speech pause
    local lines_cc_linger = render_mini_player_lines(sample_item, false, 90, 255, 6734, "", true, 100, 1, 20, true, "The pace of progress is extraordinary.")
    assert(#lines_cc_linger == 4, "Mini-player with lingering subtitle must render 4 lines")
    assert(lines_cc_linger[3]:find("The pace of progress is extraordinary%.") ~= nil, "Lingering subtitle must remain visible during speech pause")

    -- No subtitle track on video
    local lines_no_subs = render_mini_player_lines(sample_item, false, 90, 252, 6734, "", true, 100, 1, 20, false, "")
    assert(#lines_no_subs == 4, "Mini-player with no subtitle track must render 4 lines")
    assert(lines_no_subs[3]:find("No subtitles available") ~= nil, "Missing subtitle track must be indicated clearly")

    local lines_cc_idle = render_mini_player_lines(sample_item, false, 90, 252, 6734, "", true, 100, 1, 20, nil, "")
    assert(#lines_cc_idle == 4, "Mini-player with CC idle must render 4 lines stably")
    assert(lines_cc_idle[3]:find("%(Listening for speech / instrumental%.%.%.%)") ~= nil, "Idle CC row must show listening placeholder")

    local lines_cc_off = render_mini_player_lines(sample_item, true, 80, 50, 6734, "Ignored subtitle", false, 100, 1, 20, true, "Ignored")
    assert(#lines_cc_off == 3, "Mini-player with CC OFF must render exactly 3 lines")
    assert(lines_cc_off[1]:find("%[PAUSED%]") ~= nil, "Mini-player paused badge failed")

    -- Boundary checks: narrow terminal and zero duration
    local lines_narrow = render_mini_player_lines({ title = "A", duration = 0 }, false, 100, 0, 0, "Test", true, 35, 1, 1, true, "Test")
    -- Exact width alignment invariants across various terminal sizes
    for _, test_w in ipairs({ 80, 120, 148 }) do
        local test_lines = render_mini_player_lines(sample_item, false, 90, 252, 6734, "The pace of progress is extraordinary.", true, test_w, 1, 20, true, "The pace of progress is extraordinary.")
        assert(#test_lines == 4, "Mini-player must render 4 lines for width " .. test_w)
        for row_idx, l in ipairs(test_lines) do
            local clean_l = strip_ansi(l):gsub("\n$", "")
            assert(display_width(clean_l) == test_w, string.format("Row %d width (%d) must exactly match term_w (%d)", row_idx, display_width(clean_l), test_w))
        end
    end
    print("  [✓] Mini-player dedicated CC layout & renderer invariants passed")

    -- 17. IPC Property Parsing & Subtitle Collision Prevention
    local ipc_sub_text = '{"event":"property-change","id":4,"name":"sub-text","data":"So today we\'re going to discuss LuaJIT"}'
    local ipc_sub_track = '{"event":"property-change","id":7,"name":"sub","data":1}'
    local ipc_sub_none = '{"event":"property-change","id":7,"name":"sub","data":false}'
    assert(parse_json_field(ipc_sub_text, "name") == "sub-text", "IPC sub-text name extraction failed")
    assert(parse_json_field(ipc_sub_track, "name") == "sub", "IPC sub track name extraction failed")
    assert(parse_json_field(ipc_sub_text, "data") == "So today we're going to discuss LuaJIT", "IPC sub-text data extraction failed")
    assert(parse_json_field(ipc_sub_track, "data") == 1, "IPC sub data extraction failed")
    assert(parse_json_field(ipc_sub_none, "data") == false, "IPC sub false data extraction failed")

    -- Multiline JSON string newline preservation
    local multiline_json = '{"name":"sub-text","data":"Line 1\\nLine 2"}'
    assert(parse_json_field(multiline_json, "data") == "Line 1\nLine 2", "parse_json_field must preserve \\n newline escapes")

    -- Sanitization entity & ASS tag stripping
    local dirty_cc = "{\\an8}<i>Don&#39;t</i> miss &quot;LuaJIT&quot; &amp; friends!"
    local clean_cc = sanitize_display_text(dirty_cc)
    assert(clean_cc == "Don't miss \"LuaJIT\" & friends!", "Caption HTML/ASS sanitization failed: " .. tostring(clean_cc))

    -- Simulated MpvController IPC buffer stream decoding with rolling caption deduplication
    MpvController.is_playing = true
    MpvController.cc_state = { prev_last_line = "", prev_displayed = "" }
    MpvController.read_buf = ipc_sub_track .. "\n" .. '{"name":"sub-text","data":"France is now spending a\\nthird of its national budget"}\n'
    MpvController:poll()
    assert(MpvController.has_sub_track == true, "MpvController has_sub_track should be true")
    assert(MpvController.sub_text == "France is now spending a third of its national budget", "Initial cue mismatch: " .. tostring(MpvController.sub_text))

    -- Subsequent cue repeats line 1; deduplication must strip repeated overlap
    MpvController.read_buf = '{"name":"sub-text","data":"third of its national budget\\non defense"}\n'
    MpvController:poll()
    assert(MpvController.sub_text == "on defense", "Overlapping words must be stripped from rolling cue: " .. tostring(MpvController.sub_text))

    MpvController.is_playing = false
    MpvController.read_buf = ""

    -- Subtitle track cycling method state reset
    MpvController.sub_text = "test cue"
    MpvController.last_sub_text = "last cue"
    MpvController.cc_state = { prev_last_line = "prev", prev_displayed = "prev" }
    MpvController:cycle_sub()
    assert(MpvController.sub_text == "", "cycle_sub must reset sub_text")
    assert(MpvController.last_sub_text == "", "cycle_sub must reset last_sub_text")
    assert(MpvController.cc_state.prev_last_line == "", "cycle_sub must reset cc_state")
    assert(MpvController.has_switched_orig == true, "cycle_sub must set has_switched_orig = true")

    -- Automatic switching to original subtitle track on track-list event
    local sent_cmds = {}
    local orig_send = MpvController.send_command
    MpvController.send_command = function(self, cmd)
        table.insert(sent_cmds, cmd)
    end
    MpvController.is_playing = true
    MpvController.has_switched_orig = false
    local test_track_list = '{"event":"property-change","name":"track-list","data":[{"id":1,"type":"sub","lang":"en","selected":true},{"id":2,"type":"sub","lang":"en-orig","selected":false}]}'
    MpvController.read_buf = test_track_list .. "\n"
    MpvController:poll()
    assert(MpvController.has_switched_orig == true, "MpvController must set has_switched_orig = true when en-orig track found")
    assert(#sent_cmds == 1, "Must send exactly 1 command to switch track")
    assert(sent_cmds[1]:find('"set_property", "sid", 2') ~= nil, "Command must set sid to track 2: " .. tostring(sent_cmds[1]))

    -- If already selected, should not redundantly send set_property
    sent_cmds = {}
    MpvController.has_switched_orig = false
    local test_track_list_sel = '{"event":"property-change","name":"track-list","data":[{"id":2,"type":"sub","lang":"en-orig","selected":true}]}'
    MpvController.read_buf = test_track_list_sel .. "\n"
    MpvController:poll()
    assert(MpvController.has_switched_orig == true, "MpvController must mark has_switched_orig")
    assert(#sent_cmds == 0, "Must not send set_property if orig track is already selected")

    MpvController.send_command = orig_send
    MpvController.is_playing = false
    MpvController.read_buf = ""
    print("  [✓] IPC property parsing, rolling caption deduplication & track-list auto-selection passed")

    -- 17b. Live MPV POSIX IPC stream verification (if mpv installed)
    if HAS_MPV and not is_windows then
        local live_item = { url = "av://lavfi:sine=frequency=440:duration=3", title = "IPC Test", duration = 3 }
        MpvController:start(live_item, true, "en.*")
        assert(MpvController.is_playing == true, "MpvController:start must mark is_playing = true")
        local got_pos = false
        for _ = 1, 30 do
            sleep_ms(30)
            local st = MpvController:poll()
            if st and st.time_pos and st.time_pos > 0 then
                got_pos = true
                break
            end
        end
        MpvController:toggle_pause()
        assert(MpvController.is_paused == true, "toggle_pause must toggle is_paused")
        MpvController:stop()
        assert(MpvController.is_playing == false, "MpvController:stop must mark is_playing = false")
        assert(MpvController.sock_fd == nil, "MpvController:stop must reset sock_fd")
        print("  [✓] Live MPV POSIX UNIX domain socket IPC lifecycle validated")
    end

    -- 18. Clipboard URL Copying (y key)
    assert(copy_to_clipboard(nil) == false, "copy_to_clipboard(nil) must return false")
    assert(copy_to_clipboard("") == false, "copy_to_clipboard('') must return false")
    local test_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    local copy_ok = copy_to_clipboard(test_url)
    assert(copy_ok == true, "copy_to_clipboard must succeed for valid URL string")
    print("  [✓] Cross-platform clipboard copy (y key) validated")

    -- 19. Default Web Browser Opening (o key)
    assert(open_in_browser(nil) == false, "open_in_browser(nil) must return false")
    assert(open_in_browser("") == false, "open_in_browser('') must return false")
    print("  [✓] Default web browser open helper (o key) validated")

    -- 20. Standalone MPV GUI window (-w) YouTube-identical subtitle styling & high-contrast options
    local script_file = get_mpv_cc_script()
    assert(script_file ~= nil and #script_file > 0, "get_mpv_cc_script must return valid path")
    local sf = io.open(script_file, "r")
    assert(sf ~= nil, "Unable to open generated MPV CC script file")
    local script_content = sf:read("*a")
    sf:close()
    assert(script_content:find("Alt%+c") ~= nil, "MPV CC script must bind Alt+c for cycling styles")
    assert(script_content:find("cycle_cc_style") ~= nil, "MPV CC script must define cycle_cc_style")

    local function build_test_yt_style(color)
        local text_color = (color == "yellow") and "#FFFF00FF" or ((color == "cyan") and "#00FFFFFF" or "#FFFFFFFF")
        return string.format(' --sub-border-style=background-box --sub-back-color="#000000E6" --sub-color=%q --sub-outline-size=2 --sub-outline-color="#FF000000" --sub-shadow-offset=1.5 --sub-shadow-color="#FF000000" --sub-font="Roboto,Arial,sans-serif" --sub-bold=yes --sub-ass-override=force --sub-margin-y=36', text_color)
    end
    local yt_style_white = build_test_yt_style("white")
    assert(yt_style_white:find("sub%-border%-style=background%-box") ~= nil, "YouTube background-box style missing")
    assert(yt_style_white:find('sub%-back%-color="#000000E6"') ~= nil, "High contrast 90% opaque background box missing")
    assert(yt_style_white:find('sub%-color="#FFFFFFFF"') ~= nil, "YouTube white text color missing")
    assert(yt_style_white:find("sub%-outline%-size=2") ~= nil, "High contrast 2px outline missing")
    assert(yt_style_white:find("sub%-shadow%-offset=1.5") ~= nil, "Subtle drop-shadow missing")
    assert(yt_style_white:find("sub%-bold=yes") ~= nil, "YouTube bold subtitle styling missing")

    local yt_style_yellow = build_test_yt_style("yellow")
    assert(yt_style_yellow:find('sub%-color="#FFFF00FF"') ~= nil, "Yellow CC color missing")

    local yt_style_cyan = build_test_yt_style("cyan")
    assert(yt_style_cyan:find('sub%-color="#00FFFFFF"') ~= nil, "Cyan CC color missing")
    print("  [✓] Standalone window (-w) YouTube-identical & high-contrast subtitle styling validated")

    -- 21. scrape_youtube_search query parameter handling & fallback validation
    local ok_nil_scrape = pcall(function() return scrape_youtube_search(nil, 1) end)
    assert(ok_nil_scrape, "scrape_youtube_search must safely handle nil query without error")
    local ok_empty_scrape = pcall(function() return scrape_youtube_search("", 1) end)
    assert(ok_empty_scrape, "scrape_youtube_search must safely handle empty query")
    print("  [✓] scrape_youtube_search query parameter & fallback robustness passed")

    -- 22. Multi-byte pasted input FIFO queueing (Issue 3.5)
    local sample_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    for k in pairs(pending_keys) do pending_keys[k] = nil end
    local sim_buf = ffi.new("char[?]", #sample_url + 1, sample_url)
    enqueue_pending_bytes(sim_buf, 0, #sample_url)
    local recovered = {}
    while true do
        local k = read_key(0)
        if not k then break end
        table.insert(recovered, k)
    end
    assert(table.concat(recovered) == sample_url, "Pending keys queue failed to recover complete pasted string: got " .. table.concat(recovered))

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    local chunk1 = "abc\n"
    local sim_c1 = ffi.new("char[?]", #chunk1 + 1, chunk1)
    enqueue_pending_bytes(sim_c1, 0, #chunk1)
    assert(read_key(0) == "a", "First key mismatch")
    assert(read_key(0) == "b", "Second key mismatch")
    assert(read_key(0) == "c", "Third key mismatch")
    assert(read_key(0) == "ENTER", "Enter translation mismatch")
    assert(read_key(0) == nil, "Queue should be empty after draining")
    print("  [✓] Multi-byte pasted input FIFO queueing & token normalization validated")

    -- 23. Search query prompt pre-fill & Ctrl+U fast clear (Issue 3.6)
    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "ENTER")
    local preserved = prompt_search_query("lofi beats")
    assert(preserved == "lofi beats", "prompt_search_query must preserve active query on ENTER: got " .. tostring(preserved))

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "CTRL_U")
    table.insert(pending_keys, "s")
    table.insert(pending_keys, "y")
    table.insert(pending_keys, "n")
    table.insert(pending_keys, "t")
    table.insert(pending_keys, "h")
    table.insert(pending_keys, "ENTER")
    local replaced = prompt_search_query("lofi beats")
    assert(replaced == "synth", "prompt_search_query must clear via CTRL_U and accept new input: got " .. tostring(replaced))

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "ESC")
    local cancelled = prompt_search_query("lofi beats")
    assert(cancelled == nil, "prompt_search_query must return nil on ESC")
    print("  [✓] Search query modal pre-fill, Ctrl+U clear & interactive simulation validated")

    -- 24. Search query persistence & Readline-style history cycling
    local sfile = get_search_history_file()
    os.remove(sfile)
    assert(save_search_history("lofi beats") == true, "save_search_history failed")
    assert(save_search_history("synthwave radio") == true, "save_search_history failed")
    assert(save_search_history("lofi beats") == true, "save_search_history re-save failed")
    local sh_list = load_search_history()
    assert(#sh_list == 2, "Expected 2 deduplicated history items, got " .. #sh_list)
    assert(sh_list[1] == "lofi beats", "Most recent search must be at index 1")
    assert(sh_list[2] == "synthwave radio", "Previous search must be at index 2")

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "UP")
    table.insert(pending_keys, "ENTER")
    local recalled = prompt_search_query("")
    assert(recalled == "lofi beats", "UP arrow failed to recall most recent search: got " .. tostring(recalled))

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "UP")
    table.insert(pending_keys, "UP")
    table.insert(pending_keys, "ENTER")
    local older = prompt_search_query("")
    assert(older == "synthwave radio", "UP arrow twice failed to recall older search: got " .. tostring(older))

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "d")
    table.insert(pending_keys, "r")
    table.insert(pending_keys, "a")
    table.insert(pending_keys, "f")
    table.insert(pending_keys, "t")
    table.insert(pending_keys, "UP")
    table.insert(pending_keys, "DOWN")
    table.insert(pending_keys, "ENTER")
    local draft_restored = prompt_search_query("")
    assert(draft_restored == "draft", "DOWN arrow failed to restore draft input: got " .. tostring(draft_restored))
    print("  [✓] Persistent search history & Readline-style UP/DOWN cycling validated")

    -- 25. Resume playback position helpers, watch-later config parsing & quit logic
    local resume_test_dir = get_resume_dir()
    assert(resume_test_dir ~= nil and #resume_test_dir > 0, "get_resume_dir must return valid directory path")
    local test_track_url = "https://www.youtube.com/watch?v=TESTRESUME123"
    local dummy_conf = resume_test_dir .. (is_windows and "\\" or "/") .. "TESTRESUME123"

    -- Write a mock watch-later entry
    local fw = io.open(dummy_conf, "w")
    assert(fw ~= nil, "Failed to create mock watch-later config file")
    fw:write("# " .. test_track_url .. "\n")
    fw:write("start=127.450000\n")
    fw:write("volume=80.000000\n")
    fw:close()

    local pos = get_resume_position(test_track_url)
    assert(pos == 127, "get_resume_position must extract floor(127.45) = 127: got " .. tostring(pos))

    -- Positions below threshold (RESUME_MIN_SEC = 5) should be ignored
    fw = io.open(dummy_conf, "w")
    assert(fw ~= nil, "Failed to re-open mock watch-later config file")
    fw:write("# " .. test_track_url .. "\nstart=3.200000\n")
    fw:close()
    assert(get_resume_position(test_track_url) == nil, "get_resume_position must return nil for positions < 5 seconds")

    -- Check --no-resume disable flag behavior
    resume_cfg.enabled = false
    assert(get_resume_position(test_track_url) == nil, "get_resume_position must return nil when resume_cfg.enabled is false")
    assert(get_resume_mpv_opts() == " --no-resume-playback", "get_resume_mpv_opts must return --no-resume-playback when disabled")
    resume_cfg.enabled = true
    resume_cfg.opts = nil -- reset cached opts

    -- Direct delete_resume_position test
    fw = io.open(dummy_conf, "w")
    assert(fw ~= nil, "Failed to create mock watch-later config file")
    fw:write("# " .. test_track_url .. "\nstart=60.000000\n")
    fw:close()
    assert(get_resume_position(test_track_url) == 60, "Expected resume position of 60")
    local deleted = delete_resume_position(test_track_url)
    assert(deleted == true, "delete_resume_position must return true when matching file is removed")
    assert(get_resume_position(test_track_url) == nil, "get_resume_position must return nil after delete_resume_position")
    assert(delete_resume_position(test_track_url) == false, "delete_resume_position must return false when no entry exists")

    -- Test MpvController:quit_command() logic
    MpvController.is_playing = true
    MpvController.is_eof = false
    MpvController.time_pos = 45
    MpvController.duration = 180
    MpvController.current_item = { url = test_track_url, title = "Test Resume Track", duration = 180 }
    assert(MpvController:quit_command() == '{"command": ["quit-watch-later"]}', "MpvController:quit_command must return quit-watch-later mid-track")

    -- Stopped within 10s of track end should delete config rather than saving near-end
    fw = io.open(dummy_conf, "w")
    assert(fw ~= nil, "Failed to create mock watch-later config file")
    fw:write("# " .. test_track_url .. "\nstart=175.000000\n")
    fw:close()
    MpvController.time_pos = 175
    MpvController.duration = 180
    assert(MpvController:quit_command() == '{"command": ["quit"]}', "MpvController:quit_command must return quit near end of track")
    assert(get_resume_position(test_track_url) == nil, "Resume position must be cleared after quit near end of track")

    MpvController.is_playing = false
    MpvController.time_pos = 0
    MpvController.duration = 0
    MpvController.current_item = nil

    print("  [✓] Playback resume position helpers, watch-later config parsing & quit logic validated")

    -- 26. Playback speed multiplier & clamping logic
    MpvController:set_speed(1.5)
    assert(MpvController.speed == 1.5, "MpvController speed must be 1.5: got " .. tostring(MpvController.speed))
    MpvController:set_speed(0.2)
    assert(MpvController.speed == 0.5, "MpvController speed must clamp minimum to 0.5: got " .. tostring(MpvController.speed))
    MpvController:set_speed(3.5)
    assert(MpvController.speed == 2.5, "MpvController speed must clamp maximum to 2.5: got " .. tostring(MpvController.speed))
    MpvController:set_speed(1.0)
    assert(MpvController.speed == 1.0, "MpvController speed reset to 1.0 failed")

    local sample_spd_item = { title = "Speed Test Track", duration = 200 }
    local spd_lines = render_mini_player_lines(sample_spd_item, false, 100, 50, 200, "", false, 90, 1, 1, false, "", 1.5, "flat")
    assert(spd_lines[1]:find("%[1%.50x%]") ~= nil, "Mini-player header must show [1.50x] speed badge")
    local normal_spd_lines = render_mini_player_lines(sample_spd_item, false, 100, 50, 200, "", false, 90, 1, 1, false, "", 1.0, "flat")
    assert(normal_spd_lines[1]:find("%[1%.00x%]") == nil, "Mini-player header should omit speed badge at 1.0x")
    print("  [✓] Playback speed multiplier, clamping & mini-player badges validated")

    -- 27. Audio Equalizer presets & lavfi / af string generation
    assert(is_valid_eq_preset("flat") == true, "Missing flat EQ preset")
    assert(is_valid_eq_preset("night") == true, "Missing night EQ preset")
    assert(is_valid_eq_preset("bass") == true, "Missing bass EQ preset")
    assert(is_valid_eq_preset("vocal") == true, "Missing vocal EQ preset")
    assert(is_valid_eq_preset("lofi") == true, "Missing lofi EQ preset")
    assert(is_valid_eq_preset("nonexistent") == false, "Nonexistent EQ preset must be invalid")

    assert(get_eq_filter("bass"):find("equalizer") ~= nil and get_eq_filter("bass"):find("f=64") ~= nil, "Bass EQ filter string invalid: " .. tostring(get_eq_filter("bass")))
    assert(get_eq_filter("night"):find("dynaudnorm") ~= nil, "Night EQ filter string invalid: " .. tostring(get_eq_filter("night")))
    assert(get_eq_filter("vocal"):find("equalizer") ~= nil, "Vocal EQ filter string invalid: " .. tostring(get_eq_filter("vocal")))
    assert(get_eq_filter("lofi"):find("lowpass") ~= nil, "Lofi EQ filter string invalid: " .. tostring(get_eq_filter("lofi")))
    assert(get_eq_filter("flat") == "", "Flat EQ preset must produce empty filter")
    assert(get_eq_filter("unknown_preset") == "", "Unknown preset must produce empty filter")

    MpvController:set_eq("bass")
    assert(MpvController.eq_preset == "bass", "MpvController:set_eq failed")
    local bass_lines = render_mini_player_lines(sample_spd_item, false, 100, 50, 200, "", false, 90, 1, 1, false, "", 1.0, "bass")
    assert(bass_lines[1]:find("%[BASS%]") ~= nil, "Mini-player header must show [BASS] EQ badge")
    MpvController:set_eq("flat")
    assert(MpvController.eq_preset == "flat", "MpvController:set_eq flat failed")
    print("  [✓] Audio Equalizer presets, dynamic lavfi filter generation & badges validated")

    -- 28. Starred favorites persistence, deduplication, and toggling
    local fav_file = get_favorites_file()
    assert(fav_file ~= nil and #fav_file > 0, "get_favorites_file must return non-empty path")
    local fav_test_item = {
        id = "TESTFAV999",
        url = "https://www.youtube.com/watch?v=TESTFAV999",
        title = "My Starred Track",
        uploader = "Starred Artist",
        duration = 185,
        duration_str = "03:05",
    }
    remove_favorite_item(fav_test_item)
    assert(is_favorite(fav_test_item) == false, "Item should not be favorite initially")
    assert(save_favorite_item(fav_test_item) == true, "save_favorite_item must return true")
    assert(is_favorite(fav_test_item) == true, "Item must be marked as favorite after saving")

    save_favorite_item(fav_test_item)
    local all_favs = load_favorites()
    local count_fav = 0
    for _, f_it in ipairs(all_favs) do
        if f_it.url == fav_test_item.url or f_it.id == fav_test_item.id then
            count_fav = count_fav + 1
        end
    end
    assert(count_fav == 1, "Expected exactly 1 entry for saved favorite in list, got " .. count_fav)

    local toggled_off = toggle_favorite_item(fav_test_item)
    assert(toggled_off == false, "toggle_favorite_item should return false when un-starred")
    assert(is_favorite(fav_test_item) == false, "Item must not be favorite after toggle off")

    local toggled_on = toggle_favorite_item(fav_test_item)
    assert(toggled_on == true, "toggle_favorite_item should return true when starred")
    assert(is_favorite(fav_test_item) == true, "Item must be favorite after toggle on")

    remove_favorite_item(fav_test_item)
    assert(is_favorite(fav_test_item) == false, "Item must not be favorite after remove_favorite_item")
    print("  [✓] Starred favorites persistence, toggle logic & deduplication validated")

    -- 29. Infinite YouTube Mix / Radio recommendations formatting & deduplication
    local existing_queue = {
        { url = "https://www.youtube.com/watch?v=DUP001" },
        { url = "https://www.youtube.com/watch?v=SEEDVID001" },
    }
    local raw_radio_candidates = {
        { id = "DUP001", url = "https://www.youtube.com/watch?v=DUP001", title = "Duplicate 1" },
        { id = "SEEDVID001", url = "https://www.youtube.com/watch?v=SEEDVID001", title = "Original Seed" },
        { id = "NEW001", url = "https://www.youtube.com/watch?v=NEW001", title = "Fresh Radio Track 1" },
        { id = "NEW002", url = "https://www.youtube.com/watch?v=NEW002", title = "Fresh Radio Track 2" },
    }
    local seen_radio = {}
    for _, q in ipairs(existing_queue) do
        seen_radio[q.url or q.id] = true
    end
    local filtered_radio = {}
    for _, c in ipairs(raw_radio_candidates) do
        local key = c.url or c.id
        if not seen_radio[key] then
            seen_radio[key] = true
            table.insert(filtered_radio, c)
        end
    end
    assert(#filtered_radio == 2, "Radio deduplication must yield exactly 2 fresh tracks, got " .. #filtered_radio)
    assert(filtered_radio[1].id == "NEW001", "First fresh radio track mismatch")
    assert(filtered_radio[2].id == "NEW002", "Second fresh radio track mismatch")
    print("  [✓] Infinite YouTube Mix / Radio recommendations deduplication validated")

    -- 30. Audio Equalizer modal headless interaction & key navigation
    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "ESC")
    local eq_esc = show_eq_modal("flat")
    assert(eq_esc == nil, "show_eq_modal must return nil on ESC: got " .. tostring(eq_esc))

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "2")
    local eq_selected = show_eq_modal("flat")
    assert(eq_selected == "night", "show_eq_modal numeric key 2 must select night preset: got " .. tostring(eq_selected))

    for k in pairs(pending_keys) do pending_keys[k] = nil end
    table.insert(pending_keys, "3")
    local eq_bass = show_eq_modal("flat")
    assert(eq_bass == "bass", "show_eq_modal numeric key 3 must select bass preset: got " .. tostring(eq_bass))
    print("  [✓] Audio Equalizer modal headless interaction & key navigation validated")

    print("=== All Internal Self-Tests Passed Successfully ===")
    return true
end

local function print_help()
    print("\27[1;36myt.lua -- Cross-Platform YouTube & Music Terminal Player (LuaJIT FFI)\27[0m")
    print("\nUsage:")
    print("  ./LuaJIT/src/luajit yt.lua [query | url] [options]")
    print("\nOptions:")
    print("  -m, --music           Music mode: audio-only background mini-player via mpv (default)")
    print("  -v, --video           Video mode: video streaming in terminal via mpv --vo=tct")
    print("  -w, --window          In video mode, play in external MPV GUI window instead of terminal")
    print("  -d, --download <q|url> Download track offline to ./downloads/ (MP3 for music, MP4 for video)")
    print("  --sort <type>         Sort search results (relevance, views, date, rating)")
    print("  --duration <type>     Filter results by duration (all, short, medium, long)")
    print("  --site <name>         Search site: youtube, soundcloud, or twitch (default: youtube)")
    print("  -c, --cc, --lyrics    Show Closed Captions (CC) / lyrics (enabled by default)")
    print("  --no-cc               Disable Closed Captions (CC) / lyrics")
    print("  --no-resume           Do not resume playback from last saved position")
    print("  --radio               Start directly in infinite Radio mode (YouTube Mix)")
    print("  --speed <mult>        Initial playback speed (0.5 to 2.5, default: 1.0)")
    print("  --eq <preset>         Initial audio equalizer preset (flat, night, bass, vocal, lofi)")
    print("  --favorites           Open directly to Starred Favorites playlist")
    print("  --sub-lang <lang>     Preferred subtitle/lyrics language pattern (default: en.*)")
    print("  --sub-font-size <pts> Font size for subtitles / CC (default: 55, range: 10-120)")
    print("  --cc-font-size <pts>  Alias for --sub-font-size")
    print("  --sub-color <color>   Subtitle color: white, yellow, cyan (default: white)")
    print("  --cc-color <color>    Alias for --sub-color")
    print("  --browser <name>      Extract session cookies from browser (firefox, chrome, brave, edge)")
    print("  --no-interactive      Non-interactive script/batch mode (print results and exit)")
    print("  --cookies <file>      Use Netscape format cookies.txt file")
    print("  --proxy <url>         Use HTTP/HTTPS/SOCKS proxy for search and streaming (or $HTTPS_PROXY)")
    print("  --insecure            Disable SSL certificate checks (or $YT_INSECURE=1; auto-retried on SSL fail)")
    print("  --liked               Load user's Liked Music or Liked Videos playlist")
    print("  --test                Run automated self-tests and exit")
    print("  -h, --help            Show this help message")
    print("\nInteractive TUI Controls:")
    print("  [Enter]       Play selected track (background mini-player in music mode)")
    print("  [P]           Play foreground full-screen playback")
    print("  [Tab]         Add selected track to Up-Next playback queue")
    print("  [Q]           Open Up-Next playback queue modal (play, delete, clear)")
    print("  [d]           Download selected track offline into ./downloads/")
    print("  [o]           Open selected track in default web browser")
    print("  [y]           Copy selected track URL to clipboard")
    print("  [f]           Open Search Filters & Sorting modal")
    print("  [r]           Toggle infinite Radio mode (YouTube Mix)")
    print("  [e]           Open Audio Equalizer & Sound Enhancement modal")
    print("  [*]           Star / Un-star selected track as Favorite")
    print("  [F]           Toggle Starred Favorites playlist view")
    print("  [[ / ]]       Decrease / Increase playback speed (-/+0.25x)  [{] Reset")
    print("  [Space]       Pause / Resume background mini-player")
    print("  [s]           Skip to next track in queue")
    print("  [x]           Stop background mini-player")
    print("  [<- / ->]     Seek backward / forward 5 seconds")
    print("  [9 / 0]       Volume down / up (-/+10%)")
    print("  [/]           Open search modal or paste URL")
    print("  [a]           Toggle Auto-Play")
    print("  [c]           Toggle Closed Captions (CC / Lyrics)")
    print("  [C]           Cycle subtitle track (Mini-Player)")
    print("  [+ / -]       Increase / Decrease CC font size (+/-5 pt)")
    print("  [Alt+c]       Cycle CC style: White, Yellow, Cyan (in MPV GUI window)")
    print("  [m]           Toggle Music / Video mode")
    print("  [q]           Quit viewer")
    print("\nSystem Status:")
    print(string.format("  yt-dlp:    %s", HAS_YTDLP and "\27[32m[Installed]\27[0m" or "\27[31m[Missing - Required for search/streams]\27[0m"))
    print(string.format("  mpv:       %s", HAS_MPV and "\27[32m[Installed]\27[0m" or "\27[31m[Missing - Required for playback]\27[0m"))
    print(string.format("  chafa:     %s", HAS_CHAFA and "\27[32m[Installed]\27[0m" or "\27[90m[Not Detected - Optional for thumbnails]\27[0m"))
    print(string.format("  ffmpeg:    %s", HAS_FFMPEG and "\27[32m[Installed]\27[0m" or "\27[90m[Not Detected]\27[0m"))
    print(string.format("  deno:      %s", HAS_DENO and "\27[32m[Installed - Fast JS solver for yt-dlp]\27[0m" or "\27[90m[Not Detected - Optional for yt-dlp]\27[0m"))
    print("\nExamples:")
    print("  luajit yt.lua \"synthwave radio\"")
    print("  luajit yt.lua -v \"World War 2 in color\"")
    print("  luajit yt.lua -v --window \"nature 4k\"")
    print("  luajit yt.lua -d \"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"")
    print("  luajit yt.lua --sort views --duration short \"piano relax\"")
    print("  luajit yt.lua --music --lyrics \"never gonna give you up\"")
    print("  luajit yt.lua --site soundcloud --music \"jazz\"")
    print("  luajit yt.lua --site twitch --video \"developer stream\"")
    print("  luajit yt.lua --site vimeo --video \"https://vimeo.com/123456789\"")
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
    local show_cc = true
    local sub_lang = "en.*"
    local sub_font_size = 55
    local sub_color = "white"
    local download_target = nil
    local active_filters = { sort = "relevance", duration = "all" }
    local site = "youtube"
    local is_radio = false
    local initial_speed = 1.0
    local initial_eq = "flat"
    local is_favorites = false

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
        elseif a == "-w" or a == "--window" then
            use_window = true
        elseif a == "-c" or a == "--cc" or a == "--lyrics" or a == "--subtitles" then
            show_cc = true
        elseif a == "--no-cc" or a == "--no-lyrics" or a == "--no-subtitles" then
            show_cc = false
        elseif a == "--no-resume" then
            resume_cfg.enabled = false
        elseif a == "--resume" then
            resume_cfg.enabled = true
        elseif a == "-r" or a == "--radio" then
            is_radio = true
        elseif a == "--speed" then
            i = i + 1
            local sp = tonumber(arg[i])
            if sp then
                initial_speed = math.max(0.5, math.min(2.5, sp))
            end
        elseif a == "--eq" then
            i = i + 1
            local eq = (arg[i] or "flat"):lower()
            if is_valid_eq_preset(eq) then
                initial_eq = eq
            end
        elseif a == "--fav" or a == "--favorites" or a == "--starred" then
            is_favorites = true
        elseif a == "--sub-lang" or a == "--sub-langs" or a == "--slang" then
            i = i + 1
            sub_lang = arg[i]
        elseif a == "--sub-font-size" or a == "--cc-font-size" or a == "--sub-fontsize" then
            i = i + 1
            local parsed_size = tonumber(arg[i])
            if parsed_size then
                sub_font_size = math.max(10, math.min(120, math.floor(parsed_size)))
            end
        elseif a == "--sub-color" or a == "--cc-color" then
            i = i + 1
            local c = (arg[i] or "white"):lower()
            if c == "yellow" or c == "cyan" or c == "white" then
                sub_color = c
            end
        elseif a == "-d" or a == "--download" then
            i = i + 1
            download_target = arg[i]
        elseif a == "--sort" then
            i = i + 1
            active_filters.sort = (arg[i] or "relevance"):lower()
        elseif a == "--duration" then
            i = i + 1
            active_filters.duration = (arg[i] or "all"):lower()
        elseif a == "--site" then
            i = i + 1
            site = normalize_site(arg[i])
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

    if download_target then
        local target_item
        local is_direct_url = download_target:match("^https?://") or download_target:match("^www%.") or download_target:match("^youtu%.be/")
        if is_direct_url then
            target_item = {
                id = "direct",
                url = download_target,
                title = "Direct Download",
                uploader = "YouTube",
            }
        else
            io.write(string.format("\27[1;36m* Searching %s for download (%s mode): \27[1;93m%s\27[0m ...\n", site:upper(), mode:upper(), download_target))
            io.flush()
            local res, err = fetch_youtube_results(download_target, mode, browser, cookies_file, 1, false, proxy, insecure, active_filters, site)
            if res and #res > 0 then
                target_item = res[1]
            else
                io.stderr:write("Download error: " .. tostring(err or "No video found for search query") .. "\n")
                os.exit(1)
            end
        end
        download_item(target_item, mode, browser, cookies_file, proxy, insecure)
        return
    end

    if non_interactive or (not is_stdin_tty()) then
        if is_favorites then
            local res = load_favorites()
            print(string.format("\27[1;36m=== Starred Favorites (%d tracks) ===\27[0m", #res))
            for idx, item in ipairs(res) do
                local t_disp = utf8_truncate(item.title or "Unknown", 50)
                local t_pad = string.rep(" ", math.max(0, 50 - display_width(t_disp)))
                local up_disp = utf8_truncate(item.uploader or "Unknown", 22)
                local up_pad = string.rep(" ", math.max(0, 22 - display_width(up_disp)))
                print(string.format("  %02d. %s%s | %s%s | %s", idx, t_disp, t_pad, up_disp, up_pad, item.duration_str or "--:--"))
            end
            return
        end

        local q = query or "lofi hip hop"
        local res, err, used_insecure = fetch_youtube_results(q, mode, browser, cookies_file, max_results, is_liked, proxy, insecure, active_filters, site)
        if not res then
            io.stderr:write("Error: " .. tostring(err) .. "\n")
            os.exit(1)
        end
        local sec_note = (used_insecure or insecure) and " [CORP SSL/INSECURE]" or ""
        local filter_note = (active_filters.sort ~= "relevance" or active_filters.duration ~= "all") and string.format(" [Sort: %s, Dur: %s]", active_filters.sort, active_filters.duration) or ""
        print(string.format("\27[1;36m=== %s Results for '%s' (%s mode)%s%s ===\27[0m", site:upper(), q, mode:upper(), filter_note, sec_note))
        for idx, item in ipairs(res) do
            local t_disp = utf8_truncate(item.title, 50)
            local t_pad = string.rep(" ", math.max(0, 50 - display_width(t_disp)))
            local up_disp = utf8_truncate(item.uploader, 22)
            local up_pad = string.rep(" ", math.max(0, 22 - display_width(up_disp)))
            print(string.format("  %02d. %s%s | %s%s | %s", idx, t_disp, t_pad, up_disp, up_pad, item.duration_str))
        end
        return
    end

    run_app(query, mode, browser, cookies_file, is_liked, use_window, proxy, insecure, show_cc, sub_lang, active_filters, site, sub_font_size, sub_color, is_radio, initial_speed, initial_eq, is_favorites)
end

main()
