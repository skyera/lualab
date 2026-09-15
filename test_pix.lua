--[[
    test_pix.lua
    Unit tests for pix.lua (Fast Terminal Image Viewer).
]]

print("=== Running Unit Tests for pix.lua ===")

local luajit = "luajit"
local f_check = io.open("./LuaJIT/src/luajit", "rb") or io.open("./LuaJIT/src/luajit.exe", "rb")
if f_check then
    f_check:close()
    luajit = (package.config:sub(1,1) == '\\') and ".\\LuaJIT\\src\\luajit.exe" or "./LuaJIT/src/luajit"
end

local tests = {
    {
        name = "CLI Help display (--help)",
        cmd = luajit .. " pix.lua --help",
        expect = "pix — Terminal Image Viewer"
    },
    {
        name = "CLI Help display (-h)",
        cmd = luajit .. " pix.lua -h",
        expect = "pix.lua <image_path>"
    },
    {
        name = "Missing argument prints usage",
        cmd = luajit .. " pix.lua",
        expect = "pix — Terminal Image Viewer"
    },
    {
        name = "Render JPEG image",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg 40 20",
        expect = "Displayed pillars_of_creation.jpg"
    },
    {
        name = "Render PNG image",
        cmd = luajit .. " pix.lua nebula_orion.png 40 20",
        expect = "Displayed nebula_orion.png"
    },
    {
        name = "Aspect ratio and pixel dimension reporting",
        cmd = luajit .. " pix.lua portrait.png 30 15",
        expect = "Rescaled:"
    },
    {
        name = "Non-existent file error reporting",
        cmd = luajit .. " pix.lua nonexistent_file_12345.png",
        expect = "Error loading image"
    }
}

local passed = 0
for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
    local out = p:read("*a")
    p:close()

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, #tests, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, #tests, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

print(string.format("\nTest Summary: %d / %d tests passed.", passed, #tests))
if passed == #tests then
    print("\27[1;32mALL PIX TESTS PASSED!\27[0m")
else
    os.exit(1)
end
