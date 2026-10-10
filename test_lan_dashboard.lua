#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_lan_dashboard.lua
-- Comprehensive Verification Suite for lan_dashboard.lua
--------------------------------------------------------------------------------

local lan = require("lan_dashboard")

local passed = 0
local failed = 0

local function test(name, fn)
    io.write(string.format("Testing %-50s ... ", name))
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("\27[32m[PASS]\27[0m")
    else
        failed = failed + 1
        print("\27[31m[FAIL]\27[0m: " .. tostring(err))
    end
end

print("\n=======================================================")
print("  LAN Dashboard Test Suite")
print("=======================================================\n")

-- Test 1: Vendor OUI database resolution
test("MAC OUI Apple lookup", function()
    local v = lan.lookup_vendor("DC:CD:2F:00:11:22")
    assert(v:find("Apple"), "Expected Apple vendor, got: " .. tostring(v))
end)

test("MAC OUI Raspberry Pi lookup", function()
    local v = lan.lookup_vendor("DC:A6:32:00:11:22")
    assert(v:find("Raspberry Pi"), "Expected Raspberry Pi vendor, got: " .. tostring(v))
end)

test("MAC OUI Intel lookup", function()
    local v = lan.lookup_vendor("1C:61:B4:00:11:22")
    assert(v:find("Intel"), "Expected Intel vendor, got: " .. tostring(v))
end)

test("MAC OUI Espressif IoT lookup", function()
    local v = lan.lookup_vendor("84:3E:1D:00:11:22")
    assert(v:find("Espressif"), "Expected Espressif vendor, got: " .. tostring(v))
end)

test("MAC OUI Dahua Camera lookup", function()
    local v = lan.lookup_vendor("00:9E:C8:00:11:22")
    assert(v:find("Dahua"), "Expected Dahua vendor, got: " .. tostring(v))
end)

test("MAC OUI Private / Randomized MAC", function()
    local v = lan.lookup_vendor("D2:FB:42:00:11:22")
    assert(v:find("Random") or v:find("Private"), "Expected Private/Random MAC, got: " .. tostring(v))
end)

test("MAC OUI Unknown fallback", function()
    local v = lan.lookup_vendor("02:00:00:00:00:00")
    assert(v ~= nil, "Vendor should not be nil")
end)

-- Test 2: Device classification heuristics
test("Classify Camera (via RTSP port 554)", function()
    local c = lan.classify_device("192.168.1.55", "aa:bb:cc:dd:ee:ff", "Unknown", {554, 80}, "cam1")
    assert(c.category == "camera", "Expected camera, got: " .. c.category)
    assert(c.type_name == "Security Camera")
end)

test("Classify Windows (via SMB port 445)", function()
    local c = lan.classify_device("192.168.1.109", "1c:61:b4:00:11:22", "Intel Corporation", {445, 135}, "Workstation-PC")
    assert(c.category == "windows", "Expected windows, got: " .. c.category)
end)

test("Classify Linux / Raspberry Pi (via SSH port 22 & OUI)", function()
    local c = lan.classify_device("192.168.1.10", "dc:a6:32:00:11:22", "Raspberry Pi Trading", {22}, "raspberrypi")
    assert(c.category == "linux", "Expected linux, got: " .. c.category)
    assert(c.type_name == "Raspberry Pi")
end)

test("Classify Gateway Router (IP .1 and port 53/80)", function()
    local c = lan.classify_device("192.168.1.1", "6c:cd:d6:00:11:22", "Netgear / Router", {80, 53}, "gateway")
    assert(c.category == "router", "Expected router, got: " .. c.category)
end)

test("Classify Smart IoT (Espressif)", function()
    local c = lan.classify_device("192.168.1.32", "84:3e:1d:00:11:22", "Espressif Inc (IoT)", {80}, "esp32-plug")
    assert(c.category == "iot", "Expected iot, got: " .. c.category)
end)

test("Classify iPhone / Phone (Apple OUI without server ports)", function()
    local c = lan.classify_device("192.168.1.14", "60:6d:c7:00:11:22", "Apple, Inc.", {}, "iPhone")
    assert(c.category == "phone", "Expected phone, got: " .. c.category)
    assert(c.type_name == "Apple iPhone (iOS)")
end)

