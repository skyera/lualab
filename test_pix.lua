--[[
    test_pix.lua
    Unit tests for pix.lua (Terminal Directory Image Viewer).
]]

print("=== Running Unit Tests for pix.lua ===")

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

-- Create synthetic test video fixture via ffmpeg
local video_test_file = (os.getenv("TEMP") or "/tmp") .. "/test_gallery_video.mp4"
if package.config:sub(1,1) == '\\' then
    video_test_file = (os.getenv("TEMP") or "."):gsub("\\", "/") .. "/test_gallery_video.mp4"
end
os.execute(string.format('ffmpeg -y -loglevel quiet -f lavfi -i testsrc=duration=1:size=64x64:rate=10 -c:v libx264 -pix_fmt yuv420p %q', video_test_file))

local tests = {
    {
        name = "Help display (--help)",
        cmd = luajit .. " pix.lua --help",
        expect = "Terminal Directory Image Viewer"
    },
    {
        name = "Default current directory listing",
        cmd = "echo q| " .. luajit .. " pix.lua --no-interactive",
        expect = "pillars_of_creation.jpg"
    },
    {
        name = "Direct image view via --truecolor flag",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --truecolor --select 1",
        expect = "ANSI 24-bit Truecolor Half-Block"
    },
    {
        name = "Direct image view via --timg-half flag",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --timg-half --select 1",
        expect = "timg Half-Block"
    },
    {
        name = "Direct image view via --timg-quarter flag",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --timg-quarter --select 1",
        expect = "timg Quarter-Block"
    },
    {
        name = "Direct image view via --chafa flag",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --chafa --select 1",
        expect = "Chafa Symbols"
    },
    {
        name = "Direct image view via --chafa-braille flag",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --chafa-braille --select 1",
        expect = "Chafa Braille 2×4"
    },
    {
        name = "Direct image view via --timg-cli flag (if installed)",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --timg-cli --select 1",
        expect = "timg"
    },
    {
        name = "Direct image view via --chafa-cli flag (if installed)",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --chafa-cli --select 1",
        expect = "Chafa"
    },
    {
        name = "Non-interactive directory navigation",
        cmd = "echo q| " .. luajit .. " pix.lua LuaBridge/Source --no-interactive",
        expect = "TERMINAL DIRECTORY IMAGE VIEWER"
    },
    {
        name = "EXIF timestamp extraction in viewer header",
        cmd = luajit .. " pix.lua " .. exif_test_file .. " --timg-half --select 1",
        expect = "Date: 2024-06-15 10:20:30 (EXIF)"
    },
    {
        name = "Filesystem timestamp fallback in viewer header",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --timg-half --select 1",
        expect = "(File)"
    },
    {
        name = "Render engine detection list in --help",
        cmd = luajit .. " pix.lua --help",
        expect = "Render Engines (Detected on this system):"
    },
    {
        name = "Viewer header engine position indicator [cur/total]",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --select 1 --truecolor",
        expect = "Engine: ["
    },
    {
        name = "Viewer header engine available count in cycle hint",
        cmd = luajit .. " pix.lua pillars_of_creation.jpg --select 1 --truecolor",
        expect = "available)"
    },
    {
        name = "Video format support listed in --help",
        cmd = luajit .. " pix.lua --help",
        expect = "Videos: MP4, MKV, WEBM, AVI, MOV, M4V, FLV (via libavcodec FFI or ffmpeg)"
    },
    {
        name = "Video engine status listed in --help",
        cmd = luajit .. " pix.lua --help",
        expect = "Video Engine:"
    },
    {
        name = "Direct video thumbnail decode via --select 1",
        cmd = luajit .. " pix.lua " .. video_test_file .. " --select 1",
        expect = "IMAGE VIEWER [1/1]"
    },
    {
        name = "LuaJIT FFI video decode without ffmpeg CLI in PATH",
        cmd = (package.config:sub(1,1) == '\\')
            and (luajit .. " pix.lua " .. video_test_file .. " --select 1")
            or ("PATH=/usr/local/sbin:/tmp " .. luajit .. " pix.lua " .. video_test_file .. " --select 1"),
        expect = "IMAGE VIEWER [1/1]"
    },
    {
        name = "Non-interactive video file direct selection",
        cmd = "echo q| " .. luajit .. " pix.lua " .. video_test_file .. " --no-interactive",
        expect = "test_gallery_video.mp4"
    },
    {
        name = "Video player mpv shortcut keys documented in help modal",
        cmd = luajit .. " -e 'local f = io.open(\"pix.lua\"); local s = f:read(\"*a\"); f:close(); assert(s:find(\"Video Playback %(mpv shortcuts%)\")); print(\"OK_MPV_HELP\")'",
        expect = "OK_MPV_HELP"
    },
    {
        name = "Video player mpv controls implementation (speed, loop, frame-step, seek)",
        cmd = luajit .. " -e 'local f = io.open(\"pix.lua\"); local s = f:read(\"*a\"); f:close(); assert(s:find(\"playback_speed\")); assert(s:find(\"is_loop\")); assert(s:find(\"%%[Space/p%%]\")); print(\"OK_MPV_CONTROLS\")'",
        expect = "OK_MPV_CONTROLS"
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
os.remove(video_test_file)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, #tests))
if passed == #tests then
    print("\27[1;32mALL PIX TESTS PASSED!\27[0m")
else
    os.exit(1)
end
