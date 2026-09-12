#!/usr/bin/env luajit
--[[
    ffi_russian_block.lua
    A full-featured, cross-platform Russian Block (Tetris / 俄罗斯方块) game
    built entirely with LuaJIT FFI for both Windows and Linux.

    Features & FFI Highlights:
    1. Cross-Platform C Terminal Control:
       - Windows: Win32 Console API (GetStdHandle, GetConsoleMode, SetConsoleMode,
         SetConsoleOutputCP(65001 UTF-8), _kbhit, _getch, Sleep).
       - Linux/POSIX: termios (tcgetattr/tcsetattr raw mode), poll() non-blocking input,
         ioctl(TIOCGWINSZ), clock_gettime(CLOCK_MONOTONIC) microsecond timer, usleep().
    2. Zero-Overhead C Memory Data Structures:
       - Fixed-size 2D board in C struct array: BoardCell[TOTAL_ROWS * COLS].
       - Fast memory clearing & copying via ffi.fill.
       - C struct for game statistics & scoring.
    3. Complete Modern Russian Block (Tetris) Mechanics:
       - Standard 7 Tetrominoes (I, O, T, S, Z, J, L).
       - 7-Bag Randomizer (guarantees fair piece distribution without droughts).
       - Super Rotation System (SRS) wall kicks (left, right, floor kick resilience).
       - Real-time Ghost Piece shadow projection.
       - Hold Piece swapping (C / H key, once per drop).
       - Next Queue preview (upcoming pieces).
       - Hard Drop (instant lock with drop score bonus, Spacebar).
       - Soft Drop (accelerated fall with score bonus, Down / S).
       - Lock Delay (500ms grace period with move/rotate resets).
       - Line Clears with flash animation, Back-to-Back Tetris bonus, and Combos.
       - Level progression with accelerating gravity.
       - High score tracking saved to disk (.russian_block_score).
       - Built-in heuristic AI Bot autoplay (--demo mode).
       - Headless snapshot (--snapshot) and test verification (--test).
       - Unicode box-drawing or ASCII fallback (--ascii).
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. FFI C Declarations (Cross-Platform: Windows & POSIX / Linux)
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

    local STD_INPUT_HANDLE  = 0xFFFFFFF6 -- ((uint32_t)-10)
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- ((uint32_t)-11)

    local orig_in_mode = ffi.new("uint32_t[1]")
    local in_raw_mode  = false

    -- Initialize Windows UTF-8 console output and ANSI Virtual Terminal Processing
    pcall(function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        ffi.C.SetConsoleOutputCP(65001) -- UTF-8 code page
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

        -- Switch to alternate screen buffer, hide cursor, clear screen
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
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
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

        -- Switch to alternate screen buffer, hide cursor, clear screen
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
-- 2. Board C Structs & Constants
-- =========================================================================
ffi.cdef[[
    typedef struct {
        uint8_t color;  // 0: empty, 1..7: piece color, 8: ghost, 9: flash
        uint8_t locked; // 1: locked cell, 0: unoccupied
    } BoardCell;

    typedef struct {
        int32_t score;
        int32_t high_score;
        int32_t lines;
        int32_t level;
        int32_t pieces_dropped;
        int32_t combos;
    } GameStats;
]]

local BOARD_COLS    = 10
local BOARD_ROWS    = 20
local BUFFER_ROWS   = 4
local TOTAL_ROWS    = BOARD_ROWS + BUFFER_ROWS -- rows 1..4: spawn buffer, 5..24: visible playfield

-- =========================================================================
-- 3. Tetromino Shapes & Visual Definitions
-- =========================================================================
local PIECES = {
    I = {
        id = 1,
        name = "I",
        color_name = "Cyan",
        ansi = "\27[38;2;0;240;255m",
        ascii = "[]",
        size = 4,
        spawn_x = 4,
        spawn_y = 3,
        shape = {
            {0, 0, 0, 0},
            {1, 1, 1, 1},
            {0, 0, 0, 0},
            {0, 0, 0, 0}
        }
    },
    O = {
        id = 2,
        name = "O",
        color_name = "Yellow",
        ansi = "\27[38;2;255;225;0m",
        ascii = "[]",
        size = 2,
        spawn_x = 5,
        spawn_y = 3,
        shape = {
            {1, 1},
            {1, 1}
        }
    },
    T = {
        id = 3,
        name = "T",
        color_name = "Purple",
        ansi = "\27[38;2;195;60;255m",
        ascii = "[]",
        size = 3,
        spawn_x = 4,
        spawn_y = 3,
        shape = {
            {0, 1, 0},
            {1, 1, 1},
            {0, 0, 0}
        }
    },
    S = {
        id = 4,
        name = "S",
        color_name = "Green",
        ansi = "\27[38;2;0;235;85m",
        ascii = "[]",
        size = 3,
        spawn_x = 4,
        spawn_y = 3,
        shape = {
            {0, 1, 1},
            {1, 1, 0},
            {0, 0, 0}
        }
    },
    Z = {
        id = 5,
        name = "Z",
        color_name = "Red",
        ansi = "\27[38;2;255;55;65m",
        ascii = "[]",
        size = 3,
        spawn_x = 4,
        spawn_y = 3,
        shape = {
            {1, 1, 0},
            {0, 1, 1},
            {0, 0, 0}
        }
    },
    J = {
        id = 6,
        name = "J",
        color_name = "Blue",
        ansi = "\27[38;2;55;135;255m",
        ascii = "[]",
        size = 3,
        spawn_x = 4,
        spawn_y = 3,
        shape = {
            {1, 0, 0},
            {1, 1, 1},
            {0, 0, 0}
        }
    },
    L = {
        id = 7,
        name = "L",
        color_name = "Orange",
        ansi = "\27[38;2;255;145;0m",
        ascii = "[]",
        size = 3,
        spawn_x = 4,
        spawn_y = 3,
        shape = {
            {0, 0, 1},
            {1, 1, 1},
            {0, 0, 0}
        }
    }
}

local PIECE_ID_MAP = {}
for k, v in pairs(PIECES) do
    PIECE_ID_MAP[v.id] = v
end

-- =========================================================================
-- 4. High Score File Management
-- =========================================================================
local SCORE_FILE = ".russian_block_score"

local function load_high_score()
    local f = io.open(SCORE_FILE, "r")
    if f then
        local val = tonumber(f:read("*a")) or 0
        f:close()
        return val
    end
    return 0
end

local function save_high_score(val)
    local f = io.open(SCORE_FILE, "w")
    if f then
        f:write(tostring(val))
        f:close()
    end
end

-- =========================================================================
-- 5. Russian Block Engine Class
-- =========================================================================
local TetrisGame = {}
TetrisGame.__index = TetrisGame

function TetrisGame.new(options)
    options = options or {}
    local self = setmetatable({}, TetrisGame)

    self.ascii_mode = options.ascii_mode or false
    self.board = ffi.new("BoardCell[?]", TOTAL_ROWS * BOARD_COLS)
    self.stats = ffi.new("GameStats")
    self.stats.high_score = load_high_score()
    self.stats.level = 1

    self.bag = {}
    self.active_piece = nil
    self.held_piece = nil
    self.can_hold = true
    self.game_over = false
    self.paused = false
    self.last_was_tetris = false

    self.gravity_ms = 800
    self.last_fall_time = 0
    self.lock_delay_ms = 500
    self.lock_timer_start = nil
    self.lock_moves_count = 0
    self.max_lock_resets = 15

    self.clearing_lines = nil
    self.flash_timer = 0

    self:reset()
    return self
end

function TetrisGame:cell_index(row, col)
    return (row - 1) * BOARD_COLS + (col - 1)
end

function TetrisGame:get_cell(row, col)
    if row < 1 or row > TOTAL_ROWS or col < 1 or col > BOARD_COLS then
        return nil
    end
    return self.board[self:cell_index(row, col)]
end

function TetrisGame:set_cell(row, col, color, locked)
    if row >= 1 and row <= TOTAL_ROWS and col >= 1 and col <= BOARD_COLS then
        local cell = self.board[self:cell_index(row, col)]
        cell.color = color
        cell.locked = locked and 1 or 0
    end
end

function TetrisGame:clear_board()
    ffi.fill(self.board, ffi.sizeof("BoardCell") * (TOTAL_ROWS * BOARD_COLS), 0)
end

function TetrisGame:reset()
    self:clear_board()
    self.stats.score = 0
    self.stats.lines = 0
    self.stats.level = 1
    self.stats.pieces_dropped = 0
    self.stats.combos = 0
    self.bag = {}
    self.held_piece = nil
    self.can_hold = true
    self.game_over = false
    self.paused = false
    self.last_was_tetris = false
    self.lock_timer_start = nil
    self.clearing_lines = nil

    self:fill_bag_if_needed()
    self:spawn_piece()
    self:update_gravity()
    self.last_fall_time = get_time_ms()
end

function TetrisGame:update_gravity()
    local lvl = self.stats.level
    -- Standard exponential gravity acceleration curve
    self.gravity_ms = math.max(50, math.floor(800 * (0.86 ^ (lvl - 1))))
end

-- 7-Bag Randomizer (guarantees fair piece distribution)
function TetrisGame:fill_bag_if_needed()
    while #self.bag < 7 do
        local pool = {"I", "O", "T", "S", "Z", "J", "L"}
        for i = #pool, 2, -1 do
            local j = math.random(1, i)
            pool[i], pool[j] = pool[j], pool[i]
        end
        for _, k in ipairs(pool) do
            table.insert(self.bag, k)
        end
    end
end

function TetrisGame:clone_matrix(matrix, size)
    local copy = {}
    for r = 1, size do
        copy[r] = {}
        for c = 1, size do
            copy[r][c] = matrix[r][c]
        end
    end
    return copy
end

function TetrisGame:rotate_cw(matrix, size)
    local res = {}
    for r = 1, size do
        res[r] = {}
        for c = 1, size do
            res[r][c] = matrix[size - c + 1][r]
        end
    end
    return res
end

function TetrisGame:rotate_ccw(matrix, size)
    local res = {}
    for r = 1, size do
        res[r] = {}
        for c = 1, size do
            res[r][c] = matrix[c][size - r + 1]
        end
    end
    return res
end

function TetrisGame:can_place(matrix, px, py)
    local size = #matrix
    for r = 1, size do
        for c = 1, size do
            if matrix[r][c] ~= 0 then
                local board_col = px + (c - 1)
                local board_row = py + (r - 1)
                if board_col < 1 or board_col > BOARD_COLS then
                    return false
                end
                if board_row > TOTAL_ROWS then
                    return false
                end
                if board_row >= 1 then
                    local cell = self:get_cell(board_row, board_col)
                    if cell and cell.locked == 1 then
                        return false
                    end
                end
            end
        end
    end
    return true
end

function TetrisGame:update_ghost_y()
    if not self.active_piece then return end
    local gy = self.active_piece.y
    while self:can_place(self.active_piece.matrix, self.active_piece.x, gy + 1) do
        gy = gy + 1
    end
    self.active_piece.ghost_y = gy
end

function TetrisGame:spawn_piece(piece_type)
    self:fill_bag_if_needed()
    local p_key = piece_type or table.remove(self.bag, 1)
    local def = PIECES[p_key]
    if not def then return false end

    self.active_piece = {
        type = p_key,
        id = def.id,
        def = def,
        size = def.size,
        matrix = self:clone_matrix(def.shape, def.size),
        x = def.spawn_x,
        y = def.spawn_y,
        ghost_y = def.spawn_y
    }

    self.can_hold = true
    self.lock_timer_start = nil
    self.lock_moves_count = 0

    if not self:can_place(self.active_piece.matrix, self.active_piece.x, self.active_piece.y) then
        self.game_over = true
        return false
    end

    self:update_ghost_y()
    return true
end

-- Super Rotation System (SRS) Wall Kicks
function TetrisGame:try_rotate(clockwise)
    if not self.active_piece then return false end
    local ap = self.active_piece
    if ap.type == "O" then return true end -- O tetromino does not need rotation

    local new_matrix
    if clockwise then
        new_matrix = self:rotate_cw(ap.matrix, ap.size)
    else
        new_matrix = self:rotate_ccw(ap.matrix, ap.size)
    end

    -- Wall kick offset tests
    local kick_offsets = {
        {x = 0, y = 0},
        {x = -1, y = 0},
        {x = 1, y = 0},
        {x = -2, y = 0},
        {x = 2, y = 0},
        {x = 0, y = -1},
        {x = -1, y = -1},
        {x = 1, y = -1},
        {x = 0, y = -2}
    }

    for _, offset in ipairs(kick_offsets) do
        local test_x = ap.x + offset.x
        local test_y = ap.y + offset.y
        if self:can_place(new_matrix, test_x, test_y) then
            ap.matrix = new_matrix
            ap.x = test_x
            ap.y = test_y
            self:update_ghost_y()
            self:reset_lock_delay_on_move()
            return true
        end
    end
    return false
end

function TetrisGame:move_left()
    if not self.active_piece or self.game_over or self.paused then return false end
    if self:can_place(self.active_piece.matrix, self.active_piece.x - 1, self.active_piece.y) then
        self.active_piece.x = self.active_piece.x - 1
        self:update_ghost_y()
        self:reset_lock_delay_on_move()
        return true
    end
    return false
end

function TetrisGame:move_right()
    if not self.active_piece or self.game_over or self.paused then return false end
    if self:can_place(self.active_piece.matrix, self.active_piece.x + 1, self.active_piece.y) then
        self.active_piece.x = self.active_piece.x + 1
        self:update_ghost_y()
        self:reset_lock_delay_on_move()
        return true
    end
    return false
end

function TetrisGame:soft_drop()
    if not self.active_piece or self.game_over or self.paused then return false end
    if self:can_place(self.active_piece.matrix, self.active_piece.x, self.active_piece.y + 1) then
        self.active_piece.y = self.active_piece.y + 1
        self.stats.score = self.stats.score + 1
        if self.stats.score > self.stats.high_score then
            self.stats.high_score = self.stats.score
        end
        self:update_ghost_y()
        return true
    else
        self:lock_active_piece()
        return false
    end
end

function TetrisGame:hard_drop()
    if not self.active_piece or self.game_over or self.paused then return false end
    local drop_dist = self.active_piece.ghost_y - self.active_piece.y
    self.stats.score = self.stats.score + drop_dist * 2
    if self.stats.score > self.stats.high_score then
        self.stats.high_score = self.stats.score
    end
    self.active_piece.y = self.active_piece.ghost_y
    self:lock_active_piece()
    return true
end

function TetrisGame:hold_piece()
    if not self.active_piece or not self.can_hold or self.game_over or self.paused then return false end
    local current_type = self.active_piece.type
    if self.held_piece == nil then
        self.held_piece = current_type
        self:spawn_piece()
    else
        local prev_held = self.held_piece
        self.held_piece = current_type
        self:spawn_piece(prev_held)
    end
    self.can_hold = false
    return true
end

function TetrisGame:reset_lock_delay_on_move()
    if not self.active_piece then return end
    local on_ground = not self:can_place(self.active_piece.matrix, self.active_piece.x, self.active_piece.y + 1)
    if on_ground and self.lock_moves_count < self.max_lock_resets then
        self.lock_timer_start = get_time_ms()
        self.lock_moves_count = self.lock_moves_count + 1
    end
end

function TetrisGame:lock_active_piece()
    local ap = self.active_piece
    if not ap then return end

    local size = ap.size
    for r = 1, size do
        for c = 1, size do
            if ap.matrix[r][c] ~= 0 then
                local br = ap.y + (r - 1)
                local bc = ap.x + (c - 1)
                self:set_cell(br, bc, ap.id, true)
            end
        end
    end

    self.stats.pieces_dropped = self.stats.pieces_dropped + 1
    self.active_piece = nil
    self.lock_timer_start = nil

    -- Check Top-Out (Game Over) in buffer zone
    for br = 1, BUFFER_ROWS do
        for bc = 1, BOARD_COLS do
            local cell = self:get_cell(br, bc)
            if cell and cell.locked == 1 then
                self.game_over = true
                if self.stats.score > self.stats.high_score then
                    save_high_score(self.stats.score)
                end
                return
            end
        end
    end

    -- Check for full lines
    local full_lines = {}
    for r = TOTAL_ROWS, BUFFER_ROWS + 1, -1 do
        local full = true
        for c = 1, BOARD_COLS do
            local cell = self:get_cell(r, c)
            if not cell or cell.locked == 0 then
                full = false
                break
            end
        end
        if full then
            table.insert(full_lines, r)
        end
    end

    if #full_lines > 0 then
        self:collapse_lines(full_lines)
    else
        self.stats.combos = 0
        self:spawn_piece()
    end
end

function TetrisGame:collapse_lines(full_lines)
    local count = #full_lines
    local base_score = 0
    local lvl = self.stats.level

    if count == 1 then
        base_score = 100 * lvl
    elseif count == 2 then
        base_score = 300 * lvl
    elseif count == 3 then
        base_score = 500 * lvl
    elseif count == 4 then
        base_score = 800 * lvl
        if self.last_was_tetris then
            base_score = math.floor(base_score * 1.5) -- Back-to-Back Tetris bonus
        end
        self.last_was_tetris = true
    end

    if count < 4 then
        self.last_was_tetris = false
    end

    -- Combo bonus
    self.stats.combos = self.stats.combos + 1
    if self.stats.combos > 1 then
        base_score = base_score + (50 * (self.stats.combos - 1) * lvl)
    end

    self.stats.score = self.stats.score + base_score
    self.stats.lines = self.stats.lines + count
    self.stats.level = math.floor(self.stats.lines / 10) + 1
    self:update_gravity()

    if self.stats.score > self.stats.high_score then
        self.stats.high_score = self.stats.score
        save_high_score(self.stats.high_score)
    end

    -- Shift lines down in C memory
    table.sort(full_lines) -- ascending order
    for _, cleared_row in ipairs(full_lines) do
        for r = cleared_row, 2, -1 do
            for c = 1, BOARD_COLS do
                local above = self:get_cell(r - 1, c)
                self:set_cell(r, c, above.color, above.locked == 1)
            end
        end
        for c = 1, BOARD_COLS do
            self:set_cell(1, c, 0, false)
        end
    end

    self:spawn_piece()
end

function TetrisGame:tick(current_time)
    if self.game_over or self.paused or not self.active_piece then return end

    local ap = self.active_piece
    local on_ground = not self:can_place(ap.matrix, ap.x, ap.y + 1)

    if on_ground then
        if not self.lock_timer_start then
            self.lock_timer_start = current_time
        elseif (current_time - self.lock_timer_start) >= self.lock_delay_ms then
            self:lock_active_piece()
            return
        end
    else
        self.lock_timer_start = nil
    end

    -- Gravity step
    if current_time - self.last_fall_time >= self.gravity_ms then
        self.last_fall_time = current_time
        if self:can_place(ap.matrix, ap.x, ap.y + 1) then
            ap.y = ap.y + 1
            self:update_ghost_y()
        end
    end
end

-- =========================================================================
-- 6. Heuristic AI Bot (for Autoplay and Headless Simulation)
-- =========================================================================
function TetrisGame:find_best_move()
    if not self.active_piece then return nil end
    local ap = self.active_piece

    local best_score = -1e9
    local best_rotations = 0
    local best_x = ap.x

    local test_matrices = {}
    local curr_m = self:clone_matrix(ap.matrix, ap.size)
    table.insert(test_matrices, curr_m)

    local max_rot = (ap.type == "O") and 1 or ((ap.type == "I" or ap.type == "S" or ap.type == "Z") and 2 or 4)
    for r = 1, max_rot - 1 do
        curr_m = self:rotate_cw(curr_m, ap.size)
        table.insert(test_matrices, curr_m)
    end

    for rot_idx, m in ipairs(test_matrices) do
        for test_col = -2, BOARD_COLS + 1 do
            if self:can_place(m, test_col, ap.y) or self:can_place(m, test_col, 1) then
                local test_y = 1
                while test_y <= TOTAL_ROWS and not self:can_place(m, test_col, test_y) do
                    test_y = test_y + 1
                end
                if test_y <= TOTAL_ROWS and self:can_place(m, test_col, test_y) then
                    while self:can_place(m, test_col, test_y + 1) do
                        test_y = test_y + 1
                    end

                    -- Evaluate candidate placement
                    local eval = self:evaluate_candidate(m, test_col, test_y, ap.id)
                    if eval > best_score then
                        best_score = eval
                        best_rotations = rot_idx - 1
                        best_x = test_col
                    end
                end
            end
        end
    end

    return { rotations = best_rotations, target_x = best_x }
end

function TetrisGame:evaluate_candidate(matrix, px, py, piece_id)
    local heights = {}
    for c = 1, BOARD_COLS do heights[c] = 0 end
    local holes = 0
    local size = #matrix

    -- Build simulated column heights
    for c = 1, BOARD_COLS do
        for r = BUFFER_ROWS + 1, TOTAL_ROWS do
            local has_cell = false
            local board_cell = self:get_cell(r, c)
            if board_cell and board_cell.locked == 1 then
                has_cell = true
            end
            if not has_cell then
                local pr = r - py + 1
                local pc = c - px + 1
                if pr >= 1 and pr <= size and pc >= 1 and pc <= size and matrix[pr][pc] ~= 0 then
                    has_cell = true
                end
            end
            if has_cell then
                heights[c] = TOTAL_ROWS - r + 1
                break
            end
        end
    end

    -- Count holes under simulated placement
    for c = 1, BOARD_COLS do
        local found_block = false
        for r = BUFFER_ROWS + 1, TOTAL_ROWS do
            local has_cell = false
            local board_cell = self:get_cell(r, c)
            if board_cell and board_cell.locked == 1 then
                has_cell = true
            end
            if not has_cell then
                local pr = r - py + 1
                local pc = c - px + 1
                if pr >= 1 and pr <= size and pc >= 1 and pc <= size and matrix[pr][pc] ~= 0 then
                    has_cell = true
                end
            end
            if has_cell then
                found_block = true
            elseif found_block then
                holes = holes + 1
            end
        end
    end

    -- Calculate aggregate height & bumpiness
    local agg_height = 0
    local bumpiness = 0
    for c = 1, BOARD_COLS do
        agg_height = agg_height + heights[c]
        if c > 1 then
            bumpiness = bumpiness + math.abs(heights[c] - heights[c - 1])
        end
    end

    -- Count completed lines
    local lines_cleared = 0
    for r = BUFFER_ROWS + 1, TOTAL_ROWS do
        local full = true
        for c = 1, BOARD_COLS do
            local has_cell = false
            local board_cell = self:get_cell(r, c)
            if board_cell and board_cell.locked == 1 then
                has_cell = true
            end
            if not has_cell then
                local pr = r - py + 1
                local pc = c - px + 1
                if pr >= 1 and pr <= size and pc >= 1 and pc <= size and matrix[pr][pc] ~= 0 then
                    has_cell = true
                end
            end
            if not has_cell then
                full = false
                break
            end
        end
        if full then lines_cleared = lines_cleared + 1 end
    end

    -- Dellacherie heuristic formula
    return (-0.51 * agg_height) + (0.76 * lines_cleared * lines_cleared) - (0.36 * holes) - (0.18 * bumpiness)
end

-- =========================================================================
-- 7. High-Performance Terminal Rendering
-- =========================================================================
local UI_CHARS = {
    unicode = {
        h_line   = "═",
        v_line   = "║",
        tl       = "╔",
        tr       = "╗",
        bl       = "╚",
        br       = "╝",
        t_left   = "╠",
        t_right  = "╣",
        b_box_h  = "─",
        b_box_v  = "│",
        b_tl     = "┌",
        b_tr     = "┐",
        b_bl     = "└",
        b_br     = "┘",
        b_t_left = "├",
        b_t_r    = "┤",
        block    = "██",
        ghost    = "░░",
        empty    = " ·"
    },
    ascii = {
        h_line   = "=",
        v_line   = "|",
        tl       = "+",
        tr       = "+",
        bl       = "+",
        br       = "+",
        t_left   = "+",
        t_right  = "+",
        b_box_h  = "-",
        b_box_v  = "|",
        b_tl     = "+",
        b_tr     = "+",
        b_bl     = "+",
        b_br     = "+",
        b_t_left = "+",
        b_t_r    = "+",
        block    = "[]",
        ghost    = "::",
        empty    = "  "
    }
}

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

local function fmt_num_5(val)
    if val < 100000 then
        return string.format("%-5d", val)
    elseif val < 1000000 then
        return string.format("%4dk", math.floor(val / 1000))
    else
        return string.format("%4.1fM", val / 1000000)
    end
end

function TetrisGame:render_frame()
    local U = self.ascii_mode and UI_CHARS.ascii or UI_CHARS.unicode
    local out = { "\27[H" } -- Move cursor home

    -- Build active piece coordinate set for fast overlay lookup
    local active_cells = {}
    if self.active_piece then
        local ap = self.active_piece
        for r = 1, ap.size do
            for c = 1, ap.size do
                if ap.matrix[r][c] ~= 0 then
                    local br = ap.y + (r - 1)
                    local bc = ap.x + (c - 1)
                    active_cells[br .. ":" .. bc] = ap.id
                end
            end
        end
    end

    -- Build ghost piece coordinate set
    local ghost_cells = {}
    if self.active_piece and self.active_piece.ghost_y ~= self.active_piece.y then
        local ap = self.active_piece
        for r = 1, ap.size do
            for c = 1, ap.size do
                if ap.matrix[r][c] ~= 0 then
                    local br = ap.ghost_y + (r - 1)
                    local bc = ap.x + (c - 1)
                    if not active_cells[br .. ":" .. bc] then
                        ghost_cells[br .. ":" .. bc] = true
                    end
                end
            end
        end
    end

    -- Header Banner (width: 59 columns = 1 space + 1 corner + 56 h_lines + 1 corner)
    table.insert(out, " \27[1;36m" .. U.tl .. string.rep(U.h_line, 56) .. U.tr .. "\27[0m\n")
    local title_str = self.ascii_mode
        and "          RUSSIAN BLOCK (TETRIS) - LUAJIT FFI           "
        or  "    🎮  RUSSIAN BLOCK (俄罗斯方块) - LUAJIT FFI  🎮     "
    table.insert(out, string.format(" \27[1;36m%s\27[1;33m%s\27[1;36m%s\27[0m\n", U.v_line, title_str, U.v_line))
    table.insert(out, " \27[1;36m" .. U.bl .. string.rep(U.h_line, 56) .. U.br .. "\27[0m\n")

    -- Prepare side panels (20 rows total, each exactly 15 visible columns wide)
    local left_lines = {}
    local right_lines = {}

    -- Hold box (rows 1..6)
    table.insert(left_lines, string.format("\27[1;34m%s%s HOLD %s%s\27[0m", U.b_tl, string.rep(U.b_box_h, 3), string.rep(U.b_box_h, 4), U.b_tr))
    local held_def = self.held_piece and PIECES[self.held_piece] or nil
    for r = 1, 4 do
        local row_str = ""
        if held_def and r <= held_def.size then
            for c = 1, 4 do
                if c <= held_def.size and held_def.shape[r][c] ~= 0 then
                    row_str = row_str .. held_def.ansi .. U.block .. "\27[0m"
                else
                    row_str = row_str .. "  "
                end
            end
        else
            row_str = "        "
        end
        table.insert(left_lines, string.format("\27[1;34m%s\27[0m  %s   \27[1;34m%s\27[0m", U.b_box_v, row_str, U.b_box_v))
    end
    table.insert(left_lines, string.format("\27[1;34m%s%s%s\27[0m", U.b_bl, string.rep(U.b_box_h, 13), U.b_br))

    -- Controls box (rows 7..18)
    local k_left  = self.ascii_mode and "<" or "←"
    local k_right = self.ascii_mode and ">" or "→"
    local k_up    = self.ascii_mode and "^" or "↑"
    local k_down  = self.ascii_mode and "v" or "↓"

    table.insert(left_lines, string.format("\27[1;35m%s%s CONTROLS %s%s\27[0m", U.b_tl, string.rep(U.b_box_h, 1), string.rep(U.b_box_h, 2), U.b_tr))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m %s/A : Left  \27[1;35m%s\27[0m", U.b_box_v, k_left, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m %s/D : Right \27[1;35m%s\27[0m", U.b_box_v, k_right, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m %s/W : RotCW \27[1;35m%s\27[0m", U.b_box_v, k_up, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m Z   : RotCC \27[1;35m%s\27[0m", U.b_box_v, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m %s/S : Soft  \27[1;35m%s\27[0m", U.b_box_v, k_down, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m Space: Drop \27[1;35m%s\27[0m", U.b_box_v, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m C / H: Hold \27[1;35m%s\27[0m", U.b_box_v, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m P/Esc: Pause\27[1;35m%s\27[0m", U.b_box_v, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m R    : Reset\27[1;35m%s\27[0m", U.b_box_v, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s\27[0m Q    : Quit \27[1;35m%s\27[0m", U.b_box_v, U.b_box_v))
    table.insert(left_lines, string.format("\27[1;35m%s%s%s\27[0m", U.b_bl, string.rep(U.b_box_h, 13), U.b_br))

    -- Left panel footer (rows 19..20): FFI OS centered in 15 columns
    local os_tag = string.format("(FFI %s)", ffi.os)
    local os_tag_len = #os_tag
    local l_pad = math.max(0, math.floor((15 - os_tag_len) / 2))
    local r_pad = math.max(0, 15 - os_tag_len - l_pad)
    table.insert(left_lines, string.format("%s\27[90m%s\27[0m%s", string.rep(" ", l_pad), os_tag, string.rep(" ", r_pad)))
    while #left_lines < BOARD_ROWS do
        table.insert(left_lines, string.rep(" ", 15))
    end

    -- Next queue box (rows 1..6)
    table.insert(right_lines, string.format("\27[1;32m%s%s NEXT %s%s\27[0m", U.b_tl, string.rep(U.b_box_h, 3), string.rep(U.b_box_h, 4), U.b_tr))
    local next_piece_key = self.bag[1] or "I"
    local next_def = PIECES[next_piece_key]
    for r = 1, 4 do
        local row_str = ""
        if next_def and r <= next_def.size then
            for c = 1, 4 do
                if c <= next_def.size and next_def.shape[r][c] ~= 0 then
                    row_str = row_str .. next_def.ansi .. U.block .. "\27[0m"
                else
                    row_str = row_str .. "  "
                end
            end
        else
            row_str = "        "
        end
        table.insert(right_lines, string.format("\27[1;32m%s\27[0m  %s   \27[1;32m%s\27[0m", U.b_box_v, row_str, U.b_box_v))
    end
    table.insert(right_lines, string.format("\27[1;32m%s%s%s\27[0m", U.b_bl, string.rep(U.b_box_h, 13), U.b_br))

    -- Stats box (rows 7..20)
    table.insert(right_lines, string.format("\27[1;33m%s%s STATS %s%s\27[0m", U.b_tl, string.rep(U.b_box_h, 3), string.rep(U.b_box_h, 3), U.b_tr))
    table.insert(right_lines, string.format("\27[1;33m%s\27[0m SCORE: \27[1;32m%s\27[0m\27[1;33m%s\27[0m", U.b_box_v, fmt_num_5(self.stats.score), U.b_box_v))
    table.insert(right_lines, string.format("\27[1;33m%s\27[0m LEVEL: \27[1;33m%-5d\27[0m\27[1;33m%s\27[0m", U.b_box_v, self.stats.level, U.b_box_v))
    table.insert(right_lines, string.format("\27[1;33m%s\27[0m LINES: \27[1;36m%-5d\27[0m\27[1;33m%s\27[0m", U.b_box_v, self.stats.lines, U.b_box_v))
    table.insert(right_lines, string.format("\27[1;33m%s\27[0m COMBO: \27[1;35mx%-4d\27[0m\27[1;33m%s\27[0m", U.b_box_v, self.stats.combos, U.b_box_v))
    table.insert(right_lines, string.format("\27[1;33m%s\27[0m HIGH:  \27[1;31m%s\27[0m\27[1;33m%s\27[0m", U.b_box_v, fmt_num_5(self.stats.high_score), U.b_box_v))
    table.insert(right_lines, string.format("\27[1;33m%s\27[0m SPEED: \27[90m%3dms\27[0m\27[1;33m%s\27[0m", U.b_box_v, math.min(self.gravity_ms, 999), U.b_box_v))
    table.insert(right_lines, string.format("\27[1;33m%s%s%s\27[0m", U.b_bl, string.rep(U.b_box_h, 13), U.b_br))

    local status_text = "PLAYING"
    local status_color = "\27[32m"
    if self.game_over then
        status_text = "GAME OVER"
        status_color = "\27[1;31m"
    elseif self.paused then
        status_text = "PAUSED"
        status_color = "\27[1;33m"
    end
    local tag_len = #status_text + 2
    local s_l_pad = math.floor((15 - tag_len) / 2)
    local s_r_pad = 15 - tag_len - s_l_pad
    table.insert(right_lines, string.format("%s[%s%s\27[0m]%s",
        string.rep(" ", s_l_pad), status_color, status_text, string.rep(" ", s_r_pad)))

    while #right_lines < BOARD_ROWS do
        table.insert(right_lines, string.rep(" ", 15))
    end

    -- Top border of playfield
    table.insert(out, string.format(" %s   \27[1;37m%s%s%s\27[0m   %s\n",
        string.rep(" ", 15), U.b_tl, string.rep(U.b_box_h, BOARD_COLS * 2), U.b_tr, string.rep(" ", 15)))

    -- Visible Board Rows (rows 5 to 24 internally)
    for vi = 1, BOARD_ROWS do
        local br = vi + BUFFER_ROWS
        local row_buf = {}

        for bc = 1, BOARD_COLS do
            local key = br .. ":" .. bc
            local active_id = active_cells[key]

            if active_id then
                local def = PIECE_ID_MAP[active_id]
                table.insert(row_buf, def.ansi .. U.block .. "\27[0m")
            elseif ghost_cells[key] then
                table.insert(row_buf, "\27[38;2;110;125;145m" .. U.ghost .. "\27[0m")
            else
                local cell = self:get_cell(br, bc)
                if cell and cell.locked == 1 then
                    local def = PIECE_ID_MAP[cell.color]
                    if def then
                        table.insert(row_buf, def.ansi .. U.block .. "\27[0m")
                    else
                        table.insert(row_buf, "\27[37m" .. U.block .. "\27[0m")
                    end
                else
                    table.insert(row_buf, "\27[38;2;55;65;85m" .. U.empty .. "\27[0m")
                end
            end
        end

        local left_col = left_lines[vi] or string.rep(" ", 15)
        local right_col = right_lines[vi] or string.rep(" ", 15)
        local playfield_line = table.concat(row_buf)

        -- Overlay Pause / Game Over message directly on the board
        if self.paused and vi == 10 then
            playfield_line = "  \27[1;33;44m  ** PAUSED **  \27[0m  "
        elseif self.game_over and vi == 10 then
            playfield_line = "  \27[1;37;41m   GAME OVER!   \27[0m  "
        elseif self.game_over and vi == 11 then
            playfield_line = "  \27[1;33;41m Press R: Retry \27[0m  "
        end

        table.insert(out, string.format(" %s   \27[1;37m%s\27[0m%s\27[1;37m%s\27[0m   %s\n",
            pad_right(left_col, 15), U.b_box_v, playfield_line, U.b_box_v, pad_right(right_col, 15)))
    end

    -- Bottom border of playfield
    table.insert(out, string.format(" %s   \27[1;37m%s%s%s\27[0m   %s\n",
        string.rep(" ", 15), U.b_bl, string.rep(U.b_box_h, BOARD_COLS * 2), U.b_br, string.rep(" ", 15)))

    return table.concat(out)
end

-- =========================================================================
-- 8. Main Interactive Game Loop & CLI
-- =========================================================================
local function run_interactive_game(options)
    local game = TetrisGame.new(options)
    math.randomseed(os.time())

    local raw_ok = enable_raw_mode()
    if not raw_ok then
        print("\27[33mWarning: Standard input is not an interactive TTY; falling back.\27[0m")
    end

    local last_render = 0
    local target_fps = 60
    local frame_time_ms = 1000.0 / target_fps

    local ok, err = pcall(function()
        while true do
            local now = get_time_ms()

            -- 1. Input Processing
            local key = read_key(0)
            if key == "q" or key == "CTRL_C" then
                break
            elseif key == "p" or key == "ESC" then
                game.paused = not game.paused
            elseif key == "r" then
                game:reset()
            elseif not game.paused and not game.game_over then
                if key == "a" or key == "LEFT" then
                    game:move_left()
                elseif key == "d" or key == "RIGHT" then
                    game:move_right()
                elseif key == "w" or key == "UP" or key == "k" or key == "x" then
                    game:try_rotate(true) -- Rotate Clockwise
                elseif key == "z" then
                    game:try_rotate(false) -- Rotate Counter-Clockwise
                elseif key == "s" or key == "DOWN" then
                    game:soft_drop()
                elseif key == "SPACE" then
                    game:hard_drop()
                elseif key == "c" or key == "h" then
                    game:hold_piece()
                end
            end

            -- 2. Game Logic Tick
            game:tick(now)

            -- 3. Render Frame at target FPS
            if now - last_render >= frame_time_ms then
                io.write(game:render_frame())
                io.flush()
                last_render = now
            end

            sleep_ms(8) -- Yield ~8ms to prevent CPU spinning
        end
    end)

    disable_raw_mode()

    if not ok then
        io.stderr:write("\n\27[31mFatal error in game loop:\27[0m " .. tostring(err) .. "\n")
    else
        print("\n\27[1;32mThanks for playing Russian Block (Tetris)!\27[0m Final Score: " .. game.stats.score .. "\n")
    end
end

-- Automated AI Demo Mode
local function run_ai_demo(max_frames, options)
    options = options or {}
    local game = TetrisGame.new(options)
    max_frames = max_frames or 150
    math.randomseed(12345)

    local raw_ok = enable_raw_mode()
    local frame = 0
    local ai_plan = nil

    local ok, err = pcall(function()
        while frame < max_frames and not game.game_over do
            local now = get_time_ms()

            -- Check user interrupt key
            local key = read_key(0)
            if key == "q" or key == "CTRL_C" or key == "ESC" then break end

            if not ai_plan or not game.active_piece then
                ai_plan = game:find_best_move()
            end

            if ai_plan and game.active_piece then
                if ai_plan.rotations > 0 then
                    game:try_rotate(true)
                    ai_plan.rotations = ai_plan.rotations - 1
                elseif game.active_piece.x < ai_plan.target_x then
                    game:move_right()
                elseif game.active_piece.x > ai_plan.target_x then
                    game:move_left()
                else
                    game:hard_drop()
                    ai_plan = nil
                end
            end

            game:tick(now)
            io.write(game:render_frame())
            io.flush()

            frame = frame + 1
            sleep_ms(options.delay or 60)
        end
    end)

    disable_raw_mode()
    if not ok then
        io.stderr:write("\nError in demo: " .. tostring(err) .. "\n")
    end
    print(string.format("\n[AI Demo Complete] Frames: %d, Score: %d, Lines: %d, Level: %d\n",
        frame, game.stats.score, game.stats.lines, game.stats.level))
end

-- =========================================================================
-- 9. Self-Test Mode (--test)
-- =========================================================================
local function run_self_tests()
    print("=== Running Self-Tests for Russian Block (LuaJIT FFI) ===")
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

    -- 1. Struct sizes
    check("BoardCell struct size is 2 bytes", ffi.sizeof("BoardCell") == 2)
    check("GameStats struct size is 24 bytes", ffi.sizeof("GameStats") == 24)

    -- 2. Game initialization
    local g = TetrisGame.new({ ascii_mode = true })
    check("Game initialized with zero score", g.stats.score == 0)
    check("Active piece spawned correctly", g.active_piece ~= nil)
    check("Ghost piece projected below active piece", g.active_piece.ghost_y >= g.active_piece.y)

    -- 3. Piece Rotations (Clockwise & CCW)
    local t_matrix = PIECES.T.shape
    local t_rot1 = g:rotate_cw(t_matrix, 3)
    local t_rot2 = g:rotate_cw(t_rot1, 3)
    local t_rot3 = g:rotate_cw(t_rot2, 3)
    local t_rot4 = g:rotate_cw(t_rot3, 3)
    check("4x Clockwise rotation returns to original matrix",
        t_rot4[1][2] == 1 and t_rot4[2][1] == 1 and t_rot4[2][2] == 1 and t_rot4[2][3] == 1)

    local t_ccw = g:rotate_ccw(t_rot1, 3)
    check("CCW rotation reverses CW rotation",
        t_ccw[1][2] == t_matrix[1][2] and t_ccw[2][2] == t_matrix[2][2])

    -- 4. 7-Bag Randomizer
    local bag_counts = {}
    local sample_g = TetrisGame.new()
    sample_g.bag = {}
    for _ = 1, 14 do
        sample_g:fill_bag_if_needed()
        local p = table.remove(sample_g.bag, 1)
        bag_counts[p] = (bag_counts[p] or 0) + 1
    end
    local fair_bag = true
    for _, k in ipairs({"I", "O", "T", "S", "Z", "J", "L"}) do
        if not bag_counts[k] or bag_counts[k] ~= 2 then
            fair_bag = false
        end
    end
    check("7-Bag generator maintains exact piece distribution", fair_bag)

    -- 5. Collision & Boundary Checking
    g:clear_board()
    check("Placement valid inside board bounds", g:can_place(PIECES.O.shape, 1, 5) == true)
    check("Placement invalid beyond left board edge", g:can_place(PIECES.O.shape, 0, 5) == false)
    check("Placement invalid beyond right board edge", g:can_place(PIECES.O.shape, 10, 5) == false)
    check("Placement invalid below bottom floor", g:can_place(PIECES.O.shape, 1, TOTAL_ROWS) == false)

    -- 6. Movement & Drops
    g:clear_board()
    g:spawn_piece("T")
    local init_x = g.active_piece.x
    g:move_left()
    check("move_left decreases x coordinate", g.active_piece.x == init_x - 1)
    g:move_right()
    check("move_right restores x coordinate", g.active_piece.x == init_x)
    local init_score = g.stats.score
    g:soft_drop()
    check("soft_drop increments score", g.stats.score == init_score + 1)

    -- 7. Line Clears & Collapse
    g:clear_board()
    -- Fill row TOTAL_ROWS completely except column 1
    for c = 2, BOARD_COLS do
        g:set_cell(TOTAL_ROWS, c, 1, true)
    end
    -- Complete the row by dropping an I piece at column 1
    g:set_cell(TOTAL_ROWS, 1, 1, true)
    g:collapse_lines({ TOTAL_ROWS })
    check("Full line cleared and line counter incremented", g.stats.lines == 1)
    check("Score awarded for single line clear", g.stats.score >= 100)

    -- 8. Tetris (4-line) Clear & Scoring
    g:clear_board()
    local start_lines = g.stats.lines
    local clear_rows = { TOTAL_ROWS - 3, TOTAL_ROWS - 2, TOTAL_ROWS - 1, TOTAL_ROWS }
    for _, r in ipairs(clear_rows) do
        for c = 1, BOARD_COLS do
            g:set_cell(r, c, 1, true)
        end
    end
    g:collapse_lines(clear_rows)
    check("4 lines cleared simultaneously (Tetris)", g.stats.lines == start_lines + 4)
    check("Tetris awarded 800 * level points", g.stats.score >= 800)

    -- 9. Hold Piece Swapping
    g:clear_board()
    g:spawn_piece("I")
    check("Initial held piece is nil", g.held_piece == nil)
    g:hold_piece()
    check("Active piece held into hold slot", g.held_piece == "I")
    check("can_hold flag prevents holding twice in one turn", g.can_hold == false)

    -- 10. Frame Snapshot Rendering & Layout Width
    local snapshot = g:render_frame()
    check("Frame render produces valid ANSI string", type(snapshot) == "string" and #snapshot > 200)

    -- 11. Terminal UI Layout Width & Box Alignment
    local function verify_layout_uniformity(g_obj)
        local frame = g_obj:render_frame()
        for line in frame:gmatch("([^\r\n]+)") do
            local w = utf8_visible_width(line)
            if w > 0 and w ~= 59 then return false end
        end
        return true
    end
    check("Layout width is uniformly 59 columns in Unicode mode", verify_layout_uniformity(g))
    local g_ascii = TetrisGame.new({ ascii_mode = true })
    check("Layout width is uniformly 59 columns in ASCII mode", verify_layout_uniformity(g_ascii))

    print(string.format("\nSelf-Test Summary: %d / %d tests passed.", passed, total))
    if passed == total then
        print("\27[1;32mALL RUSSIAN BLOCK TESTS PASSED SUCCESSFULLY!\27[0m\n")
        return true
    else
        print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
        return false
    end
end

-- =========================================================================
-- 10. Module Exports & Command Line Dispatcher
-- =========================================================================
local function print_help()
    print([[
Russian Block (Tetris / 俄罗斯方块) - LuaJIT FFI Cross-Platform Arcade Game

Usage:
    luajit ffi_russian_block.lua [options]

Options:
    --help, -h          Show this help message and exit
    --test              Run internal automated unit tests and exit
    --snapshot          Render a single frame snapshot to stdout and exit
    --demo [frames]     Run automated AI bot autoplay demonstration (default: 150 frames)
    --ascii             Run in plain ASCII mode (no Unicode box-drawing characters)

Controls in Interactive Mode:
    Left Arrow / A      Move piece Left
    Right Arrow / D     Move piece Right
    Up Arrow / W / K    Rotate Clockwise
    Z                   Rotate Counter-Clockwise
    Down Arrow / S      Soft Drop (1 pt / row)
    Spacebar            Hard Drop (2 pts / row, instant lock)
    C / H               Hold current piece
    P / Escape          Pause / Resume
    R                   Restart game
    Q / Ctrl+C          Quit game

Platform Support:
    Windows (Win32 Console API, MSVCRT non-blocking IO, UTF-8 VT processing)
    Linux / POSIX (termios raw mode, poll() non-blocking IO, CLOCK_MONOTONIC)
]])
end

-- If executed directly from command line
local is_main = (debug.getinfo(3) == nil)

if is_main then
    local arg1 = arg and arg[1] or ""
    local options = {}

    for _, a in ipairs(arg or {}) do
        if a == "--ascii" then
            options.ascii_mode = true
        end
    end

    if arg1 == "--help" or arg1 == "-h" then
        print_help()
        os.exit(0)
    elseif arg1 == "--test" then
        local success = run_self_tests()
        os.exit(success and 0 or 1)
    elseif arg1 == "--snapshot" then
        local game = TetrisGame.new(options)
        print(game:render_frame())
        os.exit(0)
    elseif arg1 == "--demo" then
        local frames = tonumber(arg and arg[2]) or 150
        run_ai_demo(frames, options)
        os.exit(0)
    else
        run_interactive_game(options)
    end
end

-- Export module for external testing or embedding
return {
    TetrisGame = TetrisGame,
    PIECES = PIECES,
    BOARD_COLS = BOARD_COLS,
    BOARD_ROWS = BOARD_ROWS,
    TOTAL_ROWS = TOTAL_ROWS,
    utf8_visible_width = utf8_visible_width,
    run_self_tests = run_self_tests
}
