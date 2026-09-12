#!/usr/bin/env luajit
--[[
    test_ffi_system_info.lua
    Comprehensive unit and integration test suite for ffi_system_info.lua.
]]

local SysInfo = require("ffi_system_info")

local TestRunner = {
    passed = 0,
    failed = 0
}

function TestRunner.describe(suite_name, fn)
    print(string.format("\n\27[1;36m▶ Suite: %s\27[0m", suite_name))
    fn()
end

function TestRunner.it(test_name, fn)
    local ok, err = pcall(fn)
    if ok then
        TestRunner.passed = TestRunner.passed + 1
        print(string.format("  \27[32m✔\27[0m %s", test_name))
    else
        TestRunner.failed = TestRunner.failed + 1
        print(string.format("  \27[31m✘\27[0m %s", test_name))
        print(string.format("    \27[31mError: %s\27[0m", tostring(err)))
    end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(val, msg)
    if not val then
        error(msg or "Assertion failed: expected true", 2)
    end
end

print("=== Running FFI System Information & Diagnostics Test Suite ===")

-- 1. OS & Host Info
TestRunner.describe("1. OS and Host Information", function()
    local os_info = SysInfo.get_os_info()

    TestRunner.it("should report valid non-empty hostname and nodename", function()
        assert_true(type(os_info.hostname) == "string" and #os_info.hostname > 0, "hostname invalid")
        assert_true(type(os_info.nodename) == "string" and #os_info.nodename > 0, "nodename invalid")
    end)

    TestRunner.it("should report kernel release and machine architecture", function()
        assert_true(type(os_info.release) == "string" and #os_info.release > 0, "release invalid")
        assert_true(os_info.machine == "x86_64" or os_info.machine == "aarch64" or #os_info.machine > 0, "machine invalid")
    end)

    TestRunner.it("should report positive uptime and process count", function()
        assert_true(os_info.uptime_seconds > 0, "uptime should be > 0")
        assert_true(os_info.processes_count > 0, "procs should be > 0")
        assert_true(#os_info.uptime_formatted > 0, "uptime formatted should not be empty")
    end)

    TestRunner.it("should return valid load averages", function()
        assert_true(type(os_info.loadavg.load_1m) == "number" and os_info.loadavg.load_1m >= 0, "load_1m invalid")
        assert_true(type(os_info.loadavg.load_5m) == "number" and os_info.loadavg.load_5m >= 0, "load_5m invalid")
        assert_true(type(os_info.loadavg.load_15m) == "number" and os_info.loadavg.load_15m >= 0, "load_15m invalid")
    end)
end)

-- 2. User & Environment
TestRunner.describe("2. User and Process Context", function()
    local user = SysInfo.get_user_info()
    local proc = SysInfo.get_process_info()

    TestRunner.it("should return valid UID, GID, and non-empty username", function()
        assert_true(type(user.uid) == "number" and user.uid >= 0, "UID invalid")
        assert_true(type(user.gid) == "number" and user.gid >= 0, "GID invalid")
        assert_true(type(user.username) == "string" and #user.username > 0, "username invalid")
    end)

    TestRunner.it("should return valid process ID (PID) and parent PID", function()
        assert_true(proc.pid > 0, "PID should be > 0")
        assert_true(proc.ppid >= 0, "PPID should be >= 0")
        assert_true(proc.pgrp >= 0, "PGRP should be >= 0")
    end)

    TestRunner.it("should return valid resource limits and usage metrics", function()
        assert_true(proc.rlimit_nofile_cur > 0, "soft FD limit should be > 0")
        assert_true(proc.rlimit_nofile_max >= proc.rlimit_nofile_cur, "hard limit >= soft limit")
        assert_true(proc.max_rss_kb > 0, "max RSS should be > 0")
    end)
end)

-- 3. CPU & Memory
TestRunner.describe("3. Hardware, CPU, and Memory Metrics", function()
    local cpu = SysInfo.get_cpu_info()
    local mem = SysInfo.get_memory_info()

    TestRunner.it("should report positive CPU core count and page size", function()
        assert_true(cpu.online_cpus > 0, "online CPUs should be > 0")
        assert_true(cpu.configured_cpus >= cpu.online_cpus, "configured >= online")
        assert_true(cpu.page_size_bytes == 4096 or cpu.page_size_bytes > 0, "page size > 0")
        assert_true(cpu.clock_ticks_hz > 0, "clock ticks > 0")
    end)

    TestRunner.it("should report realistic memory totals and utilization", function()
        assert_true(mem.total_ram > 0, "total RAM should be > 0")
        assert_true(mem.used_ram <= mem.total_ram, "used RAM <= total RAM")
        assert_true(mem.free_ram <= mem.total_ram, "free RAM <= total RAM")
        assert_true(mem.ram_percent >= 0 and mem.ram_percent <= 100, "ram percent in [0, 100]")
    end)
end)

-- 4. Storage & Filesystem
TestRunner.describe("4. Storage and POSIX File Inspection", function()
    TestRunner.it("should inspect filesystem storage via statvfs", function()
        local disk = SysInfo.get_storage_info(".")
        assert_true(disk.total_bytes > 0, "total storage bytes > 0")
        assert_true(disk.avail_bytes > 0, "available storage bytes > 0")
        assert_true(disk.block_size > 0, "block size > 0")
        assert_true(disk.used_percent >= 0 and disk.used_percent <= 100, "disk used percent in range")
    end)

    TestRunner.it("should accurately inspect file metadata via stat", function()
        local st = SysInfo.get_file_stat("Makefile")
        assert_true(st.exists == true, "Makefile must exist")
        assert_true(st.size_bytes > 0, "Makefile size > 0")
        assert_true(st.is_regular_file == true, "Makefile is regular file")
        assert_true(#st.permissions == 10, "POSIX mode string length == 10")
        assert_true(#st.mode_octal == 4, "Octal string length == 4")
    end)

    TestRunner.it("legacy get_file_size fopen/fseek should match stat size", function()
        local fopen_size = SysInfo.get_file_size("Makefile")
        local stat_info = SysInfo.get_file_stat("Makefile")
        assert_eq(fopen_size, stat_info.size_bytes, "size mismatch between fopen and stat")
    end)
end)

-- 5. Network Interfaces & Benchmark
TestRunner.describe("5. Network Interfaces & Memory Benchmark", function()
    TestRunner.it("should discover network interfaces with getifaddrs", function()
        local ifaces = SysInfo.get_network_info()
        assert_true(#ifaces > 0, "should have at least one network interface")

        local found_lo = false
        for _, iface in ipairs(ifaces) do
            if iface.is_loopback then
                found_lo = true
                assert_true(#iface.ipv4 > 0 and iface.ipv4[1] == "127.0.0.1", "loopback IPv4 should be 127.0.0.1")
            end
        end
        assert_true(found_lo, "must find loopback interface")
    end)

    TestRunner.it("should run memory throughput benchmark cleanly", function()
        local b = SysInfo.benchmark_memory(4, 5)
        assert_true(b.memset_gb_per_sec > 0, "memset bandwidth > 0")
        assert_true(b.c_ptr_duration_sec > 0, "c pointer duration > 0")
        assert_true(b.lua_tbl_duration_sec > 0, "lua table duration > 0")
    end)

    TestRunner.it("should serialize full telemetry to valid JSON", function()
        local json_str = SysInfo.to_json()
        assert_true(type(json_str) == "string" and #json_str > 100, "JSON string should be valid and long")
        assert_true(json_str:find('"hostname"', 1, true) ~= nil, "JSON must contain hostname")
        assert_true(json_str:find('"total_ram"', 1, true) ~= nil, "JSON must contain total_ram")
    end)
end)

-- Summary
print("\n--------------------------------------------------")
local total = TestRunner.passed + TestRunner.failed
print(string.format("TEST RESULTS: %d / %d tests passed", TestRunner.passed, total))
if TestRunner.failed == 0 then
    print("\27[1;32mALL FFI SYSTEM INFO TESTS PASSED SUCCESSFULLY!\27[0m")
    os.exit(0)
else
    print(string.format("\27[1;31mFAILED: %d tests failed!\27[0m", TestRunner.failed))
    os.exit(1)
end
