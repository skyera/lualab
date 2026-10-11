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
-- 6. HTML Template Generation
-- 7. Adaptive Startup Banner & Mojibake Prevention (UTF-8 & ASCII)
-- 8. Bytecode Scoping Assertion (Zero Undeclared Globals)
-- 9. Live HTTP Server Headless Integration (Port 8079)
-- =========================================================================

local ffi = require("ffi")
local is_windows = (ffi.os == "Windows")

if is_windows then
    pcall(function()
        ffi.cdef[[void Sleep(uint32_t);]]
    end)
else
    pcall(function()
        ffi.cdef[[int usleep(unsigned int);]]
    end)
end

local function portable_sleep(ms)
    if is_windows then
        pcall(function() ffi.C.Sleep(ms) end)
    else
        pcall(function() ffi.C.usleep(ms * 1000) end)
    end
end

local function make_dir(path)
    if is_windows then
        local win_path = path:gsub("/", "\\")
        os.execute(string.format('if not exist "%s" mkdir "%s" >nul 2>nul', win_path, win_path))
    else
        os.execute("mkdir -p " .. path .. " 2>/dev/null")
    end
end

local function remove_tree(path)
    if is_windows then
        local win_path = path:gsub("/", "\\")
        os.execute(string.format('if exist "%s" rmdir /s /q "%s" >nul 2>nul', win_path, win_path))
    else
        os.execute("rm -rf " .. path .. " 2>/dev/null")
    end
