#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- oop_person_student.lua
-- Demonstrates Lua OOP inheritance and method overriding:
--   - Person base class with constructor and greet method
--   - Student subclass inheriting from Person via metatable __index
--   - Method overriding with explicit call to base implementation
--------------------------------------------------------------------------------

local Person = {}
Person.__index = Person

function Person.new(name, age)
    local instance = {
        name = name,
        age = age,
    }
    return setmetatable(instance, Person)
end

function Person:greet()
    return "Hi, I'm " .. self.name
end

local Student = setmetatable({}, { __index = Person })
Student.__index = Student

function Student.new(name, age, school)
    local instance = Person.new(name, age)
    instance.school = school
    return setmetatable(instance, Student)
end

function Student:greet()
    return Person.greet(self) .. " from " .. self.school
end

-- =============================================================================
-- Demo Usage
-- =============================================================================
local person = Person.new("Ann", 30)
print(person:greet())

local student = Student.new("Alice", 18, "SJSU")
print(student:greet())
