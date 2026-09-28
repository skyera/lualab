#!/usr/bin/env luajit
--[[
    ffi_heap_sort.lua
    A step-by-step heap-sort visualization TUI built with LuaJIT FFI.

    Demonstrates FFI capabilities:
    1. POSIX Raw Terminal Mode (tcgetattr / tcsetattr) for instant keystrokes.
    2. Non-blocking I/O polling via poll() syscall.
    3. Native C int array allocation (ffi.new("int[?]", n)) for the data.
    4. High-resolution timing via clock_gettime(CLOCK_MONOTONIC).
    5. ANSI escape-code TUI with differential refresh and synchronized updates.

    Usage:
        luajit ffi_heap_sort.lua [n1 n2 n3 ...]
        luajit ffi_heap_sort.lua              -- generates 12 random numbers

    Controls:
        Space / Enter   → advance one step
        a               → auto-play (toggle)
        r               → restart with new random data
        q / Esc         → quit
]]

local ffi = require("ffi")
local bit = require("bit")

-- ─────────────────────────── FFI C declarations ───────────────────────────

ffi.cdef[[
    /* terminal */
    typedef unsigned char  cc_t;
    typedef unsigned int   speed_t;
    typedef unsigned int   tcflag_t;

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

    /* polling / reading */
    struct pollfd {
        int   fd;
        short events;
        short revents;
    };

    int  poll(struct pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, size_t count);

    /* timing */
    typedef struct { long tv_sec; long tv_nsec; } timespec_t;
    int clock_gettime(int clk_id, timespec_t *tp);
    int usleep(unsigned int usec);

    /* ioctl for terminal size */
    struct winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };
    int ioctl(int fd, unsigned long request, ...);
]]

-- ─────────────────────────── Constants ───────────────────────────

local STDIN_FILENO    = 0
local STDOUT_FILENO   = 1
local TCSANOW         = 0
local ICANON          = 0x0002
local ECHO            = 0x0008
local POLLIN          = 0x0001
local CLOCK_MONOTONIC = 1
local TIOCGWINSZ      = 0x5413   -- Linux

-- ─────────────────────────── Terminal helpers ───────────────────────────

local orig_termios  = ffi.new("struct termios")
local raw_termios   = ffi.new("struct termios")
local has_raw_mode  = false

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(STDOUT_FILENO, TIOCGWINSZ, ws) == 0 then
        return ws.ws_row, ws.ws_col
    end
    return 24, 80  -- fallback
end

local function enable_raw_mode()
    ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
    ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
    raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
    has_raw_mode = true
    -- Enter alt screen, hide cursor, disable line wrap
    io.write("\27[?1049h\27[?25l\27[?7l")
    io.flush()
end

local function disable_raw_mode()
    if has_raw_mode then
        -- Leave alt screen, show cursor, re-enable line wrap, reset colors
        io.write("\27[?7h\27[?25h\27[0m\27[?1049l")
        io.flush()
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
        has_raw_mode = false
    end
end

-- Graceful exit helper
local function safe_exit(code)
    disable_raw_mode()
    os.exit(code or 0)
end

-- ─────────────────────────── Non-blocking key input ───────────────────────────

local pfd       = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
local input_buf = ffi.new("char[16]")

local function read_key(timeout_ms)
    timeout_ms = timeout_ms or 0
    local ret = ffi.C.poll(pfd, 1, timeout_ms)
    if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local n = ffi.C.read(STDIN_FILENO, input_buf, 16)
        if n > 0 then
            local ch = input_buf[0]
            if ch == 27 then
                if n >= 3 and input_buf[1] == 91 then
                    local code = input_buf[2]
                    if code == 65 then return "UP"    end
                    if code == 66 then return "DOWN"  end
                    if code == 67 then return "RIGHT" end
                    if code == 68 then return "LEFT"  end
                end
                return "ESC"
            end
            return string.char(ch)
        end
    end
    return nil
end

-- ─────────────────────────── Timing ───────────────────────────

local ts = ffi.new("timespec_t")

local function get_time_ms()
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) * 1000.0 + tonumber(ts.tv_nsec) / 1000000.0
end

local function sleep_ms(ms)
    ffi.C.usleep(ms * 1000)
end

-- ─────────────────────────── ANSI color palette ───────────────────────────