end

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
    local test_dir = "_test_pix_web_dir"
    remove_tree(test_dir)
    make_dir(test_dir)
    make_dir(test_dir .. "/subdir")

    local f1 = io.open(test_dir .. "/img1.png", "wb"); check(f1, "open img1.png"); f1:write("FAKE_PNG"); f1:close()
    local f2 = io.open(test_dir .. "/track1.mp3", "wb"); check(f2, "open track1.mp3"); f2:write("FAKE_MP3"); f2:close()
    local f3 = io.open(test_dir .. "/subdir/clip1.mp4", "wb"); check(f3, "open clip1.mp4"); f3:write("FAKE_MP4"); f3:close()
    local f4 = io.open(test_dir .. "/ignore.txt", "wb"); check(f4, "open ignore.txt"); f4:write("TXT"); f4:close()

    local entries, folders = pix_web.scan_media_dir(test_dir, "", false)
    check(#folders >= 1, "Discovered subdirectory")
    check(#entries >= 2, "Discovered root media entries")

    local found_png, found_mp3 = false, false
    for _, e in ipairs(entries) do
        if e.name == "img1.png" and e.type == "image" then found_png = true end
        if e.name == "track1.mp3" and e.type == "audio" then found_mp3 = true end
    end
    check(found_png, "Discovered PNG image")
    check(found_mp3, "Discovered MP3 audio")

    remove_tree(test_dir)
end) then passed = passed + 1 end

-- Test 6: HTML Template Generation
total = total + 1
if run_test("HTML5 Template Generation", function()
    local html = pix_web.get_index_html("192.168.1.10", 8060, ".")
    check(type(html) == "string" and #html > 500, "HTML length check")
    check(html:find("PixWeb Media Gallery") ~= nil, "Page title check")
    check(html:find("lightbox%-modal") ~= nil, "Lightbox modal present")
    check(html:find("qr%-modal") ~= nil, "QR modal present")
    check(html:find("thumb%-media") ~= nil, "Video thumbnail element present")
    check(html:find("video%-play%-indicator") ~= nil, "Video play indicator present")
    check(html:find("previewVideo") ~= nil, "Video hover preview handler present")
    check(html:find("list%-thumb") ~= nil, "List view thumbnail present")
end) then passed = passed + 1 end

-- Test 7: Adaptive Banner & Mojibake Prevention
total = total + 1
if run_test("Adaptive Banner & Mojibake Prevention (UTF-8 & ASCII)", function()
    check(type(pix_web.render_banner) == "function", "render_banner is exported")

    -- 1. Test UTF-8 mode
    local u_banner = pix_web.render_banner(8060, "192.168.1.108", ".", true)
    local u_lines = {}
    for line in u_banner:gmatch("[^\r\n]+") do table.insert(u_lines, line) end
    check(#u_lines == 9, "UTF-8 banner has 9 rows")
    for idx, line in ipairs(u_lines) do
        local visual_len = #line:gsub("[\128-\191]", "")
        check(visual_len == 77, string.format("UTF-8 banner row %d visual length is 77 (got %d)", idx, visual_len))
    end
    check(u_banner:find("╔") ~= nil, "Contains double top-left corner")
    check(u_banner:find("║") ~= nil, "Contains double vertical bar")
    check(u_banner:find("•") ~= nil, "Contains bullet glyph")

    -- 2. Test ASCII fallback mode
    local a_banner = pix_web.render_banner(8060, "192.168.1.108", ".", false)
    local a_lines = {}
    for line in a_banner:gmatch("[^\r\n]+") do table.insert(a_lines, line) end
    check(#a_lines == 9, "ASCII banner has 9 rows")
    for idx, line in ipairs(a_lines) do
        check(#line == 77, string.format("ASCII banner row %d length is 77 (got %d)", idx, #line))
    end
    check(a_banner:find("+") ~= nil, "Contains + corners")
    check(a_banner:find("|") ~= nil, "Contains | borders")
    check(a_banner:find("*") ~= nil, "Contains * bullet")
    -- Ensure 0 non-ASCII bytes in fallback
    for i = 1, #a_banner do
        local byte = a_banner:byte(i)
        check(byte < 128, "No non-ASCII bytes in fallback mode")
    end
end) then passed = passed + 1 end

-- Test 8: Scoping Assertion (Zero Undeclared Globals)
total = total + 1
if run_test("Bytecode Scoping (Zero Undeclared Globals)", function()
    local p = io.popen("luajit -bl pix-web.lua", "r")
    check(p ~= nil, "popen luajit -bl pix-web.lua")
    local whitelisted = {
        arg = true, debug = true, io = true, ipairs = true,
        math = true, next = true, os = true, package = true,
        pairs = true, pcall = true, print = true, require = true,
        string = true, table = true, tonumber = true, tostring = true,
        type = true
    }
    local leaked = {}
    for line in p:lines() do
        if line:find("GGET") then
            local sym = line:match(';%s*"([^"]+)"')
            if sym and not whitelisted[sym] then
                leaked[sym] = true
            end
        end
    end
    p:close()
    local leak_list = {}
    for sym in pairs(leaked) do table.insert(leak_list, sym) end
    check(#leak_list == 0, "Undeclared globals leaked: " .. table.concat(leak_list, ", "))
end) then passed = passed + 1 end

-- Test 9: Live HTTP Server Smoke Test on Port 8079
total = total + 1
if run_test("Live HTTP Server Headless Integration (Port 8079)", function()
    local test_dir = "_pix_live_test"
    local test_port = 8079
    remove_tree(test_dir)
    make_dir(test_dir)

    local f = io.open(test_dir .. "/sample.jpg", "wb"); check(f, "open sample.jpg"); f:write("TEST_SAMPLE_JPEG_BYTES_12345"); f:close()

    local pid = nil
    if is_windows then
        os.execute(string.format('start /B luajit pix-web.lua --port %d --dir %s >nul 2>nul', test_port, test_dir))
    else
        local pid_p = io.popen(string.format("luajit pix-web.lua --port %d --dir %s >/dev/null 2>&1 & echo $!", test_port, test_dir), "r")
        pid = pid_p:read("*l")
        pid_p:close()
    end

    -- Allow server to bind
    portable_sleep(350)

    local function cleanup_server()
        if is_windows then
            os.execute(string.format('for /f "tokens=5" %%a in (\'netstat -aon ^| findstr :%d\') do @taskkill /F /PID %%a >nul 2>nul', test_port))
        else
            if pid and tonumber(pid) then
                os.execute("kill -9 " .. pid .. " >/dev/null 2>&1")
            end
        end
        remove_tree(test_dir)
    end

    local ok, err = pcall(function()
        -- 1. Check HTTP Index
        local p_idx = io.popen(string.format("curl -s -o /dev/null -w \"%%{http_code}\" http://127.0.0.1:%d/", test_port), "r")
        local idx_res = p_idx:read("*l")
        p_idx:close()
        check(idx_res == "200", "GET / returns 200 OK (got " .. tostring(idx_res) .. ")")

        -- 2. Check /api/status
        local p_st = io.popen(string.format("curl -s http://127.0.0.1:%d/api/status", test_port), "r")
        local st_json = p_st:read("*a")
        p_st:close()
        check(st_json:find(string.format('"port":%d', test_port)) ~= nil, "Status port matches " .. test_port)

        -- 3. Check /api/media
        local p_media = io.popen(string.format("curl -s http://127.0.0.1:%d/api/media", test_port), "r")
        local media_json = p_media:read("*a")
        p_media:close()
        check(media_json:find("sample.jpg") ~= nil, "Discovered sample.jpg in API response")

        -- 4. Check Partial Content Byte Range Streaming
        local p_range = io.popen(string.format("curl -s -i -r 0-9 http://127.0.0.1:%d/media/sample.jpg", test_port), "r")
        local range_res = p_range:read("*a")
        p_range:close()
        check(range_res:find("HTTP/1.1 206 Partial Content", 1, true) ~= nil, "Range request returns 206 Partial Content")
        check(range_res:find("Content-Range: bytes 0-9/", 1, true) ~= nil, "Content-Range header present")
    end)

    cleanup_server()
    if not ok then error(err) end
end) then passed = passed + 1 end

-- Test 10: Unicode & Suffix Range Media Streaming (Live Integration)
total = total + 1
if run_test("Unicode & Suffix Range Media Streaming (Port 8078)", function()
    local test_dir = "_pix_unicode_test"
    local test_port = 8078
    remove_tree(test_dir)
    make_dir(test_dir)

    -- Create a Unicode video file using open_media_file
    local test_content = "0123456789ABCDEF_VIDEO_BYTES_9999"
    local f_uni = pix_web.open_media_file(test_dir .. "/测试视频.mp4", "wb")
    check(f_uni ~= nil, "Create Unicode named MP4 file")
    f_uni:write(test_content)
    f_uni:close()

    -- Verify open_media_file read & seek
    local f_read = pix_web.open_media_file(test_dir .. "/测试视频.mp4", "rb")
    check(f_read ~= nil, "open_media_file read Unicode MP4")
    local sz = f_read:seek("end")
    check(sz == #test_content, "Unicode MP4 file size matches: " .. tostring(sz))
    f_read:seek("set", 0)
    local prefix = f_read:read(10)
    check(prefix == "0123456789", "Prefix matches: " .. tostring(prefix))
    f_read:close()

    -- Start server
    local pid = nil
    if is_windows then
        os.execute(string.format('start /B luajit pix-web.lua --port %d --dir %s >nul 2>nul', test_port, test_dir))
    else
        local pid_p = io.popen(string.format("luajit pix-web.lua --port %d --dir %s >/dev/null 2>&1 & echo $!", test_port, test_dir), "r")
        pid = pid_p:read("*l")
        pid_p:close()
    end
    portable_sleep(350)

    local function cleanup_uni()
        if is_windows then
            os.execute(string.format('for /f "tokens=5" %%a in (\'netstat -aon ^| findstr :%d\') do @taskkill /F /PID %%a >nul 2>nul', test_port))
        else
            if pid and tonumber(pid) then os.execute("kill -9 " .. pid .. " >/dev/null 2>&1") end
        end
        remove_tree(test_dir)
    end

    local ok, err = pcall(function()
        -- 1. Verify /api/media discovers the Unicode MP4
        local p_media = io.popen(string.format("curl -s http://127.0.0.1:%d/api/media", test_port), "r")
        local media_json = p_media:read("*a")
        p_media:close()
        check(media_json:find("测试视频.mp4") ~= nil, "API discovers Unicode MP4")

        -- 2. Range request on Unicode filename: bytes=0-9
        local url_enc = "http://127.0.0.1:" .. test_port .. "/media/%E6%B5%8B%E8%AF%95%E8%A7%86%E9%A2%91.mp4"
        local p_range = io.popen("curl -s -i -r 0-9 " .. url_enc, "r")
        local range_res = p_range:read("*a")
        p_range:close()
        check(range_res:find("HTTP/1.1 206 Partial Content", 1, true) ~= nil, "Unicode stream returns 206")
        check(range_res:find("Content-Range: bytes 0-9/" .. #test_content, 1, true) ~= nil, "Content-Range matches 0-9")

        -- 3. Suffix Range request: bytes=-4 (last 4 bytes: '9999')
        local p_suffix = io.popen("curl -s -i -H \"Range: bytes=-4\" " .. url_enc, "r")
        local suffix_res = p_suffix:read("*a")
        p_suffix:close()
        check(suffix_res:find("HTTP/1.1 206 Partial Content", 1, true) ~= nil, "Suffix range returns 206")
        local exp_cr = string.format("Content-Range: bytes %d-%d/%d", #test_content - 4, #test_content - 1, #test_content)
        check(suffix_res:find(exp_cr, 1, true) ~= nil, "Content-Range matches suffix range: " .. exp_cr)
        check(suffix_res:find("9999", 1, true) ~= nil, "Suffix payload contains trailing bytes '9999'")

        -- 4. Open-ended range request on Unicode media: bytes=10-
        local p_open = io.popen("curl -s -i -H \"Range: bytes=10-\" " .. url_enc, "r")
        local open_res = p_open:read("*a")
        p_open:close()
        check(open_res:find("HTTP/1.1 206 Partial Content", 1, true) ~= nil, "Open-ended range returns 206")
        local exp_open_cr = string.format("Content-Range: bytes 10-%d/%d", #test_content - 1, #test_content)
        check(open_res:find(exp_open_cr, 1, true) ~= nil, "Content-Range matches open-ended: " .. exp_open_cr)

        -- 5. Test 2.5MB media file slice capping
        local f_large = io.open(test_dir .. "/large_test.mp4", "wb")
        local chunk_1m = string.rep("A", 1024 * 1024)
        f_large:write(chunk_1m)
        f_large:write(chunk_1m)
        f_large:write(string.rep("B", 512 * 1024))
        f_large:close()
        local large_total = math.floor(2.5 * 1024 * 1024)

        local p_slice = io.popen(string.format("curl -s -i -H \"Range: bytes=0-\" http://127.0.0.1:%d/media/large_test.mp4", test_port), "r")
        local slice_res = p_slice:read("*a")
        p_slice:close()
        check(slice_res:find("HTTP/1.1 206 Partial Content", 1, true) ~= nil, "Large media open range returns 206")
        check(slice_res:find("Content-Length: 2097152", 1, true) ~= nil, "Large media capped at 2MB (2097152 bytes)")
        check(slice_res:find("Content-Range: bytes 0-2097151/" .. tostring(large_total), 1, true) ~= nil, "Content-Range specifies 2MB slice")

        -- 6. Verify download endpoint is NOT capped
        local p_dl = io.popen(string.format("curl -s -I http://127.0.0.1:%d/download/large_test.mp4", test_port), "r")
        local dl_headers = p_dl:read("*a")
        p_dl:close()
        check(dl_headers:find("Content-Length: " .. tostring(large_total), 1, true) ~= nil, "Download preserves full content length")

        -- 7. Rapid scrub / seek test across arbitrary offsets
        local seek_offsets = { 0, 524288, 1048576, 1572864, 2097152 }
        for _, offset in ipairs(seek_offsets) do
            local p_seek = io.popen(string.format("curl -s -i -H \"Range: bytes=%d-\" http://127.0.0.1:%d/media/large_test.mp4", offset, test_port), "r")
            local seek_res = p_seek:read("*a")
            p_seek:close()
            check(seek_res:find("HTTP/1.1 206 Partial Content", 1, true) ~= nil, "Scrub to offset " .. offset .. " returns 206")
            local exp_slice_end = math.min(offset + 2 * 1024 * 1024 - 1, large_total - 1)
            local exp_cr_seek = string.format("Content-Range: bytes %d-%d/%d", offset, exp_slice_end, large_total)
            check(seek_res:find(exp_cr_seek, 1, true) ~= nil, "Content-Range matches scrub position: " .. exp_cr_seek)
        end
    end)

    cleanup_uni()
    if not ok then error(err) end
end) then passed = passed + 1 end

print(string.format("\n========================================================"))
print(string.format("PixWeb Test Summary: %d / %d tests passed (%.1f%%)", passed, total, (passed / total) * 100))
print(string.format("========================================================"))

if passed < total then
    os.exit(1)
end
