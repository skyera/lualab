Animal = {}
Animal.__index = Animal

<<<<<<< HEAD
function Animal:new(name)
    o = setmetatable({}, self)
=======
function Animal.new(name)
    local o = setmetatable({}, Animal)
>>>>>>> 669d474 (class Animal)
    o.name = name
    o.sound = "Unknown"
    return o
end

function Animal:makeSound()
    print(self.name .. " says " .. self.sound)
end

Dog = {}
Dog.__index = Dog
<<<<<<< HEAD

function Dog:new(name)
    o = Animal:new(name)
    o.sound = "Woof!"
    setmetatable(o, self)
=======
setmetatable(Dog, {__index = Animal})

function Dog.new(name)
    local o = setmetatable(Animal.new(name), Dog)
    o.sound = "Woof!"
>>>>>>> 669d474 (class Animal)
    return o
end

function Dog:makeSound()
    print(self.name .. " says " .. self.sound)
end

<<<<<<< HEAD
local animal = Animal:new("Animal")
local dog = Dog:new("Dog")
=======
local animal = Animal.new("Animal")
local dog = Dog.new("Dog")
>>>>>>> 669d474 (class Animal)
animal:makeSound()
dog:makeSound()
