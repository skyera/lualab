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

--- version 3
--- Parent class
local Animal = {}
Animal.__index = Animal

function Animal:new(name)
    local obj = {
        name = name
    }

    -- self = actual class (Animal, Dog, etc.)
    setmetatable(obj, self)

    return obj
end

function Animal:speak()
    print(self.name .. " makes a sound")
end

function Animal:eat()
    print(self.name .. " is eating")
end


-- Child class
local Dog = {}
Dog.__index = Dog

-- Dog inherits from Animal
setmetatable(Dog, {
    __index = Animal
})

function Dog:new(name)
    -- Pass Dog as self to parent constructor
    local obj = Animal.new(self, name)
    return obj
end

function Dog:bark()
    print(self.name .. " says Woof!")
end

-- Override parent method
function Dog:speak()
    print(self.name .. " says Woof Woof!")
end


-- Create object
local dog = Dog:new("Buddy")

dog:bark()       -- Dog method
dog:speak()      -- overridden Dog method
dog:eat()        -- inherited Animal method

-- Explicitly call parent method
Animal.speak(dog)
