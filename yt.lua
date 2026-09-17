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
        DWORD GetTickCount(void);
        void Sleep(DWORD dwMilliseconds);

        int _kbhit(void);
        int _getch(void);
        int _isatty(int fd);
    ]]

    local kernel32 = ffi.load("kernel32")
    local STD_INPUT_HANDLE = ffi.cast("DWORD", -10)
    local STD_OUTPUT_HANDLE = ffi.cast("DWORD", -11)

    local orig_in_mode = ffi.new("DWORD[1]")
    local raw_mode_enabled = false

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
                return unescape_unicode(table.concat(chars))
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
    local p = io.popen(cmd, POPEN_READ_BIN)
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
                title = unescape_unicode(title),
                uploader = unescape_unicode(channel),
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

        local p = io.popen(cmd, POPEN_READ_BIN)
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
        return items
    end

    -- Automatic Fallback: Direct Web Scrape via curl (works even if yt-dlp is blocked or broken)
    if not is_liked and not is_direct_url then
        local fallback_items = scrape_youtube_search(term, max_results, proxy, insecure)
        if fallback_items and #fallback_items > 0 then
            return fallback_items
        end
    end

    -- If both engines failed, produce helpful actionable error
    local err_text = table.concat(err_lines, "\n")
    if err_text:find("CERTIFICATE_VERIFY_FAILED") or err_text:find("certificate verify failed") then
        return nil, "SSL certificate failed (corporate network?). Try: --insecure"
    elseif err_text:find("Sign in to confirm") or err_text:find("bot") then
        return nil, "YouTube blocked request (anti-bot). Try: --browser <chrome|edge|firefox> or --cookies <file>"
    elseif err_text:find("429") or err_text:find("Too Many Requests") then
        return nil, "Rate limited by YouTube (429). Try: --browser or --proxy <url>"
    elseif err_text:find("ProxyError") or err_text:find("Connection refused") or err_text:find("timed out") then
        return nil, "Connection failed. Check network or try: --proxy <url>"
    elseif #err_lines > 0 then
        local first_err = err_lines[1]:gsub("^ERROR:%s*", ""):gsub("^%[.-%]%s*", "")
        return nil, "yt-dlp error: " .. first_err:sub(1, 70)
    elseif not HAS_YTDLP then
        return nil, "yt-dlp is not installed and web fallback returned 0 items."
    end

    return nil, "No results found for '" .. query .. "'."
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
        local p = io.popen(string.format('chafa --size=%dx%d --format=symbols --symbols=block %q 2>/dev/null',
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

-- =========================================================================
-- 5. Playback Controller
-- =========================================================================
local function play_item(item, mode, browser, cookies_file, use_external_window, proxy, insecure)
    if not HAS_MPV then
        io.write("\27[H\27[2J\27[1;31mError: mpv is not installed.\27[0m\n\nPlease install mpv to play audio/video streams.\nPress any key to return...")
        io.flush()
        read_key()
        return
    end

    local raw_opts = { "extractor-args=youtube:player_client=android" }
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

    local term_w, term_h = get_terminal_size()
    local mpv_cmd

    if mode == "music" then
        -- Audio-only streaming with OSD status
        mpv_cmd = string.format(
            'mpv --no-video --hwdec=auto --term-osd-bar --ytdl-format="bestaudio/best" '
            .. '--term-status-msg="  ${media-title}  [${playback-time} / ${duration}]  Vol: ${volume}%%" '
            .. '%s%s %q',
            ytdl_raw_opts, extra_mpv_opts, item.url
        )
    else
        -- Video playback
        if use_external_window then
            mpv_cmd = string.format('mpv --hwdec=auto %s%s %q', ytdl_raw_opts, extra_mpv_opts, item.url)
        else
            -- Terminal ASCII/Half-block video (capped to 480p for performance & bandwidth efficiency)
            mpv_cmd = string.format(
                'mpv --vo=tct --vo-tct-width=%d --vo-tct-height=%d --hwdec=auto --term-osd-bar '
                .. '--ytdl-format="bestvideo[height<=480]+bestaudio/best[height<=480]/best" '
                .. '--term-status-msg="  ${media-title}  [${playback-time} / ${duration}]" '
                .. '%s%s %q',
                math.max(10, term_w), math.max(6, term_h - 1),
                ytdl_raw_opts, extra_mpv_opts, item.url
            )
        end
    end

    disable_raw_mode()
    io.write("\27[H\27[2J\27[1;36m▶ Connecting to YouTube stream: \27[1;33m" .. item.title .. "\27[0m\n\n")
    io.flush()

    local exit_code = os.execute(mpv_cmd)

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
        io.write(string.format("\27[%d;%dH\27[1;36m┌%s┐\27[0m", box_y, box_x, string.rep("─", box_w - 2)))
        io.write(string.format("\27[%d;%dH\27[1;36m│ \27[1;37mSearch YouTube / URL:\27[0m%s\27[1;36m│\27[0m",
            box_y + 1, box_x, string.rep(" ", box_w - 24)))
        
        local display_input = input_str
        if #display_input > box_w - 6 then
            display_input = display_input:sub(#display_input - (box_w - 9))
        end
        local pad = math.max(0, box_w - 6 - #display_input)
        io.write(string.format("\27[%d;%dH\27[1;36m│ \27[93m> %s\27[7m \27[0m%s\27[1;36m│\27[0m",
            box_y + 2, box_x, display_input, string.rep(" ", pad)))
        io.write(string.format("\27[%d;%dH\27[1;36m│ \27[90m[Enter] Search   [Esc] Cancel\27[0m%s\27[1;36m│\27[0m",
            box_y + 3, box_x, string.rep(" ", box_w - 32)))
        io.write(string.format("\27[%d;%dH\27[1;36m└%s┘\27[0m", box_y + 4, box_x, string.rep("─", box_w - 2)))
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
        return text .. string.rep(" ", pad) .. "│"
    end

    local help_lines = {
        "┌" .. string.rep("─", box_w - 2) .. "┐",
        line_pad("│  \27[1;36mYouTube Terminal Viewer — Shortcut Cheat Sheet\27[0m", 47),
        "├" .. string.rep("─", box_w - 2) .. "┤",
        line_pad("│  \27[1;33mTerminal Navigation & Controls:\27[0m", 32),
        line_pad("│    \27[93m[Enter]\27[0m       Play selected video or music track", 45),
        line_pad("│    \27[93m[/]\27[0m           Open search modal or paste direct URL", 48),
        line_pad("│    \27[93m[a]\27[0m           Toggle continuous Auto-Play (Radio mode)", 51),
        line_pad("│    \27[93m[h]\27[0m           Toggle Playback History (recent tracks)", 50),
        line_pad("│    \27[93m[m]\27[0m           Toggle between Music and Video mode", 46),
        line_pad("│    \27[93m[L]\27[0m           Toggle Liked Songs playlist", 38),
        line_pad("│    \27[93m[↑/↓, k/j]\27[0m    Navigate results list", 33),
        line_pad("│    \27[93m[PgUp/PgDn]\27[0m   Scroll 10 tracks up or down", 38),
        line_pad("│  \27[1;33mIn-Playback Controls (mpv):\27[0m", 28),
        line_pad("│    \27[93m[Space]\27[0m       Pause / Resume playback", 34),
        line_pad("│    \27[93m[← / →]\27[0m       Seek backward / forward 5 seconds", 44),
        line_pad("│    \27[93m[9 / 0]\27[0m       Volume down / Volume up", 34),
        line_pad("│    \27[93m[[ / ]]\27[0m       Speed down / Speed up (±10%)", 39),
        line_pad("│    \27[93m[q]\27[0m           Stop playing and return to browser", 45),
        "├" .. string.rep("─", box_w - 2) .. "┤",
        line_pad("│  \27[90mPress any key to close this help modal...\27[0m", 41),
        "└" .. string.rep("─", box_w - 2) .. "┘",
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
local function run_app(init_query, init_mode, browser, cookies_file, is_liked, use_window, proxy, insecure)
    local current_query = init_query or "lofi beats"
    local mode = init_mode or "music"
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
        io.write(string.format("\n  \27[1;36m⟳ Searching YouTube (%s mode): \27[1;93m%s\27[0m ...\n",
            mode:upper(), is_liked and "Liked Songs" or current_query))
        io.flush()

        local res, err = fetch_youtube_results(current_query, mode, browser, cookies_file, 25, is_liked, proxy, insecure)
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
        local header = string.format(" \27[1;36mYouTube Terminal Viewer\27[0m | %s | %s | \27[90m%s\27[0m", mode_badge, auto_badge, auth_label)
        table.insert(buf, "\27[1;34m" .. string.rep("═", term_w) .. "\27[0m\n")
        table.insert(buf, header .. "\27[K\n")

        -- 2. Query / Search Subheader
        local q_display
        if is_history then
            q_display = "\27[1;95m🕒 Playback History\27[0m"
        elseif is_liked then
            q_display = "\27[1;95m★ Liked Songs Playlist\27[0m"
        else
            q_display = '"' .. current_query .. '"'
        end
        table.insert(buf, string.format("  \27[90mSearch:\27[0m %s  \27[90m(%s)\27[0m\27[K\n", q_display, status_msg))
        table.insert(buf, "\27[1;34m" .. string.rep("─", term_w) .. "\27[0m\n")

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
                    local cursor = is_sel and "\27[1;92m❯ " or "  "
                    
                    local max_title_w = math.max(15, term_w - 38)
                    local t = it.title
                    if #t > max_title_w then
                        t = t:sub(1, max_title_w - 1) .. "…"
                    end
                    local title_pad = string.rep(" ", math.max(0, max_title_w - #t))

                    local max_up_w = 18
                    local up = it.uploader
                    if #up > max_up_w then
                        up = up:sub(1, max_up_w - 1) .. "…"
                    end
                    local up_pad = string.rep(" ", math.max(0, max_up_w - #up))

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
        table.insert(buf, "\27[1;34m" .. string.rep("─", term_w) .. "\27[0m\n")
        table.insert(buf, string.format(" \27[93m[Enter]\27[0m Play  \27[93m[/]\27[0m Search  \27[93m[a]\27[0m Auto:%s  \27[93m[h]\27[0m History  \27[93m[m]\27[0m Mode  \27[93m[?]\27[0m Help  \27[91m[q]\27[0m Quit\27[K", auto_footer))
        
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
                local exit_code = play_item(sel, mode, browser, cookies_file, use_window, proxy, insecure)
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
local function print_help()
    print("\27[1;36myt.lua — Cross-Platform YouTube & Music Terminal Player (LuaJIT FFI)\27[0m")
    print("\nUsage:")
    print("  ./LuaJIT/src/luajit yt.lua [query | url] [options]")
    print("\nOptions:")
    print("  -m, --music           Music mode: audio-only streaming via mpv (default)")
    print("  -v, --video           Video mode: video streaming in terminal via mpv --vo=tct")
    print("  --window              In video mode, play in external MPV GUI window instead of terminal")
    print("  --browser <name>      Extract session cookies from browser (firefox, chrome, brave, edge)")
    print("  --no-interactive      Non-interactive script/batch mode (print results and exit)")
    print("  --cookies <file>      Use Netscape format cookies.txt file")
    print("  --proxy <url>         Use HTTP/HTTPS/SOCKS proxy for search and streaming")
    print("  --insecure            Disable SSL certificate checks (useful for corporate proxy SSL inspection)")
    print("  --liked               Load user's Liked Music or Liked Videos playlist")
    print("  -h, --help            Show this help message")
    print("\nSystem Status:")
    print(string.format("  yt-dlp:    %s", HAS_YTDLP and "\27[32m[Installed]\27[0m" or "\27[31m[Missing - Required for search/streams]\27[0m"))
    print(string.format("  mpv:       %s", HAS_MPV and "\27[32m[Installed]\27[0m" or "\27[31m[Missing - Required for playback]\27[0m"))
    print(string.format("  chafa:     %s", HAS_CHAFA and "\27[32m[Installed]\27[0m" or "\27[90m[Not Detected - Optional for thumbnails]\27[0m"))
    print(string.format("  ffmpeg:    %s", HAS_FFMPEG and "\27[32m[Installed]\27[0m" or "\27[90m[Not Detected]\27[0m"))
    print(string.format("  deno:      %s", HAS_DENO and "\27[32m[Installed - Fast JS solver for yt-dlp]\27[0m" or "\27[90m[Not Detected - Optional for yt-dlp]\27[0m"))
    print("\nExamples:")
    print("  luajit yt.lua \"synthwave radio\"")
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
    local proxy = nil
    local insecure = false
    local max_results = 20
    local query_parts = {}

    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "-h" or a == "--help" then
            print_help()
            return
        elseif a == "-m" or a == "--music" then
            mode = "music"
        elseif a == "-v" or a == "--video" then
            mode = "video"
        elseif a == "--window" then
            use_window = true
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
        local res, err = fetch_youtube_results(q, mode, browser, cookies_file, max_results, is_liked, proxy, insecure)
        if not res then
            io.stderr:write("Error: " .. tostring(err) .. "\n")
            os.exit(1)
        end
        print(string.format("\27[1;36m=== YouTube Results for '%s' (%s mode) ===\27[0m", q, mode:upper()))
        for idx, item in ipairs(res) do
            print(string.format("  %02d. %-50s | %-22s | %s", idx, item.title:sub(1, 50), item.uploader:sub(1, 22), item.duration_str))
        end
        return
    end

    run_app(query, mode, browser, cookies_file, is_liked, use_window, proxy, insecure)
end

main()
