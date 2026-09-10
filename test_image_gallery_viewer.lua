--[[
    test_image_gallery_viewer.lua
    Unit tests for image_gallery_viewer.lua.
]]

print("=== Running Unit Tests for image_gallery_viewer.lua ===")

local tests = {
    {
        name = "Help display (--help)",
        cmd = "./LuaJIT/src/luajit image_gallery_viewer.lua --help",
        expect = "Terminal Directory Image Viewer"
    },
    {
        name = "Default current directory listing",
        cmd = "printf 'q\\n' | ./LuaJIT/src/luajit image_gallery_viewer.lua --no-interactive",
        expect = "portrait.png"
    },
    {
        name = "Custom input directory listing (portraits)",
        cmd = "printf 'q\\n' | ./LuaJIT/src/luajit image_gallery_viewer.lua portraits --no-interactive",
        expect = "01_traditional_hanfu_lady.png"
    },
    {
        name = "Direct image view via --select flag",
        cmd = "./LuaJIT/src/luajit image_gallery_viewer.lua portraits --select 1",
        expect = "IMAGE VIEWER [1/"
    },
    {
        name = "Empty directory graceful notification",
        cmd = "./LuaJIT/src/luajit image_gallery_viewer.lua LuaBridge",
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