local C = {
    reset    = "\27[0m",
    bold     = "\27[1m",
    dim      = "\27[2m",
    -- foreground
    white    = "\27[97m",
    black    = "\27[30m",
    red      = "\27[91m",
    green    = "\27[92m",
    yellow   = "\27[93m",
    blue     = "\27[94m",
    magenta  = "\27[95m",
    cyan     = "\27[96m",
    gray     = "\27[90m",
    -- background
    bg_red     = "\27[101m",
    bg_green   = "\27[102m",
    bg_yellow  = "\27[103m",
    bg_blue    = "\27[104m",
    bg_magenta = "\27[105m",
    bg_cyan    = "\27[46m",
    bg_gray    = "\27[100m",
    bg_white   = "\27[107m",
}

-- ─────────────────────────── Data setup ───────────────────────────

local n           -- number of elements
local arr         -- ffi int array (0-indexed)
local arr_orig    -- original copy for restart

local function parse_args()
    local nums = {}
    for i = 1, #arg do
        local v = tonumber(arg[i])
        if not v then
            io.stderr:write("Error: invalid argument \"" .. arg[i] .. "\" – expected an integer.\n")
            os.exit(1)
        end
        nums[#nums + 1] = math.floor(v)
    end
    if #nums == 0 then
        -- Generate random data
        math.randomseed(os.time())
        local count = 12
        for _ = 1, count do
            nums[#nums + 1] = math.random(1, 99)
        end
    end
    return nums
end

local function init_array(nums)
    n = #nums
    arr = ffi.new("int[?]", n)
    arr_orig = ffi.new("int[?]", n)
    for i = 0, n - 1 do
        arr[i] = nums[i + 1]
        arr_orig[i] = nums[i + 1]
    end
end

local function reset_array()
    for i = 0, n - 1 do
        arr[i] = arr_orig[i]
    end
end

-- ─────────────────────────── Step generator ───────────────────────────
-- We pre-generate all the steps so the user can walk through them.
-- Each step is a table:
--   { phase, description, highlight_a, highlight_b, swap, heap_size, sorted_from }
-- We record snapshots of the array at each step.

local steps = {}
local snapshots = {}

local function record_snapshot()
    local snap = ffi.new("int[?]", n)
    ffi.copy(snap, arr, n * ffi.sizeof("int"))
    return snap
end

local function generate_steps()
    steps = {}
    snapshots = {}
    reset_array()

    local function add_step(phase, desc, hi_a, hi_b, is_swap, heap_sz)
        steps[#steps + 1] = {
            phase      = phase,
            desc       = desc,
            highlight_a = hi_a,       -- 0-indexed or -1
            highlight_b = hi_b,       -- 0-indexed or -1
            is_swap    = is_swap or false,
            heap_size  = heap_sz,
        }
        snapshots[#snapshots + 1] = record_snapshot()
    end

    -- Initial state
    add_step("init", "Initial array – press Space to start", -1, -1, false, n)

    -- ── Phase 1: Build max-heap (bottom-up) ──
    local function sift_down(start_idx, heap_len, phase_name)
        local root = start_idx
        while true do
            local left  = 2 * root + 1
            local right = 2 * root + 2
            local largest = root

            if left < heap_len then
                add_step(phase_name,
                    string.format("Compare arr[%d]=%d with left child arr[%d]=%d",
                        largest, arr[largest], left, arr[left]),
                    largest, left, false, heap_len)
                if arr[left] > arr[largest] then
                    largest = left
                end
            end

            if right < heap_len then
                add_step(phase_name,
                    string.format("Compare arr[%d]=%d with right child arr[%d]=%d",
                        largest, arr[largest], right, arr[right]),
                    largest, right, false, heap_len)
                if arr[right] > arr[largest] then
                    largest = right
                end
            end

            if largest ~= root then
                add_step(phase_name,
                    string.format("Swap arr[%d]=%d ↔ arr[%d]=%d",
                        root, arr[root], largest, arr[largest]),
                    root, largest, true, heap_len)
                arr[root], arr[largest] = arr[largest], arr[root]
                root = largest
            else
                add_step(phase_name,
                    string.format("arr[%d]=%d is in correct position (heap property satisfied)",
                        root, arr[root]),
                    root, -1, false, heap_len)
                break
            end
        end
    end

    -- Build heap
    for i = math.floor(n / 2) - 1, 0, -1 do
        add_step("build",
            string.format("─── Build heap: sift down idx=%d (value=%d) ───", i, arr[i]),
            i, -1, false, n)
        sift_down(i, n, "build")
    end

    add_step("build", "Max-heap built! Now extracting elements...", -1, -1, false, n)

    -- ── Phase 2: Extract sorted elements ──
    for heap_len = n, 2, -1 do
        -- Swap root (max) with last element in heap
        add_step("sort",
            string.format("Swap root arr[0]=%d ↔ arr[%d]=%d (move max to sorted position)",
                arr[0], heap_len - 1, arr[heap_len - 1]),
            0, heap_len - 1, true, heap_len)
        arr[0], arr[heap_len - 1] = arr[heap_len - 1], arr[0]

        local new_heap_len = heap_len - 1
        add_step("sort",
            string.format("Heap size reduced to %d. Sorted region: [%d..%d]",
                new_heap_len, new_heap_len, n - 1),
            -1, -1, false, new_heap_len)

        -- Sift down the new root
        if new_heap_len > 1 then
            add_step("sort",
                string.format("Sift down new root arr[0]=%d", arr[0]),
                0, -1, false, new_heap_len)
            sift_down(0, new_heap_len, "sort")
        end
    end

    -- Final sorted
    add_step("done", "✓ Array is fully sorted!", -1, -1, false, 0)
end

-- ─────────────────────────── Rendering ───────────────────────────

local term_rows, term_cols
local last_rendered_step = -1

-- Forward declarations for all rendering functions
local render_full_screen
local render_step

local function clamp_str(s, max_len)
    if #s > max_len then
        return s:sub(1, max_len - 1) .. "…"
    end
    return s
end

local function pad_right(s, width)
    if #s >= width then return s:sub(1, width) end
    return s .. string.rep(" ", width - #s)
end

-- Render the array bar chart + number row
local function render_array_line(snap, step_info, max_width)
    local buf = {}
    local heap_sz = step_info.heap_size
    local hi_a    = step_info.highlight_a
    local hi_b    = step_info.highlight_b

    -- Find max value for bar scaling
    local max_val = 1
    for i = 0, n - 1 do
        if snap[i] > max_val then max_val = snap[i] end
    end

    -- Compute cell width: each cell = "[" + number + "]" + space
    local cell_w = 5  -- default: " XX "
    local total_w = n * cell_w
    if total_w > max_width - 4 then
        cell_w = 4
        total_w = n * cell_w
    end

    -- Number row
    for i = 0, n - 1 do
        local val = snap[i]
        local num_str = string.format("%2d", val)

        local style
        if i == hi_a and i == hi_b then
            style = C.bold .. C.black .. C.bg_magenta
        elseif i == hi_a then
            if step_info.is_swap then
                style = C.bold .. C.black .. C.bg_red
            else
                style = C.bold .. C.black .. C.bg_yellow
            end
        elseif i == hi_b then
            if step_info.is_swap then
                style = C.bold .. C.black .. C.bg_red
            else
                style = C.bold .. C.black .. C.bg_cyan
            end
        elseif i >= heap_sz and heap_sz < n then
            -- Sorted region
            style = C.bold .. C.black .. C.bg_green
        else
            -- Normal heap region
            style = C.bold .. C.white .. C.bg_blue
        end

        buf[#buf + 1] = style .. " " .. num_str .. " " .. C.reset
        if cell_w == 5 then
            buf[#buf + 1] = " "
        end
    end

    return table.concat(buf)
end

-- Render the bar chart (vertical bars above each number)
local function render_bars(snap, step_info, max_width, bar_height)
    local buf = {}
    local heap_sz = step_info.heap_size
    local hi_a    = step_info.highlight_a
    local hi_b    = step_info.highlight_b

    local max_val = 1
    for i = 0, n - 1 do
        if snap[i] > max_val then max_val = snap[i] end
    end

    local cell_w = 5
    local total_w = n * cell_w
    if total_w > max_width - 4 then
        cell_w = 4
    end

    for row = bar_height, 1, -1 do
        local line = {}
        for i = 0, n - 1 do
            local val = snap[i]
            local bar_h = math.floor((val / max_val) * bar_height + 0.5)
            if bar_h < 1 and val > 0 then bar_h = 1 end

            local fg
            if i == hi_a or i == hi_b then
                if step_info.is_swap then
                    fg = C.red .. C.bold
                else
                    fg = C.yellow .. C.bold
                end
            elseif i >= heap_sz and heap_sz < n then
                fg = C.green
            else
                fg = C.cyan
            end

            if row <= bar_h then
                if cell_w == 5 then
                    line[#line + 1] = fg .. " ██ " .. C.reset .. " "
                else
                    line[#line + 1] = fg .. " ██ " .. C.reset
                end
            else
                line[#line + 1] = string.rep(" ", cell_w)
            end
        end
        buf[#buf + 1] = table.concat(line)
    end

    return buf
end

-- Render the index row beneath numbers
local function render_index_line(step_info, max_width)
    local buf = {}
    local hi_a = step_info.highlight_a
    local hi_b = step_info.highlight_b
    local cell_w = 5
    if n * cell_w > max_width - 4 then cell_w = 4 end

    for i = 0, n - 1 do
        local idx_str = string.format("%2d", i)
        local style
        if i == hi_a or i == hi_b then
            style = C.bold .. C.yellow
        else
            style = C.gray
        end
        buf[#buf + 1] = style .. " " .. idx_str .. " " .. C.reset
        if cell_w == 5 then buf[#buf + 1] = " " end
    end
    return table.concat(buf)
end

-- Render the tree/heap visualization (shows parent-child relationships)
local function render_heap_tree(snap, step_info)
    local heap_sz = step_info.heap_size
    if heap_sz <= 0 then return {} end

    local lines = {}
    -- Show a compact textual tree: level by level
    local level = 0
    local idx = 0
    while idx < heap_sz do
        local count = math.min(2^level, heap_sz - idx)
        local parts = {}
        local indent = math.max(0, math.floor(2^(4-level)) - 1)
        local spacing = math.max(1, math.floor(2^(5-level)) - 1)

        for j = 0, count - 1 do
            local i = idx + j
            local val = string.format("%2d", snap[i])
            local style
            if i == step_info.highlight_a then
                if step_info.is_swap then
                    style = C.bold .. C.red
                else
                    style = C.bold .. C.yellow
                end
            elseif i == step_info.highlight_b then
                if step_info.is_swap then
                    style = C.bold .. C.red
                else
                    style = C.bold .. C.cyan
                end
            else
                style = C.white
            end
            parts[#parts + 1] = style .. val .. C.reset
            if j < count - 1 then
                parts[#parts + 1] = string.rep(" ", spacing)
            end
        end
        lines[#lines + 1] = string.rep(" ", indent) .. table.concat(parts)
        idx = idx + count
        level = level + 1
    end
    return lines
end

render_full_screen = function(step_idx)
    term_rows, term_cols = get_terminal_size()
    local max_w = term_cols - 1

    local step_info = steps[step_idx]
    local snap = snapshots[step_idx]

    local buf = {}
    buf[#buf + 1] = "\27[?2026h"  -- begin synchronized update
    buf[#buf + 1] = "\27[2J"      -- full clear (only on full redraws)

    -- Row 1: Title bar
    buf[#buf + 1] = "\27[1;1H"
    local title = C.bold .. C.white .. C.bg_blue
        .. pad_right("  ⬢ Heap Sort Visualizer", max_w)
        .. C.reset

    buf[#buf + 1] = title

    -- Row 2: Controls
    buf[#buf + 1] = "\27[2;1H"
    buf[#buf + 1] = C.gray
        .. clamp_str("  [Space/Enter] step  [a] auto-play  [r] restart  [q] quit", max_w)
        .. C.reset

    -- Row 3: blank
    buf[#buf + 1] = "\27[3;1H"
    buf[#buf + 1] = string.rep(" ", max_w)

    -- Row 4: Phase + Step counter
    buf[#buf + 1] = "\27[4;1H"
    local phase_color
    if step_info.phase == "init" then
        phase_color = C.cyan
    elseif step_info.phase == "build" then
        phase_color = C.yellow
    elseif step_info.phase == "sort" then
        phase_color = C.magenta
    elseif step_info.phase == "done" then
        phase_color = C.green
    else
        phase_color = C.white
    end
    local phase_label = step_info.phase:upper()
    buf[#buf + 1] = "  " .. C.bold .. phase_color .. "[" .. phase_label .. "]" .. C.reset
        .. C.gray .. "  Step " .. step_idx .. "/" .. #steps .. C.reset
        .. string.rep(" ", max_w)

    -- Row 5: Description
    buf[#buf + 1] = "\27[5;1H"
    buf[#buf + 1] = "  " .. C.bold .. C.white
        .. clamp_str(step_info.desc, max_w - 4) .. C.reset
        .. string.rep(" ", max_w)

    -- Row 6: blank separator
    buf[#buf + 1] = "\27[6;1H"
    buf[#buf + 1] = string.rep(" ", max_w)

    -- Rows 7+: Bar chart
    local bar_height = math.min(12, math.max(4, term_rows - 18))
    local bar_lines = render_bars(snap, step_info, max_w, bar_height)
    local row = 7
    for _, line in ipairs(bar_lines) do
        buf[#buf + 1] = string.format("\27[%d;1H", row)
        buf[#buf + 1] = "  " .. line .. string.rep(" ", 10)
        row = row + 1
    end

    -- Number row
    buf[#buf + 1] = string.format("\27[%d;1H", row)
    buf[#buf + 1] = "  " .. render_array_line(snap, step_info, max_w)
        .. string.rep(" ", 10)
    row = row + 1

    -- Index row
    buf[#buf + 1] = string.format("\27[%d;1H", row)
    buf[#buf + 1] = "  " .. render_index_line(step_info, max_w)
        .. string.rep(" ", 10)
    row = row + 1

    -- Blank
    buf[#buf + 1] = string.format("\27[%d;1H", row)
    buf[#buf + 1] = string.rep(" ", max_w)
    row = row + 1

    -- Legend
    buf[#buf + 1] = string.format("\27[%d;1H", row)
    buf[#buf + 1] = "  " .. C.bold .. C.white .. "Legend: " .. C.reset
        .. C.bold .. C.black .. C.bg_blue .. " Heap " .. C.reset .. " "
        .. C.bold .. C.black .. C.bg_green .. " Sorted " .. C.reset .. " "
        .. C.bold .. C.black .. C.bg_yellow .. " Comparing " .. C.reset .. " "
        .. C.bold .. C.black .. C.bg_red .. " Swapping " .. C.reset
        .. string.rep(" ", 20)
    row = row + 1

    -- Blank
    buf[#buf + 1] = string.format("\27[%d;1H", row)
    buf[#buf + 1] = string.rep(" ", max_w)
    row = row + 1

    -- Heap tree header
    buf[#buf + 1] = string.format("\27[%d;1H", row)
    buf[#buf + 1] = "  " .. C.bold .. C.cyan .. "Heap Tree View:" .. C.reset
        .. string.rep(" ", max_w)
    row = row + 1

    -- Heap tree
    local tree_lines = render_heap_tree(snap, step_info)
    for _, line in ipairs(tree_lines) do
        if row >= term_rows then break end
        buf[#buf + 1] = string.format("\27[%d;1H", row)
        buf[#buf + 1] = "    " .. line .. string.rep(" ", 20)
        row = row + 1
    end

    -- Clear remaining rows
    while row <= term_rows do
        buf[#buf + 1] = string.format("\27[%d;1H", row)
        buf[#buf + 1] = string.rep(" ", max_w)
        row = row + 1
    end

    buf[#buf + 1] = "\27[?2026l"  -- end synchronized update

    io.write(table.concat(buf))
    io.flush()
    last_rendered_step = step_idx
end

-- Differential render: only update the rows that change between steps
-- (status line, description line, array, bars, tree)
-- For simplicity in this visualization, we do a full render each step
-- since the bar chart changes substantially. We still use synchronized
-- output to prevent flicker.
render_step = render_full_screen

-- ─────────────────────────── Main loop ───────────────────────────

local function main()
    local nums = parse_args()
    init_array(nums)
    generate_steps()

    enable_raw_mode()

    local current_step = 1
    local auto_play = false
    local auto_speed = 400  -- ms between auto steps
    local last_auto_time = get_time_ms()

    -- Initial full render
    render_full_screen(current_step)

    while true do
        local key = read_key(50)  -- 50ms poll timeout

        if key == "q" or key == "ESC" then
            break
        elseif key == " " or key == "\n" or key == "\r" then
            -- Advance one step
            if current_step < #steps then
                current_step = current_step + 1
                render_step(current_step)
            end
            auto_play = false
        elseif key == "a" then
            auto_play = not auto_play
            last_auto_time = get_time_ms()
        elseif key == "r" then
            -- Restart with new random data
            math.randomseed(os.time() + math.floor(get_time_ms()))
            local new_nums = {}
            for _ = 1, n do
                new_nums[#new_nums + 1] = math.random(1, 99)
            end
            init_array(new_nums)
            generate_steps()
            current_step = 1
            auto_play = false
            render_full_screen(current_step)
        end

        -- Auto-play logic
        if auto_play and current_step < #steps then
            local now = get_time_ms()
            if now - last_auto_time >= auto_speed then
                current_step = current_step + 1
                render_step(current_step)
                last_auto_time = now
                if current_step >= #steps then
                    auto_play = false
                end
            end
        end
    end

    disable_raw_mode()
end

-- ─────────────────────────── Entry point ───────────────────────────

local ok, err = xpcall(main, debug.traceback)
if not ok then
    disable_raw_mode()
    io.stderr:write("Error: " .. tostring(err) .. "\n")
    os.exit(1)
end
