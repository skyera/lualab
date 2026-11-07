#!/usr/bin/env luajit
-- oop_class_helper.lua: Rect/Square built with a reusable class() helper

local function class(parent)
    local cls = {}
    cls.__index = cls

    local class_meta = {
        __call = function(c, ...)
            return c.new(...)
        end,
    }

    if parent then
        class_meta.__index = parent

        for key, value in pairs(parent) do
            if key:sub(1, 2) == "__" and key ~= "__index" then
                cls[key] = value
            end
        end
    end

    setmetatable(cls, class_meta)

    function cls.new(...)
        local obj = setmetatable({}, cls)
        obj:init(...)
        return obj
    end

    return cls
end

local Rect = class()

function Rect:init(w, h)
    self.width = w
    self.height = h
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

local r = Rect(3, 4)
print(r:area())

local Square = class(Rect)

function Square:init(side)
    Rect.init(self, side, side)
end

function Square:describe()
    return string.format("Square %d", self.width)
end

function Square:describe_full()
    return Rect.describe(self) .. " (square)"
end

local s = Square(5)
print(s:area())
print(getmetatable(s) == Square)

print(r:describe())
print(s:describe())
print(s:describe_full())

print("------")
print(r)
print(s)

print(Rect(2, 8) == Rect(4, 4))
print(Rect(4, 4) == Square(4))
print(r == s)
print(r < s)
print(s <= r)
print(r > s)
print(s >= r)
