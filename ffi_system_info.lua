#!/usr/bin/env luajit
--[[
    ffi_system_info.lua
    High-Performance System Information & Diagnostics Engine using LuaJIT FFI.

    Demonstrates:
    1. Zero-overhead C system calls via direct libc FFI (uname, sysinfo, statvfs, getrusage, getpwuid).
    2. Real-time CPU, RAM, Swap, and Filesystem utilization with truecolor terminal progress bars.
    3. Process execution context (PID, PPID, PGID, limits, page faults, CPU user/sys time).
    4. Network interface enumeration (IPv4, IPv6, MAC, UP/DOWN flags) via getifaddrs FFI.
    5. POSIX file metadata inspection (stat, permissions, timestamps, inodes) and backward-compatible libc fopen/fseek.
    6. High-throughput memory benchmarks (GB/s bandwidth comparison between C memset and Lua).
    7. Dual-mode design: Executable CLI tool with rich ANSI dashboard (--compact, --json, --bench, --test)
       AND fully modular reusable Lua library (require("ffi_system_info")).
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. C Declarations via ffi.cdef
-- =========================================================================
ffi.cdef[[
    // 1. Process & Hostname
    int getpid(void);
    int getppid(void);
    int getpgrp(void);
    int gethostname(char *name, size_t len);
    char *getcwd(char *buf, size_t size);

    // 2. User & Groups
    unsigned int getuid(void);
    unsigned int geteuid(void);
    unsigned int getgid(void);
    unsigned int getegid(void);

    struct passwd {
        char   *pw_name;
        char   *pw_passwd;
        unsigned int pw_uid;
        unsigned int pw_gid;
        char   *pw_gecos;
        char   *pw_dir;
        char   *pw_shell;
    };
    struct passwd *getpwuid(unsigned int uid);

    // 3. File I/O & Stat
    typedef void FILE;
    FILE *fopen(const char *path, const char *mode);
    int fseek(FILE *stream, long offset, int whence);
    long ftell(FILE *stream);
    int fclose(FILE *stream);
    size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);

    typedef long time_t;
    struct timespec {
        time_t tv_sec;
        long   tv_nsec;
    };

    struct stat {
        unsigned long  st_dev;
        unsigned long  st_ino;
        unsigned long  st_nlink;
        unsigned int   st_mode;
        unsigned int   st_uid;
        unsigned int   st_gid;
        unsigned int   __pad0;
        unsigned long  st_rdev;
        long           st_size;
        long           st_blksize;
        long           st_blocks;
        struct timespec st_atim;
        struct timespec st_mtim;
        struct timespec st_ctim;
        long           __glibc_reserved[3];
    };
    int stat(const char *pathname, struct stat *statbuf);

    // 4. Memory & Performance
    void *memset(void *s, int c, size_t n);
    void *memcpy(void *dest, const void *src, size_t n);
    int memcmp(const void *s1, const void *s2, size_t n);
    int clock_gettime(int clk_id, struct timespec *tp);

    // 5. OS & Kernel Info
    struct utsname {
        char sysname[65];
        char nodename[65];
        char release[65];
        char version[65];
        char machine[65];
        char __domainname[65];
    };
    int uname(struct utsname *buf);

    // 6. Sysinfo & Loads
    struct sysinfo {
        long uptime;
        unsigned long loads[3];
        unsigned long totalram;
        unsigned long freeram;
        unsigned long sharedram;
        unsigned long bufferram;
        unsigned long totalswap;
        unsigned long freeswap;
        unsigned short procs;
        unsigned short pad;
        unsigned long totalhigh;
        unsigned long freehigh;
        unsigned int mem_unit;
        char _f[20-2*sizeof(long)-sizeof(int)];
    };
    int sysinfo(struct sysinfo *info);
    int getloadavg(double loadavg[], int nelem);
    long sysconf(int name);

    // 7. Filesystem (statvfs)
    typedef unsigned long fsblkcnt_t;
    typedef unsigned long fsfilcnt_t;
    struct statvfs {
        unsigned long f_bsize;
        unsigned long f_frsize;
        fsblkcnt_t    f_blocks;
        fsblkcnt_t    f_bfree;
        fsblkcnt_t    f_bavail;
        fsfilcnt_t    f_files;
        fsfilcnt_t    f_ffree;
        fsfilcnt_t    f_favail;
        unsigned long f_fsid;
        unsigned long f_flag;
        unsigned long f_namemax;
        int __f_spare[6];
    };
    int statvfs(const char *path, struct statvfs *buf);

    // 8. Resource Usage & Limits
    struct timeval {
        time_t tv_sec;
        long   tv_usec;
    };
    struct rusage {
        struct timeval ru_utime;
        struct timeval ru_stime;
        long   ru_maxrss;
        long   ru_ixrss;
        long   ru_idrss;
        long   ru_isrss;
        long   ru_minflt;
        long   ru_majflt;
        long   ru_nswap;
        long   ru_inblock;
        long   ru_oublock;
        long   ru_msgsnd;
        long   ru_msgrcv;
        long   ru_nsignals;
        long   ru_nvcsw;
        long   ru_nivcsw;
    };
    int getrusage(int who, struct rusage *usage);

    struct rlimit {
        unsigned long rlim_cur;
        unsigned long rlim_max;
    };
    int getrlimit(int resource, struct rlimit *rlim);

    // 9. Network Interfaces
    struct in_addr { uint32_t s_addr; };
    struct in6_addr { uint8_t s6_addr[16]; };
    struct sockaddr { unsigned short sa_family; char sa_data[14]; };
    struct sockaddr_in { unsigned short sin_family; uint16_t sin_port; struct in_addr sin_addr; char sin_zero[8]; };
    struct sockaddr_in6 { unsigned short sin6_family; uint16_t sin6_port; uint32_t sin6_flowinfo; struct in6_addr sin6_addr; uint32_t sin6_scope_id; };
    struct sockaddr_ll {
        unsigned short sll_family;
        unsigned short sll_protocol;
        int            sll_ifindex;
        unsigned short sll_hatype;
        unsigned char  sll_pkttype;
        unsigned char  sll_halen;
        unsigned char  sll_addr[8];
    };
    struct ifaddrs {
        struct ifaddrs  *ifa_next;
        char            *ifa_name;
        unsigned int     ifa_flags;
        struct sockaddr *ifa_addr;
        struct sockaddr *ifa_netmask;
        void            *ifu;
        void            *ifa_data;
    };
    int getifaddrs(struct ifaddrs **ifap);
    void freeifaddrs(struct ifaddrs *ifa);
    const char *inet_ntop(int af, const void *src, char *dst, unsigned int size);
]]

-- =========================================================================
-- 2. Module Definition & ANSI Color Theme
-- =========================================================================
local SysInfo = {
    _VERSION = "2.0.0",
    _AUTHOR = "LuaLab Team"
}

local C = {
    reset   = "\27[0m",
    bold    = "\27[1m",
    dim     = "\27[2m",
    cyan    = "\27[38;2;56;189;248m",
    blue    = "\27[38;2;96;165;250m",
    emerald = "\27[38;2;52;211;153m",
    green   = "\27[38;2;74;222;128m",
    amber   = "\27[38;2;251;191;36m",
    red     = "\27[38;2;248;113;113m",
    purple  = "\27[38;2;192;132;252m",
    slate   = "\27[38;2;148;163;184m",
    border  = "\27[38;2;71;85;105m",
    white   = "\27[38;2;248;250;252m",
}

-- =========================================================================
-- 3. String & Metric Formatting Helpers
-- =========================================================================
local function visual_length(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function pad_string(str, target_width, align)
    local vis_len = visual_length(str)
    local diff = math.max(0, target_width - vis_len)
    align = align or "left"
    if align == "right" then
        return string.rep(" ", diff) .. str
    elseif align == "center" then
        local left = math.floor(diff / 2)
        local right = diff - left
        return string.rep(" ", left) .. str .. string.rep(" ", right)
    else
        return str .. string.rep(" ", diff)
    end
end

local function format_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024^4 then
        return string.format("%.2f TB", bytes / (1024^4))
    elseif bytes >= 1024^3 then
        return string.format("%.2f GB", bytes / (1024^3))
    elseif bytes >= 1024^2 then
        return string.format("%.2f MB", bytes / (1024^2))
    elseif bytes >= 1024 then
        return string.format("%.2f KB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

local function format_uptime(sec)
    sec = math.floor(tonumber(sec) or 0)
    local days = math.floor(sec / 86400)
    local hours = math.floor((sec % 86400) / 3600)
    local mins = math.floor((sec % 3600) / 60)
    local secs = sec % 60
    local parts = {}
    if days > 0 then parts[#parts + 1] = string.format("%dd", days) end
    if hours > 0 or days > 0 then parts[#parts + 1] = string.format("%dh", hours) end
    if mins > 0 or hours > 0 or days > 0 then parts[#parts + 1] = string.format("%dm", mins) end
    parts[#parts + 1] = string.format("%ds", secs)
    return table.concat(parts, " ")
end

local function format_permissions(mode)
    local types = {
        [0x8000] = "-", -- Regular file
        [0x4000] = "d", -- Directory
        [0x2000] = "c", -- Character device
        [0x6000] = "b", -- Block device
        [0x1000] = "p", -- FIFO pipe
        [0xA000] = "l", -- Symlink
        [0xC000] = "s", -- Socket
    }
    local ftype = types[bit.band(mode, 0xF000)] or "?"
    local chars = {"r", "w", "x", "r", "w", "x", "r", "w", "x"}
    local flags = {0x100, 0x80, 0x40, 0x20, 0x10, 0x8, 0x4, 0x2, 0x1}
    local res = {ftype}
    for i = 1, 9 do
        if bit.band(mode, flags[i]) ~= 0 then
            res[#res + 1] = chars[i]
        else
            res[#res + 1] = "-"
        end
    end
    return table.concat(res)
end

local function render_bar(ratio, width, custom_color)
    width = width or 20
    ratio = math.max(0, math.min(1, ratio or 0))
    local filled = math.floor(ratio * width + 0.5)
    local empty = width - filled
    local color = custom_color
    if not color then
        if ratio < 0.70 then
            color = C.green
        elseif ratio < 0.90 then
            color = C.amber
        else
            color = C.red
        end
    end
    return string.format("%s%s\27[38;2;100;116;139m%s%s %s%5.1f%%%s",
        color, string.rep("█", filled), string.rep("░", empty), C.reset,
        C.bold, ratio * 100, C.reset)
end

local function get_hrtime_sec()
    local ts = ffi.new("struct timespec")
    ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC = 1
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

-- =========================================================================
-- 4. Core System Query Functions
-- =========================================================================

--- 1. Get OS, Kernel, and System Uptime Info
function SysInfo.get_os_info()
    local u = ffi.new("struct utsname")
    local uname_ok = (ffi.C.uname(u) == 0)

    local si = ffi.new("struct sysinfo")
    local sysinfo_ok = (ffi.C.sysinfo(si) == 0)

    local loads = ffi.new("double[3]")
    local load_ok = (ffi.C.getloadavg(loads, 3) == 3)

    local hostname = "unknown"
    local hbuf = ffi.new("char[256]")
    if ffi.C.gethostname(hbuf, 256) == 0 then
        hostname = ffi.string(hbuf)
    elseif uname_ok then
        hostname = ffi.string(u.nodename)
    end

    local uptime_sec = sysinfo_ok and tonumber(si.uptime) or 0

    return {
        hostname        = hostname,
        sysname         = uname_ok and ffi.string(u.sysname) or "Linux",
        nodename        = uname_ok and ffi.string(u.nodename) or hostname,
        release         = uname_ok and ffi.string(u.release) or "unknown",
        version         = uname_ok and ffi.string(u.version) or "unknown",
        machine         = uname_ok and ffi.string(u.machine) or "unknown",
        domainname      = uname_ok and ffi.string(u.__domainname) or "",
        uptime_seconds  = uptime_sec,
        uptime_formatted= format_uptime(uptime_sec),
        processes_count = sysinfo_ok and tonumber(si.procs) or 0,
        loadavg         = {
            load_1m  = load_ok and loads[0] or 0.0,
            load_5m  = load_ok and loads[1] or 0.0,
            load_15m = load_ok and loads[2] or 0.0,
        }
    }
end

--- 2. Get User and Environment Info
function SysInfo.get_user_info()
    local uid = ffi.C.getuid()
    local euid = ffi.C.geteuid()
    local gid = ffi.C.getgid()
    local egid = ffi.C.getegid()

    local username = "unknown"
    local home_dir = os.getenv("HOME") or ""
    local shell = os.getenv("SHELL") or ""
    local full_name = ""

    local pw = ffi.C.getpwuid(uid)
    if pw ~= nil then
        if pw.pw_name ~= nil then username = ffi.string(pw.pw_name) end
        if pw.pw_dir ~= nil then home_dir = ffi.string(pw.pw_dir) end
        if pw.pw_shell ~= nil then shell = ffi.string(pw.pw_shell) end
        if pw.pw_gecos ~= nil then full_name = ffi.string(pw.pw_gecos) end
    end

    local cwd = "."
    local cwdbuf = ffi.new("char[2048]")
    if ffi.C.getcwd(cwdbuf, 2048) ~= nil then
        cwd = ffi.string(cwdbuf)
    end

    return {
        uid       = tonumber(uid),
        euid      = tonumber(euid),
        gid       = tonumber(gid),
        egid      = tonumber(egid),
        username  = username,
        home_dir  = home_dir,
        shell     = shell,
        full_name = full_name,
        cwd       = cwd
    }
end

--- 3. Get CPU and Hardware Architecture
function SysInfo.get_cpu_info()
    local cpu_model = "Generic Processor"
    local f = ffi.C.fopen("/proc/cpuinfo", "r")
    if f ~= nil then
        local buf = ffi.new("char[8192]")
        local n = ffi.C.fread(buf, 1, 8191, f)
        ffi.C.fclose(f)
        if n > 0 then
            local text = ffi.string(buf, n)
            local model = text:match("model name%s*:%s*([^\n\r]+)")
            if model then cpu_model = model end
        end
    end

    -- _SC_NPROCESSORS_ONLN = 84, _SC_NPROCESSORS_CONF = 83, _SC_PAGESIZE = 30, _SC_CLK_TCK = 2
    local online_cpus = tonumber(ffi.C.sysconf(84))
    if online_cpus <= 0 then online_cpus = 1 end
    local conf_cpus = tonumber(ffi.C.sysconf(83))
    if conf_cpus <= 0 then conf_cpus = online_cpus end
    local page_size = tonumber(ffi.C.sysconf(30))
    if page_size <= 0 then page_size = 4096 end
    local clk_tck = tonumber(ffi.C.sysconf(2))
    if clk_tck <= 0 then clk_tck = 100 end

    return {
        model           = cpu_model,
        online_cpus     = online_cpus,
        configured_cpus = conf_cpus,
        page_size_bytes = page_size,
        clock_ticks_hz  = clk_tck
    }
end

--- 4. Get Memory and Swap Statistics
function SysInfo.get_memory_info()
    local si = ffi.new("struct sysinfo")
    if ffi.C.sysinfo(si) ~= 0 then
        return nil, "sysinfo failed"
    end

    local unit = si.mem_unit > 0 and tonumber(si.mem_unit) or 1
    local total_ram  = tonumber(si.totalram) * unit
    local free_ram   = tonumber(si.freeram) * unit
    local buffer_ram = tonumber(si.bufferram) * unit
    local shared_ram = tonumber(si.sharedram) * unit
    local used_ram   = math.max(0, total_ram - free_ram - buffer_ram)

    local total_swap = tonumber(si.totalswap) * unit
    local free_swap  = tonumber(si.freeswap) * unit
    local used_swap  = math.max(0, total_swap - free_swap)

    local ram_ratio  = total_ram > 0 and (used_ram / total_ram) or 0
    local swap_ratio = total_swap > 0 and (used_swap / total_swap) or 0

    return {
        total_ram        = total_ram,
        free_ram         = free_ram,
        buffer_ram       = buffer_ram,
        shared_ram       = shared_ram,
        used_ram         = used_ram,
        ram_ratio        = ram_ratio,
        ram_percent      = ram_ratio * 100,
        total_swap       = total_swap,
        free_swap        = free_swap,
        used_swap        = used_swap,
        swap_ratio       = swap_ratio,
        swap_percent     = swap_ratio * 100
    }
end

--- 5. Get Storage & Filesystem Statistics via statvfs
function SysInfo.get_storage_info(path)
    path = path or "."
    local sv = ffi.new("struct statvfs")
    if ffi.C.statvfs(path, sv) ~= 0 then
        return nil, "statvfs failed for: " .. path
    end

    local frsize = tonumber(sv.f_frsize)
    if frsize <= 0 then frsize = tonumber(sv.f_bsize) end
    if frsize <= 0 then frsize = 4096 end

    local total_bytes = frsize * tonumber(sv.f_blocks)
    local free_bytes  = frsize * tonumber(sv.f_bfree)
    local avail_bytes = frsize * tonumber(sv.f_bavail)
    local used_bytes  = math.max(0, total_bytes - free_bytes)
    local used_ratio  = total_bytes > 0 and (used_bytes / total_bytes) or 0

    local total_inodes = tonumber(sv.f_files)
    local free_inodes  = tonumber(sv.f_favail)
    local used_inodes  = math.max(0, total_inodes - free_inodes)
    local inode_ratio  = total_inodes > 0 and (used_inodes / total_inodes) or 0

    return {
        path          = path,
        block_size    = frsize,
        total_bytes   = total_bytes,
        free_bytes    = free_bytes,
        avail_bytes   = avail_bytes,
        used_bytes    = used_bytes,
        used_ratio    = used_ratio,
        used_percent  = used_ratio * 100,
        total_inodes  = total_inodes,
        free_inodes   = free_inodes,
        used_inodes   = used_inodes,
        inode_ratio   = inode_ratio,
        inode_percent = inode_ratio * 100
    }
end

--- 6. Target File Inspection (POSIX stat + backward compatible libc fopen)
function SysInfo.get_file_stat(filepath)
    filepath = filepath or "Makefile"
    local st = ffi.new("struct stat")
    if ffi.C.stat(filepath, st) ~= 0 then
        return nil, "File not found or inaccessible: " .. filepath
    end

    local mode = tonumber(st.st_mode)
    local mtime_sec = tonumber(st.st_mtim.tv_sec)
    local is_reg = bit.band(mode, 0xF000) == 0x8000
    local is_dir = bit.band(mode, 0xF000) == 0x4000
    local is_link = bit.band(mode, 0xF000) == 0xA000

    return {
        path            = filepath,
        exists          = true,
        size_bytes      = tonumber(st.st_size),
        mode_raw        = mode,
        mode_octal      = string.format("%04o", bit.band(mode, 0x1FF)),
        permissions     = format_permissions(mode),
        is_regular_file = is_reg,
        is_directory    = is_dir,
        is_symlink      = is_link,
        inode           = tonumber(st.st_ino),
        hard_links      = tonumber(st.st_nlink),
        uid             = tonumber(st.st_uid),
        gid             = tonumber(st.st_gid),
        mtime_epoch     = mtime_sec,
        mtime_formatted = os.date("%Y-%m-%d %H:%M:%S", mtime_sec)
    }
end

--- Backward-compatible libc fopen/fseek file sizing
function SysInfo.get_file_size(filename)
    local f = ffi.C.fopen(filename, "rb")
    if f == nil then return nil, "Could not open file" end
    ffi.C.fseek(f, 0, 2) -- SEEK_END = 2
    local size = ffi.C.ftell(f)
    ffi.C.fclose(f)
    return tonumber(size)
end

--- 7. Process Execution Context & Resource Usage via getrusage
function SysInfo.get_process_info()
    local pid = tonumber(ffi.C.getpid())
    local ppid = tonumber(ffi.C.getppid())
    local pgrp = tonumber(ffi.C.getpgrp())

    local ru = ffi.new("struct rusage")
    local rusage_ok = (ffi.C.getrusage(0, ru) == 0) -- RUSAGE_SELF = 0

    local user_time = rusage_ok and (tonumber(ru.ru_utime.tv_sec) + tonumber(ru.ru_utime.tv_usec) * 1e-6) or 0
    local sys_time  = rusage_ok and (tonumber(ru.ru_stime.tv_sec) + tonumber(ru.ru_stime.tv_usec) * 1e-6) or 0
    local max_rss_kb = rusage_ok and tonumber(ru.ru_maxrss) or 0

    -- RLIMIT_NOFILE = 7, RLIMIT_STACK = 3
    local rlim_nofile = ffi.new("struct rlimit")
    local nofile_ok = (ffi.C.getrlimit(7, rlim_nofile) == 0)

    local rlim_stack = ffi.new("struct rlimit")
    local stack_ok = (ffi.C.getrlimit(3, rlim_stack) == 0)

    return {
        pid                     = pid,
        ppid                    = ppid,
        pgrp                    = pgrp,
        user_time_sec           = user_time,
        sys_time_sec            = sys_time,
        total_cpu_time_sec      = user_time + sys_time,
        max_rss_kb              = max_rss_kb,
        max_rss_bytes           = max_rss_kb * 1024,
        minor_page_faults       = rusage_ok and tonumber(ru.ru_minflt) or 0,
        major_page_faults       = rusage_ok and tonumber(ru.ru_majflt) or 0,
        voluntary_ctx_switches  = rusage_ok and tonumber(ru.ru_nvcsw) or 0,
        involuntary_ctx_switches= rusage_ok and tonumber(ru.ru_nivcsw) or 0,
        rlimit_nofile_cur       = nofile_ok and tonumber(rlim_nofile.rlim_cur) or 0,
        rlimit_nofile_max       = nofile_ok and tonumber(rlim_nofile.rlim_max) or 0,
        rlimit_stack_cur        = stack_ok and tonumber(rlim_stack.rlim_cur) or 0,
    }
end

--- 8. Network Interface Enumeration via getifaddrs
function SysInfo.get_network_info()
    local ifap = ffi.new("struct ifaddrs*[1]")
    if ffi.C.getifaddrs(ifap) ~= 0 then
        return {}
    end

    local ifaces_map = {}
    local ifaces_order = {}
    local curr = ifap[0]

    while curr ~= nil do
        local name = ffi.string(curr.ifa_name)
        if not ifaces_map[name] then
            ifaces_map[name] = {
                name = name,
                flags = tonumber(curr.ifa_flags),
                is_up = bit.band(curr.ifa_flags, 0x1) ~= 0,
                is_loopback = bit.band(curr.ifa_flags, 0x8) ~= 0,
                is_running = bit.band(curr.ifa_flags, 0x40) ~= 0,
                ipv4 = {},
                ipv6 = {},
                mac = nil
            }
            ifaces_order[#ifaces_order + 1] = name
        end

        local item = ifaces_map[name]
        if curr.ifa_addr ~= nil then
            local family = curr.ifa_addr.sa_family
            if family == 2 then -- AF_INET
                local sin = ffi.cast("struct sockaddr_in*", curr.ifa_addr)
                local buf = ffi.new("char[64]")
                if ffi.C.inet_ntop(2, sin.sin_addr, buf, 64) ~= nil then
                    item.ipv4[#item.ipv4 + 1] = ffi.string(buf)
                end
            elseif family == 10 then -- AF_INET6
                local sin6 = ffi.cast("struct sockaddr_in6*", curr.ifa_addr)
                local buf = ffi.new("char[128]")
                if ffi.C.inet_ntop(10, sin6.sin6_addr, buf, 128) ~= nil then
                    item.ipv6[#item.ipv6 + 1] = ffi.string(buf)
                end
            elseif family == 17 then -- AF_PACKET (Linux MAC address)
                local sll = ffi.cast("struct sockaddr_ll*", curr.ifa_addr)
                if sll.sll_halen == 6 and not item.mac then
                    item.mac = string.format("%02x:%02x:%02x:%02x:%02x:%02x",
                        sll.sll_addr[0], sll.sll_addr[1], sll.sll_addr[2],
                        sll.sll_addr[3], sll.sll_addr[4], sll.sll_addr[5])
                end
            end
        end
        curr = curr.ifa_next
    end

    ffi.C.freeifaddrs(ifap[0])

    local result = {}
    for _, name in ipairs(ifaces_order) do
        result[#result + 1] = ifaces_map[name]
    end
    return result
end

--- 9. High-Throughput Memory Benchmark (FFI C memset vs Lua)
function SysInfo.benchmark_memory(size_mb, iterations)
    size_mb = size_mb or 16
    iterations = iterations or 20
    local bytes = size_mb * 1024 * 1024

    local buf = ffi.new("uint8_t[?]", bytes)
    ffi.C.memset(buf, 0, bytes) -- warmup

    -- Benchmark 1: C memset throughput
    local t0 = get_hrtime_sec()
    for _ = 1, iterations do
        ffi.C.memset(buf, 0x5A, bytes)
    end
    local t1 = get_hrtime_sec()
    local dt_memset = math.max(1e-9, t1 - t0)
    local gb_total = (bytes * iterations) / (1024^3)
    local memset_gb_sec = gb_total / dt_memset

    -- Benchmark 2: C pointer stride write
    local t2 = get_hrtime_sec()
    local ptr32 = ffi.cast("uint32_t*", buf)
    local words = math.floor(bytes / 4)
    local sum = 0
    for i = 0, math.min(words - 1, 1000000) do
        ptr32[i] = i
        sum = sum + ptr32[i]
    end
    local t3 = get_hrtime_sec()
    local dt_ptr = math.max(1e-9, t3 - t2)

    -- Benchmark 3: Pure Lua table creation comparison (100,000 items)
    local t4 = get_hrtime_sec()
    local lua_tbl = {}
    for i = 1, 100000 do
        lua_tbl[i] = i
    end
    local t5 = get_hrtime_sec()
    local dt_lua = math.max(1e-9, t5 - t4)

    return {
        buffer_size_mb      = size_mb,
        iterations          = iterations,
        memset_duration_sec = dt_memset,
        memset_gb_per_sec   = memset_gb_sec,
        c_ptr_duration_sec  = dt_ptr,
        lua_tbl_duration_sec= dt_lua,
        speedup_ratio       = dt_lua > 0 and (dt_ptr / dt_lua) or 0,
        sum_check           = sum
    }
end

--- 10. Aggregate all data into a master dictionary
function SysInfo.get_all(target_file, target_path)
    target_file = target_file or "Makefile"
    target_path = target_path or "."

    return {
        os       = SysInfo.get_os_info(),
        user     = SysInfo.get_user_info(),
        cpu      = SysInfo.get_cpu_info(),
        memory   = SysInfo.get_memory_info(),
        storage  = SysInfo.get_storage_info(target_path),
        target_file = SysInfo.get_file_stat(target_file),
        process  = SysInfo.get_process_info(),
        network  = SysInfo.get_network_info(),
        benchmark= SysInfo.benchmark_memory(16, 10)
    }
end

-- =========================================================================
-- 5. JSON Serialization
-- =========================================================================
function SysInfo.to_json(data)
    data = data or SysInfo.get_all()
    local ok, json = pcall(require, "json")
    if ok and json and json.encode then
        return json.encode(data)
    end

    -- Fallback light JSON serializer
    local function serialize(val)
        local t = type(val)
        if t == "number" then
            if val ~= val then return "0" end
            if val == math.huge then return "1e999" end
            if val == -math.huge then return "-1e999" end
            return tostring(val)
        elseif t == "boolean" then
            return tostring(val)
        elseif t == "string" then
            return string.format("%q", val):gsub("\n", "\\n"):gsub("\r", "\\r")
        elseif t == "table" then
            local is_array = true
            local n = 0
            for k, _ in pairs(val) do
                n = n + 1
                if type(k) ~= "number" or k ~= n then
                    is_array = false
                end
            end
            if is_array then
                local items = {}
                for _, v in ipairs(val) do
                    items[#items + 1] = serialize(v)
                end
                return "[" .. table.concat(items, ",") .. "]"
            else
                local items = {}
                for k, v in pairs(val) do
                    items[#items + 1] = string.format("%q:%s", tostring(k), serialize(v))
                end
                return "{" .. table.concat(items, ",") .. "}"
            end
        else
            return "null"
        end
    end

    return serialize(data)
end

-- =========================================================================
-- 6. Rich Terminal Visual Presentation
-- =========================================================================
local function card_box(title, badge, lines, width)
    width = width or 78
    local inner_width = width - 4

    local title_str = string.format(" %s%s%s %s[%s]%s ", C.bold, title, C.reset, C.cyan, badge, C.reset)
    local top_fill = inner_width - visual_length(title_str)
    if top_fill < 0 then top_fill = 0 end

    print(C.border .. "╭─" .. C.reset .. title_str .. C.border .. string.rep("─", top_fill) .. "╮" .. C.reset)

    for _, line in ipairs(lines) do
        local line_vis = visual_length(line)
        local pad = math.max(0, inner_width - line_vis)
        print(C.border .. "│ " .. C.reset .. line .. string.rep(" ", pad) .. C.border .. " │" .. C.reset)
    end

    print(C.border .. "╰" .. string.rep("─", width - 2) .. "╯" .. C.reset)
end

function SysInfo.print_report(opts)
    opts = opts or {}
    local target_file = opts.file or "Makefile"
    local target_path = opts.path or "."

    local os_info   = SysInfo.get_os_info()
    local user_info = SysInfo.get_user_info()
    local cpu_info  = SysInfo.get_cpu_info()
    local mem_info  = SysInfo.get_memory_info()
    local disk_info = SysInfo.get_storage_info(target_path)
    local proc_info = SysInfo.get_process_info()
    local file_info = SysInfo.get_file_stat(target_file)
    local net_info  = SysInfo.get_network_info()
    local bench     = SysInfo.benchmark_memory(16, 15)

    -- Header Banner
    print("\n" .. C.border .. "╭────────────────────────────────────────────────────────────────────────────╮" .. C.reset)
    print(C.border .. "│ " .. C.bold .. C.cyan .. "🚀 LuaJIT FFI System Information & POSIX Runtime Diagnostics" .. C.reset ..
          string.rep(" ", 14) .. C.border .. "│" .. C.reset)
    print(C.border .. "│ " .. C.dim .. C.slate .. string.format("Generated: %s | Target Host: %s", os.date("%Y-%m-%d %H:%M:%S"), os_info.hostname) ..
          C.reset .. string.rep(" ", math.max(0, 75 - visual_length("Generated: " .. os.date("%Y-%m-%d %H:%M:%S") .. " | Target Host: " .. os_info.hostname))) .. C.border .. "│" .. C.reset)
    print(C.border .. "╰────────────────────────────────────────────────────────────────────────────╯" .. C.reset)

    -- 1. Host & OS
    local os_lines = {
        string.format("%sHostname%s      : %s%-20s%s %sDomain%s   : %s%s%s",
            C.slate, C.reset, C.bold, os_info.hostname, C.reset, C.slate, C.reset, C.amber, os_info.domainname ~= "" and os_info.domainname or "(none)", C.reset),
        string.format("%sOS & Kernel%s   : %s%s %s (%s)%s",
            C.slate, C.reset, C.bold .. C.cyan, os_info.sysname, os_info.release, os_info.machine, C.reset),
        string.format("%sSystem Uptime%s : %s%-20s%s %sTasks%s    : %s%d running%s",
            C.slate, C.reset, C.emerald, os_info.uptime_formatted, C.reset, C.slate, C.reset, C.blue, os_info.processes_count, C.reset),
        string.format("%sLoad Averages%s : 1m: %s%.2f%s,  5m: %s%.2f%s,  15m: %s%.2f%s",
            C.slate, C.reset, C.bold, os_info.loadavg.load_1m, C.reset, C.bold, os_info.loadavg.load_5m, C.reset, C.bold, os_info.loadavg.load_15m, C.reset)
    }
    card_box("HOST & OPERATING SYSTEM", "OS", os_lines)

    -- 2. CPU & Architecture
    local cpu_lines = {
        string.format("%sProcessor%s     : %s%s%s",
            C.slate, C.reset, C.bold .. C.purple, cpu_info.model, C.reset),
        string.format("%sCPU Cores%s     : %s%d Online%s / %s%d Configured%s",
            C.slate, C.reset, C.emerald, cpu_info.online_cpus, C.reset, C.slate, cpu_info.configured_cpus, C.reset),
        string.format("%sArchitecture%s  : %s%-16s%s %sPage Size%s: %s%s (%d B)%s",
            C.slate, C.reset, C.bold, os_info.machine, C.reset, C.slate, C.reset, C.cyan, format_bytes(cpu_info.page_size_bytes), cpu_info.page_size_bytes, C.reset),
        string.format("%sClock Frequency%s: %s%d Hz (ticks/sec)%s",
            C.slate, C.reset, C.amber, cpu_info.clock_ticks_hz, C.reset)
    }
    card_box("CPU & HARDWARE ARCHITECTURE", "CPU", cpu_lines)

    -- 3. Memory & Virtual Memory
    local ram_bar = render_bar(mem_info.ram_ratio, 24)
    local swap_bar = render_bar(mem_info.swap_ratio, 24)
    local mem_lines = {
        string.format("%sPhysical RAM%s  : %s%s%s / %s%s%s  %s",
            C.slate, C.reset, C.bold .. C.white, format_bytes(mem_info.used_ram), C.reset,
            C.dim, format_bytes(mem_info.total_ram), C.reset, ram_bar),
        string.format("  %s├─ Free RAM%s   : %-14s %s├─ Buffers/Cache%s: %s",
            C.slate, C.reset, format_bytes(mem_info.free_ram), C.slate, C.reset, format_bytes(mem_info.buffer_ram)),
        string.format("  %s└─ Shared RAM%s : %-14s",
            C.slate, C.reset, format_bytes(mem_info.shared_ram)),
        string.format("%sSwap Storage%s  : %s%s%s / %s%s%s  %s",
            C.slate, C.reset, C.bold .. C.white, format_bytes(mem_info.used_swap), C.reset,
            C.dim, format_bytes(mem_info.total_swap), C.reset, swap_bar)
    }
    card_box("MEMORY & SWAP UTILIZATION", "MEM", mem_lines)

    -- 4. Storage & Filesystem
    local disk_bar = render_bar(disk_info.used_ratio, 24)
    local storage_lines = {
        string.format("%sFilesystem Path%s: %s%s%s (block size: %s)",
            C.slate, C.reset, C.bold .. C.cyan, disk_info.path, C.reset, format_bytes(disk_info.block_size)),
        string.format("%sDisk Capacity%s  : %s%s%s / %s%s%s  %s",
            C.slate, C.reset, C.bold .. C.white, format_bytes(disk_info.used_bytes), C.reset,
            C.dim, format_bytes(disk_info.total_bytes), C.reset, disk_bar),
        string.format("  %s├─ Avail to User%s: %-14s %s├─ Inodes Total%s : %d",
            C.slate, C.reset, format_bytes(disk_info.avail_bytes), C.slate, C.reset, disk_info.total_inodes),
        string.format("  %s└─ Free Space%s   : %-14s %s└─ Inodes Free%s  : %d (%.1f%% used)",
            C.slate, C.reset, format_bytes(disk_info.free_bytes), C.slate, C.reset, disk_info.free_inodes, disk_info.inode_percent)
    }
    card_box("STORAGE & FILESYSTEM (STATVFS)", "DISK", storage_lines)

    -- 5. Process & User Context
    local proc_lines = {
        string.format("%sCurrent Process%s: PID: %s%d%s  |  PPID: %s%d%s  |  PGRP: %s%d%s",
            C.slate, C.reset, C.bold .. C.amber, proc_info.pid, C.reset, C.dim, proc_info.ppid, C.reset, C.dim, proc_info.pgrp, C.reset),
        string.format("%sUser & Shell%s   : %s%s%s (UID: %d, GID: %d)  |  Shell: %s%s%s",
            C.slate, C.reset, C.bold .. C.emerald, user_info.username, C.reset, user_info.uid, user_info.gid, C.dim, user_info.shell, C.reset),
        string.format("%sWorking Dir%s    : %s%s%s",
            C.slate, C.reset, C.cyan, user_info.cwd, C.reset),
        string.format("%sCPU Time Used%s  : User: %s%.3fs%s  |  Sys: %s%.3fs%s  |  Total: %s%.3fs%s",
            C.slate, C.reset, C.bold, proc_info.user_time_sec, C.reset, C.bold, proc_info.sys_time_sec, C.reset, C.bold .. C.green, proc_info.total_cpu_time_sec, C.reset),
        string.format("%sMemory Peak%s    : Max RSS: %s%s%s (%d KB)",
            C.slate, C.reset, C.bold .. C.purple, format_bytes(proc_info.max_rss_bytes), C.reset, proc_info.max_rss_kb),
        string.format("%sResource Limits%s: File Descriptors: %s%d%s soft / %s%d%s hard",
            C.slate, C.reset, C.emerald, proc_info.rlimit_nofile_cur, C.reset, C.dim, proc_info.rlimit_nofile_max, C.reset)
    }
    card_box("PROCESS & USER CONTEXT", "PROC", proc_lines)

    -- 6. Target File Inspection
    local file_lines
    if file_info then
        file_lines = {
            string.format("%sInspected File%s : %s%s%s",
                C.slate, C.reset, C.bold .. C.white, file_info.path, C.reset),
            string.format("%sFile Size%s      : %s%d bytes%s (%s)",
                C.slate, C.reset, C.bold .. C.green, file_info.size_bytes, C.reset, format_bytes(file_info.size_bytes)),
            string.format("%sPOSIX Mode%s     : %s%s%s (Octal: %s%s%s, Inode: %d, Links: %d)",
                C.slate, C.reset, C.cyan, file_info.permissions, C.reset, C.amber, file_info.mode_octal, C.reset, file_info.inode, file_info.hard_links),
            string.format("%sOwnership%s      : UID: %d  |  GID: %d",
                C.slate, C.reset, file_info.uid, file_info.gid),
            string.format("%sLast Modified%s  : %s%s%s",
                C.slate, C.reset, C.bold, file_info.mtime_formatted, C.reset)
        }
    else
        file_lines = {
            string.format("%sTarget File%s    : %s%s%s (Not found or inaccessible)",
                C.slate, C.reset, C.red, target_file, C.reset)
        }
    end
    card_box("FILE SYSTEM METADATA (STAT)", "FILE", file_lines)

    -- 7. Network Interfaces
    local net_lines = {}
    if #net_info == 0 then
        net_lines[1] = C.dim .. "No network interfaces discovered" .. C.reset
    else
        for _, iface in ipairs(net_info) do
            local state = iface.is_up and (C.green .. "UP" .. C.reset) or (C.red .. "DOWN" .. C.reset)
            if iface.is_running then state = state .. C.dim .. ",RUNNING" .. C.reset end
            if iface.is_loopback then state = state .. C.dim .. ",LOOPBACK" .. C.reset end

            local ip4_str = #iface.ipv4 > 0 and table.concat(iface.ipv4, ", ") or "(no IPv4)"
            local mac_str = iface.mac and (" | MAC: " .. C.dim .. iface.mac .. C.reset) or ""

            net_lines[#net_lines + 1] = string.format("%s%-10s%s [%s] -> IPv4: %s%s%s%s",
                C.bold .. C.cyan, iface.name, C.reset, state, C.bold, ip4_str, C.reset, mac_str)

            if #iface.ipv6 > 0 then
                net_lines[#net_lines + 1] = string.format("  %s└─ IPv6: %s%s%s",
                    C.slate, C.dim, iface.ipv6[1], C.reset)
            end
        end
    end
    card_box("NETWORK INTERFACES (GETIFADDRS)", "NET", net_lines)

    -- 8. FFI Memory Benchmark
    local bench_lines = {
        string.format("%sC memset Clear%s : %s%d MB%s buffer cleared %d times in %s%.4fs%s",
            C.slate, C.reset, C.bold, bench.buffer_size_mb, C.reset, bench.iterations, C.amber, bench.memset_duration_sec, C.reset),
        string.format("%sThroughput%s     : %s%s%.2f GB/s%s (Direct SIMD / libc bandwidth)",
            C.slate, C.reset, C.bold, C.emerald, bench.memset_gb_per_sec, C.reset),
        string.format("%sPointer Write%s  : 1,000,000 typed uint32_t writes in %s%.4f ms%s",
            C.slate, C.reset, C.cyan, bench.c_ptr_duration_sec * 1000, C.reset),
        string.format("%sLua vs C Speed%s  : Lua table allocation: %s%.2f ms%s (%s~%.1fx faster in C%s)",
            C.slate, C.reset, C.slate, bench.lua_tbl_duration_sec * 1000, C.reset,
            C.bold .. C.green, bench.lua_tbl_duration_sec / math.max(1e-9, bench.c_ptr_duration_sec), C.reset)
    }
    card_box("FFI HIGH-SPEED MEMORY BENCHMARK", "BENCH", bench_lines)

    -- Footer
    print("\n" .. C.emerald .. C.bold .. "✔ All FFI diagnostics and system queries executed successfully!" .. C.reset .. "\n")
end

--- Compact Neofetch-style badge summary
function SysInfo.print_compact()
    local os_info   = SysInfo.get_os_info()
    local user_info = SysInfo.get_user_info()
    local cpu_info  = SysInfo.get_cpu_info()
    local mem_info  = SysInfo.get_memory_info()
    local disk_info = SysInfo.get_storage_info(".")
    local proc_info = SysInfo.get_process_info()
    local net_info  = SysInfo.get_network_info()

    local active_ip = "127.0.0.1"
    for _, iface in ipairs(net_info) do
        if not iface.is_loopback and #iface.ipv4 > 0 then
            active_ip = string.format("%s (%s)", iface.name, iface.ipv4[1])
            break
        end
    end

    local ram_bar = render_bar(mem_info.ram_ratio, 16)
    local disk_bar = render_bar(disk_info.used_ratio, 16)

    print("")
    print(C.cyan .. "    _        " .. C.slate .. "Host   : " .. C.bold .. C.white .. os_info.hostname .. C.reset)
    print(C.cyan .. "  /   \\      " .. C.slate .. "OS     : " .. C.bold .. os_info.sysname .. " " .. os_info.release .. " (" .. os_info.machine .. ")" .. C.reset)
    print(C.cyan .. " |  O  |     " .. C.slate .. "CPU    : " .. C.purple .. cpu_info.model .. " (" .. cpu_info.online_cpus .. " cores)" .. C.reset)
    print(C.cyan .. "  \\ _ /      " .. C.slate .. "RAM    : " .. format_bytes(mem_info.used_ram) .. " / " .. format_bytes(mem_info.total_ram) .. "  " .. ram_bar .. C.reset)
    print(C.blue .. "  LuaJIT     " .. C.slate .. "Disk   : " .. format_bytes(disk_info.used_bytes) .. " / " .. format_bytes(disk_info.total_bytes) .. "  " .. disk_bar .. C.reset)
    print(C.blue .. "   FFI       " .. C.slate .. "Uptime : " .. C.emerald .. os_info.uptime_formatted .. C.reset .. C.dim .. " | Procs: " .. os_info.processes_count .. C.reset)
    print(C.blue .. "  v" .. SysInfo._VERSION .. "     " .. C.slate .. "Context: " .. C.amber .. user_info.username .. C.reset .. " (PID: " .. proc_info.pid .. ") | Net: " .. C.cyan .. active_ip .. C.reset)
    print("")
end

-- =========================================================================
-- 7. Verification & Built-In Self Test Suite
-- =========================================================================
function SysInfo.run_tests()
    print("--- Running FFI System Info Test Suite ---")

    -- 1. getpid test
    local pid = ffi.C.getpid()
    assert(type(pid) == "number" and pid > 0, "PID should be a positive number")
    print(string.format("  ✔ Current Process ID: %d", pid))

    -- 2. gethostname test
    local buffer = ffi.new("char[256]")
    assert(ffi.C.gethostname(buffer, 256) == 0, "gethostname failed")
    local hostname = ffi.string(buffer)
    assert(#hostname > 0, "Hostname should not be empty")
    print(string.format("  ✔ Hostname: %s", hostname))

    -- 3. File sizing via fopen/fseek/ftell
    local size, err = SysInfo.get_file_size("Makefile")
    assert(size and size > 0, "Makefile size should be greater than 0")
    print(string.format("  ✔ Size of 'Makefile' (fopen/fseek): %d bytes", size))

    -- 4. File sizing via stat
    local fstat = SysInfo.get_file_stat("Makefile")
    assert(fstat and fstat.size_bytes == size, "stat size should match fopen size")
    assert(#fstat.permissions == 10, "POSIX permissions string should be 10 chars")
    print(string.format("  ✔ POSIX stat verified: %s, mode: %s", fstat.permissions, fstat.mode_octal))

    -- 5. Fast memory clearing via memset
    local large_array = ffi.new("uint8_t[1000000]")
    ffi.C.memset(large_array, 0, 1000000)
    assert(large_array[0] == 0 and large_array[999999] == 0, "Memset failed to clear array")
    print("  ✔ Cleared 1MB array using C memset.")

    -- 6. Sysinfo verification
    local mem = SysInfo.get_memory_info()
    assert(mem and mem.total_ram > 0, "RAM total must be greater than 0")
    print(string.format("  ✔ Memory verified: %.2f GB Total, %.2f GB Used", mem.total_ram / (1024^3), mem.used_ram / (1024^3)))

    -- 7. Storage verification
    local disk = SysInfo.get_storage_info(".")
    assert(disk and disk.total_bytes > 0, "Disk capacity must be greater than 0")
    print(string.format("  ✔ Storage verified: %.2f GB Total, %.2f GB Avail", disk.total_bytes / (1024^3), disk.avail_bytes / (1024^3)))

    -- 8. Network verification
    local net = SysInfo.get_network_info()
    assert(#net > 0, "At least one network interface must exist")
    print(string.format("  ✔ Network interfaces verified (%d found)", #net))

    print("\nAll FFI tests passed successfully!")
    return true
end

-- =========================================================================
-- 8. CLI Argument Parsing & Direct Execution
-- =========================================================================
local function print_help()
    print([[
Usage: luajit ffi_system_info.lua [OPTIONS]

High-Performance System Information & Diagnostics via LuaJIT FFI.

Options:
  -c, --compact       Display concise Fastfetch/Neofetch-style summary badge
  -j, --json          Output full system telemetry as JSON
  -t, --test          Run built-in FFI assertions & self-test suite
  -b, --bench         Run memory & C syscall throughput benchmark
  -f, --file <PATH>   Inspect detailed metadata for specified file (default: Makefile)
  -p, --path <PATH>   Inspect storage & filesystem for specified directory (default: .)
  -h, --help          Show this help message
]])
end

local function main(args)
    args = args or {}
    local opts = {
        compact = false,
        json    = false,
        test    = false,
        bench   = false,
        file    = "Makefile",
        path    = "."
    }

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-c" or a == "--compact" then
            opts.compact = true
        elseif a == "-j" or a == "--json" then
            opts.json = true
        elseif a == "-t" or a == "--test" then
            opts.test = true
        elseif a == "-b" or a == "--bench" then
            opts.bench = true
        elseif (a == "-f" or a == "--file") and args[i + 1] then
            i = i + 1
            opts.file = args[i]
        elseif (a == "-p" or a == "--path") and args[i + 1] then
            i = i + 1
            opts.path = args[i]
        elseif a == "-h" or a == "--help" then
            print_help()
            return
        end
        i = i + 1
    end

    if opts.test then
        SysInfo.run_tests()
    elseif opts.json then
        local data = SysInfo.get_all(opts.file, opts.path)
        print(SysInfo.to_json(data))
    elseif opts.compact then
        SysInfo.print_compact()
    elseif opts.bench then
        print(C.bold .. C.cyan .. "\n--- Running Extended FFI Memory & Throughput Benchmark ---" .. C.reset)
        for _, mb in ipairs({1, 4, 16, 64}) do
            local res = SysInfo.benchmark_memory(mb, 20)
            print(string.format("  [%2d MB] Throughput: %s%6.2f GB/s%s (time: %.4fs, C ptr write: %.3f ms)",
                mb, C.green .. C.bold, res.memset_gb_per_sec, C.reset, res.memset_duration_sec, res.c_ptr_duration_sec * 1000))
        end
        print(C.emerald .. "✔ Benchmark completed successfully!\n" .. C.reset)
    else
        SysInfo.print_report(opts)
    end
end

-- If executed directly as a script from CLI, invoke main
if arg and arg[0] and (arg[0] == "ffi_system_info.lua" or arg[0]:match("/ffi_system_info%.lua$")) then
    main(arg)
end

return SysInfo
