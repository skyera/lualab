#!/usr/bin/env luajit
-- =========================================================================
-- progressbar.lua - High-Performance ANSI/Unicode Terminal Progress Bar
--
-- Features:
--   * Reusable OOP library module with dual-use CLI demo
--   * Unicode 8th-step sub-block resolution, shaded block, and ASCII styles
--   * Throughput (units/s), elapsed time, count, and ETA calculations
--   * Protected cursor hiding (\27[?25l) and restoration (\27[?25h)
--   * Universal row-clear invariant (\27[K) preventing ghost text
--   * Decoupled pure frame generator (bar:render) for headless assertions
--   * TTY auto-detection and clean non-TTY logging milestones
--   * Bulletproof cross-platform sleep via POSIX poll and Windows Sleep
--   * Array / iterator loop wrapper (bar:iterate)
-- =========================================================================

local ffi = require("ffi")

-- Cache standard library functions for JIT performance
local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local string_rep = string.rep
local string_format = string.format
local io_write   = io.write
local io_flush   = io.flush

-- =========================================================================
-- Cross-Platform Sleep, Wall-Clock Timer & TTY Detection
-- =========================================================================

local is_windows = (ffi.os == "Windows")
local sleep_ms
local get_now_sec
local is_tty_stream

if is_windows then
    pcall(ffi.cdef, [[
        void __stdcall Sleep(uint32_t dwMilliseconds);
        int _isatty(int fd);
        int QueryPerformanceCounter(int64_t *lpPerformanceCount);
        int QueryPerformanceFrequency(int64_t *lpFrequency);
    ]])
    sleep_ms = function(ms)
        if ms and ms > 0 then
            ffi.C.Sleep(math_floor(ms))
        end
    end
    is_tty_stream = function()
        local ok, res = pcall(function()
            return ffi.C._isatty(1) == 1
        end)
        return ok and res or true
    end

    local qpc_count = ffi.new("int64_t[1]")
    local qpc_freq = ffi.new("int64_t[1]")
    local ok_qpc = pcall(function()
        return ffi.C.QueryPerformanceFrequency(qpc_freq) ~= 0 and qpc_freq[0] > 0
    end)
    if ok_qpc then
        local freq = tonumber(qpc_freq[0])
        get_now_sec = function()
            ffi.C.QueryPerformanceCounter(qpc_count)
            return tonumber(qpc_count[0]) / freq
        end
    else
        get_now_sec = os.clock
    end
else
    pcall(ffi.cdef, [[
        int poll(void *fds, unsigned long nfds, int timeout);
        int isatty(int fd);
        typedef struct timespec_progressbar {
            long tv_sec;
            long tv_nsec;
        } timespec_progressbar;
        int clock_gettime(int clk_id, struct timespec_progressbar *tp);
    ]])
    sleep_ms = function(ms)
        if ms and ms > 0 then
            ffi.C.poll(nil, 0, math_floor(ms))
        end
    end
    is_tty_stream = function()
        local ok, res = pcall(function()
            return ffi.C.isatty(1) == 1
        end)
        return ok and res or true
    end

    local mono_ts = ffi.new("struct timespec_progressbar")
    local ok_mono = pcall(function() return ffi.C.clock_gettime(1, mono_ts) == 0 end)
    if ok_mono then
        get_now_sec = function()
            ffi.C.clock_gettime(1, mono_ts)
            return tonumber(mono_ts.tv_sec) + tonumber(mono_ts.tv_nsec) * 1e-9
        end
    else
        get_now_sec = os.clock
    end
end

-- =========================================================================
-- Style Definitions & ANSI Constants
-- =========================================================================

local SUB_BLOCKS = { " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" }

local ANSI_COLORS = {
    green  = "\27[32m",
    cyan   = "\27[36m",
    blue   = "\27[34m",
    yellow = "\27[33m",
    magenta= "\27[35m",
    bold   = "\27[1m",
    dim    = "\27[2m",
    reset  = "\27[0m"
}

-- =========================================================================
-- ProgressBar Class Implementation
-- =========================================================================

local ProgressBar = {}
ProgressBar.__index = ProgressBar

function ProgressBar.new(opts)
    opts = opts or {}
    local self = setmetatable({}, ProgressBar)

    self.total = math_max(1, opts.total or 100)
    self.current = 0
    self.width = math_max(5, opts.width or 30)
    self.style = opts.style or "unicode" -- "unicode", "ascii", "shaded"
    self.label = opts.label or ""
    self.unit = opts.unit or "it"
    self.color = opts.color -- e.g. "green", "cyan", "blue"
    self.show_percent = (opts.show_percent ~= false)
    self.show_counts = (opts.show_counts ~= false)
    self.show_rate = (opts.show_rate ~= false)
    self.show_eta = (opts.show_eta ~= false)
    self.stream = opts.stream or io.stdout
    if opts.is_tty ~= nil then
        self.is_tty = (opts.is_tty == true)
    else
        self.is_tty = is_tty_stream()
    end

    self.cursor_hidden = false
    self.start_time = get_now_sec()
    self.last_render_time = self.start_time
    self.last_printed_pct = -1
    self.completed = false

    return self
end

function ProgressBar:format_eta(seconds)
    if not seconds or seconds ~= seconds or seconds < 0 or seconds > 86400 * 7 then
        return "--:--"
    end
    local s = math_floor(seconds)
    local m = math_floor(s / 60)
    local h = math_floor(m / 60)
    if h > 0 then
        return string_format("%02d:%02d:%02d", h, m % 60, s % 60)
    end
    return string_format("%02d:%02d", m, s % 60)
end

function ProgressBar:render_bar(pct)
    local clamped = math_max(0, math_min(1, pct))
    local total_slots = self.width
    local bar_str = ""

    if self.style == "ascii" then
        local filled = math_floor(clamped * total_slots)
        local arrow = (filled < total_slots and filled > 0) and ">" or ""
        local fill_len = math_max(0, filled - #arrow)
        local empty_len = math_max(0, total_slots - fill_len - #arrow)
        bar_str = string_rep("=", fill_len) .. arrow .. string_rep(" ", empty_len)
    elseif self.style == "shaded" then
        local filled = math_floor(clamped * total_slots)
        local empty_len = math_max(0, total_slots - filled)
        bar_str = string_rep("█", filled) .. string_rep("░", empty_len)
    else
        -- Unicode 8th-step fractional blocks
        local filled_f = clamped * total_slots
        local full_cells = math_floor(filled_f)
        local remainder = filled_f - full_cells
        local sub_idx = math_floor(remainder * 8) + 1
        local bar = string_rep("█", full_cells)
        if full_cells < total_slots then
            local sub_char = SUB_BLOCKS[math_min(9, math_max(1, sub_idx))]
            local empty_len = math_max(0, total_slots - full_cells - 1)
            bar = bar .. sub_char .. string_rep(" ", empty_len)
        end
        bar_str = bar
    end

    if self.color and ANSI_COLORS[self.color] and self.is_tty then
        local color_code = ANSI_COLORS[self.color]
        return "[" .. color_code .. bar_str .. ANSI_COLORS.reset .. "]"
    end

    return "[" .. bar_str .. "]"
end

function ProgressBar:render(current, message)
    if current then
        self.current = math_max(0, math_min(self.total, current))
    end

    local pct = self.current / self.total
    local now = get_now_sec()
    local elapsed = math_max(0.0001, now - self.start_time)
    local rate = self.current / elapsed
    local eta = 0
    if self.current > 0 and self.current < self.total and rate > 0 then
        eta = (self.total - self.current) / rate
    end

    local parts = {}
    if #self.label > 0 then
        parts[#parts + 1] = self.label
    end

    parts[#parts + 1] = self:render_bar(pct)

    if self.show_percent then
        parts[#parts + 1] = string_format("%5.1f%%", pct * 100)
    end

    if self.show_counts then
        parts[#parts + 1] = string_format("(%d/%d)", self.current, self.total)
    end

    if self.show_rate then
        parts[#parts + 1] = string_format("%4.1f %s/s", rate, self.unit)
    end

    if self.show_eta and self.current < self.total then
        parts[#parts + 1] = "ETA " .. self:format_eta(eta)
    end

    if message and #message > 0 then
        parts[#parts + 1] = "[" .. message .. "]"
    end

    return table.concat(parts, " ")
end

function ProgressBar:update(current, message)
    local frame = self:render(current, message)

    if self.is_tty then
        if not self.cursor_hidden then
            self.stream:write("\27[?25l")
            self.cursor_hidden = true
        end
        -- Universal Row-Clear Invariant: \r + content + \27[K
        self.stream:write("\r" .. frame .. "\27[K")
        self.stream:flush()
    else
        -- Non-TTY milestone throttling (every 10%)
        local pct10 = math_floor((self.current / self.total) * 10)
        if pct10 ~= self.last_printed_pct then
            self.last_printed_pct = pct10
            self.stream:write(frame .. "\n")
            self.stream:flush()
        end
    end
end

function ProgressBar:tick(delta, message)
    self:update(self.current + (delta or 1), message)
end

function ProgressBar:finish(message)
    if self.completed then
        return
    end
    self.completed = true

    if self.is_tty then
        self:update(self.total, message)
        if self.cursor_hidden then
            self.stream:write("\27[?25h")
            self.cursor_hidden = false
        end
        self.stream:write("\n")
        self.stream:flush()
    else
        if self.last_printed_pct ~= 10 then
            self.last_printed_pct = 10
            local frame = self:render(self.total, message)
            self.stream:write(frame .. "\n")
            self.stream:flush()
        end
    end
end

function ProgressBar:iterate(items, label)
    if label then
        self.label = label
    end
    local n = #items
    self.total = math_max(1, n)
    local idx = 0

    return function()
        idx = idx + 1
        if idx <= n then
            local item = items[idx]
            local msg = (type(item) == "string") and item or nil
            self:update(idx, msg)
            if idx == n then
                self:finish()
            end
            return item, idx
        end
    end
end

-- =========================================================================
-- Backward-Compatibility Coroutine Helpers
-- =========================================================================

local function make_progress_bar(total)
    total = total or 100
    local bar = ProgressBar.new({ total = total })
    return coroutine.create(function()
        for done = 0, total do
            coroutine.yield(done / total)
        end
    end), bar
end

local function draw_progress(progress, width)
    width = width or 30
    local bar = ProgressBar.new({ total = 100, width = width, show_rate = false, show_eta = false, show_counts = false })
    local frame = bar:render(progress * 100)
    io_write("\r" .. frame .. "\27[K")
    io_flush()
end

-- Export module table & class
local print_help
local cli_main

local M = {
    ProgressBar = ProgressBar,
    new = ProgressBar.new,
    sleep_ms = sleep_ms,
    get_now_sec = get_now_sec,
    is_tty = is_tty_stream,
    make_progress_bar = make_progress_bar,
    draw_progress = draw_progress,
    print_help = function(stream) return print_help(stream) end,
    main = function(args) return cli_main(args) end
}

-- =========================================================================
-- CLI Help & Argument Dispatcher
-- =========================================================================

print_help = function(stream)
    stream = stream or io.stdout
    stream:write([[
progressbar.lua - High-Performance ANSI/Unicode Terminal Progress Bar

USAGE:
  luajit progressbar.lua [OPTIONS]
  ./progressbar.lua [OPTIONS]

OPTIONS:
  -h, --help, /?        Show this help documentation and exit
  --demo                Run the interactive multi-style showcase (default)
  --style <name>        Bar style: unicode (default), ascii, shaded
  --total <num>         Total item count or steps (default: 100)
  --width <num>         Bar width in character cells (default: 30)
  --label <text>        Prefix description label (e.g. "Downloading")
  --color <name>        ANSI color: cyan, green, blue, yellow, magenta
  --unit <text>         Throughput unit label (default: "it")
  --delay <ms>          Delay between simulated steps in ms (default: 20)
  --no-eta              Disable ETA calculation display
  --no-rate             Disable throughput rate display
  --no-counts           Disable item counts (current/total)
  --no-percent          Disable percentage display

LIBRARY USAGE:
  local ProgressBar = require("progressbar")
  local bar = ProgressBar.new({ total = 100, style = "unicode", color = "cyan" })
  for i = 1, 100 do
      bar:update(i, "chunk_" .. i)
  end
  bar:finish("Done!")
]])
    stream:flush()
end

local function run_demo()
    io_write("\n=== ProgressBar Showcase ===\n\n")

    -- Demo 1: Smooth Unicode 8th-block filling
    local p1 = ProgressBar.new({
        total = 100,
        width = 30,
        style = "unicode",
        color = "cyan",
        label = "Unicode Smooth"
    })
    for i = 1, 100 do
        p1:update(i, "chunk_" .. i)
        sleep_ms(15)
    end
    p1:finish("Done!")

    -- Demo 2: ASCII with arrow indicator
    local p2 = ProgressBar.new({
        total = 80,
        width = 25,
        style = "ascii",
        label = "ASCII Classic"
    })
    for i = 1, 80 do
        p2:update(i)
        sleep_ms(15)
    end
    p2:finish("Complete!")

    -- Demo 3: Shaded blocks with custom unit
    local p3 = ProgressBar.new({
        total = 50,
        width = 20,
        style = "shaded",
        color = "green",
        label = "Shaded Blocks",
        unit = "MB"
    })
    for i = 1, 50 do
        p3:update(i)
        sleep_ms(20)
    end
    p3:finish("Finished!")

    -- Demo 4: Iterator loop wrapper
    local files = { "kernel.c", "fs.c", "net.c", "sched.c", "mem.c", "drivers.c" }
    local p4 = ProgressBar.new({
        width = 20,
        style = "unicode",
        color = "yellow",
        label = "Compiling"
    })
    for file in p4:iterate(files) do
        sleep_ms(70)
    end

    io_write("\nAll demos passed successfully!\n")
    return 0
end

cli_main = function(args)
    args = args or {}
    if #args == 0 then
        return run_demo()
    end

    local opts = { delay = 20 }
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-h" or a == "--help" or a == "/?" then
            print_help()
            return 0
        elseif a == "--demo" then
            return run_demo()
        elseif a == "--style" then
            i = i + 1
            if not args[i] then
                io.stderr:write("Error: --style requires an argument (unicode, ascii, shaded).\n")
                return 1
            end
            opts.style = args[i]
        elseif a == "--total" then
            i = i + 1
            local val = tonumber(args[i])
            if not val or val < 1 then
                io.stderr:write("Error: --total must be a positive integer.\n")
                return 1
            end
            opts.total = val
        elseif a == "--width" then
            i = i + 1
            local val = tonumber(args[i])
            if not val or val < 5 then
                io.stderr:write("Error: --width must be an integer >= 5.\n")
                return 1
            end
            opts.width = val
        elseif a == "--delay" then
            i = i + 1
            local val = tonumber(args[i])
            if not val or val < 0 then
                io.stderr:write("Error: --delay must be a non-negative number of milliseconds.\n")
                return 1
            end
            opts.delay = val
        elseif a == "--label" then
            i = i + 1
            opts.label = args[i] or ""
        elseif a == "--color" then
            i = i + 1
            opts.color = args[i]
        elseif a == "--unit" then
            i = i + 1
            opts.unit = args[i]
        elseif a == "--no-eta" then
            opts.show_eta = false
        elseif a == "--no-rate" then
            opts.show_rate = false
        elseif a == "--no-counts" then
            opts.show_counts = false
        elseif a == "--no-percent" then
            opts.show_percent = false
        else
            io.stderr:write(string_format("Error: Unrecognized option '%s'.\n", a))
            io.stderr:write("Try 'luajit progressbar.lua --help' for available options.\n")
            return 1
        end
        i = i + 1
    end

    local bar = ProgressBar.new(opts)
    local total = bar.total
    local delay = opts.delay or 20
    for step = 1, total do
        bar:update(step)
        if delay > 0 then
            sleep_ms(delay)
        end
    end
    bar:finish("Complete!")
    return 0
end

-- =========================================================================
-- Standalone CLI Invocation
-- =========================================================================

local is_standalone = false
if not pcall(debug.getlocal, 4, 1) and arg and arg[0] and arg[0]:match("progressbar%.lua$") then
    is_standalone = true
end

if is_standalone then
    local cli_args = {}
    if arg then
        for idx = 1, #arg do
            cli_args[#cli_args + 1] = arg[idx]
        end
    end
    local exit_code = cli_main(cli_args)
    if exit_code ~= 0 then
        os.exit(exit_code)
    end
end

return M
