#!/usr/bin/env luajit
--[[
    ffi_chinese_chess.lua
    A complete, cross-platform Chinese Chess (Xiangqi / 中国象棋) engine and terminal game
    built entirely with LuaJIT FFI for both Windows and Linux.

    Features & FFI Highlights:
    1. Cross-Platform C Terminal Control:
       - Windows: Win32 Console API (GetStdHandle, GetConsoleMode, SetConsoleMode,
         SetConsoleOutputCP(65001 UTF-8), _kbhit, _getch, Sleep).
       - Linux/POSIX: termios (tcgetattr/tcsetattr raw mode), poll() non-blocking input,
         ioctl(TIOCGWINSZ), clock_gettime(CLOCK_MONOTONIC) microsecond timer, usleep().
    2. Zero-Overhead C Memory Data Structures:
       - Fixed-size 9x10 Xiangqi board in C struct array: BoardPoint[90].
       - Fast state snapshots, moves, and undo stacks.
    3. Complete Official Xiangqi (Chinese Chess) Rules:
       - General / King (帥/將): Palace bounded, step orthogonally, Flying General (飞将/对脸将).
       - Advisor (仕/士): Palace bounded, step diagonally.
       - Elephant (相/象): River bounded (cannot cross), 2-step diagonal, Blocked Elephant Eye (塞象眼).
       - Horse (傌/馬): "日" shape jump, Hobbled Horse Leg (蹩马腿).
       - Chariot (俥/車): Full orthogonal rank/file range.
       - Cannon (炮/砲): Moves like Chariot, captures by jumping over exactly 1 piece (mount / 炮架).
       - Soldier (兵/卒): Forward 1 step; after river can also move left/right (never backwards).
       - Check (将军), Checkmate (绝杀), and Stalemate (困毙为输).
       - Traditional Chinese Move Notation (e.g. 炮二平五, 馬8進7).
    4. Heuristic AI Engine:
       - Alpha-Beta Pruning with Negamax search.
       - Material + Piece-Square Tables (PST) positional evaluation.
       - MVV-LVA move ordering.
       - Play vs AI (PvE), 2-Player Pass-and-Play (PvP), or AI Demo (EvE).
    5. Clean Terminal UI:
       - Traditional Chinese piece glyphs with color styling.
       - Complete board grid with river (楚河汉界) and palace diagonals (九宫).
       - Interactive cursor selection with move destination previews.
       - Move history, captured pieces display, and evaluation bar.
       - Pure ASCII fallback mode (--ascii).
       - Headless snapshot (--snapshot) and test suite (--test).
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. Cross-Platform C Terminal & System Declarations
-- =========================================================================
local is_windows = (ffi.os == "Windows")

local enable_raw_mode
local disable_raw_mode
local read_key
local get_time_ms
local sleep_ms
local is_stdin_tty
local get_terminal_size

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
        int   __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int   __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int   __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int   __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        void  __stdcall Sleep(uint32_t dwMilliseconds);

        int _kbhit(void);
        int _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5

    local orig_in_mode = ffi.new("uint32_t[1]")
    local in_raw_mode  = false

    pcall(function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        ffi.C.SetConsoleOutputCP(65001)
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
            if w > 0 and h > 0 then return tonumber(w), tonumber(h) end
        end
        return 80, 25
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        if ffi.C.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end

        local ENABLE_LINE_INPUT = 0x0002
        local ENABLE_ECHO_INPUT = 0x0004
        local new_mode = bit.band(orig_in_mode[0], bit.bnot(bit.bor(ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT)))
        ffi.C.SetConsoleMode(hIn, new_mode)
        in_raw_mode = true

        io.write("\27[?1049h\27[?25l\27[2J\27[H")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            in_raw_mode = false
        end
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 0
        local elapsed = 0
        while timeout_ms <= 0 or elapsed <= timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                local ch = ffi.C._getch()
                if ch == 0 or ch == 224 then
                    local code = ffi.C._getch()
                    if code == 72 then return "UP"
                    elseif code == 80 then return "DOWN"
                    elseif code == 75 then return "LEFT"
                    elseif code == 77 then return "RIGHT"
                    end
                elseif ch == 27 then
                    return "ESC"
                elseif ch == 32 then
                    return "SPACE"
                elseif ch == 13 or ch == 10 then
                    return "ENTER"
                elseif ch == 3 then
                    return "CTRL_C"
                elseif ch >= 32 and ch <= 126 then
                    return string.char(ch):lower()
                end
            end
            if timeout_ms > 0 then
                ffi.C.Sleep(5)
                elapsed = elapsed + 5
            else
                break
            end
        end
        return nil
    end

    get_time_ms = function()
        return os.clock() * 1000.0
    end

    sleep_ms = function(ms)
        ffi.C.Sleep(ms)
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
        int  poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);

        typedef struct { long tv_sec; long tv_nsec; } timespec_t;
        int clock_gettime(int clk_id, timespec_t *tp);
        int usleep(unsigned int usec);
    ]]

    local TIOCGWINSZ   = 0x5413
    local STDIN_FILENO = 0
    local TCSANOW      = 0
    local ICANON       = 2
    local ECHO         = 8
    local POLLIN       = 1
    local CLOCK_MONOTONIC = 1

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")
    local in_raw_mode  = false

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if pcall(function() return ffi.C.ioctl(1, TIOCGWINSZ, ws) end) and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 80, 25
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        in_raw_mode = true

        io.write("\27[?1049h\27[?25l\27[2J\27[H")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            in_raw_mode = false
        end
    end

    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local key_buf = ffi.new("char[16]")

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 0
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 16)
            if n > 0 then
                local c0 = key_buf[0]
                if c0 == 27 then
                    if n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP"
                        elseif c2 == 66 then return "DOWN"
                        elseif c2 == 67 then return "RIGHT"
                        elseif c2 == 68 then return "LEFT"
                        end
                    end
                    return "ESC"
                elseif c0 == 32 then
                    return "SPACE"
                elseif c0 == 10 or c0 == 13 then
                    return "ENTER"
                elseif c0 == 3 then
                    return "CTRL_C"
                elseif c0 >= 32 and c0 <= 126 then
                    return string.char(c0):lower()
                end
            end
        end
        return nil
    end

    local ts = ffi.new("timespec_t")
    get_time_ms = function()
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) * 1000.0 + tonumber(ts.tv_nsec) / 1e6
    end

    sleep_ms = function(ms)
        ffi.C.usleep(ms * 1000)
    end
end

-- =========================================================================
-- 2. Board Constants, C Structs, and Piece Enums
-- =========================================================================
ffi.cdef[[
    typedef struct {
        uint8_t piece_type; // 0: empty, 1: General, 2: Advisor, 3: Elephant, 4: Horse, 5: Chariot, 6: Cannon, 7: Soldier
        uint8_t side;       // 0: empty, 1: Red, 2: Black
    } BoardPoint;
]]

local BOARD_FILES = 9
local BOARD_RANKS = 10
local TOTAL_POINTS = BOARD_FILES * BOARD_RANKS -- 90 points

local PIECE_EMPTY    = 0
local PIECE_GENERAL  = 1
local PIECE_ADVISOR  = 2
local PIECE_ELEPHANT = 3
local PIECE_HORSE    = 4
local PIECE_CHARIOT  = 5
local PIECE_CANNON   = 6
local PIECE_SOLDIER  = 7

local SIDE_EMPTY = 0
local SIDE_RED   = 1
local SIDE_BLACK = 2

