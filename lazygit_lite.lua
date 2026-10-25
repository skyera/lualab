#!/usr/bin/env luajit
--[[
    lazygit_lite.lua
    A fast, beautiful, and practical Git TUI written in pure LuaJIT with FFI.
    Inspired by lazygit.

    Features:
    - POSIX ioctl(TIOCGWINSZ) for terminal window size detection.
    - POSIX termios raw mode + poll() for instant non-blocking keystrokes.
    - Multi-pane layout:
      [1] Status / Changed Files (staged & unstaged)
      [2] Git Branches (local & remote)
      [3] Git Commits (recent history log)
      [4] Diff / Commit Inspector viewer (syntax colored diff)
    - Keybindings:
      - Tab / 1, 2, 3 : Switch active pane
      - ↑ / ↓ or k / j: Navigate items in active pane
      - Space         : Stage / unstage selected file (git add / git reset)
      - a             : Stage all / unstage all
      - c             : Quick commit prompt
      - d             : Discard changes in working directory (with confirmation)
      - r             : Refresh git status
      - q / ESC       : Quit
]]

io.stderr:write("lazygit-lite: loading terminal support...\n")
io.stderr:flush()
local ffi = require("ffi")
local bit = require("bit")
local script_dir = (arg[0] or ""):match("^(.*[/\\])") or "./"
local process = dofile(script_dir .. "lazygit_process.lua")

-- =========================================================================
-- 1. FFI C Definitions for Terminal, Polling, and Window
-- =========================================================================
local is_windows = (ffi.os == "Windows")

local enable_raw_mode, disable_raw_mode, get_terminal_size, read_key
local in_raw_mode = false
local interrupted = false

local function normalize_key(ch)
    local tokens = {
        [" "] = "SPACE", ["\t"] = "TAB", ["\r"] = "ENTER", ["\n"] = "ENTER",
        ["\27"] = "ESC", ["\8"] = "BACKSPACE", ["\127"] = "BACKSPACE",
    }
    return tokens[ch] or ch
end

