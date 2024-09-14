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
