#!/usr/bin/env luajit
--[[
    ffi_breakout.lua
    Cross-platform terminal Breakout built with LuaJIT FFI.

    Controls: A/D or Left/Right to move, P to pause, Q to quit.
    Modes: --help, --test, and --snapshot [--ascii].
]]

local ffi = require("ffi")
local bit = require("bit")

local WIDTH, HEIGHT = 64, 22
local PADDLE_Y = 20
local BRICK_ROWS, BRICK_COLS = 5, 10
local BRICK_W, BRICK_H = 5, 1
local BRICK_X0, BRICK_Y0, BRICK_GAP = 3, 3, 6
local BALL_RADIUS = 0.35

local Game = {}
Game.__index = Game
local terminal_callbacks = {}

local function make_bricks()
    local bricks = {}
    for row = 1, BRICK_ROWS do
        for col = 1, BRICK_COLS do
            bricks[#bricks + 1] = {
                x = BRICK_X0 + (col - 1) * BRICK_GAP,
                y = BRICK_Y0 + row - 1,
                w = BRICK_W,
                h = BRICK_H,
                row = row,
            }
        end
    end
    return bricks
end

function Game.new()
    local self = setmetatable({}, Game)
    self.score = 0
    self.lives = 3
    self.level = 1
    self.paddle_x = WIDTH / 2
    self.paddle_width = 9
    self.paddle_speed = 42
    self.brick_speed = 16
    self.paused = false
    self.game_over = false
    self.bricks = make_bricks()
    self:reset_ball()
    return self
end

function Game:reset_ball()
    self.ball_x = self.paddle_x
    self.ball_y = PADDLE_Y - 1
    self.ball_vx = 5
    self.ball_vy = -self.brick_speed
end

function Game:move_paddle(direction, dt)
    self.paddle_x = self.paddle_x + direction * self.paddle_speed * dt
    local half = self.paddle_width / 2
    self.paddle_x = math.max(2 + half, math.min(WIDTH - 1 - half, self.paddle_x))
end

function Game:remaining_bricks()
    return #self.bricks
end

function Game:update(dt)
    if self.paused or self.game_over or dt <= 0 then return end
    dt = math.min(dt, 0.05)
    local speed = math.max(math.abs(self.ball_vx), math.abs(self.ball_vy))
    local steps = math.max(1, math.ceil(dt * speed / 0.35))
    local step_dt = dt / steps

    for _ = 1, steps do
        local old_x, old_y = self.ball_x, self.ball_y
        self.ball_x = self.ball_x + self.ball_vx * step_dt
        self.ball_y = self.ball_y + self.ball_vy * step_dt

        if self.ball_x - BALL_RADIUS <= 2 then
            self.ball_x = 2 + BALL_RADIUS
            self.ball_vx = math.abs(self.ball_vx)
        elseif self.ball_x + BALL_RADIUS >= WIDTH - 1 then
            self.ball_x = WIDTH - 1 - BALL_RADIUS
            self.ball_vx = -math.abs(self.ball_vx)
        end
        if self.ball_y - BALL_RADIUS <= 2 then
            self.ball_y = 2 + BALL_RADIUS
            self.ball_vy = math.abs(self.ball_vy)
        end

        -- Paddle collision is only valid while the ball is descending.
        if self.ball_vy > 0 and old_y <= PADDLE_Y - BALL_RADIUS and
           self.ball_y + BALL_RADIUS >= PADDLE_Y and
           math.abs(self.ball_x - self.paddle_x) <= self.paddle_width / 2 + BALL_RADIUS then
            self.ball_y = PADDLE_Y - BALL_RADIUS
            local impact = (self.ball_x - self.paddle_x) / (self.paddle_width / 2)
            impact = math.max(-1, math.min(1, impact))
            local speed = math.sqrt(self.ball_vx * self.ball_vx + self.ball_vy * self.ball_vy)
            self.ball_vx = impact * speed * 0.82
            self.ball_vy = -math.sqrt(math.max(1, speed * speed - self.ball_vx * self.ball_vx))
        end

        -- Expanded brick bounds approximate a circular ball against rectangular bricks.
        for i = #self.bricks, 1, -1 do
            local brick = self.bricks[i]
            local left, right = brick.x - BALL_RADIUS, brick.x + brick.w + BALL_RADIUS
            local top, bottom = brick.y - BALL_RADIUS, brick.y + brick.h + BALL_RADIUS
            if self.ball_x >= left and self.ball_x <= right and self.ball_y >= top and self.ball_y <= bottom then
                if old_x < left or old_x > right then
                    self.ball_vx = -self.ball_vx
                else
                    self.ball_vy = -self.ball_vy
                end
                table.remove(self.bricks, i)
                self.score = self.score + (BRICK_ROWS - brick.row + 1) * 10
                break
            end
        end

        if #self.bricks == 0 then
            self.level = self.level + 1
            self.brick_speed = self.brick_speed + 1.5
            self.bricks = make_bricks()
            self:reset_ball()
            return
        end

        if self.ball_y - BALL_RADIUS > HEIGHT - 1 then
            self.lives = self.lives - 1
            if self.lives <= 0 then
                self.lives = 0
                self.game_over = true
            else
                self:reset_ball()
            end
            return
        end
    end
