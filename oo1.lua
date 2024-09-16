MyClass = {}
MyClass.__index = MyClass

setmetatable(MyClass, {
    __call = function(cls, ...)
        local obj = setmetatable({}, cls)
        obj:init(...)
        return obj
    end,
})

function MyClass.new(value)
    local obj = setmetatable({}, MyClass)
    obj.value = value
    return obj
end

function MyClass:init(value)
    self.value = value
end

function MyClass:get_value()
    return self.value
end

obj1 = MyClass(3)
print(obj1:get_value())

obj2 = MyClass(4)
print(obj2:get_value())
print(obj1:get_value())
print(obj2:get_value())

