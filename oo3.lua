Animal = {}
Animal.__index = Animal

function Animal:new(name)
    o = setmetatable({}, self)
    o.name = name
    o.sound = "Unknown"
    return o
end

function Animal:makeSound()
    print(self.name .. " says " .. self.sound)
end

Dog = {}
Dog.__index = Dog

function Dog:new(name)
    o = Animal:new(name)
    o.sound = "Woof!"
    setmetatable(o, self)
    return o
end

function Dog:makeSound()
    print(self.name .. " says " .. self.sound)
end

local animal = Animal:new("Animal")
local dog = Dog:new("Dog")
animal:makeSound()
dog:makeSound()
