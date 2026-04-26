Animal = {}
Animal.__index = Animal

function Animal:new(name)
    local obj = setmetatable({}, self)
    obj.name = name or "Unnamed"
    return obj
end

function Animal:speak()
    print(self.name .. " makes a sound.")
end

-- Derived class: inherit from Animal
Dog = setmetatable({}, {__index = Animal})
Dog.__index = Dog

function Dog:new(name, breed)
    local obj = Animal.new(self, name)
    obj.breed = breed or "Unknown"
    return obj
end

function Dog:speak()
    print(self.name .. " barks.i(" .. self.breed .. ")")
end

local a = Animal:new("Generic Animal")
a:speak()
local d = Dog:new("Fido", "Golden Retriever")
d:speak()
