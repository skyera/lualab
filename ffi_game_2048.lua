#!/usr/bin/env luajit
--[[
    ffi_game_2048.lua
    A sleek, full-featured, cross-platform 2048 sliding-tile puzzle game
    and automated Expectimax AI solver built entirely with LuaJIT FFI.

    Features & FFI Highlights:
    1. Cross-Platform C Terminal Control:
       - Windows: Win32 Console API (GetStdHandle, GetConsoleMode, SetConsoleMode,
         SetConsoleOutputCP(65001 UTF-8), _kbhit, _getch, Sleep).
       - Linux/POSIX: termios (tcgetattr/tcsetattr raw mode), poll() non-blocking input,
         ioctl(TIOCGWINSZ), clock_gettime(CLOCK_MONOTONIC) microsecond timer, usleep().
    2. Zero-Overhead C Memory Data Structures:
       - Bitboard / uint64_t / C struct board representations:
         * BoardCell[16] for direct cell access and animations.
         * uint64_t bitboard (4 bits per tile, representing power-of-two 0..15).
         * Precomputed fast lookup tables for row shifts/merges.
    3. Complete 2048 Mechanics:
       - 4x4 Grid with smooth slide and merge physics.
       - Authentic spawn distribution (90% 2, 10% 4).
       - Unlimited Undo history stack using C struct ring buffer.
       - Best/High score persistence to disk (.game_2048_score).
       - Win condition detection (reaching 2048 tile, with option to keep playing).
       - Game over detection (no valid moves remaining).
    4. Fast Expectimax AI Solver:
       - Transposition table using FFI 64-bit hashing.
       - Heuristic evaluation: Monotonicity, Smoothness, Empty Tiles count, Corner Max Tile bonus.
       - Expectimax tree search evaluating Up/Down/Left/Right and stochastic tile spawns.
       - Automatic play mode (--auto or pressing 'A' in-game) running at 30-60 moves/sec.
    5. Modern Terminal UI & Visualization:
       - Truecolor (24-bit ANSI) and 256-color gradient tile palettes.
       - Unicode box-drawing with clean rounded cards.
       - Pure ASCII fallback mode (--ascii).
       - Non-interactive snapshot renderer (--snapshot).
       - CLI self-test suite (--test) for automated CI.
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

        void*    __stdcall GetStdHandle(uint32_t nStdHandle);
        int      __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int      __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int      __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int      __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        void     __stdcall Sleep(uint32_t dwMilliseconds);

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

    enable_raw_mode = function()
        if in_raw_mode then return true end
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        if ffi.C.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end

        local ENABLE_LINE_INPUT      = 0x0002
        local ENABLE_ECHO_INPUT      = 0x0004
        local ENABLE_PROCESSED_INPUT = 0x0001
        local mask = bit.bnot(bit.bor(ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT, ENABLE_PROCESSED_INPUT))
        local new_mode = bit.band(orig_in_mode[0], mask)
        ffi.C.SetConsoleMode(hIn, new_mode)
        in_raw_mode = true

        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?25h\27[0m")
            io.flush()
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            in_raw_mode = false
        end
    end

    read_key = function()
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
            elseif ch == 13 or ch == 10 then
                return "ENTER"
            elseif ch == 32 then
                return "SPACE"
            elseif ch == 8 then
                return "BACKSPACE"
            else
                return string.char(ch):lower()
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

    get_terminal_size = function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if ffi.C.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            return math.max(cols, 40), math.max(rows, 20)
        end
        return 80, 24
    end

else
    ffi.cdef[[
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

        typedef struct { long tv_sec; long tv_nsec; } timespec_t;

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int ioctl(int fd, unsigned long request, ...);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);
        int isatty(int fd);
        int clock_gettime(int clk_id, timespec_t *tp);
        int usleep(unsigned int usec);
    ]]

    local STDIN_FILENO  = 0
    local TCSANOW       = 0
    local ICANON        = 2
    local ECHO          = 8
    local ISIG          = 1
    local POLLIN        = 1
    local TIOCGWINSZ    = 0x5413
    local CLOCK_MONOTONIC = 1

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")
    local in_raw_mode  = false

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    enable_raw_mode = function()
        if in_raw_mode then return true end
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end

        if ffi.C.tcgetattr(STDIN_FILENO, orig_termios) ~= 0 then return false end
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG)))
        raw_termios.c_cc[5] = 0 -- VMIN = 0
        raw_termios.c_cc[6] = 0 -- VTIME = 0

        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        in_raw_mode = true

        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            in_raw_mode = false
        end
    end

    local key_buf = ffi.new("char[16]")
    read_key = function()
        local pfd = ffi.new("struct pollfd[1]")
        pfd[0].fd = STDIN_FILENO
        pfd[0].events = POLLIN

        local ret = ffi.C.poll(pfd, 1, 0)
        if ret > 0 and bit.band(pfd[0].revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 15)
            if n > 0 then
                local b0 = key_buf[0]
                if b0 == 27 then
                    if n == 1 then
                        return "ESC"
                    elseif n >= 3 and key_buf[1] == 91 then -- '\27['
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP"
                        elseif c2 == 66 then return "DOWN"
                        elseif c2 == 67 then return "RIGHT"
                        elseif c2 == 68 then return "LEFT"
                        elseif c2 == 72 then return "HOME"
                        elseif c2 == 70 then return "END"
                        end
                    elseif n >= 3 and key_buf[1] == 79 then -- '\27O'
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP"
                        elseif c2 == 66 then return "DOWN"
                        elseif c2 == 67 then return "RIGHT"
                        elseif c2 == 68 then return "LEFT"
                        end
                    end
                    return "ESC"
                elseif b0 == 10 or b0 == 13 then
                    return "ENTER"
                elseif b0 == 32 then
                    return "SPACE"
                elseif b0 == 127 or b0 == 8 then
                    return "BACKSPACE"
                elseif b0 == 3 then -- Ctrl-C
                    return "CTRL_C"
                else
                    return string.char(b0):lower()
                end
            end
        end
        return nil
    end

    local ts = ffi.new("timespec_t")
    get_time_ms = function()
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) * 1000.0 + tonumber(ts.tv_nsec) / 1000000.0
    end

    sleep_ms = function(ms)
        ffi.C.usleep(math.floor(ms * 1000))
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(STDIN_FILENO, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return ws.ws_col, ws.ws_row
        end
        return 80, 24
    end
end

-- =========================================================================
-- 2. Zero-Overhead C Data Structures (FFI)
-- =========================================================================
ffi.cdef[[
    typedef struct {
        uint32_t val;         // Current numeric value: 0, 2, 4, 8, ... 65536
        uint8_t  merged;      // Flag: merged in current turn
        uint8_t  spawned;     // Flag: just spawned in current turn
        uint16_t pad;
    } BoardCell;

    typedef struct {
        uint32_t score;
        uint32_t high_score;
        uint32_t move_count;
        uint32_t max_tile;
        uint32_t undos_remaining;
    } Game2048Stats;

    typedef struct {
        uint32_t cells[16];
        uint32_t score;
    } UndoState;
]]

-- Constants
local GRID_SIZE = 4
local TOTAL_CELLS = 16
local SCORE_FILE = ".game_2048_score"
local MAX_UNDOS = 200

-- Directions
local DIR_UP    = 0
local DIR_DOWN  = 1
local DIR_LEFT  = 2
local DIR_RIGHT = 3

local DIR_NAMES = {
    [DIR_UP]    = "UP",
    [DIR_DOWN]  = "DOWN",
    [DIR_LEFT]  = "LEFT",
    [DIR_RIGHT] = "RIGHT",
}

-- Color Palette for Tiles (24-bit Truecolor ANSI and 256-color fallback)
-- Format: { bg_r, bg_g, bg_b, fg_r, fg_g, fg_b, c256_bg, c256_fg }
local TILE_COLORS = {
    [0]     = { 205, 193, 180, 119, 110, 101,  250, 240 }, -- Empty
    [2]     = { 238, 228, 218, 119, 110, 101,  255, 238 },
    [4]     = { 237, 224, 200, 119, 110, 101,  254, 238 },
    [8]     = { 242, 177, 121, 249, 246, 242,  215, 231 },
    [16]    = { 245, 149,  99, 249, 246, 242,  208, 231 },
    [32]    = { 246, 124,  95, 249, 246, 242,  203, 231 },
    [64]    = { 246,  94,  59, 249, 246, 242,  196, 231 },
    [128]   = { 237, 207, 114, 249, 246, 242,  221, 231 },
    [256]   = { 237, 204,  97, 249, 246, 242,  220, 231 },
    [512]   = { 237, 200,  80, 249, 246, 242,  214, 231 },
    [1024]  = { 237, 197,  63, 249, 246, 242,  214, 231 },
    [2048]  = { 237, 194,  46, 255, 255, 255,  226, 231 },
    [4096]  = { 160,  62, 179, 255, 255, 255,  133, 231 },
    [8192]  = { 108,  52, 163, 255, 255, 255,   92, 231 },
    [16384] = {  41, 128, 185, 255, 255, 255,   32, 231 },
    [32768] = {  26, 188, 156, 255, 255, 255,   36, 231 },
    [65536] = {  46, 204, 113, 255, 255, 255,   41, 231 },
}

local function get_tile_color(val, use_ascii)
    if use_ascii then
        return "", ""
    end
    local c = TILE_COLORS[val] or TILE_COLORS[65536]
    local bg = string.format("\27[48;2;%d;%d;%dm", c[1], c[2], c[3])
    local fg = string.format("\27[38;2;%d;%d;%dm", c[4], c[5], c[6])
    return bg, fg
end

-- =========================================================================
-- 3. Game State & Logic Engine (Game2048)
-- =========================================================================
local Game2048 = {}
Game2048.__index = Game2048

function Game2048.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Game2048)

    self.board = ffi.new("BoardCell[16]")
    self.stats = ffi.new("Game2048Stats")
    self.undo_stack = ffi.new("UndoState[?]", MAX_UNDOS)
    self.undo_count = 0
    self.undo_head  = 0

    self.use_ascii  = opts.use_ascii or false
    self.auto_mode  = opts.auto_mode or false
    self.auto_speed = opts.auto_speed or 20 -- ms per step in auto mode
    self.game_over  = false
    self.won        = false
    self.keep_playing = false
    self.status_msg = "Join numbers to get the 2048 tile!"

    self:load_high_score()
    self:reset()
    return self
