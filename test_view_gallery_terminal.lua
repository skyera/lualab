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

-- Create synthetic test fixture with EXIF DateTimeOriginal
local exif_test_file = (os.getenv("TEMP") or "/tmp") .. "/test_gallery_exif.jpg"
if package.config:sub(1,1) == '\\' then
    exif_test_file = (os.getenv("TEMP") or "."):gsub("\\", "/") .. "/test_gallery_exif.jpg"
end
local f_exif = io.open(exif_test_file, "wb")
if f_exif then
    local tiff_payload = "II\x2A\x00\x08\x00\x00\x00\x02\x00" ..
        "\x32\x01\x02\x00\x14\x00\x00\x00\x26\x00\x00\x00" ..
        "\x69\x87\x04\x00\x01\x00\x00\x00\x3A\x00\x00\x00" ..
        "\x00\x00\x00\x00" ..
        "2024:06:15 10:20:30\x00" ..
        "\x01\x00" ..
        "\x03\x90\x02\x00\x14\x00\x00\x00\x26\x00\x00\x00" ..
        "\x00\x00\x00\x00"
    local app1_len = 2 + 6 + #tiff_payload
    local app1 = "\xFF\xE1" .. string.char(math.floor(app1_len/256), app1_len%256) .. "Exif\0\0" .. tiff_payload
    local minimal_jpeg = "\xFF\xD8" .. app1 ..
        "\xFF\xDB\x00\x43\x00" .. string.rep("\x10", 64) ..
        "\xFF\xC0\x00\x0B\x08\x00\x01\x00\x01\x01\x01\x11\x00" ..
        "\xFF\xC4\x00\x1F\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00" ..
        "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B" ..
        "\xFF\xDA\x00\x08\x01\x01\x00\x00\x3F\x00\x7F\x00\xFF\xD9"
    f_exif:write(minimal_jpeg)
    f_exif:close()
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
    },
    {
        name = "EXIF timestamp extraction in viewer header",
        cmd = luajit .. " view_gallery_terminal.lua " .. exif_test_file .. " --timg-half --select 1",
        expect = "Date: 2024-06-15 10:20:30 (EXIF)"
    },
    {
        name = "Filesystem timestamp fallback in viewer header",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --timg-half --select 1",
        expect = "(File)"
    },
    {
        name = "Render engine detection list in --help",
        cmd = luajit .. " view_gallery_terminal.lua --help",
        expect = "Render Engines (Detected on this system):"
    },
    {
        name = "Viewer header engine position indicator [cur/total]",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --select 1 --truecolor",
        expect = "Engine: ["
    },
    {
        name = "Viewer header engine available count in cycle hint",
        cmd = luajit .. " view_gallery_terminal.lua pillars_of_creation.jpg --select 1 --truecolor",
        expect = "available)"
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

os.remove(exif_test_file)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, #tests))
if passed == #tests then
    print("\27[1;32mALL IMAGE GALLERY VIEWER TESTS PASSED!\27[0m")
else
    os.exit(1)
end
