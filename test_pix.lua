--[[
    test_pix.lua
    Unit tests for pix.lua (Terminal Media Viewer).
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
        expect = "Terminal Media Viewer"
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
        expect = "Terminal Media Viewer"
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
        expect = "Videos: MP4, MKV, WEBM, AVI, MOV, M4V, FLV"
    },
    {
        name = "MPV standalone window option listed in --help",
        cmd = luajit .. " pix.lua --help",
        expect = "--window, -w"
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
    },
    {
        name = "UTF-8 text helpers: CJK counts as two columns, truncation never splits a character",
        cmd = luajit .. [==[ -e '
local s = io.open("pix.lua"):read("*a")
local i = s:find("local function codepoint_width", 1, true)
local j = s:find("if is_windows then", i, true)
assert(i and j, "text helper block not found in pix.lua")
local H = assert(loadstring(s:sub(i, j - 1) .. "\nreturn { display_width = display_width, utf8_truncate = utf8_truncate, utf8_tail = utf8_tail }\n", "helpers"))()
local function valid_utf8(str)
    local k = 1
    while k <= #str do
        local b = str:byte(k)
        local len = (b < 0x80 and 1) or (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 0
        if len == 0 then return false end
        for m = 1, len - 1 do
            local c = str:byte(k + m)
            if not c or c < 0x80 or c >= 0xC0 then return false end
        end
        k = k + len
    end
    return true
end
assert(H.display_width("photo.png") == 9, "ASCII width")
assert(H.display_width("中文图片.png") == 12, "CJK width")
assert(H.display_width("café.png") == 8, "accented width")
assert(H.utf8_truncate("photo.png", 40) == "photo.png", "short name untouched")
assert(H.utf8_truncate("space one.png", 20) == "space one.png", "short name with space untouched")
local cut = H.utf8_truncate("中文图片.png", 10)
assert(H.display_width(cut) <= 10, "truncated CJK name must fit the column")
assert(cut == "中文图...", "truncated CJK name content")
assert(valid_utf8(cut), "truncation must not split a multi-byte sequence")
local ascii_cut = H.utf8_truncate("abcdefghijkl", 10)
assert(ascii_cut == "abcdefg...", "ASCII truncation behaviour unchanged")
assert(valid_utf8(H.utf8_tail("/home/中文目录/照片.png", 12)), "tail truncation valid UTF-8")
assert(H.utf8_tail("/tmp/x.png", 40) == "/tmp/x.png", "short path untouched")
print("OK_UTF8_TEXT")' ]==],
        expect = "OK_UTF8_TEXT"
    },
    {
        name = "Windows filenames are transcoded for the UTF-8 console (both text paths wired)",
        cmd = luajit .. [==[ -e '
local s = io.open("pix.lua"):read("*a")
assert(s:find("local to_display_text", 1, true), "to_display_text not declared")
assert(s:find("to_display_text = function(s) return s end", 1, true), "POSIX identity missing")
assert(s:find("if kernel32.GetACP() == 65001 then", 1, true), "Windows UTF-8 fast path missing")
assert(s:find("kernel32.MultiByteToWideChar(0, 0, s, #s, nil, 0)", 1, true), "ANSI->wide conversion missing")
assert(s:find("kernel32.WideCharToMultiByte(65001, 0, wbuf, wlen, nil, 0, nil, nil)", 1, true), "wide->UTF-8 conversion missing")
assert(s:find("utf8_truncate(to_display_text(img.filename), max_fn_w)", 1, true), "file list row not transcoded")
assert(s:find("to_display_text(img_entry.filename)", 1, true), "viewer title not transcoded")
assert(s:find("local dpath = to_display_text(img_entry.filepath)", 1, true), "viewer path not transcoded")
assert(s:find("to_display_text(dir_path)", 1, true), "directory header not transcoded")
assert(s:find("local wpath = to_wide(0) -- CP_ACP", 1, true), "GDI+ does not try the system code page")
assert(s:find("wpath = to_wide(65001) -- CP_UTF8", 1, true), "GDI+ UTF-8 fallback missing")
assert(s:find("local icon_cols = display_width(icon_prefix)", 1, true), "icon width hardcoded again")
print("OK_CJK_WIRING")' ]==],
        expect = "OK_CJK_WIRING"
    },
    {
        name = "GBK (CP936) filenames render correctly through to_display_text",
        cmd = (package.config:sub(1,1) == '\\')
            and (luajit .. " -e 'local s = io.open(\"pix.lua\"):read(\"*a\"); assert(s:find(\"MultiByteToWideChar(0, 0, s\", 1, true)); print(\"OK_CJK_DISPLAY\")'")
            or (luajit .. [==[ -e '
local function sh(c) local f = io.popen(c); if not f then return "" end local s = f:read("*a") or ""; f:close(); return s end
local LJ = (arg and arg[0]) or "luajit"
local tmp = (os.getenv("TEMP") or "/tmp"):gsub("\\", "/")
local dir = tmp .. "/test_pix_cjk"
os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
local gbk = "\214\208\206\196\205\188\198\172.png"  -- 中文图片.png stored as GBK bytes
local g = assert(io.open(dir .. "/" .. gbk, "wb")); g:write("P6\n1 1\n255\n\255\0\0"); g:close()
local a = assert(io.open(dir .. "/ascii_one.png", "wb")); a:write("P6\n1 1\n255\n\0\0\255"); a:close()
local src = io.open("pix.lua"):read("*a")
local ident = "    -- POSIX filenames are already UTF-8 bytes, exactly what the terminal expects\n    to_display_text = function(s) return s end\n"
local at = src:find(ident, 1, true)
assert(at, "POSIX to_display_text assignment not found")
local stub = [[    local CP936 = { ["\214\208"] = "\228\184\173", ["\206\196"] = "\230\150\135", ["\205\188"] = "\229\155\190", ["\198\172"] = "\231\137\135" }
    to_display_text = function(s)
        if type(s) ~= "string" then return s end
        local out, i = {}, 1
        while i <= #s do
            local b = s:byte(i)
            if b < 0x80 then out[#out + 1] = string.char(b); i = i + 1
            else out[#out + 1] = CP936[s:sub(i, i + 1)] or "?"; i = i + 2 end
        end
        return table.concat(out)
    end
]]
local sim = tmp .. "/test_pix_cjk_sim.lua"
local out = assert(io.open(sim, "wb"))
out:write(src:sub(1, at - 1), stub, src:sub(at + #ident)); out:close()
local function listing(script) return sh("echo q | " .. LJ .. " " .. script .. " " .. dir .. " --no-interactive 2>&1") end
local expect = "\228\184\173\230\150\135\229\155\190\231\137\135.png"  -- 中文图片.png in UTF-8
local before, after = listing("pix.lua"), listing(sim)
assert(after:find(expect, 1, true), "transcoded listing does not show the UTF-8 name")
assert(not before:find(expect, 1, true), "control build unexpectedly shows the UTF-8 name")
os.remove(sim)
os.execute("rm -rf " .. dir)
print("OK_CJK_DISPLAY")' ]==] .. " " .. luajit),
        expect = "OK_CJK_DISPLAY"
    },
    {
        name = "UTF-8 multi-byte search filtering and backspace truncation",
        cmd = luajit .. [==[ -e '
local s = io.open("pix.lua"):read("*a")
local i = s:find("local function filter_images", 1, true)
local j = s:find("local function main()", i, true)
assert(i and j, "filter_images not found")
local fn_code = s:sub(i, j - 1)
local env = {
    to_display_text = function(x) return x end,
    table = table,
    ipairs = ipairs
}
local f = assert(loadstring(fn_code .. "\nreturn filter_images"))
setfenv(f, env)
local filter = f()
local items = {
    { filename = "中文测试_01.png", filepath = "/tmp/中文测试_01.png" },
    { filename = "photo_café.jpg", filepath = "/tmp/photo_café.jpg" },
    { filename = "mountain.ppm", filepath = "/tmp/mountain.ppm" }
}
local cjk_res = filter(items, "中文")
assert(#cjk_res == 1 and cjk_res[1].filename == "中文测试_01.png", "CJK filter failed")
local cafe_res = filter(items, "café")
assert(#cafe_res == 1 and cafe_res[1].filename == "photo_café.jpg", "Accent filter failed")

-- Verify UTF-8 multi-byte deletion logic
local q = "中文"
local cut = #q
while cut > 0 and q:byte(cut) >= 0x80 and q:byte(cut) < 0xC0 do cut = cut - 1 end
if cut > 0 then cut = cut - 1 end
q = q:sub(1, cut)
assert(q == "中", "Multi-byte backspace failed to retain single remaining CJK character")

print("OK_UTF8_SEARCH")' ]==],
        expect = "OK_UTF8_SEARCH"
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
