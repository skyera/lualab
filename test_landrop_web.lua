#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_landrop_web.lua
-- Unit & Integration Test Suite for LAN Drop & Clipboard Service
--------------------------------------------------------------------------------

local landrop = require("landrop_web")
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
-- 1. Filename Sanitization & Security Tests
-- =========================================================================
test("Filename sanitization strips paths and blocks traversal", function()
    assert(landrop.sanitize_filename("hello.txt") == "hello.txt")
    assert(landrop.sanitize_filename("../../etc/passwd") == "passwd")
    assert(landrop.sanitize_filename("subdir/image.png") == "image.png")
    assert(landrop.sanitize_filename("C:\\Windows\\System32\\cmd.exe") == "cmd.exe")
    assert(landrop.sanitize_filename("..") == nil)
    assert(landrop.sanitize_filename(".") == nil)
    assert(landrop.sanitize_filename("") == nil)
    assert(landrop.sanitize_filename(nil) == nil)
end)

-- =========================================================================
-- 2. Byte Formatting & MIME Types
-- =========================================================================
test("Byte formatting converts to human-readable units", function()
    assert(landrop.format_bytes(500) == "500 B")
    assert(landrop.format_bytes(1024) == "1.0 KB")
    assert(landrop.format_bytes(2048) == "2.0 KB")
    assert(landrop.format_bytes(1048576) == "1.0 MB")
    assert(landrop.format_bytes(5242880) == "5.0 MB")
    assert(landrop.format_bytes(1073741824) == "1.00 GB")
end)

test("MIME types resolve correctly for media, docs, and code", function()
    assert(landrop.get_mime_type("photo.png"):find("image/png", 1, true))
    assert(landrop.get_mime_type("pic.jpg"):find("image/jpeg", 1, true))
    assert(landrop.get_mime_type("doc.pdf"):find("application/pdf", 1, true))
    assert(landrop.get_mime_type("archive.zip"):find("application/zip", 1, true))
    assert(landrop.get_mime_type("script.lua"):find("text/plain", 1, true))
    assert(landrop.get_mime_type("unknown.xyz"):find("application/octet-stream", 1, true))
end)

