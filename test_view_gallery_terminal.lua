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
        expect = "pillars_of_creation.jpg"
    },
    {
        name = "Direct image view via --truecolor flag",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --truecolor --select 1",
        expect = "ANSI 24-bit Truecolor Half-Block"
    },
    {
        name = "Direct image view via --timg-half flag",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --timg-half --select 1",
        expect = "timg Half-Block"
    },
    {
        name = "Direct image view via --timg-quarter flag",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --timg-quarter --select 1",
        expect = "timg Quarter-Block"
    },
    {
        name = "Direct image view via --chafa flag",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --chafa --select 1",
        expect = "Chafa Symbols"
    },
    {
        name = "Direct image view via --chafa-braille flag",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --chafa-braille --select 1",
        expect = "Chafa Braille 2×4"
    },
    {
        name = "Direct image view via --timg-cli flag (if installed)",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --timg-cli --select 1",
        expect = "timg"
    },
    {
        name = "Direct image view via --chafa-cli flag (if installed)",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --chafa-cli --select 1",
        expect = "Chafa"
    },
    {
        name = "Non-interactive directory navigation",
        cmd = "echo q| " .. luajit .. " view_gallery_terminal.lua LuaBridge/Source --no-interactive",
        expect = "TERMINAL DIRECTORY IMAGE VIEWER"
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
