#!/usr/bin/env luajit
--[[
    ffi_libc_basics.lua
    Demonstrates calling C standard library functions (libc) and structs via LuaJIT FFI,
    paired with an A/B performance benchmark comparing pure Lua tables against C struct arrays.
]]

local ffi = require("ffi")

-- ANSI color helpers
local C = {
    reset   = "\27[0m",
    bold    = "\27[1m",
    dim     = "\27[2m",
    cyan    = "\27[38;2;56;189;248m",
    green   = "\27[38;2;74;222;128m",
    yellow  = "\27[38;2;251;191;36m",
    white   = "\27[38;2;248;250;252m",
    slate   = "\27[38;2;148;163;184m",
    border  = "\27[38;2;90;105;120m",
}

ffi.cdef[[
int rand(void);
int atoi(const char*);
int printf(const char* fmt, ...);

typedef struct {
    int x;
    int y;
} Point;

typedef struct {
    uint8_t red, green, blue, alpha;
} rgba_pixel;

typedef struct {
    float x, y, z;
    float vx, vy, vz;
} Particle;
]]

-- Header Banner
print("\n" .. C.bold .. C.cyan .. "╭──────────────────────────────────────────────────────────────────────────╮" .. C.reset)
print(C.bold .. C.cyan .. "│            LuaJIT FFI Basics: C Standard Library & Structs               │" .. C.reset)
print(C.bold .. C.cyan .. "╰──────────────────────────────────────────────────────────────────────────╯" .. C.reset)

-- 1. C Standard Library Functions (libc via ffi.C)
print("\n" .. C.bold .. C.white .. "1. C Standard Library Functions (libc via ffi.C):" .. C.reset)

local rand_nums = {}
for i = 1, 4 do
    table.insert(rand_nums, tostring(ffi.C.rand()))
end
print(string.format("   %s•%s %sffi.C.rand()%s   -> Generated 4 numbers: %s%s%s",
    C.cyan, C.reset, C.bold, C.reset, C.yellow, table.concat(rand_nums, ", "), C.reset))

local atoi_str = "12"
local parsed_int = ffi.C.atoi(atoi_str)
print(string.format("   %s•%s %sffi.C.atoi()%s   -> Parsed string \"%s\" to integer: %s%d%s",
    C.cyan, C.reset, C.bold, C.reset, atoi_str, C.green, parsed_int, C.reset))

io.write(string.format("   %s•%s %sffi.C.printf()%s -> ", C.cyan, C.reset, C.bold, C.reset))
ffi.C.printf("Hello, %s\n", "world")

-- 2. C Struct Instantiation
print("\n" .. C.bold .. C.white .. "2. C Struct Instantiation (Point via ffi.new):" .. C.reset)
local p = ffi.new("Point")
p.x = 10
p.y = 20
local pt_size = ffi.sizeof("Point")
print(string.format("   %s•%s Struct layout : %sstruct Point { int x; int y; }%s (sizeof: %s%d bytes%s)",
    C.cyan, C.reset, C.dim, C.reset, C.yellow, pt_size, C.reset))
print(string.format("   %s•%s Field access  : Point(x = %s%d%s, y = %s%d%s)\n",
    C.cyan, C.reset, C.yellow, p.x, C.reset, C.yellow, p.y, C.reset))
