--[[
    ffi_game_snake.lua
    A terminal Snake arcade game built entirely using LuaJIT FFI.

    Demonstrates FFI capabilities:
    1. POSIX Raw Terminal Mode (tcgetattr / tcsetattr) for instant non-blocking keystrokes (no Enter needed).
    2. Non-blocking I/O polling via poll() syscall.
    3. High-resolution game-loop delta-time timing via clock_gettime(CLOCK_MONOTONIC).
    4. Fast fixed-size screen buffer array using C structs (ffi.new("Cell[?]", W * H)).
    5. High-performance terminal rendering using double-buffered ANSI escape codes.
]]

local ffi = require("ffi")

-- 1. C Declarations for POSIX Terminal, Polling, and High-Resolution Clock
ffi.cdef[[
    // Terminal manipulation
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

    // Non-blocking poll & I/O
    struct pollfd {
        int   fd;
        short events;
        short revents;
    };

    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, size_t count);

    // Timing
    typedef struct { long tv_sec; long tv_nsec; } timespec_t;
    int clock_gettime(int clk_id, timespec_t *tp);
    int usleep(unsigned int usec);
]]

-- Constants
local STDIN_FILENO = 0
local TCSANOW = 0
local ICANON = 2
local ECHO = 8
local POLLIN = 1
local CLOCK_MONOTONIC = 1

-- 2. Terminal Raw Mode Management via FFI
local orig_termios = ffi.new("struct termios")
local raw_termios = ffi.new("struct termios")
local has_raw_mode = false

local function enable_raw_mode()
    ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
    ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

    -- Disable canonical mode (line buffering) and echo
    raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
    has_raw_mode = true

    -- Hide cursor and clear screen
    io.write("\27[?25l\27[2J")
    io.flush()
end

local function disable_raw_mode()
    if has_raw_mode then
        -- Restore cursor, reset colors, restore terminal
        io.write("\27[?25h\27[0m\n")
        io.flush()
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
        has_raw_mode = false
    end
end

-- 3. Non-blocking Key Reading via poll()
local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
local input_buf = ffi.new("char[16]")

