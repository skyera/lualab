who="Lua user"
print("hello " .. who)

print(1 ~= 0)

-- user data
-- foreign to Lua, obj in C

a, b = 1, 2
print(a, b)
a, b = b, a
print(a, b)

print(math.pi)
x = tonumber("123") + 25
print(x)

x = 100 + "7"
print(x)

x = "Green bottles: " .. 10
print(x)

-- slow
local s = ''
for i=1,10000 do
    s = s .. math.random() .. ','
end
-- io.stdout:write(s)

-- fast
for i=1, 1000 do
    tostring(math.random())
end

local t = {}
for i=1,10000 do
    t[i] = tostring(math.random())
end

x = string.byte("ABCDE", 2)
print(x)

x = string.char(65,66,67,68,69)
print(x)

x, y = string.find("hello Lua user", "Lua")
print(x, y)
