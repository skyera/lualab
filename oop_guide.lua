#!/usr/bin/env luajit
-- ============================================================================
-- OOP Guide in Lua: Modern Idioms & Design Patterns
-- ============================================================================

-- ============================================================================
-- Chapter 1: The Modern Idiomatic Class
-- Key Concepts
--   1. Metatables & __index for prototype delegation
--   2. Colon syntax (:) for implict 'self'
--   3 Class-level __call to allow Counter(start_val) syntax
--   4. Method chaining (return 'self')
-- ===========================================================================
print("=== Chapter 1: The Modern Idiomtic Class ===")

local Counter = {}
Counter.__index = Counter

-- Make the class table callable: Counter(val) calls Counter:new(val)
setmetatable(Counter, {
    __call = function(cls, ...)
        return cls:new(...)
    end
})

function Counter:new(initial_value)
    local instance = setmetatable({}, self)
    instance.value = initial_value or 0
    return instance
end

function Counter:get()
    return self.value
end

function Counter:increment(amount)
    self.value = self.value + (amount or 1)
    return self
end

function Counter:reset()
    self.value = 0
    return self
end

local c1 = Counter(10)
c1:increment(5):increment(2)
print("c1 value (expected 17):", c1:get())

local c2 = Counter()
c2:increment()
print("c2 value (expected 1):", c2:get())
