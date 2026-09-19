#!/usr/bin/env luajit
--[[
    test_luatop.lua
    Comprehensive unit and integration test suite for luatop.lua.
]]

local luatop = require("luatop")
local btop = luatop

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

local function assert_true(val, msg)
    if not val then
        error(msg or "Assertion failed: expected true", 2)
    end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

print("=== Running luatop Professional System Monitor Test Suite ===")

-- 1. CPU & Hardware Sensors
TestRunner.describe("1. CPU & Hardware Sensors", function()
    TestRunner.it("should report valid CPU usage and per-core breakdown", function()
        local cores, overall = btop.read_cpu_stats()
        assert_true(type(cores) == "table", "cores must be a table")
        assert_true(#cores > 0, "should detect at least 1 CPU core")
        assert_true(type(overall) == "number", "overall CPU must be a number")
        assert_true(overall >= 0 and overall <= 100, "overall CPU% must be between 0 and 100")
        for i, c in ipairs(cores) do
            assert_true(type(c.name) == "string", "core name must be string")
            assert_true(c.pct >= 0 and c.pct <= 100, "core pct must be in [0, 100]")
        end
    end)

    TestRunner.it("should read CPU thermal and frequency sensors safely", function()
        local temp, freq = btop.read_cpu_sensors()
        if temp ~= nil then
            assert_true(type(temp) == "number" and temp > 0 and temp < 150, "temperature in realistic range")
        end
        if freq ~= nil then
            assert_true(type(freq) == "number" and freq > 0 and freq < 10, "frequency in realistic GHz range")
        end
    end)
end)

-- 2. Memory & Swap Telemetry
TestRunner.describe("2. Memory and Swap Telemetry", function()
    local mem = btop.read_memory_stats()

    TestRunner.it("should report non-zero physical memory totals and valid percentages", function()
        assert_true(mem.total_kb > 0, "total RAM must be > 0")
        assert_true(mem.avail_kb > 0, "available RAM must be > 0")
        assert_true(mem.used_kb <= mem.total_kb, "used RAM must be <= total RAM")
        assert_true(mem.used_pct >= 0 and mem.used_pct <= 100, "used pct must be in [0, 100]")
    end)

    TestRunner.it("should report valid Swap totals and metrics", function()
        assert_true(type(mem.swap_total_kb) == "number" and mem.swap_total_kb >= 0, "swap total >= 0")
        assert_true(type(mem.swap_used_kb) == "number" and mem.swap_used_kb >= 0, "swap used >= 0")
        assert_true(mem.swap_pct >= 0 and mem.swap_pct <= 100, "swap pct in [0, 100]")
    end)
end)

-- 3. Network I/O Telemetry
TestRunner.describe("3. Network I/O and Bandwidth Engine", function()
    TestRunner.it("should inspect network interfaces and throughput", function()
        local net = btop.read_network_stats(os.clock())
        assert_true(type(net) == "table", "net stats must be a table")
        assert_true(type(net.active_iface) == "string" and #net.active_iface > 0, "active iface should be non-empty")
        assert_true(net.rx_total >= 0, "rx_total should be non-negative")
        assert_true(net.tx_total >= 0, "tx_total should be non-negative")
        assert_true(net.rx_rate >= 0, "rx_rate should be non-negative")
        assert_true(net.tx_rate >= 0, "tx_rate should be non-negative")
        assert_true(type(net.ifaces) == "table", "ifaces must be a table")
    end)

    TestRunner.it("should format network rate strings cleanly", function()
        assert_true(btop.format_rate(500):find("B/s") ~= nil, "500 B/s format")
        assert_true(btop.format_rate(1024 * 50):find("KB/s") ~= nil, "50 KB/s format")
        assert_true(btop.format_rate(1024 * 1024 * 5):find("MB/s") ~= nil, "5 MB/s format")
        assert_true(btop.format_rate(1024 * 1024 * 1024 * 2):find("GB/s") ~= nil, "2 GB/s format")
    end)
end)

-- 4. Storage & Filesystem Telemetry
TestRunner.describe("4. Storage and Disk I/O Telemetry", function()
    TestRunner.it("should discover mounted filesystems via statvfs", function()
        local st = btop.read_storage_stats(os.clock())
        assert_true(type(st.mounts) == "table", "mounts must be a table")
        assert_true(#st.mounts > 0, "should discover at least 1 mounted filesystem")

        local root_found = false
        for _, m in ipairs(st.mounts) do
            if m.mount == "/" or m.mount == "C:" then root_found = true end
            assert_true(m.total_bytes > 0, "total storage bytes > 0")
            assert_true(m.avail_bytes > 0, "avail storage bytes > 0")
            assert_true(m.used_pct >= 0 and m.used_pct <= 100, "used pct in [0, 100]")
        end
        assert_true(root_found, "root mount point must be discovered")
    end)

    TestRunner.it("should format byte sizes accurately", function()
        assert_eq(btop.format_bytes(512), "512 K", "512 K format")
        assert_eq(btop.format_bytes(1024 * 2), "2.0 M", "2.0 M format")
        assert_eq(btop.format_bytes(1024 * 1024 * 4), "4.00 G", "4.00 G format")
    end)
end)

-- 5. Process Engine & Username Resolution
TestRunner.describe("5. Process Table & Username Resolution", function()
    local mem = btop.read_memory_stats()
    local procs = btop.read_process_table(mem.total_kb, os.clock())

    TestRunner.it("should parse running processes with valid metadata", function()
        assert_true(#procs > 0, "should find running processes")
        local p1 = procs[1]
        assert_true(p1.pid >= 0, "PID must be >= 0")
        assert_true(type(p1.comm) == "string" and #p1.comm > 0, "comm must not be empty")
        assert_true(type(p1.cmdline) == "string", "cmdline must be string")
        assert_true(type(p1.threads) == "number" and p1.threads >= 1, "threads must be >= 1")
        assert_true(p1.res_kb >= 0, "resident memory must be >= 0")
    end)

    TestRunner.it("should resolve root or system user", function()
        local is_win = package.config:sub(1, 1) == "\\"
        local root_name = btop.resolve_username(0)
        if is_win then
            assert_true(root_name == "SYSTEM" or root_name == "root", "UID 0 must resolve to SYSTEM or root on Windows")
        else
            assert_eq(root_name, "root", "UID 0 must resolve to root")
        end
    end)

    TestRunner.it("should resolve real usernames across process table without hardcoding", function()
        local is_win = package.config:sub(1, 1) == "\\"
        local seen_users = {}
        for _, p in ipairs(procs) do
            assert_true(type(p.username) == "string" and #p.username > 0, "username must not be empty")
            seen_users[p.username] = true
        end
        if is_win then
            assert_true(seen_users["SYSTEM"] == true or seen_users["Administrator"] == true or next(seen_users) ~= nil, "valid usernames must be present in process table")
        else
            assert_true(seen_users["root"] == true, "root user must be present in process table")
        end
    end)
end)

-- 6. Process Tree Construction Engine
TestRunner.describe("6. Process Tree Hierarchy & Sorting", function()
    TestRunner.it("should build hierarchical tree with correct parent-child branches", function()
        local synthetic_procs = {
            { pid = 1, ppid = 0, comm = "init", cmdline = "init", cpu_pct = 1.0, res_kb = 100, threads = 1, username = "root" },
            { pid = 10, ppid = 1, comm = "sshd", cmdline = "sshd", cpu_pct = 0.5, res_kb = 200, threads = 2, username = "root" },
            { pid = 20, ppid = 10, comm = "bash", cmdline = "bash", cpu_pct = 0.1, res_kb = 300, threads = 1, username = "user" },
            { pid = 30, ppid = 20, comm = "btop", cmdline = "btop", cpu_pct = 5.0, res_kb = 400, threads = 1, username = "user" },
            { pid = 40, ppid = 1, comm = "cron", cmdline = "cron", cpu_pct = 0.0, res_kb = 50, threads = 1, username = "root" },
        }

        local tree = btop.build_process_tree(synthetic_procs, "cpu", false)
        assert_eq(#tree, #synthetic_procs, "tree must preserve all nodes")

        local p_btop = nil
        for _, n in ipairs(tree) do
            if n.pid == 30 then p_btop = n break end
        end
        assert_true(p_btop ~= nil, "btop node must be found in tree")
        assert_eq(p_btop.tree_depth, 3, "btop depth should be 3 (init -> sshd -> bash -> btop)")
        assert_true(#p_btop.tree_prefix > 0, "btop should have tree prefix")
    end)

    TestRunner.it("should prevent infinite loops on cyclic PPID references", function()
        local cyclic_procs = {
            { pid = 100, ppid = 101, comm = "procA", cpu_pct = 1.0, res_kb = 100, threads = 1, username = "root" },
            { pid = 101, ppid = 100, comm = "procB", cpu_pct = 1.0, res_kb = 100, threads = 1, username = "root" },
        }
        local tree = btop.build_process_tree(cyclic_procs, "cpu", false)
        assert_true(#tree <= 2, "cyclic tree should terminate safely")
    end)
end)

-- 7. Themes & Visual Utilities
TestRunner.describe("7. Theme Palette & String Formatting", function()
    TestRunner.it("should support all built-in color themes", function()
        local themes = btop.get_themes()
        assert_true(themes.tokyo_night ~= nil, "tokyo_night theme must exist")
        assert_true(themes.dracula ~= nil, "dracula theme must exist")
        assert_true(themes.nord ~= nil, "nord theme must exist")
        assert_true(themes.cyberpunk ~= nil, "cyberpunk theme must exist")
        assert_true(themes.monokai ~= nil, "monokai theme must exist")

        assert_true(btop.set_theme("dracula") == true, "set dracula theme")
        assert_true(btop.set_theme("nord") == true, "set nord theme")
        assert_true(btop.set_theme("tokyo_night") == true, "set tokyo_night theme")
    end)

    TestRunner.it("should calculate visual string lengths ignoring ANSI escape codes", function()
        assert_eq(btop.visual_len("plain text"), 10, "plain text length")
        assert_eq(btop.visual_len("\27[1;31mred bold\27[0m"), 8, "ansi colored text length")
        assert_eq(btop.visual_len("\27[38;2;125;207;255m24bit color\27[0m"), 11, "24-bit truecolor length")
    end)

    TestRunner.it("should truncate strings safely with ellipsis", function()
        local short = btop.truncate("hello world", 8)
        assert_true(short:find("^hello") ~= nil, "truncated string should begin with hello")
        assert_eq(btop.visual_len(short), 8, "truncated visual length should equal max_w")
    end)
end)

-- Summary
print("\n--------------------------------------------------")
local total = TestRunner.passed + TestRunner.failed
print(string.format("TEST RESULTS: %d / %d tests passed", TestRunner.passed, total))
if TestRunner.failed == 0 then
    print("\27[1;32mALL BTOP LITE TESTS PASSED SUCCESSFULLY!\27[0m")
    os.exit(0)
else
    print(string.format("\27[1;31mFAILED: %d tests failed!\27[0m", TestRunner.failed))
    os.exit(1)
end
