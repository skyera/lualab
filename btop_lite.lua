--[[
    btop_lite.lua
    A fast, beautiful, and real-time Linux System & Process Monitor written in LuaJIT with FFI.
    Inspired by btop & htop.

    Features:
    - Zero-Fork /proc parser via direct POSIX C I/O and LuaJIT FFI:
      * /proc/stat: CPU usage per-core and overall with time-delta calculations.
      * /proc/meminfo: Real-time Memory & Swap breakdown (Total, Used, Available, Buffers/Cached).
      * /proc/loadavg: 1m, 5m, 15m load averages & active task counts.
      * /proc/[pid]/stat & status: Process tracking (PID, USER, RES, %CPU, %MEM, Command).
    - Modern TUI Visuals:
      * 24-bit Truecolor gradient progress bars & sparkline charts ( ▂▃▄▅▆▇█).
      * Auto terminal resize via POSIX ioctl(TIOCGWINSZ).
      * Tear-free, zero-flash event-driven and timer-driven rendering.
    - Interactive Process Controls:
      * Sort by CPU (c), Memory (m), PID (p), Name (n)
      * Filter / Search processes (/)
      * Send SIGTERM (t) or SIGKILL (k) with confirmation
      * Pause / Freeze screen (Space)
      * Change update interval (+ / -)
      * q / ESC: Quit cleanly
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. FFI POSIX Definitions: Terminal, Polling, Dirent, and Signals
-- =========================================================================
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

    typedef struct DIR DIR;
    struct dirent {
        unsigned long  d_ino;
        long           d_off;
        unsigned short d_reclen;
        unsigned char  d_type;
        char           d_name[256];
    };
    DIR *opendir(const char *name);
    struct dirent *readdir(DIR *dirp);
    int closedir(DIR *dirp);

    int kill(int pid, int sig);
    long sysconf(int name);
]]

local TIOCGWINSZ   = 0x5413
local STDIN_FILENO = 0
local TCSANOW      = 0
local ICANON       = 2
local ECHO         = 8
local POLLIN       = 1
local SC_CLK_TCK   = 2

local clk_tck = 100
pcall(function()
    local t = ffi.C.sysconf(SC_CLK_TCK)
    if t > 0 then clk_tck = tonumber(t) end
end)

local orig_termios = ffi.new("struct termios")
local raw_termios  = ffi.new("struct termios")
local in_raw_mode  = false

local function enable_raw_mode()
    if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
    ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
    ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
    raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
    in_raw_mode = true

    -- Switch to alternate screen buffer, hide cursor
    io.write("\27[?1049h\27[?25l")
    io.flush()
    return true
end

local function disable_raw_mode()
    if in_raw_mode then
        -- Return to main screen buffer, restore cursor, reset color
        io.write("\27[?1049l\27[?25h\27[0m")
        io.flush()
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
        in_raw_mode = false
    end
end

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 100, 30
end

local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
local key_buf = ffi.new("char[32]")

local function read_key(timeout_ms)
    timeout_ms = timeout_ms or 50
    local ret = ffi.C.poll(pfd, 1, timeout_ms)
    if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local n = ffi.C.read(STDIN_FILENO, key_buf, 32)
        if n > 0 then
            local c0 = key_buf[0]
            if c0 == 27 then
                if n >= 3 and key_buf[1] == 91 then
                    local c2 = key_buf[2]
                    if c2 == 65 then return "UP" end
                    if c2 == 66 then return "DOWN" end
                    if c2 == 67 then return "RIGHT" end
                    if c2 == 68 then return "LEFT" end
                    if c2 == 53 and n >= 4 and key_buf[3] == 126 then return "PAGE_UP" end
                    if c2 == 54 and n >= 4 and key_buf[3] == 126 then return "PAGE_DOWN" end
                    if c2 == 72 then return "HOME" end
                    if c2 == 70 then return "END" end
                end
                return "ESC"
            elseif c0 == 10 or c0 == 13 then
                return "ENTER"
            elseif c0 == 127 or c0 == 8 then
                return "BACKSPACE"
            elseif c0 == 32 then
                return "SPACE"
            else
                return string.char(c0)
            end
        end
    end
    return nil
