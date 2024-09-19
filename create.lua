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

local tbl = foo.create_table()
print(tbl)

for k, v in pairs(tbl) do
    print(k, v)
end
local x = foo.bar()
print(x)
