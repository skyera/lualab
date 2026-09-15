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

-- Create hidden-entry fixture: a dot image, a dot directory holding an image, plus a visible control
local hidden_fixture_dir = (os.getenv("TEMP") or "/tmp") .. "/test_pix_hidden"
if package.config:sub(1,1) == '\\' then
    hidden_fixture_dir = (os.getenv("TEMP") or "."):gsub("\\", "/") .. "/test_pix_hidden"
end
do
    local win = package.config:sub(1,1) == '\\'
    local win_dir = hidden_fixture_dir:gsub("/", "\\")
    if win then
        os.execute(string.format('rmdir /s /q "%s" 2>nul', win_dir))
        os.execute(string.format('mkdir "%s" 2>nul', win_dir))
        os.execute(string.format('mkdir "%s\\.dot_dir" 2>nul', win_dir))
    else
        os.execute(string.format('rm -rf "%s"', hidden_fixture_dir))
        os.execute(string.format('mkdir -p "%s/.dot_dir"', hidden_fixture_dir))
    end

    local function touch(name)
        local f = io.open(hidden_fixture_dir .. "/" .. name, "wb")
        if f then f:write("\137PNG\r\n\026\n") f:close() end
    end
    touch("visible.png")
    touch(".dot_photo.png")
    touch(".dot_dir/inside.png")