local PIECE_CHARS = {
    unicode = {
        [SIDE_RED] = {
            [PIECE_GENERAL]  = "帥",
            [PIECE_ADVISOR]  = "仕",
            [PIECE_ELEPHANT] = "相",
            [PIECE_HORSE]    = "傌",
            [PIECE_CHARIOT]  = "俥",
            [PIECE_CANNON]   = "炮",
            [PIECE_SOLDIER]  = "兵",
        },
        [SIDE_BLACK] = {
            [PIECE_GENERAL]  = "將",
            [PIECE_ADVISOR]  = "士",
            [PIECE_ELEPHANT] = "象",
            [PIECE_HORSE]    = "馬",
            [PIECE_CHARIOT]  = "車",
            [PIECE_CANNON]   = "砲",
            [PIECE_SOLDIER]  = "卒",
        }
    },
    ascii = {
        [SIDE_RED] = {
            [PIECE_GENERAL]  = "RK",
            [PIECE_ADVISOR]  = "RA",
            [PIECE_ELEPHANT] = "RE",
            [PIECE_HORSE]    = "RN",
            [PIECE_CHARIOT]  = "RR",
            [PIECE_CANNON]   = "RC",
            [PIECE_SOLDIER]  = "RP",
        },
        [SIDE_BLACK] = {
            [PIECE_GENERAL]  = "BK",
            [PIECE_ADVISOR]  = "BA",
            [PIECE_ELEPHANT] = "BE",
            [PIECE_HORSE]    = "BN",
            [PIECE_CHARIOT]  = "BR",
            [PIECE_CANNON]   = "BC",
            [PIECE_SOLDIER]  = "BP",
        }
    }
}

local CHINESE_DIGITS = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十" }

-- =========================================================================
-- 3. Display Width & String Formatting Helpers
-- =========================================================================
local function utf8_visible_width(s)
    local clean = s:gsub("\27%[[0-9;]*[a-zA-Z]", "")
    local w = 0
    local i = 1
    local len = #clean
    while i <= len do
        local b1 = string.byte(clean, i)
        if b1 < 0x80 then
            w = w + 1
            i = i + 1
        elseif b1 < 0xE0 then
            w = w + 1
            i = i + 2
        elseif b1 < 0xF0 then
            local b2 = string.byte(clean, i + 1)
            local b3 = string.byte(clean, i + 2)
            local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
            if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0xFF01 and cp <= 0xFF60) then
                w = w + 2
            else
                w = w + 1
            end
            i = i + 3
        elseif b1 < 0xF8 then
            w = w + 2
            i = i + 4
        else
            i = i + 1
        end
    end
    return w
end

local function pad_right(s, target_w)
    local cur_w = utf8_visible_width(s)
    if cur_w < target_w then
        return s .. string.rep(" ", target_w - cur_w)
    end
    return s
end

-- =========================================================================
-- 4. Xiangqi Game Engine Class
-- =========================================================================
local XiangqiGame = {}
XiangqiGame.__index = XiangqiGame

function XiangqiGame.new(options)
    options = options or {}
    local self = setmetatable({}, XiangqiGame)

    self.ascii_mode = options.ascii_mode or false
    self.board = ffi.new("BoardPoint[?]", TOTAL_POINTS)

    self.turn = SIDE_RED
    self.round_number = 1
    self.move_history = {}
    self.captured_red = {}
    self.captured_black = {}

    self.cursor_x = 5
    self.cursor_y = 1
    self.selected_x = nil
    self.selected_y = nil

    self.game_mode = options.game_mode or "pve" -- "pve" (Player vs AI), "pvp" (2-Player), "eve" (AI vs AI)
    self.ai_side = options.ai_side or SIDE_BLACK
    self.ai_depth = options.ai_depth or 3

    self.game_over = false
    self.winner = nil -- SIDE_RED, SIDE_BLACK, or 0 (Draw)
    self.game_state_msg = "PLAYING"

    self.last_move = nil
    self.status_message = "Welcome to Chinese Chess!"

    self:reset()
    return self
end

function XiangqiGame:point_index(x, y)
    return (y - 1) * BOARD_FILES + (x - 1)
end

function XiangqiGame:get_point(x, y)
    if x < 1 or x > BOARD_FILES or y < 1 or y > BOARD_RANKS then
        return nil
    end
    return self.board[self:point_index(x, y)]
end

function XiangqiGame:set_point(x, y, piece_type, side)
    if x >= 1 and x <= BOARD_FILES and y >= 1 and y <= BOARD_RANKS then
        local p = self.board[self:point_index(x, y)]
        p.piece_type = piece_type
        p.side = side
    end
end

function XiangqiGame:reset()
    ffi.fill(self.board, ffi.sizeof("BoardPoint") * TOTAL_POINTS, 0)

    -- Red back rank (rank 1)
    local red_back = { PIECE_CHARIOT, PIECE_HORSE, PIECE_ELEPHANT, PIECE_ADVISOR, PIECE_GENERAL, PIECE_ADVISOR, PIECE_ELEPHANT, PIECE_HORSE, PIECE_CHARIOT }
    for x = 1, 9 do self:set_point(x, 1, red_back[x], SIDE_RED) end
    self:set_point(2, 3, PIECE_CANNON, SIDE_RED)
    self:set_point(8, 3, PIECE_CANNON, SIDE_RED)
    for x = 1, 9, 2 do self:set_point(x, 4, PIECE_SOLDIER, SIDE_RED) end

    -- Black back rank (rank 10)
    local black_back = { PIECE_CHARIOT, PIECE_HORSE, PIECE_ELEPHANT, PIECE_ADVISOR, PIECE_GENERAL, PIECE_ADVISOR, PIECE_ELEPHANT, PIECE_HORSE, PIECE_CHARIOT }
    for x = 1, 9 do self:set_point(x, 10, black_back[x], SIDE_BLACK) end
    self:set_point(2, 8, PIECE_CANNON, SIDE_BLACK)
    self:set_point(8, 8, PIECE_CANNON, SIDE_BLACK)
    for x = 1, 9, 2 do self:set_point(x, 7, PIECE_SOLDIER, SIDE_BLACK) end

    self.turn = SIDE_RED
    self.round_number = 1
    self.move_history = {}
    self.captured_red = {}
    self.captured_black = {}
    self.selected_x = nil
    self.selected_y = nil
    self.cursor_x = 5
    self.cursor_y = 1
    self.game_over = false
    self.winner = nil
    self.game_state_msg = "PLAYING"
    self.last_move = nil
    self.status_message = "Red to move. Select piece with Enter/Space."
end

