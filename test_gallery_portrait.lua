--[[
    test_gallery_portrait.lua
    Unit tests for gallery_portrait.lua procedural generation, memory buffers, and rendering.
]]

local ffi = require("ffi")

print("=== Running Unit Tests for gallery_portrait.lua ===")

-- Load gallery_portrait in non-executing mode or require components
local chunk = assert(loadfile("gallery_portrait.lua"))

local luajit = "luajit"
local f_check = io.open("./LuaJIT/src/luajit", "rb") or io.open("./LuaJIT/src/luajit.exe", "rb")
if f_check then
    f_check:close()
    luajit = (package.config:sub(1,1) == '\\') and ".\\LuaJIT\\src\\luajit.exe" or "./LuaJIT/src/luajit"
end

-- Test direct execution with flags
local tests = {
    {
        name = "Help banner output",
        cmd = luajit .. " gallery_portrait.lua --help",
        expect = "Portrait Gallery of Ladies"
    },
    {
        name = "Batch image generation and save-all",
        cmd = "echo q| " .. luajit .. " gallery_portrait.lua --save-all --no-interactive",
        expect = "Saved portraits/portrait_1_lady.ppm"
    },
    {
        name = "Direct portrait selection (--select 3)",
        cmd = luajit .. " gallery_portrait.lua --select 3",
        expect = "LADY PORTRAIT INSPECTOR #3"
    },
    {
        name = "HTML gallery generation",
        cmd = "echo q| " .. luajit .. " gallery_portrait.lua --html test_gallery.html --no-interactive",
        expect = "Exported interactive HTML gallery to 'test_gallery.html'"
    }
}

local passed = 0
for i, t in ipairs(tests) do
    local handle = io.popen(t.cmd .. " 2>&1")
    local out = handle:read("*a")
    handle:close()
    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, #tests, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, #tests, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

-- Verify test_gallery.html exists and has valid content
local hf = io.open("test_gallery.html", "r")
if hf then
    local content = hf:read("*a")
    hf:close()
    os.remove("test_gallery.html")
    if content:find("canvas id=\"cv_1\"", 1, true) and content:find("openModal", 1, true) then
        print("  \27[32m✔ PASS\27[0m: HTML gallery structure verified with Canvas elements & Modal")
        passed = passed + 1
    end
end

print(string.format("\nTest Summary: %d / %d tests passed.", passed, #tests + 1))
if passed == #tests + 1 then
    print("\27[1;32mALL GALLERY TESTS PASSED SUCCESSFULLY!\27[0m")
else
    os.exit(1)
end
