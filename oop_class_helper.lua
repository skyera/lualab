#!/usr/bin/env luajit
-- oop_class_helper.lua: Rect/Square OOP in Lua, from metatables to a class() helper

local Rect = {}
Rect.__index = Rect

function Rect.new(w, h)
    local instance = { width = w, height = h }
    setmetatable(instance, Rect)
    return instance
end

function Rect:area()
    return self.width * self.height
end

function Rect:describe()
    return string.format("Rect %dx%d", self.width, self.height)
end

function Rect.__tostring(self)
    return self:describe()
end

function Rect.__eq(a, b)
    return a:area() == b:area()
end

function Rect.__lt(a, b)
    return a:area() < b:area()
end

function Rect.__le(a, b)
    return a:area() <= b:area()
end

local Square = setmetatable({}, { __index = Rect })
Square.__index = Square
Square.__tostring = Rect.__tostring
Square.__eq = Rect.__eq
Square.__lt = Rect.__lt
Square.__le = Rect.__le

function Square.new(side)
    local instance = Rect.new(side, side)
    setmetatable(instance, Square)
    return instance
end

function Square:describe()
    return string.format("Square %d", self.width)
end

function Square:describe_full()
    return Rect.describe(self) .. " (square)"
end

local r = Rect.new(3, 4)
print(r:area())
local s = Square.new(5)
print(s:area())
print(getmetatable(s) == Square)

print(r:describe())
print(s:describe())
print(s:describe_full())

print("------")
print(r)
print(s)

print(Rect.new(2, 8) == Rect.new(4, 4))
print(Rect.new(4, 4) == Square.new(4))
print(r == s)
print(r < s)
print(s <= r)
print(r > s)
print(s >= r)
