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

-- Inheritance
print("Inheritance")
local BaseClass = {}
BaseClass.__index = BaseClass

setmetatable(BaseClass, {
    __call = function(cls, ...)
        local obj = setmetatable({}, cls)
        obj:_init(...)
        return obj
    end,
})

function BaseClass:_init(value)
    print(debug.traceback("BaseClass::_init"))
    self.value = value
end

function BaseClass:set_value(newval)
    self.value = newval
end

function BaseClass:get_value()
    return self.value
end

local DerivedClass = {}
DerivedClass.__index = DerivedClass

setmetatable(DerivedClass, {
    __index = BaseClass, -- inheritance
    __call = function(cls, ...)
        local obj = setmetatable({}, cls)
        obj:_init(...)
        return obj
    end,
})

function DerivedClass:_init(val1, val2)
    BaseClass._init(self, val1)
    self.value2 = val2
end

function DerivedClass:get_value()
    return self.value + self.value2
end

local obj = DerivedClass(1, 2)
print(obj:get_value())
obj:set_value(3)
print(obj:get_value())

