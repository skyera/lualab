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
    -- obj.value = value
    obj:init(value)
    return obj
end

function MyClass:init(value)
    self.value = value
end

function MyClass:get_value()
    return self.value
end

local function trace(event)
    local info = debug.getinfo(2)
    if event == "call" then
        print("call", info.name)
    elseif event == "return" then
        print("return", info.name)
    end
end

debug.sethook(trace, "cr")

obj1 = MyClass(3)
obj2 = MyClass(4)
print(obj1:get_value())
print(obj2:get_value())

obj3 = MyClass.new(5)
print(obj3:get_value())
