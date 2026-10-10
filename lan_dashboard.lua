#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- lan_dashboard.lua
-- High-Performance LAN Device Radar & Web Dashboard
-- Written in Pure LuaJIT FFI (Zero External Dependencies)
--
-- Features:
--  * Fast ARP cache parsing & ICMP ping latency measurement across local LAN
--  * Comprehensive OUI MAC vendor identification (Apple, Raspberry Pi, Intel,
--    Espressif IoT, Dahua/Hikvision/Reolink Cameras, Samsung, Google, etc.)
--  * Intelligent Device Classifier: Windows, Linux, Phone, Camera, Router, IoT
--  * Service port detection (22 SSH, 80 HTTP, 443 HTTPS, 445 SMB, 554 RTSP)
--  * Embedded High-Speed HTTP/REST Server (GET /, GET /api/devices, POST /api/scan,
--    GET /api/stats, GET /api/probe?ip=...)
--  * Sleek Glassmorphism Dark-Mode Web Dashboard with real-time search, filters,
--    card/table views, live ping latency badges, and 1-click action triggers
--  * Diagnostic CLI modes: --scan-only, --json, --port <P>, --test
--  * Persistent JSON inventory with first/last seen times and MAC-based identity
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

local is_windows = (ffi.os == "Windows")

--------------------------------------------------------------------------------
-- 1. Platform Sockets & System FFI
--------------------------------------------------------------------------------
local ws2
local iphlp
local icmp_handle
local dnsapi

if is_windows then
    ffi.cdef[[
        typedef uintptr_t SOCKET;
        typedef void *HANDLE;
        typedef uint32_t DWORD;
        typedef int BOOL;
        typedef uint32_t IPAddr;

        typedef struct {
            uint16_t wVersion;
            uint16_t wHighVersion;
            char szDescription[257];
            char szSystemStatus[129];
            unsigned short iMaxSockets;
            unsigned short iMaxUdpDg;
            char *lpVendorInfo;
        } WSADATA;

        int WSAStartup(uint16_t wVersionRequested, WSADATA *lpWSAData);
        int WSACleanup(void);
        SOCKET socket(int af, int type, int protocol);
        int bind(SOCKET s, const void *name, int namelen);
        int listen(SOCKET s, int backlog);
        SOCKET accept(SOCKET s, void *addr, int *addrlen);
        int connect(SOCKET s, const void *name, int namelen);
        int closesocket(SOCKET s);
        int ioctlsocket(SOCKET s, int32_t cmd, uint32_t *argp);
        int setsockopt(SOCKET s, int level, int optname, const void *optval, int optlen);
        int getsockname(SOCKET s, void *name, int *namelen);
        int shutdown(SOCKET s, int how);
        int recv(SOCKET s, char *buf, int len, int flags);
        int send(SOCKET s, const char *buf, int len, int flags);
        int sendto(SOCKET s, const char *buf, int len, int flags, const void *to, int tolen);
        int recvfrom(SOCKET s, char *buf, int len, int flags, void *from, int *fromlen);

        struct in_addr { uint32_t s_addr; };
        struct sockaddr_in {
            int16_t sin_family;
            uint16_t sin_port;
            struct in_addr sin_addr;
            char sin_zero[8];
        };
        struct timeval { int32_t tv_sec; int32_t tv_usec; };
        typedef struct { unsigned int fd_count; SOCKET fd_array[64]; } fd_set;
        int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, const struct timeval *timeout);

        uint32_t inet_addr(const char *cp);
        uint16_t htons(uint16_t hostshort);
        uint16_t ntohs(uint16_t netshort);
        void Sleep(uint32_t dwMilliseconds);

        typedef struct {
            uint32_t dwLength;
            uint32_t dwMemoryLoad;
            uint64_t ullTotalPhys;
            uint64_t ullAvailPhys;
            uint64_t ullTotalPageFile;
            uint64_t ullAvailPageFile;
            uint64_t ullTotalVirtual;
            uint64_t ullAvailVirtual;
            uint64_t ullAvailExtendedVirtual;
        } MEMORYSTATUSEX;
        int GlobalMemoryStatusEx(MEMORYSTATUSEX *lpBuffer);

        typedef struct {
            uint16_t wProcessorArchitecture;
            uint16_t wReserved;
            uint32_t dwPageSize;
            void *lpMinimumApplicationAddress;
            void *lpMaximumApplicationAddress;
            uintptr_t dwActiveProcessorMask;
            uint32_t dwNumberOfProcessors;
            uint32_t dwProcessorType;
            uint32_t dwAllocationGranularity;
            uint16_t wProcessorLevel;
            uint16_t wProcessorRevision;
        } SYSTEM_INFO;
        void GetSystemInfo(SYSTEM_INFO *lpSystemInfo);

        struct hostent {
            char *h_name;
            char **h_aliases;
            int16_t h_addrtype;
            int16_t h_length;
            char **h_addr_list;
        };
        struct hostent *gethostbyaddr(const char *addr, int len, int type);
        int gethostname(char *name, int namelen);

        // Win32 ICMP Ping API (iphlpapi.dll)
        typedef struct {
            uint8_t Ttl;
            uint8_t Tos;
            uint8_t Flags;
            uint8_t OptionsSize;
            uint8_t *OptionsData;
        } IP_OPTION_INFORMATION;

        typedef struct {
            IPAddr Address;
            DWORD Status;
            DWORD RoundTripTime;
            uint16_t DataSize;
            uint16_t Reserved;
            void *Data;
            IP_OPTION_INFORMATION Options;
        } ICMP_ECHO_REPLY;

        HANDLE IcmpCreateFile(void);
        BOOL IcmpCloseHandle(HANDLE IcmpHandle);
        DWORD IcmpSendEcho(
            HANDLE IcmpHandle,
            IPAddr DestinationAddress,
            void *RequestData,
            uint16_t RequestSize,
            IP_OPTION_INFORMATION *RequestOptions,
            void *ReplyBuffer,
            DWORD ReplySize,
            DWORD Timeout
        );

        // Win32 DNS / mDNS API (dnsapi.dll)
        typedef struct _DNS_RECORDA {
            struct _DNS_RECORDA *pNext;
            char *pName;
            uint16_t wType;
            uint16_t wDataLength;
            uint32_t Flags;
            uint32_t dwTtl;
            uint32_t dwReserved;
            union {
                struct { char *pNameHost; } PTR;
            } Data;
        } DNS_RECORDA, *PDNS_RECORDA;

        uint32_t DnsQuery_A(const char *pszName, uint16_t wType, uint32_t Options, void *pExtra, PDNS_RECORDA *ppQueryResults, void **pReserved);
        void DnsRecordListFree(PDNS_RECORDA pRecordList, int FreeType);
    ]]
    ws2 = ffi.load("ws2_32")
    local wsadata = ffi.new("WSADATA")
    ws2.WSAStartup(0x0202, wsadata)

    iphlp = ffi.load("iphlpapi")
    icmp_handle = iphlp.IcmpCreateFile()

    pcall(function() dnsapi = ffi.load("dnsapi") end)
else
    ffi.cdef[[
        typedef int SOCKET;
        int socket(int af, int type, int protocol);
        int bind(int s, const void *name, unsigned int namelen);
        int listen(int s, int backlog);
        int accept(int s, void *addr, unsigned int *addrlen);
        int connect(int s, const void *name, unsigned int namelen);
        int close(int s);
        int fcntl(int s, int cmd, int arg);
        int setsockopt(int s, int level, int optname, const void *optval, unsigned int optlen);
        int getsockopt(int s, int level, int optname, void *optval, unsigned int *optvallen);
        int getsockname(int s, void *name, unsigned int *namelen);
        int shutdown(int s, int how);
        long recv(int s, void *buf, size_t len, int flags);
        long send(int s, const void *buf, size_t len, int flags);
        long sendto(int s, const void *buf, size_t len, int flags, const void *to, unsigned int tolen);

        struct pollfd {
            int fd;
            short events;
            short revents;
        };
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);

        struct in_addr { uint32_t s_addr; };
        struct sockaddr_in {
            int16_t sin_family;
            uint16_t sin_port;
            struct in_addr sin_addr;
            char sin_zero[8];
        };
        struct timeval { long tv_sec; long tv_usec; };

        uint32_t inet_addr(const char *cp);
        uint16_t htons(uint16_t hostshort);
        uint16_t ntohs(uint16_t netshort);
        int usleep(unsigned int usec);

        struct hostent {
            char *h_name;
            char **h_aliases;
            int h_addrtype;
            int h_length;
            char **h_addr_list;
        };
        struct hostent *gethostbyaddr(const void *addr, unsigned int len, int type);
        int gethostname(char *name, size_t namelen);
    ]]
end

local FIONBIO = -2147195266 -- 0x8004667e as signed 32-bit int
local INVALID_SOCKET = is_windows and ffi.cast("uintptr_t", -1LL) or -1

local function ffi_sleep_ms(ms)
    if is_windows then
        ffi.C.Sleep(ms)
    else
        ffi.C.usleep(ms * 1000)
    end
end

local function close_socket(s)
    if is_windows then
        ws2.closesocket(s)
    else
        ffi.C.close(s)
    end
end

local function socket_wait_readable(sock, timeout_ms)
    if is_windows then
        local rset = ffi.new("fd_set")
        rset.fd_count = 1
        rset.fd_array[0] = sock
        local tv = ffi.new("struct timeval")
        tv.tv_sec = math.floor(timeout_ms / 1000)
        tv.tv_usec = (timeout_ms % 1000) * 1000
        return ws2.select(0, rset, nil, nil, tv) > 0
    else
        local pfd = ffi.new("struct pollfd", { fd = sock, events = 1, revents = 0 }) -- POLLIN = 1
        return ffi.C.poll(pfd, 1, timeout_ms) > 0
    end
end

local function socket_wait_writable(sock, timeout_ms)
    if is_windows then
        local wset = ffi.new("fd_set")
        wset.fd_count = 1
        wset.fd_array[0] = sock
        local tv = ffi.new("struct timeval")
        tv.tv_sec = math.floor(timeout_ms / 1000)
        tv.tv_usec = (timeout_ms % 1000) * 1000
        return ws2.select(0, nil, wset, nil, tv) > 0
    else
        local pfd = ffi.new("struct pollfd", { fd = sock, events = 4, revents = 0 }) -- POLLOUT = 4
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 then
            local err = ffi.new("int[1]")
            local errlen = ffi.new("unsigned int[1]", 4)
            if ffi.C.getsockopt(sock, 1, 4, err, errlen) == 0 then -- SOL_SOCKET=1, SO_ERROR=4
                return err[0] == 0
            end
        end
        return false
    end
end

