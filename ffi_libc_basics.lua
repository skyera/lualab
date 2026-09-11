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
local floor = math.floor

local function image_ramp_green(n)
    local img = {}
    local f = 255/(n-1)

    for i=1,n do
        img[i] = {red=0, green=floor((i-1)*f), blue=0, alpha=255}
    end

    return img
end

local function image_to_gray(img, n)
    for i=1,n do
        local y=floor(0.3*img[i].red + 0.59*img[i].green + 0.11*img[i].blue)
        img[i].red = y
        img[i].green = y
        img[i].blue = y
    end
end

local N = 400 * 400
local ITERS = 200
local TOTAL_PIXELS = (N * ITERS) / 1e6

print(C.bold .. C.cyan .. "╭──────────────────────────────────────────────────────────────────────────╮" .. C.reset)
print(C.bold .. C.cyan .. "│          PERFORMANCE BENCHMARK: Image Grayscale Processing               │" .. C.reset)
print(C.bold .. C.cyan .. string.format("│     Workload: 400x400 (%s160,000 pixels%s) x %d passes = %s%.1f MPixels%s      │",
    C.yellow, C.cyan, ITERS, C.yellow, TOTAL_PIXELS, C.cyan) .. C.reset)
print(C.bold .. C.cyan .. "╰──────────────────────────────────────────────────────────────────────────╯" .. C.reset)

-- Pure Lua table setup & memory measurement
collectgarbage("collect")
local mem_before_lua = collectgarbage("count")

local img = image_ramp_green(N)
local mem_lua = (collectgarbage("count") - mem_before_lua) / 1024

local t0 = os.clock()
for i = 1, ITERS do
    image_to_gray(img, N)
end
local t_lua = os.clock() - t0
local tp_lua = TOTAL_PIXELS / t_lua

-- FFI: Use packed C data structure
ffi.cdef[[
typedef struct { uint8_t red, green, blue, alpha; } rgba_pixel;
]]

local function ffi_image_ramp_green(n)
    local img = ffi.new("rgba_pixel[?]", n)
    local f = 255 / (n - 1)
    for i = 0, n - 1 do
        img[i].green = i * f
        img[i].alpha = 255
    end
    return img
end

local function ffi_image_to_gray(img, n)
    for i = 0, n - 1 do
        local y = 0.3 * img[i].red + 0.59 * img[i].green + 0.11 * img[i].blue
        img[i].red = y
        img[i].green = y
        img[i].blue = y
    end
end

local ffi_img = ffi_image_ramp_green(N)
local mem_ffi = (N * ffi.sizeof("rgba_pixel")) / (1024 * 1024)

local t1 = os.clock()
for i = 1, ITERS do
    ffi_image_to_gray(ffi_img, N)
end
local t_ffi = os.clock() - t1
local tp_ffi = TOTAL_PIXELS / t_ffi

local speedup = t_lua / t_ffi
local mem_ratio = mem_lua / mem_ffi

-- True visual length helper (stripping ANSI escapes)
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

-- Results Table
local b = C.border
local r = C.reset
local cols = { 19, 14, 14, 24, 12 }

local function format_row(c1, c2, c3, c4, c5, a1, a2, a3, a4, a5)
    return string.format("  %s│%s %s %s│%s %s %s│%s %s %s│%s %s %s│%s %s %s│%s",
        b, r, pad_string(c1, cols[1], a1),
        b, r, pad_string(c2, cols[2], a2),
        b, r, pad_string(c3, cols[3], a3),
        b, r, pad_string(c4, cols[4], a4),
        b, r, pad_string(c5, cols[5], a5),
        b, r)
end

print(string.format("\n  %s┌─────────────────────┬────────────────┬────────────────┬──────────────────────────┬──────────────┐%s", b, r))
print(format_row(C.bold .. "Implementation", C.bold .. "Time (s)", C.bold .. "Throughput", C.bold .. "Memory Footprint", C.bold .. "Speedup", "left", "center", "center", "center", "center"))
print(string.format("  %s├─────────────────────┼────────────────┼────────────────┼──────────────────────────┼──────────────┤%s", b, r))
print(format_row("Pure Lua Tables", string.format("%.4f s", t_lua), string.format("%.1f MP/s", tp_lua), string.format("%.2f MB (160k tables)", mem_lua), "1.00x", "left", "right", "right", "right", "center"))
print(format_row(C.bold .. C.green .. "LuaJIT FFI Struct" .. r, C.green .. string.format("%.4f s", t_ffi) .. r, C.yellow .. string.format("%.1f MP/s", tp_ffi) .. r, C.cyan .. string.format("%.2f MB (packed raw)", mem_ffi) .. r, C.bold .. C.green .. string.format("%.2fx ⚡", speedup) .. r, "left", "right", "right", "right", "center"))
print(string.format("  %s└─────────────────────┴────────────────┴────────────────┴──────────────────────────┴──────────────┘%s\n", b, r))

-- Bar Charts
local bar_len = 36
local function make_bar(ratio, color)
    local filled = math.max(1, math.min(bar_len, math.floor(ratio * bar_len)))
    local empty = bar_len - filled
    return color .. string.rep("█", filled) .. C.dim .. string.rep("░", empty) .. C.reset
end

print("  " .. C.bold .. "Execution Time (shorter is better):" .. C.reset)
print(string.format("    %-11s [%s]  %.4fs (baseline)", "Pure Lua", make_bar(1.0, C.slate), t_lua))
print(string.format("    %-11s [%s]  %s%.4fs%s (%s%.2fx faster%s)", "FFI Struct", make_bar(t_ffi / t_lua, C.green), C.green, t_ffi, C.reset, C.bold .. C.green, speedup, C.reset))

print("\n  " .. C.bold .. "Memory Footprint (smaller is better):" .. C.reset)
print(string.format("    %-11s [%s]  %.2f MB (heap + GC tracking)", "Pure Lua", make_bar(1.0, C.slate), mem_lua))
print(string.format("    %-11s [%s]  %s%.2f MB%s (%s%.1fx less RAM%s)", "FFI Struct", make_bar(mem_ffi / mem_lua, C.cyan), C.cyan, mem_ffi, C.reset, C.bold .. C.cyan, mem_ratio, C.reset))

-- Architectural Insights
print("\n  " .. C.bold .. C.white .. "✦ Architectural Takeaways:" .. C.reset)
print(string.format("    %s•%s %sContiguous Packed Memory:%s 4-byte packed structs maximize L1/L2 data cache hit rates.", C.cyan, C.reset, C.bold, C.reset))
print(string.format("    %s•%s %sZero GC Overhead:%s 1 flat C array vs. 160,000 Lua table headers, hash tables, and GC pointers.", C.cyan, C.reset, C.bold, C.reset))
print(string.format("    %s•%s %sJIT Vectorization:%s LuaJIT unrolls pointer loops directly into tight native machine code.\n", C.cyan, C.reset, C.bold, C.reset))
