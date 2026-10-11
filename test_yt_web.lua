#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_yt_web.lua
-- Unit & Integration Test Suite for YouTube Web Server (yt-web.lua)
--------------------------------------------------------------------------------

local ytweb = dofile("yt-web.lua")
local json = require("json")

local passed = 0
local total = 0

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok " .. total .. " - " .. name)
    else
        io.stderr:write("not ok " .. total .. " - " .. name .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

-- =========================================================================
-- 1. Parameter Parsing & Utility Tests
-- =========================================================================
test("Query parameter parser decodes URL components and handles empty values", function()
    local params = ytweb.parse_query_params("/api/search?q=bohemian+rhapsody&mode=music&dur=short")
    assert(params.q == "bohemian rhapsody", "Expected decoded query")
    assert(params.mode == "music")
    assert(params.dur == "short")

    local empty_params = ytweb.parse_query_params("/api/status")
    assert(next(empty_params) == nil)

    local encoded = ytweb.parse_query_params("/test?title=Rock%20%26%20Roll")
    assert(encoded.title == "Rock & Roll")
end)

test("Duration and byte formatting produce clean human-readable strings", function()
    assert(ytweb.format_duration(45) == "00:45")
    assert(ytweb.format_duration(214) == "03:34")
    assert(ytweb.format_duration(3665) == "1:01:05")
    assert(ytweb.format_duration(0) == "--:--")

    assert(ytweb.format_bytes(512) == "512 B")
    assert(ytweb.format_bytes(2048) == "2.0 KB")
    assert(ytweb.format_bytes(5242880) == "5.0 MB")
end)

test("Unicode unescape and display text sanitization cleanse entities and formatting", function()
    local raw = "Guns N\\u2019 Roses - Sweet Child O\\u2019 Mine &amp; Friends"
    local clean = ytweb.sanitize_display_text(ytweb.unescape_unicode(raw))
    assert(clean:find("Guns N’ Roses", 1, true), "Expected unicode apostrophe decoded")
    assert(clean:find("& Friends", 1, true), "Expected &amp; entity decoded")

    assert(ytweb.sanitize_filename("valid_track.mp3") == "valid_track.mp3")
    assert(ytweb.sanitize_filename("../../etc/passwd") == "passwd")
    assert(ytweb.sanitize_filename("..") == nil)
end)

-- =========================================================================
-- 2. Search Specification Builder Tests
-- =========================================================================
test("Search spec builder routes correctly for YouTube, SoundCloud, Twitch, and direct URLs", function()
    local yt_spec = ytweb.build_search_spec("queen", "music", 20, nil, "youtube")
    assert(yt_spec == '"ytsearch20:queen"')

    local sc_spec = ytweb.build_search_spec("ambient beats", "music", 15, nil, "soundcloud")
    assert(sc_spec == '"scsearch15:ambient beats"')

    local tw_spec = ytweb.build_search_spec("chess stream", "video", 10, nil, "twitch")
    assert(tw_spec == '"twsearch10:chess stream"')

    local url_spec = ytweb.build_search_spec("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "music", 20, nil, "youtube")
    assert(url_spec:find("dQw4w9WgXcQ"))

    local sort_spec = ytweb.build_search_spec("veritasium", "video", 20, { sort = "date" }, "youtube")
    assert(sort_spec:find("sp=CAI%253D", 1, true))
end)

-- =========================================================================
-- 3. JSON Field Parsing Tests
-- =========================================================================
test("parse_json_field extracts fields robustly from yt-dlp dump-json lines", function()
    local sample_json = '{"id": "dQw4w9WgXcQ", "title": "Never Gonna Give You Up", "duration": 214, "uploader": "Rick Astley"}'
    assert(ytweb.parse_json_field(sample_json, "id") == "dQw4w9WgXcQ")
    assert(ytweb.parse_json_field(sample_json, "title") == "Never Gonna Give You Up")
    assert(ytweb.parse_json_field(sample_json, "duration") == 214)
    assert(ytweb.parse_json_field(sample_json, "uploader") == "Rick Astley")
end)

-- =========================================================================
-- 4. LAN IP Detection Test
-- =========================================================================
test("Local LAN IP detection returns valid IPv4 format", function()
    local ip = ytweb.get_local_lan_ip()
    assert(type(ip) == "string")
    assert(ip:match("^%d+%.%d+%.%d+%.%d+$"), "Invalid IP format: " .. tostring(ip))
end)

-- =========================================================================
-- 5. Direct Web Scrape Fallback Test
-- =========================================================================
test("Direct curl web scraper extracts videos without yt-dlp", function()
    local items = ytweb.scrape_youtube_search("rick astley", 5, nil, false)
    assert(type(items) == "table" and #items > 0, "Expected search results from web scraper")
    local first = items[1]
    assert(first.id and #first.id > 0)
    assert(first.title and #first.title > 0)
    assert(first.url:find("youtube.com/watch?v=", 1, true))
end)

-- =========================================================================
-- 6. Live HTTP Server Integration Tests
-- =========================================================================
test("Live HTTP server responds to UI, status, search, stream, and download APIs", function()
    local test_port = 8955
    local test_dir = "./test_yt_downloads"
    os.execute("rm -rf " .. test_dir .. " 2>/dev/null")

    local cmd = string.format("luajit yt-web.lua --port %d --dir %s > /dev/null 2>&1 & echo $!", test_port, test_dir)
    local p = io.popen(cmd)
    local pid_str = p:read("*l")
    p:close()
    local pid = tonumber(pid_str)
    assert(pid and pid > 0, "Failed to start background test server")

    -- Allow server socket to bind
    os.execute("sleep 0.3")

    local function cleanup()
        if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
        os.execute("rm -rf " .. test_dir .. " 2>/dev/null")
    end

    local ok, err = pcall(function()
        -- 1. Check Root UI Endpoint
        local p_ui = io.popen("curl -s http://127.0.0.1:" .. test_port .. "/")
        local ui_html = p_ui:read("*a")
        p_ui:close()
        assert(ui_html:find("YouTube Web", 1, true), "Expected 'YouTube Web' in HTML")
        assert(ui_html:find("qr-modal", 1, true), "Expected 'qr-modal' in HTML")
        assert(ui_html:find("bottom-player", 1, true), "Expected 'bottom-player' in HTML")

        -- 2. Check /api/status Endpoint
        local p_st = io.popen("curl -s http://127.0.0.1:" .. test_port .. "/api/status")
        local st_raw = p_st:read("*a")
        p_st:close()
        local st = json.decode(st_raw)
        assert(st and st.ok == true)
        assert(st.port == test_port)
        assert(st.version == "0.1.0")
        assert(type(st.lan_ip) == "string")

        -- 3. Check /api/search Endpoint
        local p_sr = io.popen("curl -s 'http://127.0.0.1:" .. test_port .. "/api/search?q=rick+astley&site=youtube'")
        local sr_raw = p_sr:read("*a")
        p_sr:close()
        local results = json.decode(sr_raw)
        assert(type(results) == "table" and #results > 0, "Expected search results array")
        assert(results[1].id and results[1].title)

        -- 4. Check /api/stream Endpoint
        local target_id = results[1].id
        local p_stream = io.popen(string.format("curl -s 'http://127.0.0.1:%d/api/stream?id=%s&mode=music'", test_port, target_id))
        local stream_raw = p_stream:read("*a")
        p_stream:close()
        local s_data = json.decode(stream_raw)
        assert(s_data and s_data.ok == true)
        assert(s_data.stream_url or s_data.embed_url, "Expected stream_url or embed_url")

        -- 5. Check /api/download Endpoint
        local p_dl = io.popen(string.format("curl -s 'http://127.0.0.1:%d/api/download?id=%s&mode=music'", test_port, target_id))
        local dl_raw = p_dl:read("*a")
        p_dl:close()
        local dl_resp = json.decode(dl_raw)
        assert(dl_resp and dl_resp.ok == true)
    end)

    cleanup()
    if not ok then error(err) end
end)

print(string.format("Passed all %d tests.", passed))