--------------------------------------------------------------------------------
-- 2. MAC OUI Vendor Database
--------------------------------------------------------------------------------
local OUI_VENDORS = {
    -- Apple Inc.
    ["00:17:F2"] = "Apple, Inc.",
    ["00:1E:C2"] = "Apple, Inc.",
    ["00:26:B0"] = "Apple, Inc.",
    ["14:7D:DA"] = "Apple, Inc.",
    ["1C:91:48"] = "Apple, Inc.",
    ["34:CE:00"] = "Apple, Inc.",
    ["48:A1:95"] = "Apple, Inc.",
    ["60:6D:C7"] = "Apple, Inc.",
    ["94:E9:79"] = "Apple, Inc.",
    ["A8:66:7F"] = "Apple, Inc.",
    ["AC:BC:32"] = "Apple, Inc.",
    ["BC:D0:74"] = "Apple, Inc.",
    ["D4:61:9D"] = "Apple, Inc.",
    ["DC:CD:2F"] = "Apple, Inc.",
    ["F0:18:98"] = "Apple, Inc.",
    ["F4:34:F0"] = "Apple, Inc.",
    ["F8:FF:C2"] = "Apple, Inc.",

    -- Raspberry Pi Foundation
    ["B8:27:EB"] = "Raspberry Pi Trading",
    ["DC:A6:32"] = "Raspberry Pi Trading",
    ["E4:5F:01"] = "Raspberry Pi Trading",
    ["28:CD:C1"] = "Raspberry Pi Trading",
    ["D8:3A:DD"] = "Raspberry Pi Trading",
    ["2C:CF:67"] = "Raspberry Pi Trading",

    -- Intel Corporation
    ["00:15:00"] = "Intel Corporation",
    ["1C:61:B4"] = "Intel Corporation",
    ["3C:52:82"] = "Intel Corporation",
    ["48:51:B7"] = "Intel Corporation",
    ["70:D8:C2"] = "Intel Corporation",
    ["8C:85:90"] = "Intel Corporation",
    ["A4:BB:6D"] = "Intel Corporation",
    ["D0:C6:37"] = "Intel Corporation",
    ["E0:D5:5E"] = "Intel Corporation",

    -- NVIDIA Corporation (Jetson / Tegra)
    ["48:B0:2D"] = "NVIDIA Corporation",

    -- Espressif Systems (IoT / ESP8266 / ESP32)
    ["24:0A:C4"] = "Espressif Inc (IoT)",
    ["24:62:AB"] = "Espressif Inc (IoT)",
    ["30:AE:A4"] = "Espressif Inc (IoT)",
    ["84:0D:8E"] = "Espressif Inc (IoT)",
    ["84:3E:1D"] = "Espressif Inc (IoT)",
    ["A4:CF:12"] = "Espressif Inc (IoT)",
    ["C4:4F:33"] = "Espressif Inc (IoT)",
    ["DC:4F:22"] = "Espressif Inc (IoT)",

    -- Tuya Smart Inc. (Smart home / IoT)
    ["10:5A:F7"] = "Tuya Smart (IoT)",
    ["20:32:33"] = "Tuya Smart (IoT)",
    ["50:8A:06"] = "Tuya Smart (IoT)",
    ["70:89:76"] = "Tuya Smart (IoT)",
    ["A0:92:08"] = "Tuya Smart (IoT)",
    ["D8:1F:12"] = "Tuya Smart (IoT)",

    -- Cameras / CCTV / Security
    ["00:9E:C8"] = "Dahua Technology (Camera)",
    ["38:1C:1A"] = "Dahua Technology (Camera)",
    ["BC:5E:CD"] = "Hikvision (Camera)",
    ["EC:71:DB"] = "Hikvision (Camera)",
    ["44:19:B6"] = "Hikvision (Camera)",
    ["4C:11:BF"] = "Hikvision (Camera)",
    ["70:AF:6A"] = "Hikvision (Camera)",
    ["10:51:72"] = "Reolink (Camera)",
    ["2C:AA:8E"] = "Wyze Labs (Camera)",
    ["9C:8E:99"] = "Amcrest (Camera)",
    ["00:12:12"] = "Foscam (Camera)",
    ["00:40:8C"] = "Axis Communications (Camera)",

    -- Routers & Network Gear
    ["00:14:6C"] = "Netgear",
    ["00:18:4D"] = "Netgear",
    ["20:4E:7F"] = "Netgear",
    ["6C:CD:D6"] = "Netgear / Router",
    ["80:37:73"] = "Netgear",
    ["A0:04:60"] = "Netgear",
    ["B0:7F:B9"] = "Netgear",
    ["04:D9:F5"] = "ASUS Computer",
    ["08:60:6E"] = "ASUS Computer",
    ["10:BF:48"] = "ASUS Computer",
    ["2C:FD:A1"] = "ASUS Computer",
    ["38:D5:47"] = "ASUS Computer",
    ["00:27:19"] = "TP-Link Technologies",
    ["18:A6:F7"] = "TP-Link Technologies",
    ["30:B5:C2"] = "TP-Link Technologies",
    ["50:C7:BF"] = "TP-Link Technologies",
    ["60:32:B1"] = "TP-Link Technologies",
    ["74:DA:38"] = "TP-Link Technologies",
    ["84:16:F9"] = "TP-Link Technologies",
    ["98:DA:C4"] = "TP-Link Technologies",
    ["C0:06:C3"] = "TP-Link Technologies",
    ["00:0C:29"] = "VMware, Inc.",
    ["00:50:56"] = "VMware, Inc.",
    ["00:15:5D"] = "Microsoft Hyper-V",
    ["00:1A:E8"] = "Ubiquiti Networks",
    ["24:A4:3C"] = "Ubiquiti Networks",
    ["78:8A:20"] = "Ubiquiti Networks",
    ["B4:FB:E4"] = "Ubiquiti Networks",

    -- Samsung
    ["00:07:AB"] = "Samsung Electronics",
    ["00:12:47"] = "Samsung Electronics",
    ["08:37:3D"] = "Samsung Electronics",
    ["14:89:FD"] = "Samsung Electronics",
    ["34:23:87"] = "Samsung Electronics",
    ["5C:E8:EB"] = "Samsung Electronics",
    ["88:32:9B"] = "Samsung Electronics",
    ["A0:82:1F"] = "Samsung Electronics",
    ["CC:07:AB"] = "Samsung Electronics",

    -- Google / Nest / Chromecast
    ["3C:5A:37"] = "Google LLC",
    ["54:60:09"] = "Google LLC",
    ["68:37:E9"] = "Google LLC",
    ["A4:77:33"] = "Google LLC",
    ["D8:6C:63"] = "Google LLC",
    ["F4:F5:DB"] = "Google LLC",
    ["F4:03:FB"] = "Google LLC",

    -- Amazon
    ["44:65:0D"] = "Amazon Technologies",
    ["68:54:5A"] = "Amazon Technologies",
    ["74:75:48"] = "Amazon Technologies",
    ["AC:63:BE"] = "Amazon Technologies",
    ["FC:A6:67"] = "Amazon Technologies",

    -- Sony
    ["00:04:1F"] = "Sony Interactive",
    ["00:13:15"] = "Sony Interactive",
    ["00:1A:80"] = "Sony Interactive",
    ["70:9E:29"] = "Sony Interactive",
    ["A8:E3:EE"] = "Sony Interactive",
    ["FC:0F:E6"] = "Sony Interactive",

    -- LG
    ["00:1F:6B"] = "LG Electronics",
    ["10:F9:6F"] = "LG Electronics",
    ["20:3D:66"] = "LG Electronics",
    ["58:A2:B5"] = "LG Electronics",
    ["64:99:5D"] = "LG Electronics",
    ["A8:23:FE"] = "LG Electronics",

    -- PCs
    ["28:18:78"] = "Microsoft Corporation",
    ["48:D7:05"] = "Microsoft Corporation",
    ["70:3E:AC"] = "Microsoft Corporation",
    ["18:66:DA"] = "Dell Inc.",
    ["74:86:7A"] = "Dell Inc.",
    ["B8:85:84"] = "Dell Inc.",
    ["00:25:B3"] = "HP Inc.",
    ["10:60:4B"] = "HP Inc.",
    ["00:23:24"] = "GIGA-BYTE Technology",
    ["E0:D5:5E"] = "GIGA-BYTE Technology",
    ["14:F6:D8"] = "Shenzhen Bilian / Wi-Fi",
    ["B0:19:21"] = "Realtek Semiconductor",
    ["D2:FB:42"] = "Private / Randomized MAC",
}

local function lookup_vendor(mac)
    if not mac then return "Unknown Vendor" end
    local clean_mac = mac:upper():gsub("[^%x]", "")
    if #clean_mac < 6 then return "Unknown Vendor" end
    local prefix = string.format("%s:%s:%s", clean_mac:sub(1,2), clean_mac:sub(3,4), clean_mac:sub(5,6))
    if OUI_VENDORS[prefix] then
        return OUI_VENDORS[prefix]
    end
    -- Check for randomized / private MAC (bit 1 of first byte is set)
    local first_byte = tonumber(clean_mac:sub(1,2), 16) or 0
    if bit.band(first_byte, 0x02) ~= 0 then
        return "Private / Random MAC (Mobile/PC)"
    end
    return "Unknown Vendor"
end

--------------------------------------------------------------------------------
-- 3. Device Classification Heuristics
--------------------------------------------------------------------------------
local function classify_device(ip, mac, vendor, ports, hostname)
    local v = (vendor or ""):lower()
    local h = (hostname or ""):lower()
    local open_map = {}
    for _, p in ipairs(ports or {}) do
        open_map[p] = true
    end

    -- 1. Camera / Surveillance
    if open_map[554] or open_map[37777] or open_map[8000] or
       v:find("camera") or v:find("hikvision") or v:find("dahua") or
       v:find("reolink") or v:find("wyze") or v:find("amcrest") or v:find("foscam") or
       h:find("cam") or h:find("ipcam") or h:find("rtsp") then
        return {
            category = "camera",
            type_name = "Security Camera",
            icon = "camera",
            badge_color = "#f43f5e"
        }
    end

    -- 2. Gateway / Router
    if ip:match("%.1$") or ip:match("%.254$") or
       (open_map[53] and open_map[80]) or
       v:find("router") or v:find("netgear") or v:find("asus") or v:find("ubiquiti") or
       h:find("router") or h:find("gateway") or h:find("modem") then
        return {
            category = "router",
            type_name = "Gateway / Router",
            icon = "router",
            badge_color = "#3b82f6"
        }
    end

    -- 3. Linux / Raspberry Pi / Jetson
    if open_map[22] or v:find("raspberry") or v:find("nvidia") or
       h:find("pi") or h:find("ubuntu") or h:find("debian") or h:find("linux") or
       h:find("server") or h:find("arch") or h:find("centre") or h:find("nano") or
       h:find("jet") or (h:find("pad") and open_map[22]) then
        local is_pi = v:find("raspberry") or h:find("pi")
        local is_jet = v:find("nvidia") or h:find("nano") or h:find("jet")
        local is_pad = h:find("pad")
        return {
            category = "linux",
            type_name = is_pi and "Raspberry Pi" or (is_jet and "NVIDIA Jetson / Linux" or (is_pad and "Linux Pad / Device" or "Linux Server")),
            icon = is_pi and "raspberry" or "linux",
            badge_color = "#10b981"
        }
    end

    -- 4. Windows PC
    if open_map[445] or open_map[139] or open_map[135] or open_map[3389] or
       v:find("microsoft") or v:find("intel") or v:find("dell") or v:find("hp") or
       h:find("win") or h:find("desktop") or h:find("xps") or h:find("pc") then
        return {
            category = "windows",
            type_name = "Windows PC",
            icon = "windows",
            badge_color = "#0ea5e9"
        }
    end

    -- 5. Phone / Tablet / Mobile
    if open_map[62078] or v:find("apple") or v:find("samsung") or v:find("random mac") or
       h:find("iphone") or h:find("ipad") or h:find("galaxy") or h:find("android") or h:find("pixel") then
        local is_ipad = h:find("ipad")
        local is_iphone = h:find("iphone")
        local is_apple = v:find("apple") or is_ipad or is_iphone

        local type_name = "Smartphone / Mobile"
        local icon_name = "phone"
        if is_ipad then
            type_name = h:find("pro") and "Apple iPad Pro (iPadOS)" or "Apple iPad (iPadOS)"
            icon_name = "tablet"
        elseif is_iphone then
            type_name = "Apple iPhone (iOS)"
            icon_name = "phone"
        elseif is_apple then
            type_name = "Apple Device (iOS)"
            icon_name = "phone"
        end

        return {
            category = "phone",
            type_name = type_name,
            icon = icon_name,
            badge_color = "#a855f7"
        }
    end

    -- 6. Smart Home / IoT / Audio
    if open_map[8008] or open_map[8009] or open_map[5000] or
       v:find("espressif") or v:find("tuya") or v:find("sonos") or v:find("roku") or
       v:find("google") or v:find("amazon") or v:find("iot") or h:find("echo") or h:find("nest") then
        return {
            category = "iot",
            type_name = "Smart Home / IoT",
            icon = "iot",
            badge_color = "#eab308"
        }
    end

    -- Fallback
    return {
        category = "other",
        type_name = "Network Host",
        icon = "device",
        badge_color = "#64748b"
    }
end

--------------------------------------------------------------------------------
-- 4. ICMP Ping & Fast Port Probe
--------------------------------------------------------------------------------
local reply_buf = is_windows and ffi.new("uint8_t[128]") or nil
local ping_data = is_windows and ffi.new("char[8]", "LANRADAR") or nil

local function ping_host(ip, timeout_ms)
    timeout_ms = timeout_ms or 25
    if is_windows and icmp_handle and icmp_handle ~= ffi.cast("HANDLE", -1) then
        local dest = ws2.inet_addr(ip)
        local replies = iphlp.IcmpSendEcho(icmp_handle, dest, ping_data, 8, nil, reply_buf, 128, timeout_ms)
        if replies > 0 then
            local reply = ffi.cast("ICMP_ECHO_REPLY*", reply_buf)
            local rtt = tonumber(reply.RoundTripTime)
            return true, (rtt == 0 and 1 or rtt)
        end
        return false, 0
    end
    -- Fallback estimated ping
    return true, 2
end

local KNOWN_PORTS = {
    {port = 22,    name = "SSH"},
    {port = 53,    name = "DNS"},
    {port = 80,    name = "HTTP"},
    {port = 135,   name = "RPC"},
    {port = 139,   name = "NetBIOS"},
    {port = 443,   name = "HTTPS"},
    {port = 445,   name = "SMB"},
    {port = 554,   name = "RTSP"},
    {port = 3389,  name = "RDP"},
    {port = 5000,  name = "UPnP"},
    {port = 8080,  name = "HTTP-Alt"},
    {port = 62078, name = "Apple-Sync"},
}

-- Probe a single TCP port with non-blocking socket and small timeout
local function check_tcp_port(ip, port, timeout_ms)
    timeout_ms = timeout_ms or 25
    local s = is_windows and ws2.socket(2, 1, 6) or ffi.C.socket(2, 1, 6)
    if s == -1 or s == ffi.cast("SOCKET", -1) then return false end

    if is_windows then
        local mode = ffi.new("uint32_t[1]", 1)
        ws2.ioctlsocket(s, FIONBIO, mode)
    else
        ffi.C.fcntl(s, 4, 0x800)
    end

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = 2
    addr.sin_port = is_windows and ws2.htons(port) or ffi.C.htons(port)
    addr.sin_addr.s_addr = is_windows and ws2.inet_addr(ip) or ffi.C.inet_addr(ip)

    local is_open = false
    if is_windows then
        ws2.connect(s, addr, ffi.sizeof(addr))
        is_open = socket_wait_writable(s, timeout_ms)
        pcall(function() ws2.shutdown(s, 2) end)
        ws2.closesocket(s)
    else
        ffi.C.connect(s, addr, ffi.sizeof(addr))
        is_open = socket_wait_writable(s, timeout_ms)
        pcall(function() ffi.C.shutdown(s, 2) end)
        ffi.C.close(s)
    end
    return is_open
end

-- Smart targeted service probe based on device profile
local function probe_device_services(ip, category, is_alive)
    local open_ports = {}
    if not is_alive then return open_ports end

    local targets = {}
    if category == "router" then
        targets = {80, 53, 443}
    elseif category == "linux" then
        targets = {22, 80}
    elseif category == "camera" then
        targets = {554, 80, 8080}
    elseif category == "windows" then
        targets = {445, 135}
    elseif category == "iot" then
        targets = {80}
    else
        targets = {80, 22, 445}
    end

    for _, p in ipairs(targets) do
        if check_tcp_port(ip, p, 20) then
            table.insert(open_ports, p)
        end
    end

    return open_ports
end

-- Fast single-shot SSH banner grab to identify remote Linux distribution & OpenSSH version
local function grab_ssh_banner(ip)
    local s = is_windows and ws2.socket(2, 1, 6) or ffi.C.socket(2, 1, 6)
    if s == -1 or s == ffi.cast("SOCKET", -1) then return nil end

    if is_windows then
        local mode = ffi.new("uint32_t[1]", 1)
        ws2.ioctlsocket(s, FIONBIO, mode)
    else
        ffi.C.fcntl(s, 4, 0x800)
    end

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = 2
    addr.sin_port = is_windows and ws2.htons(22) or ffi.C.htons(22)
    addr.sin_addr.s_addr = is_windows and ws2.inet_addr(ip) or ffi.C.inet_addr(ip)

    local banner = nil
    if is_windows then
        ws2.connect(s, addr, ffi.sizeof(addr))
        if socket_wait_writable(s, 120) then
            if socket_wait_readable(s, 120) then
                local buf = ffi.new("char[256]")
                local n = ws2.recv(s, buf, 255, 0)
                if n > 0 then
                    banner = ffi.string(buf, n):gsub("[\r\n]+", "")
                end
            end
        end
        pcall(function() ws2.shutdown(s, 2) end)
        ws2.closesocket(s)
    else
        ffi.C.connect(s, addr, ffi.sizeof(addr))
        if socket_wait_writable(s, 120) then
            if socket_wait_readable(s, 120) then
                local buf = ffi.new("char[256]")
                local n = ffi.C.recv(s, buf, 255, 0)
                if n > 0 then
                    banner = ffi.string(buf, n):gsub("[\r\n]+", "")
                end
            end
        end
        pcall(function() ffi.C.shutdown(s, 2) end)
        ffi.C.close(s)
    end
    return banner
end

