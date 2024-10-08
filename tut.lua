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

list = {{3}, {5}, {2}, {-1}}
table.sort(list, function(a, b) return a[1] < b[1] end)
for i, v in ipairs(list) do
    print(v[1])
end

-- variable args
f = function(x, ...)
    x(...)
end

f(print, "1 2 3", "abc")

-- select
f = function(...)
    print(select('#', ...))
    print(select(3, ...))
end
f(1,2,3,4,5)

-- ...->table
f = function(...)
    tbl = {...}
    print(_VERSION)
    -- print(table.unpack(tbl))
end
f("a", "b", "c")

a = {b={}}
function a.b.f(...)
    print(...)
end
a.b.f(1,2,3)

-- closure
local x = 5
local function f()
    print(x)
end

f()
x = 6
f()

-- env in Lua5.1
-- each func has env table
-- getfenv/setfenv
--  * stack lvel
--  1: curr func
--  2: func that called curr func
print(getfenv(1) == _G)
a = 1
b = nil

local function f(t)
    local print=print
    setfenv(1, t)
    print(getmetatable)
    a=2
    b=3
end
local t = {}
f(t)
print(a, b)
print(t.a, t.b)