-- =========================================================================
-- 5. Move Generation & Official Rule Enforcement
-- =========================================================================
function XiangqiGame:generate_piece_moves(x, y, moves_list)
    local p = self:get_point(x, y)
    if not p or p.piece_type == PIECE_EMPTY then return end
    local side = p.side
    local pt = p.piece_type

    if pt == PIECE_GENERAL then
        local y_min = (side == SIDE_RED) and 1 or 8
        local y_max = (side == SIDE_RED) and 3 or 10
        local offsets = { {1,0}, {-1,0}, {0,1}, {0,-1} }
        for _, off in ipairs(offsets) do
            local nx, ny = x + off[1], y + off[2]
            if nx >= 4 and nx <= 6 and ny >= y_min and ny <= y_max then
                local tp = self:get_point(nx, ny)
                if tp.side ~= side then
                    table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                end
            end
        end
    elseif pt == PIECE_ADVISOR then
        local y_min = (side == SIDE_RED) and 1 or 8
        local y_max = (side == SIDE_RED) and 3 or 10
        local diags = { {1,1}, {1,-1}, {-1,1}, {-1,-1} }
        for _, d in ipairs(diags) do
            local nx, ny = x + d[1], y + d[2]
            if nx >= 4 and nx <= 6 and ny >= y_min and ny <= y_max then
                local tp = self:get_point(nx, ny)
                if tp.side ~= side then
                    table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                end
            end
        end
    elseif pt == PIECE_ELEPHANT then
        local y_min = (side == SIDE_RED) and 1 or 6
        local y_max = (side == SIDE_RED) and 5 or 10
        local jumps = { {2,2}, {2,-2}, {-2,2}, {-2,-2} }
        for _, j in ipairs(jumps) do
            local nx, ny = x + j[1], y + j[2]
            if nx >= 1 and nx <= 9 and ny >= y_min and ny <= y_max then
                local eye = self:get_point(x + j[1]/2, y + j[2]/2)
                if eye.piece_type == PIECE_EMPTY then
                    local tp = self:get_point(nx, ny)
                    if tp.side ~= side then
                        table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                    end
                end
            end
        end
    elseif pt == PIECE_HORSE then
        local steps = {
            { dx = -1, dy = -2, lx = 0, ly = -1 },
            { dx =  1, dy = -2, lx = 0, ly = -1 },
            { dx = -1, dy =  2, lx = 0, ly =  1 },
            { dx =  1, dy =  2, lx = 0, ly =  1 },
            { dx = -2, dy = -1, lx = -1, ly = 0 },
            { dx = -2, dy =  1, lx = -1, ly = 0 },
            { dx =  2, dy = -1, lx =  1, ly = 0 },
            { dx =  2, dy =  1, lx =  1, ly = 0 },
        }
        for _, s in ipairs(steps) do
            local nx, ny = x + s.dx, y + s.dy
            if nx >= 1 and nx <= 9 and ny >= 1 and ny <= 10 then
                local leg = self:get_point(x + s.lx, y + s.ly)
                if leg.piece_type == PIECE_EMPTY then
                    local tp = self:get_point(nx, ny)
                    if tp.side ~= side then
                        table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                    end
                end
            end
        end
    elseif pt == PIECE_CHARIOT then
        local dirs = { {1,0}, {-1,0}, {0,1}, {0,-1} }
        for _, d in ipairs(dirs) do
            local nx, ny = x + d[1], y + d[2]
            while nx >= 1 and nx <= 9 and ny >= 1 and ny <= 10 do
                local tp = self:get_point(nx, ny)
                if tp.piece_type == PIECE_EMPTY then
                    table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                else
                    if tp.side ~= side then
                        table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                    end
                    break
                end
                nx = nx + d[1]
                ny = ny + d[2]
            end
        end
    elseif pt == PIECE_CANNON then
        local dirs = { {1,0}, {-1,0}, {0,1}, {0,-1} }
        for _, d in ipairs(dirs) do
            local nx, ny = x + d[1], y + d[2]
            local screen = false
            while nx >= 1 and nx <= 9 and ny >= 1 and ny <= 10 do
                local tp = self:get_point(nx, ny)
                if not screen then
                    if tp.piece_type == PIECE_EMPTY then
                        table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                    else
                        screen = true
                    end
                else
                    if tp.piece_type ~= PIECE_EMPTY then
                        if tp.side ~= side then
                            table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=ny})
                        end
                        break
                    end
                end
                nx = nx + d[1]
                ny = ny + d[2]
            end
        end
    elseif pt == PIECE_SOLDIER then
        local fwd_y = (side == SIDE_RED) and (y + 1) or (y - 1)
        if fwd_y >= 1 and fwd_y <= 10 then
            local tp = self:get_point(x, fwd_y)
            if tp.side ~= side then
                table.insert(moves_list, {from_x=x, from_y=y, to_x=x, to_y=fwd_y})
            end
        end
        local crossed = (side == SIDE_RED and y >= 6) or (side == SIDE_BLACK and y <= 5)
        if crossed then
            for _, dx in ipairs({-1, 1}) do
                local nx = x + dx
                if nx >= 1 and nx <= 9 then
                    local tp = self:get_point(nx, y)
                    if tp.side ~= side then
                        table.insert(moves_list, {from_x=x, from_y=y, to_x=nx, to_y=y})
                    end
                end
            end
        end
    end
end

function XiangqiGame:is_flying_generals()
    local rx, ry, bx, by
    for y = 1, 3 do
        for x = 4, 6 do
            local p = self:get_point(x, y)
            if p.piece_type == PIECE_GENERAL and p.side == SIDE_RED then
                rx, ry = x, y
                break
            end
        end
        if rx then break end
    end
    for y = 8, 10 do
        for x = 4, 6 do
            local p = self:get_point(x, y)
            if p.piece_type == PIECE_GENERAL and p.side == SIDE_BLACK then
                bx, by = x, y
                break
            end
        end
        if bx then break end
    end
    if not rx or not bx then return false end
    if rx ~= bx then return false end

    for y = ry + 1, by - 1 do
        local p = self:get_point(rx, y)
        if p.piece_type ~= PIECE_EMPTY then
            return false
        end
    end
    return true
end

function XiangqiGame:is_in_check(side)
    local gx, gy
    local enemy_side = (side == SIDE_RED) and SIDE_BLACK or SIDE_RED
    local y_min = (side == SIDE_RED) and 1 or 8
    local y_max = (side == SIDE_RED) and 3 or 10

    for y = y_min, y_max do
        for x = 4, 6 do
            local p = self:get_point(x, y)
            if p.piece_type == PIECE_GENERAL and p.side == side then
                gx, gy = x, y
                break
            end
        end
        if gx then break end
    end
    if not gx then return true end

    -- 1. Flying Generals check
    local step_y = (side == SIDE_RED) and 1 or -1
    local cur_y = gy + step_y
    while cur_y >= 1 and cur_y <= 10 do
        local p = self:get_point(gx, cur_y)
        if p.piece_type ~= PIECE_EMPTY then
            if p.piece_type == PIECE_GENERAL and p.side == enemy_side then
                return true
            end
            break
        end
        cur_y = cur_y + step_y
    end

    -- 2. Chariot and Cannon orthogonal ray checks
    local dirs = { {1,0}, {-1,0}, {0,1}, {0,-1} }
    for _, d in ipairs(dirs) do
        local cx, cy = gx + d[1], gy + d[2]
        local screen = false
        while cx >= 1 and cx <= 9 and cy >= 1 and cy <= 10 do
            local p = self:get_point(cx, cy)
            if p.piece_type ~= PIECE_EMPTY then
                if not screen then
                    if p.side == enemy_side and p.piece_type == PIECE_CHARIOT then
                        return true
                    end
                    screen = true
                else
                    if p.side == enemy_side and p.piece_type == PIECE_CANNON then
                        return true
                    end
                    break
                end
            end
            cx = cx + d[1]
            cy = cy + d[2]
        end
    end

    -- 3. Horse checks (8 reverse tests)
    local horse_steps = {
        { dx = -1, dy = -2, lx = 0, ly = -1 },
        { dx =  1, dy = -2, lx = 0, ly = -1 },
        { dx = -1, dy =  2, lx = 0, ly =  1 },
        { dx =  1, dy =  2, lx = 0, ly =  1 },
        { dx = -2, dy = -1, lx = -1, ly = 0 },
        { dx = -2, dy =  1, lx = -1, ly = 0 },
        { dx =  2, dy = -1, lx =  1, ly = 0 },
        { dx =  2, dy =  1, lx =  1, ly = 0 },
    }
    for _, h in ipairs(horse_steps) do
        local hx, hy = gx + h.dx, gy + h.dy
        if hx >= 1 and hx <= 9 and hy >= 1 and hy <= 10 then
            local p = self:get_point(hx, hy)
            if p.piece_type == PIECE_HORSE and p.side == enemy_side then
                local leg = self:get_point(gx + h.lx, gy + h.ly)
                if leg.piece_type == PIECE_EMPTY then
                    return true
                end
            end
        end
    end

    -- 4. Soldier checks
    local s_offsets
    if side == SIDE_RED then
        s_offsets = { {0, 1}, {-1, 0}, {1, 0} }
    else
        s_offsets = { {0, -1}, {-1, 0}, {1, 0} }
    end
    for _, off in ipairs(s_offsets) do
        local sx, sy = gx + off[1], gy + off[2]
        if sx >= 1 and sx <= 9 and sy >= 1 and sy <= 10 then
            local p = self:get_point(sx, sy)
            if p.piece_type == PIECE_SOLDIER and p.side == enemy_side then
                return true
            end
        end
    end

    return false
end

function XiangqiGame:get_legal_moves(side)
    local pseudo = {}
    for y = 1, 10 do
        for x = 1, 9 do
            local p = self:get_point(x, y)
            if p.side == side then
                self:generate_piece_moves(x, y, pseudo)
            end
        end
    end

    local legal = {}
    for _, m in ipairs(pseudo) do
        local from_p = self:get_point(m.from_x, m.from_y)
        local to_p   = self:get_point(m.to_x, m.to_y)
        local moving_type = from_p.piece_type
        local cap_type = to_p.piece_type
        local cap_side = to_p.side

        -- Tentatively make move
        self:set_point(m.to_x, m.to_y, moving_type, side)
        self:set_point(m.from_x, m.from_y, PIECE_EMPTY, SIDE_EMPTY)

        local check = self:is_in_check(side) or self:is_flying_generals()

        -- Revert move
        self:set_point(m.from_x, m.from_y, moving_type, side)
        self:set_point(m.to_x, m.to_y, cap_type, cap_side)

        if not check then
            m.captured_type = cap_type
            m.captured_side = cap_side
            m.piece_type = moving_type
            table.insert(legal, m)
        end
    end
    return legal
