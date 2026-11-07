#!/usr/bin/env luajit
-- oop_call.lua: making tables callable with __call

local function make_counter()
    return setmetatable({ count = 0 }, {
        __call = function(self, step)
            self.count = self.count + (step or 1)
            return self.count
        end,
    })
end

local counter = make_counter()
print(counter())
print(counter(5))
print(counter())

local a, b = make_counter(), make_counter()
print(a(), a(), b())
print(type(counter))

local Point = {}
Point.__index = Point

function Point.new(x, y)
    return setmetatable({ x = x, y = y }, Point)
end

setmetatable(Point, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

local p = Point(3, 4)
print(p.x, p.y)
print(getmetatable(p) == Point)
