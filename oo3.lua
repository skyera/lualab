Animal = {}
Animal.__index = Animal

function Animal.new(name)
    local o = setmetatable({}, Animal)
    o.name = name
    o.sound = "Unknown"
    return o
end

function Animal:makeSound()
    print(self.name .. " says " .. self.sound)
end

Dog = {}
Dog.__index = Dog
setmetatable(Dog, {__index = Animal})

function Dog.new(name)
    local o = setmetatable(Animal.new(name), Dog)
    o.sound = "Woof!"
    return o
end

function Dog:makeSound()
    print(self.name .. " says " .. self.sound)
end

local animal = Animal.new("Animal")
local dog = Dog.new("Dog")
animal:makeSound()
dog:makeSound()
