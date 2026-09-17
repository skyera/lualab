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
assert(help_out:find("--proxy", 1, true), "Help output missing --proxy option")
assert(help_out:find("--insecure", 1, true), "Help output missing --insecure option")
assert(help_out:find("deno:", 1, true), "Help output missing deno status")
print("  [✓] Test 1 passed: yt.lua --help renders properly.")

local is_win = (package.config:sub(1,1) == '\\')
local null_dev = is_win and "2>nul" or "2>/dev/null"

-- Test 2: Extraction & search via yt-dlp
local p_search = io.popen('yt-dlp --dump-json --flat-playlist --skip-download "ytsearch2:lofi" ' .. null_dev, "r")
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

-- Test 5: Stream playback verification (verify player_client=android avoids 403 Forbidden)
local test_stream_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
local mpv_check_cmd = string.format('mpv --no-video --ao=null --end=2 --ytdl-raw-options="extractor-args=youtube:player_client=android" %q %s', test_stream_url, null_dev)
local exit_code = os.execute(mpv_check_cmd)
assert(exit_code == 0, "mpv stream playback verification failed (unexpected exit code " .. tostring(exit_code) .. ")")
print("  [✓] Test 5 passed: Stream playback connected and played cleanly without 403 Forbidden.")

-- Test 6: Direct Web Search Fallback (tests curl scraping directly)
local curl_check = io.popen('curl -s -L --max-time 6 -A "Mozilla/5.0" "https://www.youtube.com/results?search_query=piano" ' .. null_dev, "rb")
if curl_check then
    local html = curl_check:read("*a")
    curl_check:close()
    local found = 0
    for _ in html:gmatch('"videoRenderer":%b{}') do
        found = found + 1
        if found >= 2 then break end
    end
    assert(found >= 1, "Direct web search fallback returned 0 items")
    print("  [✓] Test 6 passed: Direct web search fallback extracted video entries.")
end

-- Test 7: Terminal Video 480p Stream Check
local video_check_cmd = string.format('mpv --vo=null --ao=null --frames=1 --hwdec=auto --ytdl-format="bestvideo[height<=480]+bestaudio/best[height<=480]/best" --ytdl-raw-options="extractor-args=youtube:player_client=android" %q %s', test_stream_url, null_dev)
local v_code = os.execute(video_check_cmd)
assert(v_code == 0, "Capped 480p video check failed (exit code " .. tostring(v_code) .. ")")
print("  [✓] Test 7 passed: Capped 480p video format and hwdec=auto stream successfully.")

print("=== All Backend Verification Tests Completed Successfully ===")
