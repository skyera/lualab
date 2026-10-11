#!/usr/bin/env luajit
-- =========================================================================
-- test_pix_web.lua
-- Comprehensive Test Suite for pix-web.lua
--
-- Tests:
-- 1. Module export sanity and extension tables
-- 2. MIME type resolution for images, videos, audio, and web assets
-- 3. Path sanitization and directory traversal guards
-- 4. LAN IP discovery
-- 5. Directory media scanning (types, sizes, extensions, animated flags)
-- 6. Live HTTP Endpoints (GET /, GET /api/status, GET /api/media, Range streaming)
-- 7. Undeclared globals assertion (0 unwhitelisted GGETs)
-- =========================================================================

local ffi = require("ffi")

local function run_test(name, fn)
    io.write(string.format("[TEST] %-55s ... ", name))
    io.flush()
    local ok, err = pcall(fn)
    if ok then
        io.write("\27[32mPASS\27[0m\n")
        return true
    else
        io.write("\27[31mFAIL\27[0m\n")
        io.stderr:write("  Error: " .. tostring(err) .. "\n")
        return false
    end
end

local passed = 0
local total = 0

local function check(cond, msg)
    if not cond then error(msg or "Assertion failed") end
end

local pix_web = require("pix-web")

-- Test 1: Module & Extension Exports
total = total + 1
if run_test("Module Export & Extension Tables", function()
    check(type(pix_web) == "table", "pix_web module is table")
    check(pix_web.IMAGE_EXTENSIONS.png == true, "png in image extensions")
    check(pix_web.IMAGE_EXTENSIONS.jpg == true, "jpg in image extensions")
    check(pix_web.IMAGE_EXTENSIONS.webp == true, "webp in image extensions")
    check(pix_web.VIDEO_EXTENSIONS.mp4 == true, "mp4 in video extensions")
    check(pix_web.VIDEO_EXTENSIONS.mkv == true, "mkv in video extensions")
    check(pix_web.AUDIO_EXTENSIONS.mp3 == true, "mp3 in audio extensions")
    check(pix_web.AUDIO_EXTENSIONS.flac == true, "flac in audio extensions")
end) then passed = passed + 1 end

-- Test 2: MIME Type Resolution
total = total + 1
if run_test("MIME Type Resolution", function()
    check(pix_web.get_mime_type("photo.png") == "image/png", "PNG mime")
    check(pix_web.get_mime_type("photo.jpg") == "image/jpeg", "JPG mime")
    check(pix_web.get_mime_type("video.mp4") == "video/mp4", "MP4 mime")
    check(pix_web.get_mime_type("song.mp3") == "audio/mpeg", "MP3 mime")
    check(pix_web.get_mime_type("track.flac") == "audio/flac", "FLAC mime")
    check(pix_web.get_mime_type("doc.xyz") == "application/octet-stream", "Unknown fallback")
end) then passed = passed + 1 end

-- Test 3: Path Sanitization & Traversal Prevention
total = total + 1
if run_test("Path Sanitization & Security Traversal Guard", function()
    check(pix_web.sanitize_subpath("normal/path") == "normal/path", "normal path")
    check(pix_web.sanitize_subpath("/abs/path") == "abs/path", "strip leading slash")
    check(pix_web.sanitize_subpath("../../../etc/passwd") == "etc/passwd", "traversal stripped")
    check(pix_web.sanitize_subpath("foo/../bar") == "bar", "dot-dot resolved")
    check(pix_web.sanitize_subpath("foo/./bar") == "foo/bar", "dot skipped")
end) then passed = passed + 1 end