end

local function make_board(game)
    local board = {}
    for y = 1, HEIGHT do
        local row = {}
        for x = 1, WIDTH do row[x] = " " end
        board[y] = row
    end
    for x = 1, WIDTH do
        board[1][x] = (x == 1 or x == WIDTH) and "+" or "-"
        board[HEIGHT][x] = (x == 1 or x == WIDTH) and "+" or "-"
    end
    for y = 2, HEIGHT - 1 do
        board[y][1], board[y][WIDTH] = "|", "|"
    end

    for _, brick in ipairs(game.bricks) do
        for x = brick.x, brick.x + brick.w - 1 do
            if x >= 2 and x < WIDTH then board[brick.y][x] = "#" end
        end
    end

    local paddle_left = math.floor(game.paddle_x - game.paddle_width / 2 + 0.5)
    local paddle_right = paddle_left + game.paddle_width - 1
    for x = paddle_left, paddle_right do
        if x >= 2 and x < WIDTH then board[PADDLE_Y][x] = "=" end
    end

    local ball_x = math.max(2, math.min(WIDTH - 1, math.floor(game.ball_x + 0.5)))
    local ball_y = math.max(2, math.min(HEIGHT - 1, math.floor(game.ball_y + 0.5)))
    board[ball_y][ball_x] = "o"

    local lines = {}
    for y = 1, HEIGHT do lines[y] = table.concat(board[y]) end
    return lines
end