end

function XiangqiGame:get_legal_moves_for_piece(x, y)
    local all_moves = self:get_legal_moves(self.turn)
    local piece_moves = {}
    for _, m in ipairs(all_moves) do
        if m.from_x == x and m.from_y == y then
            table.insert(piece_moves, m)
        end
    end
    return piece_moves
end

-- =========================================================================
-- 6. Move Notation & History
-- =========================================================================
function XiangqiGame:move_to_notation(move)
    local p = self:get_point(move.from_x, move.from_y)
    local pt = p and p.piece_type or move.piece_type or PIECE_SOLDIER
    local side = p and p.side or move.side or self.turn

    if self.ascii_mode then
        local names = { "K", "A", "E", "H", "R", "C", "S" }
        local p_char = names[pt] or "?"
        local side_char = (side == SIDE_RED) and "R" or "B"
        return string.format("%s%s(%d,%d)-(%d,%d)", side_char, p_char, move.from_x, move.from_y, move.to_x, move.to_y)
    end

    local name = PIECE_CHARS.unicode[side][pt] or "?"
    if side == SIDE_RED then
        local f_from = 10 - move.from_x
        local f_to   = 10 - move.to_x
        local s_from = CHINESE_DIGITS[f_from] or tostring(f_from)
        local s_to, motion

        if move.to_y > move.from_y then
            motion = "進"
            if pt == PIECE_HORSE or pt == PIECE_ELEPHANT or pt == PIECE_ADVISOR then
                s_to = CHINESE_DIGITS[f_to]
            else
                local dist = move.to_y - move.from_y
                s_to = CHINESE_DIGITS[dist] or tostring(dist)
            end
        elseif move.to_y < move.from_y then
            motion = "退"
            if pt == PIECE_HORSE or pt == PIECE_ELEPHANT or pt == PIECE_ADVISOR then
                s_to = CHINESE_DIGITS[f_to]
            else
                local dist = move.from_y - move.to_y
                s_to = CHINESE_DIGITS[dist] or tostring(dist)
            end
        else
            motion = "平"
            s_to = CHINESE_DIGITS[f_to]
        end
        return string.format("%s%s%s%s", name, s_from, motion, s_to)
    else
        local f_from = move.from_x
        local f_to   = move.to_x
        local s_to, motion

        if move.to_y < move.from_y then
            motion = "進"
            if pt == PIECE_HORSE or pt == PIECE_ELEPHANT or pt == PIECE_ADVISOR then
                s_to = tostring(f_to)
            else
                local dist = move.from_y - move.to_y
                s_to = tostring(dist)
            end
        elseif move.to_y > move.from_y then
            motion = "退"
            if pt == PIECE_HORSE or pt == PIECE_ELEPHANT or pt == PIECE_ADVISOR then
                s_to = tostring(f_to)
            else
                local dist = move.to_y - move.from_y
                s_to = tostring(dist)
            end
        else
            motion = "平"
            s_to = tostring(f_to)
        end
        return string.format("%s%d%s%s", name, f_from, motion, s_to)
    end
end

function XiangqiGame:execute_move(move)
    local from_p = self:get_point(move.from_x, move.from_y)
    local to_p   = self:get_point(move.to_x, move.to_y)
    if not from_p or from_p.piece_type == PIECE_EMPTY then return false end

    local notation = self:move_to_notation(move)
    local cap_type = to_p.piece_type
    local cap_side = to_p.side

    if cap_type ~= PIECE_EMPTY then
        if cap_side == SIDE_RED then
            table.insert(self.captured_red, cap_type)
        else
            table.insert(self.captured_black, cap_type)
        end
    end

    table.insert(self.move_history, {
        from_x = move.from_x,
        from_y = move.from_y,
        to_x   = move.to_x,
        to_y   = move.to_y,
        piece_type = from_p.piece_type,
        side = from_p.side,
        captured_type = cap_type,
        captured_side = cap_side,
        notation = notation,
        round = self.round_number
    })

    self:set_point(move.to_x, move.to_y, from_p.piece_type, from_p.side)
    self:set_point(move.from_x, move.from_y, PIECE_EMPTY, SIDE_EMPTY)

    self.last_move = { from_x = move.from_x, from_y = move.from_y, to_x = move.to_x, to_y = move.to_y }
    self.selected_x = nil
    self.selected_y = nil

    -- Switch turn
    if self.turn == SIDE_BLACK then
        self.round_number = self.round_number + 1
        self.turn = SIDE_RED
    else
        self.turn = SIDE_BLACK
    end

    -- Check win/loss or check states
    local next_moves = self:get_legal_moves(self.turn)
    local in_check = self:is_in_check(self.turn)

    if #next_moves == 0 then
        self.game_over = true
        self.winner = (self.turn == SIDE_RED) and SIDE_BLACK or SIDE_RED
        local winner_str = (self.winner == SIDE_RED) and "RED WINS" or "BLACK WINS"
        if in_check then
            self.game_state_msg = string.format("CHECKMATE! %s", winner_str)
            self.status_message = string.format("Checkmate! %s wins the match!", (self.winner == SIDE_RED) and "Red" or "Black")
        else
            self.game_state_msg = string.format("STALEMATE! %s", winner_str)
            self.status_message = string.format("Stalemate (困毙)! %s has no legal moves.", (self.turn == SIDE_RED) and "Red" or "Black")
        end
    else
        if in_check then
            self.game_state_msg = (self.turn == SIDE_RED) and "RED IN CHECK!" or "BLACK IN CHECK!"
            self.status_message = string.format("Check! %s must defend General!", (self.turn == SIDE_RED) and "Red" or "Black")
        else
            self.game_state_msg = "PLAYING"
            self.status_message = string.format("%s to move (%s).",
                (self.turn == SIDE_RED) and "Red" or "Black",
                notation)
        end
    end

    return true
end

