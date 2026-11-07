#!/usr/bin/env luajit
--[[
    test_hwinfo_tui.lua
    Test suite for hwinfo_tui.lua: collectors (fixture tree), failure paths,
    frame rendering at many sizes, keystroke simulation, differential refresh,
    JSON export, and CLI behaviour.
]]

local HW = require("hwinfo_tui")

local passed, failed = 0, 0

local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  \27[32m✔\27[0m " .. name)
    else
        failed = failed + 1
        print("  \27[31m✘\27[0m " .. name)
        print("    \27[31m" .. tostring(err) .. "\27[0m")
    end
end

local function describe(name, fn)
    print("\n\27[1;36m▶ " .. name .. "\27[0m")
    fn()
end

local function assert_true(v, msg)
    if not v then
        error(msg or "expected true", 2)
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected '%s', got '%s'", msg or "mismatch", tostring(b),
            tostring(a)), 2)
    end
end

-- =========================================================================
-- Fixture tree
-- =========================================================================
local ROOT = os.tmpname()
os.remove(ROOT)
os.execute("mkdir -p '" .. ROOT .. "'")

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function write_file(path, content)
    local full = ROOT .. path
    os.execute("mkdir -p " .. shell_quote(full:match("^(.*)/[^/]*$")))
    local f = assert(io.open(full, "wb"))
    f:write(content)
    f:close()
end

local function symlink(target, path)
    local full = ROOT .. path
    os.execute("mkdir -p " .. shell_quote(full:match("^(.*)/[^/]*$")))
    os.execute("ln -sfn " .. shell_quote(target) .. " " .. shell_quote(full))
end

write_file("/sys/class/dmi/id/sys_vendor", "ACME Corp\n")
write_file("/sys/class/dmi/id/product_name", "Rocket 9000\n")
write_file("/sys/class/dmi/id/chassis_type", "10\n")
write_file("/sys/class/dmi/id/bios_version", "F.42\n")
write_file("/etc/os-release", 'NAME="Test"\nPRETTY_NAME="Test Linux 1.0"\n')
write_file("/proc/uptime", "93784.12 5000.00\n")

