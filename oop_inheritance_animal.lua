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

-- version 2
local Animal = {}
Animal.__index = Animal

function Animal:new(name)
    return setmetatable({name=name}, self)
end

function Animal:speak()
    print(self.name .. " makes a sound")
end

local Dog = setmetatable({}, Animal)
Dog.__index = Dog

function Dog:new(name, breed)
    local obj = Animal.new(self, name)
    obj.breed = breed
    return obj
end

function Dog:speak()
    print(self.name .. " barks! (Breed: " .. self.breed .. ")")
end

local a = Animal:new("Generic Animal")
a:speak()

local d = Dog:new("Buddy", "Golden Retriever")
d:speak()
