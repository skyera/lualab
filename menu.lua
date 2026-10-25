#!/usr/bin/env luajit
--[[
    menu.lua - Adaptive Interactive Program Launcher for lualab
    Rock-solid border alignment, dual-pane (wide) & compact (standard) responsive layouts.
    Cross-platform support for Windows (Win32 Console API) and POSIX (Linux / macOS / BSD).
--]]

local ffi = require("ffi")
local bit = require("bit")

--------------------------------------------------------------------------------
-- Cross-Platform Terminal State & Input Management
--------------------------------------------------------------------------------
local is_windows = (ffi.os == "Windows")
local is_raw = false

local restore_terminal
local init_terminal
local get_term_size
local read_key
local flush_input

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

        void* __stdcall GetStdHandle(uint32_t nStdHandle);
        int   __stdcall GetConsoleScreenBufferInfo(
            void* hConsoleOutput,
            CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo
        );
        int   __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int   __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int   __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        int   __stdcall FlushConsoleInputBuffer(void* hConsoleInput);
        void  __stdcall Sleep(uint32_t dwMilliseconds);

        int _kbhit(void);
        int _getch(void);
    ]]

    local C = ffi.C
    local STD_INPUT_HANDLE  = 0xFFFFFFF6
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5
    local ENABLE_PROCESSED_INPUT = 0x0001
    local ENABLE_LINE_INPUT      = 0x0002
    local ENABLE_ECHO_INPUT      = 0x0004
    local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

    local orig_in_mode  = ffi.new("uint32_t[1]")
    local orig_out_mode = ffi.new("uint32_t[1]")
    local has_console_in  = false
    local has_console_out = false

    pcall(function()
        C.SetConsoleOutputCP(65001)
    end)

    restore_terminal = function()
        if is_raw then
            io.write("\27[?7h\27[?25h\27[?1049l\27[0m")
            io.flush()
            if has_console_in then
                local hIn = C.GetStdHandle(STD_INPUT_HANDLE)
                C.SetConsoleMode(hIn, orig_in_mode[0])
            end
            if has_console_out then
                local hOut = C.GetStdHandle(STD_OUTPUT_HANDLE)
                C.SetConsoleMode(hOut, orig_out_mode[0])
            end
            is_raw = false
        end
    end

    init_terminal = function()
        local hIn = C.GetStdHandle(STD_INPUT_HANDLE)
        local hOut = C.GetStdHandle(STD_OUTPUT_HANDLE)

        C.SetConsoleOutputCP(65001)
        if C.GetConsoleMode(hOut, orig_out_mode) ~= 0 then
            has_console_out = true
            local vt_mode = bit.bor(orig_out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING)
            C.SetConsoleMode(hOut, vt_mode)
        end

        if C.GetConsoleMode(hIn, orig_in_mode) ~= 0 then
            has_console_in = true
            local mask = bit.bor(ENABLE_PROCESSED_INPUT, ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT)
            local raw_mode = bit.band(orig_in_mode[0], bit.bnot(mask))
            C.SetConsoleMode(hIn, raw_mode)
        end

        is_raw = true
        io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
        io.flush()
    end

    get_term_size = function()
        local hOut = C.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if C.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if cols > 10 and rows > 10 then
                return tonumber(cols), tonumber(rows)
            end
        end
        return 80, 24
    end

    flush_input = function()
        if has_console_in then
            local hIn = C.GetStdHandle(STD_INPUT_HANDLE)
            C.FlushConsoleInputBuffer(hIn)
        end
        while C._kbhit() ~= 0 do
            C._getch()
        end
    end

    read_key = function(timeout_ms)
        local hIn = C.GetStdHandle(STD_INPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        if C.GetConsoleMode(hIn, mode) == 0 then
            local ch = io.read(1)
            if not ch then
                return "q"
            end
            if ch == "\27" then
                return "ESC"
            elseif ch == "\n" or ch == "\r" then
                return "ENTER"
            end
            return ch:lower()
        end

        local wait_ms = timeout_ms or 50
        local elapsed = 0
        while wait_ms <= 0 or elapsed <= wait_ms do
            if C._kbhit() ~= 0 then
                local ch = C._getch()
                if ch == 0 or ch == 224 then
                    local code = C._getch()
                    if code == 72 then
                        return "UP"
                    elseif code == 80 then
                        return "DOWN"
                    elseif code == 75 then
                        return "LEFT"
                    elseif code == 77 then
                        return "RIGHT"
                    end
                    return nil
                elseif ch == 27 then
                    if C._kbhit() ~= 0 then
                        local b1 = C._getch()
                        if b1 == 91 and C._kbhit() ~= 0 then
                            local b2 = C._getch()
                            if b2 == 65 then
                                return "UP"
                            elseif b2 == 66 then
                                return "DOWN"
                            elseif b2 == 67 then
                                return "RIGHT"
                            elseif b2 == 68 then
                                return "LEFT"
                            end
                        end
                    end
                    return "ESC"
                elseif ch == 10 or ch == 13 then
                    return "ENTER"
                elseif ch == 3 then
                    return "q"
                elseif ch >= 32 and ch <= 126 then
                    return string.char(ch):lower()
                end
            end
            if wait_ms > 0 then
                C.Sleep(10)
                elapsed = elapsed + 10
            else
                break
            end
        end
        return nil
    end
else
    -- POSIX definitions for Linux, macOS, and BSD
    local function posix_termios_cdef(def)
        if ffi.os == "OSX" or ffi.os == "BSD" then
            def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
            def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
            def = def:gsub("c_cc%[32%]", "c_cc[20]")
        end
        return def
    end

    ffi.cdef(posix_termios_cdef[[
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

        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };

        struct pollfd {
            int   fd;
            short events;
            short revents;
        };

        int isatty(int fd);
        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int tcflush(int fd, int queue_selector);
        int ioctl(int fd, unsigned long request, ...);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);
        int usleep(unsigned int usec);
    ]])

    local C = ffi.C
    local TCSANOW    = 0
    local TCIFLUSH   = 0
    local TIOCGWINSZ = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413
    local POLLIN     = 0x0001
    local POLLERR    = 0x0008
    local POLLHUP    = 0x0010

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")
    local has_tty      = false
    local pollfd       = ffi.new("struct pollfd", { fd = 0, events = POLLIN, revents = 0 })
    local in_buf       = ffi.new("char[64]")

    restore_terminal = function()
        if is_raw then
            if has_tty then
                C.tcsetattr(0, TCSANOW, orig_termios)
            end
            io.write("\27[?7h\27[?25h\27[?1049l\27[0m")
            io.flush()
            is_raw = false
        end
    end

    init_terminal = function()
        if C.isatty(0) == 1 and C.tcgetattr(0, orig_termios) == 0 then
            has_tty = true
            ffi.copy(raw_termios, orig_termios, ffi.sizeof("struct termios"))

            -- Raw mode: disable ECHO, ICANON, ISIG, IEXTEN
            local lflag_mask = bit.bor(0x0008, 0x0002, 0x0001, 0x8000)
            local iflag_mask = bit.bor(0x0400, 0x0100)
            raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(lflag_mask))
            raw_termios.c_iflag = bit.band(raw_termios.c_iflag, bit.bnot(iflag_mask))
            raw_termios.c_cc[5] = 0 -- VMIN
            raw_termios.c_cc[6] = 0 -- VTIME

            if C.tcsetattr(0, TCSANOW, raw_termios) ~= 0 then
                error("Failed to set raw terminal mode")
            end
        end
        is_raw = true

        io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
        io.flush()
    end

    get_term_size = function()
        local ws = ffi.new("struct winsize")
        if C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 10 and ws.ws_row > 10 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 80, 24
    end

    flush_input = function()
        if has_tty then
            C.tcflush(0, TCIFLUSH)
        end
    end

    read_key = function(timeout_ms)
        pollfd.revents = 0
        local ret = C.poll(pollfd, 1, timeout_ms or 50)
        if ret <= 0 then
            return nil
        end
        if bit.band(pollfd.revents, POLLIN) ~= 0 then
            local n = C.read(0, in_buf, 64)
            if n <= 0 then
                return "q"
            end

            if in_buf[0] == 27 then
                if n >= 3 and in_buf[1] == 91 then
                    local code = in_buf[2]
                    if code == 65 then
                        return "UP"
                    elseif code == 66 then
                        return "DOWN"
                    elseif code == 67 then
                        return "RIGHT"
                    elseif code == 68 then
                        return "LEFT"
                    end
                end
                return "ESC"
            elseif in_buf[0] == 10 or in_buf[0] == 13 then
                return "ENTER"
            elseif in_buf[0] == 3 then
                return "q"
            end
            return string.char(in_buf[0]):lower()
        elseif bit.band(pollfd.revents, bit.bor(POLLHUP, POLLERR)) ~= 0 then
            return "q"
        end
        return nil
    end
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