write_file("/proc/cpuinfo", table.concat({
    "processor\t: 0", "vendor_id\t: GenuineTest", "model name\t: Test CPU 3000 @ 3.0GHz",
    "cpu MHz\t\t: 2999.5", "physical id\t: 0", "core id\t\t: 0",
    "flags\t\t: fpu sse avx2 aes", "",
    "processor\t: 1", "physical id\t: 0", "core id\t\t: 0", "",
    "processor\t: 2", "physical id\t: 0", "core id\t\t: 1", "",
    "processor\t: 3", "physical id\t: 0", "core id\t\t: 1", "",
}, "\n"))
write_file("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq", "800000\n")
write_file("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq", "4200000\n")
write_file("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "1500000\n")
write_file("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", "powersave\n")
write_file("/sys/devices/system/cpu/cpu0/cache/index0/level", "1\n")
write_file("/sys/devices/system/cpu/cpu0/cache/index0/type", "Data\n")
write_file("/sys/devices/system/cpu/cpu0/cache/index0/size", "32K\n")
write_file("/sys/devices/system/cpu/cpu0/cache/index2/level", "3\n")
write_file("/sys/devices/system/cpu/cpu0/cache/index2/type", "Unified\n")
write_file("/sys/devices/system/cpu/cpu0/cache/index2/size", "8192K\n")

write_file("/proc/meminfo", table.concat({
    "MemTotal:       16384000 kB", "MemFree:         1000000 kB",
    "MemAvailable:    8192000 kB", "Cached:          2048000 kB",
    "SwapTotal:       4096000 kB", "SwapFree:        4096000 kB",
    "Hugepagesize:       2048 kB", "",
}, "\n"))

local smbios = string.char(17, 0x22, 0, 0) .. string.rep("\0", 8)
    .. string.char(0x00, 0x20) -- size word at 0x0C = 8192 MB
    .. string.rep("\0", 2)
    .. string.char(1) -- 0x10 locator idx
    .. string.char(0) -- 0x11 bank
    .. string.char(0x1A) -- 0x12 DDR4
    .. string.rep("\0", 2)
    .. string.char(0x00, 0x0C) -- 0x15 speed 3072
    .. string.char(2) -- 0x17 manufacturer idx
    .. string.rep("\0", 2)
    .. string.char(3) -- 0x1A part idx
    .. string.rep("\0", 0x22 - 0x1B)
    .. "DIMM A\0Acme\0PN-123  \0\0"
write_file("/sys/firmware/dmi/entries/17-0/raw", smbios)

write_file("/usr/share/hwdata/pci.ids",
    "1234  Test Vendor Inc\n\t0001  Test GPU X\n\t0002  Test NIC\n9999  Other\n\t0001  Other Dev\n")
write_file("/sys/bus/pci/devices/0000:01:00.0/vendor", "0x1234\n")
write_file("/sys/bus/pci/devices/0000:01:00.0/device", "0x0001\n")
write_file("/sys/bus/pci/devices/0000:01:00.0/class", "0x030000\n")
write_file("/sys/bus/pci/devices/0000:01:00.0/mem_info_vram_total", "8589934592\n")
write_file("/sys/bus/pci/devices/0000:02:00.0/vendor", "0x1234\n")
write_file("/sys/bus/pci/devices/0000:02:00.0/device", "0x0002\n")
write_file("/sys/bus/pci/devices/0000:02:00.0/class", "0x020000\n")
symlink("/sys/bus/pci/drivers/testdrv", "/sys/bus/pci/devices/0000:01:00.0/driver")

write_file("/sys/block/sda/size", "2097152\n")
write_file("/sys/block/sda/device/model", "FAKE DISK 1TB\n")
write_file("/sys/block/sda/queue/rotational", "1\n")
write_file("/sys/block/sda/queue/scheduler", "none [mq-deadline] kyber\n")
write_file("/sys/block/loop0/size", "100\n")
write_file("/sys/block/nvme0n1/size", "1000215216\n")
write_file("/sys/block/nvme0n1/queue/rotational", "0\n")
write_file("/proc/mounts", "/dev/sda1 / ext4 rw 0 0\ntmpfs /run tmpfs rw 0 0\n"
    .. "/dev/gone /nonexistent_mnt ext4 rw 0 0\n")

write_file("/sys/class/net/eth0/operstate", "up\n")
write_file("/sys/class/net/eth0/address", "aa:bb:cc:dd:ee:ff\n")
write_file("/sys/class/net/eth0/speed", "1000\n")
write_file("/sys/class/net/eth0/mtu", "1500\n")

write_file("/sys/class/hwmon/hwmon0/name", "coretemp\n")
write_file("/sys/class/hwmon/hwmon0/temp1_input", "45500\n")
write_file("/sys/class/hwmon/hwmon0/temp1_label", "Package id 0\n")
write_file("/sys/class/hwmon/hwmon0/fan1_input", "2400\n")
write_file("/sys/class/hwmon/hwmon1/name", "emptyhw\n")
write_file("/sys/class/power_supply/BAT0/type", "Battery\n")
write_file("/sys/class/power_supply/BAT0/status", "Charging\n")
write_file("/sys/class/power_supply/BAT0/capacity", "80\n")
write_file("/sys/class/power_supply/BAT0/energy_full", "40000000\n")
write_file("/sys/class/power_supply/BAT0/energy_full_design", "50000000\n")
write_file("/sys/class/power_supply/AC/type", "Mains\n")
write_file("/sys/class/power_supply/AC/online", "1\n")

write_file("/sys/bus/usb/devices/1-1/idVendor", "046d\n")
write_file("/sys/bus/usb/devices/1-1/idProduct", "c52b\n")
write_file("/sys/bus/usb/devices/1-1/manufacturer", "Logitech\n")
write_file("/sys/bus/usb/devices/1-1/product", "Receiver\n")
write_file("/sys/bus/usb/devices/1-1/speed", "12\n")
write_file("/sys/bus/usb/devices/1-1:1.0/bInterfaceClass", "03\n")

local function find_item(groups, label)
    for _, g in ipairs(groups) do
        for _, it_ in ipairs(g.items) do
            if it_.label == label or it_.label:find(label, 1, true) then
                return it_.value
            end
        end
    end
    return nil
end

local function strip_ansi(s)
    return (s:gsub("\27%[[%d;?]*[%a]", ""))
end

print("=== Running hwinfo_tui test suite ===")

describe("1. Collectors against a fixture tree", function()
    HW.root = ROOT

    it("system: DMI, chassis, OS, uptime", function()
        local g = HW.collect_system()
        assert_eq(find_item(g, "Vendor"), "ACME Corp")
        assert_eq(find_item(g, "Product"), "Rocket 9000")
        assert_eq(find_item(g, "Chassis"), "Notebook")
        assert_eq(find_item(g, "Distribution"), "Test Linux 1.0")
        assert_eq(find_item(g, "Uptime"), "1d 2h 3m")
        assert_true(find_item(g, "Kernel"):find("Linux"), "kernel from uname FFI")
    end)

    it("cpu: model, threads, cores, frequency, cache, flags", function()
        local g = HW.collect_cpu()
        assert_eq(find_item(g, "Model"), "Test CPU 3000 @ 3.0GHz")
        assert_eq(find_item(g, "Threads"), "4")
        assert_eq(find_item(g, "Cores"), "2")
        assert_eq(find_item(g, "Range"), "800 MHz - 4200 MHz")
        assert_eq(find_item(g, "Current"), "1500 MHz")
        assert_eq(find_item(g, "Governor"), "powersave")
        assert_eq(find_item(g, "L1 Data"), "32K")
        assert_eq(find_item(g, "L3 Unified"), "8192K")
        assert_eq(find_item(g, "Flags"), "fpu sse avx2 aes")
    end)

    it("memory: meminfo and SMBIOS type 17 DIMM", function()
        local g = HW.collect_memory()
        assert_eq(find_item(g, "Total"), "15.6 GiB")
        assert_true(find_item(g, "Used"):find("50%%"), "used percent")
        local dimm = find_item(g, "DIMM A")
        assert_true(dimm ~= nil, "DIMM row present")
        assert_true(dimm:find("8.0 GiB") and dimm:find("DDR4") and dimm:find("Acme")
            and dimm:find("PN%-123"), "DIMM details: " .. tostring(dimm))
    end)

    it("gpu/pci: names from pci.ids, driver symlink, VRAM, GPU split", function()
        local g = HW.collect_gpu_pci()
        assert_eq(g[1].title, "Graphics")
        local gpu = find_item({ g[1] }, "VGA")
        assert_true(gpu and gpu:find("Test Vendor Inc Test GPU X") and gpu:find("driver: testdrv"),
            tostring(gpu))
        assert_eq(find_item({ g[1] }, "VRAM"), "8.0 GiB")
        local nic = find_item({ g[2] }, "Ethernet")
        assert_true(nic and nic:find("Test NIC"), "NIC resolved")
        assert_true(find_item({ g[1] }, "Ethernet") == nil, "NIC is not a GPU")
    end)

    it("storage: skips loop, classifies HDD/NVMe, statvfs mounts", function()
        local g = HW.collect_storage()
        local sda = find_item(g, "sda")
        assert_true(sda and sda:find("1.0 GiB") and sda:find("HDD") and sda:find("FAKE DISK")
            and sda:find("mq%-deadline"), tostring(sda))
        assert_true(find_item(g, "loop0") == nil, "loop device skipped")
        assert_true(find_item(g, "nvme0n1"):find("NVMe SSD"), "nvme kind")
        local root = find_item(g, "/")
        assert_true(root and root:find("ext4") and root:find("%%"), tostring(root))
        local gone = find_item(g, "/nonexistent_mnt")
        assert_true(gone and gone:find("statvfs unavailable"), "failed statvfs is visible")
        assert_true(find_item(g, "/run") == nil, "tmpfs skipped")
    end)

    it("network: interface state, MAC, speed, MTU", function()
        local g = HW.collect_network()
        local eth = find_item(g, "eth0")
        assert_true(eth and eth:find("up") and eth:find("aa:bb:cc:dd:ee:ff")
            and eth:find("1000 Mb/s") and eth:find("mtu 1500"), tostring(eth))
    end)

    it("sensors: temp, fan, battery health, mains", function()
        local g = HW.collect_sensors()
        assert_eq(find_item(g, "Package id 0"), "45.5 °C")
        assert_eq(find_item(g, "fan1"), "2400 RPM")
        local bat = find_item(g, "BAT0")
        assert_true(bat and bat:find("Charging") and bat:find("80%%") and bat:find("health 80%%"),
            tostring(bat))
        assert_true(find_item(g, "AC"):find("online"), "AC online")
    end)

    it("usb: skips interface entries, shows ids and names", function()
        local g = HW.collect_usb()
        local dev = find_item(g, "1-1")
        assert_true(dev and dev:find("%[046d:c52b%]") and dev:find("Logitech")
            and dev:find("12 Mb/s"), tostring(dev))
        assert_true(find_item(g, "1-1:1.0") == nil, "interface skipped")
    end)

    it("smbios parser rejects short or wrong-type data", function()
        assert_true(HW.parse_smbios_type17("") == nil, "empty")
        assert_true(HW.parse_smbios_type17(string.char(4) .. string.rep("\0", 40)) == nil,
            "wrong type")
    end)
end)

describe("2. Failure paths (missing / malformed data)", function()
    it("missing root: every collector returns visible N/A, no crash", function()
        HW.root = ROOT .. "/does/not/exist"
        for _, tab in ipairs(HW.TABS) do
            local groups = HW.safe_collect(tab)
            assert_true(#groups > 0, tab.id .. " returned no groups")
            local any = false
            for _, g in ipairs(groups) do
                assert_true(#g.items > 0, tab.id .. " has an empty group")
                any = true
            end
            assert_true(any, tab.id)
        end
        local cpu = HW.collect_cpu()
        assert_true(find_item(cpu, "Model"):find("N/A"), "cpu N/A text")
    end)

    it("malformed cpuinfo and meminfo do not crash", function()
        HW.root = ROOT
        write_file("/proc/cpuinfo", "garbage\n\n:::\nprocessor\n")
        write_file("/proc/meminfo", "MemTotal: lots\n")
        assert_true(#HW.collect_cpu() > 0, "cpu survives")
        assert_true(#HW.collect_memory() > 0, "memory survives")
    end)

    it("crashing collector becomes an Error group", function()
        local groups = HW.safe_collect({ id = "boom", collect = function()
            error("kaput")
        end })
        assert_true(find_item(groups, "Collector"):find("kaput"), "error text kept")
    end)

    it("unreadable SMBIOS entries report root requirement", function()
        HW.root = ROOT
        os.execute("chmod 000 " .. shell_quote(ROOT .. "/sys/firmware/dmi/entries/17-0/raw"))
        local g = HW.collect_memory()
        local v = find_item(g, "DIMMs")
        os.execute("chmod 644 " .. shell_quote(ROOT .. "/sys/firmware/dmi/entries/17-0/raw"))
        if io.open("/proc/self/status") and tostring(os.getenv("USER")) ~= "root" then
            assert_true(v and v:find("needs root"), tostring(v))
        end
    end)
end)

describe("3. Frame rendering across sizes and data", function()
    HW.root = ROOT
    write_file("/proc/cpuinfo", "processor : 0\nmodel name : X\nflags : a b c\n")
    local data = HW.collect_all()
    local sizes = { { 24, 7 }, { 40, 10 }, { 80, 24 }, { 200, 60 }, { 30, 100 } }

    it("renders every tab at every size with row/width invariants", function()
        for _, sz in ipairs(sizes) do
            local w, h = sz[1], sz[2]
            for t = 1, #data do
                local state = HW.helpers.new_state(data)
                state.tab = t
                local rows = HW.frame_rows(state, w, h)
                assert_eq(#rows, h, "row count at " .. w .. "x" .. h)
                for i, row in ipairs(rows) do
                    local plain = strip_ansi(row)
                    assert_true(HW.helpers.ulen(plain) <= w - 1,
                        string.format("row %d too wide (%d) at %dx%d tab %d", i,
                            HW.helpers.ulen(plain), w, h, t))
                end
                local frame = HW.render_frame(state, w, h)
                assert_true(frame:find("\27[?2026h", 1, true), "sync start")
                assert_true(frame:find("\27[?2026l", 1, true), "sync end")
                assert_true(not frame:find("\27[2J", 1, true), "no full clear on render")
            end
        end
    end)

    it("every addressed row ends with clear-to-EOL", function()
        local state = HW.helpers.new_state(data)
        local frame = HW.render_frame(state, 80, 24)
        local count = 0
        for line in frame:gmatch("\27%[%d+;1H[^\27]*.-\27%[K") do
            count = count + 1
        end
        assert_eq(count, 24, "24 rows each cleared")
    end)

    it("too-small terminal shows a message instead of crashing", function()
        local state = HW.helpers.new_state(data)
        local rows = HW.frame_rows(state, 30, 3)
        assert_true(strip_ansi(rows[1]):find("too small"), "message")
    end)

    it("long, wide and special strings are truncated safely", function()
        local long = {
            { id = "x", title = "Long", groups = { { title = "T" .. string.rep("é", 300),
                items = { { label = string.rep("L", 80), value = string.rep("ü中", 200) },
                    { label = "fmt", value = "100% %s %d" .. string.rep("w", 400) } } } } },
        }
        local state = HW.helpers.new_state(long)
        for _, sz in ipairs(sizes) do
            local rows = HW.frame_rows(state, sz[1], sz[2])
            for _, row in ipairs(rows) do
                assert_true(HW.helpers.ulen(strip_ansi(row)) <= sz[1] - 1, "width")
            end
        end
    end)

    it("empty data renders an empty-state row", function()
        local state = HW.helpers.new_state({ { id = "e", title = "Empty", groups = {} } })
        local rows = HW.frame_rows(state, 80, 24)
        assert_true(strip_ansi(rows[3]):find("no matching"), "empty placeholder")
    end)
end)

describe("4. Keystroke simulation & state machine", function()
    HW.root = ROOT
    local data = HW.collect_all()

    local function feed(state, keys)
        local action
        for _, k in ipairs(keys) do
            action = HW.handle_key(state, k, 80, 24) or action
        end
        return action
    end

    it("tab navigation wraps and number keys jump", function()
        local s = HW.helpers.new_state(data)
        feed(s, { "RIGHT" })
        assert_eq(s.tab, 2)
        feed(s, { "LEFT", "LEFT" })
        assert_eq(s.tab, #data, "wraps backwards")
        feed(s, { "RIGHT" })
        assert_eq(s.tab, 1, "wraps forwards")
        feed(s, { "5" })
        assert_eq(s.tab, 5)
        feed(s, { "9" })
        assert_eq(s.tab, 5, "out-of-range number ignored")
    end)

    it("scroll stays within bounds at both ends", function()
        local s = HW.helpers.new_state(data)
        s.tab = 4
        feed(s, { "UP", "UP" })
        assert_eq(s.scroll[4], 0, "clamped at top")
        HW.handle_key(s, "END", 40, 10)
        local lines = HW.flatten(data[4].groups, 39, "")
        assert_eq(s.scroll[4], math.max(0, #lines - 6), "clamped at bottom")
        HW.handle_key(s, "DOWN", 40, 10)
        HW.handle_key(s, "PAGE_DOWN", 40, 10)
        assert_eq(s.scroll[4], math.max(0, #lines - 6), "no overscroll")
    end)

    it("filter mode: SPACE, BACKSPACE, ENTER, ESC tokens", function()
        local s = HW.helpers.new_state(data)
        s.tab = 5
        feed(s, { "/", "n", "v", "m", "e" })
        assert_true(s.filter_mode, "in filter mode")
        assert_eq(s.filter, "nvme")
        feed(s, { "SPACE", "x", "BACKSPACE", "BACKSPACE" })
        assert_eq(s.filter, "nvme")
        feed(s, { "BACKSPACE", "BACKSPACE", "BACKSPACE", "BACKSPACE", "BACKSPACE" })
        assert_eq(s.filter, "", "backspace at index 0 is safe")
        feed(s, { "s", "d", "a", "ENTER" })
        assert_true(not s.filter_mode, "ENTER leaves filter mode")
        assert_eq(s.filter, "sda")
        local rows = HW.frame_rows(s, 80, 24)
        local text = strip_ansi(table.concat(rows, "\n"))
        assert_true(text:find("sda") and not text:find("nvme0n1"), "filter applied")
        feed(s, { "ESC" })
        assert_eq(s.filter, "", "ESC clears filter")
    end)

    it("filter accepts multi-byte characters and deletes them whole", function()
        local s = HW.helpers.new_state(data)
        feed(s, { "/", "é", "中", "BACKSPACE" })
        assert_eq(s.filter, "é")
        feed(s, { "BACKSPACE" })
        assert_eq(s.filter, "")
    end)

    it("symbolic tokens are not typed into the filter", function()
        local s = HW.helpers.new_state(data)
        feed(s, { "/", "UP", "DOWN", "TAB", "a" })
        assert_eq(s.filter, "a")
    end)

    it("burst input is split into tokens without dropping keys", function()
        local seq = {}
        local rest = "q\27[C\27[6~ \r\127é\27x"
        while rest ~= "" do
            local tok
            tok, rest = HW.next_token(rest)
            seq[#seq + 1] = tok
        end
        assert_eq(table.concat(seq, ","), "q,RIGHT,PAGE_DOWN,SPACE,ENTER,BACKSPACE,é,ESC,x")
    end)

    it("q / r / e return actions", function()
        local s = HW.helpers.new_state(data)
        assert_eq(feed(s, { "q" }), "quit")
        assert_eq(feed(s, { "r" }), "refresh")
        assert_eq(feed(s, { "e" }), "export")
        assert_eq(HW.handle_key(s, nil), nil, "nil key ignored")
    end)

    it("tab round trip preserves per-tab scroll and filter", function()
        local s = HW.helpers.new_state(data)
        s.tab = 4
        feed(s, { "DOWN", "DOWN" })
        local before = s.scroll[4]
        feed(s, { "RIGHT", "LEFT" })
        assert_eq(s.scroll[4], before, "scroll preserved")
    end)

    it("differential refresh rewrites only changed rows, no ghost text", function()
        local s = HW.helpers.new_state(data)
        s.tab = 4
        local prev = HW.frame_rows(s, 80, 24)
        local same = HW.diff_frame(prev, HW.frame_rows(s, 80, 24))
        assert_eq(same, "", "identical frame emits nothing")
        s.filter = "zzz-no-match"
        local rows = HW.frame_rows(s, 80, 24)
        local out = HW.diff_frame(prev, rows)
        assert_true(not out:find("\27[2J", 1, true), "no clear")
        for i = 4, 21 do
            if prev[i] ~= "" then
                assert_true(out:find(string.format("\27[%d;1H", i), 1, true),
                    "stale row " .. i .. " was overwritten")
            end
        end
        for i, row in ipairs(rows) do
            if i > 3 and i < 22 then
                assert_eq(strip_ansi(row):gsub(" ", ""), "", "row " .. i .. " blank")
            end
        end
    end)
end)

describe("5. JSON export and text report", function()
    HW.root = ROOT
    write_file("/proc/cpuinfo", "processor : 0\nmodel name : Quote \"Test\" \\ CPU\n")
    local data = HW.collect_all()

    it("JSON is well-formed enough to round trip through a verifier", function()
        local json = HW.to_json(data)
        assert_true(json:find('"tabs":%['), "root key")
        assert_true(json:find('Quote \\"Test\\" \\\\ CPU', 1, true), "escaping")
        local depth = 0
        local in_str, esc = false, false
        for c in json:gmatch(".") do
            if in_str then
                if esc then
                    esc = false
                elseif c == "\\" then
                    esc = true
                elseif c == '"' then
                    in_str = false
                end
            elseif c == '"' then
                in_str = true
            elseif c == "{" or c == "[" then
                depth = depth + 1
            elseif c == "}" or c == "]" then
                depth = depth - 1
            end
        end
        assert_eq(depth, 0, "balanced brackets")
    end)

    it("export writes and verifies the file", function()
        local path = ROOT .. "/snapshot.json"
        local ok, msg = HW.export_json(data, path)
        assert_true(ok, msg)
        assert_true(msg:find(path, 1, true), "message names the path")
    end)

    it("export to an unwritable path fails visibly", function()
        local ok, msg = HW.export_json(data, ROOT .. "/no/such/dir/out.json")
        assert_true(not ok, "should fail")
        assert_true(msg:find("cannot write") and msg:find("no/such/dir"), msg)
    end)

    it("text report lists all tabs", function()
        local text = HW.text_report(data, 100)
        for _, tab in ipairs(HW.TABS) do
            assert_true(text:find("== " .. tab.title .. " ==", 1, true), tab.title)
        end
    end)
end)

describe("6. CLI behaviour (subprocess)", function()
    local function run(cmd)
        local ok, how, code = os.execute(cmd)
        if type(ok) == "number" then
            return ok == 0 and 0 or ok / 256
        end
        return code or (ok and 0 or 1), how
    end
    local pwd = io.popen("pwd"):read("*l")
    local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
    if script_dir:sub(1, 1) ~= "/" then
        script_dir = pwd .. "/" .. script_dir
    end
    local script = script_dir .. "/hwinfo_tui.lua"

    it("unknown option exits 2 with a stderr message", function()
        local f = io.popen("luajit " .. script .. " --bogus 2>&1 >/dev/null; echo rc=$?")
        local out = f:read("*a")
        f:close()
        assert_true(out:find("unknown option") and out:find("rc=2"), out)
    end)

    it("invalid --tab exits 2", function()
        local f = io.popen("luajit " .. script .. " --tab nope 2>&1 >/dev/null; echo rc=$?")
        local out = f:read("*a")
        f:close()
        assert_true(out:find("invalid %-%-tab") and out:find("rc=2"), out)
    end)

    it("--json prints a snapshot using the fixture root", function()
        local f = io.popen("HWINFO_ROOT=" .. shell_quote(ROOT) .. " luajit " .. script
            .. " --json")
        local out = f:read("*a")
        f:close()
        assert_true(out:find('"id":"cpu"', 1, true), "cpu tab in json")
    end)

    it("headless pipeline: piped 'q' starts, renders and exits 0", function()
        local f = io.popen("printf q | luajit " .. script .. " 2>/dev/null; echo rc=$?")
        local out = f:read("*a")
        f:close()
        assert_true(out:find("rc=0"), out:sub(-200))
        assert_true(out:find("HWINFO", 1, true), "frame was rendered")
    end)

    it("headless keystrokes: tab switch, filter, export, quit", function()
        local dir = ROOT .. "/cwd"
        os.execute("mkdir -p " .. shell_quote(dir))
        local f = io.popen("cd " .. shell_quote(dir) .. " && printf '2/ab\\x7fc\\recq' | luajit "
            .. script .. " 2>/dev/null; echo rc=$?; ls " .. shell_quote(dir))
        local out = f:read("*a")
        f:close()
        assert_true(out:find("rc=0"), out:sub(-200))
        assert_true(out:find("hwinfo_snapshot.json", 1, true), "export file created")
    end)

    it("no undeclared globals in bytecode", function()
        local f = io.popen("luajit -bl " .. script .. " 2>&1")
        local out = f:read("*a")
        f:close()
        local allowed = { ipairs = 1, pairs = 1, pcall = 1, tostring = 1, tonumber = 1,
            type = 1, string = 1, table = 1, math = 1, io = 1, os = 1, require = 1,
            arg = 1, error = 1, select = 1, assert = 1 }
        for name in out:gmatch('GGET%s+%d+%s+%d+%s+;%s+"([^"]+)"') do
            assert_true(allowed[name], "undeclared global: " .. name)
        end
    end)
end)

os.execute("chmod -R u+rwx " .. shell_quote(ROOT) .. " && rm -rf " .. shell_quote(ROOT))

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
