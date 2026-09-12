--[[
    test_view_gallery_terminal.lua
    Unit tests for view_gallery_terminal.lua.
]]

print("=== Running Unit Tests for view_gallery_terminal.lua ===")

local luajit = "luajit"
local f_check = io.open("./LuaJIT/src/luajit", "rb") or io.open("./LuaJIT/src/luajit.exe", "rb")
if f_check then
    f_check:close()
    luajit = (package.config:sub(1,1) == '\\') and ".\\LuaJIT\\src\\luajit.exe" or "./LuaJIT/src/luajit"
end

local tests = {
    {
        name = "Help display (--help)",
        cmd = luajit .. " view_gallery_terminal.lua --help",
        expect = "Terminal Directory Image Viewer"
    },
    {
        name = "Default current directory listing",
        cmd = "echo q| " .. luajit .. " view_gallery_terminal.lua --no-interactive",
        expect = "portrait.png"
    },
    {
        name = "Custom input directory listing (portraits)",
        cmd = "echo q| " .. luajit .. " view_gallery_terminal.lua portraits --no-interactive",
        expect = "01_traditional_hanfu_lady.png"
    },
    {
        name = "Direct image view via --select flag",
        cmd = luajit .. " view_gallery_terminal.lua portraits --select 1",
        expect = "IMAGE VIEWER [1/"
    },
    {
        name = "Empty directory graceful notification",
        cmd = luajit .. " view_gallery_terminal.lua LuaBridge",
        expect = "No supported images found"
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
    print("\27[1;32mALL IMAGE GALLERY VIEWER TESTS PASSED!\27[0m")
else
    os.exit(1)
end