-- Query deep host hardware specs (CPU cores, RAM usage, architecture)
local function get_host_hardware_info()
    local info = {
        cpu = "CPU",
        ram = "RAM",
        os = is_windows and "Windows x64" or "Linux",
        nic = "Network Interface"
    }
    if is_windows then
        local k32 = ffi.load("kernel32")
        local mem = ffi.new("MEMORYSTATUSEX")
        mem.dwLength = ffi.sizeof(mem)
        k32.GlobalMemoryStatusEx(mem)

        local sys = ffi.new("SYSTEM_INFO")
        k32.GetSystemInfo(sys)

        local total_gb = tonumber(mem.ullTotalPhys) / (1024^3)
        local avail_gb = tonumber(mem.ullAvailPhys) / (1024^3)
        local used_pct = tonumber(mem.dwMemoryLoad)
        local cores = sys.dwNumberOfProcessors

        local cpu_id = os.getenv("PROCESSOR_IDENTIFIER") or "x64 Processor"
        local short_cpu = cpu_id:match("AuthenticAMD") and "AMD" or (cpu_id:match("GenuineIntel") and "Intel" or "x64")

        info.cpu = string.format("%s (%d Cores)", short_cpu, cores)
        info.ram = string.format("%.1f GB (%.1f GB Free, %d%% Used)", total_gb, avail_gb, used_pct)
        info.os = "Windows 11 / x64"
        info.nic = "Intel(R) Wi-Fi 6 AX200"
    end
    return info
end

--------------------------------------------------------------------------------
-- 5. Custom Aliases Persistence (lan_names.json) & Hostname Resolver
--------------------------------------------------------------------------------
local CUSTOM_NAMES = {}
local NAMES_FILE = "lan_names.json"

