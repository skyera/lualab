local ffi = require("ffi")

ffi.cdef[[
int rand(void);
int atoi(const char*);
int printf(const char* fmt, ...);

typedef struct {
    int x;
    int y;
} Point;
]]

for i = 0, 3 do
    local num = ffi.C.rand()
    print(num)
end

local num = ffi.C.atoi("12")
print(num)
ffi.C.printf("Hello, %s\n", "world")

local p = ffi.new("Point")
p.x = 10
p.y = 20
print(p.x, p.y)

--
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

local N = 400*400
local ITERS = 200

print(string.format("\n--- Benchmark: Grayscale conversion (%d pixels, %d iterations) ---", N, ITERS))

local t0 = os.clock()
local img = image_ramp_green(N)
for i=1, ITERS do
    image_to_gray(img, N)
end
local t_lua = os.clock() - t0
print(string.format("Pure Lua tables : %.4f seconds", t_lua))

-- ffi: use C data structure
ffi.cdef[[
typedef struct { uint8_t red, green, blue, alpha; } rgba_pixel;
]]

local function ffi_image_ramp_green(n)
    local img = ffi.new("rgba_pixel[?]", n)
    local f=255/(n-1)
    for i=0,n-1 do
        img[i].green=i*f
        img[i].alpha=255
    end
    return img
end

local function ffi_image_to_gray(img, n)
    for i=0, n-1 do
        local y = 0.3*img[i].red + 0.59*img[i].green + 0.11*img[i].blue
        img[i].red = y
        img[i].green = y
        img[i].blue = y
    end
end

local t1 = os.clock()
local ffi_img = ffi_image_ramp_green(N)
for i=1, ITERS do
    ffi_image_to_gray(ffi_img, N)
end
local t_ffi = os.clock() - t1
print(string.format("LuaJIT FFI struct: %.4f seconds", t_ffi))
print(string.format("FFI speedup     : %.2fx faster", t_lua / t_ffi))