local function read_key()
    local ret = ffi.C.poll(pfd, 1, 0)
    if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local n = ffi.C.read(STDIN_FILENO, input_buf, 16)
        if n > 0 then
            local ch = string.char(input_buf[0])
            -- Handle arrow keys: ESC [ A/B/C/D
            if ch == "\27" and n >= 3 and input_buf[1] == 91 then -- 91 is '['
                local code = input_buf[2]
                if code == 65 then return "UP" end
                if code == 66 then return "DOWN" end
                if code == 67 then return "RIGHT" end
                if code == 68 then return "LEFT" end
            end
            return ch:lower()
        end
    end
    return nil
end

local function get_time_ms()
    local ts = ffi.new("timespec_t")
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

-- 4. Game Configuration and Board
local WIDTH = 40
local HEIGHT = 20

ffi.cdef[[
    typedef struct {
        char ch;
        uint8_t color; // 0: default, 1: border, 2: snake head, 3: snake body, 4: food
    } ScreenCell;
]]

local screen = ffi.new("ScreenCell[?]", WIDTH * HEIGHT)

local function screen_set(x, y, ch, color)
    if x >= 1 and x <= WIDTH and y >= 1 and y <= HEIGHT then
        local idx = (y - 1) * WIDTH + (x - 1)
        screen[idx].ch = ch:byte()
        screen[idx].color = color
    end
end

local function render_screen(score, high_score)
    local out = { "\27[H" } -- Home cursor

    table.insert(out, string.format(" \27[1;36m=== LUAJIT FFI TERMINAL SNAKE ===\27[0m\n"))
    table.insert(out, string.format(" Score: \27[1;32m%-4d\27[0m  High Score: \27[1;33m%-4d\27[0m  Controls: \27[1mWASD / Arrows, Q: Quit\27[0m\n", score, high_score))

    for y = 1, HEIGHT do
        for x = 1, WIDTH do
            local cell = screen[(y - 1) * WIDTH + (x - 1)]
            local ch = string.char(cell.ch)
            if cell.color == 1 then
                table.insert(out, "\27[1;34m" .. ch .. "\27[0m")       -- Cyan borders
            elseif cell.color == 2 then
                table.insert(out, "\27[1;32m" .. ch .. "\27[0m")       -- Bright green head
            elseif cell.color == 3 then
                table.insert(out, "\27[32m" .. ch .. "\27[0m")         -- Green body
            elseif cell.color == 4 then
                table.insert(out, "\27[1;31m" .. ch .. "\27[0m")       -- Bright red food
            else
                table.insert(out, " ")
            end
        end
        table.insert(out, "\n")
    end

    io.write(table.concat(out))
    io.flush()
end

-- 5. Game State & Logic
local function run_game()
    math.randomseed(os.time())
    enable_raw_mode()

    local snake = {
        {x = 10, y = 10},
        {x = 9,  y = 10},
        {x = 8,  y = 10},
    }
    local dx, dy = 1, 0
    local score = 0
    local high_score = 0
    local game_over = false
    local speed_ms = 90
    local food = {x = 20, y = 10}

    local function spawn_food()
        while true do
            local fx = math.random(2, WIDTH - 1)
            local fy = math.random(2, HEIGHT - 1)
            local on_snake = false
            for _, seg in ipairs(snake) do
                if seg.x == fx and seg.y == fy then
                    on_snake = true
                    break
                end
            end
            if not on_snake then
                food.x = fx
                food.y = fy
                break
            end
        end
    end

    local last_step = get_time_ms()

    while not game_over do
        -- A. Handle non-blocking input
        local key = read_key()
        if key == "q" then
            break
        elseif (key == "w" or key == "UP") and dy == 0 then
            dx, dy = 0, -1
        elseif (key == "s" or key == "DOWN") and dy == 0 then
            dx, dy = 0, 1
        elseif (key == "a" or key == "LEFT") and dx == 0 then
            dx, dy = -1, 0
        elseif (key == "d" or key == "RIGHT") and dx == 0 then
            dx, dy = 1, 0
        end

        -- B. Fixed time-step update
        local now = get_time_ms()
        if now - last_step >= speed_ms then
            last_step = now

            -- Move snake head
            local head = {x = snake[1].x + dx, y = snake[1].y + dy}

            -- Check wall collision
            if head.x <= 1 or head.x >= WIDTH or head.y <= 1 or head.y >= HEIGHT then
                game_over = true
            end

            -- Check self-collision
            for i = 1, #snake - 1 do
                if snake[i].x == head.x and snake[i].y == head.y then
                    game_over = true
                end
            end

            if not game_over then
                table.insert(snake, 1, head)

                -- Check food eaten
                if head.x == food.x and head.y == food.y then
                    score = score + 10
                    if score > high_score then high_score = score end
                    if speed_ms > 45 then speed_ms = speed_ms - 1 end
                    spawn_food()
                else
                    table.remove(snake)
                end

                -- C. Render into ScreenCell C buffer
                for y = 1, HEIGHT do
                    for x = 1, WIDTH do
                        if x == 1 or x == WIDTH or y == 1 or y == HEIGHT then
                            screen_set(x, y, "#", 1) -- Wall
                        else
                            screen_set(x, y, " ", 0) -- Empty
                        end
                    end
                end

                -- Place food
                screen_set(food.x, food.y, "@", 4)

                -- Place snake body & head
                for i = #snake, 2, -1 do
                    screen_set(snake[i].x, snake[i].y, "o", 3)
                end
                screen_set(snake[1].x, snake[1].y, "O", 2)

                render_screen(score, high_score)
            end
        end

        ffi.C.usleep(4000) -- ~4ms frame polling to avoid CPU busy-waiting
    end

    disable_raw_mode()

    if game_over then
        print(string.format("\n\27[1;31mGAME OVER!\27[0m Final Score: \27[1;32m%d\27[0m\n", score))
    else
        print("\nGame exited.")
    end
end

-- Safe execution with guaranteed terminal restoration
local ok, err = pcall(run_game)
disable_raw_mode()
if not ok then
    io.stderr:write("Error: " .. tostring(err) .. "\n")
end
