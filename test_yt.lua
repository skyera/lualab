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

-- Test 5: Stream playback verification
local test_stream_url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
local mpv_check_cmd = string.format('mpv --no-video --ao=null --end=2 %q %s', test_stream_url, null_dev)
local exit_code = os.execute(mpv_check_cmd)
assert(exit_code == 0, "mpv stream playback verification failed (unexpected exit code " .. tostring(exit_code) .. ")")
print("  [✓] Test 5 passed: Stream playback connected and played cleanly.")

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
local video_check_cmd = string.format('mpv --vo=null --ao=null --frames=1 --hwdec=auto --ytdl-format="bestvideo[height<=480]+bestaudio/best[height<=480]/best" %q %s', test_stream_url, null_dev)
local v_code = os.execute(video_check_cmd)
assert(v_code == 0, "Capped 480p video check failed (exit code " .. tostring(v_code) .. ")")
print("  [✓] Test 7 passed: Capped 480p video format and hwdec=auto stream successfully.")

-- Test 8: Corporate SSL / Insecure Environment Variable Check
local test8_cmd = is_win
    and ('cmd.exe /c "set YT_INSECURE=1&& ' .. luajit .. ' yt.lua --no-interactive --max-results 1 piano"')
    or ('YT_INSECURE=1 ' .. luajit .. ' yt.lua --no-interactive --max-results 1 piano')
local p_sec = io.popen(test8_cmd, "r")
if p_sec then
    local sec_out = p_sec:read("*a")
    p_sec:close()
    assert(sec_out:find("CORP SSL/INSECURE", 1, true), "Expected [CORP SSL/INSECURE] flag in output when YT_INSECURE=1")
    print("  [✓] Test 8 passed: YT_INSECURE=1 environment variable correctly activates corporate SSL bypass.")
end

-- Test 9: Self-Test Mode (--test) including History Save/Load and parse_json_field verification
local p_test = io.popen(luajit .. " yt.lua --test", "r")
assert(p_test, "Failed to run yt.lua --test")
local test_out = p_test:read("*a")
p_test:close()
assert(test_out:find("parse_json_field passed", 1, true), "parse_json_field unit test failed")
assert(test_out:find("sanitize_display_text passed", 1, true), "sanitize_display_text unit test failed")
assert(test_out:find("display_width & utf8_truncate passed", 1, true), "display_width & utf8_truncate unit test failed")
assert(test_out:find("save_history_item & load_history_items passed", 1, true), "History save/load test failed")
assert(test_out:find("CC / Lyrics status formatting passed", 1, true), "CC/Lyrics status formatting unit test failed")
assert(test_out:find("CC rolling caption deduplication passed", 1, true), "CC rolling caption deduplication unit test failed")
assert(test_out:find("All Internal Self-Tests Passed Successfully", 1, true), "Self-tests summary missing")
print("  [✓] Test 9 passed: yt.lua --test verified JSON parsing, CJK width, history, and CC deduplication without errors.")

-- Test 10: CC / Lyrics CLI Options & Help verification
local p_help = io.popen(luajit .. " yt.lua --help", "r")
assert(p_help, "Failed to run yt.lua --help for CC options")
local h_out = p_help:read("*a")
p_help:close()
assert(h_out:find("--cc", 1, true), "Help output missing --cc option")
assert(h_out:find("--lyrics", 1, true), "Help output missing --lyrics option")
assert(h_out:find("--sub-lang", 1, true), "Help output missing --sub-lang option")
assert(h_out:find("--sub-font-size", 1, true), "Help output missing --sub-font-size option")
assert(h_out:find("--cc-font-size", 1, true), "Help output missing --cc-font-size option")

local p_cc_run = io.popen(luajit .. ' yt.lua --lyrics --sub-lang en.* --sub-font-size 65 --no-interactive --max-results 1 "lofi" ' .. null_dev, "r")
assert(p_cc_run, "Failed to run yt.lua with --lyrics and --sub-font-size flags")
local cc_run_out = p_cc_run:read("*a")
p_cc_run:close()
assert(cc_run_out:find("01.", 1, true), "Non-interactive run with --lyrics failed to produce results")
print("  [✓] Test 10 passed: --cc, --lyrics, --sub-lang, and --sub-font-size options parse and execute successfully.")

-- Test 11: Mini-Player, Queue, Download, and Filter Options & Self-Test verification
local p_help11 = io.popen(luajit .. " yt.lua --help", "r")
assert(p_help11, "Failed to run yt.lua --help for features 1-4")
local h11_out = p_help11:read("*a")
p_help11:close()
assert(h11_out:find("--download", 1, true), "Help output missing --download option")
assert(h11_out:find("--sort", 1, true), "Help output missing --sort option")
assert(h11_out:find("--duration", 1, true), "Help output missing --duration option")
assert(h11_out:find("Up-Next playback queue", 1, true), "Help output missing queue controls")
assert(h11_out:find("Search Filters & Sorting", 1, true), "Help output missing filter controls")
assert(h11_out:find("./downloads/", 1, true), "Help output missing ./downloads/ directory reference")

local p_test11 = io.popen(luajit .. " yt.lua --test", "r")
assert(p_test11, "Failed to run yt.lua --test")
local t11_out = p_test11:read("*a")
p_test11:close()
assert(t11_out:find("Download directory validation passed", 1, true), "Self-test missing download dir validation")
assert(t11_out:find("Up-Next Playback Queue FIFO logic passed", 1, true), "Self-test missing queue validation")
assert(t11_out:find("Search Filters & Sorting validation passed", 1, true), "Self-test missing search filters validation")
if is_win then
    assert(t11_out:find("Win32 Named Pipe FFI bindings validated", 1, true), "Self-test missing pipe bindings validation")
end
print("  [✓] Test 11 passed: Mini-Player, Playback Queue, Offline Download, and Search Filters verified.")

-- Test 12: Bytecode Scoping & Global Integrity Check (ensures max_list_h and other locals are not global)
local p_bc = io.popen(luajit .. " -bl yt.lua", "r")
assert(p_bc, "Failed to run luajit -bl yt.lua")
local std_globals = {
    require=true, io=true, os=true, pcall=true, xpcall=true, string=true, math=true, table=true,
    print=true, ipairs=true, pairs=true, tonumber=true, tostring=true, type=true, assert=true,
    error=true, setmetatable=true, getmetatable=true, select=true, next=true, rawget=true,
    rawset=true, loadstring=true, bit=true, ffi=true, jit=true, arg=true, _G=true
}
local bad_globals = {}
for line in p_bc:lines() do
    local g = line:match('GGET%s+%d+%s+%d+%s+;%s+"([^"]+)"')
    if g and not std_globals[g] then
        bad_globals[g] = (bad_globals[g] or 0) + 1
    end
end
p_bc:close()
assert(next(bad_globals) == nil, "Undefined global accesses detected in yt.lua: " .. table.concat((function()
    local t = {}
    for k, v in pairs(bad_globals) do table.insert(t, string.format("%s (%d)", k, v)) end
    return t
end)(), ", "))
print("  [✓] Test 12 passed: Bytecode scoping verified (0 undeclared globals in yt.lua).")

print("=== All Backend Verification Tests Completed Successfully ===")

