local ffi = require("ffi")

-- 1. Define C declarations
ffi.cdef[[
    // For Timing
    typedef struct { long tv_sec; long tv_nsec; } timespec_t;
    int clock_gettime(int clk_id, timespec_t *tp);

    // For Sorting (qsort)
    // The last argument is a function pointer: int (*compar)(const void *, const void *)
    void qsort(void *base, size_t nmemb, size_t size, 
               int (*compar)(const void *, const void *));

    // For Math (from libm)
    double pow(double x, double y);
    double sin(double x);
]]

-- 2. Loading an external shared library (libm - Math library)
-- On Linux, math functions are often in a separate library
local libm = ffi.load("m")

print("--- Advanced FFI Demo ---")

-- Example A: High-Resolution Timer (Nanoseconds)
local function get_nanos()
    local ts = ffi.new("timespec_t")
    -- 1 is CLOCK_MONOTONIC
    ffi.C.clock_gettime(1, ts)
    return tonumber(ts.tv_sec) * 1e9 + tonumber(ts.tv_nsec)
end

local start_t = get_nanos()
local val = libm.sin(math.pi / 2)
local end_t = get_nanos()

print(string.format("Math libm.sin(pi/2) = %f", val))
print(string.format("Execution time: %d ns", end_t - start_t))


-- Example B: C Callbacks (Sorting an array using C's qsort)
-- Create a C array of integers
local count = 10
local nums = ffi.new("int[?]", count)
for i = 0, count-1 do nums[i] = math.random(1, 100) end

print("\nBefore qsort: " .. table.concat({
    nums[0], nums[1], nums[2], nums[3], nums[4], 
    nums[5], nums[6], nums[7], nums[8], nums[9]
}, ", "))

-- Define the callback function in Lua
-- Note: 'const void*' in C becomes 'void*' or a specific pointer in Lua FFI
local function compare_ints(a, b)
    local va = ffi.cast("int*", a)[0]
    local vb = ffi.cast("int*", b)[0]
    return va - vb
end

-- Wrap the Lua function as a C callback
local callback = ffi.cast("int (*)(const void *, const void *)", compare_ints)

-- Call C qsort
ffi.C.qsort(nums, count, ffi.sizeof("int"), callback)

print("After qsort:  " .. table.concat({
    nums[0], nums[1], nums[2], nums[3], nums[4], 
    nums[5], nums[6], nums[7], nums[8], nums[9]
}, ", "))

-- Important: Free the callback if you created it in a loop (to avoid memory leaks)
-- In this simple script, Lua's GC handles it, but ffi.cast callbacks 
-- are special resources.
callback:free()

print("\nAdvanced FFI demo complete.")