local function utf8_width(str)
    local count = 0
    for i = 1, #str do
        local b = str:byte(i)
        if bit.band(b, 0xC0) ~= 0x80 then
            count = count + 1
        end
    end
    return count
end

local function utf8_truncate(str, max_cols, suffix)
    suffix = suffix or "..."
    if utf8_width(str) <= max_cols then
        return str
    end
    local suffix_w = utf8_width(suffix)
    local target = math.max(1, max_cols - suffix_w)
    local cols = 0
    local byte_end = 0
    local i = 1
    while i <= #str do
        local b = str:byte(i)
        local char_len = 1
        if b >= 0xF0 then
            char_len = 4
        elseif b >= 0xE0 then
            char_len = 3
        elseif b >= 0xC0 then
            char_len = 2
        end
        if cols + 1 > target then
            break
        end
        cols = cols + 1
        byte_end = i + char_len - 1
        i = i + char_len
    end
    return str:sub(1, byte_end) .. suffix
end

--------------------------------------------------------------------------------
-- Program Manifest & Catalog
--------------------------------------------------------------------------------
local PROGRAMS = {
    {
        id = "outrun_racer",
        file = "outrun_racer.lua",
        name = "OutRun Racer",
        icon = "🏎️",
        full_title = "OutRun Terminal Racer",
        category = "Game",
        type = "Arcade 3D Racing",
        backend = "LuaJIT FFI + POSIX termios + TrueColor ANSI Double-Buffer",
        desc = "High-performance pseudo-3D road racing game. Features smooth scanline\n" ..
               "road curves, elevation, parallax sunset backdrop, roadside scenery,\n" ..
               "and overtaking AI traffic running at locked 60 FPS.",
        controls = "[A/D] or [←/→] Steer  •  [W/S] or [↑/↓] Gas/Brake  •  [Q] Quit",
    },
    {
        id = "wolf3d",
        file = "ffi_wolf3d_raycaster.lua",
        name = "Wolfenstein 3D",
        icon = "🐺",
        full_title = "Wolfenstein 3D Raycaster",
        category = "Game",
        type = "FPS Raycaster",
        backend = "LuaJIT FFI + DDA Raycasting + TrueColor ANSI",
        desc = "Classic first-person 3D raycaster. Explore a 2.5D maze with textured walls,\n" ..
               "minimap display, smooth movement, and retro corridor aesthetics.",
        controls = "[W/S] Move  •  [A/D] Turn  •  [Q/E] Strafe  •  [M] Map  •  [ESC] Quit",
    },
    {
        id = "falling_sand",
        file = "ffi_falling_sand.lua",
        name = "Falling Sand",
        icon = "⏳",
        full_title = "Falling Sand Sandbox",
        category = "Game",
        type = "Physics Sandbox",
        backend = "LuaJIT FFI + Cellular Automata Grid + ANSI 24-bit",
        desc = "Real-time falling particle and chemical reaction simulation.\n" ..
               "Draw sand, water, fire, wood, acid, and gunpowder to observe reactions.",
        controls = "[Mouse/WASD] Cursor  •  [1-6] Select Element  •  [C] Clear",
    },
    {
        id = "tetris",
        file = "ffi_tetris.lua",
        name = "Tetris",
        icon = "🧱",
        full_title = "Tetris (LuaJIT FFI)",
        category = "Game",
        type = "Block Puzzle",
        backend = "LuaJIT FFI + Terminal Matrix Grid",
        desc = "Faithful implementation of classic Tetris with 7 tetrominoes, rotation,\n" ..
               "ghost piece indicator, score tracker, level progression, and line clears.",
        controls = "[←/→] Move  •  [↑] Rotate  •  [↓] Soft Drop  •  [Space] Hard Drop",
    },
    {
        id = "breakout",
        file = "ffi_breakout.lua",
        name = "Breakout",
        icon = "🏓",
        full_title = "Breakout Terminal Arcade",
        category = "Game",
        type = "Arcade / Brick Breaker",
        backend = "LuaJIT FFI + Fixed-Step Terminal Renderer",
        desc = "Classic paddle-and-ball action: clear rows of bricks, keep the ball alive,\n" ..
               "and build your score across increasingly faster levels.",
        controls = "[A/D] or [←/→] Move  •  [P] Pause  •  [Q] Quit",
    },
    {
        id = "game_2048",
        file = "ffi_game_2048.lua",
        name = "2048 Edition",
        icon = "🔢",
        full_title = "2048 Terminal Edition",
        category = "Game",
        type = "Sliding Tile Puzzle",
        backend = "LuaJIT FFI + ANSI Colored Tiles",
        desc = "Sleek terminal edition of the popular 2048 tile merging puzzle.\n" ..
               "Features smooth colored tile blocks, undo history, and high score tracking.",
        controls = "[WASD] or [Arrows] Slide Tiles  •  [U] Undo  •  [R] Restart  •  [Q] Quit",
    },
    {
        id = "chinese_chess",
        file = "ffi_chinese_chess.lua",
        name = "Chinese Chess",
        icon = "♟️",
        full_title = "Chinese Chess (Xiangqi)",
        category = "Game",
        type = "Board Game / Strategy",
        backend = "LuaJIT FFI + Unicode Board Renderer",
        desc = "Traditional Chinese Chess (Xiangqi) with full board rendering, legal move\n" ..
               "validation, piece captures, check detection, and turn-based play.",
        controls = "[Arrows] Move Cursor  •  [Space/Enter] Pick & Place  •  [Q] Quit",
    },
    {
        id = "snake",
        file = "ffi_game_snake.lua",
        name = "Classic Snake",
        icon = "🐍",
        full_title = "Classic Snake",
        category = "Game",
        type = "Arcade Classic",
        backend = "LuaJIT FFI + Framebuffer Loop",
        desc = "Classic snake game with smooth movement, fruit spawning, score counter,\n" ..
               "and boundary wrapping modes.",
        controls = "[WASD] or [Arrows] Direction  •  [P] Pause  •  [Q] Quit",
    },
    {
        id = "file_list_tui",
        file = "file_list_tui.lua",
        name = "File Manager",
        icon = "📁",
        full_title = "File Manager TUI",
        category = "Utility",
        type = "File Browser",
        backend = "LuaJIT FFI + POSIX dirent/stat + ANSI Viewport",
        desc = "Interactive terminal file manager. Features directory tree navigation,\n" ..
               "file permissions and size inspection, multi-sort, and quick preview.",
        controls = "[↑/↓] Navigate  •  [Enter] Open/Enter  •  [Backspace] Up  •  [Q] Quit",
    },
    {
        id = "luatop",
        file = "luatop.lua",
        name = "Luatop Monitor",
        icon = "📊",
        full_title = "Luatop System Monitor",
        category = "Utility",
        type = "System Monitor",
        backend = "LuaJIT FFI + /proc Parser + Live Sparklines",
        desc = "Comprehensive real-time system resource monitor. Displays per-core CPU usage,\n" ..
               "memory distribution, process tables, network I/O, and disk load graphs.",
        controls = "[Tab] Switch Panel  •  [↑/↓] Select Process  •  [K] Kill  •  [Q] Quit",
    },
    {
        id = "lazygit_lite",
        file = "lazygit_lite.lua",
        name = "Lazygit Lite",
        icon = "🌿",
        full_title = "Lazygit Lite",
        category = "Utility",
        type = "Git Client",
        backend = "LuaJIT FFI + Git Subprocess + Split View",
        desc = "Streamlined terminal interface for Git repositories. Inspect status,\n" ..
               "stage/unstage changes, view diffs side-by-side, and browse commit logs.",
        controls = "[Tab] Switch Section  •  [Space] Stage  •  [C] Commit  •  [Q] Quit",
    },
    {
        id = "todo_tui",
        file = "todo_tui.lua",
        name = "Todo Manager",
        icon = "✅",
        full_title = "Todo List Manager",
        category = "Utility",
        type = "Task Organizer",
        backend = "LuaJIT FFI + JSON Persistence",
        desc = "Interactive task and priority manager with categorized task lists,\n" ..
               "due dates, completion status, and instant search.",
        controls = "[A] Add  •  [Space] Toggle Done  •  [D] Delete  •  [E] Edit  •  [Q] Quit",
    }
}