-- =========================================================================
-- Helper Functions for Formatted Terminal Output
-- =========================================================================
local function visual_length(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function pad_string(str, target_width, align)
    local vis_len = visual_length(str)
    local diff = math.max(0, target_width - vis_len)
    align = align or "left"
    if align == "right" then
        return string.rep(" ", diff) .. str
    elseif align == "center" then
        local left = math.floor(diff / 2)
        local right = diff - left
        return string.rep(" ", left) .. str .. string.rep(" ", right)
    else
        return str .. string.rep(" ", diff)
    end
end

local function make_border(l, m, r, h, widths)
    local parts = { C.border, l }
    for i, w in ipairs(widths) do
        table.insert(parts, string.rep(h, w + 2))
        if i < #widths then table.insert(parts, m) end
    end
    table.insert(parts, r .. C.reset)
    return table.concat(parts)
end

local function make_bar(ratio, color, bar_len)
    bar_len = bar_len or 34
    local filled = math.max(1, math.min(bar_len, math.floor(ratio * bar_len)))
    local empty = bar_len - filled
    return color .. string.rep("█", filled) .. C.dim .. string.rep("░", empty) .. C.reset
end

local function print_box_banner(title, subtitle)
    local w = 74
    print("\n" .. C.bold .. C.cyan .. "╭" .. string.rep("─", w) .. "╮" .. C.reset)
    print(C.bold .. C.cyan .. "│" .. pad_string(title, w, "center") .. "│" .. C.reset)
    if subtitle then
        print(C.cyan .. "│" .. pad_string(subtitle, w, "center") .. "│" .. C.reset)
    end
    print(C.bold .. C.cyan .. "╰" .. string.rep("─", w) .. "╯" .. C.reset)
end

local table_cols = { 21, 14, 14, 25, 12 }
local function render_bench_table(time_lua, tp_lua, ram_lua, ram_lua_lbl,
                                  time_ffi, tp_ffi, ram_ffi, ram_ffi_lbl,
                                  speedup, tp_unit)
    local top = "  " .. make_border("┌", "┬", "┐", "─", table_cols)
    local mid = "  " .. make_border("├", "┼", "┤", "─", table_cols)
    local btm = "  " .. make_border("└", "┴", "┘", "─", table_cols)

    local function row(c1, c2, c3, c4, c5, a1, a2, a3, a4, a5)
        return string.format("  %s│%s %s %s│%s %s %s│%s %s %s│%s %s %s│%s %s %s│%s",
            C.border, C.reset, pad_string(c1, table_cols[1], a1),
            C.border, C.reset, pad_string(c2, table_cols[2], a2),
            C.border, C.reset, pad_string(c3, table_cols[3], a3),
            C.border, C.reset, pad_string(c4, table_cols[4], a4),
            C.border, C.reset, pad_string(c5, table_cols[5], a5),
            C.border, C.reset)
    end

    print(top)
    print(row(C.bold .. "Implementation", C.bold .. "Time (s)", C.bold .. "Throughput", C.bold .. "Memory Footprint", C.bold .. "Speedup",
              "left", "center", "center", "center", "center"))
    print(mid)
    print(row("Pure Lua Tables",
              string.format("%.4f s", time_lua),
              string.format("%.1f %s", tp_lua, tp_unit),
              string.format("%.2f MB (%s)", ram_lua, ram_lua_lbl),
              "1.00x",
              "left", "right", "right", "right", "center"))
    print(row(C.bold .. C.green .. "LuaJIT FFI Struct" .. C.reset,
              C.green .. string.format("%.4f s", time_ffi) .. C.reset,
              C.yellow .. string.format("%.1f %s", tp_ffi, tp_unit) .. C.reset,
              C.cyan .. string.format("%.2f MB (%s)", ram_ffi, ram_ffi_lbl) .. C.reset,
              C.bold .. C.green .. string.format("%.2fx ⚡", speedup) .. C.reset,
              "left", "right", "right", "right", "center"))
    print(btm)
end

-- =========================================================================
-- Part 2: Multi-Domain A/B Performance Benchmark Suite
-- =========================================================================
print_box_banner("COMPREHENSIVE A/B BENCHMARK SUITE: Pure Lua vs. LuaJIT FFI",
                 "Testing Memory Locality, Struct Access, and Bulk Buffer Transfers")

-- -------------------------------------------------------------------------
-- Benchmark 1: 2D Image Grayscale (Array of Structs & Cache Locality)
-- -------------------------------------------------------------------------
print("\n" .. C.bold .. C.yellow .. "▶ BENCHMARK 1: 2D Image Grayscale (Array-of-Structs & Cache Locality)" .. C.reset)
local N1 = 400 * 400
local ITERS1 = 200
local TOTAL_PIXELS = (N1 * ITERS1) / 1e6
local floor = math.floor
print(string.format("  Workload: 400x400 (%s160,000 pixels%s) x %d passes = %s%.1f MPixels%s\n",
    C.cyan, C.reset, ITERS1, C.cyan, TOTAL_PIXELS, C.reset))

-- Pure Lua table setup & run
collectgarbage("collect")
local m0_1 = collectgarbage("count")
local function image_ramp_green(n)
    local img = {}
    local f = 255 / (n - 1)
    for i = 1, n do img[i] = { red = 0, green = floor((i - 1) * f), blue = 0, alpha = 255 } end
    return img
end
local img_lua = image_ramp_green(N1)
local ram_lua_1 = (collectgarbage("count") - m0_1) / 1024

local function image_to_gray(img, n)
    for i = 1, n do
        local p = img[i]
        local y = floor(0.3 * p.red + 0.59 * p.green + 0.11 * p.blue)
        p.red = y; p.green = y; p.blue = y
    end
end

local t0_1 = os.clock()
for it = 1, ITERS1 do image_to_gray(img_lua, N1) end
local time_lua_1 = os.clock() - t0_1
local tp_lua_1 = TOTAL_PIXELS / time_lua_1

-- FFI struct setup & run
local f1 = 255 / (N1 - 1)
local img_ffi = ffi.new("rgba_pixel[?]", N1)
for i = 0, N1 - 1 do img_ffi[i].green = i * f1; img_ffi[i].alpha = 255 end
local ram_ffi_1 = (N1 * ffi.sizeof("rgba_pixel")) / (1024 * 1024)

local function ffi_image_to_gray(img, n)
    for i = 0, n - 1 do
        local y = 0.3 * img[i].red + 0.59 * img[i].green + 0.11 * img[i].blue
        img[i].red = y; img[i].green = y; img[i].blue = y
    end
end

local t1_1 = os.clock()
for it = 1, ITERS1 do ffi_image_to_gray(img_ffi, N1) end
local time_ffi_1 = os.clock() - t1_1
local tp_ffi_1 = TOTAL_PIXELS / time_ffi_1
local speedup_1 = time_lua_1 / time_ffi_1
local ram_ratio_1 = ram_lua_1 / ram_ffi_1

render_bench_table(time_lua_1, tp_lua_1, ram_lua_1, "160k tables",
                   time_ffi_1, tp_ffi_1, ram_ffi_1, "packed raw",
                   speedup_1, "MP/s")

print("  Execution Time: Pure Lua [" .. make_bar(1.0, C.slate, 28) .. "] " .. string.format("%.4fs", time_lua_1))
print("                  FFI      [" .. make_bar(time_ffi_1 / time_lua_1, C.green, 28) .. "] " .. C.green .. string.format("%.4fs", time_ffi_1) .. C.reset .. " (" .. C.bold .. C.green .. string.format("%.2fx faster", speedup_1) .. C.reset .. ")")
print("  Memory Footprint: Pure Lua [" .. make_bar(1.0, C.slate, 28) .. "] " .. string.format("%.2f MB", ram_lua_1))
print("                    FFI      [" .. make_bar(ram_ffi_1 / ram_lua_1, C.cyan, 28) .. "] " .. C.cyan .. string.format("%.2f MB", ram_ffi_1) .. C.reset .. " (" .. C.bold .. C.cyan .. string.format("%.1fx less RAM", ram_ratio_1) .. C.reset .. ")")

-- -------------------------------------------------------------------------
-- Benchmark 2: 3D Particle Kinematics (6-DOF Float Physics Simulation)
-- -------------------------------------------------------------------------
print("\n" .. C.bold .. C.yellow .. "▶ BENCHMARK 2: 3D Particle Kinematics (6-DOF Float Physics)" .. C.reset)
local N2 = 100000
local ITERS2 = 100
local TOTAL_PARTS = (N2 * ITERS2) / 1e6
print(string.format("  Workload: 100,000 particles (x, y, z, vx, vy, vz) x %d steps = %s%.1f M updates%s\n",
    ITERS2, C.cyan, TOTAL_PARTS, C.reset))

-- Pure Lua table setup & run
collectgarbage("collect")
local m0_2 = collectgarbage("count")
local part_lua = {}
for i = 1, N2 do
    part_lua[i] = { x = i * 0.1, y = i * 0.2, z = i * 0.3, vx = 0.5, vy = -0.5, vz = 1.0 }
end
local ram_lua_2 = (collectgarbage("count") - m0_2) / 1024

local t0_2 = os.clock()
for it = 1, ITERS2 do
    for i = 1, N2 do
        local pt = part_lua[i]
        pt.x = pt.x + pt.vx * 0.016
        pt.y = pt.y + pt.vy * 0.016
        pt.z = pt.z + pt.vz * 0.016
    end
end
local time_lua_2 = os.clock() - t0_2
local tp_lua_2 = TOTAL_PARTS / time_lua_2

-- FFI struct setup & run
local part_ffi = ffi.new("Particle[?]", N2)
for i = 0, N2 - 1 do
    part_ffi[i].x = i * 0.1; part_ffi[i].y = i * 0.2; part_ffi[i].z = i * 0.3
    part_ffi[i].vx = 0.5; part_ffi[i].vy = -0.5; part_ffi[i].vz = 1.0
end
local ram_ffi_2 = (N2 * ffi.sizeof("Particle")) / (1024 * 1024)

local t1_2 = os.clock()
for it = 1, ITERS2 do
    for i = 0, N2 - 1 do
        local pt = part_ffi[i]
        pt.x = pt.x + pt.vx * 0.016
        pt.y = pt.y + pt.vy * 0.016
        pt.z = pt.z + pt.vz * 0.016
    end
end
local time_ffi_2 = os.clock() - t1_2
local tp_ffi_2 = TOTAL_PARTS / time_ffi_2
local speedup_2 = time_lua_2 / time_ffi_2
local ram_ratio_2 = ram_lua_2 / ram_ffi_2

render_bench_table(time_lua_2, tp_lua_2, ram_lua_2, "100k tables",
                   time_ffi_2, tp_ffi_2, ram_ffi_2, "packed floats",
                   speedup_2, "M/s")

print("  Execution Time: Pure Lua [" .. make_bar(1.0, C.slate, 28) .. "] " .. string.format("%.4fs", time_lua_2))
print("                  FFI      [" .. make_bar(time_ffi_2 / time_lua_2, C.green, 28) .. "] " .. C.green .. string.format("%.4fs", time_ffi_2) .. C.reset .. " (" .. C.bold .. C.green .. string.format("%.2fx faster", speedup_2) .. C.reset .. ")")
print("  Memory Footprint: Pure Lua [" .. make_bar(1.0, C.slate, 28) .. "] " .. string.format("%.2f MB", ram_lua_2))
print("                    FFI      [" .. make_bar(ram_ffi_2 / ram_lua_2, C.cyan, 28) .. "] " .. C.cyan .. string.format("%.2f MB", ram_ffi_2) .. C.reset .. " (" .. C.bold .. C.cyan .. string.format("%.1fx less RAM", ram_ratio_2) .. C.reset .. ")")

-- -------------------------------------------------------------------------
-- Benchmark 3: Bulk Memory Block Transfer (Hardware memcpy vs Table Loop)
-- -------------------------------------------------------------------------
print("\n" .. C.bold .. C.yellow .. "▶ BENCHMARK 3: Bulk Memory Block Transfer (Hardware memcpy vs Table Loop)" .. C.reset)
local N3 = 4 * 1024 * 1024
local ITERS3 = 80
local TOTAL_MB = (N3 * ITERS3) / (1024 * 1024)
local TOTAL_GB = TOTAL_MB / 1024
print(string.format("  Workload: 4 MB buffer x %d passes = %s%.1f MB (%.2f GB) transferred%s\n",
    ITERS3, C.cyan, TOTAL_MB, TOTAL_GB, C.reset))

-- Pure Lua table copy & run
collectgarbage("collect")
local m0_3 = collectgarbage("count")
local src_lua = {}
for i = 1, N3 do src_lua[i] = i % 256 end
local dst_lua = {}
local ram_lua_3 = (collectgarbage("count") - m0_3) / 1024

local t0_3 = os.clock()
for it = 1, ITERS3 do
    for i = 1, N3 do dst_lua[i] = src_lua[i] end
end
local time_lua_3 = os.clock() - t0_3
local bw_lua = TOTAL_GB / time_lua_3

-- FFI memcpy copy & run
local src_ffi = ffi.new("uint8_t[?]", N3)
local dst_ffi = ffi.new("uint8_t[?]", N3)
for i = 0, N3 - 1 do src_ffi[i] = i % 256 end
local ram_ffi_3 = (2 * N3) / (1024 * 1024)

local t1_3 = os.clock()
for it = 1, ITERS3 do
    ffi.copy(dst_ffi, src_ffi, N3)
end
local time_ffi_3 = os.clock() - t1_3
local bw_ffi = TOTAL_GB / time_ffi_3
local speedup_3 = time_lua_3 / time_ffi_3
local ram_ratio_3 = ram_lua_3 / ram_ffi_3

render_bench_table(time_lua_3, bw_lua, ram_lua_3, "4M hash/arr",
                   time_ffi_3, bw_ffi, ram_ffi_3, "raw bytes",
                   speedup_3, "GB/s")

print("  Execution Time: Pure Lua [" .. make_bar(1.0, C.slate, 28) .. "] " .. string.format("%.4fs", time_lua_3))
print("                  FFI      [" .. make_bar(time_ffi_3 / time_lua_3, C.green, 28) .. "] " .. C.green .. string.format("%.4fs", time_ffi_3) .. C.reset .. " (" .. C.bold .. C.green .. string.format("%.2fx faster", speedup_3) .. C.reset .. ")")
print("  Memory Footprint: Pure Lua [" .. make_bar(1.0, C.slate, 28) .. "] " .. string.format("%.2f MB", ram_lua_3))
print("                    FFI      [" .. make_bar(ram_ffi_3 / ram_lua_3, C.cyan, 28) .. "] " .. C.cyan .. string.format("%.2f MB", ram_ffi_3) .. C.reset .. " (" .. C.bold .. C.cyan .. string.format("%.1fx less RAM", ram_ratio_3) .. C.reset .. ")")

-- =========================================================================
-- Part 3: Executive Summary Scorecard
-- =========================================================================
local sc_cols = { 36, 14, 14, 16, 14 }
local top_sc = "  " .. make_border("┌", "┬", "┐", "─", sc_cols)
local mid_sc = "  " .. make_border("├", "┼", "┤", "─", sc_cols)
local btm_sc = "  " .. make_border("└", "┴", "┘", "─", sc_cols)

local function sc_row(c1, c2, c3, c4, c5, a1, a2, a3, a4, a5)
    return string.format("  %s│%s %s %s│%s %s %s│%s %s %s│%s %s %s│%s %s %s│%s",
        C.border, C.reset, pad_string(c1, sc_cols[1], a1),
        C.border, C.reset, pad_string(c2, sc_cols[2], a2),
        C.border, C.reset, pad_string(c3, sc_cols[3], a3),
        C.border, C.reset, pad_string(c4, sc_cols[4], a4),
        C.border, C.reset, pad_string(c5, sc_cols[5], a5),
        C.border, C.reset)
end

print_box_banner("BENCHMARK SUITE SUMMARY SCORECARD",
                 "Multi-Domain Speedup & RAM Reduction Comparison")

print(top_sc)
print(sc_row(C.bold .. "Benchmark Domain", C.bold .. "Pure Lua (s)", C.bold .. "FFI Cdata(s)", C.bold .. "RAM Savings", C.bold .. "Speedup",
             "left", "center", "center", "center", "center"))
print(mid_sc)

print(sc_row(
    "1. 2D Image Processing (AoS)",
    string.format("%.4f s", time_lua_1),
    C.green .. string.format("%.4f s", time_ffi_1) .. C.reset,
    C.cyan .. string.format("%.1fx less", ram_ratio_1) .. C.reset,
    C.bold .. C.green .. string.format("%.2fx ⚡", speedup_1) .. C.reset,
    "left", "right", "right", "right", "center"))

print(sc_row(
    "2. 3D Particle Physics (Kinematics)",
    string.format("%.4f s", time_lua_2),
    C.green .. string.format("%.4f s", time_ffi_2) .. C.reset,
    C.cyan .. string.format("%.1fx less", ram_ratio_2) .. C.reset,
    C.bold .. C.green .. string.format("%.2fx ⚡", speedup_2) .. C.reset,
    "left", "right", "right", "right", "center"))

print(sc_row(
    "3. Bulk Memory Transfer (Memcpy)",
    string.format("%.4f s", time_lua_3),
    C.green .. string.format("%.4f s", time_ffi_3) .. C.reset,
    C.cyan .. string.format("%.1fx less", ram_ratio_3) .. C.reset,
    C.bold .. C.green .. string.format("%.2fx ⚡", speedup_3) .. C.reset,
    "left", "right", "right", "right", "center"))

print(mid_sc)

-- Geometric Mean Calculations
local geo_speedup = math.exp((math.log(speedup_1) + math.log(speedup_2) + math.log(speedup_3)) / 3)
local geo_ram = math.exp((math.log(ram_ratio_1) + math.log(ram_ratio_2) + math.log(ram_ratio_3)) / 3)
local geo_lua = math.exp((math.log(time_lua_1) + math.log(time_lua_2) + math.log(time_lua_3)) / 3)
local geo_ffi = math.exp((math.log(time_ffi_1) + math.log(time_ffi_2) + math.log(time_ffi_3)) / 3)

print(sc_row(
    C.bold .. C.yellow .. "OVERALL GEOMETRIC MEAN" .. C.reset,
    string.format("%.4f s", geo_lua),
    C.green .. string.format("%.4f s", geo_ffi) .. C.reset,
    C.cyan .. string.format("%.1fx less", geo_ram) .. C.reset,
    C.bold .. C.green .. string.format("%.2fx ⚡", geo_speedup) .. C.reset,
    "left", "right", "right", "right", "center"))

print(btm_sc)

-- =========================================================================
-- Part 4: Architectural Takeaways
-- =========================================================================
print("\n  " .. C.bold .. C.white .. "✦ Key Architectural Takeaways:" .. C.reset)
print(string.format("    %s•%s %sContiguous Packed Memory:%s Flat C structs avoid pointer indirection and saturate CPU cache lines.", C.cyan, C.reset, C.bold, C.reset))
print(string.format("    %s•%s %sZero GC Pressure:%s Replaces hundreds of thousands of heap-tracked Lua tables with single raw allocations.", C.cyan, C.reset, C.bold, C.reset))
print(string.format("    %s•%s %sDirect Hardware Primitives:%s FFI loops leverage SIMD instructions, vectorization, and kernel memcpy/memset.\n", C.cyan, C.reset, C.bold, C.reset))
