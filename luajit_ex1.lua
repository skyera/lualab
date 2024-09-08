local ffi = require("ffi")

ffi.cdef[[
int rand(void);
]]

for i = 0, 3 do
    local num = ffi.C.rand()
    print(num)
end