--------------------------------------------------------------------------------
-- ANSI Colors & Utilities
--------------------------------------------------------------------------------
local ANSI = {
    RESET     = "\27[0m",
    HOME      = "\27[H",
    EOL_CLEAR = "\27[K",
    BOLD      = "\27[1m",
    DIM       = "\27[2m",
    BG_HDR    = "\27[48;2;30;40;65m",
    FG_HDR    = "\27[38;2;120;210;255m",
    FG_TITLE  = "\27[38;2;255;220;60m",
    FG_CYAN   = "\27[38;2;90;210;245m",
    FG_GREEN  = "\27[38;2;100;240;130m",
    FG_GRAY   = "\27[38;2;140;145;160m",
    FG_WHITE  = "\27[38;2;240;245;255m",
    FG_YELLOW = "\27[38;2;255;220;80m",
    FG_SEL    = "\27[38;2;255;255;255m\27[48;2;45;75;135m",
    BORDER    = "\27[38;2;80;90;120m",
}

--------------------------------------------------------------------------------
-- Dual-Pane Layout Renderer (for width >= 90)
--------------------------------------------------------------------------------
local function render_dual_pane(selected_idx, scroll_offset, width, height)
    local lines = {}

    -- 1. Top Header
    local hdr_text = "  ⚡ LUALAB - INTERACTIVE PROGRAM LAUNCHER"
    local ver_text = "v1.2.1  "
    local hdr_w = utf8_width(hdr_text)
    local top_bar = ANSI.BG_HDR .. ANSI.FG_HDR .. ANSI.BOLD .. hdr_text ..
                    string.rep(" ", math.max(0, width - hdr_w - #ver_text)) ..
                    ANSI.FG_TITLE .. ver_text .. ANSI.RESET .. ANSI.EOL_CLEAR
    table.insert(lines, top_bar)

    -- Subtitle instruction
    local pos_str = string.format("%d/%d", selected_idx, #PROGRAMS)
    local sub_line = ANSI.FG_GRAY .. "  Select program with " .. ANSI.FG_CYAN .. "[↑/↓ or J/K]" ..
                     ANSI.FG_GRAY .. ", press " .. ANSI.FG_GREEN .. "[Enter]" ..
                     ANSI.FG_GRAY .. " to launch: " .. ANSI.FG_CYAN .. ANSI.BOLD ..
                     "(" .. pos_str .. ")" .. ANSI.RESET .. ANSI.EOL_CLEAR
    table.insert(lines, sub_line)

    -- Dimensions
    local avail_w = width - 4
    local left_w = math.max(40, math.floor(avail_w * 0.44))
    local right_w = avail_w - left_w - 2
    local box_h = math.max(10, height - 5)
    local max_visible = box_h - 2 -- top border + bottom border

    -- Adjust scroll offset
    if selected_idx <= scroll_offset then
        scroll_offset = selected_idx - 1
    elseif selected_idx > scroll_offset + max_visible then
        scroll_offset = selected_idx - max_visible
    end

    local left_rows = {}
    local right_rows = {}

    -- Build Left Rows (Programs)
    local left_title = string.format("┌── AVAILABLE PROGRAMS (%s) ", pos_str)
    local left_title_w = utf8_width(left_title)
    local left_top = ANSI.BORDER .. left_title ..
                     string.rep("─", math.max(0, left_w - left_title_w - 1)) ..
                     "┐" .. ANSI.RESET
    table.insert(left_rows, left_top)

    local end_i = math.min(#PROGRAMS, scroll_offset + max_visible)
    for i = scroll_offset + 1, end_i do
        local prog = PROGRAMS[i]
        local is_sel = (i == selected_idx)
        local exists = file_exists(prog.file)
        local badge_raw = exists and ("(" .. prog.category .. ")") or "(not found)"
        local badge = exists and
            (ANSI.FG_GREEN .. badge_raw .. ANSI.RESET) or
            (ANSI.FG_GRAY .. badge_raw .. ANSI.RESET)

        local prefix = is_sel and " ▶ " or "   "
        local prefix_w = 3
        local num_str = string.format("%2d. ", i)
        local inner_w = left_w - 2
        local avail_for_name = inner_w - prefix_w - #num_str - #badge_raw - 1
        local name_str = utf8_truncate(prog.name, math.max(4, avail_for_name), "..")

        local text_part = prefix .. num_str .. name_str
        local text_w = prefix_w + #num_str + utf8_width(name_str)
        local pad = math.max(1, inner_w - text_w - #badge_raw)
        local line_content = is_sel and
            (ANSI.FG_SEL .. ANSI.BOLD .. text_part .. string.rep(" ", pad) .. badge .. ANSI.RESET) or
            (ANSI.FG_WHITE .. text_part .. string.rep(" ", pad) .. badge .. ANSI.RESET)

        table.insert(left_rows, ANSI.BORDER .. "│" .. line_content .. ANSI.BORDER .. "│" .. ANSI.RESET)
    end

    -- Fill any remaining rows in left box
    while #left_rows < box_h - 1 do
        local is_last = (#left_rows == box_h - 2)
        if is_last and (scroll_offset > 0 or end_i < #PROGRAMS) then
            local hint = (scroll_offset > 0 and end_i < #PROGRAMS) and "▲ more | ▼ more" or
                         ((scroll_offset > 0) and "▲ more above" or
                         string.format("▼ %d more below", #PROGRAMS - end_i))
            local hpad = left_w - 2 - utf8_width(hint)
            local hl = math.floor(hpad / 2)
            local hr = hpad - hl
            local hint_line = string.rep(" ", math.max(0, hl)) ..
                              ANSI.FG_GRAY .. ANSI.DIM .. hint .. ANSI.RESET ..
                              string.rep(" ", math.max(0, hr))
            table.insert(left_rows, ANSI.BORDER .. "│" .. hint_line .. ANSI.BORDER .. "│" .. ANSI.RESET)
        else
            table.insert(left_rows, ANSI.BORDER .. "│" .. string.rep(" ", left_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)
        end
    end
    table.insert(left_rows, ANSI.BORDER .. "└──" .. string.rep("─", left_w - 4) .. "┘" .. ANSI.RESET)

    -- Build Right Rows (Details Box)
    local cur = PROGRAMS[selected_idx]
    local right_title = "┌── PROGRAM DETAILS "
    local right_title_w = utf8_width(right_title)
    local right_top = ANSI.BORDER .. right_title ..
                      string.rep("─", math.max(0, right_w - right_title_w - 1)) .. "┐" .. ANSI.RESET
    table.insert(right_rows, right_top)

    local function add_detail(label, val, val_color)
        val_color = val_color or ANSI.FG_WHITE
        local inner_w = right_w - 2
        local lbl_str = label ~= "" and (label .. ": ") or "  "
        local max_val_w = math.max(4, inner_w - #lbl_str - 1)
        local val_display = utf8_truncate(val, max_val_w, "...")
        local val_w = utf8_width(val_display)
        local pad = math.max(0, inner_w - #lbl_str - val_w)
        local row = ANSI.FG_CYAN .. lbl_str .. val_color .. val_display .. ANSI.RESET .. string.rep(" ", pad)
        table.insert(right_rows, ANSI.BORDER .. "│" .. row .. ANSI.BORDER .. "│" .. ANSI.RESET)
    end

    add_detail(" Name", cur.full_title, ANSI.FG_TITLE .. ANSI.BOLD)
    add_detail(" Script", cur.file, ANSI.FG_WHITE)
    add_detail(" Type", cur.type, ANSI.FG_GREEN)
    add_detail(" Backend", cur.backend, ANSI.FG_GRAY)
    table.insert(right_rows, ANSI.BORDER .. "│" .. string.rep(" ", right_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)

    local first = true
    for line in cur.desc:gmatch("[^\r\n]+") do
        local lbl = first and " Desc" or "     "
        first = false
        add_detail(lbl, line, ANSI.FG_WHITE)
    end

    table.insert(right_rows, ANSI.BORDER .. "│" .. string.rep(" ", right_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)
    add_detail(" Keys", cur.controls, ANSI.FG_YELLOW)

    while #right_rows < box_h - 1 do
        table.insert(right_rows, ANSI.BORDER .. "│" .. string.rep(" ", right_w - 2) .. ANSI.BORDER .. "│" .. ANSI.RESET)
    end
    table.insert(right_rows, ANSI.BORDER .. "└──" .. string.rep("─", right_w - 4) .. "┘" .. ANSI.RESET)

    -- Combine Columns
    for r = 1, box_h do
        local l_chunk = left_rows[r] or string.rep(" ", left_w)
        local r_chunk = right_rows[r] or string.rep(" ", right_w)
        table.insert(lines, "  " .. l_chunk .. " " .. r_chunk .. ANSI.EOL_CLEAR)
    end

    -- Footer
    local foot_text = "  [Enter] Launch Program    [↑/↓ or J/K] Navigate    [Q / Esc] Exit"
    table.insert(lines, ANSI.FG_GRAY .. ANSI.DIM .. foot_text .. ANSI.RESET .. ANSI.EOL_CLEAR)

    return table.concat(lines, "\n"), scroll_offset
end

--------------------------------------------------------------------------------
-- Compact Stacked Layout Renderer (for width < 90 or height < 18)
--------------------------------------------------------------------------------
local function render_compact(selected_idx, scroll_offset, width, height)
    local lines = {}
    local box_w = math.max(36, math.min(width - 4, 76))

    -- Header
    local hdr_text = "  ⚡ LUALAB LAUNCHER"
    local ver_text = "v1.2.1  "
    local hdr_w = utf8_width(hdr_text)
    local top_bar = ANSI.BG_HDR .. ANSI.FG_HDR .. ANSI.BOLD .. hdr_text ..
                    string.rep(" ", math.max(0, width - hdr_w - #ver_text)) ..
                    ANSI.FG_TITLE .. ver_text .. ANSI.RESET .. ANSI.EOL_CLEAR
    table.insert(lines, top_bar)

    -- Position line
    local pos_str = string.format("%d/%d", selected_idx, #PROGRAMS)
    local sub_line = ANSI.FG_GRAY .. "  Select: " .. ANSI.FG_CYAN .. "[↑/↓]" ..
                     ANSI.FG_GRAY .. "  Launch: " .. ANSI.FG_GREEN .. "[Enter]" ..
                     ANSI.FG_GRAY .. "  " .. ANSI.FG_CYAN .. ANSI.BOLD ..
                     "(" .. pos_str .. ")" .. ANSI.RESET .. ANSI.EOL_CLEAR
    table.insert(lines, sub_line)

    -- Room for programs
    local list_visible = math.max(3, math.min(5, height - 14))
    if selected_idx <= scroll_offset then
        scroll_offset = selected_idx - 1
    elseif selected_idx > scroll_offset + list_visible then
        scroll_offset = selected_idx - list_visible
    end

    -- Programs Box
    local top_title = string.format("┌── PROGRAMS (%s) ", pos_str)
    local top_title_w = utf8_width(top_title)
    local top_bdr = "  " .. ANSI.BORDER .. top_title ..
                    string.rep("─", math.max(0, box_w - top_title_w - 1)) ..
                    "┐" .. ANSI.RESET .. ANSI.EOL_CLEAR
    table.insert(lines, top_bdr)

    local end_i = math.min(#PROGRAMS, scroll_offset + list_visible)
    for i = scroll_offset + 1, end_i do
        local prog = PROGRAMS[i]
        local is_sel = (i == selected_idx)
        local exists = file_exists(prog.file)
        local badge_raw = exists and ("(" .. prog.category .. ")") or "(not found)"
        local badge = exists and
            (ANSI.FG_GREEN .. badge_raw .. ANSI.RESET) or
            (ANSI.FG_GRAY .. badge_raw .. ANSI.RESET)

        local prefix = is_sel and " ▶ " or "   "
        local prefix_w = 3
        local num_str = string.format("%2d. ", i)
        local file_str = "[" .. prog.file .. "]"
        local inner_w = box_w - 2
        local avail = inner_w - prefix_w - #num_str - #file_str - #badge_raw - 2
        local name_s = utf8_truncate(prog.name, math.max(4, avail), "..")
        local name_padded = name_s .. string.rep(" ", math.max(0, 16 - utf8_width(name_s)))

        local text_part = string.format("%s%s%s %s", prefix, num_str, name_padded, file_str)
        local text_w = prefix_w + #num_str + utf8_width(name_padded) + 1 + #file_str
        local pad = math.max(1, inner_w - text_w - #badge_raw)
        local line_content = is_sel and
            (ANSI.FG_SEL .. ANSI.BOLD .. text_part .. string.rep(" ", pad) .. badge .. ANSI.RESET) or
            (ANSI.FG_WHITE .. text_part .. string.rep(" ", pad) .. badge .. ANSI.RESET)

        table.insert(lines, "  " .. ANSI.BORDER .. "│" .. line_content .. ANSI.BORDER .. "│" .. ANSI.RESET .. ANSI.EOL_CLEAR)
    end

    local hint = (scroll_offset > 0 and end_i < #PROGRAMS) and "▲ more | ▼ more" or
                 ((scroll_offset > 0) and "▲ more above" or
                 ((end_i < #PROGRAMS) and string.format("▼ %d more below", #PROGRAMS - end_i) or ""))
    local hpad = box_w - 2 - utf8_width(hint)
    local hl = math.floor(hpad / 2)
    local hr = hpad - hl
    table.insert(lines, "  " .. ANSI.BORDER .. "│" .. string.rep(" ", math.max(0, hl)) ..
                        ANSI.FG_GRAY .. ANSI.DIM .. hint .. ANSI.RESET ..
                        string.rep(" ", math.max(0, hr)) .. ANSI.BORDER .. "│" .. ANSI.RESET .. ANSI.EOL_CLEAR)
    table.insert(lines, "  " .. ANSI.BORDER .. "└──" .. string.rep("─", math.max(0, box_w - 4)) .. "┘" .. ANSI.RESET .. ANSI.EOL_CLEAR)

    -- Details Box
    local cur = PROGRAMS[selected_idx]
    local det_title = "┌── DETAILS "
    local det_title_w = utf8_width(det_title)
    local det_bdr = "  " .. ANSI.BORDER .. det_title ..
                    string.rep("─", math.max(0, box_w - det_title_w - 1)) .. "┐" .. ANSI.RESET .. ANSI.EOL_CLEAR
    table.insert(lines, det_bdr)

    local function add_compact_detail(lbl, val, col)
        col = col or ANSI.FG_WHITE
        local inner_w = box_w - 2
        local prefix_str = " " .. ANSI.FG_CYAN .. lbl .. ": " .. col
        local max_v = math.max(4, inner_w - #lbl - 3)
        local v_str = utf8_truncate(val, max_v, "...")
        local v_w = utf8_width(v_str)
        local pad = math.max(0, inner_w - #lbl - 3 - v_w)
        local row = prefix_str .. v_str .. ANSI.RESET .. string.rep(" ", pad)
        table.insert(lines, "  " .. ANSI.BORDER .. "│" .. row .. ANSI.BORDER .. "│" .. ANSI.RESET .. ANSI.EOL_CLEAR)
    end

    add_compact_detail("Name", cur.full_title, ANSI.FG_TITLE .. ANSI.BOLD)
    add_compact_detail("Script", cur.file .. "  (" .. cur.type .. ")", ANSI.FG_WHITE)
    local first_desc = cur.desc:match("^[^\r\n]+") or cur.desc
    add_compact_detail("Desc", first_desc, ANSI.FG_GRAY)
    add_compact_detail("Keys", cur.controls, ANSI.FG_YELLOW)
    table.insert(lines, "  " .. ANSI.BORDER .. "└──" .. string.rep("─", math.max(0, box_w - 4)) .. "┘" .. ANSI.RESET .. ANSI.EOL_CLEAR)

    -- Footer
    table.insert(lines, ANSI.FG_GRAY .. ANSI.DIM .. "  [Enter] Launch   [↑/↓] Navigate   [Q] Exit" .. ANSI.RESET .. ANSI.EOL_CLEAR)

    return table.concat(lines, "\n"), scroll_offset
end

--------------------------------------------------------------------------------
-- Main Loop & Draw Coordinator
--------------------------------------------------------------------------------
local function run_menu(is_test)
    local selected_idx = 1
    local scroll_offset = 0

    local function render()
        local raw_w, h = get_term_size()
        local w = math.max(40, raw_w - 1)
        local frame_str
        if w >= 90 and h >= 18 then
            frame_str, scroll_offset = render_dual_pane(selected_idx, scroll_offset, w, h)
        else
            frame_str, scroll_offset = render_compact(selected_idx, scroll_offset, w, h)
        end
        io.write("\27[?2026h" .. ANSI.HOME .. frame_str .. "\27[?2026l")
        io.flush()
    end

    if is_test then
        local breakout_found = false
        for _, prog in ipairs(PROGRAMS) do
            if prog.id == "breakout" and prog.file == "ffi_breakout.lua" then
                breakout_found = file_exists(prog.file)
                break
            end
        end
        assert(breakout_found, "Breakout must be registered and its script must exist")

        local function strip_ansi(s)
            return s:gsub("\27%[[%d;?]*[A-Za-z]", "")
        end

        -- Verify every selection in dual-pane across standard and wide viewports
        for sel = 1, #PROGRAMS do
            local dual_out = render_dual_pane(sel, 0, 100, 30)
            assert(dual_out and #dual_out > 0)
            local row_idx = 0
            for row in dual_out:gmatch("[^\n]+") do
                row_idx = row_idx + 1
                assert(row:sub(-3) == ANSI.EOL_CLEAR, "Dual-pane row must end with \\27[K")
                if row_idx >= 3 and row_idx <= 27 then
                    local clean = strip_ansi(row)
                    assert(utf8_width(clean) == 97, "Dual-pane box row width mismatch: " .. tostring(utf8_width(clean)))
                end
            end
        end

        -- Verify compact mode across all items and small boundary dimensions
        for sel = 1, #PROGRAMS do
            local compact_out = render_compact(sel, 0, 80, 24)
            assert(compact_out and #compact_out > 0)
            local row_idx = 0
            for row in compact_out:gmatch("[^\n]+") do
                row_idx = row_idx + 1
                assert(row:sub(-3) == ANSI.EOL_CLEAR, "Compact row must end with \\27[K")
                if row_idx >= 3 and row_idx <= 16 then
                    local clean = strip_ansi(row)
                    assert(utf8_width(clean) == 78, "Compact box row width mismatch: " .. tostring(utf8_width(clean)))
                end
            end
            local narrow_out = render_compact(sel, 0, 44, 15)
            assert(narrow_out and #narrow_out > 0)
        end

        local tw, th = get_term_size()
        assert(type(tw) == "number" and tw >= 10, "Terminal width must be valid")
        assert(type(th) == "number" and th >= 10, "Terminal height must be valid")

        render()
        return { ok = true, programs_count = #PROGRAMS }
    end

    local running = true
    while running do
        render()
        local key = read_key(100)

        if key == "UP" or key == "k" then
            selected_idx = selected_idx - 1
            if selected_idx < 1 then
                selected_idx = #PROGRAMS
            end
        elseif key == "DOWN" or key == "j" then
            selected_idx = selected_idx + 1
            if selected_idx > #PROGRAMS then
                selected_idx = 1
            end
        elseif key == "q" or key == "ESC" then
            running = false
        elseif key == "ENTER" then
            local prog = PROGRAMS[selected_idx]
            if file_exists(prog.file) then
                restore_terminal()
                print("\n\27[38;2;100;240;130mLaunching " .. (prog.full_title or prog.name) .. "...\27[0m\n")
                local luajit_bin = (arg and arg[-1] and #arg[-1] > 0) and arg[-1] or "luajit"
                os.execute(string.format('"%s" %s', luajit_bin, prog.file))
                flush_input()
                print("\n\27[38;2;120;210;255m[Press any key to return to menu]\27[0m")
                init_terminal()
                read_key(5000)
                io.write("\27[2J\27[H")
                io.flush()
            else
                print("\n\27[38;2;255;70;70mError: " .. prog.file .. " not found!\27[0m\n")
            end
        end
    end

    return { ok = true }
end

--------------------------------------------------------------------------------
-- Entry Point
--------------------------------------------------------------------------------
local is_test = false
for i = 1, #arg do
    if arg[i] == "--test" then
        is_test = true
    end
end

if not is_test then
    init_terminal()
end

local ok, res = pcall(function()
    return run_menu(is_test)
end)

restore_terminal()

if not ok then
    io.stderr:write("Error: " .. tostring(res) .. "\n")
    os.exit(1)
end

if is_test then
    print("\n✓ menu.lua alignment verification passed across all items!")
end
