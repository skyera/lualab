-- __index
--      * if a key does not exist in a table
--      * run a function or use a table
--
local func_ex = setmetatable({}, {
    __index = function(t, key)
        return "key not exist"
    end,
})

print(func_ex[1])

local fallback_table = setmetatable({
        foo="bar",
        [123]=456,
    }, { __index=func_ex })

print(fallback_table[1])

local fallback_ex = setmetatable({}, {__index=fallback_table})
print(fallback_ex[1])
print(fallback_ex[123])
print(fallback_ex.foo)
print(fallback_ex[456])
