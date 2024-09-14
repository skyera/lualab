Car = {}

function Car:new(make, model, year)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self

    obj.make = make
    obj.model = model
    obj.year = year
    obj.speed = 0
    return obj
end

function Car:accelerate(increase)
    self.speed = self.speed + increase
    print(self.make .. " " .. self.model .. " " .. " is now going at "
        .. self.speed)
end

function Car:brake(decrease)
    self.speed = self.speed - decrease
    if self.speed < 0 then
        self.speed = 0
    end
    print(self.make .. " " .. self.model .. " " .. " slowed down to " 
        .. self.speed)
end

function Car:getDetails()
    return "Make: " .. self.make .. ", Model:  " .. self.model .. ", Year: " 
    .. self.year
end

local function print_help()
    print("Usage: lua script.lua <arg1> <arg2>")
    print("Description:")
    print(" <arg1>: First arg")
    print(" <arg2>: Second arg")
    print("Example:")
    print(" lua script.lya input1 input2")
end


if #arg < 2 or arg[1] == "-h" or arg[1] == "--help" then
    print_help()
    os.exit(1)
end

local arg1 = arg[1]
local arg2 = arg[2]
print("Argument 1:", arg1)
print("Argument 2:", arg2) 

for i=0, 10 do
    print("[] Item", i+1)
end

myCar = Car:new("Ford", "Mustang", 1969)
myCar:accelerate(20)
myCar:brake(5)
print(myCar:getDetails())
