Person = {}
Person.__index = Person

function Person:new(name, age)
    local self = setmetatable({}, Person)
    self.name = name or "Unkown"
    self.age = age or 0
    return self
end

function Person:greet()
    print("Hello, my name is " .. self.name .. " and I'm " .. self.age .. " years old.")
end

Student = setmetatable({}, Person)
Student.__index = Student

function Student:new(name, age, grade)
    local self = setmetatable(Person.new(self, name, age), Student)
    self.grade = grade or "NA"
    return self
end

function Student:study()
    print(self.name .. " is studying in grade " .. self.grade .. ".")
end

local bob = Person:new("Bob", 20)
local alice = Student:new("Alice", 18, "9th")
bob:greet()
alice:greet()
alice:study()

