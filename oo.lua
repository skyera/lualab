local MyClass = {}
MyClass.__index = MyClass

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