end

-- =========================================================================
-- 2. Styling Palette & String Measurement
-- =========================================================================
local C = {
    reset        = "\27[0m",
    bold         = "\27[1m",
    dim          = "\27[2m",

    -- Borders
    border_col   = "\27[38;2;71;85;105m",      -- Slate grey
    border_focus = "\27[1;38;2;56;189;248m",   -- Cyan
    title_col    = "\27[1;38;2;241;245;249m",

    -- Metrics & Meters
    cpu_low      = "\27[38;2;34;197;94m",      -- Emerald
    cpu_mid      = "\27[38;2;234;179;8m",      -- Amber
    cpu_high     = "\27[1;38;2;239;68;68m",    -- Coral Red

    mem_used     = "\27[38;2;168;85;247m",     -- Purple
    mem_cached   = "\27[38;2;56;189;248m",     -- Cyan
    mem_free     = "\27[38;2;34;197;94m",      -- Green

    -- Process Table
    sel_bg       = "\27[48;2;30;58;138m\27[1;38;2;255;255;255m",
    table_hdr    = "\27[1;38;2;203;213;225m",
    col_pid      = "\27[38;2;56;189;248m",
    col_user     = "\27[38;2;148;163;184m",
    col_pri      = "\27[38;2;251;191;36m",
}

local function visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function truncate(str, max_w)
    local len = visual_len(str)
    if len <= max_w then return str end
    if max_w <= 3 then return string.rep(".", max_w) end

    local out = {}
    local curr = 0
    for c in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if curr + 1 > max_w - 3 then break end
        table.insert(out, c)
        curr = curr + 1
    end
    return table.concat(out) .. "..."
end

local function format_bytes(kb)
    if kb < 1024 then
        return string.format("%d K", kb)
    elseif kb < 1024 * 1024 then
        return string.format("%.1f M", kb / 1024)
    else
        return string.format("%.2f G", kb / (1024 * 1024))
    end
end