-- =========================================================================
-- 3. Storage Unit Tests
-- =========================================================================
test("Storage manager saves, reads, lists, and deletes files safely", function()
    local test_dir = "./test_shared_tmp"
    local s = landrop.Storage.new(test_dir)

    -- Save file
    local ok, name = s:save_file("demo.txt", "Hello LAN Drop 12345")
    assert(ok and name == "demo.txt")

    -- Read file
    local content, rname = s:read_file("demo.txt")
    assert(content == "Hello LAN Drop 12345" and rname == "demo.txt")

    -- List files
    local list = s:list_files()
    assert(#list >= 1)
    local found = false
    for _, f in ipairs(list) do
        if f.name == "demo.txt" then
            found = true
            assert(f.size == 20)
            assert(f.is_text == true)
            assert(f.is_image == false)
        end
    end
    assert(found, "demo.txt not found in list")

    -- Path traversal in read/delete returns nil/false
    assert(s:read_file("../../../etc/passwd") == nil)
    assert(s:delete_file("../../../etc/passwd") == false or s:delete_file("..") == false)

    -- Delete file
    assert(s:delete_file("demo.txt") == true)
    assert(s:read_file("demo.txt") == nil)

    -- Cleanup temp directory
    os.remove(test_dir)
end)

-- =========================================================================
-- 4. Clipboard Store Tests
-- =========================================================================
test("Clipboard store captures clips, detects URLs, and bounds history", function()
    local c = landrop.ClipboardStore.new()
    assert(c:get_data().current == nil)
    assert(#c:get_data().history == 0)

    -- Add text clip
    local ok, item = c:set_text("Some useful bash command", "MacBook")
    assert(ok)
    assert(item.text == "Some useful bash command")
    assert(item.is_url == false)
    assert(c:get_data().current.text == "Some useful bash command")

    -- Add URL clip
    local ok2, item2 = c:set_text("https://github.com/skyera/lualab", "Phone")
    assert(ok2)
    assert(item2.is_url == true)
    assert(c:get_data().current.text == "https://github.com/skyera/lualab")
    assert(#c:get_data().history == 2)

    -- Clear
    c:clear()
    assert(c:get_data().current == nil)
    assert(#c:get_data().history == 0)
end)

-- =========================================================================
-- 5. LAN IP Detection Test
-- =========================================================================
test("Local LAN IP detection returns valid IPv4 address", function()
    local ip = landrop.get_local_lan_ip()
    assert(type(ip) == "string")
    assert(ip:match("^%d+%.%d+%.%d+%.%d+$"), "Invalid IP format: " .. tostring(ip))
end)

-- =========================================================================
-- 6. End-to-End Live HTTP Integration Test
-- =========================================================================
test("Live HTTP server serves UI, uploads, downloads, and syncs clipboard", function()
    local test_port = 8942
    local test_dir = "./test_shared_http"
    os.execute("rm -rf " .. test_dir .. " 2>/dev/null")

    -- Launch server in background
    local cmd = string.format("luajit landrop_web.lua --port %d --dir %s > /dev/null 2>&1 & echo $!", test_port, test_dir)
    local p = io.popen(cmd)
    local pid_str = p:read("*l")
    p:close()
    local pid = tonumber(pid_str)
    assert(pid and pid > 0, "Failed to start background test server")

    -- Give server time to bind and listen
    os.execute("sleep 0.3")

    local function cleanup()
        if pid then
            os.execute("kill " .. pid .. " 2>/dev/null")
        end
        os.execute("rm -rf " .. test_dir .. " 2>/dev/null")
    end

    local ok, err = pcall(function()
        -- 1. Check UI endpoint
        local p_ui = io.popen("curl -s http://127.0.0.1:" .. test_port .. "/")
        local ui_html = p_ui:read("*a")
        p_ui:close()
        assert(ui_html:find("LAN Drop"), "Expected 'LAN Drop' in HTML")

        -- 2. Check /api/status
        local p_st = io.popen("curl -s http://127.0.0.1:" .. test_port .. "/api/status")
        local st_raw = p_st:read("*a")
        p_st:close()
        local st = json.decode(st_raw)
        assert(st and st.port == test_port and st.version == "0.1.0")

        -- 3. Upload file
        local test_body = "Hello from automated test suite " .. os.time()
        local p_up = io.popen(string.format("curl -s -X POST --data-binary '%s' 'http://127.0.0.1:%d/api/upload?name=hello_test.txt'", test_body, test_port))
        local up_raw = p_up:read("*a")
        p_up:close()
        local up = json.decode(up_raw)
        assert(up and up.ok == true and up.file == "hello_test.txt")

        -- 4. List files
        local p_list = io.popen("curl -s http://127.0.0.1:" .. test_port .. "/api/files")
        local list_raw = p_list:read("*a")
        p_list:close()
        local files = json.decode(list_raw)
        assert(type(files) == "table" and #files == 1)
        assert(files[1].name == "hello_test.txt" and files[1].size == #test_body)

        -- 5. Download file and verify byte equality
        local p_dl = io.popen("curl -s http://127.0.0.1:" .. test_port .. "/download/hello_test.txt")
        local dl_body = p_dl:read("*a")
        p_dl:close()
        assert(dl_body == test_body, "Downloaded body does not match uploaded body")

        -- 6. Clipboard sync
        local clip_text = "https://example.org/lan-drop-link"
        local p_clip = io.popen(string.format("curl -s -X POST -H 'Content-Type: application/json' -d '{\"text\":\"%s\"}' http://127.0.0.1:%d/api/clipboard", clip_text, test_port))
        local clip_raw = p_clip:read("*a")
        p_clip:close()
        local clip_resp = json.decode(clip_raw)
        assert(clip_resp and clip_resp.ok == true)

        -- 7. Retrieve clipboard
        local p_get_clip = io.popen("curl -s http://127.0.0.1:" .. test_port .. "/api/clipboard")
        local get_clip_raw = p_get_clip:read("*a")
        p_get_clip:close()
        local clip_data = json.decode(get_clip_raw)
        assert(clip_data.current and clip_data.current.text == clip_text)

        -- 8. Delete file
        local p_del = io.popen("curl -s -X POST 'http://127.0.0.1:" .. test_port .. "/api/delete?name=hello_test.txt'")
        local del_raw = p_del:read("*a")
        p_del:close()
        local del_resp = json.decode(del_raw)
        assert(del_resp and del_resp.ok == true)
    end)

    cleanup()
    if not ok then error(err) end
end)

print(string.format("Passed all %d tests.", passed))
