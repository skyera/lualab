--[[
    web_lite.lua
    A fast, beautiful, Vim-driven terminal web browser written in pure LuaJIT with FFI.
    Inspired by Lynx, w3m, qutebrowser, and Vimium.

    Key Features:
    1. Full Vim Keybindings & Modal Navigation:
       - Normal Mode:
         * j / k / ↓ / ↑       : Scroll down / up 1 line (supports counts, e.g. 5j)
         * d / u               : Half-page scroll down / up (Ctrl-d / Ctrl-u)
         * Ctrl-f / Space / PgDn: Full-page scroll down
         * Ctrl-b / PgUp       : Full-page scroll up
         * gg / G              : Jump to top / bottom of document
         * H / L               : Navigate back / forward in browsing history
         * r / R               : Reload current page
         * yy                  : Yank (copy) current page URL to clipboard
         * Tab / Shift-Tab     : Cycle focus to next / previous link on page
         * Enter               : Follow currently focused link
         * o                   : Open URL / Search prompt (:open )
         * O                   : Open URL prompt prefilled with current URL
         * /                   : In-page text search
         * n / N               : Jump to next / previous search match
         * :                   : Ex-command mode (:open, :q, :help, :reload, :dump)
         * q                   : Quit browser
       - Vimium Hint Mode (f):
         * Press 'f' to overlay letter badges ([A], [B], [C]...) on all visible links.
         * Press the matching letter to follow that link instantly!
         * Press Esc to cancel hint mode.
       - Smart Omnibox URL Input:
         * Type direct domain (e.g., "news.ycombinator.com" -> auto-adds https://)
         * Type search query (e.g., "luajit ffi tutorial" -> routes to DuckDuckGo Lite)
         * History navigation with Up / Down arrow keys
         * Editing with Backspace, Left/Right, Ctrl-U (clear), Ctrl-W (delete word)
    2. HTML5 Reader & Layout Reflow Engine:
       - Fast streaming tokenizer & entity decoder (&amp;, &lt;, &gt;, &quot;, &mdash;, &#...;).
       - Semantics: Headings (h1-h3) with styling, blockquotes (│ ), code fences, lists (•, 1.).
       - Unicode box-drawing Table Formatter (┌─┬─┐, │ │ │, ├─┼─┤, └─┴─┘).
       - Strips non-content tags (<script>, <style>, <noscript>, <svg>, <nav>).
       - Preserves and numbers all hyperlinks with click & hint coordinates.
    3. Cross-Platform FFI Architecture:
       - Windows: Win32 Console API (kernel32.dll) for VT100, raw mode, and terminal sizing.
       - Linux / macOS: POSIX termios, poll, ioctl(TIOCGWINSZ).
       - Network: HTTPS fetching via curl.exe / curl / local file:// support.
    4. Headless Dump Mode:
       - Run 'luajit web_lite.lua --dump <url>' for instant terminal plain-text rendering (like lynx -dump).
]]

local ffi = require("ffi")
local bit = require("bit")

local is_windows = (ffi.os == "Windows")
local M = {}

-- =========================================================================
-- 1. Platform FFI Declarations (Windows & POSIX)
-- =========================================================================
local enable_raw_mode, disable_raw_mode, get_terminal_size, read_key
local in_raw_mode = false
local kernel32

if is_windows then
    kernel32 = ffi.load("kernel32")
    ffi.cdef[[
        typedef void *HANDLE;
        typedef struct _COORD { short X; short Y; } COORD;
        typedef struct _SMALL_RECT { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
        typedef struct _CONSOLE_SCREEN_BUFFER_INFO {
            COORD      dwSize;
            COORD      dwCursorPosition;
            uint16_t   wAttributes;
            SMALL_RECT srWindow;
            COORD      dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;
        HANDLE GetStdHandle(uint32_t nStdHandle);
        int GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO *lpConsoleScreenBufferInfo);
        int GetConsoleMode(HANDLE hConsoleHandle, uint32_t *lpMode);
        int SetConsoleMode(HANDLE hConsoleHandle, uint32_t dwMode);
        int SetConsoleCP(uint32_t wCodePageID);
        int SetConsoleOutputCP(uint32_t wCodePageID);
        void Sleep(uint32_t dwMilliseconds);
        int _kbhit(void);
        int _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5
    local orig_in_mode = ffi.new("uint32_t[1]")
    local orig_out_mode = ffi.new("uint32_t[1]")

    enable_raw_mode = function()
        local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        if kernel32.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end
        kernel32.GetConsoleMode(hOut, orig_out_mode)

        kernel32.SetConsoleCP(65001)
        kernel32.SetConsoleOutputCP(65001)
        local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        kernel32.SetConsoleMode(hOut, bit.bor(orig_out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))

        local raw_mode = bit.band(orig_in_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
        kernel32.SetConsoleMode(hIn, raw_mode)

        in_raw_mode = true
        io.write("\27[?1049h\27[?25l") -- alternate screen buffer, hide cursor
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1049l\27[?25h\27[0m") -- restore main buffer, show cursor, reset color
            io.flush()
            local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
            local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
            kernel32.SetConsoleMode(hIn, orig_in_mode[0])
            kernel32.SetConsoleMode(hOut, orig_out_mode[0])
            in_raw_mode = false
        end
    end

    get_terminal_size = function()
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if kernel32.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if w > 0 and h > 0 then return tonumber(w), tonumber(h) end
        end
        return 100, 30
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 50
        local elapsed = 0
        while elapsed < timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                local c0 = ffi.C._getch()
                if c0 == 0 or c0 == 224 then
                    local c1 = ffi.C._getch()
                    if c1 == 72 then return "UP"
                    elseif c1 == 80 then return "DOWN"
                    elseif c1 == 75 then return "LEFT"
                    elseif c1 == 77 then return "RIGHT"
                    elseif c1 == 73 then return "PAGE_UP"
                    elseif c1 == 81 then return "PAGE_DOWN"
                    elseif c1 == 71 then return "HOME"
                    elseif c1 == 79 then return "END"
                    elseif c1 == 15 then return "SHIFT_TAB"
                    end
                elseif c0 == 27 then
                    return "ESC"
                elseif c0 == 9 then
                    return "TAB"
                elseif c0 == 13 or c0 == 10 then
                    return "ENTER"
                elseif c0 == 32 then
                    return "SPACE"
                elseif c0 == 8 or c0 == 127 then
                    return "BACKSPACE"
                elseif c0 == 4 then -- Ctrl-D
                    return "CTRL_D"
                elseif c0 == 21 then -- Ctrl-U
                    return "CTRL_U"
                elseif c0 == 6 then -- Ctrl-F
                    return "CTRL_F"
                elseif c0 == 2 then -- Ctrl-B
                    return "CTRL_B"
                elseif c0 == 23 then -- Ctrl-W
                    return "CTRL_W"
                elseif c0 >= 32 and c0 <= 126 then
                    return string.char(c0)
                elseif c0 >= 192 and c0 < 224 then
                    local c1 = ffi.C._getch()
                    return string.char(c0, c1)
                elseif c0 >= 224 and c0 < 240 then
                    local c1 = ffi.C._getch()
                    local c2 = ffi.C._getch()
                    return string.char(c0, c1, c2)
                elseif c0 >= 240 and c0 <= 247 then
                    local c1 = ffi.C._getch()
                    local c2 = ffi.C._getch()
                    local c3 = ffi.C._getch()
                    return string.char(c0, c1, c2, c3)
                end
            end
            kernel32.Sleep(10)
            elapsed = elapsed + 10
        end
        return nil
    end
else
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
        void usleep(unsigned int usec);
    ]]

    local TIOCGWINSZ = (ffi.os == "OSX") and 0x40087468 or 0x5413
    local orig_termios = ffi.new("struct termios")

    enable_raw_mode = function()
        if ffi.C.tcgetattr(0, orig_termios) ~= 0 then return false end
        local raw = ffi.new("struct termios")
        ffi.copy(raw, orig_termios, ffi.sizeof("struct termios"))

        raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0008, 0x0002, 0x0001, 0x0010)))
        raw.c_iflag = bit.band(raw.c_iflag, bit.bnot(bit.bor(0x0001, 0x0002, 0x0004, 0x0010, 0x0400)))
        raw.c_cc[5] = 0 -- VMIN
        raw.c_cc[6] = 0 -- VTIME

        if ffi.C.tcsetattr(0, 0, raw) ~= 0 then return false end
        in_raw_mode = true
        io.write("\27[?1049h\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(0, 0, orig_termios)
            in_raw_mode = false
        end
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 100, 30
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 50
        local pfd = ffi.new("struct pollfd[1]")
        pfd[0].fd = 0
        pfd[0].events = 1 -- POLLIN
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret <= 0 then return nil end

        local buf = ffi.new("char[16]")
        local n = ffi.C.read(0, buf, 16)
        if n <= 0 then return nil end

        local b0 = string.byte(ffi.string(buf, 1))
        if b0 == 27 then
            if n == 1 then return "ESC" end
            local seq = ffi.string(buf + 1, n - 1)
            if seq == "[A" then return "UP"
            elseif seq == "[B" then return "DOWN"
            elseif seq == "[C" then return "RIGHT"
            elseif seq == "[D" then return "LEFT"
            elseif seq == "[5~" then return "PAGE_UP"
            elseif seq == "[6~" then return "PAGE_DOWN"
            elseif seq == "[H" or seq == "[1~" then return "HOME"
            elseif seq == "[F" or seq == "[4~" then return "END"
            elseif seq == "[Z" then return "SHIFT_TAB"
            end
            return "ESC"
        elseif b0 == 9 then
            return "TAB"
        elseif b0 == 10 or b0 == 13 then
            return "ENTER"
        elseif b0 == 32 then
            return "SPACE"
        elseif b0 == 127 or b0 == 8 then
            return "BACKSPACE"
        elseif b0 == 4 then
            return "CTRL_D"
        elseif b0 == 21 then
            return "CTRL_U"
        elseif b0 == 6 then
            return "CTRL_F"
        elseif b0 == 2 then
            return "CTRL_B"
        elseif b0 == 23 then
            return "CTRL_W"
        else
            return ffi.string(buf, n)
        end
    end
end

-- Export low-level terminal functions to M
M.enable_raw_mode   = enable_raw_mode
M.disable_raw_mode  = disable_raw_mode
M.get_terminal_size = get_terminal_size
M.read_key          = read_key

-- =========================================================================
-- 2. String & Visual Formatting Utilities
-- =========================================================================
local function strip_ansi(str)
    return (str:gsub("\27%[[0-9;]*[a-zA-Z]", ""))
end

local function visual_len(str)
    local clean = strip_ansi(str)
    local len = 0
    local i = 1
    local n = #clean
    while i <= n do
        local b = string.byte(clean, i)
        if b < 128 then
            len = len + 1
            i = i + 1
        elseif b >= 192 and b < 224 then
            len = len + 1
            i = i + 2
        elseif b >= 224 and b < 240 then
            len = len + 2
            i = i + 3
        elseif b >= 240 then
            len = len + 2
            i = i + 4
        else
            i = i + 1
        end
    end
    return len
end

local function truncate(str, max_len)
    if not str then return "" end
    if visual_len(str) <= max_len then return str end
    local cur_len = 0
    local res = {}
    local i = 1
    local n = #str
    while i <= n and cur_len < max_len - 1 do
        local b = string.byte(str, i)
        local w = 1
        local step = 1
        if b < 128 then
            step = 1
            w = 1
        elseif b >= 192 and b < 224 then
            step = 2
            w = 1
        elseif b >= 224 and b < 240 then
            step = 3
            w = 2
        elseif b >= 240 then
            step = 4
            w = 2
        end
        if cur_len + w > max_len - 1 then break end
        table.insert(res, str:sub(i, i + step - 1))
        cur_len = cur_len + w
        i = i + step
    end
    return table.concat(res) .. "…"
end

local function pad_right(str, width)
    local vlen = visual_len(str)
    if vlen >= width then return str end
    return str .. string.rep(" ", width - vlen)
end

local function utf8_pop_char(str)
    if not str or #str == 0 then return "" end
    local i = #str
    while i > 1 and string.byte(str, i) >= 128 and string.byte(str, i) < 192 do
        i = i - 1
    end
    return str:sub(1, i - 1)
end

local function url_encode(str)
    if not str then return "" end
    return (str:gsub("([^%w%-%_%.%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+"))
end

M.strip_ansi     = strip_ansi
M.visual_len     = visual_len
M.truncate       = truncate
M.pad_right      = pad_right
M.utf8_pop_char  = utf8_pop_char
M.url_encode     = url_encode

-- =========================================================================
-- 3. HTML Entity Decoder & Tag Cleaner
-- =========================================================================
local ENTITIES = {
    ["&nbsp;"]  = " ",
    ["&amp;"]   = "&",
    ["&lt;"]    = "<",
    ["&gt;"]    = ">",
    ["&quot;"]  = "\"",
    ["&apos;"]  = "'",
    ["&#39;"]   = "'",
    ["&#039;"]  = "'",
    ["&mdash;"] = "—",
    ["&ndash;"] = "–",
    ["&bull;"]  = "•",
    ["&hellip;"]= "…",
    ["&copy;"]  = "©",
    ["&reg;"]   = "®",
    ["&trade;"] = "™",
    ["&ldquo;"] = "“",
    ["&rdquo;"] = "”",
    ["&lsquo;"] = "‘",
    ["&rsquo;"] = "’",
    ["&deg;"]   = "°",
    ["&plusmn;"]= "±",
    ["&times;"] = "×",
    ["&divide;"]= "÷",
    ["&cent;"]  = "¢",
    ["&pound;"] = "£",
    ["&euro;"]  = "€",
    ["&yen;"]   = "¥",
    ["&middot;"]= "·",
    ["&darr;"]  = "↓",
    ["&uarr;"]  = "↑",
    ["&rarr;"]  = "→",
    ["&larr;"]  = "←",
}

local function decode_entities(text)
    if not text then return "" end
    text = text:gsub("(&%a+;)", function(ent)
        return ENTITIES[ent] or ent
    end)
    text = text:gsub("&#([0-9]+);", function(num_str)
        local code = tonumber(num_str)
        if code and code > 0 and code < 65536 then
            if code < 128 then return string.char(code)
            elseif code < 2048 then
                return string.char(bit.bor(0xC0, bit.rshift(code, 6)), bit.bor(0x80, bit.band(code, 0x3F)))
            else
                return string.char(bit.bor(0xE0, bit.rshift(code, 12)), bit.bor(0x80, bit.band(bit.rshift(code, 6), 0x3F)), bit.bor(0x80, bit.band(code, 0x3F)))
            end
        end
        return ""
    end)
    text = text:gsub("&#x([0-9a-fA-F]+);", function(hex_str)
        local code = tonumber(hex_str, 16)
        if code and code > 0 and code < 65536 then
            if code < 128 then return string.char(code)
            elseif code < 2048 then
                return string.char(bit.bor(0xC0, bit.rshift(code, 6)), bit.bor(0x80, bit.band(code, 0x3F)))
            else
                return string.char(bit.bor(0xE0, bit.rshift(code, 12)), bit.bor(0x80, bit.band(bit.rshift(code, 6), 0x3F)), bit.bor(0x80, bit.band(code, 0x3F)))
            end
        end
        return ""
    end)
    return text
end

local function strip_scripts_and_styles(html)
    if not html then return "" end
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]>", "")
    html = html:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]>", "")
    html = html:gsub("<[nN][oO][sS][cC][rR][iI][pP][tT][^>]*>.-</[nN][oO][sS][cC][rR][iI][pP][tT]>", "")
    html = html:gsub("<[sS][vV][gG][^>]*>.-</[sS][vV][gG]>", "")
    return html
end

M.decode_entities             = decode_entities
M.strip_scripts_and_styles    = strip_scripts_and_styles

-- =========================================================================
-- 4. URL Resolver & Search Engine Integration
-- =========================================================================
local function resolve_relative_url(base_url, href)
    if not href or href == "" then return base_url or "" end
    if href:match("^https?://") or href:match("^file://") then
        return href
    end
    if not base_url or base_url == "" or base_url:match("^about:") then
        return href
    end

    local scheme, host, path = base_url:match("^(https?://)([^/]+)(.*)$")
    if not scheme then return href end

    if href:sub(1, 2) == "//" then
        return scheme:sub(1, -2) .. ":" .. href
    end

    if href:sub(1, 1) == "/" then
        return scheme .. host .. href
    end

    if href:sub(1, 1) == "#" then
        local no_hash = base_url:match("^([^#]+)")
        return (no_hash or base_url) .. href
    end

    local dir = path:match("^(.-/)[^/]*$") or "/"
    return scheme .. host .. dir .. href
end

local function smart_resolve_input(input)
    if not input or input == "" then
        return "about:home", "home"
    end

    input = input:match("^%s*(.-)%s*$")
    if input == "about:home" or input == "about:blank" or input == "about:help" or input == "home" or input == "help" then
        if input == "home" then return "about:home", "about" end
        if input == "help" then return "about:help", "about" end
        return input, "about"
    end

    if input:match("^file://") or input:match("^[A-Za-z]:[\\/]") or input:match("^/[^/]") then
        return input, "file"
    end

    if input:match("^https?://") then
        return input, "url"
    end

    if input:match("^[%w%-]+%.[%w%.%-%/]+$") or (input:match("%.") and not input:match("%s")) then
        return "https://" .. input, "url"
    end

    local query = url_encode(input)
    return "https://lite.duckduckgo.com/lite/?q=" .. query, "search"
end

M.resolve_relative_url = resolve_relative_url
M.smart_resolve_input  = smart_resolve_input

-- =========================================================================
-- 5. Network & HTTP/HTTPS Fetcher
-- =========================================================================
local function fetch_url(url)
    if url == "about:home" or url == "about:blank" then
        return M.get_home_page_html(), 200, "text/html"
    elseif url == "about:help" then
        return M.get_help_page_html(), 200, "text/html"
    end

    if url:match("^file://") or url:match("^[A-Za-z]:[\\/]") or (is_windows and url:match("^[A-Za-z]:")) then
        local filepath = url:gsub("^file:///?", "")
        if is_windows and filepath:match("^/[A-Za-z]:") then
            filepath = filepath:sub(2)
        end
        local f = io.open(filepath, "rb")
        if not f then
            return string.format("<html><body><h1>404 Not Found</h1><p>Cannot open local file: %s</p></body></html>", filepath), 404, "text/html"
        end
        local content = f:read("*a")
        f:close()
        return content, 200, "text/html"
    end

    local curl_cmd = is_windows and "curl.exe" or "curl"
    local user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) web_lite/1.0"
    local escaped_url = url:gsub("\"", "\\\"")
    local cmd = string.format("%s -sSL --max-time 15 -H \"Accept-Language: zh-CN,zh;q=0.9,en;q=0.8\" -H \"Accept-Charset: utf-8, *;q=0.8\" -A \"%s\" \"%s\"", curl_cmd, user_agent, escaped_url)

    local pipe = io.popen(cmd, is_windows and "rb" or "r")
    if not pipe then
        return "<html><body><h1>Network Error</h1><p>Failed to execute network request.</p></body></html>", 500, "text/html"
    end

    local body = pipe:read("*a")
    pipe:close()

    if not body or #body == 0 then
        return string.format("<html><body><h1>Connection Failed</h1><p>Could not connect to: %s</p><p>Please check your internet connection or URL.</p></body></html>", url), 502, "text/html"
    end

    return body, 200, "text/html"
end

M.fetch_url = fetch_url

-- =========================================================================
-- 6. Built-in Pages: Home & Help
-- =========================================================================
function M.get_home_page_html()
    return [[
<!DOCTYPE html>
<html>
<head><title>web_lite: Modern Terminal Browser</title></head>
<body>
<h1>web_lite</h1>
<h3>A Fast, Vim-Driven Terminal Web Browser for LuaJIT FFI</h3>
<p>Welcome to <b>web_lite</b>! Browse the web with pure Vim efficiency, zero bloat, and lightning speed.</p>
<hr>
<h2>Quick Bookmarks / 热门书签</h2>
<ul>
  <li><a href="https://news.ycombinator.com">Hacker News</a> - Tech, startups, and programming discussions</li>
  <li><a href="https://luajit.org">LuaJIT Official Site</a> - Just-In-Time Compiler for Lua</li>
  <li><a href="https://luajit.org/ext_ffi.html">LuaJIT FFI Library</a> - Direct C calls and performance bindings</li>
  <li><a href="https://zh.wikipedia.org">中文维基百科</a> - 自由的百科全书</li>
  <li><a href="https://v2ex.com">V2EX</a> - 创意工作者社区</li>
  <li><a href="https://lite.duckduckgo.com/lite">DuckDuckGo Lite</a> - Clean, distraction-free search engine</li>
  <li><a href="https://github.com/trending">GitHub Trending</a> - Today's trending open-source repositories</li>
  <li><a href="about:help">Browser Help &amp; Vim Keybindings</a> - Complete command guide</li>
</ul>
<hr>
<h2>Essential Vim Navigation Keys</h2>
<table>
  <tr><th>Key</th><th>Action</th><th>Description</th></tr>
  <tr><td><b>j / k</b></td><td>Scroll 1 line</td><td>Move viewport down / up</td></tr>
  <tr><td><b>d / u</b></td><td>Half-page scroll</td><td>Standard Vim Ctrl-d / Ctrl-u</td></tr>
  <tr><td><b>gg / G</b></td><td>Top / Bottom</td><td>Jump directly to beginning or end of page</td></tr>
  <tr><td><b>f</b></td><td><b>Follow Link Hint</b></td><td>Overlays letters [A], [B] on links; press key to open!</td></tr>
  <tr><td><b>Tab / Enter</b></td><td>Link Focus</td><td>Cycle between links and press Enter to follow</td></tr>
  <tr><td><b>o / O</b></td><td><b>Open URL / Search</b></td><td>Open the Omnibox prompt to enter website or search query</td></tr>
  <tr><td><b>H / L</b></td><td>History Back / Fwd</td><td>Navigate back and forward in browsing history</td></tr>
  <tr><td><b>/</b></td><td>Search in Page</td><td>Search text (press 'n' for next, 'N' for previous)</td></tr>
  <tr><td><b>yy</b></td><td>Yank URL</td><td>Copy current website URL to system clipboard</td></tr>
  <tr><td><b>:</b></td><td>Command Mode</td><td>Type :open &lt;url&gt;, :reload, :help, or :q</td></tr>
  <tr><td><b>q</b></td><td>Quit</td><td>Exit web_lite</td></tr>
</table>
<hr>
<p><i>Tip: Press 'o' right now to enter any URL or search terms!</i></p>
</body>
</html>
]]
end

function M.get_help_page_html()
    return [[
<!DOCTYPE html>
<html>
<head><title>web_lite: Help & Keybindings</title></head>
<body>
<h1>web_lite Help Manual</h1>
<p><b>web_lite</b> is a minimalist, keyboard-centric web browser designed for terminal lovers.</p>
<hr>
<h2>1. Navigation & Scrolling (Vim Mode)</h2>
<ul>
  <li><b>j</b> or <b>↓</b>: Scroll down 1 line (can prefix with number, e.g. 5j)</li>
  <li><b>k</b> or <b>↑</b>: Scroll up 1 line</li>
  <li><b>d</b>: Scroll down half a page</li>
  <li><b>u</b>: Scroll up half a page</li>
  <li><b>Ctrl-f</b> or <b>Space</b> or <b>PageDown</b>: Scroll down full page</li>
  <li><b>Ctrl-b</b> or <b>PageUp</b>: Scroll up full page</li>
  <li><b>gg</b>: Jump to the very top of document</li>
  <li><b>G</b>: Jump to the very bottom of document</li>
  <li><b>gh</b>: <b>Go Home</b> (jump directly to about:home)</li>
</ul>
<h2>2. Links & Vimium Hint Mode</h2>
<ul>
  <li><b>f</b>: Activate <b>Vimium Hint Mode</b>. Visible links are assigned badges [A], [B], [C]... Type the letter to navigate!</li>
  <li><b>Tab</b> or <b>]</b>: Highlight and scroll to next hyperlink on page</li>
  <li><b>Shift-Tab</b> or <b>[</b>: Highlight and scroll to previous hyperlink on page</li>
  <li><b>Enter</b>: Open the currently highlighted link</li>
</ul>
<h2>3. URL Input & Omnibox</h2>
<ul>
  <li><b>o</b>: Open URL input bar. Type domain (e.g. news.ycombinator.com) or search query</li>
  <li><b>O</b>: Open URL input bar pre-filled with current address</li>
  <li><b>↑ / ↓</b>: Cycle through previously visited URL history</li>
  <li><b>Ctrl-U</b>: Clear the input line</li>
  <li><b>Ctrl-W</b>: Delete the previous word</li>
  <li><b>Esc</b>: Cancel input and return to Normal mode</li>
</ul>
<h2>4. Page Search</h2>
<ul>
  <li><b>/</b>: Prompt for search string. Matches are highlighted in yellow</li>
  <li><b>n</b>: Jump to next occurrence</li>
  <li><b>N</b>: Jump to previous occurrence</li>
  <li><b>Esc</b>: Clear search highlights</li>
</ul>
<h2>5. Browser Commands & History</h2>
<ul>
  <li><b>H</b>: Go Back in history</li>
  <li><b>L</b>: Go Forward in history</li>
  <li><b>r</b> or <b>R</b>: Reload current page</li>
  <li><b>yy</b>: Copy (yank) current page URL to clipboard</li>
  <li><b>:open &lt;url&gt;</b>: Navigate to URL</li>
  <li><b>:help</b>: Display this help page</li>
  <li><b>:q</b>: Quit web_lite</li>
</ul>
<p><a href="about:home">Back to Home Page</a></p>
</body>
</html>
]]
end

-- =========================================================================
-- 7. HTML Reflow & Layout Engine
-- =========================================================================
local function is_cjk_closing_punct(s)
    return s == "，" or s == "。" or s == "！" or s == "？" or s == "；" or s == "：" or s == "、" or s == "）" or s == "》" or s == "”" or s == "’" or s == "】" or s == "』" or s == "・"
end

local function word_wrap(text, max_width, first_prefix, rest_prefix)
    first_prefix = first_prefix or ""
    rest_prefix = rest_prefix or first_prefix

    -- Tokenize into words (English sequences) and individual CJK characters
    local tokens = {}
    local i = 1
    local n = #text
    local had_space = false

    while i <= n do
        local b = string.byte(text, i)
        if b <= 32 then
            had_space = true
            i = i + 1
        elseif b < 128 then
            local j = i
            while j <= n and string.byte(text, j) > 32 and string.byte(text, j) < 128 do
                j = j + 1
            end
            local tok_text = text:sub(i, j - 1)
            table.insert(tokens, { text = tok_text, width = j - i, is_cjk = false, pre_space = had_space })
            had_space = false
            i = j
        else
            local step = (b >= 240) and 4 or ((b >= 224) and 3 or 2)
            local ch = text:sub(i, i + step - 1)
            local w = (step >= 3) and 2 or 1
            if is_cjk_closing_punct(ch) and #tokens > 0 then
                tokens[#tokens].text = tokens[#tokens].text .. ch
                tokens[#tokens].width = tokens[#tokens].width + w
            else
                table.insert(tokens, { text = ch, width = w, is_cjk = true, pre_space = had_space })
            end
            had_space = false
            i = i + step
        end
    end

    if #tokens == 0 then return { first_prefix } end

    local lines = {}
    local cur_line = first_prefix .. tokens[1].text
    local cur_vlen = visual_len(first_prefix) + tokens[1].width
    local rest_vlen = visual_len(rest_prefix)
    local prev_is_cjk = tokens[1].is_cjk

    for idx = 2, #tokens do
        local tok = tokens[idx]
        local need_space = tok.pre_space or ((not prev_is_cjk) and (not tok.is_cjk))
        local sep = need_space and " " or ""
        local sep_w = need_space and 1 or 0

        if cur_vlen + sep_w + tok.width <= max_width then
            cur_line = cur_line .. sep .. tok.text
            cur_vlen = cur_vlen + sep_w + tok.width
        else
            table.insert(lines, cur_line)
            cur_line = rest_prefix .. tok.text
            cur_vlen = rest_vlen + tok.width
        end
        prev_is_cjk = tok.is_cjk
    end
    table.insert(lines, cur_line)
    return lines
end

local function format_html_table(table_html, max_width, links, base_url)
    local rows = {}
    for tr in table_html:gmatch("<[tT][rR][^>]*>(.-)</[tT][rR]>") do
        local row = {}
        for cell in tr:gmatch("<[tT][hHdD][^>]*>(.-)</[tT][hHdD]>") do
            if links then
                cell = cell:gsub("<[aA][^>]*href=[\"'](.-)[\"'][^>]*>(.-)</[aA]>", function(href, txt)
                    local clean_txt = decode_entities(txt:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
                    if #clean_txt == 0 then clean_txt = "link" end
                    local l_id = #links + 1
                    local full_href = base_url and resolve_relative_url(base_url, href) or href
                    table.insert(links, { id = l_id, href = full_href, text = clean_txt, line_idx = 0 })
                    return string.format("%s [%d]", clean_txt, l_id)
                end)
            end
            local clean_cell = decode_entities(cell:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
            table.insert(row, clean_cell)
        end
        if #row > 0 then
            table.insert(rows, row)
        end
    end

    if #rows == 0 then return {} end

    local num_cols = 0
    for _, r in ipairs(rows) do
        if #r > num_cols then num_cols = #r end
    end
    if num_cols == 0 then return {} end

    local col_widths = {}
    for c = 1, num_cols do col_widths[c] = 4 end

    for _, r in ipairs(rows) do
        for c = 1, num_cols do
            local val = r[c] or ""
            local vl = visual_len(val)
            if vl > col_widths[c] then
                col_widths[c] = vl
            end
        end
    end

    local total_w = 1
    for c = 1, num_cols do
        total_w = total_w + col_widths[c] + 3
    end

    if total_w > max_width then
        local scale = (max_width - 1 - (num_cols * 3)) / (total_w - 1 - (num_cols * 3))
        if scale < 0.3 then scale = 0.3 end
        for c = 1, num_cols do
            col_widths[c] = math.max(6, math.floor(col_widths[c] * scale))
        end
    end

    local out_lines = {}

    local top_parts = {}
    for c = 1, num_cols do
        table.insert(top_parts, string.rep("─", col_widths[c] + 2))
    end
    table.insert(out_lines, "┌" .. table.concat(top_parts, "┬") .. "┐")

    for r_idx, r in ipairs(rows) do
        local cell_parts = {}
        for c = 1, num_cols do
            local val = r[c] or ""
            local truncated_val = truncate(val, col_widths[c])
            local padded = pad_right(truncated_val, col_widths[c])
            table.insert(cell_parts, " " .. padded .. " ")
        end
        table.insert(out_lines, "│" .. table.concat(cell_parts, "│") .. "│")

        if r_idx == 1 and #rows > 1 then
            local sep_parts = {}
            for c = 1, num_cols do
                table.insert(sep_parts, string.rep("─", col_widths[c] + 2))
            end
            table.insert(out_lines, "├" .. table.concat(sep_parts, "┼") .. "┤")
        end
    end

    local bot_parts = {}
    for c = 1, num_cols do
        table.insert(bot_parts, string.rep("─", col_widths[c] + 2))
    end
    table.insert(out_lines, "└" .. table.concat(bot_parts, "┴") .. "┘")

    return out_lines
end

M.word_wrap         = word_wrap
M.format_html_table = format_html_table

function M.render_html_to_document(html_text, base_url, max_width)
    max_width = max_width or 80
    if max_width < 40 then max_width = 40 end

    local clean_html = strip_scripts_and_styles(html_text)

    local doc = {
        title = "Untitled",
        lines = {},
        links = {},
        url = base_url
    }

    local title_match = clean_html:match("<[tT][iI][tT][lL][eE][^>]*>(.-)</[tT][iI][tT][lL][eE]>")
    if title_match then
        doc.title = decode_entities(title_match:gsub("%s+", " "):match("^%s*(.-)%s*$") or "Untitled")
    end

    local body = clean_html:match("<[bB][oO][dD][yY][^>]*>(.-)</[bB][oO][dD][yY]>") or clean_html

    local current_lines = {}
    local links = {}
    local link_counter = 0

    local function add_line(str)
        table.insert(current_lines, str)
    end

    local function add_blank_line()
        if #current_lines > 0 and current_lines[#current_lines] ~= "" then
            table.insert(current_lines, "")
        end
    end

    local inline_buf = {}
    local cur_first_prefix = ""
    local cur_rest_prefix = ""

    local function flush_inline()
        if #inline_buf > 0 then
            local text = table.concat(inline_buf, " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
            if #text > 0 then
                for _, wl in ipairs(word_wrap(text, max_width, cur_first_prefix, cur_rest_prefix)) do
                    add_line(wl)
                end
            end
            inline_buf = {}
            cur_first_prefix = ""
            cur_rest_prefix = ""
        end
    end

    local table_blocks = {}
    local table_idx = 0
    -- Only treat standalone tables with <th> headers as boxed data tables
    body = body:gsub("(<[tT][aA][bB][lL][eE][^>]*>(.-)</[tT][aA][bB][lL][eE]>)", function(full_tbl, tbl_inner)
        local lower_inner = tbl_inner:lower()
        if lower_inner:find("<th") and not lower_inner:find("<table") then
            table_idx = table_idx + 1
            table_blocks[table_idx] = full_tbl
            return string.format("___TABLE_BLOCK_%d___", table_idx)
        end
        return full_tbl
    end)

    local pre_blocks = {}
    local pre_idx = 0
    body = body:gsub("(<[pP][rR][eE][^>]*>.-</[pP][rR][eE]>)", function(pre_content)
        pre_idx = pre_idx + 1
        pre_blocks[pre_idx] = pre_content
        return string.format("___PRE_BLOCK_%d___", pre_idx)
    end)

    local pos = 1
    local len = #body

    while pos <= len do
        local tag_start, tag_end, slash, tag_name = body:find("<%s*(/?)([%w:]+)[^>]*>", pos)
        if not tag_start then
            local chunk = body:sub(pos)
            local clean_text = decode_entities(chunk:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
            if #clean_text > 0 then
                table.insert(inline_buf, clean_text)
            end
            break
        end

        if tag_start > pos then
            local text_chunk = body:sub(pos, tag_start - 1)
            local tbl_id = text_chunk:match("___TABLE_BLOCK_(%d+)___")
            if tbl_id then
                flush_inline()
                local tbl_content = table_blocks[tonumber(tbl_id)]
                if tbl_content then
                    add_blank_line()
                    local t_lines = format_html_table(tbl_content, max_width, links, base_url)
                    for _, tl in ipairs(t_lines) do add_line(tl) end
                    add_blank_line()
                end
            end
            local p_id = text_chunk:match("___PRE_BLOCK_(%d+)___")
            if p_id then
                flush_inline()
                local p_content = pre_blocks[tonumber(p_id)]
                if p_content then
                    local raw_code = p_content:match("<[pP][rR][eE][^>]*>(.-)</[pP][rR][eE]>") or ""
                    raw_code = decode_entities(raw_code:gsub("<[^>]+>", ""))
                    add_blank_line()
                    add_line("┌─ Code ───────────────────────────────────────────")
                    for cl in raw_code:gmatch("([^\r\n]+)") do
                        add_line("│ " .. truncate(cl, max_width - 4))
                    end
                    add_line("└──────────────────────────────────────────────────")
                    add_blank_line()
                end
            end

            local clean_chunk = decode_entities(text_chunk:gsub("___[A-Z0-9_]+___", ""):gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
            if #clean_chunk > 0 then
                table.insert(inline_buf, clean_chunk)
            end
        end

        local lower_tag = tag_name:lower()
        local full_tag = body:sub(tag_start, tag_end)
        local is_closing = (slash == "/")

        if is_closing then
            if lower_tag == "p" or lower_tag == "div" or lower_tag == "li" or lower_tag == "ul" or lower_tag == "ol" or lower_tag == "table" or lower_tag == "blockquote" or lower_tag:match("^h[1-6]$") or lower_tag == "pre" or lower_tag == "section" or lower_tag == "article" or lower_tag == "tr" then
                flush_inline()
                if lower_tag == "p" or lower_tag == "div" or lower_tag == "ul" or lower_tag == "ol" or lower_tag == "table" or lower_tag == "blockquote" then
                    add_blank_line()
                end
            elseif lower_tag == "td" or lower_tag == "th" then
                table.insert(inline_buf, " ")
            end
            pos = tag_end + 1
        elseif lower_tag:match("^h[1-3]$") then
            flush_inline()
            local close_pat = "</%s*" .. tag_name .. "%s*>"
            local close_start, close_end = body:find(close_pat, tag_end + 1)
            local heading_text = ""
            if close_start then
                heading_text = body:sub(tag_end + 1, close_start - 1)
                pos = close_end + 1
            else
                pos = tag_end + 1
            end
            heading_text = decode_entities(heading_text:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
            if #heading_text > 0 then
                add_blank_line()
                add_line(heading_text)
                if lower_tag == "h1" then
                    add_line(string.rep("═", math.min(visual_len(heading_text), max_width)))
                else
                    add_line(string.rep("─", math.min(visual_len(heading_text), max_width)))
                end
                add_blank_line()
            end
        elseif lower_tag == "hr" then
            flush_inline()
            add_blank_line()
            add_line(string.rep("─", max_width))
            add_blank_line()
            pos = tag_end + 1
        elseif lower_tag == "tr" then
            flush_inline()
            pos = tag_end + 1
        elseif lower_tag == "td" or lower_tag == "th" then
            table.insert(inline_buf, " ")
            pos = tag_end + 1
        elseif lower_tag == "a" then
            local href = full_tag:match("[hH][rR][eE][fF]=[\"'](.-)[\"']") or full_tag:match("[hH][rR][eE][fF]=([^%s>]+)")
            local close_start, close_end = body:find("</%s*[aA]%s*>", tag_end + 1)
            local a_inner = ""
            if close_start then
                a_inner = body:sub(tag_end + 1, close_start - 1)
                pos = close_end + 1
            else
                pos = tag_end + 1
            end
            local link_text = decode_entities(a_inner:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
            if #link_text == 0 then
                if full_tag:find("vote") or a_inner:find("vote") or a_inner:find("votearrow") then
                    link_text = "▲"
                else
                    link_text = href or "link"
                end
            end

            if href and not href:match("^javascript:") then
                link_counter = link_counter + 1
                local full_href = resolve_relative_url(base_url, href)
                local display_link = string.format("%s [%d]", link_text, link_counter)
                table.insert(inline_buf, display_link)
                table.insert(links, {
                    id = link_counter,
                    href = full_href,
                    text = link_text,
                    line_idx = 0
                })
            end
        elseif lower_tag == "li" then
            flush_inline()
            local close_start, close_end = body:find("</%s*[lL][iI]%s*>", tag_end + 1)
            local li_text = ""
            if close_start then
                li_text = body:sub(tag_end + 1, close_start - 1)
                pos = close_end + 1
            else
                pos = tag_end + 1
            end
            li_text = li_text:gsub("<[aA][^>]*href=[\"'](.-)[\"'][^>]*>(.-)</[aA]>", function(a_href, a_txt)
                link_counter = link_counter + 1
                local full_href = resolve_relative_url(base_url, a_href)
                local clean_txt = decode_entities(a_txt:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
                table.insert(links, {
                    id = link_counter,
                    href = full_href,
                    text = clean_txt,
                    line_idx = 0
                })
                return string.format("%s [%d]", clean_txt, link_counter)
            end)
            li_text = decode_entities(li_text:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
            if #li_text > 0 then
                local wrapped = word_wrap(li_text, max_width, "  • ", "    ")
                for _, wl in ipairs(wrapped) do
                    add_line(wl)
                end
            end
        elseif lower_tag == "blockquote" then
            flush_inline()
            local close_start, close_end = body:find("</%s*[bB][lL][oO][cC][kK][qQ][uU][oO][tT][eE]%s*>", tag_end + 1)
            local bq_text = ""
            if close_start then
                bq_text = body:sub(tag_end + 1, close_start - 1)
                pos = close_end + 1
            else
                pos = tag_end + 1
            end
            bq_text = decode_entities(bq_text:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
            if #bq_text > 0 then
                add_blank_line()
                for _, wl in ipairs(word_wrap(bq_text, max_width, "  │ ", "  │ ")) do
                    add_line(wl)
                end
                add_blank_line()
            end
        elseif lower_tag == "p" or lower_tag == "div" or lower_tag == "br" then
            flush_inline()
            if lower_tag == "p" or lower_tag == "div" then add_blank_line() end
            pos = tag_end + 1
        else
            pos = tag_end + 1
        end
    end

    flush_inline()

    while #current_lines > 0 and current_lines[#current_lines] == "" do
        table.remove(current_lines)
    end

    if #current_lines == 0 then
        table.insert(current_lines, "(Empty page or non-HTML content)")
    end

    -- Accurately associate line_idx for all links by scanning rendered lines
    for l_idx, line in ipairs(current_lines) do
        for link_id in line:gmatch("%[(%d+)%]") do
            local lid = tonumber(link_id)
            if lid and links[lid] then
                links[lid].line_idx = l_idx
            end
        end
    end

    doc.lines = current_lines
    doc.links = links
    return doc
end

-- =========================================================================
-- 8. Terminal Browser UI & State Machine
-- =========================================================================
local Browser = {}
Browser.__index = Browser

function Browser.new(initial_url)
    local self = setmetatable({}, Browser)
    self.url = initial_url or "about:home"
    self.history = { self.url }
    self.history_idx = 1
    self.doc = nil
    self.scroll_y = 1
    self.selected_link_idx = 1
    self.mode = "NORMAL"
    self.input_buf = ""
    self.input_cursor = 1
    self.input_prompt = ":open "
    self.search_query = ""
    self.search_matches = {}
    self.search_match_idx = 1
    self.pending_key = nil
    self.count_prefix = 0
    self.hint_map = {}
    self.status_msg = "Ready. Press '?' or 'h' for help."
    self.running = true
    return self
end

function Browser:load_url(target_url)
    self.status_msg = "Fetching " .. target_url .. "..."
    local term_w, _ = get_terminal_size()
    local html, status_code, content_type = fetch_url(target_url)

    self.doc = M.render_html_to_document(html, target_url, term_w - 4)
    self.url = target_url
    self.scroll_y = 1
    self.selected_link_idx = 1
    self.search_matches = {}
    self.status_msg = string.format("Loaded (%d lines, %d links)", #self.doc.lines, #self.doc.links)
end

function Browser:navigate_to(new_url)
    local resolved, mode = smart_resolve_input(new_url)
    if self.history[self.history_idx] ~= resolved then
        while #self.history > self.history_idx do
            table.remove(self.history)
        end
        table.insert(self.history, resolved)
        self.history_idx = #self.history
    end
    self:load_url(resolved)
end

function Browser:history_back()
    if self.history_idx > 1 then
        self.history_idx = self.history_idx - 1
        self:load_url(self.history[self.history_idx])
    else
        self.status_msg = "Already at oldest history entry."
    end
end

function Browser:history_forward()
    if self.history_idx < #self.history then
        self.history_idx = self.history_idx + 1
        self:load_url(self.history[self.history_idx])
    else
        self.status_msg = "Already at newest history entry."
    end
end

function Browser:reload()
    self:load_url(self.url)
    self.status_msg = "Page reloaded."
end

function Browser:yank_url()
    local text = self.url
    if is_windows then
        local p = io.popen("clip", "w")
        if p then
            p:write(text)
            p:close()
        end
    else
        local p = io.popen("xclip -selection clipboard 2>/dev/null || pbcopy 2>/dev/null", "w")
        if p then
            p:write(text)
            p:close()
        end
    end
    self.status_msg = "Yanked URL to clipboard: " .. truncate(text, 40)
end

function Browser:build_hints(view_height)
    self.hint_map = {}
    if not self.doc or #self.doc.links == 0 then return end

    local visible_links = {}
    for idx, l in ipairs(self.doc.links) do
        if l.line_idx >= self.scroll_y and l.line_idx < self.scroll_y + view_height then
            table.insert(visible_links, { idx = idx, link = l })
        end
    end

    if #visible_links == 0 then
        for idx = 1, math.min(#self.doc.links, 25) do
            table.insert(visible_links, { idx = idx, link = self.doc.links[idx] })
        end
    end

    local letters = "ASDFJKLGHWERUIOMNCVXZ"
    for i, vl in ipairs(visible_links) do
        local key
        if i <= #letters then
            key = letters:sub(i, i)
        else
            local i1 = math.floor((i - 1) / #letters)
            local i2 = ((i - 1) % #letters) + 1
            key = letters:sub(i1, i1) .. letters:sub(i2, i2)
        end
        self.hint_map[key] = vl.idx
        self.hint_map[key:lower()] = vl.idx
    end
end

-- =========================================================================
-- 9. Screen Buffer & Viewport Renderer
-- =========================================================================
function Browser:render()
    local term_w, term_h = get_terminal_size()
    local view_h = term_h - 4
    if view_h < 5 then view_h = 5 end

    local buf = {}
    local function emit(str) table.insert(buf, str) end

    emit("\27[H")

    local is_https = self.url:match("^https://")
    local security_badge = is_https and "\27[32m[🔒 HTTPS]\27[0m" or "\27[33m[🌐 HTTP]\27[0m"
    if self.url:match("^about:") then security_badge = "\27[36m[⚙ LOCAL]\27[0m" end

    local nav_icons = string.format("\27[1;36m[◄ %d/%d ►]\27[0m \27[1;32m[⟳]\27[0m", self.history_idx, #self.history)
    local title_disp = truncate(self.doc and self.doc.title or "web_lite", 25)
    local url_disp = truncate(self.url, term_w - 45)

    local header_text = string.format(" %s  \27[1;37m%s\27[0m \27[90m─\27[0m \27[34;4m%s\27[0m", nav_icons, title_disp, url_disp)
    local header_vlen = visual_len(header_text)
    local padding = math.max(0, term_w - header_vlen - visual_len(security_badge) - 1)
    emit(header_text .. string.rep(" ", padding) .. security_badge .. "\n")
    emit("\27[90m" .. string.rep("─", term_w) .. "\27[0m\n")

    local total_lines = (self.doc and #self.doc.lines) or 0
    if self.mode == "HINT" then
        self:build_hints(view_h)
    end

    for row = 1, view_h do
        local line_idx = self.scroll_y + row - 1
        if line_idx <= total_lines then
            local raw_line = self.doc.lines[line_idx] or ""
            local display_line = raw_line

            if #self.search_query > 0 then
                local query = self.search_query
                display_line = display_line:gsub("(" .. query:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") .. ")", "\27[7;33m%1\27[0m")
            end

            if self.mode == "HINT" then
                for hint_key, link_idx in pairs(self.hint_map) do
                    if #hint_key == 1 then
                        local l = self.doc.links[link_idx]
                        if l and l.line_idx == line_idx then
                            display_line = display_line:gsub("%[" .. l.id .. "%]", string.format("\27[1;30;43m[%s]\27[0m", hint_key))
                        end
                    end
                end
            else
                display_line = display_line:gsub("%[(%d+)%]", function(id_str)
                    local id = tonumber(id_str)
                    if id and id == self.selected_link_idx then
                        return string.format("\27[7;1;33m[▶ %d ◀]\27[0m", id)
                    else
                        return string.format("\27[1;36m[%d]\27[0m", id)
                    end
                end)
            end

            local clean_len = visual_len(display_line)
            if clean_len < term_w then
                emit("  " .. display_line .. string.rep(" ", term_w - clean_len - 2) .. "\n")
            else
                emit("  " .. truncate(display_line, term_w - 2) .. "\n")
            end
        else
            emit("\27[90m~" .. string.rep(" ", term_w - 1) .. "\27[0m\n")
        end
    end

    emit("\27[90m" .. string.rep("─", term_w) .. "\27[0m\n")

    local pct = total_lines > 0 and math.floor((self.scroll_y / math.max(1, total_lines - view_h + 1)) * 100) or 0
    if pct > 100 then pct = 100 end
    local pos_info = string.format("Line %d/%d (%d%%)", self.scroll_y, total_lines, pct)

    if self.mode == "COMMAND" or self.mode == "INPUT" then
        local prompt_disp = self.input_prompt .. self.input_buf
        local badge = ""
        if self.input_buf:match("^https?://") or self.input_buf:match("%.[%w]+") then
            badge = " \27[32m[🌐 Direct URL]\27[0m"
        elseif #self.input_buf > 0 then
            badge = " \27[33m[🔍 DuckDuckGo]\27[0m"
        end

        local prompt_vlen = visual_len(prompt_disp) + visual_len(badge)
        local pad = math.max(0, term_w - prompt_vlen - 1)
        emit("\27[1;37m" .. prompt_disp .. "\27[7m \27[0m" .. badge .. string.rep(" ", pad))
    elseif self.mode == "SEARCH" then
        local prompt_disp = "/" .. self.input_buf
        local pad = math.max(0, term_w - visual_len(prompt_disp) - 1)
        emit("\27[1;33m" .. prompt_disp .. "\27[7m \27[0m" .. string.rep(" ", pad))
    elseif self.mode == "HINT" then
        local hint_prompt = "-- HINT MODE -- Type letter [A-Z] to follow link, or <Esc> to cancel."
        local pad = math.max(0, term_w - visual_len(hint_prompt) - 1)
        emit("\27[1;30;43m " .. hint_prompt .. " \27[0m" .. string.rep(" ", pad))
    else
        local mode_tag = "\27[1;30;46m NORMAL \27[0m"
        local shortcuts = "\27[90m[j/k] Move [Tab/]] Link [gh] Home [f] Hint [o] Open [H/L] Hist [/] Find [:] Cmd\27[0m"
        local status_left = string.format("%s  \27[1;37m%s\27[0m", mode_tag, truncate(self.status_msg, 40))
        local right_info = string.format("%s  %s", shortcuts, pos_info)
        local pad = math.max(1, term_w - visual_len(status_left) - visual_len(right_info) - 1)
        emit(status_left .. string.rep(" ", pad) .. right_info)
    end

    io.write(table.concat(buf))
    io.flush()
end

-- =========================================================================
-- 10. Key Handling & Vim Controller
-- =========================================================================
function Browser:handle_key(k)
    if not k then return end

    local term_w, term_h = get_terminal_size()
    local view_h = term_h - 4
    if view_h < 5 then view_h = 5 end
    local total_lines = (self.doc and #self.doc.lines) or 0
    local max_scroll = math.max(1, total_lines - view_h + 1)

    -- A. COMMAND / INPUT / OMNIBOX MODE
    if self.mode == "COMMAND" or self.mode == "INPUT" then
        if k == "ESC" then
            self.mode = "NORMAL"
            self.status_msg = "Cancelled."
        elseif k == "ENTER" then
            local cmd = self.input_buf:match("^%s*(.-)%s*$")
            self.mode = "NORMAL"
            if cmd == "q" or cmd == "quit" then
                self.running = false
            elseif cmd == "home" then
                self:navigate_to("about:home")
            elseif cmd == "help" or cmd == "h" then
                self:navigate_to("about:help")
            elseif cmd == "r" or cmd == "reload" then
                self:reload()
            elseif cmd:match("^open%s+(.+)") or cmd:match("^o%s+(.+)") then
                local url_target = cmd:match("^open%s+(.+)") or cmd:match("^o%s+(.+)")
                self:navigate_to(url_target)
            elseif #cmd > 0 then
                self:navigate_to(cmd)
            end
        elseif k == "BACKSPACE" then
            self.input_buf = utf8_pop_char(self.input_buf)
        elseif k == "CTRL_U" then
            self.input_buf = ""
        elseif k == "CTRL_W" then
            self.input_buf = self.input_buf:gsub("%s*%S+$", "")
        elseif k == "SPACE" then
            self.input_buf = self.input_buf .. " "
        elseif #k >= 1 and not k:match("^CTRL_") and not (k:match("^[A-Z_]+$") and #k > 1) then
            self.input_buf = self.input_buf .. k
        end
        return
    end

    -- B. SEARCH MODE (/)
    if self.mode == "SEARCH" then
        if k == "ESC" then
            self.mode = "NORMAL"
            self.status_msg = "Search cancelled."
        elseif k == "ENTER" then
            self.mode = "NORMAL"
            self.search_query = self.input_buf
            self.search_matches = {}
            if #self.search_query > 0 and self.doc then
                local pat = self.search_query:lower()
                for l_idx, line in ipairs(self.doc.lines) do
                    if line:lower():find(pat, 1, true) then
                        table.insert(self.search_matches, l_idx)
                    end
                end
            end
            if #self.search_matches > 0 then
                self.search_match_idx = 1
                self.scroll_y = math.min(max_scroll, self.search_matches[1])
                self.status_msg = string.format("Match 1/%d for '%s'", #self.search_matches, self.search_query)
            else
                self.status_msg = string.format("Pattern not found: '%s'", self.search_query)
            end
        elseif k == "BACKSPACE" then
            self.input_buf = utf8_pop_char(self.input_buf)
        elseif k == "SPACE" then
            self.input_buf = self.input_buf .. " "
        elseif #k >= 1 and not k:match("^CTRL_") and not (k:match("^[A-Z_]+$") and #k > 1) then
            self.input_buf = self.input_buf .. k
        end
        return
    end

    -- C. VIMIUM HINT MODE (f)
    if self.mode == "HINT" then
        if k == "ESC" then
            self.mode = "NORMAL"
            self.status_msg = "Hint mode cancelled."
            return
        end

        local upper_k = k:upper()
        local matched_link_idx = self.hint_map[upper_k] or self.hint_map[k]
        if matched_link_idx and self.doc and self.doc.links[matched_link_idx] then
            local target = self.doc.links[matched_link_idx].href
            self.mode = "NORMAL"
            self:navigate_to(target)
        else
            self.mode = "NORMAL"
            self.status_msg = "Invalid hint key."
        end
        return
    end

    -- D. NORMAL MODE (Vim Navigation)
    if k:match("^[1-9]$") and not self.pending_key then
        self.count_prefix = self.count_prefix * 10 + tonumber(k)
        return
    elseif k == "0" and self.count_prefix > 0 and not self.pending_key then
        self.count_prefix = self.count_prefix * 10
        return
    end

    local count = (self.count_prefix > 0) and self.count_prefix or 1
    self.count_prefix = 0

    if self.pending_key == "g" then
        self.pending_key = nil
        if k == "g" then
            self.scroll_y = 1
            self.status_msg = "Jumped to top."
            return
        elseif k == "h" then
            self:navigate_to("about:home")
            self.status_msg = "Navigated to Home."
            return
        end
    end

    if k == "j" or k == "DOWN" then
        self.scroll_y = math.min(max_scroll, self.scroll_y + count)
    elseif k == "k" or k == "UP" then
        self.scroll_y = math.max(1, self.scroll_y - count)
    elseif k == "d" or k == "CTRL_D" then
        self.scroll_y = math.min(max_scroll, self.scroll_y + math.floor(view_h / 2))
    elseif k == "u" or k == "CTRL_U" then
        self.scroll_y = math.max(1, self.scroll_y - math.floor(view_h / 2))
    elseif k == "CTRL_F" or k == "PAGE_DOWN" or k == "SPACE" then
        self.scroll_y = math.min(max_scroll, self.scroll_y + view_h - 1)
    elseif k == "CTRL_B" or k == "PAGE_UP" then
        self.scroll_y = math.max(1, self.scroll_y - view_h + 1)
    elseif k == "g" then
        self.pending_key = "g"
    elseif k == "G" then
        self.scroll_y = max_scroll
        self.status_msg = "Jumped to bottom."
    elseif k == "H" then
        self:history_back()
    elseif k == "L" then
        self:history_forward()
    elseif k == "r" or k == "R" then
        self:reload()
    elseif k == "y" then
        if self.pending_key == "y" then
            self.pending_key = nil
            self:yank_url()
        else
            self.pending_key = "y"
        end
    elseif k == "f" then
        if self.doc and #self.doc.links > 0 then
            self.mode = "HINT"
            self.status_msg = "Hint mode: Press letter to open link."
        else
            self.status_msg = "No links on current page."
        end
    elseif k == "TAB" or k == "]" then
        if self.doc and #self.doc.links > 0 then
            local cur = self.doc.links[self.selected_link_idx]
            if not cur or cur.line_idx < self.scroll_y or cur.line_idx >= self.scroll_y + view_h then
                local found = false
                for idx, l in ipairs(self.doc.links) do
                    if l.line_idx >= self.scroll_y and l.line_idx < self.scroll_y + view_h then
                        self.selected_link_idx = idx
                        found = true
                        break
                    end
                end
                if not found then
                    self.selected_link_idx = (self.selected_link_idx % #self.doc.links) + 1
                end
            else
                self.selected_link_idx = (self.selected_link_idx % #self.doc.links) + 1
            end

            local l = self.doc.links[self.selected_link_idx]
            if l and l.line_idx > 0 then
                if l.line_idx < self.scroll_y or l.line_idx >= self.scroll_y + view_h then
                    self.scroll_y = math.max(1, l.line_idx - math.floor(view_h / 3))
                end
            end
            self.status_msg = string.format("Focused link [%d]: %s", l.id, truncate(l.href, 50))
        end
    elseif k == "SHIFT_TAB" or k == "[" then
        if self.doc and #self.doc.links > 0 then
            local cur = self.doc.links[self.selected_link_idx]
            if not cur or cur.line_idx < self.scroll_y or cur.line_idx >= self.scroll_y + view_h then
                local found = false
                for idx = #self.doc.links, 1, -1 do
                    local l = self.doc.links[idx]
                    if l.line_idx >= self.scroll_y and l.line_idx < self.scroll_y + view_h then
                        self.selected_link_idx = idx
                        found = true
                        break
                    end
                end
                if not found then
                    self.selected_link_idx = self.selected_link_idx - 1
                    if self.selected_link_idx < 1 then self.selected_link_idx = #self.doc.links end
                end
            else
                self.selected_link_idx = self.selected_link_idx - 1
                if self.selected_link_idx < 1 then self.selected_link_idx = #self.doc.links end
            end

            local l = self.doc.links[self.selected_link_idx]
            if l and l.line_idx > 0 then
                if l.line_idx < self.scroll_y or l.line_idx >= self.scroll_y + view_h then
                    self.scroll_y = math.max(1, l.line_idx - math.floor(view_h / 3))
                end
            end
            self.status_msg = string.format("Focused link [%d]: %s", l.id, truncate(l.href, 50))
        end
    elseif k == "ENTER" then
        if self.doc and #self.doc.links >= self.selected_link_idx then
            local l = self.doc.links[self.selected_link_idx]
            if l and l.href then
                self:navigate_to(l.href)
            end
        end
    elseif k == "o" then
        self.mode = "INPUT"
        self.input_prompt = ":open "
        self.input_buf = ""
    elseif k == "O" then
        self.mode = "INPUT"
        self.input_prompt = ":open "
        self.input_buf = self.url
    elseif k == ":" then
        self.mode = "COMMAND"
        self.input_prompt = ":"
        self.input_buf = ""
    elseif k == "/" then
        self.mode = "SEARCH"
        self.input_buf = ""
    elseif k == "n" then
        if #self.search_matches > 0 then
            self.search_match_idx = (self.search_match_idx % #self.search_matches) + 1
            local target_line = self.search_matches[self.search_match_idx]
            self.scroll_y = math.min(max_scroll, target_line)
            self.status_msg = string.format("Match %d/%d for '%s'", self.search_match_idx, #self.search_matches, self.search_query)
        end
    elseif k == "N" then
        if #self.search_matches > 0 then
            self.search_match_idx = self.search_match_idx - 1
            if self.search_match_idx < 1 then self.search_match_idx = #self.search_matches end
            local target_line = self.search_matches[self.search_match_idx]
            self.scroll_y = math.min(max_scroll, target_line)
            self.status_msg = string.format("Match %d/%d for '%s'", self.search_match_idx, #self.search_matches, self.search_query)
        end
    elseif k == "ESC" then
        self.search_query = ""
        self.search_matches = {}
        self.pending_key = nil
        self.status_msg = "Cleared search."
    elseif k == "q" then
        self.running = false
    elseif k == "?" or k == "h" then
        self:navigate_to("about:help")
    end
end

function Browser:run()
    if not enable_raw_mode() then
        io.stderr:write("Error: Failed to enable terminal raw mode.\n")
        return 1
    end

    self:load_url(self.url)

    while self.running do
        self:render()
        local k = read_key(50)
        if k then
            self:handle_key(k)
        end
    end

    disable_raw_mode()
    return 0
end

M.Browser = Browser

-- =========================================================================
-- 11. Headless Dump Mode & CLI Entry Point
-- =========================================================================
local function dump_page(url, max_width)
    max_width = max_width or 80
    local resolved, _ = smart_resolve_input(url)
    local html, code = fetch_url(resolved)
    local doc = M.render_html_to_document(html, resolved, max_width)

    print(string.format("=== %s (%s) ===\n", doc.title, resolved))
    for _, l in ipairs(doc.lines) do
        print(l)
    end
    if #doc.links > 0 then
        print("\n=== Hyperlinks ===")
        for _, l in ipairs(doc.links) do
            print(string.format("  [%d] %s", l.id, l.href))
        end
    end
end

M.dump_page = dump_page

local function main(args)
    args = args or {}
    local dump_target = nil
    local target_url = "about:home"

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--dump" or a == "-d" then
            i = i + 1
            dump_target = args[i] or "about:home"
        elseif a == "--help" then
            print("web_lite: Modern Vim-Driven Terminal Web Browser for LuaJIT FFI")
            print("Usage:")
            print("  luajit web_lite.lua [URL or Search Query]")
            print("  luajit web_lite.lua --dump <URL>    (print rendered text to stdout)")
            print("  luajit web_lite.lua --test          (run unit test suite)")
            return 0
        elseif not a:match("^%-") then
            target_url = a
        end
        i = i + 1
    end

    if dump_target then
        local cols, _ = get_terminal_size()
        dump_page(dump_target, cols or 80)
        return 0
    end

    local browser = Browser.new(target_url)
    return browser:run()
end

M.main = main

local is_entry_point = false
if arg and arg[0] then
    local script_name = arg[0]:match("([^/\\]+)$")
    if script_name and (script_name == "web_lite.lua" or script_name == "web_lite") then
        is_entry_point = true
    end
end

if is_entry_point then
    local code = main(arg)
    os.exit(code or 0)
end

return M
