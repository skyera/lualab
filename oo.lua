-- http://lua-users.org/wiki/ObjectOrientationTutorial
-- : syntax sugar
--      call function
--      insert table as self
local MyClass = {}
MyClass.__index = MyClass
print("MyClass ", MyClass)

function MyClass.new(value)
    local obj = setmetatable({}, MyClass)
    obj.value = value
    return obj
end

function MyClass.set_value(self, newval)
    print("MyClass.set_value ", MyClass)
    self.value = newval
end

function MyClass.get_value(self)
    print("MyClass.get_value ", MyClass)
    return self.value
end

local obj = MyClass.new(3)
print("obj ", obj)
print(obj:get_value())
obj:set_value(4)
print(obj:get_value())

--
print("2nd version of class")
local MyClass = {}
MyClass.__index = MyClass

setmetatable(MyClass, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function MyClass.new(value)
    local obj = setmetatable({}, MyClass)
    obj.value = value
    return obj
end

function MyClass:set_value(newval)
    self.value = newval
end

function MyClass:get_value()
    return self.value
end

local obj = MyClass(3)
print(obj:get_value())
obj:set_value(1)
print(obj:get_value())