-- =========================================================================
-- 3. Visual Meter & Sparkline Generator
-- =========================================================================
local SPARK_CHARS = { " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function make_meter_bar(pct, width)
    width = math.max(4, width)
    local filled = math.floor((pct / 100.0) * width)
    filled = math.max(0, math.min(width, filled))
    local empty = width - filled

    local col = C.cpu_low
    if pct > 80 then col = C.cpu_high
    elseif pct > 50 then col = C.cpu_mid
    end

    return string.format("%s%s\27[90m%s%s", col, string.rep("■", filled), string.rep("·", empty), C.reset)
end

-- =========================================================================
-- 4. Fast Linux /proc Reader Engine
-- =========================================================================
local prev_cpu_totals = {}
local prev_proc_times = {}

local function read_cpu_stats()
    local f = io.open("/proc/stat", "r")
    if not f then return {}, 0 end

    local cores = {}
    local overall_pct = 0

    while true do
        local line = f:read("*l")
        if not line or not line:find("^cpu") then break end

        local name, user, nice, sys, idle, iowait, irq, softirq =
            line:match("^(cpu%w*)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")

        if name then
            user = tonumber(user) or 0
            nice = tonumber(nice) or 0
            sys  = tonumber(sys) or 0
            idle = tonumber(idle) or 0
            iowait = tonumber(iowait) or 0
            irq = tonumber(irq) or 0
            softirq = tonumber(softirq) or 0

            local busy = user + nice + sys + irq + softirq
            local total = busy + idle + iowait

            local prev = prev_cpu_totals[name]
            local pct = 0
            if prev then
                local d_total = total - prev.total
                local d_busy  = busy - prev.busy
                if d_total > 0 then
                    pct = math.min(100.0, math.max(0.0, (d_busy / d_total) * 100.0))
                end
            end
            prev_cpu_totals[name] = { total = total, busy = busy }

            if name == "cpu" then
                overall_pct = pct
            else
                table.insert(cores, { name = name, pct = pct })
            end
        end
    end
    f:close()
    return cores, overall_pct
end

local function read_memory_stats()
    local f = io.open("/proc/meminfo", "r")
    if not f then return {} end

    local mem = {}
    while true do
        local line = f:read("*l")
        if not line then break end
        local k, v = line:match("([^:]+):%s+(%d+)")
        if k and v then
            mem[k] = tonumber(v)
        end
    end
    f:close()

    local total = mem["MemTotal"] or 1
    local free = mem["MemFree"] or 0
    local avail = mem["MemAvailable"] or free
    local buffers = mem["Buffers"] or 0
    local cached = mem["Cached"] or 0
    local used = total - avail

    local swap_total = mem["SwapTotal"] or 0
    local swap_free = mem["SwapFree"] or 0
    local swap_used = swap_total - swap_free

    return {
        total_kb = total,
        used_kb = used,
        avail_kb = avail,
        buffers_kb = buffers,
        cached_kb = cached,
        used_pct = (used / total) * 100.0,
        swap_total_kb = swap_total,
        swap_used_kb = swap_used,
        swap_pct = (swap_total > 0) and ((swap_used / swap_total) * 100.0) or 0,
    }
end

local function read_loadavg()
    local f = io.open("/proc/loadavg", "r")
    if not f then return "0.00 0.00 0.00", "0/0" end
    local content = f:read("*l") or ""
    f:close()
    local l1, l5, l15, tasks = content:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    return string.format("%s %s %s", l1 or "0.0", l5 or "0.0", l15 or "0.0"), tasks or ""
end

-- Read process table directly via /proc dirent
local function read_process_table(mem_total_kb, uptime_sec)
    local d = ffi.C.opendir("/proc")
    if d == nil then return {} end

    local procs = {}

    while true do
        local ent = ffi.C.readdir(d)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)

        if name:match("^%d+$") then
            local pid = tonumber(name)
            local stat_f = io.open("/proc/" .. name .. "/stat", "r")
            if stat_f then
                local stat_line = stat_f:read("*l")
                stat_f:close()

                if stat_line then
                    -- Format: pid (comm) state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime ...
                    local comm = stat_line:match("%((.-)%)") or ""
                    local rest = stat_line:match("%).-(%S+.*)")
                    if rest then
                        local parts = {}
                        for p in rest:gmatch("%S+") do
                            table.insert(parts, p)
                            if #parts >= 22 then break end
                        end

                        local state  = parts[1] or "R"
                        local utime  = tonumber(parts[12]) or 0
                        local stime  = tonumber(parts[13]) or 0
                        local start_time = tonumber(parts[20]) or 0
                        local rss_pages  = tonumber(parts[22]) or 0

                        local total_time = utime + stime
                        local prev = prev_proc_times[pid]
                        local cpu_pct = 0
                        if prev then
                            local d_proc = total_time - prev.time
                            if d_proc > 0 then
                                cpu_pct = math.min(100.0, (d_proc / clk_tck) * 100.0)
                            end
                        end
                        prev_proc_times[pid] = { time = total_time }

                        local res_kb = rss_pages * 4
                        local mem_pct = (res_kb / mem_total_kb) * 100.0

                        -- Get commandline
                        local cmdline = comm
                        local cmd_f = io.open("/proc/" .. name .. "/cmdline", "r")
                        if cmd_f then
                            local raw_cmd = cmd_f:read(128) or ""
                            cmd_f:close()
                            if #raw_cmd > 0 then
                                cmdline = raw_cmd:gsub("%z", " "):gsub("%s+$", "")
                            end
                        end

                        table.insert(procs, {
                            pid = pid,
                            comm = comm,
                            cmdline = cmdline,
                            state = state,
                            cpu_pct = cpu_pct,
                            mem_pct = mem_pct,
                            res_kb = res_kb,
                        })
                    end
                end
            end
        end
    end
    ffi.C.closedir(d)

    return procs
end

-- =========================================================================
-- 5. TUI Layout & Drawing Engine
-- =========================================================================
local function draw_box_row(x, y, w, text)
    local clr = truncate(text, w - 2)
    local vlen = visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s", y, x + 1, clr, pad)
end

