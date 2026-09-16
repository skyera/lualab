--[[
    test_yt.lua
    Validation and test suite for yt.lua backend functions.
]]

print("=== Running Backend Verification Tests for yt.lua ===")

local luajit = "./LuaJIT/src/luajit"
local f = io.open(luajit, "rb")
if not f then
    luajit = "luajit"
else
    f:close()
end

-- Test 1: CLI Help output
local p = io.popen(luajit .. " yt.lua --help", "r")
assert(p, "Failed to run yt.lua --help")
local help_out = p:read("*a")
p:close()
assert(help_out:find("yt.lua", 1, true), "Help output missing header")
assert(help_out:find("System Status:", 1, true), "Help output missing status")
print("  [✓] Test 1 passed: yt.lua --help renders properly.")

-- Test 2: Extraction & search via yt-dlp
local p_search = io.popen('yt-dlp --dump-json --flat-playlist --skip-download "ytsearch2:lofi" 2>/dev/null', "r")
if p_search then
    local count = 0
    for line in p_search:lines() do
        local id = line:match('"id"%s*:%s*"([^"]+)"')
        local title = line:match('"title"%s*:%s*"([^"]+)"')
        if id and title then
            count = count + 1
        end
    end
    p_search:close()
    if count >= 1 then
        print(string.format("  [✓] Test 2 passed: yt-dlp search query resolved %d items.", count))
    else
        print("  [!] Warning: Test 2 got 0 items (network may be restricted or slow).")
    end
end

-- Test 3: Non-interactive music search
local p_music = io.popen(luajit .. ' yt.lua --music --no-interactive --max-results 2 "synthwave"', "r")
assert(p_music, "Failed to run yt.lua in non-interactive music mode")
local music_out = p_music:read("*a")
p_music:close()
assert(music_out:find("MUSIC mode", 1, true), "Music mode header missing")
assert(music_out:find("01.", 1, true), "Music item 1 missing")
print("  [✓] Test 3 passed: yt.lua --music --no-interactive successfully extracted and listed items.")

-- Test 4: Non-interactive video search
local p_video = io.popen(luajit .. ' yt.lua --video --no-interactive --max-results 2 "space documentary"', "r")
assert(p_video, "Failed to run yt.lua in non-interactive video mode")
local video_out = p_video:read("*a")
p_video:close()
assert(video_out:find("VIDEO mode", 1, true), "Video mode header missing")
assert(video_out:find("01.", 1, true), "Video item 1 missing")
print("  [✓] Test 4 passed: yt.lua --video --no-interactive successfully extracted and listed items.")

print("=== All Backend Verification Tests Completed Successfully ===")