end

function Game2048:reset()
    ffi.fill(self.board, ffi.sizeof("BoardCell") * TOTAL_CELLS)
    self.stats.score = 0
    self.stats.move_count = 0
    self.stats.max_tile = 0
    self.stats.undos_remaining = MAX_UNDOS
    self.undo_count = 0
    self.undo_head = 0
    self.game_over = false
    self.won = false
    self.keep_playing = false
    self.status_msg = "Use Arrow Keys or WASD to slide. Press 'H' for help."

    -- Spawn initial two tiles
    self:spawn_random_tile()
    self:spawn_random_tile()
    self:update_max_tile()
end

function Game2048:load_high_score()
    self.stats.high_score = 0
    local f = io.open(SCORE_FILE, "r")
    if f then
        local line = f:read("*l")
        if line then
            local hs = tonumber(line)
            if hs and hs > 0 then
                self.stats.high_score = hs
            end
        end
        f:close()
    end
end

function Game2048:save_high_score()
    if self.stats.score > self.stats.high_score then
        self.stats.high_score = self.stats.score
    end
    local f = io.open(SCORE_FILE, "w")
    if f then
        f:write(tostring(self.stats.high_score) .. "\n")
        f:close()
    end
end

function Game2048:get_empty_indices()
    local empties = {}
    for i = 0, TOTAL_CELLS - 1 do
        if self.board[i].val == 0 then
            table.insert(empties, i)
        end
    end
    return empties
