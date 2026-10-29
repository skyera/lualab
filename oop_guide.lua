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

-- ============================================================================
-- Chapter 4: Dynamic Properties & Geometric Metamethods
-- Key Concepts:
--   1. Clean constructor arguments (no dummy 'nil')
--   2. Dynamically computed properties vs stale cached fields
--   3. Subclassing with geometric invariants (Square is a Rectangle)
--   4. Metamethods: __tostring and __eq
-- ============================================================================
print("\n=== Chapter 4: Dynamic Properties & Metamethods ===")

local Rectangle = {}
Rectangle.__index = Rectangle

setmetatable(Rectangle, {
    __call = function(cls, ...)
        return cls:new(...)
    end
})

function Rectangle:new(width, height)
    local instance = setmetatable({}, self)
    instance.width = width or 0
    instance.height = height or 0
    return instance
end

function Rectangle:area()
    return self.width * self.height
end

function Rectangle:perimeter()
    return 2 * (self.width + self.height)
end

function Rectangle:__tostring()
    return string.format("Rectangle(width: %d, height: %d, area: %d)",
        self.width, self.height, self:area())
end

function Rectangle.__eq(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return a.width == b.width and a.height == b.height
end

-- Subclass: Square (where width == height)
local Square = setmetatable({}, {
    __index = Rectangle,
    __call = function(cls, ...)
        return cls:new(...)
    end
})
Square.__index = Square
Square.__eq = Rectangle.__eq

function Square:new(side)
    local instance = Rectangle.new(self, side, side)
    return instance
end

function Square:__tostring()
    return string.format("Square(side: %d, area: %d)", self.width, self:area())
end

-- Chapter 4 Demo
local r1 = Rectangle(10, 20)
print(r1)
print("Perimeter:", r1:perimeter())

r1.width = 30
print("After resizing width to 30:", r1)

local s1 = Square(15)
print(s1)
print("Square perimeter (inherited):", s1:perimeter())

local r2 = Rectangle(30, 20)
print("r1 == r2:", r1 == r2)

-- ============================================================================
-- Chapter 5: The Universal Class:extend() Pattern
-- Key Concepts:
--   1. Reusable inheritance factory: Class:extend(name)
--   2. Automatic metamethod inheritance (__call, __tostring, __eq)
--   3. The 'super' reference: sub.super = self
--   4. Universal type inspection: instance:is_a(Class)
-- ============================================================================
print("\n=== Chapter 5: The Universal Class:extend() Pattern ===")

local Object = {}
Object.__index = Object

-- Creates a new sublcass linked to this class
function Object:extend(class_name)
    local sub = setmetatable({}, {
        __index = self,
        __call = function(cls, ...)
            return cls:new(...)
        end
    })
    sub.__index = sub
    sub.super = self
    sub.class_name = class_name or "AnonymousClass"

    sub.__tostring = self.__tostring
    sub.__eq = self.__eq

    return sub
end

function Object:new(...)
    local instance = setmetatable({}, self)
    if instance._init then
        instance:_init(...)
    end
    return instance
end

function Object:is_a(target_class)
    local cls = getmetatable(self)
    while cls do
        if cls == target_class then
            return true
        end
        cls = cls.super
    end
    return false
end

function Object:__tostring()
    return string.format("<%s instance>", self.class_name or "Object")
end

-- Chapter 5 Demo: Building a Class Hierarchy
local Vehicle = Object:extend("Vehicle")

function Vehicle:_init(brand, max_speed)
    self.brand = brand or "Generic"
    self.max_speed = max_speed or 60
end

function Vehicle:__tostring()
    return string.format("%s (Max Speed: %d mph)", self.brand, self.max_speed)
end

local ElectricCar = Vehicle:extend("ElectricCar")

function ElectricCar:_init(brand, max_speed, battery_capacity)
    ElectricCar.super._init(self, brand, max_speed)
    self.battery_capacity = battery_capacity or 75
end

function ElectricCar:__tostring()
    return string.format("%s (Max Speed: %d mph, Battery: %dkWh)",
        self.brand, self.max_speed, self.battery_capacity)
end

local v = Vehicle("Toyota Camry", 115)
local tesla = ElectricCar("Tesla Model 3", 140, 82)

print(v)
print(tesla)

print("tesla:is_a(ElectricCar):", tesla:is_a(ElectricCar))
print("tesla:is_a(Vehicle):    ", tesla:is_a(Vehicle))
print("tesla:is_a(Object):     ", tesla:is_a(Object))
print("v:is_a(ElectricCar):    ", v:is_a(ElectricCar))