local function render_frame(game, use_color)
    local status = string.format(" BREAKOUT   SCORE %05d   LEVEL %02d   LIVES %d ", game.score, game.level, game.lives)
    if game.paused then status = status .. "  [PAUSED]" end
    if game.game_over then status = status .. "  GAME OVER" end
    local lines = { status, " A/D or Arrows: Move   P: Pause   Q: Quit" }
    local board_lines = make_board(game)
    for _, line in ipairs(board_lines) do
        if use_color then
            local colored = {}
            for x = 1, #line do
                local ch = line:sub(x, x)
                if ch == "#" then
                    colored[#colored + 1] = "\27[1;33m#\27[0m"
                elseif ch == "=" then
                    colored[#colored + 1] = "\27[1;36m=\27[0m"
                elseif ch == "o" then
                    colored[#colored + 1] = "\27[1;37mo\27[0m"
                else
                    colored[#colored + 1] = ch
                end
            end
            line = table.concat(colored)
        end
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end    local function run_self_tests()

    local function check(name, condition)
        assert(condition, "FAIL: " .. name)
        print("  PASS: " .. name)
    end

    local g = Game.new()
    check("initial state has 3 lives and 50 bricks", g.lives == 3 and g:remaining_bricks() == 50)
    g:move_paddle(-1, 1)
    check("paddle movement clamps at left boundary", g.paddle_x == 2 + g.paddle_width / 2)
    g:move_paddle(1, 2)
    check("paddle movement clamps at right boundary", g.paddle_x == WIDTH - 1 - g.paddle_width / 2)

    g = Game.new()
    g.bricks = {
        { x = 10, y = 5, w = 5, h = 1, row = 1 },
        { x = 20, y = 5, w = 5, h = 1, row = 2 },
    }
    g.ball_x, g.ball_y, g.ball_vx, g.ball_vy = 12, 6.2, 0, -10
    g:update(0.04)
    check("ball removes a hit brick and scores", #g.bricks == 1 and g.score == 50)

    g.bricks = { { x = 10, y = 5, w = 5, h = 1, row = 1 } }
    g.ball_x, g.ball_y, g.ball_vx, g.ball_vy = 12, 6.2, 0, -10
    g:update(0.04)
    check("clearing last brick advances level", g.level == 2 and #g.bricks == 50)

    g = Game.new()
    g.ball_x, g.ball_y, g.ball_vx, g.ball_vy = 2.5, 10, -12, 0
    g:update(0.05)
    check("left wall collision reverses horizontal velocity", g.ball_vx > 0)
    g = Game.new()
    g.ball_x, g.ball_y, g.ball_vx, g.ball_vy = g.paddle_x, PADDLE_Y - 0.5, 0, 12
    g:update(0.05)
    check("paddle collision sends ball upward", g.ball_vy < 0)
    g.ball_x, g.ball_y, g.ball_vx, g.ball_vy = 32, HEIGHT - 1.1, 0, 10
    g:update(0.05)
    check("miss costs one life and resets ball", g.lives == 2 and g.ball_y < PADDLE_Y)
    g.lives = 1
    g.ball_x, g.ball_y, g.ball_vx, g.ball_vy = 32, HEIGHT - 1.1, 0, 10
    g:update(0.05)
    check("last miss ends the game", g.game_over and g.lives == 0)

    local frame = render_frame(Game.new(), false)
    check("snapshot renderer returns a fixed-width board", #frame > 100 and frame:find("BREAKOUT", 1, true) ~= nil)
    print("ALL BREAKOUT TESTS PASSED")
end

local function print_help()
    print([[Breakout — LuaJIT FFI Terminal Arcade

Usage: luajit ffi_breakout.lua [--help|--test|--snapshot] [--ascii]

Controls: A/D or Left/Right move the paddle, P pauses, Q quits.

Example: luajit ffi_breakout.lua]])
end

local function launch_game(use_color)
    local is_windows = ffi.os == "Windows"
    local kernel32, msvcrt
    local original_mode, original_output_mode
    local original_termios
    local raw_enabled = false
    local interrupted = false
    local old_input_codepage, old_output_codepage

    if is_windows then
        ffi.cdef[[
            typedef struct { short X; short Y; } BreakoutCoord;
            typedef struct { short Left; short Top; short Right; short Bottom; } BreakoutRect;
            typedef struct {
                BreakoutCoord dwSize;
                BreakoutCoord dwCursorPosition;
                uint16_t wAttributes;
                BreakoutRect srWindow;
                BreakoutCoord dwMaximumWindowSize;
            } BreakoutConsoleInfo;
            int __stdcall GetConsoleMode(void *handle, uint32_t *mode);
            int __stdcall SetConsoleMode(void *handle, uint32_t mode);
            void *__stdcall GetStdHandle(uint32_t which);
            int __stdcall SetConsoleOutputCP(uint32_t codepage);
            uint32_t __stdcall GetConsoleCP(void);
            int __stdcall SetConsoleCP(uint32_t codepage);
            uint32_t __stdcall GetConsoleOutputCP(void);
            void __stdcall Sleep(uint32_t milliseconds);
            int __stdcall GetConsoleScreenBufferInfo(void *handle, BreakoutConsoleInfo *info);
            uint64_t __stdcall GetTickCount64(void);
            int _kbhit(void);
            int _getch(void);
        ]]
        kernel32 = ffi.load("kernel32")
        msvcrt = ffi.load("msvcrt")
    else
        ffi.cdef[[
            typedef unsigned char breakout_cc_t;
            typedef unsigned int breakout_speed_t;
            typedef unsigned int breakout_tcflag_t;
            struct BreakoutTermios {
                breakout_tcflag_t c_iflag;
                breakout_tcflag_t c_oflag;
                breakout_tcflag_t c_cflag;
                breakout_tcflag_t c_lflag;
                breakout_cc_t c_line;
                breakout_cc_t c_cc[32];
                breakout_speed_t c_ispeed;
                breakout_speed_t c_ospeed;
            };
            struct BreakoutPollfd { int fd; short events; short revents; };
            struct BreakoutTimespec { long tv_sec; long tv_nsec; };
            int tcgetattr(int fd, struct BreakoutTermios *termios_p);
            int tcsetattr(int fd, int actions, const struct BreakoutTermios *termios_p);
            int poll(struct BreakoutPollfd *fds, unsigned long nfds, int timeout);
            long read(int fd, void *buf, size_t count);
            int clock_gettime(int clock_id, struct BreakoutTimespec *tp);
            int usleep(unsigned int usec);
            int ioctl(int fd, unsigned long request, void *argp);
            long write(int fd, const void *buf, size_t count);
            typedef void (*breakout_sighandler_t)(int);
            breakout_sighandler_t signal(int signum, breakout_sighandler_t handler);
        ]]
    end

    local game = Game.new()
    local input_queue = {}
    local pollfd, input_buf
    local input_handle, output_handle
    local esc = "\27"

    local function restore_terminal()
        if not raw_enabled then return end
        if is_windows then
            kernel32.SetConsoleMode(input_handle, original_mode[0])
            kernel32.SetConsoleMode(output_handle, original_output_mode[0])
            if old_input_codepage and old_input_codepage ~= 0 then
                kernel32.SetConsoleCP(old_input_codepage)
            end
            if old_output_codepage and old_output_codepage ~= 0 then
                kernel32.SetConsoleOutputCP(old_output_codepage)
            end
        else
            ffi.C.tcsetattr(0, 0, original_termios)
        end
        raw_enabled = false
        io.write(esc .. "[?7h" .. esc .. "[?1049l" .. esc .. "[?25h" .. esc .. "[0m")
        io.flush()
    end

    local function enter_terminal()
        if is_windows then
            input_handle = kernel32.GetStdHandle(0xFFFFFFF6)
            output_handle = kernel32.GetStdHandle(0xFFFFFFF5)
            original_mode, original_output_mode = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
            assert(kernel32.GetConsoleMode(input_handle, original_mode) ~= 0, "stdin is not a Windows console")
            assert(kernel32.GetConsoleMode(output_handle, original_output_mode) ~= 0, "stdout is not a Windows console")
            local console_info = ffi.new("BreakoutConsoleInfo")
            if kernel32.GetConsoleScreenBufferInfo(output_handle, console_info) ~= 0 then
                local cols = console_info.srWindow.Right - console_info.srWindow.Left + 1
                local rows = console_info.srWindow.Bottom - console_info.srWindow.Top + 1
                if cols < WIDTH or rows < HEIGHT + 2 then
                    error("Breakout needs a terminal at least " .. WIDTH .. " columns by " .. (HEIGHT + 2) .. " rows")
                end
            end
            old_input_codepage = kernel32.GetConsoleCP()
            old_output_codepage = kernel32.GetConsoleOutputCP()
            kernel32.SetConsoleOutputCP(65001)
            kernel32.SetConsoleCP(65001)
            raw_enabled = true
            local out_mode = bit.bor(original_output_mode[0], 0x0004)
            kernel32.SetConsoleMode(output_handle, out_mode)
            local in_mode = bit.band(original_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
            kernel32.SetConsoleMode(input_handle, in_mode)
        else
            original_termios = ffi.new("struct BreakoutTermios")
            assert(ffi.C.tcgetattr(0, original_termios) == 0, "Breakout requires an interactive terminal")
            local winsize = ffi.new("struct { unsigned short rows, cols, xpixel, ypixel; }")
            if ffi.C.ioctl(1, 0x5413, winsize) == 0 and winsize.cols > 0 and
               (winsize.cols < WIDTH or winsize.rows < HEIGHT + 2) then
                error("Breakout needs a terminal at least " .. WIDTH .. " columns by " .. (HEIGHT + 2) .. " rows")
            end
            local raw = ffi.new("struct BreakoutTermios")
            ffi.copy(raw, original_termios, ffi.sizeof("struct BreakoutTermios"))
            -- Disable canonical input, echo, signal processing, and software flow control.
            raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
            raw.c_iflag = bit.band(raw.c_iflag, bit.bnot(bit.bor(0x0400, 0x0100)))
            raw.c_cc[5], raw.c_cc[6] = 0, 0
            assert(ffi.C.tcsetattr(0, 0, raw) == 0, "could not enable raw terminal mode")
            raw_enabled = true
            pollfd = ffi.new("struct BreakoutPollfd", { fd = 0, events = 1, revents = 0 })
            input_buf = ffi.new("char[64]")
        end
        raw_enabled = true
        io.write(esc .. "[?1049h" .. esc .. "[?25l" .. esc .. "[?7l" .. esc .. "[2J")
        io.flush()
    end

    local function get_time()
        if is_windows then return tonumber(kernel32.GetTickCount64()) / 1000 end
        local ts = ffi.new("struct BreakoutTimespec")
        ffi.C.clock_gettime(1, ts)
        return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
    end

    local function read_key(timeout_ms)
        if #input_queue > 0 then return table.remove(input_queue, 1) end
        if is_windows then
            local elapsed = 0
            while elapsed < timeout_ms do
                if msvcrt._kbhit() ~= 0 then
                    local ch = msvcrt._getch()
                    if ch == 0 or ch == 224 then
                        local code = msvcrt._getch()
                        if code == 75 then return "left" elseif code == 77 then return "right" end
                    elseif ch == 27 then
                        return "q"
                    elseif ch == 3 then return "q"
                    else return string.char(ch):lower() end
                end
                kernel32.Sleep(2)
                elapsed = elapsed + 2
            end
            return nil
        end

        pollfd.revents = 0
        if ffi.C.poll(pollfd, 1, timeout_ms) <= 0 then return nil end
        local n = ffi.C.read(0, input_buf, 64)
        if n <= 0 then return nil end
        local keys, i = {}, 0
        while i < n do
            local ch = input_buf[i]
            if ch == 27 and i + 2 < n and input_buf[i + 1] == 91 then
                local code = input_buf[i + 2]
                if code == 67 then keys[#keys + 1] = "right"
                elseif code == 68 then keys[#keys + 1] = "left" end
                i = i + 3
            else
                local s = string.char(ch):lower()
                if s == "\3" then s = "q" end
                keys[#keys + 1] = s
                i = i + 1
            end
        end
        for j = 2, #keys do input_queue[#input_queue + 1] = keys[j] end
        return keys[1]
    end

    local signal_cb
    if not is_windows then
        signal_cb = ffi.cast("breakout_sighandler_t", function() interrupted = true end)
        terminal_callbacks[#terminal_callbacks + 1] = signal_cb
        ffi.C.signal(2, signal_cb)  -- SIGINT
        ffi.C.signal(15, signal_cb) -- SIGTERM
    end

    local function draw()
        io.write("\27[?2026h\27[H" .. render_frame(game, use_color) .. "\27[?2026l")
        io.flush()
    end

    local ok, err = pcall(function()
        enter_terminal()
        local last = get_time()
        local running = true
        while running and not interrupted and not game.game_over do
            local key = read_key(16)
            while key do
                if key == "q" then
                    running = false
                    break
                elseif key == "left" or key == "a" then
                    game:move_paddle(-1, 0.035)
                elseif key == "right" or key == "d" then
                    game:move_paddle(1, 0.035)
                elseif key == "p" then
                    game.paused = not game.paused
                end
                key = read_key(0)
            end

            local now = get_time()
            local dt = math.min(0.05, now - last)
            last = now
            game:update(dt)
            draw()
        end
    end)

    restore_terminal()
    if not ok then error(err) end
    if game.game_over then
        print(string.format("Game over — score %d, level %d.", game.score, game.level))
    else
        print(string.format("Thanks for playing — score %d.", game.score))
    end
end

local function main(args)
    local snapshot = false
    local ascii = false
    for _, option in ipairs(args or {}) do
        if option == "--help" or option == "-h" then print_help(); return
        elseif option == "--test" then run_self_tests(); return
        elseif option == "--snapshot" then snapshot = true
        elseif option == "--ascii" then ascii = true
        else
            io.stderr:write("Unknown option: " .. tostring(option) .. "\n")
            print_help()
            os.exit(2)
        end
    end

    if snapshot then
        print(render_frame(Game.new(), not ascii))
    else
        launch_game(not ascii)
    end
end

local M = {
    Game = Game,
    make_bricks = make_bricks,
    make_board = make_board,
    render_frame = render_frame,
    WIDTH = WIDTH,
    HEIGHT = HEIGHT,
    PADDLE_Y = PADDLE_Y,
}

if ... == "ffi_breakout" then
    return M
end
main(arg or {})
