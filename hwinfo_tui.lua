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

-- Find termkit.lua next to this script even when launched from another directory.
local script_dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$")
if script_dir then
    package.path = script_dir .. "/?.lua;" .. package.path
end
local termkit = require("termkit")

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

    int ioctl(int fd, unsigned long request, void *argp);

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
local function add(group, label, value)
    if value == nil or value == false then
        return
    end
    group.items[#group.items + 1] = { label = label, value = tostring(value) }
end

--- Append a row using `fallback` when the value is missing (never silent).
local function add_na(group, label, value, fallback)
    add(group, label, value == nil and (fallback or "N/A") or value)
end

--- Append a numeric row. `key` identifies it in the sensor history, `num` is the
--- plotted value and `unit` selects the sparkline number format.
local function add_metric(group, label, text, key, num, unit)
    group.items[#group.items + 1] = {
        label = label,
        value = text,
        key = key,
        num = num,
        unit = unit,
    }
end

--- Join the non-empty arguments with `sep` (nil and false are skipped).
local function join(sep, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value and value ~= "" then
            parts[#parts + 1] = tostring(value)
        end
    end
    return table.concat(parts, sep)
end

--- Format a PCIe link as "8.0 GT/s PCIe x4 (max 16.0 GT/s PCIe x4)"; nil when the
--- device reports no usable link (e.g. an integrated GPU).
local function pcie_link(dir)
    local speed = read_str(dir .. "current_link_speed")
    local width = read_str(dir .. "current_link_width")
    local max_speed = read_str(dir .. "max_link_speed")
    local max_width = read_str(dir .. "max_link_width")
    if not speed or not width or speed:find("Unknown", 1, true) or width == "0" then
        return nil
    end
    local text = string.format("%s x%s", speed, width)
    if max_speed and max_width and (max_speed ~= speed or max_width ~= width) then
        text = text .. string.format(" (max %s x%s)", max_speed, max_width)
    end
    return text
end

-- =========================================================================
-- 3. Collectors (each returns a list of groups)
-- =========================================================================

-- System ------------------------------------------------------------------
local DMI_DIR = "/sys/class/dmi/id/"
local NO_DMI = "N/A (no DMI)"

-- SMBIOS chassis type codes (DMTF DSP0134, "System Enclosure").
local CHASSIS = {
    [1] = "Other", [2] = "Unknown", [3] = "Desktop", [4] = "Low Profile Desktop",
    [6] = "Mini Tower", [7] = "Tower", [8] = "Portable", [9] = "Laptop",
    [10] = "Notebook", [11] = "Handheld", [13] = "All-in-One", [14] = "Sub Notebook",
    [15] = "Space-saving", [16] = "Lunch Box", [17] = "Main Server",
    [23] = "Rack Mount", [30] = "Tablet", [31] = "Convertible", [32] = "Detachable",
    [35] = "Mini PC", [36] = "Stick PC",
}

local function machine_group()
    local g = new_group("Machine")
    add_na(g, "Vendor", read_str(DMI_DIR .. "sys_vendor"), NO_DMI)
    add_na(g, "Product", read_str(DMI_DIR .. "product_name"), NO_DMI)
    add(g, "Version", read_str(DMI_DIR .. "product_version"))
    local chassis = read_num(DMI_DIR .. "chassis_type")
    if chassis then
        add(g, "Chassis", CHASSIS[chassis] or ("Type " .. chassis))
    end
    return g
end

local function firmware_group()
    local g = new_group("Mainboard & Firmware")
    add_na(g, "Board", read_str(DMI_DIR .. "board_name"), NO_DMI)
    add(g, "Board vendor", read_str(DMI_DIR .. "board_vendor"))
    add(g, "Board version", read_str(DMI_DIR .. "board_version"))
    add_na(g, "BIOS vendor", read_str(DMI_DIR .. "bios_vendor"), NO_DMI)
    add(g, "BIOS version", read_str(DMI_DIR .. "bios_version"))
    add(g, "BIOS date", read_str(DMI_DIR .. "bios_date"))
    -- /sys/firmware/efi exists only when the kernel was booted through UEFI.
    add(g, "Boot mode", list_dir("/sys/firmware/efi") and "UEFI" or "Legacy BIOS / unknown")
    return g
end

local function os_group()
    local g = new_group("Operating System")
    local uts = ffi.new("struct hw_utsname")
    if ffi.C.uname(uts) == 0 then
        add(g, "Kernel", ffi.string(uts.sysname) .. " " .. ffi.string(uts.release))
        add(g, "Hostname", ffi.string(uts.nodename))
        add(g, "Architecture", ffi.string(uts.machine))
    else
        add(g, "Kernel", "N/A (uname failed)")
    end
    local os_release = read_raw("/etc/os-release")
    if os_release then
        add(g, "Distribution", os_release:match('PRETTY_NAME="?([^"\n]+)"?'))
    end
    local uptime = tonumber((read_str("/proc/uptime") or ""):match("^(%S+)"))
    if uptime then
        add(g, "Uptime", format_uptime(uptime))
    end
    return g
end

--- System tab: machine identity, firmware, kernel and uptime.
function HW.collect_system()
    return { machine_group(), firmware_group(), os_group() }
end

-- CPU ---------------------------------------------------------------------
local CPU_DIR = "/sys/devices/system/cpu/cpu0/"

--- Parse /proc/cpuinfo text. Handles x86 ("model name") and ARM ("Model") layouts.
--- Returns { model, vendor, flags, mhz, logical, physical }.
function HW.parse_cpuinfo(text)
    local info = { logical = 0 }
    local cores = {} -- unique "package:core" pairs give the physical core count
    local package_id
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local key, val = line:match("^([^:]-)%s*:%s*(.*)$")
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
            package_id = val
        elseif key == "core id" then
            cores[(package_id or "0") .. ":" .. val] = true
        end
    end
    info.physical = 0
    for _ in pairs(cores) do
        info.physical = info.physical + 1
    end
    return info
end

local function processor_group(info)
    local g = new_group("Processor")
    add_na(g, "Model", info.model)
    add(g, "Vendor", info.vendor)
    add(g, "Threads", info.logical)
    if info.physical > 0 then
        add(g, "Cores", info.physical)
    end
    return g
end

local function frequency_group(info)
    local g = new_group("Frequency")
    local base = CPU_DIR .. "cpufreq/"
    local min_khz = read_num(base .. "cpuinfo_min_freq")
    local max_khz = read_num(base .. "cpuinfo_max_freq")
    local cur_khz = read_num(base .. "scaling_cur_freq")
    if min_khz and max_khz then
        add(g, "Range", string.format("%.0f MHz - %.0f MHz", min_khz / 1000, max_khz / 1000))
    end
    if cur_khz then
        add(g, "Current", string.format("%.0f MHz", cur_khz / 1000))
    elseif info.mhz then
        add(g, "Current", string.format("%.0f MHz", info.mhz))
    end
    add(g, "Governor", read_str(base .. "scaling_governor"))
    add(g, "Driver", read_str(base .. "scaling_driver"))
    if #g.items == 0 then
        add(g, "Scaling", "N/A (cpufreq not exposed)")
    end
    return g
end

local function cache_group()
    local g = new_group("Cache (cpu0)")
    for _, name in ipairs(list_dir(CPU_DIR .. "cache") or {}) do
        if name:match("^index%d+$") then
            local dir = CPU_DIR .. "cache/" .. name .. "/"
            local level, size = read_str(dir .. "level"), read_str(dir .. "size")
            if level and size then
                add(g, "L" .. level .. " " .. (read_str(dir .. "type") or ""), size)
            end
        end
    end
    if #g.items == 0 then
        add(g, "Cache", "N/A (not exposed)")
    end
    return g
end

--- CPU tab: model, core counts, frequency scaling, caches and feature flags.
function HW.collect_cpu()
    local text, err = read_raw("/proc/cpuinfo")
    if not text then
        local g = new_group("Processor")
        add(g, "Model", "N/A (cannot read /proc/cpuinfo: " .. tostring(err) .. ")")
        return { g }
    end
    local info = HW.parse_cpuinfo(text)
    local groups = { processor_group(info), frequency_group(info), cache_group() }
    if info.flags then
        local flags = new_group("Flags")
        add(flags, "Flags", info.flags)
        groups[#groups + 1] = flags
    end
    return groups
end

-- Memory ------------------------------------------------------------------
local DMI_ENTRIES = "/sys/firmware/dmi/entries"

-- SMBIOS type 17 "Memory Device" memory-type codes.
local SMBIOS_MEMORY_TYPES = {
    [0x13] = "DDR2", [0x18] = "DDR3", [0x1A] = "DDR4", [0x1B] = "LPDDR", [0x1C] = "LPDDR2",
    [0x1D] = "LPDDR3", [0x1E] = "LPDDR4", [0x22] = "DDR5", [0x23] = "LPDDR5",
}

--- Decode the SMBIOS "Size" field into MiB; nil for empty or unknown slots.
--- 0x7FFF means "see the extended size field" (modules of 32 GiB and larger).
local function decode_dimm_size(field, extended)
    if field == 0x7FFF and extended then
        return extended
    elseif field == 0 or field == 0xFFFF then
        return nil
    elseif bit.band(field, 0x8000) ~= 0 then
        return bit.band(field, 0x7FFF) / 1024 -- bit 15 set: the size is in KiB
    end
    return field
end

--- Parse one raw SMBIOS type 17 (Memory Device) structure; nil if it is not one.
--- Field offsets are 0-based byte offsets from the DMTF SMBIOS specification.
function HW.parse_smbios_type17(raw)
    local MIN_LENGTH, TYPE_MEMORY_DEVICE = 0x1B, 17
    if #raw < MIN_LENGTH or raw:byte(1) ~= TYPE_MEMORY_DEVICE then
        return nil
    end
    local formatted_len = raw:byte(2)
    local strings = {} -- the string table follows the formatted area, NUL separated
    for s in raw:sub(formatted_len + 1):gmatch("([^%z]+)") do
        strings[#strings + 1] = s
    end
    local function byte_at(off)
        return raw:byte(off + 1)
    end
    local function word_at(off)
        return byte_at(off) + byte_at(off + 1) * 256
    end
    local function string_at(off) -- the byte is a 1-based index into the string table
        local index = byte_at(off)
        return index > 0 and strings[index] or nil
    end

    local size_field = word_at(0x0C)
    local extended = size_field == 0x7FFF and formatted_len >= 0x20 and word_at(0x1C) or nil
    local size_mb = decode_dimm_size(size_field, extended)
    local speed = word_at(0x15)
    return {
        locator = string_at(0x10),
        size_mb = size_mb,
        type = SMBIOS_MEMORY_TYPES[byte_at(0x12)],
        speed = speed > 0 and speed or nil,
        manufacturer = string_at(0x17),
        part = string_at(0x1A) and clean(string_at(0x1A)) or nil,
    }
end

--- Extract a /proc/meminfo field (reported in kB) as bytes.
local function meminfo_bytes(text, key)
    local kib = text:match("\n?" .. key .. ":%s*(%d+)%s*kB")
    return kib and tonumber(kib) * 1024 or nil
end

local function capacity_group(meminfo)
    local g = new_group("Capacity")
    local total = meminfo_bytes(meminfo, "MemTotal")
    local available = meminfo_bytes(meminfo, "MemAvailable")
    add(g, "Total", format_bytes(total))
    if total and available then
        local used = total - available
        add(g, "Used", string.format("%s (%.0f%%)", format_bytes(used), used * 100 / total))
        add(g, "Available", format_bytes(available))
    end
    local cached = meminfo_bytes(meminfo, "Cached")
    add(g, "Cached", cached and format_bytes(cached))
    local swap_total = meminfo_bytes(meminfo, "SwapTotal")
    local swap_free = meminfo_bytes(meminfo, "SwapFree")
    if swap_total then
        add(g, "Swap", string.format("%s (free %s)", format_bytes(swap_total),
            format_bytes(swap_free)))
    end
    local huge = meminfo_bytes(meminfo, "Hugepagesize")
    add(g, "Huge pages", huge and format_bytes(huge))
    return g
end

local function describe_dimm(dimm)
    local size = dimm.size_mb and format_bytes(dimm.size_mb * 1024 * 1024) or "empty"
    local speed = dimm.speed and ("@" .. dimm.speed .. " MT/s")
    return join(" ", size, dimm.type, speed, dimm.manufacturer and clean(dimm.manufacturer),
        dimm.part)
end

local function dimm_group()
    local g = new_group("Memory Modules (SMBIOS)")
    local unreadable = false
    for _, name in ipairs(list_dir(DMI_ENTRIES) or {}) do
        if name:match("^17%-%d+$") then
            local raw = read_raw(DMI_ENTRIES .. "/" .. name .. "/raw")
            local dimm = raw and HW.parse_smbios_type17(raw)
            if dimm then
                add(g, dimm.locator or name, describe_dimm(dimm))
            elseif not raw then
                unreadable = true
            end
        end
    end
    if #g.items == 0 then
        add(g, "DIMMs", unreadable
            and "N/A (needs root to read " .. DMI_ENTRIES .. ")"
            or "N/A (no SMBIOS memory entries exposed)")
    end
    return g
end

--- Memory tab: capacity/usage from /proc/meminfo and SMBIOS module details.
function HW.collect_memory()
    local meminfo, err = read_raw("/proc/meminfo")
    if not meminfo then
        local g = new_group("Capacity")
        add(g, "Memory", "N/A (cannot read /proc/meminfo: " .. tostring(err) .. ")")
        return { g }
    end
    return { capacity_group(meminfo), dimm_group() }
end

-- PCI and GPU -------------------------------------------------------------
local PCI_DIR = "/sys/bus/pci/devices"
local DRM_DIR = "/sys/class/drm"
local PCI_BASE_CLASS_DISPLAY = "03"
local PCI_IDS_PATHS = { "/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids" }

-- PCI class codes: first four hex digits of the class (base + sub-class), then
-- the base class alone as a fallback.
local PCI_CLASSES = {
    ["0300"] = "VGA controller", ["0302"] = "3D controller", ["0380"] = "Display controller",
    ["0108"] = "NVMe controller", ["0106"] = "SATA controller", ["0200"] = "Ethernet controller",
    ["0280"] = "Network controller", ["0403"] = "Audio device", ["0401"] = "Multimedia audio",
    ["0600"] = "Host bridge", ["0601"] = "ISA bridge", ["0604"] = "PCI bridge",
    ["0c03"] = "USB controller", ["0c05"] = "SMBus", ["0d11"] = "Bluetooth",
}
local PCI_BASE_CLASSES = {
    ["00"] = "Unclassified", ["01"] = "Storage", ["02"] = "Network", ["03"] = "Display",
    ["04"] = "Multimedia", ["05"] = "Memory", ["06"] = "Bridge", ["07"] = "Communication",
    ["08"] = "System peripheral", ["09"] = "Input", ["0b"] = "Processor",
    ["0c"] = "Serial bus", ["0d"] = "Wireless", ["10"] = "Encryption",
    ["11"] = "Signal processing", ["12"] = "Accelerator",
}

--- Resolve vendor/device names from pci.ids, keeping only vendors in `wanted`
--- (a set of 4-digit hex ids). Returns { vendors = {id=name}, devices = {"v:d"=name} };
--- both tables are empty when no pci.ids file is installed.
function HW.load_pci_names(wanted)
    local names = { vendors = {}, devices = {} }
    local file
    for _, path in ipairs(PCI_IDS_PATHS) do
        file = io.open(sys_path(path), "rb")
        if file then
            break
        end
    end
    if not file then
        return names
    end
    local vendor -- the wanted vendor whose device lines we are currently inside
    for line in file:lines() do
        local vendor_id, vendor_name = line:match("^(%x%x%x%x)%s%s(.+)$")
        if vendor_id then
            vendor = wanted[vendor_id] and vendor_id or nil
            if vendor then
                names.vendors[vendor] = vendor_name
            end
        elseif vendor then
            local device_id, device_name = line:match("^\t(%x%x%x%x)%s%s(.+)$")
            if device_id then
                names.devices[vendor .. ":" .. device_id] = device_name
            end
        end
    end
    file:close()
    return names
end

--- Read every PCI device's ids and driver. Returns the device list and the set of
--- vendor ids seen, or nil when /sys/bus/pci is unreadable.
local function read_pci_devices()
    local addresses = list_dir(PCI_DIR)
    if not addresses then
        return nil
    end
    local devices, vendors = {}, {}
    local function hex_id(path) -- sysfs ids look like "0x8086"
        return ((read_str(path) or ""):gsub("^0x", ""))
    end
    for _, addr in ipairs(addresses) do
        local dir = PCI_DIR .. "/" .. addr .. "/"
        local vendor, device = hex_id(dir .. "vendor"), hex_id(dir .. "device")
        local class = hex_id(dir .. "class"):sub(1, 4)
        devices[#devices + 1] = {
            addr = addr,
            dir = dir,
            vendor = vendor,
            device = device,
            class = class,
            kind = PCI_CLASSES[class] or PCI_BASE_CLASSES[class:sub(1, 2)] or "Device",
            driver = link_base(dir .. "driver"),
        }
        vendors[vendor] = true
    end
    return devices, vendors
end

local function describe_pci_device(dev, names)
    local vendor = names.vendors[dev.vendor] or ("vendor " .. dev.vendor)
    local device = names.devices[dev.vendor .. ":" .. dev.device] or ("device " .. dev.device)
    local text = string.format("%s %s [%s:%s]", vendor, device, dev.vendor, dev.device)
    if dev.driver then
        text = text .. "  driver: " .. dev.driver
    end
    return text
end

-- Displays (EDID) -----------------------------------------------------------
local EDID_MAGIC = "\0\255\255\255\255\255\255\0"
local EDID_BLOCK_SIZE = 128
local EDID_DESCRIPTOR_MONITOR_NAME = 0xFC

--- Parse the interesting fields of a 128-byte EDID block; nil when invalid.
--- Returns { mfr, product, width_cm, height_cm, year, name }.
function HW.parse_edid(raw)
    if #raw < EDID_BLOCK_SIZE or raw:sub(1, 8) ~= EDID_MAGIC then
        return nil
    end
    -- Manufacturer id: three 5-bit letters packed into a big-endian 16-bit word.
    local packed = raw:byte(9) * 256 + raw:byte(10)
    local function letter(shift)
        return string.char(64 + bit.band(bit.rshift(packed, shift), 31))
    end
    local info = {
        mfr = letter(10) .. letter(5) .. letter(0),
        product = raw:byte(11) + raw:byte(12) * 256,
        width_cm = raw:byte(22),
        height_cm = raw:byte(23),
        year = 1990 + raw:byte(18),
    }
    -- Four 18-byte descriptors start at (1-based) byte 55; a monitor-name descriptor
    -- is 0,0,0,0xFC,0 followed by up to 13 text bytes ending in a newline.
    for first = 55, 109, 18 do
        local is_text = raw:byte(first) == 0 and raw:byte(first + 1) == 0
        if is_text and raw:byte(first + 3) == EDID_DESCRIPTOR_MONITOR_NAME then
            info.name = clean(raw:sub(first + 5, first + 17):match("^[^\n]*"))
        end
    end
    return info
end

local function describe_display(dir)
    local modes = read_raw(dir .. "modes")
    local raw_edid = read_raw(dir .. "edid")
    local edid = raw_edid and HW.parse_edid(raw_edid)
    local name, size
    if edid then
        name = edid.name and (edid.name .. " (" .. edid.mfr .. ")") or edid.mfr
        if edid.width_cm > 0 and edid.height_cm > 0 then
            local diagonal_in = math.sqrt(edid.width_cm ^ 2 + edid.height_cm ^ 2) / 2.54
            size = string.format("%dx%d cm (%.1f\")", edid.width_cm, edid.height_cm, diagonal_in)
        end
    end
    return join("  ", "connected", modes and modes:match("^(%S+)"), name, size)
end

--- Displays group: one row per connected DRM output (mode, EDID name, size).
function HW.collect_displays()
    local g = new_group("Displays")
    for _, name in ipairs(list_dir(DRM_DIR) or {}) do
        local connector = name:match("^card%d+%-(.+)$")
        local dir = DRM_DIR .. "/" .. name .. "/"
        if connector and read_str(dir .. "status") == "connected" then
            add(g, connector, describe_display(dir))
        end
    end
    if #g.items == 0 then
        add(g, "Displays", "N/A (no connected outputs in " .. DRM_DIR .. ")")
    end
    return g
end

-- GPU details ---------------------------------------------------------------
-- Matches the active clock in amdgpu's pp_dpm_* tables, e.g. "1: 1800Mhz *".
local DPM_ACTIVE_PATTERN = "(%d+)%s*[Mm][Hh][Zz]%s*%*"

local function intel_frequency_row(g, card_dir, card)
    local requested = read_num(card_dir .. "gt_cur_freq_mhz")
    if not requested then
        return
    end
    local actual = read_num(card_dir .. "gt_act_freq_mhz")
    local low = read_num(card_dir .. "gt_min_freq_mhz")
    local high = read_num(card_dir .. "gt_max_freq_mhz")
    local text = string.format("requested %d MHz%s  (range %s-%s MHz)", requested,
        actual and (", actual " .. actual .. " MHz") or "", tostring(low or "?"),
        tostring(high or "?"))
    add_metric(g, "GT frequency", text, card .. "/gt_freq", actual or requested, "MHz")
end

local function amdgpu_rows(g, dev, card)
    local busy = read_num(dev .. "gpu_busy_percent")
    if busy then
        add_metric(g, "Utilization", busy .. " %", card .. "/busy", busy, "%")
    end
    local vram_used, vram_total = read_num(dev .. "mem_info_vram_used"),
        read_num(dev .. "mem_info_vram_total")
    if vram_used and vram_total then
        add(g, "VRAM", format_bytes(vram_used) .. " / " .. format_bytes(vram_total))
    end
    local core = (read_raw(dev .. "pp_dpm_sclk") or ""):match(DPM_ACTIVE_PATTERN)
    add(g, "Core clock", core and (core .. " MHz"))
    local memory = (read_raw(dev .. "pp_dpm_mclk") or ""):match(DPM_ACTIVE_PATTERN)
    add(g, "Memory clock", memory and (memory .. " MHz"))
end

--- Temperature, power and fan from the hwmon nodes under a GPU device.
local function gpu_hwmon_rows(g, dev, card)
    for _, hwmon in ipairs(list_dir(dev .. "hwmon") or {}) do
        local dir = dev .. "hwmon/" .. hwmon .. "/"
        local temp_mc = read_num(dir .. "temp1_input")
        if temp_mc then
            add_metric(g, "Temperature", string.format("%.1f °C", temp_mc / 1000),
                card .. "/temp", temp_mc / 1000, "°C")
        end
        local power_uw = read_num(dir .. "power1_average") or read_num(dir .. "power1_input")
        add(g, "Power", power_uw and string.format("%.1f W", power_uw / 1000000))
        local fan_rpm = read_num(dir .. "fan1_input")
        add(g, "Fan", fan_rpm and (fan_rpm .. " RPM"))
    end
end

local function drm_card_group(card)
    local card_dir = DRM_DIR .. "/" .. card .. "/"
    local dev = card_dir .. "device/"
    local g = new_group("GPU Details (" .. card .. ")")
    add(g, "Driver", link_base(dev .. "driver"))
    add(g, "PCIe link", pcie_link(dev))
    intel_frequency_row(g, card_dir, card)
    amdgpu_rows(g, dev, card)
    gpu_hwmon_rows(g, dev, card)
    return g
end

local function nvidia_groups()
    local groups = {}
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

--- Per-GPU live details: PCIe link, clocks, utilization, VRAM, temperature.
--- Covers Intel (i915/xe), AMD (amdgpu) and the NVIDIA proprietary driver.
function HW.collect_gpu_details()
    local groups = {}
    for _, name in ipairs(list_dir(DRM_DIR) or {}) do
        if name:match("^card%d+$") then
            local g = drm_card_group(name)
            if #g.items > 0 then
                groups[#groups + 1] = g
            end
        end
    end
    for _, g in ipairs(nvidia_groups()) do
        groups[#groups + 1] = g
    end
    return groups
end

--- GPU/PCI tab: graphics adapters, live GPU details, displays, all PCI devices.
function HW.collect_gpu_pci()
    local devices, vendors = read_pci_devices()
    if not devices then
        local g = new_group("PCI Devices")
        add(g, "PCI", "N/A (cannot read " .. PCI_DIR .. ")")
        return { g }
    end
    local names = HW.load_pci_names(vendors)
    local gpu, pci = new_group("Graphics"), new_group("PCI Devices")
    for _, dev in ipairs(devices) do
        local label, text = dev.addr .. " " .. dev.kind, describe_pci_device(dev, names)
        add(pci, label, text)
        if dev.class:sub(1, 2) == PCI_BASE_CLASS_DISPLAY then
            add(gpu, label, text)
            local vram = read_num(dev.dir .. "mem_info_vram_total")
            add(gpu, "  VRAM", vram and format_bytes(vram))
        end
    end
    if #gpu.items == 0 then
        add(gpu, "GPU", "N/A (no display-class PCI device)")
    end
    if #pci.items == 0 then
        add(pci, "PCI", "N/A (no devices)")
    end
    local groups = { gpu }
    for _, g in ipairs(HW.collect_gpu_details()) do
        groups[#groups + 1] = g
    end
    groups[#groups + 1] = HW.collect_displays()
    groups[#groups + 1] = pci
    return groups
end

-- Storage -------------------------------------------------------------------
local NVME_DIR = "/sys/class/nvme"
local SECTOR_BYTES = 512

-- NVMe admin passthrough: ioctl NVME_IOCTL_ADMIN_CMD = _IOWR('N', 0x41, 72-byte command).
local NVME_IOCTL_ADMIN_CMD = 0xC0484E41
local NVME_ADMIN_GET_LOG_PAGE = 0x02
local NVME_LOG_SMART_HEALTH = 0x02
local NVME_NSID_ALL = 0xFFFFFFFF
local SMART_LOG_BYTES = 512

-- Byte offsets inside the SMART / Health log page (NVMe base specification).
local SMART_OFFSET = {
    data_units_read = 32,
    data_units_written = 48,
    power_cycles = 112,
    power_on_hours = 128,
    unsafe_shutdowns = 144,
    media_errors = 160,
}
local SMART_MIN_BYTES = 192 -- through the error-log-entries counter at offset 176
local SMART_DATA_UNIT_BYTES = 512000 -- one "data unit" is 1000 sectors of 512 bytes

--- Read a little-endian 64-bit counter at 0-based `off` (exact below 2^53).
local function le64(buf, off)
    local value = 0
    for i = 7, 0, -1 do
        value = value * 256 + buf:byte(off + i + 1)
    end
    return value
end

--- Parse a 512-byte NVMe SMART / Health log page; nil when the buffer is too short.
function HW.parse_nvme_smart(buf)
    if #buf < SMART_MIN_BYTES then
        return nil
    end
    local kelvin = buf:byte(2) + buf:byte(3) * 256
    return {
        critical_warning = buf:byte(1),
        temp_c = kelvin > 0 and kelvin - 273 or nil,
        spare_pct = buf:byte(4),
        spare_threshold = buf:byte(5),
        used_pct = buf:byte(6),
        read_bytes = le64(buf, SMART_OFFSET.data_units_read) * SMART_DATA_UNIT_BYTES,
        written_bytes = le64(buf, SMART_OFFSET.data_units_written) * SMART_DATA_UNIT_BYTES,
        power_cycles = le64(buf, SMART_OFFSET.power_cycles),
        power_on_hours = le64(buf, SMART_OFFSET.power_on_hours),
        unsafe_shutdowns = le64(buf, SMART_OFFSET.unsafe_shutdowns),
        media_errors = le64(buf, SMART_OFFSET.media_errors),
    }
end

--- Read the SMART log through the NVMe admin ioctl (normally root only).
--- Returns the parsed table, or nil plus a message naming the failed step.
function HW.read_nvme_smart(devpath)
    local EACCES = 13
    local fd = ffi.C.open(devpath, 0)
    if fd < 0 then
        local errno = ffi.errno()
        return nil, string.format("cannot open %s: %s", devpath,
            errno == EACCES and "permission denied (run as root)" or ("errno " .. errno))
    end
    local data = ffi.new("uint8_t[?]", SMART_LOG_BYTES)
    local cmd = ffi.new("struct hw_nvme_admin_cmd")
    cmd.opcode = NVME_ADMIN_GET_LOG_PAGE
    cmd.nsid = NVME_NSID_ALL
    cmd.addr = tonumber(ffi.cast("uintptr_t", data))
    cmd.data_len = SMART_LOG_BYTES
    -- cdw10: bits 31..16 = number of dwords - 1, bits 7..0 = log page id.
    cmd.cdw10 = bit.bor(bit.lshift(SMART_LOG_BYTES / 4 - 1, 16), NVME_LOG_SMART_HEALTH)
    local rc = ffi.C.ioctl(fd, NVME_IOCTL_ADMIN_CMD, cmd)
    local errno = ffi.errno()
    ffi.C.close(fd)
    if rc ~= 0 then
        return nil, string.format("NVMe SMART ioctl on %s failed (rc=%d, errno %d)", devpath,
            rc, errno)
    end
    local parsed = HW.parse_nvme_smart(ffi.string(data, SMART_LOG_BYTES))
    if not parsed then
        return nil, "NVMe SMART log too short"
    end
    return parsed
end

local function add_smart_rows(g, smart)
    local health = "OK"
    if smart.critical_warning ~= 0 then
        health = string.format("WARNING (flags 0x%02x)", smart.critical_warning)
    end
    add(g, "Health", health)
    add(g, "Wear", string.format("%d%% used", smart.used_pct))
    add(g, "Spare", string.format("%d%% (threshold %d%%)", smart.spare_pct,
        smart.spare_threshold))
    add(g, "Data written", format_bytes(smart.written_bytes))
    add(g, "Data read", format_bytes(smart.read_bytes))
    add(g, "Power-on", string.format("%d h", smart.power_on_hours))
    add(g, "Power cycles", smart.power_cycles)
    add(g, "Unsafe shutdowns", smart.unsafe_shutdowns)
    add(g, "Media errors", smart.media_errors)
end

local function nvme_controller_group(name)
    local dir = NVME_DIR .. "/" .. name .. "/"
    local g = new_group("NVMe Controller " .. name)
    add(g, "Model", read_str(dir .. "model"))
    add(g, "Firmware", read_str(dir .. "firmware_rev"))
    add(g, "State", read_str(dir .. "state"))
    add(g, "Transport", read_str(dir .. "transport"))
    add(g, "I/O queues", read_str(dir .. "queue_count"))
    add(g, "PCIe link", pcie_link(dir .. "device/"))
    for _, entry in ipairs(list_dir(dir) or {}) do
        local temp_mc = entry:match("^hwmon%d+$") and read_num(dir .. entry .. "/temp1_input")
        if temp_mc then
            add_metric(g, "Temperature", string.format("%.1f °C", temp_mc / 1000),
                name .. "/temp", temp_mc / 1000, "°C")
        end
    end
    local smart, err = HW.read_nvme_smart("/dev/" .. name)
    if smart then
        add_smart_rows(g, smart)
    else
        add(g, "SMART", "N/A (" .. err .. ")")
    end
    return g
end

--- One group per NVMe controller: identity, link, temperature and SMART health.
function HW.collect_nvme()
    local groups = {}
    for _, name in ipairs(list_dir(NVME_DIR) or {}) do
        groups[#groups + 1] = nvme_controller_group(name)
    end
    return groups
end

local function describe_block_device(name)
    local dir = "/sys/block/" .. name .. "/"
    local rotational = read_num(dir .. "queue/rotational")
    local kind = "disk"
    if name:match("^nvme") then
        kind = "NVMe SSD"
    elseif rotational == 1 then
        kind = "HDD"
    elseif rotational == 0 then
        kind = "SSD"
    end
    local scheduler = read_str(dir .. "queue/scheduler")
    return join("  ",
        format_bytes((read_num(dir .. "size") or 0) * SECTOR_BYTES),
        kind,
        read_str(dir .. "device/model"),
        read_num(dir .. "removable") == 1 and "(removable)" or nil,
        scheduler and ("sched: " .. (scheduler:match("%[([^%]]+)%]") or scheduler)))
end

local function block_devices_group()
    local g = new_group("Block Devices")
    local names = list_dir("/sys/block")
    if not names then
        add(g, "Disks", "N/A (cannot read /sys/block)")
        return g
    end
    for _, name in ipairs(names) do
        if not name:match("^loop") and not name:match("^ram") then
            add(g, name, describe_block_device(name))
        end
    end
    if #g.items == 0 then
        add(g, "Disks", "N/A (no block devices)")
    end
    return g
end

--- Group /proc/mounts lines by backing device (only device-backed mounts), keeping
--- first-seen order. Returns a list of { dev, fs, mounts = { mountpoints } }.
local function mounts_by_device(mounts_text)
    local ordered, by_dev = {}, {}
    for line in mounts_text:gmatch("[^\n]+") do
        local dev, mountpoint, fs = line:match("^(%S+)%s+(%S+)%s+(%S+)")
        if dev and dev:sub(1, 1) == "/" then
            local entry = by_dev[dev]
            if not entry then
                entry = { dev = dev, fs = fs, mounts = {} }
                by_dev[dev] = entry
                ordered[#ordered + 1] = entry
            end
            -- /proc/mounts escapes spaces in paths as \040
            entry.mounts[#entry.mounts + 1] = mountpoint:gsub("\\040", " ")
        end
    end
    return ordered
end

local function describe_mount(entry)
    local mountpoint = entry.mounts[1]
    local extra
    if #entry.mounts > 1 then
        extra = string.format("(+%d more: %s)", #entry.mounts - 1,
            table.concat(entry.mounts, ", ", 2))
    end
    local sv = ffi.new("struct hw_statvfs")
    if ffi.C.statvfs(mountpoint, sv) ~= 0 or tonumber(sv.f_blocks) == 0 then
        return mountpoint, join("  ", entry.dev, entry.fs, "(statvfs unavailable)", extra)
    end
    local block = tonumber(sv.f_frsize)
    local total = tonumber(sv.f_blocks) * block
    local used = total - tonumber(sv.f_bfree) * block
    local free = tonumber(sv.f_bavail) * block
    local usage = string.format("used %s / %s (%.0f%%)  free %s", format_bytes(used),
        format_bytes(total), used * 100 / total, format_bytes(free))
    return mountpoint, join("  ", entry.dev, entry.fs, usage, extra)
end

local function mounts_group()
    local g = new_group("Mounted Filesystems")
    local text = read_raw("/proc/mounts")
    if not text then
        add(g, "Mounts", "N/A (cannot read /proc/mounts)")
        return g
    end
    for _, entry in ipairs(mounts_by_device(text)) do
        add(g, describe_mount(entry))
    end
    if #g.items == 0 then
        add(g, "Mounts", "N/A (no device-backed mounts)")
    end
    return g
end

--- Storage tab: block devices, NVMe controllers and mounted filesystems.
function HW.collect_storage()
    local groups = { block_devices_group() }
    for _, g in ipairs(HW.collect_nvme()) do
        groups[#groups + 1] = g
    end
    groups[#groups + 1] = mounts_group()
    return groups
end

-- Network -------------------------------------------------------------------
local AF_INET = 2

--- Map interface name -> dotted IPv4 address via getifaddrs.
--- Returns the map, plus an error string when getifaddrs failed.
local function ipv4_by_interface()
    local result = {}
    local head = ffi.new("struct hw_ifaddrs *[1]")
    if ffi.C.getifaddrs(head) ~= 0 then
        return result, "getifaddrs failed"
    end
    local node = head[0]
    while node ~= nil do
        if node.ifa_addr ~= nil and node.ifa_addr.sa_family == AF_INET then
            local d = node.ifa_addr.sa_data -- sockaddr_in: 2 port bytes, then the address
            result[ffi.string(node.ifa_name)] = string.format("%d.%d.%d.%d", d[2], d[3], d[4], d[5])
        end
        node = node.ifa_next
    end
    ffi.C.freeifaddrs(head[0])
    return result
end

local function describe_interface(name, ipv4)
    local dir = "/sys/class/net/" .. name .. "/"
    local speed = read_num(dir .. "speed")
    local driver = link_base(dir .. "device/driver")
    local mtu = read_str(dir .. "mtu")
    return join("  ",
        read_str(dir .. "operstate") or "unknown",
        ipv4,
        read_str(dir .. "address"),
        speed and speed > 0 and (speed .. " Mb/s") or nil,
        driver and ("driver: " .. driver),
        mtu and ("mtu " .. mtu))
end

--- Network tab: interface state, IPv4, MAC, link speed, driver and MTU.
function HW.collect_network()
    local g = new_group("Interfaces")
    local names = list_dir("/sys/class/net")
    if not names then
        add(g, "Network", "N/A (cannot read /sys/class/net)")
        return { g }
    end
    local ipv4, ip_err = ipv4_by_interface()
    for _, name in ipairs(names) do
        add(g, name, describe_interface(name, ipv4[name]))
    end
    if #g.items == 0 then
        add(g, "Network", "N/A (no interfaces)")
    end
    if ip_err then
        add(g, "IPv4", "N/A (" .. ip_err .. ")")
    end
    return { g }
end

-- Sensors -------------------------------------------------------------------
local HWMON_DIR = "/sys/class/hwmon"

-- hwmon "<kind>N_input" attributes: `divisor` converts the raw sysfs integer to the
-- displayed unit (millidegrees, millivolts, microwatts), `fmt` renders it.
local HWMON_KINDS = {
    temp = { divisor = 1000, unit = "°C", fmt = "%.1f °C" },
    fan = { divisor = 1, unit = "RPM", fmt = "%d RPM" },
    ["in"] = { divisor = 1000, unit = "V", fmt = "%.3f V" },
    power = { divisor = 1000000, unit = "W", fmt = "%.2f W" },
}

local function hwmon_group(hwmon)
    local dir = HWMON_DIR .. "/" .. hwmon .. "/"
    local g = new_group((read_str(dir .. "name") or hwmon) .. " (" .. hwmon .. ")")
    for _, file in ipairs(list_dir(HWMON_DIR .. "/" .. hwmon) or {}) do
        local kind, index = file:match("^(%a+)(%d+)_input$")
        local spec = kind and HWMON_KINDS[kind]
        local raw = spec and read_num(dir .. file)
        if raw then
            local label = read_str(dir .. kind .. index .. "_label") or (kind .. index)
            local value = raw / spec.divisor
            add_metric(g, label, string.format(spec.fmt, value), hwmon .. "/" .. file, value,
                spec.unit)
        end
    end
    return g
end

local function describe_power_supply(name)
    local dir = "/sys/class/power_supply/" .. name .. "/"
    local kind = read_str(dir .. "type") or "?"
    if kind == "Mains" then
        return join("  ", kind, read_num(dir .. "online") == 1 and "online" or "offline")
    elseif kind ~= "Battery" then
        return kind
    end
    local capacity = read_str(dir .. "capacity")
    local full = read_num(dir .. "energy_full") or read_num(dir .. "charge_full")
    local design = read_num(dir .. "energy_full_design") or read_num(dir .. "charge_full_design")
    local health = full and design and design > 0
        and string.format("health %.0f%%", full * 100 / design)
    local cycles = read_num(dir .. "cycle_count")
    return join("  ", kind, read_str(dir .. "status"), capacity and (capacity .. "%"), health,
        read_str(dir .. "model_name"), cycles and cycles > 0 and (cycles .. " cycles") or nil)
end

--- Sensors tab: every hwmon temperature/fan/voltage/power input, plus batteries and
--- AC adapters from /sys/class/power_supply.
function HW.collect_sensors()
    local groups = {}
    for _, hwmon in ipairs(list_dir(HWMON_DIR) or {}) do
        local g = hwmon_group(hwmon)
        if #g.items > 0 then
            groups[#groups + 1] = g
        end
    end
    if #groups == 0 then
        local g = new_group("Hardware Monitors")
        add(g, "hwmon", "N/A (no sensors exposed in " .. HWMON_DIR .. ")")
        groups[1] = g
    end
    local supplies = new_group("Power Supplies")
    for _, name in ipairs(list_dir("/sys/class/power_supply") or {}) do
        add(supplies, name, describe_power_supply(name))
    end
    if #supplies.items > 0 then
        groups[#groups + 1] = supplies
    end
    return groups
end

-- USB -----------------------------------------------------------------------
--- USB tab: devices and hubs (interface entries such as "1-1:1.0" are skipped).
function HW.collect_usb()
    local g = new_group("USB Devices")
    local names = list_dir("/sys/bus/usb/devices")
    if not names then
        add(g, "USB", "N/A (cannot read /sys/bus/usb/devices)")
        return { g }
    end
    for _, name in ipairs(names) do
        local dir = "/sys/bus/usb/devices/" .. name .. "/"
        local vendor, product = read_str(dir .. "idVendor"), read_str(dir .. "idProduct")
        if not name:find(":", 1, true) and vendor and product then
            local speed = read_str(dir .. "speed")
            add(g, name, join(" ", string.format("[%s:%s]", vendor, product),
                read_str(dir .. "manufacturer"), read_str(dir .. "product"),
                speed and (speed .. " Mb/s")))
        end
    end
    if #g.items == 0 then
        add(g, "USB", "N/A (no devices)")
    end
    return { g }
end

-- Tab registry --------------------------------------------------------------
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

--- Collect every tab. Returns a list of { id, title, groups }.
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
local JSON_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function json_str(s)
    local escaped = s:gsub('[%c"\\]', function(c)
        return JSON_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. escaped .. '"'
end

--- Encode `list` as a JSON array, applying `encode` to every element.
local function json_array(list, encode)
    local parts = {}
    for i, element in ipairs(list) do
        parts[i] = encode(element)
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function json_item(item)
    return string.format('{"label":%s,"value":%s}', json_str(item.label), json_str(item.value))
end

local function json_group(group)
    return string.format('{"title":%s,"items":%s}', json_str(group.title),
        json_array(group.items, json_item))
end

local function json_tab(tab)
    return string.format('{"id":%s,"title":%s,"groups":%s}', json_str(tab.id),
        json_str(tab.title), json_array(tab.groups, json_group))
end

--- Serialize the collected tabs as {"tabs":[{id,title,groups:[{title,items}]}]}.
function HW.to_json(data)
    return '{"tabs":' .. json_array(data, json_tab) .. "}\n"
end

--- Write the snapshot to `path` and verify it by reading it back.
--- Returns true plus a success message, or false plus the failure reason.
function HW.export_json(data, path)
    local json = HW.to_json(data)
    local file, open_err = io.open(path, "wb")
    if not file then
        return false, "cannot write " .. path .. ": " .. tostring(open_err)
    end
    local written, write_err = file:write(json)
    file:close()
    if not written then
        return false, "write failed for " .. path .. ": " .. tostring(write_err)
    end
    local check = io.open(path, "rb")
    if not check then
        return false, "verification failed: cannot reopen " .. path
    end
    local content = check:read("*a")
    check:close()
    if content ~= json then
        return false, "verification failed: content mismatch in " .. path
    end
    return true, string.format("Saved %d bytes to %s", #json, path)
end

-- =========================================================================
-- 5. Text layout helpers (UTF-8 aware)
-- =========================================================================
--- Number of bytes in the UTF-8 character that starts with byte `lead`.
local function utf8_char_length(lead)
    if lead >= 240 then
        return 4
    elseif lead >= 224 then
        return 3
    elseif lead >= 192 then
        return 2
    end
    return 1
end

local function is_continuation_byte(byte)
    return byte >= 128 and byte < 192
end

--- Display width of `s`, counting one column per UTF-8 character.
local function ulen(s)
    local _, count = s:gsub("[^\128-\191]", "")
    return count
end

--- Truncate to at most `width` columns, appending an ellipsis when cut.
local function truncate(s, width)
    if width <= 0 then
        return ""
    end
    if ulen(s) <= width then
        return s
    end
    local chars, pos = 0, 1
    while pos <= #s and chars < width - 1 do
        pos = pos + utf8_char_length(s:byte(pos))
        chars = chars + 1
    end
    return s:sub(1, pos - 1) .. "…"
end

--- Longest prefix of `s` that is at most `max_bytes` long and ends on a character
--- boundary.
local function utf8_prefix(s, max_bytes)
    if #s <= max_bytes then
        return s
    end
    local cut = max_bytes
    -- Back up to the lead byte of the character the cut would split.
    local lead = cut + 1
    while lead > 1 and is_continuation_byte(s:byte(lead)) do
        lead = lead - 1
    end
    if lead <= cut then
        cut = lead - 1
    end
    return s:sub(1, cut)
end

--- Word-wrap `text` to `width` columns (minimum 4); over-long words are split.
local function wrap(text, width)
    width = math.max(width, 4)
    local lines, current = {}, ""
    for word in text:gmatch("%S+") do
        while ulen(word) > width do
            if current ~= "" then
                lines[#lines + 1] = current
                current = ""
            end
            local piece = utf8_prefix(word, width)
            lines[#lines + 1] = piece
            word = word:sub(#piece + 1)
        end
        if current == "" then
            current = word
        elseif ulen(current) + 1 + ulen(word) <= width then
            current = current .. " " .. word
        else
            lines[#lines + 1] = current
            current = word
        end
    end
    if current ~= "" or #lines == 0 then
        lines[#lines + 1] = current
    end
    return lines
end

-- =========================================================================
-- 6. Sensor history (sparklines) and display lines
-- =========================================================================
local SPARK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local HISTORY_MAX = 30
local LABEL_MIN_COLS, LABEL_MAX_COLS = 12, 34

local function push_sample(history, key, value)
    local samples = history[key]
    if not samples then
        samples = {}
        history[key] = samples
    end
    samples[#samples + 1] = value
    if #samples > HISTORY_MAX then
        table.remove(samples, 1)
    end
end

--- Append the current value of every metric row (rows with a `key`) to `history`.
function HW.record_history(history, data)
    for _, tab in ipairs(data) do
        for _, group in ipairs(tab.groups) do
            for _, item in ipairs(group.items) do
                if item.key and item.num then
                    push_sample(history, item.key, item.num)
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
    local low, high = math.huge, -math.huge
    for _, v in ipairs(samples) do
        low = math.min(low, v)
        high = math.max(high, v)
    end
    local bars = {}
    for i, v in ipairs(samples) do
        local level = 4 -- a flat series is drawn at mid height
        if high > low then
            level = 1 + math.floor((v - low) / (high - low) * (#SPARK_CHARS - 1) + 0.5)
        end
        bars[i] = SPARK_CHARS[level]
    end
    local number = unit == "RPM" and "%.0f" or "%.1f"
    return string.format("%s min " .. number .. " max " .. number, table.concat(bars), low, high)
end

--- Width of the label column: widest label, clamped to a third of the screen.
local function label_column_width(groups, width)
    local label_w = LABEL_MIN_COLS
    for _, group in ipairs(groups) do
        for _, item in ipairs(group.items) do
            label_w = math.max(label_w, math.min(ulen(item.label), LABEL_MAX_COLS))
        end
    end
    return math.min(label_w, math.max(8, math.floor(width / 3)))
end

--- Items of `group` whose "label value" text contains `needle` (all when nil).
local function matching_items(group, needle)
    if not needle then
        return group.items
    end
    local kept = {}
    for _, item in ipairs(group.items) do
        if (item.label .. " " .. item.value):lower():find(needle, 1, true) then
            kept[#kept + 1] = item
        end
    end
    return kept
end

local function item_text(item, history)
    local spark = history and item.key and HW.sparkline(history[item.key], item.unit)
    if spark and spark ~= "" then
        return item.value .. "  " .. spark
    end
    return item.value
end

--- Flatten a tab's groups into display lines for the given width and filter.
--- Lines are { kind = "hdr" | "kv" | "blank", ... }; long values wrap onto extra "kv"
--- lines with an empty label. `history` (optional) adds sparklines to metric rows.
function HW.flatten(groups, width, filter, history)
    local needle = filter and filter ~= "" and filter:lower() or nil
    local label_w = label_column_width(groups, width)
    local value_w = math.max(4, width - label_w - 4)
    local lines = {}
    for _, group in ipairs(groups) do
        local kept = matching_items(group, needle)
        if #kept > 0 then
            if #lines > 0 then
                lines[#lines + 1] = { kind = "blank" }
            end
            lines[#lines + 1] = { kind = "hdr", text = group.title }
            for _, item in ipairs(kept) do
                for i, part in ipairs(wrap(item_text(item, history), value_w)) do
                    lines[#lines + 1] = {
                        kind = "kv",
                        label = i == 1 and truncate(item.label, label_w) or "",
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
-- 7. Pure frame generators
-- =========================================================================
local MIN_COLS, MIN_ROWS = 24, 7
local CHROME_ROWS = 4 -- tab bar, two rules and the footer; the rest shows content

-- SGR colour escapes (Tokyo Night palette).
local C = {
    reset = "\27[0m",
    dim = "\27[2m",
    title = "\27[1;38;2;192;202;245m",
    accent = "\27[1;38;2;125;207;255m",
    tab_on = "\27[1;48;2;41;46;66;38;2;255;255;255m",
    tab_off = "\27[38;2;130;140;180m",
    hdr = "\27[1;38;2;122;162;247m",
    label = "\27[38;2;169;177;214m",
    value = "\27[38;2;220;225;245m",
    rule = "\27[38;2;65;72;104m",
    err = "\27[1;38;2;247;118;142m",
    ok = "\27[38;2;158;206;106m",
    na = "\27[38;2;224;175;104m",
}

--- Create the UI state for collected `data`: active tab, per-tab scroll offsets,
--- filter text, one-shot status message and the sensor history.
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

local function body_height(rows)
    return math.max(1, rows - CHROME_ROWS)
end

local function visible_lines(state, width)
    local tab = state.data[state.tab]
    return HW.flatten(tab.groups, width, state.filter, state.history)
end

--- Clamp the active tab's scroll offset to the content. Returns lines, offset.
local function clamp_scroll(state, width, rows)
    local lines = visible_lines(state, width)
    local max_scroll = math.max(0, #lines - body_height(rows))
    local offset = math.min(math.max(state.scroll[state.tab], 0), max_scroll)
    state.scroll[state.tab] = offset
    return lines, offset
end

local function render_tabbar(state, width)
    local labels = {}
    for i, tab in ipairs(state.data) do
        labels[i] = string.format(" %d:%s ", i, tab.title)
    end
    if ulen(" HWINFO " .. table.concat(labels)) > width then
        -- Too narrow for every tab: show only the active one.
        local tab = state.data[state.tab]
        local compact = string.format(" HWINFO  ‹ %s %d/%d ›", tab.title, state.tab, #state.data)
        return C.title .. truncate(compact, width) .. C.reset
    end
    local out = { C.title, " HWINFO ", C.reset }
    for i, label in ipairs(labels) do
        out[#out + 1] = (i == state.tab and C.tab_on or C.tab_off) .. label .. C.reset
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
    local help = " ←/→ tab  ↑/↓ PgUp/PgDn scroll  / filter  e export  r refresh  q quit"
    if state.filter ~= "" then
        help = " filter: " .. state.filter .. "  (Esc clears)  " .. help:sub(2)
    end
    return C.dim .. truncate(help, width) .. C.reset
end

--- Footer row plus, when the content scrolls, a "first-last/total" position marker.
local function render_footer_row(state, width, offset, body_h, total)
    local position = ""
    if total > body_h then
        position = string.format(" %d-%d/%d ", offset + 1, math.min(total, offset + body_h), total)
    end
    local reserved = position ~= "" and ulen(position) + 2 or 0
    local footer = render_footer(state, width - reserved)
    if position ~= "" and not state.filter_mode then
        return footer .. C.dim .. "  " .. position .. C.reset
    end
    return footer
end

local function render_body_row(line, width, show_empty_hint)
    if line == nil then
        if show_empty_hint then
            return C.na .. truncate(" (no matching entries)", width) .. C.reset
        end
        return ""
    elseif line.kind == "hdr" then
        return " " .. C.hdr .. truncate(line.text, width - 1) .. C.reset
    elseif line.kind == "kv" then
        local pad = string.rep(" ", math.max(0, line.label_w - ulen(line.label)))
        local value_color = line.value:find("^N/A") and C.na or C.value
        local value = truncate(line.value, math.max(1, width - line.label_w - 5))
        return "   " .. C.label .. line.label .. pad .. C.reset .. "  " .. value_color .. value
            .. C.reset
    end
    return "" -- blank separator line
end

local function render_too_small(width, rows)
    local screen = {}
    for i = 1, rows do
        screen[i] = ""
    end
    screen[1] = C.err .. truncate("Terminal too small", width) .. C.reset
    if rows >= 2 then
        screen[2] = truncate(string.format("need at least %dx%d", MIN_COLS, MIN_ROWS), width)
    end
    return screen
end

--- Build the whole screen as an array of `h` row strings (no cursor addressing).
--- Rows are one column narrower than the terminal so nothing touches the last column.
function HW.frame_rows(state, w, h)
    local width = math.max(1, w - 1)
    if w < MIN_COLS or h < MIN_ROWS then
        return render_too_small(width, h)
    end
    local lines, offset = clamp_scroll(state, width, h)
    local body_h = body_height(h)
    local rule = C.rule .. string.rep("─", width) .. C.reset
    local rows = { render_tabbar(state, width), rule }
    for i = 1, body_h do
        rows[#rows + 1] = render_body_row(lines[offset + i], width, i == 1 and #lines == 0)
    end
    rows[#rows + 1] = rule
    rows[#rows + 1] = render_footer_row(state, width, offset, body_h, #lines)
    return rows
end

--- Emit only the rows that differ from `prev` (cursor-addressed, each cleared to EOL),
--- wrapped in synchronized-update escapes. Returns "" when nothing changed.
function HW.diff_frame(prev, rows)
    local out = { "\27[?2026h" }
    for i, row in ipairs(rows) do
        if prev == nil or prev[i] ~= row then
            out[#out + 1] = string.format("\27[%d;1H%s\27[K", i, row)
        end
    end
    if #out == 1 then
        return ""
    end
    out[#out + 1] = "\27[?2026l"
    return table.concat(out)
end

--- Whole-frame string (used for headless assertions and the first paint).
function HW.render_frame(state, w, h)
    return HW.diff_frame(nil, HW.frame_rows(state, w, h))
end

-- =========================================================================
-- 8. Input handling (pure state transitions)
-- =========================================================================
--- Remove the last UTF-8 character from `s` (no-op on an empty string).
local function utf8_pop(s)
    local i = #s
    while i > 1 and is_continuation_byte(s:byte(i)) do
        i = i - 1
    end
    return s:sub(1, i - 1)
end

--- Apply a key to the filter prompt. ENTER keeps the filter, ESC discards it.
local function edit_filter(state, key)
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
        local is_symbolic = key:match("^[A-Z][A-Z_]+$") ~= nil -- UP, TAB, PAGE_DOWN, ...
        if not is_symbolic and key:byte(1) >= 32 then
            state.filter = state.filter .. key
        end
    end
    state.scroll[state.tab] = 0
end

--- Switch tabs for arrow/number keys. Returns true when the key was a tab key.
local function change_tab(state, key)
    local count = #state.data
    if key == "RIGHT" or key == "l" or key == "TAB" then
        state.tab = state.tab % count + 1
    elseif key == "LEFT" or key == "h" or key == "SHIFT_TAB" then
        state.tab = (state.tab - 2) % count + 1
    elseif key:match("^[1-9]$") and tonumber(key) <= count then
        state.tab = tonumber(key)
    else
        return false
    end
    return true
end

--- Scroll the active tab. Offsets are clamped later by clamp_scroll.
local function scroll_view(state, key, page)
    local offset = state.scroll[state.tab]
    if key == "DOWN" or key == "j" then
        offset = offset + 1
    elseif key == "UP" or key == "k" then
        offset = offset - 1
    elseif key == "PAGE_DOWN" or key == "SPACE" then
        offset = offset + page
    elseif key == "PAGE_UP" then
        offset = offset - page
    elseif key == "HOME" or key == "g" then
        offset = 0
    elseif key == "END" or key == "G" then
        offset = math.huge
    end
    state.scroll[state.tab] = offset
end

--- Apply one key token to `state`. Returns "quit", "refresh" or "export" when the
--- caller must act, otherwise nil. `w`, `h` (optional) enable scroll clamping.
function HW.handle_key(state, key, w, h)
    if type(key) ~= "string" then
        return nil
    end
    state.status = nil
    state.status_err = false
    if state.filter_mode then
        edit_filter(state, key)
        return nil
    end
    if key == "q" or key == "Q" then
        return "quit"
    elseif key == "r" then
        return "refresh"
    elseif key == "e" then
        return "export"
    elseif key == "/" then
        state.filter_mode = true
    elseif key == "ESC" then
        state.filter = ""
    elseif not change_tab(state, key) then
        scroll_view(state, key, body_height(h or 24))
    end
    if w and h then
        clamp_scroll(state, math.max(1, w - 1), h)
    end
    return nil
end

-- =========================================================================
-- 9. Terminal control (provided by termkit)
-- =========================================================================
local DEFAULT_COLS, DEFAULT_ROWS = 100, 30 -- size assumed when running headless
local CLEAR_SCREEN = "\27[2J"

-- Key tokenizer, exposed for the test suite.
HW.next_token = termkit.next_token

-- =========================================================================
-- 10. TUI main loop
-- =========================================================================
local REFRESH_SECONDS = 2
local KEY_POLL_MS = 250
local DEFAULT_EXPORT_PATH = "hwinfo_snapshot.json"

local function report(message)
    io.stderr:write("hwinfo: " .. message .. "\n")
    io.stderr:flush()
end

--- Re-collect the active tab and the sensors tab, recording sensor history.
function HW.refresh_live(state)
    local stale = { [state.tab] = true }
    for i, tab in ipairs(HW.TABS) do
        if tab.id == "sensors" then
            stale[i] = true
        end
    end
    for i in pairs(stale) do
        state.data[i].groups = HW.safe_collect(HW.TABS[i])
        HW.record_history(state.history, { state.data[i] })
    end
end

local function select_tab(state, tab_id)
    for i, tab in ipairs(state.data) do
        if tab.id == tab_id then
            state.tab = i
        end
    end
end

--- Perform a "refresh" or "export" action requested by handle_key.
local function run_action(state, action, opts)
    if action == "refresh" then
        state.data = HW.collect_all()
        HW.record_history(state.history, state.data)
        state.status = "Refreshed"
    elseif action == "export" then
        local saved, message = HW.export_json(state.data, opts.export_path or DEFAULT_EXPORT_PATH)
        state.status = message
        state.status_err = not saved
    end
end

--- Draw the frame (only changed rows) and return it for the next diff.
local function paint(state, w, h, previous)
    local rows = HW.frame_rows(state, w, h)
    local output = HW.diff_frame(previous, rows)
    if output ~= "" then
        io.write(output)
        io.flush()
    end
    return rows
end

--- Paint, read keys and refresh until the user quits or input ends.
local function event_loop(state, opts, interactive)
    local w, h = DEFAULT_COLS, DEFAULT_ROWS
    if interactive then
        w, h = termkit.size()
    end
    local previous
    local last_refresh = os.time()
    while true do
        if interactive then
            local new_w, new_h = termkit.size()
            if new_w ~= w or new_h ~= h then
                w, h, previous = new_w, new_h, nil
                io.write(CLEAR_SCREEN) -- resize is one of the few times a full clear is allowed
            end
        end
        previous = paint(state, w, h, previous)
        local key = termkit.read_key(KEY_POLL_MS)
        if key == "EOF" then
            return
        elseif key then
            local action = HW.handle_key(state, key, w, h)
            if action == "quit" then
                return
            elseif action then
                run_action(state, action, opts)
            end
        elseif os.time() - last_refresh >= REFRESH_SECONDS then
            last_refresh = os.time()
            HW.refresh_live(state)
        end
    end
end

--- Run the interactive viewer. Returns a process exit code.
function HW.run_tui(opts)
    opts = opts or {}
    report("collecting hardware data...")
    local state = new_state(HW.collect_all())
    if opts.tab then
        select_tab(state, opts.tab)
    end
    local interactive = termkit.enter()
    if not interactive then
        report("stdin/stdout is not a terminal; running headless (keys read from stdin, 100x30)")
    end
    local ok, err = pcall(event_loop, state, opts, interactive)
    termkit.leave() -- always restore the terminal, even after an error
    if not ok then
        report("fatal error: " .. tostring(err))
        return 1
    end
    return 0
end

-- =========================================================================
-- 11. CLI entry point
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

--- Plain-text report of all tabs, wrapped to `width` columns.
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

local function is_tab_id(id)
    for _, tab in ipairs(HW.TABS) do
        if tab.id == id then
            return true
        end
    end
    return false
end

--- Parse command-line arguments into { mode = "tui"|"json"|"text", tab = id }.
--- Returns nil plus an exit code when the program should stop (help or bad usage).
local function parse_args(args)
    local opts = { mode = "tui" }
    local i = 1
    while i <= #args do
        local arg_i = args[i]
        if arg_i == "--help" or arg_i == "-h" then
            print_help()
            return nil, 0
        elseif arg_i == "--json" then
            opts.mode = "json"
        elseif arg_i == "--text" then
            opts.mode = "text"
        elseif arg_i == "--tab" then
            i = i + 1
            opts.tab = args[i]
            if not is_tab_id(opts.tab) then
                report("invalid --tab value '" .. tostring(opts.tab)
                    .. "' (use: system cpu memory gpu storage network sensors usb)")
                return nil, 2
            end
        else
            report("unknown option '" .. tostring(arg_i) .. "' (try --help)")
            return nil, 2
        end
        i = i + 1
    end
    return opts
end

--- Program entry point. Returns the process exit code.
function HW.main(args)
    local opts, exit_code = parse_args(args)
    if not opts then
        return exit_code
    end
    if ffi.os ~= "Linux" then
        report("only Linux is supported (detected " .. ffi.os .. ")")
        return 1
    end
    if opts.mode == "json" then
        io.write(HW.to_json(HW.collect_all()))
        return 0
    elseif opts.mode == "text" then
        io.write(HW.text_report(HW.collect_all(), 100))
        return 0
    end
    return HW.run_tui(opts)
end

-- Internals exposed for the test suite.
HW.helpers = {
    truncate = truncate,
    wrap = wrap,
    ulen = ulen,
    format_bytes = format_bytes,
    new_state = new_state,
}

local script = arg and arg[0]
if script and (script == "hwinfo_tui.lua" or script:match("/hwinfo_tui%.lua$")) then
    os.exit(HW.main(arg))
end

return HW
