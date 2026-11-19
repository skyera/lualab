#!/usr/bin/env luajit
-- oop_inheritance_person.lua: Person/Student inheritance via setmetatable.

local Person = {}
Person.__index = Person

function Person:new(name, age)
    local instance = setmetatable({}, self)
    instance.name = name or "Unknown"
    instance.age = age or 0
    return instance
end

function Person:greet()
    print("Hello, my name is " .. self.name
        .. " and I'm " .. self.age .. " years old.")
end

local Student = setmetatable({}, Person)
Student.__index = Student

function Student:new(name, age, grade)
    local instance = Person.new(self, name, age)
    instance.grade = grade or "NA"
    return instance
end

function Student:study()
    print(self.name .. " is studying in grade " .. self.grade .. ".")
end

local bob = Person:new("Bob", 20)
local alice = Student:new("Alice", 18, "9th")
bob:greet()
alice:greet()
alice:study()