local function decode_key(pending, final)
    local sequences = {
        ["\27[A"] = "UP", ["\27[B"] = "DOWN", ["\27[C"] = "RIGHT", ["\27[D"] = "LEFT",
        ["\27[5~"] = "PAGE_UP", ["\27[6~"] = "PAGE_DOWN",
    }
    for sequence, token in pairs(sequences) do
        if pending:sub(1, #sequence) == sequence then
            return token, pending:sub(#sequence + 1)
        end
        if not final and sequence:sub(1, #pending) == pending then
            return nil, pending
        end
    end
    local first = pending:byte(1)
    local length = first and (first >= 240 and 4 or first >= 224 and 3 or first >= 192 and 2 or 1) or 0
    if length > 1 then
        if #pending < length and not final then
            return nil, pending
        end
        return pending:sub(1, length), pending:sub(length + 1)
    end
    return normalize_key(pending:sub(1, 1)), pending:sub(2)
end

if is_windows then
    local kernel32 = ffi.load("kernel32")
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
        int SetConsoleOutputCP(uint32_t wCodePageID);
        uint32_t GetConsoleOutputCP(void);
        void Sleep(uint32_t dwMilliseconds);
        int _kbhit(void);
        uint16_t _getwch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5
    local orig_in_mode = ffi.new("uint32_t[1]")
    local orig_out_mode = ffi.new("uint32_t[1]")
    local orig_code_page

    local function utf8_character(code)
        if code < 0x80 then
            return string.char(code)
        elseif code < 0x800 then
            return string.char(0xc0 + math.floor(code / 64), 0x80 + code % 64)
        elseif code < 0x10000 then
            return string.char(0xe0 + math.floor(code / 4096),
                0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
        end
        return string.char(0xf0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
            0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end

    enable_raw_mode = function()
        local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        if kernel32.GetConsoleMode(hIn, orig_in_mode) == 0 then
            return false
        end
        assert(kernel32.GetConsoleMode(hOut, orig_out_mode) ~= 0, "Cannot read console output mode")

        orig_code_page = kernel32.GetConsoleOutputCP()
        in_raw_mode = true -- protected cleanup also covers partial initialization.
        assert(kernel32.SetConsoleOutputCP(65001) ~= 0, "Cannot enable UTF-8 console output")
        local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        assert(kernel32.SetConsoleMode(hOut, bit.bor(orig_out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING)) ~= 0,
            "Cannot enable terminal escape sequences")

        local raw_mode = bit.band(orig_in_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
        assert(kernel32.SetConsoleMode(hIn, raw_mode) ~= 0, "Cannot enable raw console input")

        in_raw_mode = true
        io.write("\27[?1049h\27[?25l\27[?7l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
            io.flush()
            local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
            local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
            local input_ok = kernel32.SetConsoleMode(hIn, orig_in_mode[0])
            local output_ok = kernel32.SetConsoleMode(hOut, orig_out_mode[0])
            local page_ok = kernel32.SetConsoleOutputCP(orig_code_page)
            if input_ok == 0 or output_ok == 0 or page_ok == 0 then
                io.stderr:write("Failed to restore console settings. Reopen the terminal if needed.\n")
            end
            in_raw_mode = false
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
        return 100, 30
    end

    read_key = function(timeout_ms)
        local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        if kernel32.GetConsoleMode(hIn, mode) == 0 then
            local ch = io.read(1)
            if not ch then
                return "q"
            end
            return normalize_key(ch)
        end

        timeout_ms = timeout_ms or 50
        local elapsed = 0
        while elapsed < timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                local c0 = ffi.C._getwch()
                if c0 == 3 then
                    return "q"
                end
                if c0 == 0 or c0 == 224 then
                    local c1 = ffi.C._getwch()
                    if c1 == 72 then return "UP"
                    elseif c1 == 80 then return "DOWN"
                    elseif c1 == 75 then return "LEFT"
                    elseif c1 == 77 then return "RIGHT"
                    elseif c1 == 73 then return "PAGE_UP"
                    elseif c1 == 81 then return "PAGE_DOWN"
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
                else
                    if c0 >= 0xd800 and c0 <= 0xdbff then
                        local low = ffi.C._getwch()
                        if low < 0xdc00 or low > 0xdfff then
                            return "\239\191\189"
                        end
                        c0 = 0x10000 + (c0 - 0xd800) * 1024 + low - 0xdc00
                    elseif c0 >= 0xdc00 and c0 <= 0xdfff then
                        return "\239\191\189"
                    end
                    return utf8_character(c0)
                end
            end
            kernel32.Sleep(10)
            elapsed = elapsed + 10
        end
        return nil
    end
else
    -- macOS/BSD declare tcflag_t/speed_t as 64-bit and set NCCS to 20, while Linux
    -- uses 32-bit and NCCS=32.  Picking the wrong layout shifts every field offset
    -- and makes tcgetattr overrun the LuaJIT buffer, so select it at cdef time.
    -- On Linux the definition below passes through byte-for-byte unchanged.
    local function posix_termios_cdef(def)
        if ffi.os == "OSX" or ffi.os == "BSD" then
            def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
            def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
            def = def:gsub("c_cc%[32%]", "c_cc[20]")
        end
        return def
    end

    ffi.cdef(posix_termios_cdef[[
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
            typedef void (*lg_signal_handler)(int);
            lg_signal_handler signal(int, lg_signal_handler);
    ]])

    local TIOCGWINSZ   = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413
    local STDIN_FILENO = 0
    local TCSANOW      = 0
    local ICANON       = 2
    local ECHO         = 8
    local POLLIN       = 1

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")
    local signal_handler = ffi.cast("lg_signal_handler", function()
        interrupted = true
    end)
    local original_signals = {}

    enable_raw_mode = function()
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then
            return false
        end
        assert(ffi.C.tcgetattr(STDIN_FILENO, orig_termios) == 0, "Cannot read terminal attributes")
        ffi.copy(raw_termios, orig_termios, ffi.sizeof(raw_termios))
        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        assert(ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios) == 0, "Cannot enable raw terminal mode")
        in_raw_mode = true
        for _, number in ipairs({ 2, 15 }) do
            local previous = ffi.C.signal(number, signal_handler)
            assert(previous ~= ffi.cast("lg_signal_handler", -1), "Cannot install terminal signal handler")
            original_signals[number] = previous
        end

        -- Switch to alternate screen buffer, hide cursor, enable bracketed paste
        io.write("\27[?1049h\27[?25l\27[?7l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
            io.flush()
            if ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios) ~= 0 then
                io.stderr:write("Cannot restore terminal attributes. Run 'stty sane' to recover.\n")
            end
            for number, handler in pairs(original_signals) do
                ffi.C.signal(number, handler)
            end
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

    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local key_buf = ffi.new("char[256]")
    local pending = ""

    read_key = function(timeout_ms)
        if interrupted then
            return "q"
        end
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then
            local ch = io.read(1)
            return ch and normalize_key(ch) or "q"
        end
        local key
        if #pending > 0 then
            key, pending = decode_key(pending, false)
            if key then
                return key
            end
        end
        local ret = ffi.C.poll(pfd, 1, #pending > 0 and 30 or (timeout_ms or 50))
        if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 256)
            if n > 0 then
                pending = pending .. ffi.string(key_buf, n)
            elseif n == 0 then
                return "q"
            else
                error("Cannot read terminal input (errno " .. ffi.errno() .. ")")
            end
        elseif ret < 0 and ffi.errno() ~= 4 then
            error("Cannot poll terminal input (errno " .. ffi.errno() .. ")")
        end
        if #pending > 0 then
            key, pending = decode_key(pending, ret == 0)
            return key
        end
        return nil
    end
end

-- =========================================================================
-- 2. Styling, Colors, and Unicode Box Characters
-- =========================================================================
local C = {
    reset        = "\27[0m",
    bold         = "\27[1m",
    dim          = "\27[2m",
    italic       = "\27[3m",

    -- Borders
    border_focus = "\27[1;38;2;56;189;248m",   -- Cyan
    border_dim   = "\27[38;2;71;85;105m",      -- Slate grey
    header_title = "\27[1;38;2;241;245;249m",

    -- Selection
    sel_bg       = "\27[48;2;30;58;138m\27[1;38;2;255;255;255m", -- Royal blue highlight
    active_tag   = "\27[1;38;2;52;211;153m",   -- Emerald

    -- Git status indicators
    staged_color = "\27[1;38;2;34;197;94m",    -- Green
    unstaged_col = "\27[1;38;2;239;68;68m",    -- Red
    untracked_col= "\27[1;38;2;234;179;8m",    -- Amber

    -- Diff colors
    diff_add     = "\27[38;2;34;197;94m",      -- Green
    diff_del     = "\27[38;2;239;68;68m",      -- Red
    diff_hunk    = "\27[38;2;168;85;247m",     -- Purple
    diff_hdr     = "\27[1;38;2;203;213;225m",  -- Bright text
    diff_meta    = "\27[38;2;100;116;139m",    -- Muted grey

    -- Notifications
    msg_info     = "\27[1;38;2;56;189;248m",
    msg_success  = "\27[1;38;2;34;197;94m",
    msg_warn     = "\27[1;38;2;234;179;8m",
}

local function character_width(char)
    local a, b, c, d = char:byte(1, 4)
    local code = a
    if a >= 240 and d then
        code = (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128
    elseif a >= 224 and c then
        code = (a - 224) * 4096 + (b - 128) * 64 + c - 128
    elseif a >= 192 and b then
        code = (a - 192) * 64 + b - 128
    end
    if (code >= 0x300 and code <= 0x36f) or (code >= 0xfe00 and code <= 0xfe0f) then
        return 0
    end
    if code >= 0x1100 and (code <= 0x115f or code == 0x2329 or code == 0x232a
        or (code >= 0x2e80 and code <= 0xa4cf) or (code >= 0xac00 and code <= 0xd7a3)
        or (code >= 0xf900 and code <= 0xfaff) or (code >= 0xfe10 and code <= 0xfe6f)
        or (code >= 0xff01 and code <= 0xff60) or (code >= 0xffe0 and code <= 0xffe6)
        or (code >= 0x1f300 and code <= 0x1faff) or code >= 0x20000) then
        return 2
    end
    return 1
end

local function visual_len(str)
    local width = 0
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    for char in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        width = width + character_width(char)
    end
    return width
end

local function truncate(str, max_w)
    max_w = math.max(0, max_w)
    if visual_len(str) <= max_w then
        return str
    end
    if max_w <= 3 then
        return string.rep(".", max_w)
    end
    local out = {}
    local width, pos = 0, 1
    while pos <= #str and width < max_w - 3 do
        local escape = str:sub(pos):match("^\27%[[%d;]*m")
        if escape then
            out[#out + 1] = escape
            pos = pos + #escape
        else
            local char = str:sub(pos):match("^[%z\1-\127\194-\244][\128-\191]*")
            char = char or str:sub(pos, pos)
            local char_width = character_width(char)
            if width + char_width > max_w - 3 then
                break
            end
            out[#out + 1] = char
            pos = pos + #char
            width = width + char_width
        end
    end
    return table.concat(out) .. "..." .. C.reset
end

-- Turn cursor-addressed pane fragments into complete physical rows. Comparing
-- these rows lets navigation emit only changed rows, including blank row tails.
local function compose_rows(chunks, width, height)
    local cells = {}
    local row, col, style = 1, 1, ""
    local text = table.concat(chunks)
    local pos = 1
    while pos <= #text do
        local remaining = text:sub(pos)
        local escape = remaining:match("^\27%[[%d;?]*[A-Za-z]")
        if escape then
            local y, x = escape:match("^\27%[(%d+);(%d+)H$")
            if y then
                row, col = tonumber(y), tonumber(x)
            elseif escape == "\27[H" then
                row, col = 1, 1
            elseif escape:sub(-1) == "m" then
                style = escape == C.reset and "" or (style .. escape)
            elseif escape == "\27[K" or escape == "\27[2K" then
                cells[row] = cells[row] or {}
                for index = escape == "\27[2K" and 1 or col, width do
                    cells[row][index] = nil
                end
            end
            pos = pos + #escape
        else
            local char = remaining:match("^[%z\1-\127\194-\244][\128-\191]*") or remaining:sub(1, 1)
            if char == "\n" then
                row, col = row + 1, 1
            elseif char ~= "\r" then
                local size = character_width(char)
                if row >= 1 and row <= height and col >= 1 and col + size - 1 <= width then
                    cells[row] = cells[row] or {}
                    if size == 0 then
                        local previous = cells[row][col - 1]
                        if previous then
                            previous.text = previous.text .. char
                        end
                    else
                        cells[row][col] = { text = char, style = style }
                        if size == 2 then
                            cells[row][col + 1] = { text = "", style = style }
                        end
                    end
                end
                col = col + size
            end
            pos = pos + #char
        end
    end
    local rows = {}
    for y = 1, height do
        local parts, active_style = {}, ""
        for x = 1, width do
            local cell = cells[y] and cells[y][x]
            local next_style = cell and cell.style or ""
            if next_style ~= active_style then
                parts[#parts + 1] = C.reset .. next_style
                active_style = next_style
            end
            parts[#parts + 1] = cell and cell.text or " "
        end
        rows[y] = table.concat(parts) .. C.reset
    end
    return rows
end

-- =========================================================================
-- 3. Git Querying Engine
-- =========================================================================
local function exec_git(args, allowed_exit)
    local argv = { "git", "--no-pager", "--literal-pathspecs", "-c", "color.ui=false" }
    for _, value in ipairs(args) do
        argv[#argv + 1] = value
    end
    return process.run(argv, allowed_exit)
end

local function query_git(args)
    local output, err = exec_git(args)
    if not output then
        error(table.concat(args, " ") .. ": " .. err, 0)
    end
    return output
end

local function get_git_status()
    local raw = query_git({ "status", "--porcelain=v1", "-z" })
    local files = {}
    local pos = 1
    while pos <= #raw do
        local stop = assert(raw:find("\0", pos, true), "Malformed Git status record")
        local line = raw:sub(pos, stop - 1)
        pos = stop + 1
        local x, y, path = line:sub(1, 1), line:sub(2, 2), line:sub(4)
        local original_path
        if x == "R" or x == "C" or y == "R" or y == "C" then
            stop = assert(raw:find("\0", pos, true), "Malformed Git rename record")
            original_path = raw:sub(pos, stop - 1)
            pos = stop + 1
        end
        local is_staged = x ~= " " and x ~= "?"
        local is_untracked = x == "?" and y == "?"
        files[#files + 1] = {
            path = path,
            original_path = original_path,
            status_tag = x .. y,
            color = is_untracked and C.untracked_col
                or (is_staged and y == " " and C.staged_color or C.unstaged_col),
            is_staged = is_staged,
            is_untracked = is_untracked,
            x = x,
            y = y,
        }
    end
    return files
end

local function get_git_branches()
    local raw = query_git({ "branch", "-a", "--sort=-committerdate" })
    local branches = {}

    for line in raw:gmatch("[^\r\n]+") do
        local is_current = line:sub(1, 2) == "* "
        local name = line:sub(3):gsub("^%s+", "")
        -- Filter out HEAD detached or symrefs
        if not name:find("%->") then
            local is_remote = name:find("^remotes/") ~= nil
            table.insert(branches, {
                name = name,
                is_current = is_current,
                is_remote = is_remote,
            })
        end
    end
    return branches
end

local function get_git_commits(limit)
    limit = limit or 25
    local raw, err = exec_git({ "log", "-n", tostring(limit), "--pretty=format:%h|%an|%cr|%s" })
    if not raw then
        if query_git({ "rev-list", "--all", "--count" }):match("^0%s*$") then
            return {}
        end
        error(err, 0)
    end
    local commits = {}

    for line in raw:gmatch("[^\r\n]+") do
        local hash, author, time, subject = line:match("([^|]+)|([^|]+)|([^|]+)|(.*)")
        if hash then
            table.insert(commits, {
                hash = hash,
                author = author,
                time = time,
                subject = subject,
            })
        end
    end
    return commits
end

local function get_git_diff(filepath, is_staged)
    local args = { "diff" }
    if is_staged then
        args[#args + 1] = "--cached"
    end
    args[#args + 1] = "--"
    args[#args + 1] = filepath
    local raw = query_git(args)
    if #raw == 0 then
        -- Might be untracked or empty diff
        local untracked_check = query_git({ "status", "--porcelain", "--", filepath })
        if untracked_check:sub(1, 2) == "??" then
            if filepath:sub(-1) == "/" then
                return { C.dim .. "Untracked directory. Stage it to inspect its files." .. C.reset }
            end
            -- Git handles UTF-8 Windows paths and binary files; diff exit 1 means differences.
            local err
            raw, err = exec_git({ "diff", "--no-index", "--", "/dev/null", filepath }, 1)
            if not raw then
                error("Cannot preview " .. filepath .. ": " .. err, 0)
            end
        end
        if #raw == 0 then
            return { C.dim .. "(No diff content or working tree clean)" .. C.reset }
        end
    end

    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        local first = line:sub(1, 1)
        if line:sub(1, 4) == "+++" or line:sub(1, 4) == "---" or line:sub(1, 4) == "diff" then
            table.insert(lines, C.diff_hdr .. line .. C.reset)
        elseif line:sub(1, 2) == "@@" then
            table.insert(lines, C.diff_hunk .. line .. C.reset)
        elseif first == "+" then
            table.insert(lines, C.diff_add .. line .. C.reset)
        elseif first == "-" then
            table.insert(lines, C.diff_del .. line .. C.reset)
        else
            table.insert(lines, C.diff_meta .. line .. C.reset)
        end
    end
    return lines
end

local function get_commit_details(hash)
    local raw = query_git({ "show", "--stat", "-p", hash, "--" })
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        local first = line:sub(1, 1)
        if line:sub(1, 6) == "commit" or line:sub(1, 6) == "Author" or line:sub(1, 4) == "Date" then
            table.insert(lines, C.header_title .. line .. C.reset)
        elseif line:sub(1, 2) == "@@" then
            table.insert(lines, C.diff_hunk .. line .. C.reset)
        elseif first == "+" then
            table.insert(lines, C.diff_add .. line .. C.reset)
        elseif first == "-" then
            table.insert(lines, C.diff_del .. line .. C.reset)
        else
            table.insert(lines, line)
        end
    end
    return lines
end

-- =========================================================================
-- 4. TUI Screen Drawing & Layout Engine
-- =========================================================================
local function draw_box_row(x, y, w, text)
    -- Position cursor at x, y and print formatted row
    local clr = truncate(text, w - 2)
    local vlen = visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s", y, x + 1, clr, pad)
end

local function draw_border_rect(x, y, w, h, title, is_focused)
    local bcol = is_focused and C.border_focus or C.border_dim
    local out = {}

    -- Top border with title
    title = title and truncate(title, math.max(0, w - 4))
    local title_str = title and string.format(" %s%s%s ", C.header_title, title, bcol) or ""
    local t_len = title and (visual_len(title) + 2) or 0
    local top_fill = string.rep("─", math.max(0, w - 2 - t_len))
    table.insert(out, string.format("\27[%d;%dH%s╭%s%s╮%s", y, x, bcol, title_str, top_fill, C.reset))

    -- Side borders
    for i = 1, h - 2 do
        table.insert(out, string.format("\27[%d;%dH%s│\27[%d;%dH│%s", y + i, x, bcol, y + i, x + w - 1, C.reset))
    end

    -- Bottom border
    local bot_fill = string.rep("─", math.max(0, w - 2))
    table.insert(out, string.format("\27[%d;%dH%s╰%s╯%s", y + h - 1, x, bcol, bot_fill, C.reset))

    return table.concat(out)
end

-- =========================================================================
-- 5. Application State & Interactive Loop
-- =========================================================================
local function main()
    -- Ensure we are in a Git repository
    local is_repo = query_git({ "rev-parse", "--is-inside-work-tree" }):match("true")
    if not is_repo then
        io.stderr:write("\27[1;31mError: Not a git repository.\27[0m\n")
        os.exit(1)
    end

    enable_raw_mode()

    local active_pane = 1 -- 1: Files, 2: Branches, 3: Commits, 4: Diff View
    local sel_file = 1
    local sel_branch = 1
    local sel_commit = 1
    local diff_scroll = 0
    local file_offset, branch_offset, commit_offset = 0, 0, 0
    local pending_discard
    local commit_message

    local files = get_git_status()
    local branches = get_git_branches()
    local commits = get_git_commits(40)
    local status_msg = "Ready. Press [Space] to stage, [c] to commit, [Tab] to switch panes."
    local status_msg_color = C.msg_info

    local needs_redraw = true
    local previous_rows = {}
    local cached_diff_key, cached_diff_lines
    local repo_name = query_git({ "rev-parse", "--show-toplevel" }):gsub("%s+$", ""):match("([^/\\]+)$") or "repository"
    local current_branch = query_git({ "branch", "--show-current" }):gsub("%s+", "")

    local function run_git_action(args, success)
        local output, err = exec_git(args)
        if output then
            status_msg = success
            status_msg_color = C.msg_success
            return true
        end
        status_msg = table.concat(args, " ") .. ": " .. err:gsub("[\r\n]+", " ")
        status_msg_color = C.msg_warn
        return false
    end

    local function visible_offset(selected, offset, height)
        return math.max(0, math.min(math.max(offset, selected - height), selected - 1))
    end

    local function display_path(path)
        return path:gsub("[%z\1-\31\127]", function(char)
            return string.format("\\x%02x", char:byte())
        end)
    end

    local function refresh_git()
        files = get_git_status()
        branches = get_git_branches()
        commits = get_git_commits(40)
        sel_file = math.max(1, math.min(sel_file, math.max(1, #files)))
        sel_branch = math.max(1, math.min(sel_branch, math.max(1, #branches)))
        sel_commit = math.max(1, math.min(sel_commit, math.max(1, #commits)))
        diff_scroll = 0
        cached_diff_key = nil
        current_branch = query_git({ "branch", "--show-current" }):gsub("%s+", "")
        needs_redraw = true
    end

    local last_w, last_h = get_terminal_size()

    -- Initial clear once
    io.write("\27[H\27[2J")
    io.flush()

    while true do
        local raw_w, term_h = get_terminal_size()
        local term_w = math.max(1, raw_w - 1)
        if raw_w ~= last_w or term_h ~= last_h then
            last_w, last_h = raw_w, term_h
            needs_redraw = true
            previous_rows = {}
            io.write("\27[H\27[2J") -- Clear on resize
        end

        if needs_redraw then
            local out = {}
            table.insert(out, "\27[?2026h")

            if term_w < 60 or term_h < 20 then
                table.insert(out, "\27[H" .. truncate("Terminal too small; resize to at least 61 x 20. [q] Quit", term_w))
                table.insert(out, "\27[K")
                for row = 2, term_h do
                    table.insert(out, string.format("\27[%d;1H\27[K", row))
                end
            else

                -- Home cursor without blanking the screen (never emit \27[2J in regular loops to avoid screen flash)
                table.insert(out, "\27[H")
                local header_text = string.format("  \27[1;38;2;56;189;248m⚡ LAZYGIT-LITE\27[0m \27[90m│\27[0m \27[1;97m%s\27[0m \27[90m(\27[1;38;2;52;211;153m%s\27[0m\27[90m)\27[0m\27[K",
                    repo_name, current_branch ~= "" and current_branch or "detached")
                table.insert(out, header_text .. "\n")

                -- Layout Geometry Calculation
                local usable_h = term_h - 4 -- leave header and two footer rows
                local left_w = math.max(28, math.floor(term_w * 0.38))
                local right_w = term_w - left_w

                local h_files = math.floor(usable_h * 0.42)
                local h_branches = math.floor(usable_h * 0.28)
                local h_commits = usable_h - h_files - h_branches

                local y_files = 2
                local y_branches = y_files + h_files
                local y_commits = y_branches + h_branches

                -- Draw Pane 1: Files / Status
                table.insert(out, draw_border_rect(1, y_files, left_w, h_files, "1. Files (" .. #files .. ")", active_pane == 1))
                local f_visible = h_files - 2
                file_offset = visible_offset(sel_file, file_offset, f_visible)
                for i = 1, f_visible do
                    local f_idx = file_offset + i
                    if f_idx <= #files then
                        local f = files[f_idx]
                        local is_sel = (active_pane == 1 and f_idx == sel_file)
                        local line_str = string.format("%s %s", f.status_tag, display_path(f.path))
                        local content = is_sel and (C.sel_bg .. "▶ " .. line_str .. C.reset) or (f.color .. "  " .. line_str .. C.reset)
                        table.insert(out, draw_box_row(1, y_files + i, left_w, content))
                    else
                        table.insert(out, draw_box_row(1, y_files + i, left_w, ""))
                    end
                end

                -- Draw Pane 2: Branches
                table.insert(out, draw_border_rect(1, y_branches, left_w, h_branches, "2. Branches (" .. #branches .. ")", active_pane == 2))
                local b_visible = h_branches - 2
                branch_offset = visible_offset(sel_branch, branch_offset, b_visible)
                for i = 1, b_visible do
                    local b_idx = branch_offset + i
                    if b_idx <= #branches then
                        local b = branches[b_idx]
                        local is_sel = (active_pane == 2 and b_idx == sel_branch)
                        local prefix = b.is_current and (C.active_tag .. "* " .. C.reset) or "  "
                        local content = is_sel and (C.sel_bg .. "▶ " .. b.name .. C.reset) or (prefix .. (b.is_remote and (C.dim .. b.name .. C.reset) or b.name))
                        table.insert(out, draw_box_row(1, y_branches + i, left_w, content))
                    else
                        table.insert(out, draw_box_row(1, y_branches + i, left_w, ""))
                    end
                end

                -- Draw Pane 3: Commits
                table.insert(out, draw_border_rect(1, y_commits, left_w, h_commits, "3. Commits (" .. #commits .. ")", active_pane == 3))
                local c_visible = h_commits - 2
                commit_offset = visible_offset(sel_commit, commit_offset, c_visible)
                for i = 1, c_visible do
                    local c_idx = commit_offset + i
                    if c_idx <= #commits then
                        local cm = commits[c_idx]
                        local is_sel = (active_pane == 3 and c_idx == sel_commit)
                        local line_str = string.format("%s %s", cm.hash, cm.subject)
                        local content = is_sel and (C.sel_bg .. "▶ " .. line_str .. C.reset) or ("  " .. C.header_title .. cm.hash .. C.reset .. " " .. cm.subject)
                        table.insert(out, draw_box_row(1, y_commits + i, left_w, content))
                    else
                        table.insert(out, draw_box_row(1, y_commits + i, left_w, ""))
                    end
                end

                -- Draw Pane 4: Diff / Inspector (Right side)
                local diff_title = "4. Diff Inspector"
                local diff_lines = {}

                if active_pane == 3 and commits[sel_commit] then
                    diff_title = "Commit: " .. commits[sel_commit].hash .. " (" .. commits[sel_commit].author .. ", " .. commits[sel_commit].time .. ")"
                    local key = "commit:" .. commits[sel_commit].hash
                    if cached_diff_key ~= key then
                        cached_diff_lines = get_commit_details(commits[sel_commit].hash)
                        cached_diff_key = key
                        diff_scroll = 0
                    end
                    diff_lines = cached_diff_lines
                elseif files[sel_file] then
                    diff_title = "Diff: " .. display_path(files[sel_file].path)
                    local key = "file:" .. files[sel_file].path .. tostring(files[sel_file].is_staged)
                    if cached_diff_key ~= key then
                        cached_diff_lines = get_git_diff(files[sel_file].path, files[sel_file].is_staged)
                        cached_diff_key = key
                        diff_scroll = 0
                    end
                    diff_lines = cached_diff_lines
                else
                    diff_lines = { C.dim .. "Working tree clean. No files changed." .. C.reset }
                end

                table.insert(out, draw_border_rect(left_w + 1, y_files, right_w, usable_h, diff_title, active_pane == 4))
                local d_visible = usable_h - 2
                diff_scroll = math.max(0, math.min(diff_scroll, #diff_lines - d_visible))
                for i = 1, d_visible do
                    local d_idx = i + diff_scroll
                    local content = diff_lines[d_idx] or ""
                    table.insert(out, draw_box_row(left_w + 1, y_files + i, right_w, content))
                end

                -- Footer / Keybinding & Message Bar
                local footer_y = term_h - 2
                local help_keys = "[Tab] Switch Pane  [Space] Stage/Unstage  [c] Commit  [d] Discard  [r] Refresh  [q] Quit"
                local message = pending_discard and ("Discard unstaged changes in " .. display_path(pending_discard) .. "? [y/N]")
                    or (commit_message and ("Commit message: " .. commit_message .. " [Enter] Save [Esc] Cancel"))
                    or help_keys
                local footer_str = string.format("\27[%d;1H%s\27[K",
                    footer_y, truncate("  " .. C.msg_info .. message .. C.reset, term_w))
                table.insert(out, footer_str)
                table.insert(out, string.format("\27[%d;1H%s\27[K", term_h - 1,
                    truncate("  " .. status_msg_color .. status_msg .. C.reset, term_w)))
            end
            table.insert(out, "\27[?2026l")

            local rows = compose_rows(out, term_w, math.max(1, term_h - 1))
            local changes = { "\27[?2026h" }
            for index, row in ipairs(rows) do
                if previous_rows[index] ~= row then
                    changes[#changes + 1] = string.format("\27[%d;1H%s\27[K\n", index, row)
                end
            end
            changes[#changes + 1] = "\27[?2026l"
            io.write(table.concat(changes))
            io.flush()
            previous_rows = rows
            needs_redraw = false
        end

        -- Key handling: blocks up to 200ms when idle without spinning CPU or causing flashes
        local k = read_key(200)
        if k then
            needs_redraw = true
            if last_w < 61 or last_h < 20 then
                if k == "q" or k == "ESC" then
                    break
                end
            elseif pending_discard then
                if k == "y" or k == "Y" then
                    if run_git_action({ "restore", "--", pending_discard }, "Discarded changes in " .. display_path(pending_discard)) then
                        refresh_git()
                    end
                else
                    status_msg = "Discard cancelled."
                    status_msg_color = C.msg_info
                end
                pending_discard = nil
            elseif commit_message then
                if k == "ESC" then
                    commit_message = nil
                    status_msg = "Commit cancelled."
                elseif k == "ENTER" then
                    if #commit_message == 0 then
                        commit_message = nil
                        status_msg = "Commit cancelled."
                    elseif run_git_action({ "commit", "-m", commit_message }, "Committed: " .. commit_message) then
                        commit_message = nil
                        refresh_git()
                    end
                elseif k == "BACKSPACE" then
                    commit_message = commit_message:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
                elseif k == "SPACE" then
                    commit_message = commit_message .. " "
                elseif (#k == 1 and k:byte() >= 32) or k:match("^[\194-\244][\128-\191]+$") then
                    commit_message = commit_message .. k
                end
            elseif k == "q" or k == "ESC" then
                break
            elseif k == "TAB" then
                active_pane = (active_pane % 4) + 1
                status_msg = "Switched to pane " .. active_pane
                status_msg_color = C.msg_info
            elseif k == "1" then
                active_pane = 1
            elseif k == "2" then
                active_pane = 2
            elseif k == "3" then
                active_pane = 3
            elseif k == "4" then
                active_pane = 4
            elseif k == "UP" or k == "k" then
                if active_pane == 1 then
                    sel_file = math.max(1, sel_file - 1)
                elseif active_pane == 2 then
                    sel_branch = math.max(1, sel_branch - 1)
                elseif active_pane == 3 then
                    sel_commit = math.max(1, sel_commit - 1)
                elseif active_pane == 4 then
                    diff_scroll = math.max(0, diff_scroll - 1)
                end
            elseif k == "DOWN" or k == "j" then
                if active_pane == 1 then
                    sel_file = math.max(1, math.min(#files, sel_file + 1))
                elseif active_pane == 2 then
                    sel_branch = math.max(1, math.min(#branches, sel_branch + 1))
                elseif active_pane == 3 then
                    sel_commit = math.max(1, math.min(#commits, sel_commit + 1))
                elseif active_pane == 4 then
                    diff_scroll = diff_scroll + 1
                end
            elseif k == "PAGE_UP" then
                if active_pane == 4 then
                    diff_scroll = math.max(0, diff_scroll - 10)
                end
            elseif k == "PAGE_DOWN" then
                if active_pane == 4 then
                    diff_scroll = diff_scroll + 10
                end
            elseif k == "SPACE" then
                -- Stage or unstage file
                if #files > 0 and files[sel_file] then
                    local f = files[sel_file]
                    local args = f.is_staged and { "restore", "--staged", "--", f.path }
                        or { "add", "--", f.path }
                    if f.original_path then
                        args[#args + 1] = f.original_path
                    end
                    if f.is_staged then
                        run_git_action(args, "Unstaged " .. display_path(f.path))
                    else
                        run_git_action(args, "Staged " .. display_path(f.path))
                    end
                    refresh_git()
                end
            elseif k == "a" then
                -- Toggle stage all
                local has_unstaged = false
                for _, f in ipairs(files) do
                    if not f.is_staged or f.y ~= " " then
                        has_unstaged = true
                        break
                    end
                end
                if has_unstaged then
                    run_git_action({ "add", "-A" }, "Staged all changes.")
                else
                    run_git_action({ "reset" }, "Unstaged all changes.")
                end
                refresh_git()
            elseif k == "d" then
                -- Discard changes
                if #files > 0 and files[sel_file] then
                    local f = files[sel_file]
                    if f.is_untracked or f.y == " " then
                        status_msg = "No tracked unstaged changes to discard in " .. display_path(f.path)
                        status_msg_color = C.msg_warn
                    else
                        pending_discard = f.path
                    end
                end
            elseif k == "c" then
                commit_message = ""
            elseif k == "r" then
                refresh_git()
                status_msg = "Git status refreshed."
                status_msg_color = C.msg_info
            end
        end
    end

    disable_raw_mode()
    print("\n\27[1;36mExited lazygit-lite. Goodbye!\27[0m")
end

-- Run with protected terminal cleanup; the review harness also exercises main directly.
io.stderr:write("lazygit-lite: checking Git repository...\n")
io.stderr:flush()
local ok, err = xpcall(main, debug.traceback)
disable_raw_mode()
if not ok then
    io.stderr:write("lazygit-lite: " .. tostring(err) .. "\n")
    io.stderr:flush()
    os.exit(1)
end
