#!/usr/bin/env luajit
--[[
    hwinfo_tui.lua
    Tabbed terminal hardware inventory viewer written in LuaJIT with FFI (Linux).

    Features:
    - Eight tabs: System, CPU, Memory, GPU/PCI, Storage, Network, Sensors, USB.
    - Zero-fork data collection: direct /sys and /proc reads plus libc FFI
      (uname, statvfs, readlink, opendir/readdir, getifaddrs, termios, poll).
    - Differential, flicker-free rendering: pure frame generators, per-row diffing,
      synchronized-update escapes, one atomic write per frame, no screen clears
      on user actions.
    - Filter (/), scrolling, tab switching, auto refresh, JSON snapshot export (e).
    - Dual mode: CLI tool and reusable module (local HW = require("hwinfo_tui")).

    Usage:
        luajit hwinfo_tui.lua [--tab <name>] [--json] [--text] [--help]

    Environment:
        HWINFO_ROOT   Prefix prepended to every /sys and /proc path (used by tests
                      to read fixture trees instead of the live system).
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. C Declarations
-- =========================================================================
ffi.cdef[[
    struct hw_utsname {
        char sysname[65];
        char nodename[65];
        char release[65];
        char version[65];
        char machine[65];
        char domainname[65];
    };
    int uname(struct hw_utsname *buf);

    struct hw_statvfs {
        unsigned long f_bsize;
        unsigned long f_frsize;
        unsigned long f_blocks;
        unsigned long f_bfree;
        unsigned long f_bavail;
        unsigned long f_files;
        unsigned long f_ffree;
        unsigned long f_favail;
        unsigned long f_fsid;
        unsigned long f_flag;
        unsigned long f_namemax;
        int           __f_spare[6];
    };
    int statvfs(const char *path, struct hw_statvfs *buf);

    long readlink(const char *path, char *buf, size_t bufsiz);

    typedef struct hw_DIR hw_DIR;
    struct hw_dirent {
        unsigned long  d_ino;
        long           d_off;
        unsigned short d_reclen;
        unsigned char  d_type;
        char           d_name[256];
    };
    hw_DIR *opendir(const char *name);
    struct hw_dirent *readdir(hw_DIR *dirp);
    int closedir(hw_DIR *dirp);

    struct hw_sockaddr {
        unsigned short sa_family;
        unsigned char  sa_data[14];
    };
    struct hw_ifaddrs {
        struct hw_ifaddrs  *ifa_next;
        char               *ifa_name;
        unsigned int        ifa_flags;
        struct hw_sockaddr *ifa_addr;
    };
    int getifaddrs(struct hw_ifaddrs **ifap);
    void freeifaddrs(struct hw_ifaddrs *ifa);

    struct hw_winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };
    int ioctl(int fd, unsigned long request, void *argp);
    int isatty(int fd);

    struct hw_termios {
        unsigned int  c_iflag;
        unsigned int  c_oflag;
        unsigned int  c_cflag;
        unsigned int  c_lflag;
        unsigned char c_line;
        unsigned char c_cc[32];
        unsigned int  c_ispeed;
        unsigned int  c_ospeed;
    };
    int tcgetattr(int fd, struct hw_termios *termios_p);
    int tcsetattr(int fd, int optional_actions, const struct hw_termios *termios_p);

    struct hw_pollfd {
        int   fd;
        short events;
        short revents;
    };
    int poll(struct hw_pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, size_t count);

    int open(const char *pathname, int flags, ...);
    int close(int fd);

    struct hw_nvme_admin_cmd {
        uint8_t  opcode;
        uint8_t  flags;
        uint16_t rsvd1;
        uint32_t nsid;
        uint32_t cdw2;
        uint32_t cdw3;
        uint64_t metadata;
        uint64_t addr;
        uint32_t metadata_len;
        uint32_t data_len;
        uint32_t cdw10;
        uint32_t cdw11;
        uint32_t cdw12;
        uint32_t cdw13;
        uint32_t cdw14;
        uint32_t cdw15;
        uint32_t timeout_ms;
        uint32_t result;
    };

    typedef void (*hw_sighandler_t)(int);
    hw_sighandler_t signal(int signum, hw_sighandler_t handler);
]]

local HW = {}
HW.root = os.getenv("HWINFO_ROOT") or ""

-- =========================================================================
-- 2. Low-level helpers (files, directories, strings)
-- =========================================================================
local function clean(s)
    if s == nil then
        return nil
    end
    s = tostring(s):gsub("%z", ""):gsub("[%c]", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function sys_path(path)
    return HW.root .. path
end

--- Read a whole file; returns the content or nil plus an error string.
local function read_raw(path)
    local f, err = io.open(sys_path(path), "rb")
    if not f then
        return nil, err
    end
    local data = f:read("*a")
    f:close()
    if data == nil then
        return nil, "read failed: " .. path
    end
    return data
end

--- Read a file as a cleaned single-line string; nil when absent or empty.
local function read_str(path)
    local data = read_raw(path)
    if not data then
        return nil
    end
    local s = clean(data)
    if s == "" then
        return nil
    end
    return s
end

local function read_num(path)
    local s = read_str(path)
    if not s then
        return nil
    end
    return tonumber(s)
end

--- List directory entries (sorted, without . and ..); nil when unreadable.
local function list_dir(path)
    local dir = ffi.C.opendir(sys_path(path))
    if dir == nil then
        return nil
    end
    local names = {}
    while true do
        local ent = ffi.C.readdir(dir)
        if ent == nil then
            break
        end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    ffi.C.closedir(dir)
    table.sort(names, function(a, b)
        local pa, da = a:match("^(%D*)(%d+)$")
        local pb, db = b:match("^(%D*)(%d+)$")
        if da and db and pa == pb then
            return tonumber(da) < tonumber(db)
        end
        return a < b
    end)
    return names
end

--- Basename of a symlink target (e.g. a device's driver); nil when not a link.
local function link_base(path)
    local buf = ffi.new("char[512]")
    local n = ffi.C.readlink(sys_path(path), buf, 511)
    if n <= 0 then
        return nil
    end
    return ffi.string(buf, n):match("([^/]+)$")
end

local function format_bytes(n)
    if not n then
        return "N/A"
    end
    local units = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" }
    local idx = 1
    while n >= 1024 and idx < #units do
        n = n / 1024
        idx = idx + 1
    end
    if idx == 1 then
        return string.format("%d B", n)
    end
    return string.format("%.1f %s", n, units[idx])
end

local function format_uptime(sec)
    sec = math.floor(sec)
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    if d > 0 then
        return string.format("%dd %dh %dm", d, h, m)
    end
    return string.format("%dh %dm", h, m)
end

local function new_group(title)
    return { title = title, items = {} }
end

--- Append a label/value row; rows with a nil value are skipped.
local function add(group, label, value, key, num)
    if value == nil then
        return
    end
    group.items[#group.items + 1] = {
        label = label,
        value = tostring(value),
        key = key,
        num = num,
    }
end

--- Append a row using `fallback` when the value is missing (never silent).
local function add_na(group, label, value, fallback)
    if value == nil then
        value = fallback or "N/A"
    end
    add(group, label, value)
end

-- =========================================================================
-- 3. Collectors (each returns a list of groups)
-- =========================================================================
local CHASSIS = {
    [1] = "Other", [2] = "Unknown", [3] = "Desktop", [4] = "Low Profile Desktop",
    [6] = "Mini Tower", [7] = "Tower", [8] = "Portable", [9] = "Laptop",
    [10] = "Notebook", [11] = "Handheld", [13] = "All-in-One", [14] = "Sub Notebook",
    [15] = "Space-saving", [16] = "Lunch Box", [17] = "Main Server",
    [23] = "Rack Mount", [30] = "Tablet", [31] = "Convertible", [32] = "Detachable",
    [35] = "Mini PC", [36] = "Stick PC",
}

function HW.collect_system()
    local groups = {}
    local ident = new_group("Machine")
    local dmi = "/sys/class/dmi/id/"
    add_na(ident, "Vendor", read_str(dmi .. "sys_vendor"), "N/A (no DMI)")
    add_na(ident, "Product", read_str(dmi .. "product_name"), "N/A (no DMI)")
    add(ident, "Version", read_str(dmi .. "product_version"))
    local chassis = read_num(dmi .. "chassis_type")
    if chassis then
        add(ident, "Chassis", CHASSIS[chassis] or ("Type " .. chassis))
    end
    groups[#groups + 1] = ident

    local board = new_group("Mainboard & Firmware")
    add_na(board, "Board", read_str(dmi .. "board_name"), "N/A (no DMI)")
    add(board, "Board vendor", read_str(dmi .. "board_vendor"))
    add(board, "Board version", read_str(dmi .. "board_version"))
    add_na(board, "BIOS vendor", read_str(dmi .. "bios_vendor"), "N/A (no DMI)")
    add(board, "BIOS version", read_str(dmi .. "bios_version"))
    add(board, "BIOS date", read_str(dmi .. "bios_date"))
    local uefi = list_dir("/sys/firmware/efi")
    add(board, "Boot mode", uefi and "UEFI" or "Legacy BIOS / unknown")
    groups[#groups + 1] = board

    local os_group = new_group("Operating System")
    local u = ffi.new("struct hw_utsname")
    if ffi.C.uname(u) == 0 then
        add(os_group, "Kernel", ffi.string(u.sysname) .. " " .. ffi.string(u.release))
        add(os_group, "Hostname", ffi.string(u.nodename))
        add(os_group, "Architecture", ffi.string(u.machine))
    else
        add(os_group, "Kernel", "N/A (uname failed)")
    end
    local rel = read_raw("/etc/os-release")
    if rel then
        add(os_group, "Distribution", rel:match('PRETTY_NAME="?([^"\n]+)"?'))
    end
    local up = read_str("/proc/uptime")
    if up and tonumber(up:match("^(%S+)")) then
        add(os_group, "Uptime", format_uptime(tonumber(up:match("^(%S+)"))))
    end
    groups[#groups + 1] = os_group
    return groups
end

function HW.parse_cpuinfo(text)
    local info = { logical = 0, cores = {}, flags = nil, model = nil, mhz = nil }
    local phys, core = nil, nil
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local key, val = line:match("^([^:]-)%s*:%s*(.*)$")
        if key then
            if key == "processor" then
                info.logical = info.logical + 1
            elseif key == "model name" or key == "Model" or key == "Hardware" then
                info.model = info.model or clean(val)
            elseif key == "vendor_id" then
                info.vendor = info.vendor or clean(val)
            elseif key == "flags" or key == "Features" then
                info.flags = info.flags or clean(val)
            elseif key == "cpu MHz" then
                info.mhz = info.mhz or tonumber(val)
            elseif key == "physical id" then
                phys = val
            elseif key == "core id" then
                core = val
                info.cores[(phys or "0") .. ":" .. core] = true
            end
        end
    end
    local n = 0
    for _ in pairs(info.cores) do
        n = n + 1
    end
    info.physical = n
    return info
end

function HW.collect_cpu()
    local groups = {}
    local text, err = read_raw("/proc/cpuinfo")
    local g = new_group("Processor")
    if not text then
        add(g, "Model", "N/A (cannot read /proc/cpuinfo: " .. tostring(err) .. ")")
        return { g }
    end
    local info = HW.parse_cpuinfo(text)
    add_na(g, "Model", info.model)
    add(g, "Vendor", info.vendor)
    add(g, "Threads", info.logical)
    if info.physical > 0 then
        add(g, "Cores", info.physical)
    end
    groups[#groups + 1] = g

    local freq = new_group("Frequency")
    local base = "/sys/devices/system/cpu/cpu0/cpufreq/"
    local min = read_num(base .. "cpuinfo_min_freq")
    local max = read_num(base .. "cpuinfo_max_freq")
    local cur = read_num(base .. "scaling_cur_freq")
    if min and max then
        add(freq, "Range", string.format("%.0f MHz - %.0f MHz", min / 1000, max / 1000))
    end
    if cur then
        add(freq, "Current", string.format("%.0f MHz", cur / 1000))
    elseif info.mhz then
        add(freq, "Current", string.format("%.0f MHz", info.mhz))
    end
    add(freq, "Governor", read_str(base .. "scaling_governor"))
    add(freq, "Driver", read_str(base .. "scaling_driver"))
    if #freq.items == 0 then
        add(freq, "Scaling", "N/A (cpufreq not exposed)")
    end
    groups[#groups + 1] = freq

    local cache = new_group("Cache (cpu0)")
    local entries = list_dir("/sys/devices/system/cpu/cpu0/cache") or {}
    for _, name in ipairs(entries) do
        if name:match("^index%d+$") then
            local dir = "/sys/devices/system/cpu/cpu0/cache/" .. name .. "/"
            local level = read_str(dir .. "level")
            local kind = read_str(dir .. "type")
            local size = read_str(dir .. "size")
            if level and size then
                add(cache, "L" .. level .. " " .. (kind or ""), size)
            end
        end
    end
    if #cache.items == 0 then
        add(cache, "Cache", "N/A (not exposed)")
    end
    groups[#groups + 1] = cache

    if info.flags then
        local fg = new_group("Flags")
        add(fg, "Flags", info.flags)
        groups[#groups + 1] = fg
    end
    return groups
end

--- Parse one raw SMBIOS type 17 (Memory Device) structure.
function HW.parse_smbios_type17(raw)
    if #raw < 0x1B or raw:byte(1) ~= 17 then
        return nil
    end
    local len = raw:byte(2)
    local strings = {}
    for s in raw:sub(len + 1):gmatch("([^%z]+)") do
        strings[#strings + 1] = s
    end
    local function word(off)
        return raw:byte(off + 1) + raw:byte(off + 2) * 256
    end
    local function str(off)
        local idx = raw:byte(off + 1)
        return idx and idx > 0 and strings[idx] or nil
    end
    local size_raw = word(0x0C)
    local size_mb = nil
    if size_raw ~= 0 and size_raw ~= 0xFFFF then
        if size_raw == 0x7FFF and len >= 0x20 then
            size_mb = raw:byte(0x1C + 1) + raw:byte(0x1D + 1) * 256
        elseif bit.band(size_raw, 0x8000) ~= 0 then
            size_mb = bit.band(size_raw, 0x7FFF) / 1024
        else
            size_mb = size_raw
        end
    end
    local types = { [0x1A] = "DDR4", [0x1B] = "LPDDR", [0x1C] = "LPDDR2", [0x1D] = "LPDDR3",
        [0x1E] = "LPDDR4", [0x22] = "DDR5", [0x23] = "LPDDR5", [0x18] = "DDR3", [0x13] = "DDR2" }
    return {
        locator = str(0x10),
        size_mb = size_mb,
        type = types[raw:byte(0x12 + 1)],
        speed = word(0x15) > 0 and word(0x15) or nil,
        manufacturer = str(0x17),
        part = str(0x1A) and clean(str(0x1A)) or nil,
    }
end

function HW.collect_memory()
    local groups = {}
    local g = new_group("Capacity")
    local text, err = read_raw("/proc/meminfo")
    if not text then
        add(g, "Memory", "N/A (cannot read /proc/meminfo: " .. tostring(err) .. ")")
        return { g }
    end
    local function kib(key)
        local v = text:match("\n?" .. key .. ":%s*(%d+)%s*kB")
        return v and tonumber(v) * 1024 or nil
    end
    local total, avail = kib("MemTotal"), kib("MemAvailable")
    add(g, "Total", format_bytes(total))
    if total and avail then
        local used = total - avail
        add(g, "Used", string.format("%s (%.0f%%)", format_bytes(used), used * 100 / total))
        add(g, "Available", format_bytes(avail))
    end
    add(g, "Cached", kib("Cached") and format_bytes(kib("Cached")) or nil)
    local swap_total, swap_free = kib("SwapTotal"), kib("SwapFree")
    if swap_total then
        add(g, "Swap", string.format("%s (free %s)", format_bytes(swap_total),
            format_bytes(swap_free)))
    end
    add(g, "Huge pages", kib("Hugepagesize") and format_bytes(kib("Hugepagesize")) or nil)
    groups[#groups + 1] = g

    local dimms = new_group("Memory Modules (SMBIOS)")
    local entries = list_dir("/sys/firmware/dmi/entries") or {}
    local seen = 0
    local denied = false
    for _, name in ipairs(entries) do
        if name:match("^17%-%d+$") then
            local raw = read_raw("/sys/firmware/dmi/entries/" .. name .. "/raw")
            if raw then
                local d = HW.parse_smbios_type17(raw)
                if d then
                    seen = seen + 1
                    local desc = d.size_mb and format_bytes(d.size_mb * 1024 * 1024) or "empty"
                    if d.type then
                        desc = desc .. " " .. d.type
                    end
                    if d.speed then
                        desc = desc .. " @" .. d.speed .. " MT/s"
                    end
                    if d.manufacturer then
                        desc = desc .. " " .. clean(d.manufacturer)
                    end
                    if d.part then
                        desc = desc .. " " .. d.part
                    end
                    add(dimms, d.locator or name, desc)
                end
            else
                denied = true
            end
        end
    end
    if seen == 0 then
        if denied then
            add(dimms, "DIMMs", "N/A (needs root to read /sys/firmware/dmi/entries)")
        else
            add(dimms, "DIMMs", "N/A (no SMBIOS memory entries exposed)")
        end
    end
    groups[#groups + 1] = dimms
    return groups
end

local PCI_CLASSES = {
    ["0300"] = "VGA controller", ["0302"] = "3D controller", ["0380"] = "Display controller",
    ["0108"] = "NVMe controller", ["0106"] = "SATA controller", ["0200"] = "Ethernet controller",
    ["0280"] = "Network controller", ["0403"] = "Audio device", ["0401"] = "Multimedia audio",
    ["0600"] = "Host bridge", ["0601"] = "ISA bridge", ["0604"] = "PCI bridge",
    ["0c03"] = "USB controller", ["0c05"] = "SMBus", ["0d11"] = "Bluetooth",
}
local PCI_BASE = {
    ["00"] = "Unclassified", ["01"] = "Storage", ["02"] = "Network", ["03"] = "Display",
    ["04"] = "Multimedia", ["05"] = "Memory", ["06"] = "Bridge", ["07"] = "Communication",
    ["08"] = "System peripheral", ["09"] = "Input", ["0b"] = "Processor",
    ["0c"] = "Serial bus", ["0d"] = "Wireless", ["10"] = "Encryption",
    ["11"] = "Signal processing", ["12"] = "Accelerator",
}

--- Resolve vendor/device names from pci.ids for the wanted vendor set.
function HW.load_pci_names(wanted)
    local names = { vendors = {}, devices = {} }
    local f
    for _, p in ipairs({ "/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids" }) do
        f = io.open(sys_path(p), "rb")
        if f then
            break
        end
    end
    if not f then
        return names
    end
    local cur = nil
    for line in f:lines() do
        local vid, vname = line:match("^(%x%x%x%x)%s%s(.+)$")
        if vid then
            cur = wanted[vid] and vid or nil
            if cur then
                names.vendors[vid] = vname
            end
        elseif cur then
            local did, dname = line:match("^\t(%x%x%x%x)%s%s(.+)$")
            if did then
                names.devices[cur .. ":" .. did] = dname
            end
        end
    end
    f:close()
    return names
end

-- GPU details, displays (EDID) -------------------------------------------
--- Parse the interesting fields of a 128-byte EDID block; nil when invalid.
function HW.parse_edid(raw)
    if #raw < 128 or raw:sub(1, 8) ~= "\0\255\255\255\255\255\255\0" then
        return nil
    end
    local id = raw:byte(9) * 256 + raw:byte(10)
    local function letter(shift)
        return string.char(64 + bit.band(bit.rshift(id, shift), 31))
    end
    local info = {
        mfr = letter(10) .. letter(5) .. letter(0),
        product = raw:byte(11) + raw:byte(12) * 256,
        width_cm = raw:byte(22),
        height_cm = raw:byte(23),
        year = 1990 + raw:byte(18),
    }
    for off = 55, 109, 18 do
        if raw:byte(off) == 0 and raw:byte(off + 1) == 0 and raw:byte(off + 3) == 0xFC then
            info.name = clean(raw:sub(off + 5, off + 17):match("^[^\n]*"))
        end
    end
    return info
end

function HW.collect_displays()
    local g = new_group("Displays")
    local entries = list_dir("/sys/class/drm") or {}
    for _, name in ipairs(entries) do
        local conn = name:match("^card%d+%-(.+)$")
        if conn then
            local dir = "/sys/class/drm/" .. name .. "/"
            if read_str(dir .. "status") == "connected" then
                local parts = { "connected" }
                local modes = read_raw(dir .. "modes")
                local mode = modes and modes:match("^(%S+)")
                parts[#parts + 1] = mode
                local raw = read_raw(dir .. "edid")
                local edid = raw and HW.parse_edid(raw)
                if edid then
                    parts[#parts + 1] = edid.name and (edid.name .. " (" .. edid.mfr .. ")")
                        or edid.mfr
                    if edid.width_cm > 0 and edid.height_cm > 0 then
                        local diag = math.sqrt(edid.width_cm ^ 2 + edid.height_cm ^ 2) / 2.54
                        parts[#parts + 1] = string.format("%dx%d cm (%.1f\")", edid.width_cm,
                            edid.height_cm, diag)
                    end
                end
                add(g, conn, table.concat(parts, "  "))
            end
        end
    end
    if #g.items == 0 then
        add(g, "Displays", "N/A (no connected outputs in /sys/class/drm)")
    end
    return g
end

local function pcie_link(dir)
    local cur, curw = read_str(dir .. "current_link_speed"), read_str(dir .. "current_link_width")
    local max, maxw = read_str(dir .. "max_link_speed"), read_str(dir .. "max_link_width")
    if not cur or not curw or cur:find("Unknown", 1, true) or curw == "0" then
        return nil
    end
    local text = string.format("%s x%s", cur, curw)
    if max and maxw and (max ~= cur or maxw ~= curw) then
        text = text .. string.format(" (max %s x%s)", max, maxw)
    end
    return text
end

--- Per-GPU live details: PCIe link, clocks, utilization, VRAM, temperature.
function HW.collect_gpu_details()
    local groups = {}
    local entries = list_dir("/sys/class/drm") or {}
    for _, name in ipairs(entries) do
        if name:match("^card%d+$") then
            local dir = "/sys/class/drm/" .. name .. "/"
            local dev = dir .. "device/"
            local g = new_group("GPU Details (" .. name .. ")")
            add(g, "Driver", link_base(dev .. "driver"))
            add(g, "PCIe link", pcie_link(dev))
            -- Intel i915/xe
            local cur = read_num(dir .. "gt_cur_freq_mhz")
            if cur then
                local act = read_num(dir .. "gt_act_freq_mhz")
                local lo, hi = read_num(dir .. "gt_min_freq_mhz"), read_num(dir .. "gt_max_freq_mhz")
                add(g, "GT frequency", string.format("requested %d MHz%s  (range %s-%s MHz)", cur,
                    act and (", actual " .. act .. " MHz") or "", tostring(lo or "?"),
                    tostring(hi or "?")), name .. "/gt_freq", act or cur)
                g.items[#g.items].unit = "MHz"
            end
            -- AMD amdgpu
            local busy = read_num(dev .. "gpu_busy_percent")
            if busy then
                add(g, "Utilization", busy .. " %", name .. "/busy", busy)
                g.items[#g.items].unit = "%"
            end
            local vram_used, vram_total = read_num(dev .. "mem_info_vram_used"),
                read_num(dev .. "mem_info_vram_total")
            if vram_used and vram_total then
                add(g, "VRAM", string.format("%s / %s", format_bytes(vram_used),
                    format_bytes(vram_total)))
            end
            local sclk = read_raw(dev .. "pp_dpm_sclk")
            local mhz = sclk and sclk:match("(%d+)%s*[Mm][Hh][Zz]%s*%*")
            if mhz then
                add(g, "Core clock", mhz .. " MHz")
            end
            local mclk = read_raw(dev .. "pp_dpm_mclk")
            mhz = mclk and mclk:match("(%d+)%s*[Mm][Hh][Zz]%s*%*")
            if mhz then
                add(g, "Memory clock", mhz .. " MHz")
            end
            -- hwmon under the device (amdgpu, i915 power, nouveau)
            for _, hm in ipairs(list_dir(dev .. "hwmon") or {}) do
                local hdir = dev .. "hwmon/" .. hm .. "/"
                local t = read_num(hdir .. "temp1_input")
                if t then
                    add(g, "Temperature", string.format("%.1f °C", t / 1000),
                        name .. "/temp", t / 1000)
                    g.items[#g.items].unit = "°C"
                end
                local pw = read_num(hdir .. "power1_average") or read_num(hdir .. "power1_input")
                if pw then
                    add(g, "Power", string.format("%.1f W", pw / 1000000))
                end
                local fan = read_num(hdir .. "fan1_input")
                if fan then
                    add(g, "Fan", fan .. " RPM")
                end
            end
            if #g.items > 0 then
                groups[#groups + 1] = g
            end
        end
    end
    -- NVIDIA proprietary driver
    for _, gpu_id in ipairs(list_dir("/proc/driver/nvidia/gpus") or {}) do
        local info = read_raw("/proc/driver/nvidia/gpus/" .. gpu_id .. "/information")
        if info then
            local g = new_group("NVIDIA GPU (" .. gpu_id .. ")")
            add(g, "Model", info:match("Model:%s*([^\n]+)"))
            add(g, "Video BIOS", info:match("Video BIOS:%s*([^\n]+)"))
            add(g, "Bus location", info:match("Bus Location:%s*([^\n]+)"))
            add(g, "Live stats", "N/A (needs nvidia-smi; not read by this tool)")
            groups[#groups + 1] = g
        end
    end
    return groups
end

-- NVMe controllers and SMART health ---------------------------------------
local function le64(buf, off)
    local v = 0
    for i = 7, 0, -1 do
        v = v * 256 + buf:byte(off + i + 1)
    end
    return v
end

--- Parse a 512-byte NVMe SMART / Health log page.
function HW.parse_nvme_smart(buf)
    if #buf < 192 then
        return nil
    end
    local kelvin = buf:byte(2) + buf:byte(3) * 256
    return {
        critical_warning = buf:byte(1),
        temp_c = kelvin > 0 and kelvin - 273 or nil,
        spare_pct = buf:byte(4),
        spare_threshold = buf:byte(5),
        used_pct = buf:byte(6),
        read_bytes = le64(buf, 32) * 512000,
        written_bytes = le64(buf, 48) * 512000,
        power_cycles = le64(buf, 112),
        power_on_hours = le64(buf, 128),
        unsafe_shutdowns = le64(buf, 144),
        media_errors = le64(buf, 160),
    }
end

--- Query the SMART log via the NVMe admin passthrough ioctl (normally root only).
function HW.read_nvme_smart(devpath)
    local fd = ffi.C.open(devpath, 0)
    if fd < 0 then
        local errno = ffi.errno()
        return nil, string.format("cannot open %s: %s", devpath,
            errno == 13 and "permission denied (run as root)" or ("errno " .. errno))
    end
    local data = ffi.new("uint8_t[512]")
    local cmd = ffi.new("struct hw_nvme_admin_cmd")
    cmd.opcode = 0x02
    cmd.nsid = 0xFFFFFFFF
    cmd.addr = tonumber(ffi.cast("uintptr_t", data))
    cmd.data_len = 512
    cmd.cdw10 = bit.bor(bit.lshift(127, 16), 0x02)
    local rc = ffi.C.ioctl(fd, 0xC0484E41, cmd)
    local errno = ffi.errno()
    ffi.C.close(fd)
    if rc ~= 0 then
        return nil, string.format("NVMe SMART ioctl on %s failed (rc=%d, errno %d)", devpath,
            rc, errno)
    end
    local parsed = HW.parse_nvme_smart(ffi.string(data, 512))
    if not parsed then
        return nil, "NVMe SMART log too short"
    end
    return parsed
end

function HW.collect_nvme()
    local groups = {}
    for _, name in ipairs(list_dir("/sys/class/nvme") or {}) do
        local dir = "/sys/class/nvme/" .. name .. "/"
        local g = new_group("NVMe Controller " .. name)
        add(g, "Model", read_str(dir .. "model"))
        add(g, "Firmware", read_str(dir .. "firmware_rev"))
        add(g, "State", read_str(dir .. "state"))
        add(g, "Transport", read_str(dir .. "transport"))
        add(g, "I/O queues", read_str(dir .. "queue_count"))
        add(g, "PCIe link", pcie_link(dir .. "device/"))
        for _, hm in ipairs(list_dir(dir) or {}) do
            if hm:match("^hwmon%d+$") then
                local t = read_num(dir .. hm .. "/temp1_input")
                if t then
                    add(g, "Temperature", string.format("%.1f °C", t / 1000),
                        name .. "/temp", t / 1000)
                    g.items[#g.items].unit = "°C"
                end
            end
        end
        local smart, err = HW.read_nvme_smart("/dev/" .. name)
        if smart then
            local warn = smart.critical_warning == 0 and "OK"
                or string.format("WARNING (flags 0x%02x)", smart.critical_warning)
            add(g, "Health", warn)
            add(g, "Wear", string.format("%d%% used", smart.used_pct))
            add(g, "Spare", string.format("%d%% (threshold %d%%)", smart.spare_pct,
                smart.spare_threshold))
            add(g, "Data written", format_bytes(smart.written_bytes))
            add(g, "Data read", format_bytes(smart.read_bytes))
            add(g, "Power-on", string.format("%d h", smart.power_on_hours))
            add(g, "Power cycles", smart.power_cycles)
            add(g, "Unsafe shutdowns", smart.unsafe_shutdowns)
            add(g, "Media errors", smart.media_errors)
        else
            add(g, "SMART", "N/A (" .. err .. ")")
        end
        groups[#groups + 1] = g
    end
    return groups
end

function HW.collect_gpu_pci()
    local base = "/sys/bus/pci/devices"
    local entries = list_dir(base)
    local gpu = new_group("Graphics")
    local pci = new_group("PCI Devices")
    if not entries then
        add(pci, "PCI", "N/A (cannot read " .. base .. ")")
        return { pci }
    end
    local devs = {}
    local wanted = {}
    for _, addr in ipairs(entries) do
        local dir = base .. "/" .. addr .. "/"
        local vendor = (read_str(dir .. "vendor") or ""):gsub("^0x", "")
        local device = (read_str(dir .. "device") or ""):gsub("^0x", "")
        local class = (read_str(dir .. "class") or ""):gsub("^0x", "")
        devs[#devs + 1] = {
            addr = addr, vendor = vendor, device = device, class4 = class:sub(1, 4),
            driver = link_base(dir .. "driver"),
        }
        wanted[vendor] = true
    end
    local names = HW.load_pci_names(wanted)
    for _, d in ipairs(devs) do
        local vname = names.vendors[d.vendor] or ("vendor " .. d.vendor)
        local dname = names.devices[d.vendor .. ":" .. d.device] or ("device " .. d.device)
        local kind = PCI_CLASSES[d.class4] or PCI_BASE[d.class4:sub(1, 2)] or "Device"
        local text = string.format("%s %s [%s:%s]", vname, dname, d.vendor, d.device)
        if d.driver then
            text = text .. "  driver: " .. d.driver
        end
        add(pci, d.addr .. " " .. kind, text)
        if d.class4:sub(1, 2) == "03" then
            add(gpu, d.addr .. " " .. kind, text)
            local vram = read_num(base .. "/" .. d.addr .. "/mem_info_vram_total")
            if vram then
                add(gpu, "  VRAM", format_bytes(vram))
            end
        end
    end
    if #gpu.items == 0 then
        add(gpu, "GPU", "N/A (no display-class PCI device)")
    end
    if #pci.items == 0 then
        add(pci, "PCI", "N/A (no devices)")
    end
    local result = { gpu }
    for _, g in ipairs(HW.collect_gpu_details()) do
        result[#result + 1] = g
    end
    result[#result + 1] = HW.collect_displays()
    result[#result + 1] = pci
    return result
end

function HW.collect_storage()
    local groups = {}
    local disks = new_group("Block Devices")
    local entries = list_dir("/sys/block")
    if not entries then
        add(disks, "Disks", "N/A (cannot read /sys/block)")
    else
        for _, name in ipairs(entries) do
            if not name:match("^loop") and not name:match("^ram") then
                local dir = "/sys/block/" .. name .. "/"
                local sectors = read_num(dir .. "size") or 0
                local model = read_str(dir .. "device/model")
                local rot = read_num(dir .. "queue/rotational")
                local kind = name:match("^nvme") and "NVMe SSD"
                    or (rot == 1 and "HDD" or (rot == 0 and "SSD" or "disk"))
                local desc = string.format("%s  %s", format_bytes(sectors * 512), kind)
                if model then
                    desc = desc .. "  " .. model
                end
                if read_num(dir .. "removable") == 1 then
                    desc = desc .. "  (removable)"
                end
                local sched = read_str(dir .. "queue/scheduler")
                if sched then
                    desc = desc .. "  sched: " .. (sched:match("%[([^%]]+)%]") or sched)
                end
                add(disks, name, desc)
            end
        end
        if #disks.items == 0 then
            add(disks, "Disks", "N/A (no block devices)")
        end
    end
    groups[#groups + 1] = disks
    for _, g in ipairs(HW.collect_nvme()) do
        groups[#groups + 1] = g
    end

    local mounts = new_group("Mounted Filesystems")
    local text = read_raw("/proc/mounts")
    if not text then
        add(mounts, "Mounts", "N/A (cannot read /proc/mounts)")
    else
        local order = {}
        local by_dev = {}
        for line in text:gmatch("[^\n]+") do
            local dev, mp, fs = line:match("^(%S+)%s+(%S+)%s+(%S+)")
            if dev and dev:sub(1, 1) == "/" then
                mp = mp:gsub("\\040", " ")
                local entry = by_dev[dev]
                if not entry then
                    entry = { dev = dev, fs = fs, mounts = {} }
                    by_dev[dev] = entry
                    order[#order + 1] = entry
                end
                entry.mounts[#entry.mounts + 1] = mp
            end
        end
        for _, entry in ipairs(order) do
            local mp = entry.mounts[1]
            local extra = ""
            if #entry.mounts > 1 then
                extra = string.format("  (+%d more: %s)", #entry.mounts - 1,
                    table.concat(entry.mounts, ", ", 2))
            end
            local sv = ffi.new("struct hw_statvfs")
            if ffi.C.statvfs(mp, sv) == 0 and tonumber(sv.f_blocks) > 0 then
                local frsize = tonumber(sv.f_frsize)
                local total = tonumber(sv.f_blocks) * frsize
                local free = tonumber(sv.f_bavail) * frsize
                local used = total - tonumber(sv.f_bfree) * frsize
                add(mounts, mp, string.format("%s  %s  used %s / %s (%.0f%%)  free %s%s",
                    entry.dev, entry.fs, format_bytes(used), format_bytes(total),
                    used * 100 / total, format_bytes(free), extra))
            else
                add(mounts, mp, string.format("%s  %s  (statvfs unavailable)%s", entry.dev,
                    entry.fs, extra))
            end
        end
        if #mounts.items == 0 then
            add(mounts, "Mounts", "N/A (no device-backed mounts)")
        end
    end
    groups[#groups + 1] = mounts
    return groups
end

local function ipv4_by_interface()
    local result = {}
    local head = ffi.new("struct hw_ifaddrs *[1]")
    if ffi.C.getifaddrs(head) ~= 0 then
        return result, "getifaddrs failed"
    end
    local p = head[0]
    while p ~= nil do
        if p.ifa_addr ~= nil and p.ifa_addr.sa_family == 2 then
            local d = p.ifa_addr.sa_data
            local name = ffi.string(p.ifa_name)
            result[name] = string.format("%d.%d.%d.%d", d[2], d[3], d[4], d[5])
        end
        p = p.ifa_next
    end
    ffi.C.freeifaddrs(head[0])
    return result
end

function HW.collect_network()
    local g = new_group("Interfaces")
    local entries = list_dir("/sys/class/net")
    if not entries then
        add(g, "Network", "N/A (cannot read /sys/class/net)")
        return { g }
    end
    local ips, ip_err = ipv4_by_interface()
    for _, name in ipairs(entries) do
        local dir = "/sys/class/net/" .. name .. "/"
        local parts = {}
        parts[#parts + 1] = read_str(dir .. "operstate") or "unknown"
        if ips[name] then
            parts[#parts + 1] = ips[name]
        end
        parts[#parts + 1] = read_str(dir .. "address")
        local speed = read_num(dir .. "speed")
        if speed and speed > 0 then
            parts[#parts + 1] = speed .. " Mb/s"
        end
        local drv = link_base(dir .. "device/driver")
        if drv then
            parts[#parts + 1] = "driver: " .. drv
        end
        local mtu = read_str(dir .. "mtu")
        if mtu then
            parts[#parts + 1] = "mtu " .. mtu
        end
        add(g, name, table.concat(parts, "  "))
    end
    if #g.items == 0 then
        add(g, "Network", "N/A (no interfaces)")
    end
    if ip_err then
        add(g, "IPv4", "N/A (" .. ip_err .. ")")
    end
    return { g }
end

function HW.collect_sensors()
    local groups = {}
    local entries = list_dir("/sys/class/hwmon") or {}
    for _, hm in ipairs(entries) do
        local dir = "/sys/class/hwmon/" .. hm .. "/"
        local g = new_group((read_str(dir .. "name") or hm) .. " (" .. hm .. ")")
        local files = list_dir("/sys/class/hwmon/" .. hm) or {}
        for _, f in ipairs(files) do
            local kind, idx = f:match("^(%a+)(%d+)_input$")
            if kind == "temp" or kind == "fan" or kind == "in" or kind == "power" then
                local v = read_num(dir .. f)
                local label = read_str(dir .. kind .. idx .. "_label") or (kind .. idx)
                if v then
                    local text, num, unit
                    if kind == "temp" then
                        num, unit = v / 1000, "°C"
                        text = string.format("%.1f °C", num)
                    elseif kind == "fan" then
                        num, unit = v, "RPM"
                        text = string.format("%d RPM", v)
                    elseif kind == "in" then
                        num, unit = v / 1000, "V"
                        text = string.format("%.3f V", num)
                    else
                        num, unit = v / 1000000, "W"
                        text = string.format("%.2f W", num)
                    end
                    add(g, label, text, hm .. "/" .. f, num)
                    g.items[#g.items].unit = unit
                end
            end
        end
        if #g.items > 0 then
            groups[#groups + 1] = g
        end
    end
    if #groups == 0 then
        local g = new_group("Hardware Monitors")
        add(g, "hwmon", "N/A (no sensors exposed in /sys/class/hwmon)")
        groups[#groups + 1] = g
    end

    local ps = list_dir("/sys/class/power_supply") or {}
    local pg = new_group("Power Supplies")
    for _, name in ipairs(ps) do
        local dir = "/sys/class/power_supply/" .. name .. "/"
        local kind = read_str(dir .. "type") or "?"
        local parts = { kind }
        if kind == "Battery" then
            parts[#parts + 1] = read_str(dir .. "status")
            local cap = read_str(dir .. "capacity")
            parts[#parts + 1] = cap and (cap .. "%") or nil
            local full = read_num(dir .. "energy_full") or read_num(dir .. "charge_full")
            local design = read_num(dir .. "energy_full_design")
                or read_num(dir .. "charge_full_design")
            if full and design and design > 0 then
                parts[#parts + 1] = string.format("health %.0f%%", full * 100 / design)
            end
            parts[#parts + 1] = read_str(dir .. "model_name")
            local cycles = read_num(dir .. "cycle_count")
            parts[#parts + 1] = cycles and cycles > 0 and (cycles .. " cycles") or nil
        elseif kind == "Mains" then
            local online = read_num(dir .. "online")
            parts[#parts + 1] = online == 1 and "online" or "offline"
        end
        add(pg, name, table.concat(parts, "  "))
    end
    if #pg.items > 0 then
        groups[#groups + 1] = pg
    end
    return groups
end

function HW.collect_usb()
    local g = new_group("USB Devices")
    local entries = list_dir("/sys/bus/usb/devices")
    if not entries then
        add(g, "USB", "N/A (cannot read /sys/bus/usb/devices)")
        return { g }
    end
    for _, name in ipairs(entries) do
        if not name:find(":", 1, true) then
            local dir = "/sys/bus/usb/devices/" .. name .. "/"
            local vid, pid = read_str(dir .. "idVendor"), read_str(dir .. "idProduct")
            if vid and pid then
                local parts = {}
                parts[#parts + 1] = string.format("[%s:%s]", vid, pid)
                parts[#parts + 1] = read_str(dir .. "manufacturer")
                parts[#parts + 1] = read_str(dir .. "product")
                local speed = read_str(dir .. "speed")
                parts[#parts + 1] = speed and (speed .. " Mb/s") or nil
                add(g, name, table.concat(parts, " "))
            end
        end
    end
    if #g.items == 0 then
        add(g, "USB", "N/A (no devices)")
    end
    return { g }
end

HW.TABS = {
    { id = "system", title = "System", collect = HW.collect_system },
    { id = "cpu", title = "CPU", collect = HW.collect_cpu },
    { id = "memory", title = "Memory", collect = HW.collect_memory },
    { id = "gpu", title = "GPU/PCI", collect = HW.collect_gpu_pci },
    { id = "storage", title = "Storage", collect = HW.collect_storage },
    { id = "network", title = "Network", collect = HW.collect_network },
    { id = "sensors", title = "Sensors", collect = HW.collect_sensors },
    { id = "usb", title = "USB", collect = HW.collect_usb },
}

--- Run one collector; a crash becomes a visible error group, never a silent blank.
function HW.safe_collect(tab)
    local ok, result = pcall(tab.collect)
    if ok then
        return result
    end
    local g = new_group("Error")
    add(g, "Collector", tab.id .. " failed: " .. tostring(result))
    return { g }
end

function HW.collect_all()
    local data = {}
    for i, tab in ipairs(HW.TABS) do
        data[i] = { id = tab.id, title = tab.title, groups = HW.safe_collect(tab) }
    end
    return data
end

-- =========================================================================
-- 4. JSON export
-- =========================================================================
local function json_str(s)
    s = s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
            ["\t"] = "\\t" }
        return map[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

function HW.to_json(data)
    local out = {}
    for _, tab in ipairs(data) do
        local groups = {}
        for _, g in ipairs(tab.groups) do
            local items = {}
            for _, it in ipairs(g.items) do
                items[#items + 1] = string.format("{\"label\":%s,\"value\":%s}",
                    json_str(it.label), json_str(it.value))
            end
            groups[#groups + 1] = string.format("{\"title\":%s,\"items\":[%s]}",
                json_str(g.title), table.concat(items, ","))
        end
        out[#out + 1] = string.format("{\"id\":%s,\"title\":%s,\"groups\":[%s]}",
            json_str(tab.id), json_str(tab.title), table.concat(groups, ","))
    end
    return "{\"tabs\":[" .. table.concat(out, ",") .. "]}\n"
end

--- Write the snapshot and verify it by reading it back. Returns ok, message.
function HW.export_json(data, path)
    local json = HW.to_json(data)
    local f, err = io.open(path, "wb")
    if not f then
        return false, "cannot write " .. path .. ": " .. tostring(err)
    end
    local ok, werr = f:write(json)
    f:close()
    if not ok then
        return false, "write failed for " .. path .. ": " .. tostring(werr)
    end
    local back = io.open(path, "rb")
    if not back then
        return false, "verification failed: cannot reopen " .. path
    end
    local content = back:read("*a")
    back:close()
    if content ~= json then
        return false, "verification failed: content mismatch in " .. path
    end
    return true, string.format("Saved %d bytes to %s", #json, path)
end

-- =========================================================================
-- 5. Text layout helpers (UTF-8 aware)
-- =========================================================================
local function ulen(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Truncate to at most `w` display columns, appending an ellipsis when cut.
local function truncate(s, w)
    if w <= 0 then
        return ""
    end
    if ulen(s) <= w then
        return s
    end
    local count, i = 0, 1
    while i <= #s and count < w - 1 do
        local c = s:byte(i)
        local step = c >= 240 and 4 or c >= 224 and 3 or c >= 192 and 2 or 1
        i = i + step
        count = count + 1
    end
    return s:sub(1, i - 1) .. "…"
end

local function wrap(text, width)
    if width < 4 then
        width = 4
    end
    local lines = {}
    local cur = ""
    for word in text:gmatch("%S+") do
        while ulen(word) > width do
            if cur ~= "" then
                lines[#lines + 1] = cur
                cur = ""
            end
            local piece = word:sub(1, width)
            -- avoid splitting inside a UTF-8 sequence
            while #piece > 1 and piece:byte(#piece) >= 128 and piece:byte(#piece) < 192 do
                piece = piece:sub(1, -2)
            end
            lines[#lines + 1] = piece
            word = word:sub(#piece + 1)
        end
        if cur == "" then
            cur = word
        elseif ulen(cur) + 1 + ulen(word) <= width then
            cur = cur .. " " .. word
        else
            lines[#lines + 1] = cur
            cur = word
        end
    end
    if cur ~= "" or #lines == 0 then
        lines[#lines + 1] = cur
    end
    return lines
end

-- =========================================================================
-- 5b. Sensor history (sparklines)
-- =========================================================================
local SPARK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local HISTORY_MAX = 30

--- Push the current numeric value of every keyed item into `history`.
function HW.record_history(history, data)
    for _, tab in ipairs(data) do
        for _, g in ipairs(tab.groups) do
            for _, it in ipairs(g.items) do
                if it.key and it.num then
                    local list = history[it.key]
                    if not list then
                        list = {}
                        history[it.key] = list
                    end
                    list[#list + 1] = it.num
                    if #list > HISTORY_MAX then
                        table.remove(list, 1)
                    end
                end
            end
        end
    end
end

--- Render samples as a sparkline plus min/max; "" when fewer than two samples.
function HW.sparkline(samples, unit)
    if not samples or #samples < 2 then
        return ""
    end
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(samples) do
        lo = math.min(lo, v)
        hi = math.max(hi, v)
    end
    local out = {}
    for _, v in ipairs(samples) do
        local idx = 4
        if hi > lo then
            idx = 1 + math.floor((v - lo) / (hi - lo) * 7 + 0.5)
        end
        out[#out + 1] = SPARK_CHARS[idx]
    end
    local fmt = unit == "RPM" and "%.0f" or "%.1f"
    return string.format("%s min " .. fmt .. " max " .. fmt, table.concat(out), lo, hi)
end

--- Flatten a tab's groups to display lines for the given width and filter.
--- `history` (optional) adds sparklines to keyed sensor rows.
function HW.flatten(groups, width, filter, history)
    local needle = filter and filter ~= "" and filter:lower() or nil
    local label_w = 12
    for _, g in ipairs(groups) do
        for _, it in ipairs(g.items) do
            label_w = math.max(label_w, math.min(ulen(it.label), 34))
        end
    end
    label_w = math.min(label_w, math.max(8, math.floor(width / 3)))
    local value_w = math.max(4, width - label_w - 4)
    local lines = {}
    for _, g in ipairs(groups) do
        local kept = {}
        for _, it in ipairs(g.items) do
            if not needle or (it.label .. " " .. it.value):lower():find(needle, 1, true) then
                kept[#kept + 1] = it
            end
        end
        if #kept > 0 then
            if #lines > 0 then
                lines[#lines + 1] = { kind = "blank" }
            end
            lines[#lines + 1] = { kind = "hdr", text = g.title }
            for _, it in ipairs(kept) do
                local text = it.value
                local spark = history and it.key and HW.sparkline(history[it.key], it.unit)
                if spark and spark ~= "" then
                    text = text .. "  " .. spark
                end
                local parts = wrap(text, value_w)
                for i, part in ipairs(parts) do
                    lines[#lines + 1] = {
                        kind = "kv",
                        label = i == 1 and truncate(it.label, label_w) or "",
                        value = part,
                        label_w = label_w,
                    }
                end
            end
        end
    end
    return lines
end

-- =========================================================================
-- 6. Pure frame generators
-- =========================================================================
local C = {
    reset = "\27[0m", bold = "\27[1m", dim = "\27[2m",
    title = "\27[1;38;2;192;202;245m", accent = "\27[1;38;2;125;207;255m",
    tab_on = "\27[1;48;2;41;46;66;38;2;255;255;255m", tab_off = "\27[38;2;130;140;180m",
    hdr = "\27[1;38;2;122;162;247m", label = "\27[38;2;169;177;214m",
    value = "\27[38;2;220;225;245m", rule = "\27[38;2;65;72;104m",
    err = "\27[1;38;2;247;118;142m", ok = "\27[38;2;158;206;106m",
    na = "\27[38;2;224;175;104m",
}

local function new_state(data)
    local state = {
        data = data,
        tab = 1,
        scroll = {},
        filter = "",
        filter_mode = false,
        status = nil,
        status_err = false,
        history = {},
    }
    HW.record_history(state.history, data)
    for i = 1, #data do
        state.scroll[i] = 0
    end
    return state
end

local function body_height(h)
    return math.max(1, h - 4)
end

local function visible_lines(state, w)
    local tab = state.data[state.tab]
    return HW.flatten(tab.groups, w, state.filter, state.history)
end

local function clamp_scroll(state, w, h)
    local lines = visible_lines(state, w)
    local max_scroll = math.max(0, #lines - body_height(h))
    local s = state.scroll[state.tab]
    if s > max_scroll then
        s = max_scroll
    end
    if s < 0 then
        s = 0
    end
    state.scroll[state.tab] = s
    return lines, s
end

local function render_tabbar(state, width)
    local plain = " HWINFO "
    for i, tab in ipairs(state.data) do
        plain = plain .. " " .. i .. ":" .. tab.title .. " "
    end
    if ulen(plain) > width then
        local tab = state.data[state.tab]
        return C.title .. truncate(string.format(" HWINFO  ‹ %s %d/%d ›", tab.title, state.tab,
            #state.data), width) .. C.reset
    end
    local out = { C.title, " HWINFO ", C.reset }
    for i, tab in ipairs(state.data) do
        local style = i == state.tab and C.tab_on or C.tab_off
        out[#out + 1] = style .. " " .. i .. ":" .. tab.title .. " " .. C.reset
    end
    return table.concat(out)
end

local function render_footer(state, width)
    if state.filter_mode then
        return C.accent .. truncate(" /" .. state.filter .. "█", width) .. C.reset
    end
    if state.status then
        local color = state.status_err and C.err or C.ok
        return color .. truncate(" " .. state.status, width) .. C.reset
    end
    local text = " ←/→ tab  ↑/↓ PgUp/PgDn scroll  / filter  e export  r refresh  q quit"
    if state.filter ~= "" then
        text = " filter: " .. state.filter .. "  (Esc clears)  " .. text:sub(2)
    end
    return C.dim .. truncate(text, width) .. C.reset
end

--- Build the screen as an array of `h` row strings (each without cursor addressing).
function HW.frame_rows(state, w, h)
    local width = math.max(1, w - 1)
    local rows = {}
    if w < 24 or h < 7 then
        for i = 1, h do
            rows[i] = ""
        end
        rows[1] = C.err .. truncate("Terminal too small", width) .. C.reset
        if h >= 2 then
            rows[2] = truncate("need at least 24x7", width)
        end
        return rows
    end
    local lines, scroll = clamp_scroll(state, width, h)
    local bh = body_height(h)
    local rule = C.rule .. string.rep("─", width) .. C.reset
    rows[1] = render_tabbar(state, width)
    rows[2] = rule
    for i = 1, bh do
        local ln = lines[scroll + i]
        local text = ""
        if ln == nil then
            if i == 1 and #lines == 0 then
                text = C.na .. truncate(" (no matching entries)", width) .. C.reset
            end
        elseif ln.kind == "hdr" then
            text = " " .. C.hdr .. truncate(ln.text, width - 1) .. C.reset
        elseif ln.kind == "kv" then
            local pad = string.rep(" ", math.max(0, ln.label_w - ulen(ln.label)))
            local vcolor = ln.value:find("^N/A") and C.na or C.value
            text = "   " .. C.label .. ln.label .. pad .. C.reset .. "  " .. vcolor
                .. truncate(ln.value, math.max(1, width - ln.label_w - 5)) .. C.reset
        end
        rows[2 + i] = text
    end
    rows[h - 1] = rule
    local pos = ""
    if #lines > bh then
        pos = string.format(" %d-%d/%d ", scroll + 1, math.min(#lines, scroll + bh), #lines)
    end
    local footer = render_footer(state, width - (pos ~= "" and ulen(pos) + 2 or 0))
    rows[h] = footer
    if pos ~= "" and not state.filter_mode then
        rows[h] = footer .. C.dim .. "  " .. pos .. C.reset
    end
    return rows
end

--- Emit only rows that differ from `prev` (cursor-addressed, each row cleared to EOL).
function HW.diff_frame(prev, rows)
    local out = { "\27[?2026h" }
    for i, row in ipairs(rows) do
        if prev == nil or prev[i] ~= row then
            out[#out + 1] = string.format("\27[%d;1H%s\27[K", i, row)
        end
    end
    out[#out + 1] = "\27[?2026l"
    if #out == 2 then
        return ""
    end
    return table.concat(out)
end

--- Whole-frame string (used for headless assertions and the first paint).
function HW.render_frame(state, w, h)
    return HW.diff_frame(nil, HW.frame_rows(state, w, h))
end

-- =========================================================================
-- 7. Input handling (pure state transitions)
-- =========================================================================
local function utf8_pop(s)
    local i = #s
    while i > 1 and s:byte(i) >= 128 and s:byte(i) < 192 do
        i = i - 1
    end
    return s:sub(1, i - 1)
end

--- Apply one key token. Returns an action string ("quit", "refresh", "export") or nil.
function HW.handle_key(state, key, w, h)
    if type(key) ~= "string" then
        return nil
    end
    state.status = nil
    state.status_err = false
    local count = #state.data
    if state.filter_mode then
        if key == "ENTER" then
            state.filter_mode = false
        elseif key == "ESC" then
            state.filter_mode = false
            state.filter = ""
        elseif key == "BACKSPACE" then
            state.filter = utf8_pop(state.filter)
        else
            if key == "SPACE" then
                key = " "
            end
            local is_symbolic = key:match("^[A-Z][A-Z_]+$") ~= nil
            if not is_symbolic and key:byte(1) >= 32 then
                state.filter = state.filter .. key
            end
        end
        state.scroll[state.tab] = 0
        return nil
    end
    local page = body_height(h or 24)
    if key == "q" or key == "Q" then
        return "quit"
    elseif key == "RIGHT" or key == "l" or key == "TAB" then
        state.tab = state.tab % count + 1
    elseif key == "LEFT" or key == "h" or key == "SHIFT_TAB" then
        state.tab = (state.tab - 2) % count + 1
    elseif key:match("^[1-9]$") and tonumber(key) <= count then
        state.tab = tonumber(key)
    elseif key == "DOWN" or key == "j" then
        state.scroll[state.tab] = state.scroll[state.tab] + 1
    elseif key == "UP" or key == "k" then
        state.scroll[state.tab] = state.scroll[state.tab] - 1
    elseif key == "PAGE_DOWN" or key == "SPACE" then
        state.scroll[state.tab] = state.scroll[state.tab] + page
    elseif key == "PAGE_UP" then
        state.scroll[state.tab] = state.scroll[state.tab] - page
    elseif key == "HOME" or key == "g" then
        state.scroll[state.tab] = 0
    elseif key == "END" or key == "G" then
        state.scroll[state.tab] = math.huge
    elseif key == "/" then
        state.filter_mode = true
    elseif key == "ESC" then
        state.filter = ""
    elseif key == "r" then
        return "refresh"
    elseif key == "e" then
        return "export"
    end
    if w and h then
        clamp_scroll(state, math.max(1, w - 1), h)
    end
    return nil
end

-- =========================================================================
-- 8. Terminal control
-- =========================================================================
local in_raw_mode = false
local orig_termios = ffi.new("struct hw_termios")
local sig_anchor = nil

local function disable_raw_mode()
    if in_raw_mode then
        io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
        io.flush()
        ffi.C.tcsetattr(0, 0, orig_termios)
        in_raw_mode = false
    end
end

local function enable_raw_mode()
    if ffi.C.isatty(0) ~= 1 or ffi.C.isatty(1) ~= 1 then
        return false
    end
    if ffi.C.tcgetattr(0, orig_termios) ~= 0 then
        return false
    end
    local raw = ffi.new("struct hw_termios")
    ffi.copy(raw, orig_termios, ffi.sizeof(raw))
    raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(2, 8)))
    if ffi.C.tcsetattr(0, 0, raw) ~= 0 then
        return false
    end
    in_raw_mode = true
    sig_anchor = ffi.cast("hw_sighandler_t", function(sig)
        disable_raw_mode()
        os.exit(128 + sig)
    end)
    for _, sig in ipairs({ 1, 2, 3, 15 }) do
        ffi.C.signal(sig, sig_anchor)
    end
    io.write("\27[?1049h\27[?25l\27[?7l\27[2J")
    io.flush()
    return true
end

local function terminal_size()
    local ws = ffi.new("struct hw_winsize")
    if ffi.C.ioctl(1, 0x5413, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 100, 30
end

local pfd = ffi.new("struct hw_pollfd", { fd = 0, events = 1, revents = 0 })
local key_buf = ffi.new("char[64]")

--- Split the front key token off a byte string. Returns token, remainder.
--- Tokens: printable characters (UTF-8 aware) or UP/DOWN/LEFT/RIGHT/PAGE_UP/PAGE_DOWN/
--- HOME/END/SHIFT_TAB/ENTER/ESC/SPACE/TAB/BACKSPACE.
function HW.next_token(s)
    local first = s:byte(1)
    if first == 27 then
        local seq = s:match("^\27%[[%d;]*[%a~]")
        if seq then
            local map = { ["\27[A"] = "UP", ["\27[B"] = "DOWN", ["\27[C"] = "RIGHT",
                ["\27[D"] = "LEFT", ["\27[H"] = "HOME", ["\27[F"] = "END",
                ["\27[Z"] = "SHIFT_TAB", ["\27[5~"] = "PAGE_UP", ["\27[6~"] = "PAGE_DOWN",
                ["\27[1~"] = "HOME", ["\27[4~"] = "END" }
            return map[seq] or "ESC", s:sub(#seq + 1)
        end
        return "ESC", s:sub(2)
    elseif first == 10 or first == 13 then
        return "ENTER", s:sub(2)
    elseif first == 127 or first == 8 then
        return "BACKSPACE", s:sub(2)
    elseif first == 32 then
        return "SPACE", s:sub(2)
    elseif first == 9 then
        return "TAB", s:sub(2)
    end
    local len = first >= 240 and 4 or first >= 224 and 3 or first >= 192 and 2 or 1
    return s:sub(1, len), s:sub(len + 1)
end

local pending = ""

--- Read one key token, buffering burst input. Returns nil on timeout, "EOF" at end of
--- piped input.
local function read_key(timeout_ms)
    if pending == "" then
        if ffi.C.poll(pfd, 1, timeout_ms) <= 0 then
            return nil
        end
        local n = tonumber(ffi.C.read(0, key_buf, 64))
        if n <= 0 then
            return "EOF"
        end
        pending = ffi.string(key_buf, n)
    end
    local token
    token, pending = HW.next_token(pending)
    return token
end

-- =========================================================================
-- 9. TUI main loop
-- =========================================================================
local REFRESH_MS = 2000

local function now_ms()
    return os.clock() * 1000
end

--- Re-collect the active tab and the sensors tab, recording sensor history.
function HW.refresh_live(state)
    local fresh = {}
    fresh[state.tab] = true
    for i, tab in ipairs(HW.TABS) do
        if tab.id == "sensors" then
            fresh[i] = true
        end
    end
    for i in pairs(fresh) do
        state.data[i].groups = HW.safe_collect(HW.TABS[i])
        HW.record_history(state.history, { state.data[i] })
    end
end

function HW.run_tui(opts)
    opts = opts or {}
    io.stderr:write("hwinfo: collecting hardware data...\n")
    io.stderr:flush()
    local data = HW.collect_all()
    local state = new_state(data)
    if opts.tab then
        for i, tab in ipairs(data) do
            if tab.id == opts.tab then
                state.tab = i
            end
        end
    end
    local interactive = enable_raw_mode()
    if not interactive then
        io.stderr:write("hwinfo: stdin/stdout is not a terminal; "
            .. "running headless (keys read from stdin, 100x30)\n")
        io.stderr:flush()
    end
    local ok, err = pcall(function()
        local w, h = 100, 30
        if interactive then
            w, h = terminal_size()
        end
        local prev = nil
        local last_refresh = os.time()
        while true do
            local nw, nh = w, h
            if interactive then
                nw, nh = terminal_size()
            end
            if nw ~= w or nh ~= h then
                w, h = nw, nh
                prev = nil
                io.write("\27[2J")
            end
            local rows = HW.frame_rows(state, w, h)
            local out = HW.diff_frame(prev, rows)
            if out ~= "" then
                io.write(out)
                io.flush()
            end
            prev = rows
            local key = read_key(250)
            if key == "EOF" then
                break
            end
            if key then
                local action = HW.handle_key(state, key, w, h)
                if action == "quit" then
                    break
                elseif action == "refresh" then
                    state.data = HW.collect_all()
                    HW.record_history(state.history, state.data)
                    state.status = "Refreshed"
                elseif action == "export" then
                    local path = opts.export_path or "hwinfo_snapshot.json"
                    local saved, msg = HW.export_json(state.data, path)
                    state.status = msg
                    state.status_err = not saved
                end
            elseif os.time() - last_refresh >= REFRESH_MS / 1000 then
                last_refresh = os.time()
                HW.refresh_live(state)
            end
        end
    end)
    disable_raw_mode()
    if not ok then
        io.stderr:write("hwinfo: fatal error: " .. tostring(err) .. "\n")
        return 1
    end
    return 0
end

-- =========================================================================
-- 10. CLI entry point
-- =========================================================================
local function print_help()
    io.write([[
hwinfo_tui - tabbed hardware inventory (LuaJIT FFI, Linux)

Usage: luajit hwinfo_tui.lua [options]
  --tab <name>   start on a tab: system cpu memory gpu storage network sensors usb
  --json         print a JSON snapshot to stdout and exit
  --text         print a plain-text report to stdout and exit
  --help         show this help

Keys: <-/-> or 1-8 tabs, Up/Down PgUp/PgDn scroll, / filter, e export JSON,
      r refresh, q quit.
]])
end

function HW.text_report(data, width)
    local out = {}
    for _, tab in ipairs(data) do
        out[#out + 1] = "== " .. tab.title .. " =="
        for _, line in ipairs(HW.flatten(tab.groups, width or 100, "")) do
            if line.kind == "hdr" then
                out[#out + 1] = line.text
            elseif line.kind == "kv" then
                out[#out + 1] = string.format("  %-" .. line.label_w .. "s  %s", line.label,
                    line.value)
            else
                out[#out + 1] = ""
            end
        end
        out[#out + 1] = ""
    end
    return table.concat(out, "\n") .. "\n"
end

function HW.main(args)
    local opts = {}
    local mode = "tui"
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_help()
            return 0
        elseif a == "--json" then
            mode = "json"
        elseif a == "--text" then
            mode = "text"
        elseif a == "--tab" then
            i = i + 1
            opts.tab = args[i]
            local valid = false
            for _, tab in ipairs(HW.TABS) do
                if tab.id == opts.tab then
                    valid = true
                end
            end
            if not valid then
                io.stderr:write("hwinfo: invalid --tab value '" .. tostring(opts.tab)
                    .. "' (use: system cpu memory gpu storage network sensors usb)\n")
                return 2
            end
        else
            io.stderr:write("hwinfo: unknown option '" .. tostring(a) .. "' (try --help)\n")
            return 2
        end
        i = i + 1
    end
    if ffi.os ~= "Linux" then
        io.stderr:write("hwinfo: only Linux is supported (detected " .. ffi.os .. ")\n")
        return 1
    end
    if mode == "json" then
        io.write(HW.to_json(HW.collect_all()))
        return 0
    elseif mode == "text" then
        io.write(HW.text_report(HW.collect_all(), 100))
        return 0
    end
    return HW.run_tui(opts)
end

HW.helpers = {
    truncate = truncate, wrap = wrap, ulen = ulen, format_bytes = format_bytes,
    new_state = new_state,
}

if arg and arg[0]
    and (arg[0] == "hwinfo_tui.lua" or arg[0]:match("/hwinfo_tui%.lua$")) then
    os.exit(HW.main(arg))
end

return HW