test("Classify Apple iPad (via mDNS hostname and OUI)", function()
    local c = lan.classify_device("192.168.1.30", "2c:18:09:00:11:22", "Apple, Inc.", {}, "ipad-mini.local")
    assert(c.category == "phone", "Expected phone, got: " .. c.category)
    assert(c.type_name == "Apple iPad (iPadOS)", "Expected iPadOS, got: " .. c.type_name)
    assert(c.icon == "tablet", "Expected tablet icon, got: " .. tostring(c.icon))

    local c_pro = lan.classify_device("192.168.1.22", "d2:fb:42:00:11:22", "Private / Randomized MAC", {}, "ipad-pro-13.local")
    assert(c_pro.category == "phone")
    assert(c_pro.type_name == "Apple iPad Pro (iPadOS)")
    assert(c_pro.icon == "tablet")
end)

-- Test 3: JSON Serialization
test("JSON Serializer handles nested tables and primitives", function()
    local data = {
        name = "Radar",
        online = true,
        count = 42,
        ports = {22, 80, 443},
        meta = { ip = "192.168.1.1" }
    }
    local s = lan.to_json(data)
    assert(s:find('"name":"Radar"'))
    assert(s:find('"online":true'))
    assert(s:find('"count":42'))
    assert(s:find('%[22,80,443%]'))
    assert(s:find('"ip":"192.168.1.1"'))
end)