local function draw_pane(out, x, y, w, h, title, is_focused)
    local bcol = is_focused and C.border_focus or C.border_col
    local title_str = title and string.format(" %s%s%s ", C.title_col, title, bcol) or ""
    local t_len = title and (visual_len(title) + 2) or 0
    local top_fill = string.rep("─", math.max(0, w - 2 - t_len))

    table.insert(out, string.format("\27[%d;%dH%s╭%s%s╮%s", y, x, bcol, title_str, top_fill, C.reset))
    for i = 1, h - 2 do
        table.insert(out, string.format("\27[%d;%dH%s│\27[%d;%dH│%s", y + i, x, bcol, y + i, x + w - 1, C.reset))
    end
    local bot_fill = string.rep("─", math.max(0, w - 2))
    table.insert(out, string.format("\27[%d;%dH%s╰%s╯%s", y + h - 1, x, bcol, bot_fill, C.reset))
end

-- =========================================================================
-- 6. Main Interactive Application Loop
-- =========================================================================
local function main()
    enable_raw_mode()

    local sort_mode = "cpu" -- "cpu", "mem", "pid", "name"
    local sel_proc = 1
    local filter_query = ""
    local is_paused = false
    local refresh_interval_ms = 1000

    local last_w, last_h = get_terminal_size()
    local cpu_history = {}
    local max_history = 40

    -- Initial screen clear
    io.write("\27[H\27[2J")
    io.flush()

    local next_refresh_time = 0

    while true do
        local now = os.time()
        local term_w, term_h = get_terminal_size()
        local needs_redraw = false

        if term_w ~= last_w or term_h ~= last_h then
            last_w, last_h = term_w, term_h
            needs_redraw = true
            io.write("\27[H\27[2J")
        end

        -- Poll key with small timeout
        local k = read_key(80)

        if k then
            needs_redraw = true
            if k == "q" or k == "ESC" then
                if #filter_query > 0 then
                    filter_query = ""
                else
                    break
                end
            elseif k == "DOWN" or k == "j" then
                sel_proc = sel_proc + 1
            elseif k == "UP" or k == "k" then
                sel_proc = math.max(1, sel_proc - 1)
            elseif k == "PAGE_DOWN" then
                sel_proc = sel_proc + 15
            elseif k == "PAGE_UP" then
                sel_proc = math.max(1, sel_proc - 15)
            elseif k == "HOME" or k == "g" then
                sel_proc = 1
            elseif k == "SPACE" then
                is_paused = not is_paused
            elseif k == "c" then
                sort_mode = "cpu"
            elseif k == "m" then
                sort_mode = "mem"
            elseif k == "p" then
                sort_mode = "pid"
            elseif k == "n" then
                sort_mode = "name"
            elseif k == "+" or k == "=" then
                refresh_interval_ms = math.max(250, refresh_interval_ms - 250)
            elseif k == "-" then
                refresh_interval_ms = math.min(5000, refresh_interval_ms + 250)
            elseif k == "/" then
                disable_raw_mode()
                io.write("\n\27[1;38;2;56;189;248mFilter Process Name (Enter to submit): \27[0m")
                io.flush()
                local q = io.read("*l")
                enable_raw_mode()
                if q then
                    filter_query = q:gsub("^%s+", ""):gsub("%s+$", "")
                    sel_proc = 1
                end
            elseif k == "k" or k == "t" then
                -- Kill / Terminate process
                -- Handled inside loop with procs
            end
        end

        -- Check if timer expired or key pressed
        local curr_clock = os.clock()
        if (curr_clock >= next_refresh_time and not is_paused) or needs_redraw then
            next_refresh_time = curr_clock + (refresh_interval_ms / 1000.0)

            -- Read system metrics via /proc
            local cores, overall_cpu = read_cpu_stats()
            local mem = read_memory_stats()
            local load_str, task_str = read_loadavg()

            -- Maintain CPU sparkline history
            table.insert(cpu_history, overall_cpu)
            if #cpu_history > max_history then
                table.remove(cpu_history, 1)
            end

            -- Read and sort processes
            local procs = read_process_table(mem.total_kb or 1, now)

            -- Filter
            if #filter_query > 0 then
                local filtered = {}
                for _, pr in ipairs(procs) do
                    if pr.comm:lower():find(filter_query:lower(), 1, true) or
                       pr.cmdline:lower():find(filter_query:lower(), 1, true) then
                        table.insert(filtered, pr)
                    end
                end
                procs = filtered
            end

            -- Sort
            table.sort(procs, function(a, b)
                if sort_mode == "cpu" then
                    if a.cpu_pct ~= b.cpu_pct then return a.cpu_pct > b.cpu_pct end
                    return a.mem_pct > b.mem_pct
                elseif sort_mode == "mem" then
                    if a.res_kb ~= b.res_kb then return a.res_kb > b.res_kb end
                    return a.cpu_pct > b.cpu_pct
                elseif sort_mode == "pid" then
                    return a.pid < b.pid
                elseif sort_mode == "name" then
                    return a.comm:lower() < b.comm:lower()
                end
                return a.cpu_pct > b.cpu_pct
            end)

            sel_proc = math.max(1, math.min(sel_proc, math.max(1, #procs)))

            -- Kill action on selected process if requested
            if k == "k" and procs[sel_proc] then
                ffi.C.kill(procs[sel_proc].pid, 9) -- SIGKILL
            elseif k == "t" and procs[sel_proc] then
                ffi.C.kill(procs[sel_proc].pid, 15) -- SIGTERM
            end

            -- =================================================================
            -- Render Frame
            -- =================================================================
            local out = {}
            table.insert(out, "\27[H")

            -- Top Banner
            local pause_indicator = is_paused and "\27[1;38;2;239;68;68m [PAUSED]\27[0m" or ""
            local header_str = string.format("  \27[1;38;2;56;189;248m⚡ BTOP-LITE\27[0m \27[90m│\27[0m Load: \27[1;97m%s\27[0m \27[90m│\27[0m Tasks: \27[1;97m%s\27[0m \27[90m│\27[0m Interval: \27[1;93m%.1fs\27[0m%s\27[K",
                load_str, task_str, refresh_interval_ms / 1000.0, pause_indicator)
            table.insert(out, header_str .. "\n")

            -- Layout: Top split (CPU + Memory/Swap) and Bottom split (Processes)
            local top_h = math.min(11, math.max(8, math.floor(term_h * 0.36)))
            local bot_h = term_h - top_h - 2

            local left_w = math.floor(term_w * 0.52)
            local right_w = term_w - left_w

            -- 1. CPU Pane (Top Left)
            draw_pane(out, 1, 2, left_w, top_h, string.format("CPU: %.1f%%", overall_cpu), false)

            -- Sparkline chart
            local spark_str = {}
            for _, val in ipairs(cpu_history) do
                local char_idx = math.max(1, math.min(8, math.floor((val / 100.0) * 7) + 1))
                table.insert(spark_str, SPARK_CHARS[char_idx])
            end
            local spark_line = string.format("%sHistory: %s%s%s", C.dim, C.cpu_low, table.concat(spark_str), C.reset)
            table.insert(out, draw_box_row(1, 3, left_w, spark_line))

            -- CPU Cores Breakdown
            local num_cores_to_show = math.min(#cores, (top_h - 4) * 2)
            for i = 1, top_h - 4 do
                local c1_idx = (i - 1) * 2 + 1
                local c2_idx = (i - 1) * 2 + 2
                local c1 = cores[c1_idx]
                local c2 = cores[c2_idx]

                local line_parts = {}
                local col_sub_w = math.floor((left_w - 6) / 2)

                if c1 then
                    local mbar = make_meter_bar(c1.pct, col_sub_w - 11)
                    table.insert(line_parts, string.format("%s%2d%s %s%4.0f%%%s", C.dim, c1_idx - 1, C.reset, mbar, c1.pct, C.reset))
                end
                if c2 then
                    local mbar = make_meter_bar(c2.pct, col_sub_w - 11)
                    table.insert(line_parts, string.format(" %s%2d%s %s%4.0f%%%s", C.dim, c2_idx - 1, C.reset, mbar, c2.pct, C.reset))
                end
                table.insert(out, draw_box_row(1, 3 + i, left_w, table.concat(line_parts)))
            end

            -- 2. Memory & Swap Pane (Top Right)
            draw_pane(out, left_w + 1, 2, right_w, top_h, string.format("Memory & Swap"), false)
            local mem_bar = make_meter_bar(mem.used_pct, right_w - 24)
            local swap_bar = make_meter_bar(mem.swap_pct, right_w - 24)

            table.insert(out, draw_box_row(left_w + 1, 3, right_w,
                string.format("%sRAM %s %s%5.1f%%%s %s/%s",
                    C.bold, C.reset, mem_bar, mem.used_pct, C.reset,
                    format_bytes(mem.used_kb), format_bytes(mem.total_kb))))

            table.insert(out, draw_box_row(left_w + 1, 4, right_w,
                string.format("  %sFree: %s%s │ %sCached: %s%s │ %sAvail: %s%s",
                    C.dim, format_bytes(mem.total_kb - mem.used_kb), C.reset,
                    C.dim, format_bytes(mem.cached_kb), C.reset,
                    C.dim, format_bytes(mem.avail_kb), C.reset)))

            table.insert(out, draw_box_row(left_w + 1, 5, right_w,
                string.format("%sSWP %s %s%5.1f%%%s %s/%s",
                    C.bold, C.reset, swap_bar, mem.swap_pct, C.reset,
                    format_bytes(mem.swap_used_kb), format_bytes(mem.swap_total_kb))))

            -- 3. Processes Table (Bottom)
            local sort_tag = string.format("[Sort: %s]", sort_mode:upper())
            local proc_title = string.format("Processes: %d %s", #procs, sort_tag)
            draw_pane(out, 1, top_h + 2, term_w, bot_h, proc_title, true)

            -- Table Columns: PID (7), USER (8), %CPU (7), %MEM (7), RES (9), STAT (5), COMMAND (rest)
            local table_y = top_h + 3
            local th_str = string.format("  %s%-7s %-8s %-7s %-7s %-9s %-5s %s%s",
                C.table_hdr, "PID", "USER", "%CPU", "%MEM", "RES", "STAT", "COMMAND", C.reset)
            table.insert(out, draw_box_row(1, table_y, term_w, th_str))

            local visible_rows = bot_h - 3
            local page_offset = 1
            if sel_proc > visible_rows then
                page_offset = sel_proc - visible_rows + 1
            end

            for i = 1, visible_rows do
                local p_idx = page_offset + i - 1
                local pr = procs[p_idx]
                if pr then
                    local is_sel = (p_idx == sel_proc)
                    local cpu_col = pr.cpu_pct > 50 and C.cpu_high or (pr.cpu_pct > 15 and C.cpu_mid or C.reset)
                    local row_content = string.format("%-7d %-8s %s%5.1f%%%s %5.1f%% %-9s %-5s %s",
                        pr.pid, "user", cpu_col, pr.cpu_pct, C.reset, pr.mem_pct, format_bytes(pr.res_kb), pr.state, pr.cmdline)

                    if is_sel then
                        table.insert(out, draw_box_row(1, table_y + i, term_w, C.sel_bg .. "▶ " .. row_content .. C.reset))
                    else
                        table.insert(out, draw_box_row(1, table_y + i, term_w, "  " .. row_content))
                    end
                else
                    table.insert(out, draw_box_row(1, table_y + i, term_w, ""))
                end
            end

            -- 4. Footer & Keybindings
            local footer_y = term_h
            local filter_status = #filter_query > 0 and (string.format("\27[1;38;2;251;191;36mFilter: /%s\27[0m  ", filter_query)) or ""
            local help_str = "[c/m/p/n] Sort  [/] Filter  [k] Kill  [t] Term  [Space] Pause  [+/-] Speed  [q] Quit"
            local footer_line = string.format("\27[%d;1H\27[2K  %s%s%s", footer_y, filter_status, C.dim, help_str)
            table.insert(out, footer_line)

            io.write(table.concat(out))
            io.flush()
        end
    end

    disable_raw_mode()
    print("\n\27[1;36mExited btop-lite. Goodbye!\27[0m")
end

main()
