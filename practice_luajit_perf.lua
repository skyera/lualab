#!/usr/bin/env luajit
-- ============================================================================
-- Practice: LuaJIT OOP Performance & Metatable Invariants
local ITERATIONS = 10000000
print(string.format("Running %d iteration benchmark..\n", ITERATIONS))

-- Test 1: Clean, Static Metatable OOP
local StaticCounter = {}
StaticCounter.__index = StaticCounter

function StaticCounter:new(val)
    return setmetatable({ val = val or 0}, self)
end

function StaticCounter:add(n)
    self.val = self.val + n
end

local c1 = StaticCounter:new(0)
local t0 = os.clock()

for _ = 1, ITERATIONS do
    c1:add(1)
end
local t_static = os.clock() - t0

print(string.format("Test 1(Static Metatable): %.4f seconds", t_static))
print(string.format("Final value: %d\n", c1.val))

-- Test 2: Dynamic Metatable Re-blessing in loop (JIT-Killer)
local DynamicCounter = {}
DynamicCounter.__index = DynamicCounter

function DynamicCounter:add(n)
    self.val = self.val + n
end

local AltCounter = {}
AltCounter.__index = AltCounter

function AltCounter:add(n)
    self.val = self.val + n
end

local c2 = { val = 0 }

local t1 = os.clock()
for i = 1, ITERATIONS do
    -- Constantly re-assigning metatables in a hot loop invalidates JIT trace guards!
    if i % 2 == 0 then
        setmetatable(c2, DynamicCounter)
    else
        setmetatable(c2, AltCounter)
    end
    c2:add(1)
end
local t_dynamic = os.clock() - t1

print(string.format("Test 2 (Dynamic Metatable):  %.4f seconds", t_dynamic))
print(string.format("Final value: %d\n", c2.val))

local speedup = t_dynamic / t_static
print(string.format("Static OOP was %.1fx faster than Dynamic Metatable mutation!", speedup))