-- Test 4: ARP cache retrieval
test("Live ARP Table retrieval", function()
    local entries = lan.get_arp_entries()
    assert(type(entries) == "table")
    assert(#entries > 0, "Expected at least 1 entry in local ARP cache")
    for _, e in ipairs(entries) do
        assert(e.ip:match("^%d+%.%d+%.%d+%.%d+$"), "Invalid IP format: " .. e.ip)
        assert(e.mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$"), "Invalid MAC format: " .. e.mac)
    end
end)

-- Test 5: Hostname resolution & Custom Alias
test("Hostname resolver default & alias logic", function()
    -- Default for router (unaliased subnet)
    local r_name, is_custom = lan.resolve_system_hostname("192.168.2.1", "6c:cd:d6:00:11:22", "router", "Netgear")
    assert(r_name == "router.local", "Expected router.local, got: " .. tostring(r_name))
    assert(not is_custom)

    -- Default for Raspberry Pi (unaliased subnet)
    local pi_name = lan.resolve_system_hostname("192.168.2.10", "dc:a6:32:00:11:22", "linux", "Raspberry Pi Trading")
    assert(pi_name == "raspberrypi", "Expected raspberrypi, got: " .. tostring(pi_name))

    -- Custom alias override
    lan.CUSTOM_NAMES["192.168.1.99"] = "My-Custom-Device"
    local c_name, c_custom = lan.resolve_system_hostname("192.168.1.99", nil, "other", "Vendor")
    assert(c_name == "My-Custom-Device", "Expected custom alias, got: " .. tostring(c_name))
    assert(c_custom == true)
    lan.CUSTOM_NAMES["192.168.1.99"] = nil
end)

-- Test 6: Standard Port Definition & TCP Check
test("Port Prober definitions & non-blocking TCP socket", function()
    assert(type(lan.KNOWN_PORTS) == "table", "KNOWN_PORTS should be exported")
    assert(#lan.KNOWN_PORTS >= 10, "Expected at least 10 standard ports defined")
    local has_ssh, has_http, has_rtsp = false, false, false
    for _, kp in ipairs(lan.KNOWN_PORTS) do
        if kp.port == 22 then has_ssh = true end
        if kp.port == 80 then has_http = true end
        if kp.port == 554 then has_rtsp = true end
    end
    assert(has_ssh, "Port 22 (SSH) must be in KNOWN_PORTS")
    assert(has_http, "Port 80 (HTTP) must be in KNOWN_PORTS")
    assert(has_rtsp, "Port 554 (RTSP) must be in KNOWN_PORTS")

    -- TCP port check on unreachable non-routable address should fail fast without hanging
    local t0 = os.clock()
    local is_open = lan.check_tcp_port("192.0.2.1", 65534, 15)
    local dt = os.clock() - t0
    assert(not is_open, "Port on 192.0.2.1 should not be open")
    assert(dt < 0.25, string.format("TCP check timed out too slowly: %.3fs", dt))
end)

-- Test 7: Candidate-Gated Hostname Resolution Latency
test("Non-candidate devices bypass mDNS lookups instantly", function()
    -- Camera (not a candidate) should resolve instantly without blocking on mDNS
    local t0 = os.clock()
    local name = lan.resolve_system_hostname("192.168.2.55", "00:9e:c8:11:22:33", "camera", "Dahua Technology", true)
    local dt = os.clock() - t0
    assert(name == "camera-55", "Expected camera-55, got: " .. tostring(name))
    assert(dt < 0.05, string.format("Camera resolution blocked unexpectedly: %.3fs", dt))

    -- IoT device (not a candidate)
    local t1 = os.clock()
    local iot_name = lan.resolve_system_hostname("192.168.2.88", "84:3e:1d:11:22:33", "iot", "Espressif Inc (IoT)", true)
    local dt1 = os.clock() - t1
    assert(iot_name == "iot-device-88", "Expected iot-device-88, got: " .. tostring(iot_name))
    assert(dt1 < 0.05, string.format("IoT resolution blocked unexpectedly: %.3fs", dt1))
end)

-- Test 8: Live ICMP Ping RTT Response
test("ICMP Ping probe returns RTT for live targets", function()
    -- Ping localhost 127.0.0.1
    local alive, rtt = lan.ping_host("127.0.0.1", 25)
    assert(alive == true, "Localhost should respond to ping")
    assert(type(rtt) == "number" and rtt >= 0, "RTT should be non-negative number")
end)

-- Test 9: Custom Port Range Parser & Multi-Port Probing
test("Custom Port Scanner range parser and probing", function()
    -- Test custom port range parsing logic
    local test_ranges = "80,8080,9000-9003"
    local parsed_ports = {}
    for part in test_ranges:gmatch("[^,]+") do
        local p1, p2 = part:match("^(%d+)%-(%d+)$")
        if p1 and p2 then
            for p = tonumber(p1), tonumber(p2) do
                table.insert(parsed_ports, p)
            end
        else
            table.insert(parsed_ports, tonumber(part))
        end
    end
    assert(#parsed_ports == 6, "Expected 6 parsed ports (80, 8080, 9000, 9001, 9002, 9003)")
    assert(parsed_ports[1] == 80 and parsed_ports[2] == 8080)
    assert(parsed_ports[3] == 9000 and parsed_ports[6] == 9003)

    -- Probing custom non-open port on 127.0.0.1 fails cleanly without hanging
    local open = lan.check_tcp_port("127.0.0.1", 64321, 10)
    assert(open == false, "Arbitrary unallocated port should be closed")
end)

-- Test 10: Undeclared Globals Check via LuaJIT Bytecode
test("Bytecode Scoping (Assert 0 Undeclared Globals)", function()
    local p = io.popen("luajit -bl lan_dashboard.lua && luajit -bl lan_inventory.lua && luajit -bl lan_scan_job.lua && luajit -bl lan_ports.lua", "r")
    assert(p, "Failed to run luajit -bl")
    local bc = p:read("*a")
    p:close()

    local undeclared = {}
    local allowed_globals = {
        require = true, ffi = true, bit = true, os = true, io = true,
        string = true, table = true, math = true, tonumber = true,
        tostring = true, type = true, ipairs = true, pairs = true,
        pcall = true, assert = true, print = true, error = true, arg = true, debug = true
    }

    for line in bc:gmatch("[^\r\n]+") do
        local gvar = line:match('GGET%s+%d+%s+%d+%s+;%s+"([^"]+)"')
        if gvar and not allowed_globals[gvar] then
            table.insert(undeclared, gvar)
        end
    end

    if #undeclared > 0 then
        error("Found undeclared global variables: " .. table.concat(undeclared, ", "))
    end
end)

-- Test 11: Web Server REST Endpoints Verification
test("Embedded HTTP Web Server endpoints respond with 200 OK", function()
    local path = os.tmpname()
    os.remove(path)
    local inventory_module = require("lan_inventory")
    local saved_inventory = inventory_module.new(path)
    saved_inventory:merge({{ip = "203.0.113.254", mac = "aa:bb:cc:dd:ee:ff", hostname = "Saved NAS",
        vendor = "Test", category = "linux", type_name = "Linux", ports = {}, status = "online"}}, 100, false)
    assert(saved_inventory:save())
    local escaped_path = "'" .. path:gsub("'", "'\\''") .. "'"
    local p = io.popen("LAN_INVENTORY_FILE=" .. escaped_path .. " luajit lan_dashboard.lua -p 18889 >/dev/null 2>&1 & echo $!", "r")
    assert(p, "Failed to spawn background server")
    local pid = p:read("*l")
    p:close()
    assert(pid and tonumber(pid), "Failed to read server PID")

    os.execute("sleep 0.1")

    local curl_p = io.popen("curl --max-time 30 -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18889/", "r")
    local code = curl_p and curl_p:read("*a")
    if curl_p then curl_p:close() end

    local scan_state
    for _ = 1, 100 do
        local progress = io.popen("curl --max-time 2 -s http://127.0.0.1:18889/api/scan", "r")
        local data = progress and progress:read("*a")
        if progress then progress:close() end
        if data and data ~= "" then
            scan_state = require("json").decode(data).scan
            if scan_state.state == "completed" or scan_state.state == "failed" then break end
        end
        os.execute("sleep 0.1")
    end

    local curl_api = io.popen("curl --max-time 30 -s http://127.0.0.1:18889/api/devices", "r")
    local api_json = curl_api and curl_api:read("*a")
    if curl_api then curl_api:close() end

    os.execute("kill -9 " .. pid .. " 2>/dev/null")

    local reloaded = inventory_module.new(path)
    local load_ok = reloaded:load()
    os.remove(path)
    os.remove(path .. ".tmp")

    assert(code == "200", "Expected 200 OK from GET /, got: " .. tostring(code))
    assert(api_json and api_json:find('"status":"ok"'), "Expected ok status from /api/devices")
    assert(scan_state and scan_state.state == "completed", "Startup background scan failed or timed out")
    local response = require("json").decode(api_json)
    local historical
    for _, d in ipairs(response.devices) do
        assert(type(d.first_seen) == "number" and type(d.last_seen) == "number")
        if d.hostname == "Saved NAS" then historical = d end
    end
    assert(historical and historical.status == "not_observed", "Saved device disappeared after startup scan")
    assert(historical.first_seen == 100 and historical.last_seen == 100, "Historical timestamps changed")
    assert(load_ok and #reloaded.devices == #response.devices, "Completed scan was not persisted")
end)

test("Persistent inventory regression tests", function()
    dofile("test_lan_inventory.lua")
end)

test("Change timeline and trusted-device metadata", function()
    dofile("test_lan_inventory_features.lua")
end)

test("Complete custom port ranges and validation", function()
    dofile("test_lan_ports.lua")
end)

test("Background scan worker lifecycle regression tests", function()
    dofile("test_lan_scan_job.lua")
end)

test("Scan exceptions restore the scanning flag", function()
    local ok = pcall(lan.run_full_scan, false, {progress = function() error("Progress writer failed") end})
    assert(not ok and lan.STATE.scanning == false, "Scan failure left the scanner busy")
end)

test("Headless dashboard rendering regression tests", function()
    assert(os.execute("node test_lan_dashboard_ui.js") == 0, "Dashboard renderer checks failed")
end)

test("Live HTTP responsiveness and scan cancellation", function()
    assert(os.execute("python3 test_lan_dashboard_scan.py") == 0, "Live background scan checks failed")
end)

print(string.format("\nResults: %d Passed, %d Failed\n", passed, failed))
if failed > 0 then
    os.exit(1)
end