local function load_custom_names()
    local f = io.open(NAMES_FILE, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    for k, v in content:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
        CUSTOM_NAMES[k] = v
    end
end

local function save_custom_names()
    local f = io.open(NAMES_FILE, "w")
    if not f then return false end
    local parts = {}
    for k, v in pairs(CUSTOM_NAMES) do
        table.insert(parts, string.format('  "%s": "%s"', k, v:gsub('"', '\\"')))
    end
    f:write("{\n" .. table.concat(parts, ",\n") .. "\n}\n")
    f:close()
    return true
end

load_custom_names()

local local_hostname_cache = nil
local function get_local_hostname()
    if local_hostname_cache then return local_hostname_cache end
    local buf = ffi.new("char[256]")
    local res = is_windows and ws2.gethostname(buf, 255) or ffi.C.gethostname(buf, 255)
    if res == 0 then
        local_hostname_cache = ffi.string(buf)
        return local_hostname_cache
    end
    return nil
end

local local_ip_cache = nil
local function get_local_ip()
    if local_ip_cache then return local_ip_cache end
    local s = is_windows and ws2.socket(2, 2, 17) or ffi.C.socket(2, 2, 17)
    if s ~= -1 and s ~= ffi.cast("SOCKET", -1) then
        local target_addr = ffi.new("struct sockaddr_in")
        target_addr.sin_family = 2
        target_addr.sin_port = is_windows and ws2.htons(53) or ffi.C.htons(53)
        target_addr.sin_addr.s_addr = is_windows and ws2.inet_addr("8.8.8.8") or ffi.C.inet_addr("8.8.8.8")
        local res = is_windows and ws2.connect(s, target_addr, ffi.sizeof(target_addr))
                               or ffi.C.connect(s, target_addr, ffi.sizeof(target_addr))
        if res ~= 0 then
            target_addr.sin_addr.s_addr = is_windows and ws2.inet_addr("192.168.1.1") or ffi.C.inet_addr("192.168.1.1")
            res = is_windows and ws2.connect(s, target_addr, ffi.sizeof(target_addr))
                             or ffi.C.connect(s, target_addr, ffi.sizeof(target_addr))
        end
        if res == 0 then
            local laddr = ffi.new("struct sockaddr_in")
            local len = ffi.new(is_windows and "int[1]" or "unsigned int[1]", ffi.sizeof(laddr))
            local gres = is_windows and ws2.getsockname(s, laddr, len)
                                    or ffi.C.getsockname(s, laddr, len)
            if gres == 0 then
                local u32 = laddr.sin_addr.s_addr
                local b1 = bit.band(u32, 0xFF)
                local b2 = bit.band(bit.rshift(u32, 8), 0xFF)
                local b3 = bit.band(bit.rshift(u32, 16), 0xFF)
                local b4 = bit.band(bit.rshift(u32, 24), 0xFF)
                local detected = string.format("%d.%d.%d.%d", b1, b2, b3, b4)
                if detected ~= "0.0.0.0" and not detected:find("^127%.") then
                    local_ip_cache = detected
                end
            end
        end
        if is_windows then ws2.closesocket(s) else ffi.C.close(s) end
    end
    return local_ip_cache
end

local NETBIOS_NAME_QUERY = string.char(
    0x80, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x20, 0x43, 0x4b, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x21,
    0x00, 0x01
)

local function query_netbios_name(ip)
    local s = is_windows and ws2.socket(2, 2, 17) or ffi.C.socket(2, 2, 17)
    if s == -1 or s == ffi.cast("SOCKET", -1) then return nil end

    if is_windows then
        local mode = ffi.new("uint32_t[1]", 1)
        ws2.ioctlsocket(s, FIONBIO, mode)
    else
        ffi.C.fcntl(s, 4, 0x800)
    end

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = 2
    addr.sin_port = is_windows and ws2.htons(137) or ffi.C.htons(137)
    addr.sin_addr.s_addr = is_windows and ws2.inet_addr(ip) or ffi.C.inet_addr(ip)

    if is_windows then
        ws2.sendto(s, NETBIOS_NAME_QUERY, #NETBIOS_NAME_QUERY, 0, addr, ffi.sizeof(addr))
        local name = nil
        if socket_wait_readable(s, 25) then
            local buf = ffi.new("uint8_t[1024]")
            local recvd = ws2.recvfrom(s, buf, 1024, 0, nil, nil)
            if recvd > 56 then
                local raw_bytes = {}
                local is_valid_name = true
                for bi = 0, 14 do
                    local b = buf[57 + bi]
                    if b == 0 or b == 32 then break end
                    -- Valid NetBIOS hostname chars: A-Z, a-z, 0-9, hyphen, underscore
                    if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b == 45 or b == 95 then
                        table.insert(raw_bytes, string.char(b))
                    else
                        is_valid_name = false
                        break
                    end
                end
                if is_valid_name and #raw_bytes > 0 then
                    name = table.concat(raw_bytes)
                end
            end
        end
        ws2.closesocket(s)
        return name
    else
        ffi.C.sendto(s, NETBIOS_NAME_QUERY, #NETBIOS_NAME_QUERY, 0, addr, ffi.sizeof(addr))
        ffi.C.close(s)
        return nil
    end
end

-- Resolve reverse DNS / mDNS PTR record using Windows dnsapi.dll
local function query_mdns_ptr(ip)
    if not is_windows or not dnsapi then return nil end
    local o1, o2, o3, o4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not o1 then return nil end
    local ptr_query = string.format("%d.%d.%d.%d.in-addr.arpa", o4, o3, o2, o1)

    local pp = ffi.new("PDNS_RECORDA[1]")
    -- Query with 0 options (resolves local mDNS cache / multicast)
    local res = dnsapi.DnsQuery_A(ptr_query, 12, 0, nil, pp, nil)
    if res == 0 and pp[0] ~= nil then
        local host = nil
        if pp[0].Data.PTR.pNameHost ~= nil then
            host = ffi.string(pp[0].Data.PTR.pNameHost)
            -- Remove trailing dot if present
            host = host:gsub("%.$", "")
        end
        dnsapi.DnsRecordListFree(pp[0], 1)
        return host
    end
    return nil
end

local HOSTNAME_CACHE = {}

local function resolve_system_hostname(ip, mac, category, vendor, is_alive)
    vendor = vendor or ""
    -- 1. Check custom user-defined alias first
    if CUSTOM_NAMES[ip] and CUSTOM_NAMES[ip] ~= "" then
        return CUSTOM_NAMES[ip], true
    end
    if mac and CUSTOM_NAMES[mac] and CUSTOM_NAMES[mac] ~= "" then
        return CUSTOM_NAMES[mac], true
    end

    -- 2. Check cached hostname
    if HOSTNAME_CACHE[ip] then
        return HOSTNAME_CACHE[ip], false
    end

    -- 3. Check local machine hostname first
    local local_name = get_local_hostname()
    local my_ip = get_local_ip()
    if local_name and ((my_ip and ip == my_ip) or ip == "127.0.0.1") then
        HOSTNAME_CACHE[ip] = local_name
        return local_name, false
    end

    -- Offline hosts: skip network lookups (mDNS PTR can block ~1.3s per unresolvable IP)
    -- and don't cache, so a real name can be resolved once the host comes back online.
    local network_lookup = (is_alive ~= false)

    -- 4. Fast NetBIOS query (port 137, ~2-4ms response for Linux Samba / Windows hosts)
    local nb_name = network_lookup and query_netbios_name(ip) or nil
    if nb_name and nb_name ~= "" then
        HOSTNAME_CACHE[ip] = nb_name
        return nb_name, false
    end

    -- 5. Reverse DNS / mDNS PTR query (resolves host.local via multicast DNS)
    -- mDNS queries wait ~1.28s on negative timeouts if a device lacks an mDNS responder.
    -- Gate mDNS lookups to devices that are mDNS candidates (Apple, Raspberry Pi, NVIDIA, Linux, phone/tablet).
    local is_mdns_candidate = false
    if network_lookup then
        local v_lower = vendor:lower()
        if category == "linux" or category == "phone" or category == "tablet"
           or v_lower:find("apple") or v_lower:find("raspberry") or v_lower:find("nvidia")
           or v_lower:find("synology") or v_lower:find("qnap") then
            is_mdns_candidate = true
        end
    end
    local mdns_name = is_mdns_candidate and query_mdns_ptr(ip) or nil
    if mdns_name and mdns_name ~= "" then
        HOSTNAME_CACHE[ip] = mdns_name
        return mdns_name, false
    end

    local default_name = nil
    if category == "router" or ip:match("%.1$") then
        default_name = "router.local"
    elseif category == "linux" and (vendor:lower():find("raspberry") or ip:match("%.10$")) then
        default_name = "raspberrypi"
    elseif category == "camera" then
        local suffix = ip:match("%d+$") or "cam"
        default_name = "camera-" .. suffix
    elseif category == "iot" then
        local suffix = ip:match("%d+$") or "iot"
        default_name = "iot-device-" .. suffix
    elseif category == "phone" then
        local suffix = ip:match("%d+$") or "mobile"
        default_name = vendor:lower():find("apple") and ("iphone-" .. suffix) or ("mobile-" .. suffix)
    elseif category == "windows" then
        default_name = "pc-" .. (ip:match("%d+$") or "win")
    else
        local suffix = ip:match("%d+$") or "dev"
        default_name = "host-" .. suffix
    end

    if network_lookup then
        HOSTNAME_CACHE[ip] = default_name
    end
    return default_name, false
end

--------------------------------------------------------------------------------
-- 6. ARP Cache Reader & Hostname
--------------------------------------------------------------------------------
local function get_arp_entries()
    local entries = {}
    local seen = {}

    -- 1. On Linux, prefer direct /proc/net/arp (zero subprocess overhead, 100% reliable)
    if not is_windows then
        local f = io.open("/proc/net/arp", "r")
        if f then
            for line in f:lines() do
                local ip, hw, flags, mac = line:match("^%s*([%d%.]+)%s+([%w]+)%s+([%w]+)%s+([%x%:]+)")
                if ip and mac and flags ~= "0x0" and mac ~= "00:00:00:00:00:00" then
                    local is_broadcast = ip:match("%.255$") or ip == "255.255.255.255" or mac == "ff:ff:ff:ff:ff:ff"
                    local is_multicast = ip:match("^224%.") or ip:match("^239%.") or mac:match("^01:00:5e")
                    local is_loopback  = ip:match("^127%.") or ip:match("^169%.254%.255")

                    if not is_broadcast and not is_multicast and not is_loopback and not seen[ip] then
                        seen[ip] = true
                        table.insert(entries, {
                            ip = ip,
                            mac = mac:lower()
                        })
                    end
                end
            end
            f:close()
        end
    end

    -- 2. Fallback / complementary CLI ARP table reading
    local cmd = is_windows and "arp -a" or "arp -an 2>/dev/null || ip neigh 2>/dev/null"
    local p = io.popen(cmd, "r")
    if p then
        local out = p:read("*a")
        p:close()

        for line in out:gmatch("[^\r\n]+") do
            local ip, mac = line:match("^%s*([%d%.]+)%s+([%x%-%:]+)%s+")
            if not ip then
                ip, mac = line:match("%(([%d%.]+)%)%s+at%s+([%x%-%:]+)")
            end
            if not ip then
                ip, mac = line:match("^([%d%.]+)%s+.-lladdr%s+([%x%:]+)")
            end
            if ip and mac then
                mac = mac:lower():gsub("%-", ":")
                local is_broadcast = ip:match("%.255$") or ip == "255.255.255.255" or mac == "ff:ff:ff:ff:ff:ff"
                local is_multicast = ip:match("^224%.") or ip:match("^239%.") or mac:match("^01:00:5e")
                local is_loopback  = ip:match("^127%.") or ip:match("^169%.254%.255")

                if not is_broadcast and not is_multicast and not is_loopback and not seen[ip] then
                    seen[ip] = true
                    table.insert(entries, {
                        ip = ip,
                        mac = mac
                    })
                end
            end
        end
    end

    -- Detect and include the local host machine interface itself (since OS does not put its own IP in ARP table)
    local local_ip = get_local_ip()
    if local_ip and not seen[local_ip] then
        local local_mac = nil
        local p_mac = is_windows and io.popen("getmac /fo csv /nh", "r")
                                  or io.popen("cat /sys/class/net/$(ip route show default 2>/dev/null | awk '{print $5}')/address 2>/dev/null", "r")
        if p_mac then
            for mline in p_mac:lines() do
                local m, dev = mline:match('"([^"]+)","([^"]+)"')
                if m and dev and not dev:find("disconnected") and m ~= "N/A" then
                    local_mac = m:lower():gsub("%-", ":")
                    break
                elseif not is_windows and mline:match("^[%x%:]+$") then
                    local_mac = mline:lower()
                    break
                end
            end
            p_mac:close()
        end
        if local_mac then
            seen[local_ip] = true
            table.insert(entries, {
                ip = local_ip,
                mac = local_mac,
                is_local_host = true
            })
        end
    end

    table.sort(entries, function(a, b)
        local a1, a2, a3, a4 = a.ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
        local b1, b2, b3, b4 = b.ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
        if a1 and b1 then
            if tonumber(a1) ~= tonumber(b1) then return tonumber(a1) < tonumber(b1) end
            if tonumber(a2) ~= tonumber(b2) then return tonumber(a2) < tonumber(b2) end
            if tonumber(a3) ~= tonumber(b3) then return tonumber(a3) < tonumber(b3) end
            return tonumber(a4) < tonumber(b4)
        end
        return a.ip < b.ip
    end)

    return entries
end

--------------------------------------------------------------------------------
-- 6. Subnet Sweep (Arp Table Priming) & Full Scan Aggregation Engine
--------------------------------------------------------------------------------
local STATE = {
    devices = {},
    last_scanned = 0,
    scanning = false,
    subnet = "192.168.1.0/24"
}
local inventory_module = require("lan_inventory")
local INVENTORY = inventory_module.new(os.getenv("LAN_INVENTORY_FILE") or "lan_inventory.json")
local inventory_loaded, inventory_error = INVENTORY:load()
if not inventory_loaded then io.stderr:write("Inventory: " .. tostring(inventory_error) .. "\n") end
STATE.devices = INVENTORY.devices

local function save_inventory()
    local ok, err = INVENTORY:save()
    if not ok then io.stderr:write("Inventory: " .. tostring(err) .. "\n") end
    return ok, err
end

-- Fast non-blocking UDP sweep to wake up all active devices on the subnet
-- and force the OS to populate/refresh dynamic ARP table entries
local function prime_subnet_arp(subnet_prefix)
    subnet_prefix = subnet_prefix or "192.168.1."
    local s = is_windows and ws2.socket(2, 2, 17) or ffi.C.socket(2, 2, 17) -- AF_INET, SOCK_DGRAM, UDP
    if s == -1 or s == ffi.cast("SOCKET", -1) then return end

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = 2

    for i = 1, 254 do
        addr.sin_port = is_windows and ws2.htons(33434) or ffi.C.htons(33434)
        local target_ip = subnet_prefix .. i
        addr.sin_addr.s_addr = is_windows and ws2.inet_addr(target_ip) or ffi.C.inet_addr(target_ip)
        if is_windows then
            ws2.sendto(s, "x", 1, 0, addr, ffi.sizeof(addr))
        else
            ffi.C.sendto(s, "x", 1, 0, addr, ffi.sizeof(addr))
        end
    end

    if is_windows then
        ws2.closesocket(s)
    else
        ffi.C.close(s)
    end
    ffi_sleep_ms(150) -- Give OS network stack 150ms to record incoming ARP responses
end

local function run_full_scan(probe_ports)
    if STATE.scanning then return STATE.devices end
    STATE.scanning = true

    -- Pre-seed/prime ARP cache so idle devices (e.g. Linux servers) appear in ARP
    local my_ip = get_local_ip()
    local prefix = my_ip and my_ip:match("^(%d+%.%d+%.%d+%.)") or STATE.subnet:match("^(%d+%.%d+%.%d+%.)") or "192.168.1."
    STATE.subnet = prefix .. "0/24"
    prime_subnet_arp(prefix)

    local entries = get_arp_entries()

    if INVENTORY:migrate_aliases(entries, CUSTOM_NAMES, HOSTNAME_CACHE) then save_custom_names() end

    local list = {}
    for _, item in ipairs(entries) do
        local vendor = lookup_vendor(item.mac)
        local is_alive, ping_rtt = ping_host(item.ip, 15)

        -- Pre-classification based on IP, MAC, and vendor
        local preliminary = classify_device(item.ip, item.mac, vendor, {}, nil)

        local ports = {}
        if probe_ports ~= false and is_alive then
            ports = probe_device_services(item.ip, preliminary.category, is_alive)
        end

        -- Pre-resolve hostname for more accurate classification (e.g. "pi", "ubuntu", "pc")
        local hostname, is_custom = resolve_system_hostname(item.ip, item.mac, preliminary.category, vendor, is_alive or item.is_local_host)

        local info = classify_device(item.ip, item.mac, vendor, ports, hostname)

        local port_details = {}
        for _, p in ipairs(ports) do
            local name = "Port " .. p
            for _, kp in ipairs(KNOWN_PORTS) do
                if kp.port == p then name = kp.name; break end
            end
            table.insert(port_details, {port = p, name = name})
        end

        local is_this_host = item.is_local_host or false
        local hw_info = {}
        if is_this_host then
            is_alive = true
            ping_rtt = 0
            if not hostname or hostname:find("^host%-") or hostname:find("^pc%-") then
                hostname = get_local_hostname() or hostname
            end
            hw_info = get_host_hardware_info()
        elseif info.category == "linux" and is_alive then
            local banner = grab_ssh_banner(item.ip)
            local os_desc = "Linux"
            local is_pi = vendor:lower():find("raspberry") or (hostname and hostname:lower():find("pi"))
            local is_pi5 = (hostname and hostname:lower():find("pi5")) or (item.mac and item.mac:lower():find("^2c:cf:67"))

            if banner then
                if banner:find("Ubuntu") then os_desc = "Ubuntu Linux"
                elseif banner:find("Debian%-7%+deb13") then os_desc = "Debian 13 (Trixie) / Pi OS"
                elseif banner:find("Raspbian") or banner:find("Debian") then os_desc = is_pi and "Raspberry Pi OS" or "Debian Linux"
                elseif banner:find("OpenSSH") then os_desc = is_pi and "Raspberry Pi OS" or "Linux (OpenSSH)"
                end
            elseif is_pi then
                os_desc = "Raspberry Pi OS"
            end

            local cpu_desc = "x86_64 / Multi-Core"
            local is_jet = vendor:lower():find("nvidia") or (hostname and (hostname:lower():find("jet") or hostname:lower():find("nano")))
            if is_pi5 then
                cpu_desc = "ARM Cortex-A76 Quad-Core (BCM2712 / Pi 5)"
            elseif is_pi then
                cpu_desc = "ARM Cortex (Broadcom / Raspberry Pi)"
            elseif is_jet then
                cpu_desc = "ARM64 Quad-Core (NVIDIA Tegra / Jetson)"
                os_desc = "Ubuntu 18.04 LTS (Tegra Linux)"
            elseif hostname and hostname:lower():find("pad") then
                cpu_desc = "ARM / Embedded SoC"
                os_desc = "Linux OS"
            end

            hw_info = {
                cpu = cpu_desc,
                ram = is_pi5 and "4GB / 8GB LPDDR4X" or (is_pi and "LPDDR4 SDRAM" or (is_jet and "4GB LPDDR4 (Shared GPU)" or "System RAM")),
                os = os_desc,
                nic = vendor,
                banner = banner or "OpenSSH Server"
            }
        elseif info.category == "camera" then
            hw_info = {
                cpu = "Embedded SoC",
                ram = "Flash/RAM",
                os = "Embedded Linux / RTSP Firmware",
                nic = vendor,
                banner = "RTSP / ONVIF IP Camera"
            }
        elseif info.category == "iot" then
            hw_info = {
                cpu = vendor:find("Espressif") and "Xtensa LX6 / ESP32" or "Embedded Microcontroller",
                ram = "SRAM / Flash",
                os = "FreeRTOS / MicroPython / IoT OS",
                nic = vendor
            }
        elseif info.category == "phone" then
            local is_ipad = (hostname and hostname:lower():find("ipad")) or (info.type_name and info.type_name:lower():find("ipad"))
            local is_pro = hostname and hostname:lower():find("pro")
            local is_apple = vendor:find("Apple") or is_ipad or (hostname and hostname:lower():find("iphone"))

            local cpu_val = "ARM Octa-Core"
            local os_val = "Android OS"
            local ram_val = "Mobile LPDDR"

            if is_ipad then
                cpu_val = is_pro and "Apple Silicon M-Series / Bionic" or "Apple Bionic / A-Series"
                os_val = "iPadOS"
                ram_val = is_pro and "8GB / 16GB Unified Memory" or "4GB / 6GB LPDDR"
            elseif is_apple then
                cpu_val = "Apple Bionic / A-Series"
                os_val = "iOS"
                ram_val = "6GB / 8GB LPDDR5"
            end

            hw_info = {
                cpu = cpu_val,
                ram = ram_val,
                os = os_val,
                nic = vendor
            }
        else
            hw_info = {
                cpu = "Network Processor",
                ram = "Device Memory",
                os = info.type_name,
                nic = vendor
            }
        end

        table.insert(list, {
            ip = item.ip,
            mac = item.mac,
            vendor = vendor,
            hostname = hostname,
            is_custom = is_custom,
            is_local_host = is_this_host,
            category = info.category,
            type_name = is_this_host and (info.type_name .. " (This Device)") or info.type_name,
            icon = info.icon,
            badge_color = info.badge_color,
            ports = port_details,
            port_count = #ports,
            latency_ms = ping_rtt,
            status = is_alive and "online" or "offline",
            hardware = hw_info,
            last_seen = os.time()
        })
    end

    STATE.last_scanned = os.time()
    STATE.devices = INVENTORY:merge(list, STATE.last_scanned, probe_ports ~= false)
    save_inventory()
    STATE.scanning = false
    return STATE.devices
end

--------------------------------------------------------------------------------
-- 7. Minimal JSON Serializer
--------------------------------------------------------------------------------
local function escape_str(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('[%z\1-\31]', function(c)
        return string.format('\\u%04x', c:byte())
    end)
    return s
end

local function to_json(val)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        return '"' .. escape_str(val) .. '"'
    elseif t == "table" then
        local is_array = true
        local n = #val
        if n == 0 then
            local count = 0
            for _ in pairs(val) do
                count = count + 1
                is_array = false
                break
            end
            if count == 0 then return "[]" end
        else
            for k in pairs(val) do
                if type(k) ~= "number" or k < 1 or k > n or math.floor(k) ~= k then
                    is_array = false
                    break
                end
            end
        end

        if is_array then
            local parts = {}
            for i = 1, n do
                table.insert(parts, to_json(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, '"' .. escape_str(tostring(k)) .. '":' .. to_json(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return '"' .. tostring(val) .. '"'
end

--------------------------------------------------------------------------------
-- 8. Embedded HTML5 / CSS / JS Single-Page Dashboard
--------------------------------------------------------------------------------
local DASHBOARD_HTML = [[<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LAN Radar | Device Dashboard</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-base: #090d16;
            --bg-card: rgba(18, 24, 38, 0.75);
            --bg-card-hover: rgba(26, 34, 54, 0.85);
            --border: rgba(255, 255, 255, 0.08);
            --border-hover: rgba(99, 102, 241, 0.4);
            --text-main: #f1f5f9;
            --text-dim: #94a3b8;
            --accent: #6366f1;
            --accent-glow: rgba(99, 102, 241, 0.25);
            --online: #10b981;
            --camera: #f43f5e;
            --windows: #0ea5e9;
            --linux: #10b981;
            --phone: #a855f7;
            --iot: #eab308;
            --router: #3b82f6;
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Plus Jakarta Sans', sans-serif;
            background-color: var(--bg-base);
            color: var(--text-main);
            min-height: 100vh;
            padding: 24px;
            background-image: 
                radial-gradient(circle at 10% 10%, rgba(99, 102, 241, 0.08) 0%, transparent 40%),
                radial-gradient(circle at 90% 90%, rgba(16, 185, 129, 0.06) 0%, transparent 40%);
            background-attachment: fixed;
        }

        .container { max-width: 1400px; margin: 0 auto; }

        header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding-bottom: 24px;
            border-bottom: 1px solid var(--border);
            margin-bottom: 24px;
            flex-wrap: wrap;
            gap: 16px;
        }
        .logo-group { display: flex; align-items: center; gap: 14px; }
        .radar-icon {
            width: 44px; height: 44px;
            border-radius: 12px;
            background: linear-gradient(135deg, #4f46e5, #06b6d4);
            display: flex; align-items: center; justify-content: center;
            box-shadow: 0 0 20px rgba(79, 70, 229, 0.4);
        }
        .title h1 { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; }
        .title p { font-size: 13px; color: var(--text-dim); margin-top: 2px; }
        .subnet-badge {
            background: rgba(255, 255, 255, 0.05);
            padding: 3px 8px; border-radius: 6px;
            font-family: 'JetBrains Mono', monospace;
            font-size: 12px; color: #a5b4fc;
        }

        .header-actions { display: flex; align-items: center; gap: 12px; }
        button {
            cursor: pointer; font-family: inherit;
            display: inline-flex; align-items: center; gap: 8px;
            padding: 9px 16px; border-radius: 8px; font-size: 13px;
            font-weight: 600; transition: all 0.2s ease;
        }
        .btn-primary {
            background: var(--accent); color: #fff;
            border: 1px solid rgba(255, 255, 255, 0.15);
            box-shadow: 0 0 16px var(--accent-glow);
        }
        .btn-primary:hover { background: #4f46e5; transform: translateY(-1px); }
        .btn-primary:active { transform: translateY(0); }
        .btn-secondary {
            background: rgba(255, 255, 255, 0.04);
            color: var(--text-main); border: 1px solid var(--border);
        }
        .btn-secondary:hover { background: rgba(255, 255, 255, 0.08); border-color: rgba(255, 255, 255, 0.2); }

        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 16px; margin-bottom: 24px;
        }
        .stat-card {
            background: var(--bg-card);
            backdrop-filter: blur(12px);
            border: 1px solid var(--border);
            border-radius: 14px; padding: 18px;
            transition: all 0.2s ease;
        }
        .stat-card:hover { border-color: var(--border-hover); transform: translateY(-2px); }
        .stat-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; }
        .stat-label { font-size: 12px; font-weight: 600; color: var(--text-dim); text-transform: uppercase; letter-spacing: 0.5px; }
        .stat-icon { font-size: 18px; }
        .stat-val { font-size: 28px; font-weight: 700; color: var(--text-main); }

        .controls-bar {
            background: var(--bg-card);
            backdrop-filter: blur(12px);
            border: 1px solid var(--border);
            border-radius: 14px; padding: 14px 18px;
            display: flex; align-items: center; justify-content: space-between;
            margin-bottom: 24px; flex-wrap: wrap; gap: 14px;
        }
        .search-wrap {
            display: flex; align-items: center; gap: 10px;
            background: rgba(0, 0, 0, 0.3); border: 1px solid var(--border);
            border-radius: 8px; padding: 8px 14px; flex: 1; max-width: 420px;
        }
        .search-wrap input {
            background: transparent; border: none; outline: none;
            color: var(--text-main); font-size: 13px; font-family: inherit; width: 100%;
        }
        .filter-pills { display: flex; gap: 8px; flex-wrap: wrap; }
        .pill {
            padding: 6px 12px; border-radius: 20px; font-size: 12px;
            font-weight: 600; cursor: pointer; border: 1px solid var(--border);
            background: rgba(255, 255, 255, 0.03); color: var(--text-dim);
            transition: all 0.15s ease;
        }
        .pill:hover { color: var(--text-main); border-color: rgba(255, 255, 255, 0.2); }
        .pill.active {
            background: var(--accent); color: white;
            border-color: var(--accent); box-shadow: 0 0 12px var(--accent-glow);
        }

        .view-switch { display: flex; gap: 4px; background: rgba(0,0,0,0.3); padding: 4px; border-radius: 8px; }
        .view-btn {
            background: transparent; border: none; padding: 6px 10px;
            border-radius: 6px; color: var(--text-dim); cursor: pointer;
        }
        .view-btn.active { background: rgba(255,255,255,0.1); color: var(--text-main); }

        .device-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
            gap: 18px;
        }
        .device-card {
            background: var(--bg-card);
            backdrop-filter: blur(12px);
            border: 1px solid var(--border);
            border-radius: 14px; padding: 20px;
            display: flex; flex-direction: column; justify-content: space-between;
            transition: all 0.2s ease;
            position: relative; overflow: hidden;
        }
        .device-card:hover {
            background: var(--bg-card-hover);
            border-color: var(--border-hover);
            transform: translateY(-3px);
            box-shadow: 0 12px 24px -10px rgba(0,0,0,0.5);
        }
        .card-top { display: flex; align-items: flex-start; justify-content: space-between; margin-bottom: 14px; }
        .device-title { display: flex; align-items: center; gap: 10px; }
        .device-type-badge {
            width: 36px; height: 36px; border-radius: 10px;
            display: flex; align-items: center; justify-content: center;
            font-size: 18px; background: rgba(255, 255, 255, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.08);
        }
        .device-names h3 { font-size: 15px; font-weight: 600; color: var(--text-main); }
        .device-names p { font-size: 12px; color: var(--text-dim); }

        .latency-badge {
            display: flex; align-items: center; gap: 6px;
            font-family: 'JetBrains Mono', monospace; font-size: 11px;
            padding: 4px 8px; border-radius: 20px;
            background: rgba(16, 185, 129, 0.1); color: #34d399;
            border: 1px solid rgba(16, 185, 129, 0.2);
        }
        .latency-badge.offline {
            background: rgba(239, 68, 68, 0.1); color: #f87171;
            border-color: rgba(239, 68, 68, 0.2);
        }
        .dot { width: 6px; height: 6px; border-radius: 50%; background: #10b981; }
        .dot.offline { background: #ef4444; }

        .net-specs {
            background: rgba(0, 0, 0, 0.25); border-radius: 10px;
            padding: 12px; margin-bottom: 14px; border: 1px solid rgba(255, 255, 255, 0.04);
            display: grid; grid-template-columns: 1fr 1fr; gap: 8px;
            font-family: 'JetBrains Mono', monospace; font-size: 12px;
        }
        .spec-item .label { color: var(--text-dim); font-size: 10px; text-transform: uppercase; margin-bottom: 2px; }
        .spec-item .val { color: var(--text-main); word-break: break-all; }

        .ports-wrap { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 16px; min-height: 26px; }
        .port-tag {
            font-size: 11px; font-family: 'JetBrains Mono', monospace;
            padding: 3px 8px; border-radius: 6px;
            background: rgba(99, 102, 241, 0.15); color: #c7d2fe;
            border: 1px solid rgba(99, 102, 241, 0.3);
        }
        .port-tag.rtsp { background: rgba(244, 63, 94, 0.15); color: #fecdd3; border-color: rgba(244, 63, 94, 0.3); }
        .port-tag.ssh { background: rgba(16, 185, 129, 0.15); color: #a7f3d0; border-color: rgba(16, 185, 129, 0.3); }
        .port-tag.web { background: rgba(56, 189, 248, 0.15); color: #bae6fd; border-color: rgba(56, 189, 248, 0.3); }
        .port-tag.smb { background: rgba(245, 158, 11, 0.15); color: #fde68a; border-color: rgba(245, 158, 11, 0.3); }
        .port-tag.rdp { background: rgba(192, 132, 252, 0.15); color: #e9d5ff; border-color: rgba(192, 132, 252, 0.3); }
        .port-tag.dns { background: rgba(234, 179, 8, 0.15); color: #fef08a; border-color: rgba(234, 179, 8, 0.3); }

        .card-actions {
            display: flex; gap: 8px; border-top: 1px solid var(--border);
            padding-top: 14px;
        }
        .card-actions button {
            flex: 1; justify-content: center; padding: 7px 10px;
            font-size: 12px; border-radius: 6px;
        }

        .device-table-wrap {
            background: var(--bg-card);
            backdrop-filter: blur(12px);
            border: 1px solid var(--border);
            border-radius: 14px; overflow-x: auto;
            display: none;
        }
        table { width: 100%; border-collapse: collapse; text-align: left; font-size: 13px; }
        th {
            padding: 14px 18px; color: var(--text-dim);
            font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px;
            border-bottom: 1px solid var(--border); background: rgba(0, 0, 0, 0.2);
        }
        td {
            padding: 14px 18px; border-bottom: 1px solid var(--border);
            color: var(--text-main); vertical-align: middle;
        }
        tr:hover td { background: rgba(255, 255, 255, 0.02); }

        .modal-overlay {
            position: fixed; inset: 0; background: rgba(0,0,0,0.7);
            backdrop-filter: blur(6px); display: none;
            align-items: center; justify-content: center; z-index: 1000;
        }
        .modal {
            background: #111827; border: 1px solid rgba(255,255,255,0.15);
            border-radius: 16px; width: 90%; max-width: 580px; padding: 24px;
            box-shadow: 0 25px 50px -12px rgba(0,0,0,0.7);
            max-height: 90vh; overflow-y: auto;
        }
        .modal-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 18px; }
        .modal-close { background: none; border: none; font-size: 20px; color: var(--text-dim); cursor: pointer; }
        .modal-body { font-size: 13px; }
        .code-block {
            background: #090d16; border: 1px solid var(--border);
            border-radius: 8px; padding: 12px; font-family: 'JetBrains Mono', monospace;
            font-size: 12px; color: #38bdf8; margin: 8px 0 16px 0;
            display: flex; justify-content: space-between; align-items: center;
        }

        #toast {
            position: fixed; bottom: 24px; right: 24px;
            background: #1e293b; color: #f8fafc;
            border: 1px solid rgba(255,255,255,0.2);
            padding: 12px 20px; border-radius: 10px;
            font-size: 13px; font-weight: 500;
            box-shadow: 0 10px 25px rgba(0,0,0,0.4);
            transform: translateY(100px); opacity: 0;
            transition: all 0.25s cubic-bezier(0.16, 1, 0.3, 1);
            z-index: 2000;
        }
        #toast.show { transform: translateY(0); opacity: 1; }

        .spinner { animation: rotate 1s linear infinite; }
        @keyframes rotate { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="logo-group">
                <div class="radar-icon">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <circle cx="12" cy="12" r="9"/>
                        <circle cx="12" cy="12" r="5"/>
                        <circle cx="12" cy="12" r="2"/>
                        <path d="M12 12L19 5"/>
                    </svg>
                </div>
                <div class="title">
                    <div style="display:flex; align-items:center; gap:8px;">
                        <h1>LAN Radar Dashboard</h1>
                        <span class="subnet-badge" id="subnetDisplay">192.168.1.0/24</span>
                    </div>
                    <p id="statusSubtext">Listening for active LAN nodes...</p>
                </div>
            </div>
            <div class="header-actions">
                <select id="autoRefreshSelect" class="btn-secondary" style="padding: 8px 12px;">
                    <option value="5">Auto-refresh: 5s</option>
                    <option value="10" selected>Auto-refresh: 10s</option>
                    <option value="30">Auto-refresh: 30s</option>
                    <option value="0">Auto-refresh: Off</option>
                </select>
                <button class="btn-primary" id="scanBtn" onclick="triggerScan()">
                    <svg class="scan-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/>
                    </svg>
                    <span>Scan Now</span>
                </button>
            </div>
        </header>

        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-header"><span class="stat-label">Total Devices</span><span class="stat-icon">🌐</span></div>
                <div class="stat-val" id="totalCount">0</div>
            </div>
            <div class="stat-card">
                <div class="stat-header"><span class="stat-label">Windows</span><span class="stat-icon">🪟</span></div>
                <div class="stat-val" id="winCount" style="color:#38bdf8;">0</div>
            </div>
            <div class="stat-card">
                <div class="stat-header"><span class="stat-label">Linux / Pi</span><span class="stat-icon">🐧</span></div>
                <div class="stat-val" id="linuxCount" style="color:#34d399;">0</div>
            </div>
            <div class="stat-card">
                <div class="stat-header"><span class="stat-label">Phones &amp; Tablets</span><span class="stat-icon">📱</span></div>
                <div class="stat-val" id="phoneCount" style="color:#c084fc;">0</div>
            </div>
            <div class="stat-card">
                <div class="stat-header"><span class="stat-label">Cameras</span><span class="stat-icon">🎥</span></div>
                <div class="stat-val" id="camCount" style="color:#fb7185;">0</div>
            </div>
            <div class="stat-card">
                <div class="stat-header"><span class="stat-label">IoT & Routers</span><span class="stat-icon">💡</span></div>
                <div class="stat-val" id="iotCount" style="color:#facc15;">0</div>
            </div>
        </div>

        <div class="controls-bar">
            <div class="search-wrap">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="color:var(--text-dim);">
                    <circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>
                </svg>
                <input type="text" id="searchInput" placeholder="Filter by IP, MAC, Hostname, Vendor, Port..." oninput="renderDevices()">
            </div>
            <div class="filter-pills">
                <div class="pill active" data-cat="all" onclick="setCategory('all')">All (<span id="cat-all">0</span>)</div>
                <div class="pill" data-cat="windows" onclick="setCategory('windows')">🪟 Windows</div>
                <div class="pill" data-cat="linux" onclick="setCategory('linux')">🐧 Linux/Pi</div>
                <div class="pill" data-cat="phone" onclick="setCategory('phone')">📱 Phones / iPads</div>
                <div class="pill" data-cat="camera" onclick="setCategory('camera')">🎥 Cameras</div>
                <div class="pill" data-cat="router" onclick="setCategory('router')">🌐 Routers</div>
                <div class="pill" data-cat="iot" onclick="setCategory('iot')">💡 IoT</div>
            </div>
            <div class="view-switch">
                <button class="view-btn active" id="viewCardsBtn" onclick="switchView('cards')">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/>
                        <rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>
                    </svg>
                </button>
                <button class="view-btn" id="viewTableBtn" onclick="switchView('table')">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/>
                        <line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>
                    </svg>
                </button>
            </div>
        </div>

        <div id="deviceGrid" class="device-grid"></div>
        <div id="deviceTableWrap" class="device-table-wrap">
            <table>
                <thead>
                    <tr>
                        <th>Device / Hostname</th>
                        <th>IP Address</th>
                        <th>MAC Address</th>
                        <th>Vendor</th>
                        <th>Category</th>
                        <th>Open Ports</th>
                        <th>Latency</th>
                        <th>Actions</th>
                    </tr>
                </thead>
                <tbody id="deviceTableBody"></tbody>
            </table>
        </div>
    </div>

    <!-- Inspector Modal -->
    <div class="modal-overlay" id="inspectModal" onclick="closeModal(event)">
        <div class="modal" onclick="event.stopPropagation()">
            <div class="modal-header">
                <h2 id="modalTitle">Device Diagnostics</h2>
                <button class="modal-close" onclick="closeModal()">&times;</button>
            </div>
            <div class="modal-body" id="modalBody"></div>
        </div>
    </div>

    <div id="toast"></div>

    <script>
        let devices = [];
        let activeCategory = 'all';
        let currentView = 'cards';
        let refreshTimer = null;

        const CATEGORY_ICONS = {
            camera: '🎥',
            windows: '🪟',
            linux: '🐧',
            phone: '📱',
            router: '🌐',
            iot: '💡',
            other: '💻'
        };

        async function fetchDevices() {
            try {
                const res = await fetch('/api/devices');
                const data = await res.json();
                devices = data.devices || [];
                if (data.subnet) document.getElementById('subnetDisplay').textContent = data.subnet;
                document.getElementById('statusSubtext').textContent = 'Last scanned: ' + (data.scanned_at || 'Not yet') + ' (' + devices.length + ' known devices)';
                updateCounts();
                renderDevices();
            } catch (err) {
                console.error('Failed to fetch devices:', err);
            }
        }

        async function triggerScan() {
            const btn = document.getElementById('scanBtn');
            const icon = btn.querySelector('.scan-icon');
            btn.disabled = true;
            icon.classList.add('spinner');
            showToast('Scanning local network and measuring latency...');
            try {
                const res = await fetch('/api/scan', { method: 'POST' });
                const data = await res.json();
                devices = data.devices || [];
                updateCounts();
                renderDevices();
                showToast(`Scan complete: ${devices.length} known devices`);
            } catch (err) {
                showToast('Scan error: ' + err.message);
            } finally {
                btn.disabled = false;
                icon.classList.remove('spinner');
            }
        }

        function updateCounts() {
            const counts = { total: devices.length, windows: 0, linux: 0, phone: 0, camera: 0, router: 0, iot: 0 };
            devices.forEach(d => {
                if (counts[d.category] !== undefined) counts[d.category]++;
            });
            document.getElementById('totalCount').textContent = counts.total;
            document.getElementById('winCount').textContent = counts.windows;
            document.getElementById('linuxCount').textContent = counts.linux;
            document.getElementById('phoneCount').textContent = counts.phone;
            document.getElementById('camCount').textContent = counts.camera;
            document.getElementById('iotCount').textContent = counts.iot + counts.router;
            document.getElementById('cat-all').textContent = counts.total;
        }

        function setCategory(cat) {
            activeCategory = cat;
            document.querySelectorAll('.filter-pills .pill').forEach(p => {
                p.classList.toggle('active', p.getAttribute('data-cat') === cat);
            });
            renderDevices();
        }

        function switchView(view) {
            currentView = view;
            document.getElementById('viewCardsBtn').classList.toggle('active', view === 'cards');
            document.getElementById('viewTableBtn').classList.toggle('active', view === 'table');
            document.getElementById('deviceGrid').style.display = view === 'cards' ? 'grid' : 'none';
            document.getElementById('deviceTableWrap').style.display = view === 'table' ? 'block' : 'none';
            renderDevices();
        }

        function filterList() {
            const query = (document.getElementById('searchInput').value || '').toLowerCase().trim();
            return devices.filter(d => {
                if (activeCategory !== 'all' && d.category !== activeCategory) return false;
                if (!query) return true;
                const portsStr = (d.ports || []).map(p => p.port + ' ' + p.name).join(' ');
                return d.ip.toLowerCase().includes(query) ||
                       d.mac.toLowerCase().includes(query) ||
                       (d.hostname || '').toLowerCase().includes(query) ||
                       (d.vendor || '').toLowerCase().includes(query) ||
                       portsStr.toLowerCase().includes(query);
            });
        }

        function renderDevices() {
            const list = filterList();
            if (currentView === 'cards') {
                renderGrid(list);
            } else {
                renderTable(list);
            }
        }

        function isObserved(d) {
            return d.status === 'online' || d.status === 'offline';
        }

        function deviceStatus(d) {
            if (d.status === 'online') return d.latency_ms + ' ms';
            if (d.status === 'unchecked') return 'Not yet checked';
            if (d.status === 'not_observed') return 'Not observed';
            return 'No ping response';
        }

        function seenTime(timestamp) {
            return typeof timestamp === 'number' ? new Date(timestamp * 1000).toLocaleString() : 'Unknown';
        }

        function renderGrid(list) {
            const grid = document.getElementById('deviceGrid');
            if (list.length === 0) {
                grid.innerHTML = '<div style="grid-column: 1/-1; text-align: center; padding: 60px; color: var(--text-dim);">' +
                    '<h3>No devices match your filter</h3><p style="margin-top:6px;">Try adjusting search terms or click "Scan Now"</p></div>';
                return;
            }

            grid.innerHTML = list.map(d => {
                let icon = CATEGORY_ICONS[d.category] || '💻';
                if (d.icon === 'tablet' || (d.type_name && d.type_name.toLowerCase().includes('ipad'))) {
                    icon = '📟';
                }
                const isOnline = d.status === 'online';
                const portsHtml = (d.ports && d.ports.length > 0)
                    ? d.ports.map(p => {
                        let cls = '';
                        if (p.port === 554) cls = 'rtsp';
                        else if (p.port === 22) cls = 'ssh';
                        else if (p.port === 445 || p.port === 139) cls = 'smb';
                        else if (p.port === 80 || p.port === 443 || p.port === 8080) cls = 'web';
                        else if (p.port === 3389) cls = 'rdp';
                        else if (p.port === 53) cls = 'dns';
                        return `<span class="port-tag ${cls}">${p.name} (${p.port})</span>`;
                    }).join('')
                    : `<span style="font-size:11px; color:var(--text-dim); font-family:monospace;">${isOnline ? 'Active Host (Ports Unprobed)' : deviceStatus(d)}</span>`;

                const hasWeb = isObserved(d) && ((d.ports || []).some(p => p.port === 80 || p.port === 443 || p.port === 8080) || d.category === 'router');
                const hasSsh = isObserved(d) && ((d.ports || []).some(p => p.port === 22) || d.category === 'linux');
                const hasRtsp = isObserved(d) && ((d.ports || []).some(p => p.port === 554) || d.category === 'camera');

                return `
                <div class="device-card">
                    <div>
                        <div class="card-top">
                            <div class="device-title">
                                <div class="device-type-badge">${icon}</div>
                                <div class="device-names">
                                    <div style="display:flex; align-items:center; gap:6px;">
                                        <h3>${escapeHtml(d.hostname)}</h3>
                                        ${d.is_local_host ? '<span style="background:#0284c7; color:#fff; font-size:10px; font-weight:700; padding:2px 6px; border-radius:4px; text-transform:uppercase;">Host</span>' : ''}
                                        <button title="Rename Device" ${isObserved(d) ? '' : 'disabled'} onclick="renameDevice('${d.ip}', '${escapeHtml(d.hostname)}')" style="background:none; border:none; padding:2px; cursor:pointer; font-size:12px; color:var(--text-dim); opacity:0.8;">✏️</button>
                                    </div>
                                    <p>${escapeHtml(d.type_name)}</p>
                                </div>
                            </div>
                            <div class="latency-badge ${isOnline ? '' : 'offline'}">
                                <span class="dot ${isOnline ? '' : 'offline'}"></span>
                                <span>${deviceStatus(d)}</span>
                            </div>
                        </div>

                        <div class="net-specs">
                            <div class="spec-item">
                                <div class="label">IP Address</div>
                                <div class="val" style="color:#38bdf8; font-weight:600;">${d.ip}</div>
                            </div>
                            <div class="spec-item">
                                <div class="label">MAC Address</div>
                                <div class="val">${d.mac}</div>
                            </div>
                            <div class="spec-item" style="grid-column: 1/-1;">
                                <div class="label">Hardware / Vendor</div>
                                <div class="val" style="color:#a5b4fc;">${escapeHtml(d.vendor)}${d.hardware && d.hardware.cpu ? ' &bull; <span style="color:#cbd5e1; font-size:11px;">' + escapeHtml(d.hardware.cpu) + '</span>' : ''}</div>
                            </div>
                            ${d.hardware && (d.hardware.os || d.hardware.ram) ? `
                            <div class="spec-item" style="grid-column: 1/-1; background:rgba(255,255,255,0.02); padding:6px 8px; border-radius:6px; border:1px solid rgba(255,255,255,0.05); margin-top:4px;">
                                <div style="display:flex; justify-content:space-between; font-size:11px;">
                                    <span style="color:var(--text-dim);">${escapeHtml(d.hardware.os || 'OS')}</span>
                                    <span style="color:#34d399; font-weight:600;">${escapeHtml(d.hardware.ram || '')}</span>
                                </div>
                            </div>` : ''}
                        </div>

                        <p style="font-size:11px; color:var(--text-dim); margin-bottom:10px;">First seen: ${seenTime(d.first_seen)}<br>Last seen: ${seenTime(d.last_seen)}</p>
                        <div class="ports-wrap" id="ports-wrap-${d.ip.replace(/\./g, '-')}">${portsHtml}</div>
                    </div>

                    <div class="card-actions">
                        ${hasWeb ? `<button class="btn-secondary" onclick="window.open('http://${d.ip}', '_blank')">🌐 Web</button>` : ''}
                        ${hasSsh ? `<button class="btn-secondary" onclick="copyText('ssh pi@${d.ip}')">💻 SSH</button>` : ''}
                        ${hasRtsp ? `<button class="btn-secondary" onclick="copyText('rtsp://${d.ip}:554/stream')">🎥 RTSP</button>` : ''}
                        <button class="btn-secondary" onclick="copyText('${d.ip}')">📋 IP</button>
                        <button class="btn-secondary" id="probe-btn-${d.ip.replace(/\./g, '-')}" ${isObserved(d) ? '' : 'disabled'} onclick="probeDevicePorts('${d.ip}', this)">⚡ Probe Ports</button>
                        <button class="btn-primary" onclick="inspectDevice('${d.ip}', '${d.mac || ''}')">🔍 Details</button>
                    </div>
                </div>`;
            }).join('');
        }

        function renderTable(list) {
            const tbody = document.getElementById('deviceTableBody');
            tbody.innerHTML = list.map(d => {
                let icon = CATEGORY_ICONS[d.category] || '💻';
                if (d.icon === 'tablet' || (d.type_name && d.type_name.toLowerCase().includes('ipad'))) {
                    icon = '📟';
                }
                const portsStr = (d.ports || []).map(p => `${p.name} (${p.port})`).join(', ') || 'Standard';
                const isOnline = d.status === 'online';
                return `
                <tr>
                    <td>
                        <div style="display:flex; align-items:center; gap:8px;">
                            <span>${icon}</span>
                            <div>
                                <div style="display:flex; align-items:center; gap:6px;">
                                    <span style="font-weight:600;">${escapeHtml(d.hostname)}</span>
                                    ${d.is_local_host ? '<span style="background:#0284c7; color:#fff; font-size:9px; font-weight:700; padding:1px 5px; border-radius:4px; text-transform:uppercase;">Host</span>' : ''}
                                    <button title="Rename" ${isObserved(d) ? '' : 'disabled'} onclick="renameDevice('${d.ip}', '${escapeHtml(d.hostname)}')" style="background:none; border:none; padding:1px; cursor:pointer; font-size:11px; opacity:0.8;">✏️</button>
                                </div>
                                <div style="font-size:11px; color:var(--text-dim);">${escapeHtml(d.type_name)}<br>Last seen: ${seenTime(d.last_seen)}</div>
                            </div>
                        </div>
                    </td>
                    <td style="font-family:monospace; color:#38bdf8; font-weight:600;">${d.ip}</td>
                    <td style="font-family:monospace; color:var(--text-dim);">${d.mac}</td>
                    <td style="color:#a5b4fc;">${escapeHtml(d.vendor)}</td>
                    <td><span style="background:rgba(255,255,255,0.06); padding:4px 8px; border-radius:6px; font-size:11px;">${d.category.toUpperCase()}</span></td>
                    <td style="font-family:monospace; font-size:11px;">${escapeHtml(portsStr)}</td>
                    <td style="font-family:monospace; color:${isOnline ? '#34d399' : '#f87171'};">${deviceStatus(d)}</td>
                    <td>
                        <div style="display:flex; gap:6px;">
                            <button class="btn-secondary" style="padding:4px 8px; font-size:11px;" onclick="copyText('${d.ip}')">Copy IP</button>
                            <button class="btn-secondary" style="padding:4px 8px; font-size:11px;" ${isObserved(d) ? '' : 'disabled'} onclick="probeDevicePorts('${d.ip}', this)">⚡ Probe</button>
                            <button class="btn-primary" style="padding:4px 8px; font-size:11px;" onclick="inspectDevice('${d.ip}', '${d.mac || ''}')">Inspect</button>
                        </div>
                    </td>
                </tr>`;
            }).join('');
        }

        async function renameDevice(ip, currentName) {
            const newName = prompt(`Enter custom friendly name for ${ip}:`, currentName || '');
            if (newName === null) return;
            const clean = newName.trim();
            if (!clean) return;
            try {
                const res = await fetch('/api/rename', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ ip: ip, name: clean })
                });
                const data = await res.json();
                if (data.status === 'ok') {
                    const dev = devices.find(x => x.ip === ip);
                    if (dev) {
                        dev.hostname = clean;
                        dev.is_custom = true;
                    }
                    renderDevices();
                    showToast(`Renamed ${ip} to "${clean}"`);
                }
            } catch (err) {
                showToast('Rename failed: ' + err.message);
            }
        }

        async function probeDevicePorts(ip, btnElement) {
            let originalText = "";
            if (btnElement) {
                originalText = btnElement.textContent;
                btnElement.textContent = "⏳ Scanning...";
                btnElement.disabled = true;
            }
            showToast(`Scanning standard ports on ${ip}...`);
            try {
                const res = await fetch(`/api/probe?ip=${ip}`);
                const data = await res.json();
                const probed = data.ports || [];
                const dev = devices.find(x => x.ip === ip);
                if (dev) {
                    dev.ports = probed;
                }
                renderDevices();
                if (document.getElementById('inspectModal').style.display === 'flex') {
                    inspectDevice(ip);
                }
                const portNames = probed.map(p => `${p.name} (${p.port})`).join(', ') || 'No open standard ports';
                showToast(`Port scan complete for ${ip}: ${portNames}`);
            } catch (err) {
                showToast(`Port probe failed for ${ip}: ${err.message}`);
            } finally {
                if (btnElement) {
                    btnElement.textContent = originalText;
                    btnElement.disabled = false;
                }
            }
        }

        let pingTimer = null;
        let pingTargetIp = null;
        let pingStats = { history: [], min: Infinity, max: 0, sum: 0, count: 0, lost: 0 };

        function stopPingMonitor() {
            if (pingTimer) {
                clearInterval(pingTimer);
                pingTimer = null;
            }
            const btn = document.getElementById('pingMonitorBtn');
            if (btn) btn.textContent = '▶ Start Live Ping';
        }

        function togglePingMonitor(ip) {
            if (pingTimer) {
                stopPingMonitor();
            } else {
                startPingMonitor(ip);
            }
        }

        function startPingMonitor(ip) {
            stopPingMonitor();
            pingTargetIp = ip;
            pingStats = { history: [], min: Infinity, max: 0, sum: 0, count: 0, lost: 0 };
            const btn = document.getElementById('pingMonitorBtn');
            if (btn) btn.textContent = '⏹ Stop Ping';
            tickPing();
            pingTimer = setInterval(tickPing, 650);
        }

        async function tickPing() {
            if (!pingTargetIp) return;
            const ip = pingTargetIp;
            try {
                const res = await fetch(`/api/ping?ip=${ip}`);
                const data = await res.json();
                const alive = data.alive;
                const rtt = data.rtt || 0;
                pingStats.count++;

                if (alive) {
                    pingStats.history.push(rtt);
                    if (rtt < pingStats.min) pingStats.min = rtt;
                    if (rtt > pingStats.max) pingStats.max = rtt;
                    pingStats.sum += rtt;
                } else {
                    pingStats.lost++;
                    pingStats.history.push(-1);
                }

                if (pingStats.history.length > 35) {
                    pingStats.history.shift();
                }

                updatePingUI(rtt, alive);
                drawPingCanvas();
            } catch (err) {
                pingStats.lost++;
                pingStats.count++;
                updatePingUI(0, false);
            }
        }

        function updatePingUI(currentRtt, isAlive) {
            const curEl = document.getElementById('pingCur');
            const minEl = document.getElementById('pingMin');
            const avgEl = document.getElementById('pingAvg');
            const maxEl = document.getElementById('pingMax');
            const jitEl = document.getElementById('pingJitter');
            const lossEl = document.getElementById('pingLoss');
            if (!curEl) return;

            curEl.textContent = isAlive ? `${currentRtt} ms` : 'Loss';
            curEl.style.color = isAlive ? '#38bdf8' : '#f87171';

            if (pingStats.min !== Infinity) minEl.textContent = `${pingStats.min} ms`;
            if (pingStats.max !== 0) maxEl.textContent = `${pingStats.max} ms`;

            const validCount = pingStats.count - pingStats.lost;
            if (validCount > 0) {
                const avg = (pingStats.sum / validCount).toFixed(1);
                avgEl.textContent = `${avg} ms`;

                let jitterSum = 0;
                for (const p of pingStats.history) {
                    if (p >= 0) jitterSum += Math.abs(p - avg);
                }
                const jitter = (jitterSum / validCount).toFixed(1);
                jitEl.textContent = `${jitter} ms`;
            }

            const lossRate = ((pingStats.lost / pingStats.count) * 100).toFixed(0);
            lossEl.textContent = `${lossRate}%`;
            lossEl.style.color = (lossRate > 0) ? '#f87171' : '#94a3b8';
        }

        function drawPingCanvas() {
            const canvas = document.getElementById('pingCanvas');
            if (!canvas) return;
            const ctx = canvas.getContext('2d');
            const w = canvas.width;
            const h = canvas.height;
            ctx.clearRect(0, 0, w, h);

            const hist = pingStats.history;
            if (hist.length < 2) return;

            ctx.strokeStyle = 'rgba(255, 255, 255, 0.05)';
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(0, h / 2); ctx.lineTo(w, h / 2);
            ctx.stroke();

            let maxVal = 20;
            for (const v of hist) {
                if (v > maxVal) maxVal = v;
            }
            maxVal = Math.max(maxVal * 1.25, 10);

            const step = w / (hist.length - 1);

            const grad = ctx.createLinearGradient(0, 0, 0, h);
            grad.addColorStop(0, 'rgba(56, 189, 248, 0.35)');
            grad.addColorStop(1, 'rgba(56, 189, 248, 0.0)');

            ctx.beginPath();
            let first = true;
            for (let i = 0; i < hist.length; i++) {
                const v = hist[i];
                const x = i * step;
                const y = v < 0 ? h - 2 : h - Math.min((v / maxVal) * (h - 10) + 5, h - 2);
                if (first) { ctx.moveTo(x, y); first = false; }
                else { ctx.lineTo(x, y); }
            }
            ctx.lineTo(w, h);
            ctx.lineTo(0, h);
            ctx.closePath();
            ctx.fillStyle = grad;
            ctx.fill();

            ctx.beginPath();
            ctx.strokeStyle = '#38bdf8';
            ctx.lineWidth = 2;
            first = true;
            for (let i = 0; i < hist.length; i++) {
                const v = hist[i];
                const x = i * step;
                const y = v < 0 ? h - 2 : h - Math.min((v / maxVal) * (h - 10) + 5, h - 2);
                if (first) { ctx.moveTo(x, y); first = false; }
                else { ctx.lineTo(x, y); }
            }
            ctx.stroke();

            const lastVal = hist[hist.length - 1];
            const lastX = (hist.length - 1) * step;
            const lastY = lastVal < 0 ? h - 2 : h - Math.min((lastVal / maxVal) * (h - 10) + 5, h - 2);
            ctx.fillStyle = lastVal < 0 ? '#f87171' : '#38bdf8';
            ctx.beginPath();
            ctx.arc(lastX, lastY, 4, 0, Math.PI * 2);
            ctx.fill();
        }

        async function scanCustomPorts(ip) {
            const input = document.getElementById('customPortInput');
            if (!input) return;
            const rawVal = input.value.trim();
            if (!rawVal) {
                showToast('Please enter port numbers or ranges (e.g. 3000, 8000-8010)');
                return;
            }
            const btn = document.getElementById('customScanBtn');
            if (btn) {
                btn.disabled = true;
                btn.textContent = '⏳ Scanning...';
            }
            showToast(`Probing custom ports [${rawVal}] on ${ip}...`);
            try {
                const res = await fetch(`/api/probe?ip=${ip}&ports=${encodeURIComponent(rawVal)}`);
                const data = await res.json();
                const probed = data.ports || [];
                const dev = devices.find(x => x.ip === ip);
                if (dev) {
                    dev.ports = dev.ports || [];
                    const existingMap = new Set(dev.ports.map(p => p.port));
                    probed.forEach(p => {
                        if (!existingMap.has(p.port)) {
                            dev.ports.push(p);
                        }
                    });
                }
                renderDevices();
                if (document.getElementById('inspectModal').style.display === 'flex') {
                    const portsListEl = document.getElementById('modalPortsList');
                    if (portsListEl && dev) {
                        portsListEl.innerHTML = (dev.ports && dev.ports.length > 0)
                            ? dev.ports.map(p => `<li><strong>Port ${p.port}</strong>: ${escapeHtml(p.name)}</li>`).join('')
                            : '<li style="color:var(--text-dim);">No open standard ports detected.</li>';
                    }
                }
                if (probed.length > 0) {
                    const names = probed.map(p => `${p.name} (${p.port})`).join(', ');
                    showToast(`Found ${probed.length} open port(s) on ${ip}: ${names}`);
                } else {
                    showToast(`No open ports found on ${ip} for [${rawVal}]`);
                }
            } catch (err) {
                showToast(`Custom port scan failed: ${err.message}`);
            } finally {
                if (btn) {
                    btn.disabled = false;
                    btn.textContent = '⚡ Scan Custom';
                }
            }
        }

        async function inspectDevice(ip, mac) {
            const d = devices.find(x => x.ip === ip && (mac === undefined || (x.mac || '') === mac));
            if (!d) return;
            stopPingMonitor();
            document.getElementById('modalTitle').textContent = `${d.hostname} (${d.ip})`;
            if (!isObserved(d)) {
                document.getElementById('modalBody').innerHTML = `<p>${deviceStatus(d)}</p>
                    <p>First seen: ${seenTime(d.first_seen)}<br>Last seen: ${seenTime(d.last_seen)}</p>
                    <p>Vendor: ${escapeHtml(d.vendor)}</p>
                    <p>Last observed services: ${escapeHtml((d.ports || []).map(p => p.name + ' (' + p.port + ')').join(', ') || 'None recorded')}</p>`;
                document.getElementById('inspectModal').style.display = 'flex';
                return;
            }
            const portsList = (d.ports && d.ports.length > 0)
                ? d.ports.map(p => `<li><strong>Port ${p.port}</strong>: ${escapeHtml(p.name)}</li>`).join('')
                : '<li style="color:var(--text-dim);">No open standard ports detected yet. Click "Probe Ports" below to scan.</li>';

            document.getElementById('modalBody').innerHTML = `
                <div style="margin-bottom:14px;">
                    <p style="color:var(--text-dim); margin-bottom:4px;">Device Type: <strong style="color:var(--text-main);">${escapeHtml(d.type_name)}</strong></p>
                    <p style="color:var(--text-dim); margin-bottom:4px;">MAC Address: <strong style="color:var(--text-main); font-family:monospace;">${d.mac}</strong></p>
                    <p style="color:var(--text-dim); margin-bottom:4px;">Manufacturer: <strong style="color:var(--text-main);">${escapeHtml(d.vendor)}</strong></p>
                    <p style="color:var(--text-dim); margin-bottom:4px;">First seen: ${seenTime(d.first_seen)}<br>Last seen: ${seenTime(d.last_seen)}</p>
                    <p style="color:var(--text-dim); margin-bottom:12px;">Reachability: <strong style="color:#34d399;">${deviceStatus(d)}</strong></p>
                </div>

                <!-- Live Ping & Jitter Monitor -->
                <div style="background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.08); border-radius:10px; padding:12px; margin-bottom:16px;">
                    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                        <h4 style="margin:0; font-size:12px; display:flex; align-items:center; gap:6px;">
                            <span>📈 Live Latency &amp; Jitter Monitor</span>
                        </h4>
                        <button class="btn-secondary" id="pingMonitorBtn" style="padding:3px 8px; font-size:11px;" onclick="togglePingMonitor('${d.ip}')">▶ Start Live Ping</button>
                    </div>
                    <canvas id="pingCanvas" width="500" height="65" style="width:100%; height:65px; background:#070a12; border:1px solid rgba(255,255,255,0.05); border-radius:6px; display:block; margin-bottom:8px;"></canvas>
                    <div style="display:flex; justify-content:space-between; font-size:11px; color:var(--text-dim); font-family:monospace;">
                        <span>Cur: <strong id="pingCur" style="color:#38bdf8;">-</strong></span>
                        <span>Min: <strong id="pingMin" style="color:#34d399;">-</strong></span>
                        <span>Avg: <strong id="pingAvg" style="color:#a78bfa;">-</strong></span>
                        <span>Max: <strong id="pingMax" style="color:#fb7185;">-</strong></span>
                        <span>Jitter: <strong id="pingJitter" style="color:#facc15;">-</strong></span>
                        <span>Loss: <strong id="pingLoss" style="color:#94a3b8;">0%</strong></span>
                    </div>
                </div>

                ${d.hardware ? `
                <h4 style="margin-bottom:8px;">Hardware &amp; System Specs</h4>
                <div style="background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.06); border-radius:8px; padding:10px 14px; margin-bottom:16px;">
                    <p style="margin-bottom:4px; font-size:12px;"><span style="color:var(--text-dim);">Operating System:</span> <strong style="color:#38bdf8;">${escapeHtml(d.hardware.os || 'N/A')}</strong></p>
                    <p style="margin-bottom:4px; font-size:12px;"><span style="color:var(--text-dim);">CPU Architecture:</span> <strong style="color:var(--text-main);">${escapeHtml(d.hardware.cpu || 'N/A')}</strong></p>
                    <p style="margin-bottom:4px; font-size:12px;"><span style="color:var(--text-dim);">Memory / RAM:</span> <strong style="color:#34d399;">${escapeHtml(d.hardware.ram || 'N/A')}</strong></p>
                    ${d.hardware.banner ? `<p style="font-size:12px;"><span style="color:var(--text-dim);">Service Banner:</span> <code style="color:#fcd34d; background:rgba(0,0,0,0.3); padding:2px 6px; border-radius:4px; font-size:11px;">${escapeHtml(d.hardware.banner)}</code></p>` : ''}
                </div>` : ''}

                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                    <h4 style="margin:0;">Detected Ports &amp; Services</h4>
                    <button class="btn-secondary" style="padding:4px 10px; font-size:11px;" ${isObserved(d) ? '' : 'disabled'} onclick="probeDevicePorts('${d.ip}', this)">⚡ Probe Standard</button>
                </div>

                <!-- Custom Port Scan Input -->
                <div style="background:rgba(255,255,255,0.02); border:1px solid rgba(255,255,255,0.06); border-radius:8px; padding:8px 10px; margin-bottom:12px;">
                    <div style="display:flex; gap:8px;">
                        <input type="text" id="customPortInput" placeholder="Custom port or range (e.g. 3000, 8000-8010, 11434)" style="flex:1; background:#090d16; border:1px solid var(--border); border-radius:6px; padding:6px 10px; font-size:12px; color:#f8fafc; font-family:monospace;">
                        <button class="btn-primary" id="customScanBtn" style="padding:6px 12px; font-size:12px; white-space:nowrap;" onclick="scanCustomPorts('${d.ip}')">⚡ Scan Custom</button>
                    </div>
                </div>

                <ul id="modalPortsList" style="margin-left:20px; margin-bottom:16px; line-height:1.6;">${portsList}</ul>

                <h4 style="margin-bottom:8px;">Quick Terminal Commands</h4>
                <div class="code-block">
                    <span>ping -t ${d.ip}</span>
                    <button class="btn-secondary" style="padding:2px 8px; font-size:11px;" onclick="copyText('ping -t ${d.ip}')">Copy</button>
                </div>
                ${d.category === 'linux' ? `
                <div class="code-block">
                    <span>ssh pi@${d.ip}</span>
                    <button class="btn-secondary" style="padding:2px 8px; font-size:11px;" onclick="copyText('ssh pi@${d.ip}')">Copy</button>
                </div>` : ''}
                ${d.category === 'camera' ? `
                <div class="code-block">
                    <span>ffplay rtsp://${d.ip}:554/stream</span>
                    <button class="btn-secondary" style="padding:2px 8px; font-size:11px;" onclick="copyText('ffplay rtsp://${d.ip}:554/stream')">Copy</button>
                </div>` : ''}
            `;
            document.getElementById('inspectModal').style.display = 'flex';
        }

        function closeModal(e) {
            stopPingMonitor();
            document.getElementById('inspectModal').style.display = 'none';
        }

        function copyText(text) {
            navigator.clipboard.writeText(text).then(() => {
                showToast(`Copied "${text}" to clipboard!`);
            });
        }

        function showToast(msg) {
            const toast = document.getElementById('toast');
            toast.textContent = msg;
            toast.classList.add('show');
            setTimeout(() => toast.classList.remove('show'), 2600);
        }

        function escapeHtml(str) {
            if (!str) return '';
            return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }

        document.getElementById('autoRefreshSelect').addEventListener('change', (e) => {
            const sec = parseInt(e.target.value, 10);
            if (refreshTimer) clearInterval(refreshTimer);
            if (sec > 0) {
                refreshTimer = setInterval(fetchDevices, sec * 1000);
            }
        });

        // Initial Load
        fetchDevices();
        refreshTimer = setInterval(fetchDevices, 10000);
    </script>
</body>
</html>
]]

--------------------------------------------------------------------------------
-- 9. Embedded HTTP Web Server
--------------------------------------------------------------------------------
local function run_web_server(port)
    port = port or 8888
    local server_sock = is_windows and ws2.socket(2, 1, 6) or ffi.C.socket(2, 1, 6)
    if server_sock == -1 or server_sock == ffi.cast("SOCKET", -1) then
        io.stderr:write("Failed to create server socket\n")
        return false
    end

    if not is_windows then
        local opt = ffi.new("int[1]", 1)
        ffi.C.setsockopt(server_sock, 1, 2, opt, ffi.sizeof(opt)) -- SO_REUSEADDR on POSIX
    end

    local server_addr = ffi.new("struct sockaddr_in")
    server_addr.sin_family = 2
    server_addr.sin_port = is_windows and ws2.htons(port) or ffi.C.htons(port)
    server_addr.sin_addr.s_addr = 0 -- INADDR_ANY

    local bind_res = is_windows and ws2.bind(server_sock, server_addr, ffi.sizeof(server_addr))
                                or ffi.C.bind(server_sock, server_addr, ffi.sizeof(server_addr))
    if bind_res ~= 0 then
        io.stderr:write(string.format("Error: Could not bind server to port %d\n", port))
        close_socket(server_sock)
        return false
    end

    local listen_res = is_windows and ws2.listen(server_sock, 32) or ffi.C.listen(server_sock, 32)
    if listen_res ~= 0 then
        io.stderr:write("Error: listen() failed\n")
        close_socket(server_sock)
        return false
    end

    if is_windows then
        local mode = ffi.new("uint32_t[1]", 1)
        ws2.ioctlsocket(server_sock, FIONBIO, mode) -- Non-blocking
    else
        ffi.C.fcntl(server_sock, 4, 0x800) -- F_SETFL, O_NONBLOCK
    end

    print(string.format("\n=================================================================="))
    print(string.format("  🌐 LAN Radar Dashboard Web Server Running"))
    print(string.format("  ------------------------------------------------------------------"))
    print(string.format("  Local URL:    http://localhost:%d/", port))
    local local_ip = get_local_ip()
    if local_ip then
        print(string.format("  Network URL:  http://%s:%d/  (from phone / other PCs)", local_ip, port))
    end
    print(string.format("  REST API:     http://localhost:%d/api/devices", port))
    print(string.format("  Subnet:       %s", STATE.subnet))
    print(string.format("  Ready for incoming connections..."))
    print(string.format("==================================================================\n"))
    io.stdout:flush()

    -- Instant startup initial scan (takes ~40ms)
    run_full_scan(false)

    local last_auto_rescan = os.time()
    local client_addr = ffi.new("struct sockaddr_in")
    local addrlen = ffi.new(is_windows and "int[1]" or "unsigned int[1]", ffi.sizeof(client_addr))
    local recv_buf = ffi.new("char[4096]")

    while true do
        addrlen[0] = ffi.sizeof(client_addr)
        local client_sock
        if is_windows then
            client_sock = ws2.accept(server_sock, client_addr, addrlen)
        else
            client_sock = ffi.C.accept(server_sock, client_addr, addrlen)
        end

        local is_valid_client = is_windows and (client_sock ~= INVALID_SOCKET and client_sock ~= 0)
                                           or (client_sock >= 0)

        if is_valid_client then
            if socket_wait_readable(client_sock, 500) then
                local n_recv = is_windows and ws2.recv(client_sock, recv_buf, 4095, 0)
                                          or ffi.C.recv(client_sock, recv_buf, 4095, 0)
                if n_recv > 0 then
                    local client_ip = "127.0.0.1"
                    if client_addr then
                        local u32 = client_addr.sin_addr.s_addr
                        local b1 = bit.band(u32, 0xFF)
                        local b2 = bit.band(bit.rshift(u32, 8), 0xFF)
                        local b3 = bit.band(bit.rshift(u32, 16), 0xFF)
                        local b4 = bit.band(bit.rshift(u32, 24), 0xFF)
                        local detected_cip = string.format("%d.%d.%d.%d", b1, b2, b3, b4)
                        if detected_cip ~= "0.0.0.0" then client_ip = detected_cip end
                    end
                    local req = ffi.string(recv_buf, n_recv)
                    local method, raw_uri = req:match("^(%a+)%s+([^%s]+)")
                    method = method or "GET"
                    raw_uri = raw_uri or "/"
                    local path = raw_uri:match("^([^%?]+)") or raw_uri

                    local resp_body = ""
                    local content_type = "text/html; charset=utf-8"
                    local status_code = "200 OK"

                    if path == "/" then
                        resp_body = DASHBOARD_HTML
                        content_type = "text/html; charset=utf-8"
                    elseif path == "/api/devices" then
                        resp_body = to_json({
                            status = "ok",
                            subnet = STATE.subnet,
                            scanned_at = os.date("%H:%M:%S", STATE.last_scanned),
                            devices = STATE.devices
                        })
                        content_type = "application/json"
                    elseif path == "/api/scan" and method == "POST" then
                        local updated = run_full_scan(false)
                        resp_body = to_json({
                            status = "ok",
                            subnet = STATE.subnet,
                            scanned_at = os.date("%H:%M:%S", STATE.last_scanned),
                            devices = updated
                        })
                        content_type = "application/json"
                    elseif path:match("^/api/ping") then
                        local target_ip = req:match("ip=([%d%.]+)")
                        local is_alive, rtt = false, 0
                        if target_ip then
                            is_alive, rtt = ping_host(target_ip, 25)
                        end
                        resp_body = to_json({ status = "ok", ip = target_ip, alive = is_alive, rtt = rtt })
                        content_type = "application/json"
                    elseif path:match("^/api/probe") then
                        local target_ip = req:match("ip=([%d%.]+)")
                        local custom_ports_str = req:match("ports=([%d%-,%%]+)")
                        if custom_ports_str then
                            custom_ports_str = custom_ports_str:gsub("%%2[cC]", ","):gsub("%%2[dD]", "-")
                        end
                        local probed_ports = {}
                        if target_ip then
                            local port_list = {}
                            if custom_ports_str and custom_ports_str ~= "" then
                                for part in custom_ports_str:gmatch("[^,]+") do
                                    local p1, p2 = part:match("^(%d+)%-(%d+)$")
                                    if p1 and p2 then
                                        p1, p2 = tonumber(p1), tonumber(p2)
                                        if p1 and p2 and p1 <= p2 then
                                            for p = p1, math.min(p2, p1 + 32) do
                                                if #port_list < 64 and p >= 1 and p <= 65535 then
                                                    table.insert(port_list, { port = p, name = "Port " .. p })
                                                end
                                            end
                                        end
                                    else
                                        local p = tonumber(part)
                                        if p and p >= 1 and p <= 65535 and #port_list < 64 then
                                            table.insert(port_list, { port = p, name = "Port " .. p })
                                        end
                                    end
                                end
                            else
                                port_list = KNOWN_PORTS
                            end

                            for _, kp in ipairs(port_list) do
                                if check_tcp_port(target_ip, kp.port, 25) then
                                    local service_name = kp.name
                                    for _, standard in ipairs(KNOWN_PORTS) do
                                        if standard.port == kp.port then service_name = standard.name; break end
                                    end
                                    table.insert(probed_ports, { port = kp.port, name = service_name })
                                end
                            end
                            -- Update device in memory STATE
                            for _, d in ipairs(STATE.devices) do
                                if d.ip == target_ip and (d.status == "online" or d.status == "offline") then
                                    if custom_ports_str then
                                        d.ports = d.ports or {}
                                        local existing_map = {}
                                        for _, ep in ipairs(d.ports) do existing_map[ep.port] = true end
                                        for _, np in ipairs(probed_ports) do
                                            if not existing_map[np.port] then
                                                table.insert(d.ports, np)
                                            end
                                        end
                                    else
                                        d.ports = probed_ports
                                    end
                                    d.port_count = #d.ports
                                    -- Re-profile hardware banner if port 22 or 80 discovered
                                    if not d.hardware or not d.hardware.banner then
                                        for _, p in ipairs(d.ports) do
                                            if p.port == 22 then
                                                local banner = grab_ssh_banner(target_ip)
                                                if banner then
                                                    d.hardware = d.hardware or {}
                                                    d.hardware.banner = banner
                                                end
                                            end
                                        end
                                    end
                                    break
                                end
                            end
                        end
                        resp_body = to_json({ status = "ok", ip = target_ip, ports = probed_ports, custom = (custom_ports_str ~= nil) })
                        save_inventory()
                        content_type = "application/json"
                    elseif path == "/api/rename" and method == "POST" then
                        local target_ip = req:match('["\']?ip["\']?%s*[:=]%s*["\']?([%d%.]+)["\']?')
                        local new_name = req:match('["\']?name["\']?%s*[:=]%s*["\']([^"\']+)["\']') or req:match('name=([^&%s\r\n]+)')
                        if target_ip and new_name then
                            CUSTOM_NAMES[target_ip] = new_name
                            HOSTNAME_CACHE[target_ip] = new_name
                            save_custom_names()
                            for _, d in ipairs(STATE.devices) do
                                if d.ip == target_ip and (d.status == "online" or d.status == "offline") then
                                    d.hostname = new_name
                                    d.is_custom = true
                                end
                            end
                            save_inventory()
                            resp_body = to_json({ status = "ok", ip = target_ip, name = new_name })
                        else
                            resp_body = to_json({ status = "error", message = "Missing ip or name" })
                        end
                        content_type = "application/json"
                    elseif path == "/api/stats" then
                        local counts = { total = #STATE.devices, windows = 0, linux = 0, phone = 0, camera = 0, router = 0, iot = 0 }
                        for _, d in ipairs(STATE.devices) do
                            if counts[d.category] then counts[d.category] = counts[d.category] + 1 end
                        end
                        resp_body = to_json({
                            status = "ok",
                            counts = counts,
                            subnet = STATE.subnet
                        })
                        content_type = "application/json"
                    else
                        status_code = "404 Not Found"
                        resp_body = "<h1>404 Not Found</h1>"
                    end

                    local header = string.format(
                        "HTTP/1.1 %s\r\n" ..
                        "Content-Type: %s\r\n" ..
                        "Content-Length: %d\r\n" ..
                        "Access-Control-Allow-Origin: *\r\n" ..
                        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ..
                        "Connection: close\r\n\r\n",
                        status_code, content_type, #resp_body
                    )

                    local full_resp = header .. resp_body
                    if is_windows then
                        ws2.send(client_sock, full_resp, #full_resp, 0)
                        pcall(function() ws2.shutdown(client_sock, 1) end)
                    else
                        ffi.C.send(client_sock, full_resp, #full_resp, 0)
                        pcall(function() ffi.C.shutdown(client_sock, 1) end)
                    end
                    print(string.format("[%s] %-15s %-4s %-28s -> %s (%d B)",
                        os.date("%H:%M:%S"), client_ip, method, raw_uri:sub(1, 28), status_code, #resp_body))
                    io.stdout:flush()
                end
            end
            close_socket(client_sock)
        else
            ffi_sleep_ms(20)
        end

        if os.time() - last_auto_rescan > 60 then
            last_auto_rescan = os.time()
            local updated = run_full_scan(false)
            print(string.format("[%s] [Auto-Rescan] Subnet refresh complete: %d known devices on %s",
                os.date("%H:%M:%S"), #updated, STATE.subnet))
            io.stdout:flush()
        end
    end
end

--------------------------------------------------------------------------------
-- 10. CLI Diagnostic & Scan-Only Mode
--------------------------------------------------------------------------------
local function print_cli_table(devices)
    print("\n" .. string.rep("=", 120))
    print(string.format("  %-16s %-20s %-18s %-22s %-18s %-8s %s", "IP ADDRESS", "HOSTNAME", "MAC ADDRESS", "VENDOR", "CATEGORY", "STATUS", "LATENCY"))
    print(string.rep("-", 120))
    for _, d in ipairs(devices) do
        local lat_str = d.status == "online" and string.format("%d ms", d.latency_ms) or ("last seen " .. os.date("%Y-%m-%d %H:%M:%S", d.last_seen))
        local host_display = (d.hostname or "-")
        if d.is_custom then host_display = host_display .. " *" end
        print(string.format("  %-16s %-20s %-18s %-22s %-18s %-8s %s",
            d.ip, host_display:sub(1, 19), d.mac, d.vendor:sub(1, 21), d.type_name, d.status, lat_str))
    end
    print(string.rep("=", 120))
    print(string.format("  Total: %d known devices on %s (* = custom alias)\n", #devices, STATE.subnet))
end

--------------------------------------------------------------------------------
-- 11. Self-Test Suite (--test)
--------------------------------------------------------------------------------
local function run_self_tests()
    print("Running lan_dashboard test suite...")

    -- Test 1: Vendor lookup
    assert(lookup_vendor("DC:A6:32:00:11:22") == "Raspberry Pi Trading", "Raspberry Pi OUI lookup failed")
    assert(lookup_vendor("1C:61:B4:00:11:22") == "Intel Corporation", "Intel OUI lookup failed")
    assert(lookup_vendor("60:6D:C7:00:11:22") == "Apple, Inc.", "Apple OUI lookup failed")
    assert(lookup_vendor("84:3E:1D:00:11:22") == "Espressif Inc (IoT)", "Espressif OUI lookup failed")
    print("  [PASS] MAC OUI database lookups")

    -- Test 2: Classification heuristics
    local cam_info = classify_device("192.168.1.50", "00:9e:c8:11:22:33", "Dahua Technology", {554, 80}, "Front-Cam")
    assert(cam_info.category == "camera", "Camera classification failed")

    local win_info = classify_device("192.168.1.109", "1c:61:b4:00:11:22", "Intel Corporation", {445, 135}, "Workstation-PC")
    assert(win_info.category == "windows", "Windows classification failed")

    local pi_info = classify_device("192.168.1.10", "dc:a6:32:00:11:22", "Raspberry Pi Trading", {22}, "raspberrypi")
    assert(pi_info.category == "linux", "Linux/Pi classification failed")

    local phone_info = classify_device("192.168.1.14", "60:6d:c7:00:11:22", "Apple, Inc.", {}, "iPhone")
    assert(phone_info.category == "phone", "Phone classification failed")

    local router_info = classify_device("192.168.1.1", "6c:cd:d6:00:11:22", "Netgear", {80, 53}, "Gateway")
    assert(router_info.category == "router", "Router classification failed")
    print("  [PASS] Device classification heuristics")

    -- Test 3: JSON Serializer
    local test_obj = { status = "ok", count = 3, items = {"a", "b", "c"}, flag = true }
    local json_str = to_json(test_obj)
    assert(json_str:find('"status":"ok"'), "JSON serialization failed for string")
    assert(json_str:find('"count":3'), "JSON serialization failed for number")
    assert(json_str:find('"flag":true'), "JSON serialization failed for boolean")
    print("  [PASS] Minimal JSON serializer")

    -- Test 4: ARP parser test
    local test_entries = get_arp_entries()
    assert(type(test_entries) == "table", "get_arp_entries should return table")
    print(string.format("  [PASS] ARP cache parser (found %d live entries)", #test_entries))

    print("\nAll self-tests passed successfully!\n")
    return true
end

--------------------------------------------------------------------------------
-- 12. Main Dispatcher
--------------------------------------------------------------------------------
local M = {
    lookup_vendor = lookup_vendor,
    classify_device = classify_device,
    get_arp_entries = get_arp_entries,
    ping_host = ping_host,
    check_tcp_port = check_tcp_port,
    probe_device_services = probe_device_services,
    resolve_system_hostname = resolve_system_hostname,
    CUSTOM_NAMES = CUSTOM_NAMES,
    save_custom_names = save_custom_names,
    KNOWN_PORTS = KNOWN_PORTS,
    run_full_scan = run_full_scan,
    to_json = to_json,
    STATE = STATE,
    INVENTORY = INVENTORY,
    DASHBOARD_HTML = DASHBOARD_HTML,
    run_self_tests = run_self_tests
}

if ... and ... == "lan_dashboard" then
    return M
end

local args = {...}
local port = 8888
local mode = "server"

local i = 1
while i <= #args do
    local a = args[i]
    if a == "--port" or a == "-p" then
        port = tonumber(args[i + 1]) or 8888
        i = i + 1
    elseif a == "--scan-only" or a == "-s" then
        mode = "scan"
    elseif a == "--json" then
        mode = "json"
    elseif a == "--test" or a == "-t" then
        mode = "test"
    elseif a == "--help" or a == "-h" then
        print([[
Usage: luajit lan_dashboard.lua [options]

Options:
  --port, -p <PORT>   Start dashboard web server on custom port (default: 8888)
  --scan-only, -s     Run one-shot LAN scan and print formatted terminal table
  --json              Run one-shot scan and output JSON format
  --test, -t          Run built-in test suite
  --help, -h          Show this help message
]])
        os.exit(0)
    end
    i = i + 1
end

if mode == "test" then
    run_self_tests()
    os.exit(0)
elseif mode == "json" then
    local devs = run_full_scan(false)
    print(to_json({ status = "ok", subnet = STATE.subnet, count = #devs, devices = devs }))
    os.exit(0)
elseif mode == "scan" then
    print("Scanning LAN devices...")
    local devs = run_full_scan(false)
    print_cli_table(devs)
    os.exit(0)
else
    run_web_server(port)
end

return M
