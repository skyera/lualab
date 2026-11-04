#!/usr/bin/env luajit
-- ============================================================================
-- Practice: The Shared Table Prototype Trap
print("Part 1: The Buggy version (Shared Prototype Table)")
local BuggyPlayer = {
    level = 1,
    inventory = {}
}
BuggyPlayer.__index = BuggyPlayer

function BuggyPlayer:new(name)
    return setmetatable({ name = name}, self)
end

function BuggyPlayer:pick_up(item)
    table.insert(self.inventory, item)
end

local alice = BuggyPlayer:new("Alice")
local bob = BuggyPlayer:new("Bob")

print("Alice inventory address:", tostring(alice.inventory))
print("Bob inventory address:", tostring(bob.inventory))
print("Are they pointing to the exact same table?", alice.inventory == bob.inventory)

alice:pick_up("Excalibur")
print("\nAfter Alice picked up Excalibur:")
print("Alice items count:", #alice.inventory)
print("Bob items count:", #bob.inventory)

-- Part 2: Fixed version (Independent Instance Tables)
local FixedPlayer = {
    level = 1
}
FixedPlayer.__index = FixedPlayer

function FixedPlayer:new(name)
    local instance = setmetatable({}, self)
    instance.name = name
    instance.inventory = {}
    return instance
end

function FixedPlayer:pick_up(item)
    table.insert(self.inventory, item)
end

local charlie = FixedPlayer:new("Charlie")
local david = FixedPlayer:new("David")

print("Charlie inventory address:", tostring(charlie.inventory))
print("David inventory address:", tostring(david.inventory))
print("Are they pointing to the exact same table", charlie.inventory == david.inventory)

charlie:pick_up("Wooden Shield")

print("\nAfter Charlie picked up Wooden Shield:")
print("Charlie items count:", #charlie.inventory)
print("Davd items count:", #david.inventory)
