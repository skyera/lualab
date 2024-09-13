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
local img = image_ramp_green(N)
for i=1, 1000 do
    image_to_gray(img, N)
end

-- ffi: use C data structure
print("ffi")
ffi.cdef[[
typedef struct { uint8_t red, green, blue, alpha; } rgba_pixel;
]]

local function image_ramp_green(n)
    local img = ffi.new("rgba_pixel[?]", n)
    local f=255/(n-1)
    for i=0,n-1 do
        img[i].green=i*f
        img[i].alpha=255
    end
    return img
end

local function image_to_gray(img, n)
    for i=0, n-1 do
        local y = 0.3*img[i].red + 0.59*img[i].green + 0.11*img[i].blue
        img[i].red = y
        img[i].green = y
        img[i].blue = y
    end
end

local N = 400*400
local img = image_ramp_green(N)
for i=0, 1000 do
    image_to_gray(img, N)
end
