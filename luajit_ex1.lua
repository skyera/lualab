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
