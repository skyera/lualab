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

-- Chapter 2: Two-phase Initialization (__init hook)
-- Key Concepts
--   1. Allocation is handled once in __call
--   2. Initialization is decoupled into :_init(...)
--   3. Subclasses only overrid :_init(...) and chain parent._init(self, ...)
print("\n=== Chapter 2: Two-phase Initialization (_init hook) ===")

local Entity = {}
Entity.__index = Entity

-- Phase 1: Allocation
setmetatable(Entity, {
    __call = function(cls, ...)
        local instance = setmetatable({}, cls)
        instance:_init(...) -- Phase 2: Initialization
        return instance
    end
})

function Entity:_init(name, x, y)
    self.name = name or "Unnamed"
    self.x = x or 0
    self.y = y or 0
end

function Entity:move(dx, dy)
    self.x = self.x + dx
    self.y = self.y + dy
    return self
end

function Entity:__tostring()
    return string.format("Entity('%s', pos: <%d, %d>)", self.name, self.x, self.y)
end

-- Subclassing Entitty: Player
local Player = setmetatable({}, {
    __index = Entity, -- Inherit Entity methods
    __call = getmetatable(Entity).__call
})
Player.__index = Player
Player.__tostring = function(self)
    return string.format("Player('%s', pos: <%d, %d>, hp: %d)", self.name, self.x, self.y, self.hp)
end

function Player:_init(name, x, y, hp)
    -- Chain parent initialization
    Entity._init(self, name, x, y)
    -- Subclass-specifi fields
    self.hp = hp or 100
end

-- Chapter 2 Demo
local e = Entity("Rock", 5, 10)
print(e)

local p = Player("Hero", 0, 0, 150)
p:move(3, 4)
print(p)

-- ============================================================================
-- Chapter 3: Single-Pass Polymorphic Inheritance
-- Key Concepts:
--   1. Dynamic 'self' in base constructor prevents double-blessing
--   2. Explicit parent delegation via Character.new(self, ...)
--   3. Method overriding with polymorphic behavior
-- ============================================================================
print("\n=== Chapter 3: Single-Pass Polymorphic Inheritance ===")

local Character = {}
Character.__index = Character

setmetatable(Character, {
    __call = function(cls, ...)
        return cls:new(...)
    end
})

function Character:new(name, health)
    -- 'self' dynamically binds to the calling class (Character or Warrior)
    local instance = setmetatable({}, self)
    instance.name = name or "Hero"
    instance.health = health or 100
    instance.level = 1
    return instance
end

function Character:take_damage(amount)
    self.health = math.max(0, self.health - amount)
    print(string.format("%s took %d damage. Health is now %d", self.name, amount, self.health))
    return self.health
end

function Character:display_status()
    print(string.format("Name: %-8s | Level: %d | Health: %3d", self.name, self.level, self.health))
end

-- Subclass: Warrior
local Warrior = setmetatable({}, {
    __index = Character,
    __call = function(cls, ...)
        return cls:new(...)
    end
})
Warrior.__index = Warrior

function Warrior:new(name, health, armor)
    -- Single-pass instantiation: pass 'self' (Warrior) into Character.new
    local instance = Character.new(self, name, health)
    instance.armor = armor or 10
    return instance
end

function Warrior:take_damage(amount)
    local effective_damage = math.max(1, amount - self.armor)
    print(string.format("%s's armor (%d) absorbed damage! Incoming: %d -> Effective: %d",
        self.name, self.armor, amount, effective_damage))
    return Character.take_damage(self, effective_damage)
end

function Warrior:shield_bash()
    print(string.format("%s performs a shield bash with armor rating %d!", self.name, self.armor))
end

-- Chapter 3 Demo
local mage = Character("Gandalf", 80)
mage:display_status()
mage:take_damage(25)

local thorin = Warrior("Thorin", 150, 20)
thorin:display_status()
thorin:take_damage(35)
thorin:shield_bash()