-- Test 4: Local LAN IP Detection
total = total + 1
if run_test("Local LAN IP Detection", function()
    local ip = pix_web.get_local_lan_ip()
    check(type(ip) == "string" and #ip > 0, "IP is non-empty string")
    check(ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil, "Valid IPv4 format: " .. ip)
end) then passed = passed + 1 end

-- Test 5: Directory Media Scanning
total = total + 1
if run_test("Directory Media Scanning", function()
    -- Create temporary test folder with mock media files
    os.execute("mkdir -p _test_pix_web_dir/subdir")
    local f1 = io.open("_test_pix_web_dir/img1.png", "wb"); f1:write("FAKE_PNG"); f1:close()
    local f2 = io.open("_test_pix_web_dir/track1.mp3", "wb"); f2:write("FAKE_MP3"); f2:close()
    local f3 = io.open("_test_pix_web_dir/subdir/clip1.mp4", "wb"); f3:write("FAKE_MP4"); f3:close()
    local f4 = io.open("_test_pix_web_dir/ignore.txt", "wb"); f4:write("TXT"); f4:close()

    local entries, folders = pix_web.scan_media_dir("_test_pix_web_dir", "", false)
    check(#folders >= 1, "Discovered subdirectory")
    check(#entries >= 2, "Discovered root media entries")

    local found_png, found_mp3 = false, false
    for _, e in ipairs(entries) do
        if e.name == "img1.png" and e.type == "image" then found_png = true end
        if e.name == "track1.mp3" and e.type == "audio" then found_mp3 = true end
    end
    check(found_png, "Discovered PNG image")
    check(found_mp3, "Discovered MP3 audio")

    -- Clean up test folder
    os.execute("rm -rf _test_pix_web_dir")
end) then passed = passed + 1 end

-- Test 6: HTML Template Generation
total = total + 1
if run_test("HTML5 Template Generation", function()
    local html = pix_web.get_index_html("192.168.1.10", 8060, ".")
    check(type(html) == "string" and #html > 500, "HTML length check")
    check(html:find("PixWeb Media Gallery") ~= nil, "Page title check")
    check(html:find("lightbox%-modal") ~= nil, "Lightbox modal present")
    check(html:find("qr%-modal") ~= nil, "QR modal present")
end) then passed = passed + 1 end

-- Test 7: Scoping Assertion (Zero Undeclared Globals)
total = total + 1
if run_test("Bytecode Scoping (Zero Undeclared Globals)", function()
    local p = io.popen("luajit -bl pix-web.lua | grep GGET | awk '{print $NF}' | tr -d '\";' | sort -u", "r")
    check(p ~= nil, "popen bytecode dump")
    local whitelisted = {
        arg = true, debug = true, io = true, ipairs = true,
        math = true, next = true, os = true, package = true,
        pairs = true, pcall = true, print = true, require = true,
        string = true, table = true, tonumber = true, tostring = true,
        type = true
    }
    for line in p:lines() do
        local sym = line:gsub("%s+$", "")
        if #sym > 0 and not whitelisted[sym] then
            p:close()
            error("Undeclared global leaked: " .. sym)
        end
    end
    p:close()
end) then passed = passed + 1 end

-- Test 8: Live HTTP Server Smoke Test on Port 8069
total = total + 1
if run_test("Live HTTP Server Headless Integration (Port 8069)", function()
    -- Create test fixtures
    os.execute("mkdir -p _pix_live_test")
    local f = io.open("_pix_live_test/sample.jpg", "wb"); f:write("TEST_SAMPLE_JPEG_BYTES_12345"); f:close()

    local pid_p = io.popen("luajit pix-web.lua --port 8069 --dir _pix_live_test >/dev/null 2>&1 & echo $!", "r")
    local pid = pid_p:read("*l")
    pid_p:close()

    -- Allow server to bind
    os.execute("sleep 0.3")

    -- 1. Check HTTP Index
    local idx_res = io.popen("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8069/"):read("*l")
    check(idx_res == "200", "GET / returns 200 OK (got " .. tostring(idx_res) .. ")")

    -- 2. Check /api/status
    local st_json = io.popen("curl -s http://127.0.0.1:8069/api/status"):read("*a")
    check(st_json:find('"port":8069') ~= nil, "Status port matches 8069")

    -- 3. Check /api/media
    local media_json = io.popen("curl -s http://127.0.0.1:8069/api/media"):read("*a")
    check(media_json:find("sample.jpg") ~= nil, "Discovered sample.jpg in API response")

    -- 4. Check Partial Content Byte Range Streaming
    local range_res = io.popen("curl -s -i -r 0-9 http://127.0.0.1:8069/media/sample.jpg"):read("*a")
    check(range_res:find("HTTP/1.1 206 Partial Content", 1, true) ~= nil, "Range request returns 206 Partial Content")
    check(range_res:find("Content-Range: bytes 0-9/", 1, true) ~= nil, "Content-Range header present")

    -- Terminate test server and clean up
    if pid and tonumber(pid) then
        os.execute("kill -9 " .. pid .. " >/dev/null 2>&1")
    end
    os.execute("rm -rf _pix_live_test")
end) then passed = passed + 1 end

print(string.format("\n========================================================"))
print(string.format("PixWeb Test Summary: %d / %d tests passed (%.1f%%)", passed, total, (passed / total) * 100))
print(string.format("========================================================"))

if passed < total then
    os.exit(1)
end