end

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
        expect = "Videos: MP4, MKV, WEBM, AVI, MOV, M4V, FLV (via mpv, libavcodec FFI, or ffmpeg)"
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
        name = "Video player engine & mpv shortcut keys documented in help modal",
        cmd = luajit .. " -e 'local f = io.open(\"pix.lua\"); local s = f:read(\"*a\"); f:close(); assert(s:find(\"Video Playback %(engine & mpv shortcuts%)\")); assert(s:find(\"Cycle play engine\")); print(\"OK_MPV_HELP\")'",
        expect = "OK_MPV_HELP"
    },
    {
        name = "Video play engine registry and [m] cycling implementation",
        cmd = luajit .. " -e 'local f = io.open(\"pix.lua\"); local s = f:read(\"*a\"); f:close(); assert(s:find(\"VIDEO_PLAY_ENGINES\")); assert(s:find(\"cycle_play_engine\")); assert(s:find(\"resolve_inline_play_engine\")); assert(s:find(\"play_engine_hint\")); print(\"OK_PLAY_ENGINES\")'",
        expect = "OK_PLAY_ENGINES"
    },
    {
        name = "mpv hand-off captures dependency stderr and surfaces it only on failure",
        cmd = luajit .. " -e 'local f = io.open(\"pix.lua\"); local s = f:read(\"*a\"); f:close(); assert(s:find(\"get_mpv_stderr_log_path\", 1, true)); assert(s:find(\"show_mpv_failure\", 1, true)); assert(s:find(\"pix_mpv_stderr.log\", 1, true)); assert(s:find(\"2>nul\", 1, true)); print(\"OK_MPV_STDERR\")'",
        expect = "OK_MPV_STDERR"
    },
    {
        name = "Hidden (dot) entries are skipped by default",
        cmd = "echo q | " .. luajit .. " pix.lua \"" .. hidden_fixture_dir .. "\" --no-interactive 2>&1 | grep -q dot_photo && echo UNEXPECTED_HIDDEN || echo HIDDEN_EXCLUDED",
        expect = "HIDDEN_EXCLUDED"
    },
    {
        name = "--hidden lists dot files and dot directories",
        cmd = "out=$(echo q | " .. luajit .. " pix.lua \"" .. hidden_fixture_dir .. "\" --no-interactive --hidden 2>&1); "
            .. "echo \"$out\" | grep -q dot_photo && echo \"$out\" | grep -q dot_dir && echo HIDDEN_SHOWN || echo MISSING_HIDDEN",
        expect = "HIDDEN_SHOWN"
    },
    {
        name = "-a alias enables hidden entries",
        cmd = "echo q | " .. luajit .. " pix.lua \"" .. hidden_fixture_dir .. "\" --no-interactive -a 2>&1 | grep -q dot_photo && echo HIDDEN_SHOWN || echo MISSING_HIDDEN",
        expect = "HIDDEN_SHOWN"
    },
    {
        name = "Recursive scan descends into dot directories only when hidden is on",
        cmd = "echo q | " .. luajit .. " pix.lua \"" .. hidden_fixture_dir .. "\" -r --no-interactive --hidden 2>&1 | grep -q inside.png && echo DESCENDED || echo NOT_DESCENDED",
        expect = "DESCENDED"
    },
    {
        name = "Hidden toggle wiring ([.] key, help entry, CLI flag)",
        cmd = luajit .. " -e 'local f = io.open(\"pix.lua\"); local s = f:read(\"*a\"); f:close(); assert(s:find(\"show_hidden = not show_hidden\", 1, true)); assert(s:find(\"Toggle hidden files\", 1, true)); assert(s:find(\"--hidden, -a\", 1, true)); print(\"OK_HIDDEN_TOGGLE\")'",
        expect = "OK_HIDDEN_TOGGLE"
    },
    {
        name = "Frame pacing uses the shared sleep_ms helper (Windows kernel32 fix)",
        cmd = luajit .. " -e 'local s = io.open(\"pix.lua\"):read(\"*a\"); assert(s:find(\"local sleep_ms\", 1, true)); assert(s:find(\"sleep_ms = function(ms)\", 1, true)); assert(s:find(\"kernel32.Sleep(ms)\", 1, true)); assert(s:find(\"ffi.C.poll(nil, 0, ms)\", 1, true)); assert(s:find(\"sleep_ms(math.floor(wait_dt * 1000))\", 1, true)); assert(s:find(\"kernel32.Sleep(wait_ms)\", 1, true) == nil); print(\"OK_SLEEP_HELPER\")'",
        expect = "OK_SLEEP_HELPER"
    },
    {
        name = "CLI fallback reads real video dimensions (hex codec tags cannot match)",
        cmd = luajit .. [==[ -e '
local function popen(c) local f = io.popen(c); if not f then return "" end; local s = f:read("*a"); f:close(); return s end
local s = io.open("pix.lua"):read("*a")
local marker = [[info:match("Video:]]
local i = s:find(marker, 1, true)
assert(i, "banner dimension parse line not found in pix.lua")
local j = s:find([[")]], i, true)
local pat = s:sub(i + #marker, j - 1)
assert(s:find("-show_entries stream=width,height", 1, true), "ffprobe width/height probe missing")
assert(pat ~= "%s(%d+)x(%d+)", "ambiguous old banner pattern is back")
local banner = popen("ffmpeg -i ]==] .. video_test_file .. [==[ 2>&1")
assert(banner:find("0x31637661", 1, true), "fixture banner lacks the hex codec tag that broke the parse")
local w, h = banner:match(pat)
assert(w == "64" and h == "64", "parsed " .. tostring(w) .. "x" .. tostring(h) .. " from the banner")
print("OK_VIDEO_DIMS_PARSE")' ]==],
        expect = "OK_VIDEO_DIMS_PARSE"
    },
    {
        name = "[q] backs out of player/viewer to the file list, [Q]/Ctrl+C quits",
        cmd = luajit .. [==[ -e 'local s = io.open("pix.lua"):read("*a"); assert(s:find([[if k == "Q" or k == "CTRL_C" then]], 1, true)); assert(s:find([[elseif k == "q" or k == "ESC" or k == "b" then]], 1, true)); assert(s:find([[elseif k == "q" or k == "ESC" or k == "ENTER" or k == "b" or k == "BACKSPACE" then]], 1, true)); assert(s:find([[\27[91m[q]\27[0m Back]], 1, true)); assert(s:find("Return to the file list", 1, true)); print("OK_Q_BACK")' ]==],
        expect = "OK_Q_BACK"
    },
    {
        name = "FFmpeg CLI play engine listed in --help",
        cmd = luajit .. " pix.lua --help",
        expect = "--play-engine ffmpeg"
    },
    {
        name = "Play engine cycle hint and default listed in --help",
        cmd = luajit .. " pix.lua --help",
        expect = "Play engines (cycle in the player with [m]):"
    },
    {
        name = "Video player mpv controls implementation (speed, loop, frame-step, seek)",
        cmd = luajit .. " -e 'local f = io.open(\"pix.lua\"); local s = f:read(\"*a\"); f:close(); assert(s:find(\"playback_speed\")); assert(s:find(\"is_loop\")); assert(s:find(\"%%[Space/p%%]\")); print(\"OK_MPV_CONTROLS\")'",
        expect = "OK_MPV_CONTROLS"
    },
    {
        name = "AVFrame struct layout pts offset verification (136 bytes)",
        cmd = luajit .. " -e 'local ffi = require(\"ffi\"); local s = io.open(\"pix.lua\"):read(\"*a\"); local cdef = s:match(\"typedef struct AVFrame .-}%s*AVFrame;\"); ffi.cdef(\"typedef struct AVRational { int num, den; } AVRational; \" .. cdef); assert(ffi.offsetof(\"AVFrame\", \"pts\") == 136); print(\"OK_PTS_OFFSET_136\")'",
        expect = "OK_PTS_OFFSET_136"
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
if package.config:sub(1,1) == '\\' then
    os.execute(string.format('rmdir /s /q "%s" 2>nul', hidden_fixture_dir:gsub("/", "\\")))
else
    os.execute(string.format('rm -rf "%s"', hidden_fixture_dir))
end

print(string.format("\nTest Summary: %d / %d tests passed.", passed, #tests))
if passed == #tests then
    print("\27[1;32mALL PIX TESTS PASSED!\27[0m")
else
    os.exit(1)
end
