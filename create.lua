local json = require 'json'

local t = json.decode('[1,2,3,{"x":10}]') -- Returns { 1, 2, 3, { x = 10 } }

for k, v in pairs(t) do
    print(k, v)
end
t2 = t[4]

print(t2.x)
for k, v in pairs(t2) do
    print(k, v)
end

print("arg:")
for k, v in pairs(arg) do
    print(k, v)
end

if #arg == 1 and arg[1] == '-h' then
    print("usage: script.lua arg1 arg2")
end

local tbl = foo.create_table()
print(tbl)

for k, v in pairs(tbl) do
    print(k, v)
end
local x = foo.bar()
print(x)

local handle = io.popen("ls -l")
local result = handle:read("*a")
handle:close()
print(result)

local handle = io.popen("ping -c 4 google.com")

for line in handle:lines() do
    print(line)
end

handle:close()
