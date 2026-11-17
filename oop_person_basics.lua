#!/usr/bin/env luajit
-- oop_person_basics.lua: a minimal class built from a table and a metatable.

local Person = {}
Person.__index = Person

function Person.new(name, age)
    local instance = setmetatable({}, Person)
    instance.name = name
    instance.age = age
    return instance
end

function Person:say_hello()
    print("Hello, my name is " .. self.name
        .. " and I am " .. self.age .. " years old.")
end

local person = Person.new("Alice", 25)
person:say_hello()