function XiangqiGame:undo_move()
    if #self.move_history == 0 then return false end
    local last = table.remove(self.move_history)

    self:set_point(last.from_x, last.from_y, last.piece_type, last.side)
    self:set_point(last.to_x, last.to_y, last.captured_type, last.captured_side)

    if last.captured_type ~= PIECE_EMPTY then
        if last.captured_side == SIDE_RED then
            table.remove(self.captured_red)
        else
            table.remove(self.captured_black)
        end
    end

    self.turn = last.side
    self.round_number = last.round
    self.game_over = false
    self.winner = nil
    self.game_state_msg = "PLAYING"

    local prev = self.move_history[#self.move_history]
    if prev then
        self.last_move = { from_x = prev.from_x, from_y = prev.from_y, to_x = prev.to_x, to_y = prev.to_y }
    else
        self.last_move = nil
    end

    self.selected_x = nil
    self.selected_y = nil
    self.status_message = string.format("Undid move: %s", last.notation)
    return true
end

-- =========================================================================
-- 7. Heuristic AI Engine (Negamax with Alpha-Beta Pruning)
-- =========================================================================
local PIECE_VALUES = {
    [PIECE_GENERAL]  = 10000,
    [PIECE_CHARIOT]  = 1000,
    [PIECE_CANNON]   = 450,
    [PIECE_HORSE]    = 420,
    [PIECE_ADVISOR]  = 200,
    [PIECE_ELEPHANT] = 200,
    [PIECE_SOLDIER]  = 100,
}

-- Positional Piece-Square Tables (PST) from Red's perspective
local HORSE_PST = {
    { 0, -5,  0,  0,  0,  0,  0, -5,  0 },
    { 0,  5, 10,  5,  5,  5, 10,  5,  0 },
    { 5, 15, 20, 25, 20, 25, 20, 15,  5 },
    { 5, 20, 30, 35, 30, 35, 30, 20,  5 },
    { 8, 25, 35, 40, 35, 40, 35, 25,  8 },
    { 8, 25, 35, 40, 35, 40, 35, 25,  8 },
    { 5, 20, 30, 35, 30, 35, 30, 20,  5 },
    { 5, 15, 20, 25, 20, 25, 20, 15,  5 },
    { 0,  5, 10,  5,  5,  5, 10,  5,  0 },
    { 0, -5,  0,  0,  0,  0,  0, -5,  0 },
}

local SOLDIER_PST = {
    {  0,  0,  0,  0,  0,  0,  0,  0,  0 },
    {  0,  0,  0,  0,  0,  0,  0,  0,  0 },
    {  0,  0,  0,  0,  0,  0,  0,  0,  0 },
    {  0,  0,  0,  5,  5,  5,  0,  0,  0 },
    { 10, 10, 20, 30, 30, 30, 20, 10, 10 },
    { 50, 70, 80, 90, 90, 90, 80, 70, 50 }, -- Cross river bonus
    { 60, 80, 90,100,100,100, 90, 80, 60 },
    { 70, 90,100,110,110,110,100, 90, 70 },
    { 80,100,110,120,120,120,110,100, 80 },
    { 10, 20, 30, 40, 40, 40, 30, 20, 10 }, -- Back rank pawn loses forward mobility
}

function XiangqiGame:evaluate_board()
    local red_val = 0
    local black_val = 0

    for y = 1, 10 do
        for x = 1, 9 do
            local p = self:get_point(x, y)
            if p.piece_type ~= PIECE_EMPTY then
                local base_val = PIECE_VALUES[p.piece_type] or 0
                local pos_val = 0

                if p.piece_type == PIECE_HORSE then
                    local py = (p.side == SIDE_RED) and y or (11 - y)
                    pos_val = HORSE_PST[py][x] or 0
                elseif p.piece_type == PIECE_SOLDIER then
                    local py = (p.side == SIDE_RED) and y or (11 - y)
                    pos_val = SOLDIER_PST[py][x] or 0
                elseif p.piece_type == PIECE_CHARIOT then
                    -- Bonus for advanced chariots
                    local py = (p.side == SIDE_RED) and y or (11 - y)
                    pos_val = py * 5
                end

                local total_item = base_val + pos_val
                if p.side == SIDE_RED then
                    red_val = red_val + total_item
                else
                    black_val = black_val + total_item
                end
            end
        end
    end

    -- Mobility bonus
    local red_moves = #self:get_legal_moves(SIDE_RED)
    local black_moves = #self:get_legal_moves(SIDE_BLACK)
    red_val = red_val + red_moves * 2
    black_val = black_val + black_moves * 2

    return red_val - black_val
end

function XiangqiGame:find_best_move(depth)
    depth = depth or self.ai_depth
    local current_side = self.turn
    local moves = self:get_legal_moves(current_side)
    if #moves == 0 then return nil end

    -- Move ordering: captures first (MVV-LVA)
    table.sort(moves, function(a, b)
        local va = (a.captured_type ~= PIECE_EMPTY) and (PIECE_VALUES[a.captured_type] * 10 - PIECE_VALUES[a.piece_type]) or 0
        local vb = (b.captured_type ~= PIECE_EMPTY) and (PIECE_VALUES[b.captured_type] * 10 - PIECE_VALUES[b.piece_type]) or 0
        return va > vb
    end)

    local best_move = moves[1]
    local alpha = -1e9
    local beta  = 1e9

    for _, m in ipairs(moves) do
        local from_p = self:get_point(m.from_x, m.from_y)
        local to_p   = self:get_point(m.to_x, m.to_y)
        local cap_type = to_p.piece_type
        local cap_side = to_p.side
        local moving_type = from_p.piece_type

        -- Make move
        self:set_point(m.to_x, m.to_y, moving_type, current_side)
        self:set_point(m.from_x, m.from_y, PIECE_EMPTY, SIDE_EMPTY)

        local enemy_side = (current_side == SIDE_RED) and SIDE_BLACK or SIDE_RED
        local score = -self:alpha_beta(depth - 1, -beta, -alpha, enemy_side)

        -- Undo move
        self:set_point(m.from_x, m.from_y, moving_type, current_side)
        self:set_point(m.to_x, m.to_y, cap_type, cap_side)

        if score > alpha then
            alpha = score
            best_move = m
        end
    end

    return best_move, alpha
end

function XiangqiGame:alpha_beta(depth, alpha, beta, side)
    if depth <= 0 then
        local eval = self:evaluate_board()
        return (side == SIDE_RED) and eval or -eval
    end

    local moves = self:get_legal_moves(side)
    if #moves == 0 then
        if self:is_in_check(side) then
            return -10000 - depth -- Prefer faster checkmates
        else
            return -8000 -- Stalemate loss
        end
    end

    table.sort(moves, function(a, b)
        local va = (a.captured_type ~= PIECE_EMPTY) and (PIECE_VALUES[a.captured_type] * 10 - PIECE_VALUES[a.piece_type]) or 0
        local vb = (b.captured_type ~= PIECE_EMPTY) and (PIECE_VALUES[b.captured_type] * 10 - PIECE_VALUES[b.piece_type]) or 0
        return va > vb
    end)

    local enemy_side = (side == SIDE_RED) and SIDE_BLACK or SIDE_RED
    for _, m in ipairs(moves) do
        local from_p = self:get_point(m.from_x, m.from_y)
        local to_p   = self:get_point(m.to_x, m.to_y)
        local cap_type = to_p.piece_type
        local cap_side = to_p.side
        local moving_type = from_p.piece_type

        self:set_point(m.to_x, m.to_y, moving_type, side)
        self:set_point(m.from_x, m.from_y, PIECE_EMPTY, SIDE_EMPTY)

        local score = -self:alpha_beta(depth - 1, -beta, -alpha, enemy_side)

        self:set_point(m.from_x, m.from_y, moving_type, side)
        self:set_point(m.to_x, m.to_y, cap_type, cap_side)

        if score >= beta then
            return beta
        end
        if score > alpha then
            alpha = score
        end
    end
    return alpha
end

-- =========================================================================
-- 8. Terminal UI Rendering & Layout (Exact 79 Columns)
-- =========================================================================
local UI = {
    unicode = {
        tl = "╔", tr = "╗", bl = "╚", br = "╝", hl = "═", vl = "║",
        b_tl = "┌", b_tr = "┐", b_bl = "└", b_br = "┘", b_hl = "─", b_vl = "│",
        grid_cross = "十",
        valid_dest = "● ",
    },
    ascii = {
        tl = "+", tr = "+", bl = "+", br = "+", hl = "=", vl = "|",
        b_tl = "+", b_tr = "+", b_bl = "+", b_br = "+", b_hl = "-", b_vl = "|",
        grid_cross = "++",
        valid_dest = "::",
    }
}

function XiangqiGame:render_frame()
    local U = self.ascii_mode and UI.ascii or UI.unicode
    local out = { "\27[H" }

    -- Header Banner (Exact width: 79 columns = 1 space + 1 corner + 77 hl + 1 corner)
    table.insert(out, " \27[1;36m" .. U.tl .. string.rep(U.hl, 77) .. U.tr .. "\27[0m\n")
    local title_str
    if self.ascii_mode then
        title_str = "                 CHINESE CHESS (XIANGQI) - LUAJIT FFI ENGINE                 "
    else
        title_str = "            🎮  CHINESE CHESS (中国象棋) - LUAJIT FFI ENGINE  🎮             "
    end
    table.insert(out, string.format(" \27[1;36m%s\27[1;33m%s\27[1;36m%s\27[0m\n", U.vl, title_str, U.vl))
    table.insert(out, " \27[1;36m" .. U.bl .. string.rep(U.hl, 77) .. U.br .. "\27[0m\n")

    -- Calculate valid destination set if a piece is selected
    local valid_map = {}
    if self.selected_x and self.selected_y then
        local moves = self:get_legal_moves_for_piece(self.selected_x, self.selected_y)
        for _, m in ipairs(moves) do
            valid_map[m.to_x .. ":" .. m.to_y] = true
        end
    end

    -- Build 21 rows for Xiangqi board (Exact width: 45 columns)
    local board_lines = {}

    -- Row 0: Top file numbers
    table.insert(board_lines, "      1   2   3   4   5   6   7   8   9      ")

    -- 10 ranks with 9 gap rows
    for r = 1, 10 do
        local rank_num = 11 - r
        local cells = {}

        for x = 1, 9 do
            local p = self:get_point(x, rank_num)
            local is_cursor = (x == self.cursor_x and rank_num == self.cursor_y)
            local is_selected = (x == self.selected_x and rank_num == self.selected_y)
            local is_target = valid_map[x .. ":" .. rank_num]
            local is_last = self.last_move and ((x == self.last_move.from_x and rank_num == self.last_move.from_y) or (x == self.last_move.to_x and rank_num == self.last_move.to_y))

            local token_str
            if p.piece_type ~= PIECE_EMPTY then
                local raw_char = self.ascii_mode
                    and PIECE_CHARS.ascii[p.side][p.piece_type]
                    or  PIECE_CHARS.unicode[p.side][p.piece_type]
                local color_code = (p.side == SIDE_RED) and "\27[1;31m" or "\27[1;36m"

                if is_selected then
                    token_str = string.format("\27[1;30;43m%s\27[0m", raw_char)
                elseif is_cursor then
                    token_str = string.format("\27[1;37;44m%s\27[0m", raw_char)
                elseif is_target then
                    token_str = string.format("\27[1;37;41m%s\27[0m", raw_char)
                elseif is_last then
                    token_str = string.format("\27[4m%s%s\27[0m", color_code, raw_char)
                else
                    token_str = string.format("%s%s\27[0m", color_code, raw_char)
                end
            else
                local empty_sym = self.ascii_mode and "++" or "十"
                if is_selected then
                    token_str = "\27[1;30;43m" .. empty_sym .. "\27[0m"
                elseif is_cursor then
                    token_str = "\27[1;37;44m" .. empty_sym .. "\27[0m"
                elseif is_target then
                    token_str = self.ascii_mode and "\27[1;32m::\27[0m" or "\27[1;32;7m十\27[0m"
                elseif is_last then
                    token_str = "\27[4;90m" .. empty_sym .. "\27[0m"
                else
                    token_str = "\27[90m" .. empty_sym .. "\27[0m"
                end
            end
            table.insert(cells, token_str)
        end

        local h_wire = self.ascii_mode and "--" or "──"
        local row_content = table.concat(cells, "\27[90m" .. h_wire .. "\27[0m")
        table.insert(board_lines, string.format(" %2d   %s   %2d", rank_num, row_content, rank_num))

        -- Add connecting lines between ranks
        if r == 1 then
            table.insert(board_lines, self.ascii_mode
                and "      |   |   |   | \\ | / |   |   |   |      "
                or  "      │   │   │   │ ╲ │ ╱ │   │   │   │      ")
        elseif r == 2 then
            table.insert(board_lines, self.ascii_mode
                and "      |   |   |   | / | \\ |   |   |   |      "
                or  "      │   │   │   │ ╱ │ ╲ │   │   │   │      ")
        elseif r == 3 or r == 4 then
            table.insert(board_lines, self.ascii_mode
                and "      |   |   |   |   |   |   |   |   |      "
                or  "      │   │   │   │   │   │   │   │   │      ")
        elseif r == 5 then
            table.insert(board_lines, self.ascii_mode
                and "      |   ~ CHU RIVER  HAN BORDER ~  |      "
                or  "      │      ～ 楚 河   漢 界 ～      │      ")
        elseif r == 6 or r == 7 then
            table.insert(board_lines, self.ascii_mode
                and "      |   |   |   |   |   |   |   |   |      "
                or  "      │   │   │   │   │   │   │   │   │      ")
        elseif r == 8 then
            table.insert(board_lines, self.ascii_mode
                and "      |   |   |   | \\ | / |   |   |   |      "
                or  "      │   │   │   │ ╲ │ ╱ │   │   │   │      ")
        elseif r == 9 then
            table.insert(board_lines, self.ascii_mode
                and "      |   |   |   | / | \\ |   |   |   |      "
                or  "      │   │   │   │ ╱ │ ╲ │   │   │   │      ")
        end
    end

    -- Row 20: Bottom file numbers
    if self.ascii_mode then
        table.insert(board_lines, "      9   8   7   6   5   4   3   2   1      ")
    else
        table.insert(board_lines, "      九  八  七  六  五  四  三  二  一     ")
    end

    -- Build 21 rows for Side Panel (Exact width: 32 columns)
    local panel_lines = {}
    local function make_panel_box(title, lines, color_ansi)
        color_ansi = color_ansi or "\27[1;37m"
        local inner_w = 30
        local t_len = utf8_visible_width(title)
        local top
        if t_len > 0 then
            top = string.format("%s%s%s %s %s%s\27[0m",
                color_ansi, U.b_tl, string.rep(U.b_hl, 2), title, string.rep(U.b_hl, inner_w - 4 - t_len), U.b_tr)
        else
            top = string.format("%s%s%s%s\27[0m", color_ansi, U.b_tl, string.rep(U.b_hl, inner_w), U.b_tr)
        end
        local bot = string.format("%s%s%s%s\27[0m", color_ansi, U.b_bl, string.rep(U.b_hl, inner_w), U.b_br)

        table.insert(panel_lines, top)
        for _, l in ipairs(lines) do
            local lw = utf8_visible_width(l)
            local pad = inner_w - lw - 1
            if pad < 0 then pad = 0 end
            table.insert(panel_lines, string.format("%s%s\27[0m %s%s%s%s\27[0m",
                color_ansi, U.b_vl, l, string.rep(" ", pad), color_ansi, U.b_vl))
        end
        table.insert(panel_lines, bot)
    end

    -- Box 1: Game Status (5 lines)
    local turn_color = (self.turn == SIDE_RED) and "\27[1;31m" or "\27[1;36m"
    local turn_name = self.ascii_mode
        and ((self.turn == SIDE_RED) and "RED" or "BLACK")
        or  ((self.turn == SIDE_RED) and "RED (红方)" or "BLACK (黑方)")
    local state_color = (self.game_state_msg:find("CHECK") or self.game_state_msg:find("STALEMATE")) and "\27[1;33;41m" or "\27[1;32m"
    local eval_val = self:evaluate_board()
    local eval_str = string.format("Eval: %s%+d\27[0m", (eval_val >= 0) and "\27[31m" or "\27[36m", eval_val)

    make_panel_box("STATUS", {
        string.format("Turn : %s%s\27[0m", turn_color, turn_name),
        string.format("State: %s %s \27[0m", state_color, self.game_state_msg),
        string.format("Round: #%-3d  %s", self.round_number, eval_str)
    }, "\27[1;33m")

    -- Box 2: Move History (6 lines)
    local hist_lines = {}
    local start_idx = math.max(1, #self.move_history - 3)
    for i = start_idx, #self.move_history do
        local m = self.move_history[i]
        local side_str = (m.side == SIDE_RED) and "\27[31mR\27[0m" or "\27[36mB\27[0m"
        table.insert(hist_lines, string.format("%s %2d. %-14s", side_str, m.round, m.notation))
    end
    while #hist_lines < 4 do
        table.insert(hist_lines, "\27[90m(no moves yet)\27[0m")
    end
    make_panel_box("MOVES", hist_lines, "\27[1;32m")

    -- Box 3: Captured Pieces (4 lines)
    local red_caps = {}
    for _, pt in ipairs(self.captured_red) do
        local sym = self.ascii_mode and PIECE_CHARS.ascii[SIDE_RED][pt] or PIECE_CHARS.unicode[SIDE_RED][pt]
        table.insert(red_caps, sym)
    end
    local black_caps = {}
    for _, pt in ipairs(self.captured_black) do
        local sym = self.ascii_mode and PIECE_CHARS.ascii[SIDE_BLACK][pt] or PIECE_CHARS.unicode[SIDE_BLACK][pt]
        table.insert(black_caps, sym)
    end
    make_panel_box("CAPTURED", {
        string.format("Red   : \27[1;31m%-18s\27[0m", table.concat(red_caps, " ")),
        string.format("Black : \27[1;36m%-18s\27[0m", table.concat(black_caps, " "))
    }, "\27[1;34m")

    -- Box 4: Controls Help (6 lines)
    make_panel_box("CONTROLS", {
        "WASD / Arrows : Move Cursor",
        "Enter / Space : Select / Move",
        "U : Undo      H : AI Hint",
        "R : Reset     Q : Quit"
    }, "\27[1;35m")

    -- Ensure panel has exactly 21 lines
    while #panel_lines < 21 do
        table.insert(panel_lines, string.rep(" ", 32))
    end

    -- Combine board and side panel side-by-side
    for i = 1, 21 do
        local b_line = board_lines[i] or string.rep(" ", 45)
        local p_line = panel_lines[i] or string.rep(" ", 32)
        table.insert(out, string.format(" %s  %s\n", pad_right(b_line, 45), pad_right(p_line, 32)))
    end

    -- Status Message Bar (width: 80 columns)
    local msg_bar = string.format(" \27[1;37;44m >> %s\27[0m\n", pad_right(self.status_message, 75))
    table.insert(out, msg_bar)

    return table.concat(out)
end

-- =========================================================================
-- 9. Interactive Game Loop & Autoplay Demo
-- =========================================================================
local function run_interactive_game(options)
    local game = XiangqiGame.new(options)
    local raw_ok = enable_raw_mode()
    if not raw_ok then
        print("\27[33mWarning: Standard input is not an interactive TTY; falling back.\27[0m")
    end

    local ok, err = pcall(function()
        while true do
            -- Render frame
            io.write(game:render_frame())
            io.flush()

            -- Check AI turn in PvE mode
            if not game.game_over and game.game_mode == "pve" and game.turn == game.ai_side then
                game.status_message = "AI is calculating best move..."
                io.write(game:render_frame())
                io.flush()

                local best_m = game:find_best_move(game.ai_depth)
                if best_m then
                    game:execute_move(best_m)
                else
                    game.game_over = true
                end
            else
                -- Human player input
                local key = read_key(50)
                if key == "q" or key == "CTRL_C" then
                    break
                elseif key == "r" then
                    game:reset()
                elseif key == "u" then
                    game:undo_move()
                    if game.game_mode == "pve" and #game.move_history > 0 then
                        game:undo_move() -- Undo AI move as well
                    end
                elseif key == "h" then
                    local hint_m = game:find_best_move(game.ai_depth)
                    if hint_m then
                        local notat = game:move_to_notation(hint_m)
                        game.status_message = string.format("AI Hint: %s (%d,%d to %d,%d)", notat, hint_m.from_x, hint_m.from_y, hint_m.to_x, hint_m.to_y)
                    end
                elseif key == "m" then
                    game.game_mode = (game.game_mode == "pve") and "pvp" or "pve"
                    game.status_message = string.format("Switched mode to %s", (game.game_mode == "pve") and "Player vs AI" or "2-Player Pass-and-Play")
                elseif key == "UP" or key == "w" or key == "k" then
                    if game.cursor_y < 10 then game.cursor_y = game.cursor_y + 1 end
                elseif key == "DOWN" or key == "s" or key == "j" then
                    if game.cursor_y > 1 then game.cursor_y = game.cursor_y - 1 end
                elseif key == "LEFT" or key == "a" or key == "h_key" then
                    if game.cursor_x > 1 then game.cursor_x = game.cursor_x - 1 end
                elseif key == "RIGHT" or key == "d" or key == "l" then
                    if game.cursor_x < 9 then game.cursor_x = game.cursor_x + 1 end
                elseif key == "ESC" then
                    game.selected_x = nil
                    game.selected_y = nil
                    game.status_message = "Selection canceled."
                elseif key == "ENTER" or key == "SPACE" then
                    local cur_p = game:get_point(game.cursor_x, game.cursor_y)
                    if not game.selected_x then
                        if cur_p and cur_p.piece_type ~= PIECE_EMPTY and cur_p.side == game.turn then
                            game.selected_x = game.cursor_x
                            game.selected_y = game.cursor_y
                            local moves = game:get_legal_moves_for_piece(game.cursor_x, game.cursor_y)
                            game.status_message = string.format("Selected %s. %d valid moves.",
                                PIECE_CHARS.unicode[cur_p.side][cur_p.piece_type], #moves)
                        else
                            game.status_message = "Please select a friendly piece."
                        end
                    else
                        -- Attempt to move to cursor
                        if game.cursor_x == game.selected_x and game.cursor_y == game.selected_y then
                            game.selected_x = nil
                            game.selected_y = nil
                            game.status_message = "Selection canceled."
                        elseif cur_p and cur_p.side == game.turn then
                            -- Switch selection to another friendly piece
                            game.selected_x = game.cursor_x
                            game.selected_y = game.cursor_y
                            local moves = game:get_legal_moves_for_piece(game.cursor_x, game.cursor_y)
                            game.status_message = string.format("Switched selection to %s. %d valid moves.",
                                PIECE_CHARS.unicode[cur_p.side][cur_p.piece_type], #moves)
                        else
                            local moves = game:get_legal_moves_for_piece(game.selected_x, game.selected_y)
                            local target_move = nil
                            for _, m in ipairs(moves) do
                                if m.to_x == game.cursor_x and m.to_y == game.cursor_y then
                                    target_move = m
                                    break
                                end
                            end
                            if target_move then
                                game:execute_move(target_move)
                            else
                                game.status_message = "Invalid destination for selected piece!"
                            end
                        end
                    end
                end
            end
            sleep_ms(15)
        end
    end)

    disable_raw_mode()
    if not ok then
        io.stderr:write("\n\27[31mFatal error in game loop:\27[0m " .. tostring(err) .. "\n")
    else
        print("\n\27[1;32mThanks for playing Chinese Chess (Xiangqi)!\27[0m\n")
    end
end

-- Automated AI vs AI Demonstration Mode
local function run_ai_demo(max_moves, options)
    options = options or {}
    options.game_mode = "eve"
    local game = XiangqiGame.new(options)
    max_moves = max_moves or 30

    local raw_ok = enable_raw_mode()
    local move_count = 0

    local ok, err = pcall(function()
        while move_count < max_moves and not game.game_over do
            local key = read_key(0)
            if key == "q" or key == "CTRL_C" or key == "ESC" then break end

            io.write(game:render_frame())
            io.flush()

            local best_m = game:find_best_move(options.depth or 2)
            if not best_m then break end

            game:execute_move(best_m)
            move_count = move_count + 1
            sleep_ms(options.delay or 150)
        end
        io.write(game:render_frame())
        io.flush()
    end)

    disable_raw_mode()
    if not ok then
        io.stderr:write("\nError in demo: " .. tostring(err) .. "\n")
    end
    print(string.format("\n[AI Demo Complete] Moves played: %d, Result: %s\n",
        move_count, game.game_state_msg))
end

-- =========================================================================
-- 10. Self-Test Suite (--test)
-- =========================================================================
local function run_self_tests()
    print("=== Running Self-Tests for Chinese Chess (LuaJIT FFI) ===")
    local passed = 0
    local total = 0

    local function check(name, cond)
        total = total + 1
        if cond then
            passed = passed + 1
            print(string.format("  \27[32m✔ PASS\27[0m: %s", name))
        else
            print(string.format("  \27[31m✘ FAIL\27[0m: %s", name))
        end
    end

    -- 1. Struct size
    check("BoardPoint struct size is 2 bytes", ffi.sizeof("BoardPoint") == 2)

    -- 2. Board initialization
    local g = XiangqiGame.new()
    check("Red General placed at (5, 1)", g:get_point(5, 1).piece_type == PIECE_GENERAL and g:get_point(5, 1).side == SIDE_RED)
    check("Black General placed at (5, 10)", g:get_point(5, 10).piece_type == PIECE_GENERAL and g:get_point(5, 10).side == SIDE_BLACK)
    check("Initial turn is Red", g.turn == SIDE_RED)

    -- 3. Initial move count
    local red_moves = g:get_legal_moves(SIDE_RED)
    check("Initial Red legal moves count is exactly 44", #red_moves == 44)

    -- 4. Flying Generals detection
    g:reset()
    ffi.fill(g.board, ffi.sizeof("BoardPoint") * TOTAL_POINTS, 0)
    g:set_point(5, 1, PIECE_GENERAL, SIDE_RED)
    g:set_point(5, 10, PIECE_GENERAL, SIDE_BLACK)
    check("Directly facing Generals detected as Flying Generals", g:is_flying_generals() == true)
    g:set_point(5, 5, PIECE_SOLDIER, SIDE_RED)
    check("Obstacle blocks Flying Generals condition", g:is_flying_generals() == false)

    -- 5. Horse hobbling (蹩马腿)
    g:reset()
    ffi.fill(g.board, ffi.sizeof("BoardPoint") * TOTAL_POINTS, 0)
    g:set_point(5, 5, PIECE_HORSE, SIDE_RED)
    g:set_point(5, 1, PIECE_GENERAL, SIDE_RED)
    g:set_point(4, 10, PIECE_GENERAL, SIDE_BLACK) -- Not on column 5
    local unhobbled_moves = g:get_legal_moves_for_piece(5, 5)
    check("Free horse in center has 8 legal jumps", #unhobbled_moves == 8)
    g:set_point(5, 6, PIECE_SOLDIER, SIDE_RED) -- Hobble upward jump
    local hobbled_moves = g:get_legal_moves_for_piece(5, 5)
    check("Hobbled horse loses 2 upward jumps (6 moves left)", #hobbled_moves == 6)

    -- 6. Elephant eye blocking (塞象眼)
    g:reset()
    ffi.fill(g.board, ffi.sizeof("BoardPoint") * TOTAL_POINTS, 0)
    g:set_point(3, 1, PIECE_ELEPHANT, SIDE_RED)
    g:set_point(5, 1, PIECE_GENERAL, SIDE_RED)
    g:set_point(4, 10, PIECE_GENERAL, SIDE_BLACK) -- Not on column 5
    local free_elephant = g:get_legal_moves_for_piece(3, 1)
    check("Free elephant has 2 valid jumps inside territory", #free_elephant == 2)
    g:set_point(4, 2, PIECE_SOLDIER, SIDE_RED) -- Block eye to (5, 3)
    local blocked_elephant = g:get_legal_moves_for_piece(3, 1)
    check("Blocked elephant eye prevents jump (1 move left)", #blocked_elephant == 1)

    -- 7. Cannon screen mechanics (炮架)
    g:reset()
    ffi.fill(g.board, ffi.sizeof("BoardPoint") * TOTAL_POINTS, 0)
    g:set_point(2, 5, PIECE_CANNON, SIDE_RED)
    g:set_point(5, 1, PIECE_GENERAL, SIDE_RED)
    g:set_point(4, 10, PIECE_GENERAL, SIDE_BLACK) -- Not on column 5
    g:set_point(2, 7, PIECE_SOLDIER, SIDE_BLACK) -- Screen
    g:set_point(2, 9, PIECE_CHARIOT, SIDE_BLACK) -- Capture target
    local cannon_moves = g:get_legal_moves_for_piece(2, 5)
    local can_capture_chariot = false
    for _, m in ipairs(cannon_moves) do
        if m.to_x == 2 and m.to_y == 9 then can_capture_chariot = true end
    end
    check("Cannon can capture enemy piece across 1 screen", can_capture_chariot)

    -- 8. Check and checkmate
    g:reset()
    ffi.fill(g.board, ffi.sizeof("BoardPoint") * TOTAL_POINTS, 0)
    g:set_point(5, 1, PIECE_GENERAL, SIDE_RED)
    g:set_point(5, 10, PIECE_GENERAL, SIDE_BLACK)
    g:set_point(5, 8, PIECE_CHARIOT, SIDE_RED)
    check("Chariot attacks General: Black is in check", g:is_in_check(SIDE_BLACK) == true)

    -- 9. Traditional notation generation
    g:reset()
    local notat = g:move_to_notation({from_x=8, from_y=3, to_x=5, to_y=3, piece_type=PIECE_CANNON, side=SIDE_RED})
    check("Red central cannon notation matches '炮二平五'", notat == "炮二平五")

    -- 10. AI best move generation
    g:reset()
    local best_m, score = g:find_best_move(2)
    check("AI evaluates and returns valid opening move", best_m ~= nil and score ~= nil)

    -- 11. Layout width uniformity (80 columns in Unicode and ASCII)
    local function check_layout_uniformity(game_inst)
        local frame_str = game_inst:render_frame()
        for line in frame_str:gmatch("([^\r\n]+)") do
            local w = utf8_visible_width(line)
            if w > 0 and w ~= 80 then return false end
        end
        return true
    end
    check("Terminal UI layout width is uniformly 80 columns in Unicode", check_layout_uniformity(g))
    local g_ascii = XiangqiGame.new({ ascii_mode = true })
    check("Terminal UI layout width is uniformly 80 columns in ASCII", check_layout_uniformity(g_ascii))

    print(string.format("\nSelf-Test Summary: %d / %d tests passed.", passed, total))
    if passed == total then
        print("\27[1;32mALL CHINESE CHESS TESTS PASSED SUCCESSFULLY!\27[0m\n")
        return true
    else
        print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
        return false
    end
end

-- =========================================================================
-- 11. Module Exports & Command Line Dispatcher
-- =========================================================================
local function print_help()
    print([[
Chinese Chess (Xiangqi / 中国象棋) - LuaJIT FFI Cross-Platform Engine

Usage:
    luajit ffi_chinese_chess.lua [options]

Options:
    --help, -h          Show this help message and exit
    --test              Run internal automated unit tests and exit
    --snapshot          Render a single frame snapshot to stdout and exit
    --demo [moves]      Run automated AI vs AI demonstration (default: 30 moves)
    --ascii             Run in plain ASCII mode (no Chinese characters or Unicode)
    --pvp, --two-player 2-Player local pass-and-play mode (default: vs AI)

Interactive Controls:
    Arrow Keys / WASD   Move cursor across the board
    Enter / Spacebar    Select piece / Confirm destination move
    Escape              Deselect piece
    U                   Undo move
    H                   Request AI hint for current turn
    R                   Restart new game
    M                   Toggle mode (vs AI / 2-Player)
    Q / Ctrl+C          Quit game

Platform Support:
    Windows (Win32 Console API, MSVCRT non-blocking IO, UTF-8 VT processing)
    Linux / POSIX (termios raw mode, poll() non-blocking IO, CLOCK_MONOTONIC)
]])
end

local is_main = (debug.getinfo(3) == nil)

if is_main then
    local arg1 = arg and arg[1] or ""
    local options = {}

    for _, a in ipairs(arg or {}) do
        if a == "--ascii" then
            options.ascii_mode = true
        elseif a == "--pvp" or a == "--two-player" then
            options.game_mode = "pvp"
        end
    end

    if arg1 == "--help" or arg1 == "-h" then
        print_help()
        os.exit(0)
    elseif arg1 == "--test" then
        local success = run_self_tests()
        os.exit(success and 0 or 1)
    elseif arg1 == "--snapshot" then
        local game = XiangqiGame.new(options)
        print(game:render_frame())
        os.exit(0)
    elseif arg1 == "--demo" then
        local moves = tonumber(arg and arg[2]) or 30
        run_ai_demo(moves, options)
        os.exit(0)
    else
        run_interactive_game(options)
    end
end

return {
    XiangqiGame = XiangqiGame,
    PIECE_EMPTY = PIECE_EMPTY,
    PIECE_GENERAL = PIECE_GENERAL,
    PIECE_ADVISOR = PIECE_ADVISOR,
    PIECE_ELEPHANT = PIECE_ELEPHANT,
    PIECE_HORSE = PIECE_HORSE,
    PIECE_CHARIOT = PIECE_CHARIOT,
    PIECE_CANNON = PIECE_CANNON,
    PIECE_SOLDIER = PIECE_SOLDIER,
    SIDE_EMPTY = SIDE_EMPTY,
    SIDE_RED = SIDE_RED,
    SIDE_BLACK = SIDE_BLACK,
    utf8_visible_width = utf8_visible_width,
    run_self_tests = run_self_tests
}
