#!/usr/bin/env luajit
-- oop_class_helper_v1.lua: Rect/Square built with a class() helper

local function class(parent)
    local cls = {}
    cls.__index = cls

    if parent then
        setmetatable(cls, { __index = parent })

        for key, value in pairs(parent) do
            if key:sub(1, 2) == "__" and key ~= "__index" then
                cls[key] = value
            end
        end
    end

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

local r = Rect.new(3, 4)
print(r:area())

local Square = class(Rect)

function Square:init(side)
    Rect.init(self, side, side)
end

print(Square.new(5):area())