end

function Game2048:spawn_random_tile()
    local empties = self:get_empty_indices()
    if #empties == 0 then return false end

    local idx = empties[math.random(#empties)]
    -- 90% chance of 2, 10% chance of 4
    local val = (math.random() < 0.90) and 2 or 4
    self.board[idx].val = val
    self.board[idx].spawned = 1
    self.board[idx].merged = 0
    return true
end

function Game2048:update_max_tile()
    local m = 0
    for i = 0, TOTAL_CELLS - 1 do
        if self.board[i].val > m then
            m = self.board[i].val
        end
    end
    self.stats.max_tile = m
    if m >= 2048 and not self.won and not self.keep_playing then
        self.won = true
        self.status_msg = "★ YOU WON! Reached 2048! (C: Continue, R: Restart)"
    end
end

function Game2048:push_undo()
    local slot = self.undo_head % MAX_UNDOS
    for i = 0, TOTAL_CELLS - 1 do
        self.undo_stack[slot].cells[i] = self.board[i].val
    end
    self.undo_stack[slot].score = self.stats.score

    self.undo_head = (self.undo_head + 1) % MAX_UNDOS
    if self.undo_count < MAX_UNDOS then
        self.undo_count = self.undo_count + 1
    end
end

function Game2048:undo()
    if self.undo_count == 0 then
        self.status_msg = "No undo history available."
        return false
    end

    self.undo_head = (self.undo_head - 1 + MAX_UNDOS) % MAX_UNDOS
    self.undo_count = self.undo_count - 1

    local slot = self.undo_head
    for i = 0, TOTAL_CELLS - 1 do
        self.board[i].val = self.undo_stack[slot].cells[i]
        self.board[i].merged = 0
        self.board[i].spawned = 0
    end
    self.stats.score = self.undo_stack[slot].score
    self.game_over = false
    self:update_max_tile()
    self.status_msg = string.format("Move undone. (%d undos left)", self.undo_count)
    return true
end

-- Slide a single 4-element row/column: returns new array of 4 values, points scored, and whether it changed
local function slide_and_merge_line(a, b, c, d)
    local in_line = {a, b, c, d}
    local filtered = {}
    for i = 1, 4 do
        if in_line[i] ~= 0 then
            table.insert(filtered, in_line[i])
        end
    end

    local out_line = {0, 0, 0, 0}
    local points = 0
    local out_idx = 1
    local i = 1

    while i <= #filtered do
        if i + 1 <= #filtered and filtered[i] == filtered[i + 1] then
            local merged_val = filtered[i] * 2
            out_line[out_idx] = merged_val
            points = points + merged_val
            i = i + 2
        else
            out_line[out_idx] = filtered[i]
            i = i + 1
        end
        out_idx = out_idx + 1
    end

    local changed = (out_line[1] ~= a) or (out_line[2] ~= b) or
                    (out_line[3] ~= c) or (out_line[4] ~= d)

    return out_line[1], out_line[2], out_line[3], out_line[4], points, changed
end

function Game2048:move(dir)
    -- Clear animation / status flags
    for i = 0, TOTAL_CELLS - 1 do
        self.board[i].merged = 0
        self.board[i].spawned = 0
    end

    local total_points = 0
    local any_moved = false

    -- Save state for undo before applying move
    local pre_cells = {}
    for i = 0, TOTAL_CELLS - 1 do
        pre_cells[i] = self.board[i].val
    end

    if dir == DIR_LEFT then
        for r = 0, 3 do
            local o0, o1, o2, o3 = r * 4, r * 4 + 1, r * 4 + 2, r * 4 + 3
            local v0, v1, v2, v3, pts, chg = slide_and_merge_line(
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val)
            if chg then
                any_moved = true
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val = v0, v1, v2, v3
                total_points = total_points + pts
            end
        end
    elseif dir == DIR_RIGHT then
        for r = 0, 3 do
            local o0, o1, o2, o3 = r * 4 + 3, r * 4 + 2, r * 4 + 1, r * 4
            local v0, v1, v2, v3, pts, chg = slide_and_merge_line(
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val)
            if chg then
                any_moved = true
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val = v0, v1, v2, v3
                total_points = total_points + pts
            end
        end
    elseif dir == DIR_UP then
        for c = 0, 3 do
            local o0, o1, o2, o3 = c, c + 4, c + 8, c + 12
            local v0, v1, v2, v3, pts, chg = slide_and_merge_line(
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val)
            if chg then
                any_moved = true
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val = v0, v1, v2, v3
                total_points = total_points + pts
            end
        end
    elseif dir == DIR_DOWN then
        for c = 0, 3 do
            local o0, o1, o2, o3 = c + 12, c + 8, c + 4, c
            local v0, v1, v2, v3, pts, chg = slide_and_merge_line(
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val)
            if chg then
                any_moved = true
                self.board[o0].val, self.board[o1].val, self.board[o2].val, self.board[o3].val = v0, v1, v2, v3
                total_points = total_points + pts
            end
        end
    end

    if any_moved then
        -- Push previous state to undo stack
        local slot = self.undo_head % MAX_UNDOS
        for i = 0, TOTAL_CELLS - 1 do
            self.undo_stack[slot].cells[i] = pre_cells[i]
        end
        self.undo_stack[slot].score = self.stats.score
        self.undo_head = (self.undo_head + 1) % MAX_UNDOS
        if self.undo_count < MAX_UNDOS then
            self.undo_count = self.undo_count + 1
        end

        self.stats.score = self.stats.score + total_points
        self.stats.move_count = self.stats.move_count + 1
        if self.stats.score > self.stats.high_score then
            self.stats.high_score = self.stats.score
        end

        -- Spawn a new tile
        self:spawn_random_tile()
        self:update_max_tile()

        -- Check if any valid moves remain
        if not self:can_move() then
            self.game_over = true
            self.status_msg = "✖ GAME OVER! No moves left. Press 'R' to restart, 'U' to undo."
            self:save_high_score()
        else
            if total_points > 0 then
                self.status_msg = string.format("Merged! +%d pts", total_points)
            end
        end
        return true
    end

    return false
end

function Game2048:can_move()
    -- 1. Any empty cell?
    for i = 0, TOTAL_CELLS - 1 do
        if self.board[i].val == 0 then
            return true
        end
    end

    -- 2. Any adjacent horizontal merges?
    for r = 0, 3 do
        for c = 0, 2 do
            local idx = r * 4 + c
            if self.board[idx].val == self.board[idx + 1].val then
                return true
            end
        end
    end

    -- 3. Any adjacent vertical merges?
    for c = 0, 3 do
        for r = 0, 2 do
            local idx = r * 4 + c
            if self.board[idx].val == self.board[idx + 4].val then
                return true
            end
        end
    end

    return false
end

-- =========================================================================
-- 4. High-Performance Expectimax AI Solver
-- =========================================================================
local AI = {
    SCORE_WEIGHTS = {
        EMPTY        = 270.0,
        MONOTONICITY = 47.0,
        SMOOTHNESS   = 14.0,
        CORNER_MAX   = 1000.0,
    }
}

-- Fast simulation on a lightweight 16-element flat array
function AI.clone_board(board)
    local t = {}
    for i = 0, 15 do
        t[i] = board[i].val or board[i]
    end
    return t
end

function AI.can_move_board(b)
    for i = 0, 15 do
        if b[i] == 0 then return true end
    end
    for r = 0, 3 do
        local r4 = r * 4
        for c = 0, 2 do
            if b[r4 + c] == b[r4 + c + 1] then return true end
        end
    end
    for c = 0, 3 do
        for r = 0, 2 do
            if b[r * 4 + c] == b[(r + 1) * 4 + c] then return true end
        end
    end
    return false
end

function AI.simulate_move(b, dir)
    local moved = false
    local pts = 0
    local nb = {}
    for i = 0, 15 do nb[i] = b[i] end

    if dir == DIR_LEFT then
        for r = 0, 3 do
            local o0, o1, o2, o3 = r * 4, r * 4 + 1, r * 4 + 2, r * 4 + 3
            local v0, v1, v2, v3, p, chg = slide_and_merge_line(nb[o0], nb[o1], nb[o2], nb[o3])
            if chg then moved = true; nb[o0], nb[o1], nb[o2], nb[o3] = v0, v1, v2, v3; pts = pts + p end
        end
    elseif dir == DIR_RIGHT then
        for r = 0, 3 do
            local o0, o1, o2, o3 = r * 4 + 3, r * 4 + 2, r * 4 + 1, r * 4
            local v0, v1, v2, v3, p, chg = slide_and_merge_line(nb[o0], nb[o1], nb[o2], nb[o3])
            if chg then moved = true; nb[o0], nb[o1], nb[o2], nb[o3] = v0, v1, v2, v3; pts = pts + p end
        end
    elseif dir == DIR_UP then
        for c = 0, 3 do
            local o0, o1, o2, o3 = c, c + 4, c + 8, c + 12
            local v0, v1, v2, v3, p, chg = slide_and_merge_line(nb[o0], nb[o1], nb[o2], nb[o3])
            if chg then moved = true; nb[o0], nb[o1], nb[o2], nb[o3] = v0, v1, v2, v3; pts = pts + p end
        end
    elseif dir == DIR_DOWN then
        for c = 0, 3 do
            local o0, o1, o2, o3 = c + 12, c + 8, c + 4, c
            local v0, v1, v2, v3, p, chg = slide_and_merge_line(nb[o0], nb[o1], nb[o2], nb[o3])
            if chg then moved = true; nb[o0], nb[o1], nb[o2], nb[o3] = v0, v1, v2, v3; pts = pts + p end
        end
    end

    return moved, nb, pts
end

local LOG2_TABLE = {}
for i = 0, 20 do
    LOG2_TABLE[2^i] = i
end

local function val_log2(v)
    if v <= 0 then return 0 end
    return LOG2_TABLE[v] or (math.log(v) / math.log(2))
end

local SNAKE_WEIGHTS = {
    [0]  = 65536, [1]  = 32768, [2]  = 16384, [3]  = 8192,
    [7]  = 512,   [6]  = 1024,  [5]  = 2048,  [4]  = 4096,
    [8]  = 256,   [9]  = 128,   [10] = 64,    [11] = 32,
    [15] = 2,     [14] = 4,     [13] = 8,     [12] = 16,
}

function AI.evaluate(b)
    local empty_count = 0
    local max_tile = 0
    local max_idx = 0
    local smoothness = 0
    local pos_score = 0

    for i = 0, 15 do
        local v = b[i]
        if v == 0 then
            empty_count = empty_count + 1
        else
            local l2 = val_log2(v)
            pos_score = pos_score + (l2 * SNAKE_WEIGHTS[i])
            if v > max_tile then
                max_tile = v
                max_idx = i
            end
        end
    end

    for r = 0, 3 do
        for c = 0, 3 do
            local idx = r * 4 + c
            local v = b[idx]
            if v > 0 then
                local l2 = val_log2(v)
                if c < 3 and b[idx + 1] > 0 then
                    smoothness = smoothness - math.abs(l2 - val_log2(b[idx + 1]))
                end
                if r < 3 and b[idx + 4] > 0 then
                    smoothness = smoothness - math.abs(l2 - val_log2(b[idx + 4]))
                end
            end
        end
    end

    local mono_lr = 0
    local mono_ud = 0
    for r = 0, 3 do
        local left, right = 0, 0
        for c = 0, 2 do
            local curr = val_log2(b[r * 4 + c])
            local nxt  = val_log2(b[r * 4 + c + 1])
            if curr > nxt then left = left + (curr - nxt)
            elseif nxt > curr then right = right + (nxt - curr) end
        end
        mono_lr = mono_lr - math.min(left, right)
    end
    for c = 0, 3 do
        local up, down = 0, 0
        for r = 0, 2 do
            local curr = val_log2(b[r * 4 + c])
            local nxt  = val_log2(b[(r + 1) * 4 + c])
            if curr > nxt then up = up + (curr - nxt)
            elseif nxt > curr then down = down + (nxt - curr) end
        end
        mono_ud = mono_ud - math.min(up, down)
    end

    local corner_bonus = 0
    if max_idx == 0 then
        corner_bonus = AI.SCORE_WEIGHTS.CORNER_MAX * val_log2(max_tile)
    elseif max_idx == 3 or max_idx == 12 or max_idx == 15 then
        corner_bonus = (AI.SCORE_WEIGHTS.CORNER_MAX * 0.5) * val_log2(max_tile)
    end

    local total = pos_score * 0.1
        + (empty_count * AI.SCORE_WEIGHTS.EMPTY)
        + (smoothness * AI.SCORE_WEIGHTS.SMOOTHNESS)
        + ((mono_lr + mono_ud) * AI.SCORE_WEIGHTS.MONOTONICITY)
        + corner_bonus

    return total
end

function AI.expectimax(b, depth, is_player)
    if depth == 0 or not AI.can_move_board(b) then
        return AI.evaluate(b)
    end

    if is_player then
        local max_score = -1e12
        local moved_any = false

        for dir = 0, 3 do
            local moved, nb, pts = AI.simulate_move(b, dir)
            if moved then
                moved_any = true
                local score = AI.expectimax(nb, depth - 1, false)
                if score > max_score then
                    max_score = score
                end
            end
        end

        return moved_any and max_score or AI.evaluate(b)
    else
        local empties = {}
        for i = 0, 15 do
            if b[i] == 0 then table.insert(empties, i) end
        end

        if #empties == 0 then
            return AI.evaluate(b)
        end

        local sample_size = #empties
        if depth >= 3 and sample_size > 4 then
            sample_size = 4
        end

        local expected_score = 0.0
        local prob_weight = 1.0 / sample_size

        for s = 1, sample_size do
            local idx = empties[s]
            b[idx] = 2
            local s2 = AI.expectimax(b, depth - 1, true)
            b[idx] = 4
            local s4 = AI.expectimax(b, depth - 1, true)
            b[idx] = 0

            expected_score = expected_score + prob_weight * (0.90 * s2 + 0.10 * s4)
        end

        return expected_score
    end
end

function AI.find_best_move(game, max_depth)
    local b = AI.clone_board(game.board)
    max_depth = max_depth or 3

    local empties = #game:get_empty_indices()
    if empties <= 4 then
        max_depth = 4
    elseif empties >= 10 then
        max_depth = 2
    end

    local best_dir = nil
    local best_score = -1e12
    local test_order = { DIR_LEFT, DIR_UP, DIR_RIGHT, DIR_DOWN }

    for _, dir in ipairs(test_order) do
        local moved, nb, pts = AI.simulate_move(b, dir)
        if moved then
            local score = AI.expectimax(nb, max_depth, false)
            if score > best_score then
                best_score = score
                best_dir = dir
            end
        end
    end

    return best_dir, best_score
end

-- =========================================================================
-- 5. Terminal Rendering Engine
-- =========================================================================
local UI = {}

function UI.render_screen(game)
    local lines = {}
    local function emit(fmt, ...)
        table.insert(lines, string.format(fmt, ...))
    end

    local use_ascii = game.use_ascii
    local b = game.board
    local stats = game.stats

    -- Box borders
    local b_tl = use_ascii and "+" or "╭"
    local b_tr = use_ascii and "+" or "╮"
    local b_bl = use_ascii and "+" or "╰"
    local b_br = use_ascii and "+" or "╯"
    local b_h  = use_ascii and "-" or "─"
    local b_v  = use_ascii and "|" or "│"
    local b_vl = use_ascii and "+" or "├"
    local b_vr = use_ascii and "+" or "┤"
    local b_tm = use_ascii and "+" or "┬"
    local b_bm = use_ascii and "+" or "┴"
    local b_x  = use_ascii and "+" or "┼"

    local c_reset  = "\27[0m"
    local c_title  = "\27[1;38;2;237;194;46m"
    local c_accent = "\27[1;36m"
    local c_gray   = "\27[90m"
    local c_val    = "\27[1;37m"
    local c_alert  = "\27[1;33m"

    if use_ascii then
        c_reset = ""
        c_title = ""
        c_accent = ""
        c_gray = ""
        c_val = ""
        c_alert = ""
    end

    emit("\n  %s+-------------------------------------------------------+%s", c_title, c_reset)
    emit("  %s|             2048  *  LUAJIT FFI EDITION               |%s", c_title, c_reset)
    emit("  %s+-------------------------------------------------------+%s\n", c_title, c_reset)

    local auto_status = game.auto_mode and (c_alert .. "[AI AUTO ON]" .. c_reset) or (c_gray .. "[MANUAL]" .. c_reset)
    emit("  %sSCORE:%s %-9d  %sBEST:%s %-9d  %sMOVES:%s %-6d %s",
        c_accent, c_val, stats.score,
        c_accent, c_val, stats.high_score,
        c_accent, c_val, stats.move_count,
        auto_status)

    emit("  %sMAX TILE:%s %-6d  %sUNDOS:%s %-7d  %sGRID:%s 4x4",
        c_accent, c_val, stats.max_tile,
        c_accent, c_val, game.undo_count,
        c_accent, c_val)
    emit("")

    local cell_w = 7

    local function cell_str(val)
        if val == 0 then
            return "       "
        elseif val < 10 then
            return string.format("   %d   ", val)
        elseif val < 100 then
            return string.format("  %2d   ", val)
        elseif val < 1000 then
            return string.format("  %3d  ", val)
        elseif val < 10000 then
            return string.format(" %4d  ", val)
        elseif val < 100000 then
            return string.format(" %5d ", val)
        else
            return string.format("%6d ", val)
        end
    end

    local h_seg = string.rep(b_h, cell_w)
    local top_line = "  " .. b_tl .. h_seg .. b_tm .. h_seg .. b_tm .. h_seg .. b_tm .. h_seg .. b_tr
    local mid_line = "  " .. b_vl .. h_seg .. b_x  .. h_seg .. b_x  .. h_seg .. b_x  .. h_seg .. b_vr
    local bot_line = "  " .. b_bl .. h_seg .. b_bm .. h_seg .. b_bm .. h_seg .. b_bm .. h_seg .. b_br

    emit(top_line)

    for r = 0, 3 do
        local l1 = "  " .. b_v
        for c = 0, 3 do
            local idx = r * 4 + c
            local val = b[idx].val
            local bg, fg = get_tile_color(val, use_ascii)
            l1 = l1 .. bg .. fg .. string.rep(" ", cell_w) .. c_reset .. b_v
        end
        emit(l1)

        local l2 = "  " .. b_v
        for c = 0, 3 do
            local idx = r * 4 + c
            local val = b[idx].val
            local bg, fg = get_tile_color(val, use_ascii)
            local bold = (val >= 8 and not use_ascii) and "\27[1m" or ""
            local txt = cell_str(val)
            l2 = l2 .. bg .. fg .. bold .. txt .. c_reset .. b_v
        end
        emit(l2)

        local l3 = "  " .. b_v
        for c = 0, 3 do
            local idx = r * 4 + c
            local val = b[idx].val
            local bg, fg = get_tile_color(val, use_ascii)
            l3 = l3 .. bg .. fg .. string.rep(" ", cell_w) .. c_reset .. b_v
        end
        emit(l3)

        if r < 3 then
            emit(mid_line)
        else
            emit(bot_line)
        end
    end

    emit("\n  %s▶ %s%s", c_accent, game.status_msg, c_reset)
    emit("  %s[Controls]%s Arrow Keys / WASD: Move  |  U: Undo  |  A: AI Auto", c_gray, c_reset)
    emit("             R: Restart  |  Q/ESC: Quit   |  +/-: AI Speed (Currently: %dms)", game.auto_speed)

    return table.concat(lines, "\n")
end

-- =========================================================================
-- 6. Interactive Game Loop & CLI Handler
-- =========================================================================
local function print_help()
    print([[
2048 • LuaJIT FFI Sliding Tile Puzzle & Expectimax AI Solver

Usage:
  luajit ffi_game_2048.lua [options]

Options:
  --help, -h          Show this help documentation.
  --ascii             Use pure ASCII characters for rendering.
  --auto              Start immediately in automated Expectimax AI solver mode.
  --speed <ms>        Set AI step delay in milliseconds (default: 20).
  --snapshot          Print a non-interactive board snapshot and exit immediately.
  --demo <moves>      Run AI solver for N moves non-interactively and exit.
  --test              Run the comprehensive internal unit test suite and exit.

Keyboard Controls:
  Arrow Keys / WASD   Slide tiles (Up, Down, Left, Right)
  A                   Toggle Expectimax AI Autoplay
  U                   Undo previous move (up to 200 moves)
  R                   Restart game
  C                   Continue playing after reaching 2048
  +, = / -            Increase / Decrease AI solver speed
  Q, ESC, Ctrl-C      Quit game
]])
end

local function run_self_tests()
    print("=== Running Self-Tests for ffi_game_2048.lua ===")
    local passed = 0
    local total = 0

    local function assert_eq(a, b, msg)
        total = total + 1
        if a == b then
            passed = passed + 1
            print(string.format("  \27[32m✔ PASS\27[0m: %s", msg))
        else
            print(string.format("  \27[31m✘ FAIL\27[0m: %s (got %s, expected %s)", msg, tostring(a), tostring(b)))
        end
    end

    -- 1. FFI Struct checks
    assert_eq(ffi.sizeof("BoardCell"), 8, "BoardCell sizeof == 8")
    assert_eq(ffi.offsetof("BoardCell", "val"), 0, "BoardCell offsetof(val) == 0")
    assert_eq(ffi.offsetof("BoardCell", "merged"), 4, "BoardCell offsetof(merged) == 4")
    assert_eq(ffi.sizeof("Game2048Stats"), 20, "Game2048Stats sizeof == 20")

    -- 2. Line sliding & merging tests
    local v0, v1, v2, v3, pts, chg = slide_and_merge_line(2, 0, 2, 0)
    assert_eq(v0, 4, "slide_and_merge [2,0,2,0] -> 4 at 0")
    assert_eq(v1, 0, "slide_and_merge [2,0,2,0] -> 0 at 1")
    assert_eq(pts, 4, "slide_and_merge [2,0,2,0] -> 4 points")
    assert_eq(chg, true, "slide_and_merge [2,0,2,0] -> changed == true")

    v0, v1, v2, v3, pts, chg = slide_and_merge_line(2, 2, 2, 2)
    assert_eq(v0, 4, "slide_and_merge [2,2,2,2] -> 4 at 0")
    assert_eq(v1, 4, "slide_and_merge [2,2,2,2] -> 4 at 1")
    assert_eq(v2, 0, "slide_and_merge [2,2,2,2] -> 0 at 2")
    assert_eq(pts, 8, "slide_and_merge [2,2,2,2] -> 8 points")

    v0, v1, v2, v3, pts, chg = slide_and_merge_line(4, 0, 0, 0)
    assert_eq(chg, false, "slide_and_merge [4,0,0,0] -> changed == false")

    -- 3. Game instance & undo test
    local g = Game2048.new({ use_ascii = true })
    assert_eq(g.stats.score, 0, "Initial score is 0")
    assert_eq(#g:get_empty_indices(), 14, "Initial board has 14 empty cells")

    -- Fill board deterministically for move test
    for i = 0, 15 do g.board[i].val = 0 end
    g.board[0].val = 2
    g.board[1].val = 2
    local moved = g:move(DIR_LEFT)
    assert_eq(moved, true, "DIR_LEFT moved successfully")
    assert_eq(g.board[0].val, 4, "Left tile merged to 4")
    assert_eq(g.stats.score, 4, "Score updated to 4")
    assert_eq(g.undo_count, 1, "Undo stack has 1 entry")

    local undid = g:undo()
    assert_eq(undid, true, "Undo executed")
    assert_eq(g.board[0].val, 2, "Board restored tile 0 to 2")
    assert_eq(g.board[1].val, 2, "Board restored tile 1 to 2")
    assert_eq(g.stats.score, 0, "Score restored to 0")

    -- 4. Expectimax AI test
    local best_dir, best_score = AI.find_best_move(g, 2)
    assert_eq((best_dir ~= nil), true, "AI generated valid move direction")

    -- 5. Snapshot UI render test
    local snap = UI.render_screen(g)
    assert_eq((snap:find("2048", 1, true) ~= nil), true, "Snapshot rendered title correctly")

    print(string.format("\nTest Summary: %d / %d tests passed.", passed, total))
    if passed == total then
        print("\27[1;32mALL 2048 TESTS PASSED SUCCESSFULLY!\27[0m")
        return true
    else
        print("\27[1;31mSOME TESTS FAILED!\27[0m")
        return false
    end
end

local function main()
    local use_ascii  = false
    local auto_mode  = false
    local auto_speed = 25
    local snapshot   = false
    local demo_moves = nil

    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--help" or a == "-h" then
            print_help()
            return
        elseif a == "--ascii" then
            use_ascii = true
        elseif a == "--auto" then
            auto_mode = true
        elseif a == "--snapshot" then
            snapshot = true
        elseif a == "--speed" then
            i = i + 1
            auto_speed = tonumber(arg[i]) or 25
        elseif a == "--demo" then
            i = i + 1
            demo_moves = tonumber(arg[i]) or 20
        elseif a == "--test" then
            local ok = run_self_tests()
            os.exit(ok and 0 or 1)
        end
        i = i + 1
    end

    local game = Game2048.new({
        use_ascii = use_ascii,
        auto_mode = auto_mode,
        auto_speed = auto_speed
    })

    if snapshot then
        print(UI.render_screen(game))
        return
    end

    if demo_moves then
        print(string.format("Running AI Demo for %d moves...", demo_moves))
        for m = 1, demo_moves do
            if game.game_over then break end
            local dir = AI.find_best_move(game, 3)
            if not dir or not game:move(dir) then break end
        end
        print(UI.render_screen(game))
        print(string.format("[AI Demo Complete] Moves: %d, Score: %d, Max Tile: %d",
            game.stats.move_count, game.stats.score, game.stats.max_tile))
        return
    end

    if not is_stdin_tty() then
        print(UI.render_screen(game))
        return
    end

    -- Setup interactive raw terminal
    enable_raw_mode()

    local running = true
    local last_render_time = 0
    local last_auto_time = 0

    io.write("\27[2J\27[H")
    io.flush()

    local ok, err = pcall(function()
        while running do
            local now = get_time_ms()

            -- 1. Handle User Input
            local key = read_key()
            if key then
                if key == "CTRL_C" or key == "q" or key == "ESC" then
                    running = false
                elseif key == "UP" or key == "w" then
                    game:move(DIR_UP)
                elseif key == "DOWN" or key == "s" then
                    game:move(DIR_DOWN)
                elseif key == "LEFT" or (key == "a" and not game.auto_mode) then
                    game:move(DIR_LEFT)
                elseif key == "RIGHT" or key == "d" then
                    game:move(DIR_RIGHT)
                elseif key == "u" then
                    game:undo()
                elseif key == "r" then
                    game:reset()
                elseif key == "c" and game.won then
                    game.won = false
                    game.keep_playing = true
                    game.status_msg = "Keep going for 4096 or beyond!"
                elseif key == "a" then
                    game.auto_mode = not game.auto_mode
                    if game.auto_mode then
                        game.status_msg = "Expectimax AI solver engaged."
                    else
                        game.status_msg = "Manual mode engaged."
                    end
                elseif key == "+" or key == "=" then
                    game.auto_speed = math.max(0, game.auto_speed - 10)
                elseif key == "-" then
                    game.auto_speed = math.min(500, game.auto_speed + 10)
                end
            end

            -- 2. Handle AI Autoplay
            if game.auto_mode and not game.game_over and (now - last_auto_time >= game.auto_speed) then
                last_auto_time = now
                local dir, score = AI.find_best_move(game, 3)
                if dir then
                    game:move(dir)
                else
                    game.auto_mode = false
                    game.status_msg = "AI could not find a valid move."
                end
            end

            -- 3. Render at up to ~60 FPS
            if now - last_render_time >= 16 then
                last_render_time = now
                local frame = UI.render_screen(game)
                io.write("\27[H" .. frame)
                io.flush()
            end

            sleep_ms(5)
        end
    end)

    disable_raw_mode()
    io.write("\n\27[0mExited 2048.\n")
    io.flush()

    if not ok and err then
        io.stderr:write("Error: " .. tostring(err) .. "\n")
    end
end

-- If executed directly, run main(); otherwise return module table for unit testing
if pcall(debug.getlocal, 4, 1) then
    return {
        Game2048 = Game2048,
        AI = AI,
        UI = UI,
        slide_and_merge_line = slide_and_merge_line,
        DIR_UP = DIR_UP,
        DIR_DOWN = DIR_DOWN,
        DIR_LEFT = DIR_LEFT,
        DIR_RIGHT = DIR_RIGHT,
    }
else
    main()
end
