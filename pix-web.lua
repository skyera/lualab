#!/usr/bin/env luajit
-- =========================================================================
-- pix-web.lua
-- Standalone In-Browser Media Gallery & Streaming Server in LuaJIT FFI
--
-- Features:
-- 1. Full Format Parity with pix.lua:
--    - Images: PNG, JPG/JPEG, WEBP, GIF (animated detection), BMP, PPM
--    - Videos: MP4, MKV, WEBM, AVI, MOV, M4V, FLV, RMVB, RM
--    - Audio:  MP3, FLAC, WAV, OGG, M4A, AAC, OPUS, WMA
-- 2. HTTP Server Engine with Zero External Dependencies:
--    - Pure LuaJIT FFI Sockets (POSIX on Linux/macOS, Winsock2 on Windows)
--    - HTTP 1.1 with Byte-Range partial content streaming (seekable audio/video)
--    - Multi-file binary upload and file deletion
-- 3. Modern Responsive Web Interface:
--    - Dark glassmorphism gallery with Grid and List views
--    - Subdirectory breadcrumbs and parent navigation
--    - Sort by Name, Date, Size (Ascending/Descending)
--    - Instant client-side search & filter
--    - Lightbox image viewer: Pan, Zoom, Rotate (90°), Slideshow, Fullscreen
--    - Native HTML5 Video & Audio players with playback speed and loop controls
--    - Mobile QR Pairing modal for one-tap LAN access
-- =========================================================================

local ffi = require("ffi")
local bit = require("bit")

-- Local module resolution
local script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
if script_dir and script_dir ~= "" then
    package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path
end

local json
local has_json, json_mod = pcall(require, "json")
if has_json and type(json_mod) == "table" and json_mod.encode and json_mod.decode then
    json = json_mod
else
    json = {
        encode = function(val)
            local function ser(v)
                local t = type(v)
                if t == "nil" then return "null"
                elseif t == "boolean" then return v and "true" or "false"
                elseif t == "number" then return tostring(v)
                elseif t == "string" then
                    local s = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
                    return '"' .. s .. '"'
                elseif t == "table" then
                    local is_arr = false
                    if #v > 0 or next(v) == nil then
                        is_arr = true
                        for k, _ in pairs(v) do
                            if type(k) ~= "number" then is_arr = false; break end
                        end
                    end
                    local parts = {}
                    if is_arr then
                        for _, item in ipairs(v) do
                            table.insert(parts, ser(item))
                        end
                        return "[" .. table.concat(parts, ",") .. "]"
                    else
                        for k, item in pairs(v) do
                            table.insert(parts, ser(tostring(k)) .. ":" .. ser(item))
                        end
                        return "{" .. table.concat(parts, ",") .. "}"
                    end
                end
                return "null"
            end
            return ser(val)
        end,
        decode = function(str)
            if not str or #str == 0 then return nil end
            local pos = 1
            local len = #str
            local function skip_ws()
                while pos <= len and str:sub(pos, pos):match("%s") do pos = pos + 1 end
            end
            local parse_val
            local function parse_str()
                pos = pos + 1
                local res = {}
                while pos <= len do
                    local c = str:sub(pos, pos)
                    if c == '"' then
                        pos = pos + 1
                        return table.concat(res)
                    elseif c == "\\" then
                        pos = pos + 1
                        local esc = str:sub(pos, pos)
                        if esc == '"' then table.insert(res, '"')
                        elseif esc == '\\' then table.insert(res, '\\')
                        elseif esc == '/' then table.insert(res, '/')
                        elseif esc == 'b' then table.insert(res, '\b')
                        elseif esc == 'f' then table.insert(res, '\f')
                        elseif esc == 'n' then table.insert(res, '\n')
                        elseif esc == 'r' then table.insert(res, '\r')
                        elseif esc == 't' then table.insert(res, '\t')
                        else table.insert(res, esc) end
                    else
                        table.insert(res, c)
                    end
                    pos = pos + 1
                end
                return table.concat(res)
            end
            local function parse_num()
                local s_start = pos
                while pos <= len and str:sub(pos, pos):match("[%d%.%-%+eE]") do pos = pos + 1 end
                return tonumber(str:sub(s_start, pos - 1)) or 0
            end
            local function parse_arr()
                pos = pos + 1
                local arr = {}
                skip_ws()
                if pos <= len and str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
                while pos <= len do
                    table.insert(arr, parse_val())
                    skip_ws()
                    local c = str:sub(pos, pos)
                    if c == "]" then pos = pos + 1; break end
                    if c == "," then pos = pos + 1; skip_ws() end
                end
                return arr
            end
            local function parse_obj()
                pos = pos + 1
                local obj = {}
                skip_ws()
                if pos <= len and str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
                while pos <= len do
                    skip_ws()
                    local k = parse_str()
                    skip_ws()
                    if str:sub(pos, pos) == ":" then pos = pos + 1 end
                    skip_ws()
                    obj[k] = parse_val()
                    skip_ws()
                    local c = str:sub(pos, pos)
                    if c == "}" then pos = pos + 1; break end
                    if c == "," then pos = pos + 1; skip_ws() end
                end
                return obj
            end
            parse_val = function()
                skip_ws()
                if pos > len then return nil end
                local c = str:sub(pos, pos)
                if c == '"' then return parse_str()
                elseif c == '{' then return parse_obj()
                elseif c == '[' then return parse_arr()
                elseif c == 't' and str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
                elseif c == 'f' and str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
                elseif c == 'n' and str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
                else return parse_num() end
            end
            local ok, val = pcall(parse_val)
            return ok and val or nil
        end
    }
end

local PIXWEB_VERSION = "0.1.0"
local is_windows = (ffi.os == "Windows")
local ws2

-- =========================================================================
-- 1. Sockets & System FFI Declarations
-- =========================================================================
if is_windows then
    ffi.cdef[[
        typedef uintptr_t SOCKET;
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
        int closesocket(SOCKET s);
        int setsockopt(SOCKET s, int level, int optname, const void *optval, int optlen);
        int getsockname(SOCKET s, void *name, int *namelen);
        int shutdown(SOCKET s, int how);
        int recv(SOCKET s, char *buf, int len, int flags);
        int send(SOCKET s, const char *buf, int len, int flags);
        int connect(SOCKET s, const void *name, int namelen);

        struct in_addr { uint32_t s_addr; };
        struct sockaddr_in {
            uint16_t sin_family;
            uint16_t sin_port;
            struct in_addr sin_addr;
            char sin_zero[8];
        };

        uint16_t htons(uint16_t hostshort);
        uint16_t ntohs(uint16_t netshort);
        uint32_t htonl(uint32_t hostlong);
        uint32_t ntohl(uint32_t netlong);
        uint32_t inet_addr(const char *cp);
        char *inet_ntoa(struct in_addr in);

        int _mkdir(const char *path);
        int remove(const char *filename);
        int GetDiskFreeSpaceExA(const char *lpDirectoryName, uint64_t *lpFreeBytesAvailable, uint64_t *lpTotalNumberOfBytes, uint64_t *lpTotalNumberOfFreeBytes);

        typedef struct _FILETIME {
            uint32_t dwLowDateTime;
            uint32_t dwHighDateTime;
        } FILETIME;

        typedef struct _WIN32_FIND_DATAW {
            uint32_t dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            uint32_t nFileSizeHigh;
            uint32_t nFileSizeLow;
            uint32_t dwReserved0;
            uint32_t dwReserved1;
            wchar_t  cFileName[260];
            wchar_t  cAlternateFileName[14];
        } WIN32_FIND_DATAW;

        void* __stdcall FindFirstFileW(const wchar_t *lpFileName, WIN32_FIND_DATAW *lpFindFileData);
        int   __stdcall FindNextFileW(void *hFindFile, WIN32_FIND_DATAW *lpFindFileData);
        int   __stdcall FindClose(void *hFindFile);
        int   __stdcall MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
        int   __stdcall WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags, const wchar_t *lpWideCharStr, int cchWideChar, char *lpMultiByteStr, int cbMultiByte, const char *lpDefaultChar, int *lpUsedDefaultChar);
        uint32_t __stdcall GetACP(void);
        int   __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        int   __stdcall SetConsoleCP(uint32_t wCodePageID);
        uint32_t __stdcall GetConsoleOutputCP(void);
        void* __stdcall GetStdHandle(uint32_t nStdHandle);
        int   __stdcall GetConsoleMode(void *hConsoleHandle, uint32_t *lpMode);
        int   __stdcall SetConsoleMode(void *hConsoleHandle, uint32_t dwMode);
    ]]
    ws2 = ffi.load("ws2_32")
    local wsa_data = ffi.new("WSADATA")
    ws2.WSAStartup(0x0202, wsa_data)
else
    ffi.cdef[[
        typedef int SOCKET;
        struct in_addr { uint32_t s_addr; };
        struct sockaddr_in {
            uint16_t sin_family;
            uint16_t sin_port;
            struct in_addr sin_addr;
            char sin_zero[8];
        };

        struct pollfd {
            int fd;
            short events;
            short revents;
        };

        int socket(int domain, int type, int protocol);
        int bind(int sockfd, const void *addr, unsigned int addrlen);
        int listen(int sockfd, int backlog);
        int accept(int sockfd, void *addr, unsigned int *addrlen);
        int close(int fd);
        int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
        int getsockname(int sockfd, void *addr, unsigned int *addrlen);
        int shutdown(int sockfd, int how);
        long recv(int sockfd, void *buf, size_t len, int flags);
        long send(int sockfd, const void *buf, size_t len, int flags);
        int connect(int sockfd, const void *addr, unsigned int addrlen);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);

        uint16_t htons(uint16_t hostshort);
        uint16_t ntohs(uint16_t netshort);
        uint32_t htonl(uint32_t hostlong);
        uint32_t ntohl(uint32_t netlong);
        uint32_t inet_addr(const char *cp);
        char *inet_ntoa(struct in_addr in);

        int mkdir(const char *pathname, unsigned int mode);
        int remove(const char *pathname);

        struct statvfs {
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
            int __f_spare[6];
        };
        int statvfs(const char *path, struct statvfs *buf);

        typedef struct DIR DIR;
        struct dirent {
            unsigned long  d_ino;
            long           d_off;
            unsigned short d_reclen;
            unsigned char  d_type;
            char           d_name[256];
        };
        DIR *opendir(const char *name);
        struct dirent *readdir(DIR *dirp);
        int closedir(DIR *dirp);

        typedef long time_t;
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
            time_t         st_atime;
            unsigned long  st_atime_nsec;
            time_t         st_mtime;
            unsigned long  st_mtime_nsec;
            time_t         st_ctime;
            unsigned long  st_ctime_nsec;
            long           __unused[3];
        };
        int stat(const char *pathname, struct stat *statbuf);
        int __xstat(int ver, const char *pathname, struct stat *statbuf);
    ]]
end

local C = ffi.C
local kernel32 = is_windows and ffi.load("kernel32") or nil

if is_windows and kernel32 then
    pcall(function()
        kernel32.SetConsoleOutputCP(65001)
        kernel32.SetConsoleCP(65001)
        local STD_OUTPUT_HANDLE = 0xFFFFFFF5
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        if kernel32.GetConsoleMode(hOut, mode) ~= 0 then
            local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            kernel32.SetConsoleMode(hOut, bit.bor(mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        end
    end)
end

local AF_INET      = 2
local SOCK_STREAM  = 1
local SOCK_DGRAM   = 2
local SOL_SOCKET   = is_windows and 0xFFFF or 1
local SO_REUSEADDR = is_windows and 0x0004 or 2
local INVALID_SOCK = is_windows and ffi.cast("uintptr_t", -1) or -1

local function close_socket(s)
    if is_windows then
        if ws2 and s ~= INVALID_SOCK and s ~= 0 then ws2.closesocket(s) end
    else
        if s >= 0 then C.close(s) end
    end
end

-- =========================================================================
-- 2. Media Formats & Extension Categories
-- =========================================================================
local IMAGE_EXTENSIONS = {
    png = true, jpg = true, jpeg = true, ppm = true,
    webp = true, gif = true, bmp = true, svg = true,
}

local VIDEO_EXTENSIONS = {
    mp4 = true, mkv = true, webm = true, avi = true,
    mov = true, m4v = true, flv = true, rmvb = true, rm = true,
}

local AUDIO_EXTENSIONS = {
    mp3 = true, flac = true, wav = true, ogg = true, oga = true,
    m4a = true, aac = true, opus = true, wma = true,
}

local MIME_TYPES = {
    -- Images
    png  = "image/png",
    jpg  = "image/jpeg",
    jpeg = "image/jpeg",
    webp = "image/webp",
    gif  = "image/gif",
    bmp  = "image/bmp",
    svg  = "image/svg+xml",
    ppm  = "image/x-portable-pixmap",
    -- Videos
    mp4  = "video/mp4",
    webm = "video/webm",
    mkv  = "video/x-matroska",
    avi  = "video/x-msvideo",
    mov  = "video/quicktime",
    m4v  = "video/x-m4v",
    flv  = "video/x-flv",
    -- Audio
    mp3  = "audio/mpeg",
    flac = "audio/flac",
    wav  = "audio/wav",
    ogg  = "audio/ogg",
    oga  = "audio/ogg",
    m4a  = "audio/mp4",
    aac  = "audio/aac",
    opus = "audio/opus",
    wma  = "audio/x-ms-wma",
    -- Web
    html = "text/html; charset=utf-8",
    css  = "text/css",
    js   = "application/javascript",
    json = "application/json",
    txt  = "text/plain; charset=utf-8",
}

local function get_mime_type(filename)
    local ext = filename:match("%.([^.]+)$")
    if ext then
        ext = ext:lower()
        if MIME_TYPES[ext] then return MIME_TYPES[ext] end
    end
    return "application/octet-stream"
end

local function format_file_size(bytes)
    bytes = bytes or 0
    if bytes < 1024 then return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024))
    else return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function format_date(timestamp)
    if not timestamp or timestamp <= 0 then return "-" end
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

local function is_animated_gif(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(6)
    if head ~= "GIF89a" and head ~= "GIF87a" then f:close(); return false end
    f:seek("set", 10)
    local gct_info = f:read(1)
    if not gct_info then f:close(); return false end
    local gct_flag = bit.band(gct_info:byte(), 0x80) ~= 0
    local gct_size = 0
    if gct_flag then
        local sz = bit.band(gct_info:byte(), 0x07)
        gct_size = 3 * math.pow(2, sz + 1)
        f:seek("cur", gct_size)
    end
    f:seek("cur", 2) -- skip aspect ratio / bg
    local frame_count = 0
    while true do
        local b = f:read(1)
        if not b or b == ";" then break end
        if b == "!" then
            local label = f:read(1)
            while true do
                local sz_b = f:read(1)
                if not sz_b then break end
                local sz = sz_b:byte()
                if sz == 0 then break end
                f:seek("cur", sz)
            end
        elseif b == "," then
            frame_count = frame_count + 1
            if frame_count > 1 then f:close(); return true end
            f:seek("cur", 8)
            local local_info = f:read(1)
            if not local_info then break end
            local lct_flag = bit.band(local_info:byte(), 0x80) ~= 0
            if lct_flag then
                local sz = bit.band(local_info:byte(), 0x07)
                local lct_size = 3 * math.pow(2, sz + 1)
                f:seek("cur", lct_size)
            end
            f:seek("cur", 1) -- LZW code size
            while true do
                local sz_b = f:read(1)
                if not sz_b then break end
                local sz = sz_b:byte()
                if sz == 0 then break end
                f:seek("cur", sz)
            end
        else
            break
        end
    end
    f:close()
    return frame_count > 1
end

local function is_animated_webp(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(12)
    if not head or #head < 12 or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WEBP" then
        f:close(); return false
    end
    local chunk_tag = f:read(4)
    if chunk_tag == "VP8X" then
        local _ = f:read(4)
        local flags = f:read(1)
        f:close()
        if flags and bit.band(flags:byte(), 0x02) ~= 0 then return true end
    end
    f:close()
    return false
end

-- =========================================================================
-- 3. Path & Security Utilities
-- =========================================================================
local function sanitize_subpath(raw_path)
    if not raw_path or raw_path == "" or raw_path == "." then return "" end
    local p = raw_path:gsub("\\", "/"):gsub("^/+", "")
    -- Prevent directory traversal
    local parts = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." and seg ~= "" then
            table.insert(parts, seg)
        end
    end
    return table.concat(parts, "/")
end

local function get_local_lan_ip()
    local s
    if is_windows then
        s = ws2.socket(AF_INET, SOCK_DGRAM, 0)
    else
        s = C.socket(AF_INET, SOCK_DGRAM, 0)
    end
    if s == INVALID_SOCK or s < 0 then return "127.0.0.1" end

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = AF_INET
    if is_windows then
        addr.sin_port = ws2.htons(80)
        addr.sin_addr.s_addr = ws2.inet_addr("8.8.8.8")
        if ws2.connect(s, addr, ffi.sizeof(addr)) == 0 then
            local len = ffi.new("int[1]", ffi.sizeof(addr))
            if ws2.getsockname(s, addr, len) == 0 then
                local ip_str = ffi.string(ws2.inet_ntoa(addr.sin_addr))
                close_socket(s)
                return ip_str
            end
        end
    else
        addr.sin_port = C.htons(80)
        addr.sin_addr.s_addr = C.inet_addr("8.8.8.8")
        if C.connect(s, addr, ffi.sizeof(addr)) == 0 then
            local len = ffi.new("unsigned int[1]", ffi.sizeof(addr))
            if C.getsockname(s, addr, len) == 0 then
                local ip_str = ffi.string(C.inet_ntoa(addr.sin_addr))
                close_socket(s)
                return ip_str
            end
        end
    end
    close_socket(s)
    return "127.0.0.1"
end

local function get_disk_space(dir)
    if is_windows then
        local free_avail = ffi.new("uint64_t[1]")
        local total_bytes = ffi.new("uint64_t[1]")
        local total_free = ffi.new("uint64_t[1]")
        if kernel32.GetDiskFreeSpaceExA(dir, free_avail, total_bytes, total_free) ~= 0 then
            local free_b = tonumber(free_avail[0])
            local tot_b = tonumber(total_bytes[0])
            local used_b = tot_b - free_b
            local pct = tot_b > 0 and math.floor((used_b / tot_b) * 100) or 0
            return {
                disk_free = free_b,
                disk_free_fmt = format_file_size(free_b),
                disk_total = tot_b,
                disk_total_fmt = format_file_size(tot_b),
                disk_used_percent = pct,
            }
        end
    else
        local vfs = ffi.new("struct statvfs")
        if C.statvfs(dir, vfs) == 0 then
            local bsize = tonumber(vfs.f_frsize) > 0 and tonumber(vfs.f_frsize) or tonumber(vfs.f_bsize)
            local total_b = tonumber(vfs.f_blocks) * bsize
            local free_b = tonumber(vfs.f_bavail) * bsize
            local used_b = total_b - free_b
            local pct = total_b > 0 and math.floor((used_b / total_b) * 100) or 0
            return {
                disk_free = free_b,
                disk_free_fmt = format_file_size(free_b),
                disk_total = total_b,
                disk_total_fmt = format_file_size(total_b),
                disk_used_percent = pct,
            }
        end
    end
    return {
        disk_free = 0,
        disk_free_fmt = "0 B",
        disk_total = 0,
        disk_total_fmt = "0 B",
        disk_used_percent = 0,
    }
end

-- =========================================================================
-- 4. Media Scanner Engine
-- =========================================================================
local function to_win_wide(str)
    if not is_windows or type(str) ~= "string" then return nil end
    local len = kernel32.MultiByteToWideChar(65001, 0, str, #str, nil, 0)
    if len <= 0 then
        len = kernel32.MultiByteToWideChar(0, 0, str, #str, nil, 0)
        if len <= 0 then return nil end
    end
    local wbuf = ffi.new("wchar_t[?]", len + 1)
    kernel32.MultiByteToWideChar(65001, 0, str, #str, wbuf, len)
    wbuf[len] = 0
    return wbuf
end

local function win_wide_to_utf8(wstr)
    if not is_windows or not wstr then return "" end
    local len = kernel32.WideCharToMultiByte(65001, 0, wstr, -1, nil, 0, nil, nil)
    if len <= 0 then return "" end
    local buf = ffi.new("char[?]", len)
    kernel32.WideCharToMultiByte(65001, 0, wstr, -1, buf, len, nil, nil)
    return ffi.string(buf, len - 1)
end

local function posix_stat(path, st)
    if pcall(function() return C.stat end) then
        return C.stat(path, st)
    elseif pcall(function() return C.__xstat end) then
        local res = C.__xstat(3, path, st)
        if res ~= 0 then res = C.__xstat(1, path, st) end
        return res
    end
    return -1
end

local function scan_media_dir(root_dir, sub_dir, recursive, filter_query)
    local target_dir = root_dir
    local clean_sub = sanitize_subpath(sub_dir)
    if clean_sub ~= "" then
        target_dir = root_dir .. "/" .. clean_sub
    end

    local entries = {}
    local folders = {}

    local q_lower = filter_query and filter_query:lower() or nil

    if is_windows then
        local norm_dir = target_dir:gsub("/", "\\"):gsub("\\+$", "")
        if norm_dir == "" then norm_dir = "." end
        local search_pattern = norm_dir .. "\\*"
        local find_data = ffi.new("WIN32_FIND_DATAW")
        local wpattern = to_win_wide(search_pattern)
        local INVALID_HANDLE_VALUE = ffi.cast("void*", -1)
        local hFind = wpattern and kernel32.FindFirstFileW(wpattern, find_data) or INVALID_HANDLE_VALUE

        if hFind ~= INVALID_HANDLE_VALUE and hFind ~= nil and hFind ~= ffi.cast("void*", 0) then
            repeat
                local fname = win_wide_to_utf8(find_data.cFileName)
                local is_dir = bit.band(find_data.dwFileAttributes, 0x10) ~= 0

                if fname ~= "." and fname ~= ".." and not fname:match("^%..") then
                    local rel_sub = (clean_sub == "") and fname or (clean_sub .. "/" .. fname)
                    local ft = tonumber(find_data.ftLastWriteTime.dwHighDateTime) * 4294967296 + tonumber(find_data.ftLastWriteTime.dwLowDateTime)
                    local mtime = math.floor((ft - 116444736000000000) / 10000000)

                    if is_dir then
                        if recursive then
                            local sub_entries, sub_folders = scan_media_dir(root_dir, rel_sub, true, filter_query)
                            for _, se in ipairs(sub_entries) do table.insert(entries, se) end
                        else
                            table.insert(folders, {
                                name = fname,
                                subpath = rel_sub,
                                mtime = mtime,
                                date_str = format_date(mtime),
                            })
                        end
                    else
                        local ext = fname:match("%.([^.]+)$")
                        if ext then
                            ext = ext:lower()
                            local is_img = IMAGE_EXTENSIONS[ext] == true
                            local is_vid = VIDEO_EXTENSIONS[ext] == true
                            local is_aud = AUDIO_EXTENSIONS[ext] == true

                            if is_img or is_vid or is_aud then
                                if not q_lower or fname:lower():find(q_lower, 1, true) then
                                    local size = tonumber(find_data.nFileSizeHigh) * 4294967296 + tonumber(find_data.nFileSizeLow)
                                    local full_local = norm_dir .. "\\" .. fname
                                    local is_anim = false
                                    if ext == "gif" then is_anim = is_animated_gif(full_local)
                                    elseif ext == "webp" then is_anim = is_animated_webp(full_local) end

                                    table.insert(entries, {
                                        name = fname,
                                        subpath = rel_sub,
                                        ext = ext:upper(),
                                        size = size,
                                        size_fmt = format_file_size(size),
                                        mtime = mtime,
                                        date_str = format_date(mtime),
                                        type = is_img and "image" or (is_vid and "video" or "audio"),
                                        is_animated = is_anim,
                                        mime = MIME_TYPES[ext] or "application/octet-stream",
                                    })
                                end
                            end
                        end
                    end
                end
            until kernel32.FindNextFileW(hFind, find_data) == 0
            kernel32.FindClose(hFind)
        end
    else
        -- POSIX
        local d = C.opendir(target_dir)
        if d ~= nil then
            local st = ffi.new("struct stat")
            while true do
                local ent = C.readdir(d)
                if ent == nil then break end
                local fname = ffi.string(ent.d_name)

                if fname ~= "." and fname ~= ".." and not fname:match("^%..") then
                    local full_path = target_dir .. "/" .. fname
                    local rel_sub = (clean_sub == "") and fname or (clean_sub .. "/" .. fname)
                    local is_dir = (ent.d_type == 4)
                    local is_reg = (ent.d_type == 8)
                    local size = 0
                    local mtime = 0

                    if posix_stat(full_path, st) == 0 then
                        local mode = tonumber(st.st_mode)
                        if bit.band(mode, 0xF000) == 0x4000 then is_dir = true end
                        if bit.band(mode, 0xF000) == 0x8000 then is_reg = true end
                        size = tonumber(st.st_size)
                        mtime = tonumber(st.st_mtime)
                    end

                    if is_dir then
                        if recursive then
                            local sub_entries, _ = scan_media_dir(root_dir, rel_sub, true, filter_query)
                            for _, se in ipairs(sub_entries) do table.insert(entries, se) end
                        else
                            table.insert(folders, {
                                name = fname,
                                subpath = rel_sub,
                                mtime = mtime,
                                date_str = format_date(mtime),
                            })
                        end
                    elseif is_reg or ent.d_type == 0 then
                        local ext = fname:match("%.([^.]+)$")
                        if ext then
                            ext = ext:lower()
                            local is_img = IMAGE_EXTENSIONS[ext] == true
                            local is_vid = VIDEO_EXTENSIONS[ext] == true
                            local is_aud = AUDIO_EXTENSIONS[ext] == true

                            if is_img or is_vid or is_aud then
                                if not q_lower or fname:lower():find(q_lower, 1, true) then
                                    if size == 0 then
                                        local tf = io.open(full_path, "rb")
                                        if tf then
                                            size = tf:seek("end") or 0
                                            tf:close()
                                        end
                                    end
                                    local is_anim = false
                                    if ext == "gif" then is_anim = is_animated_gif(full_path)
                                    elseif ext == "webp" then is_anim = is_animated_webp(full_path) end

                                    table.insert(entries, {
                                        name = fname,
                                        subpath = rel_sub,
                                        ext = ext:upper(),
                                        size = size,
                                        size_fmt = format_file_size(size),
                                        mtime = mtime,
                                        date_str = format_date(mtime),
                                        type = is_img and "image" or (is_vid and "video" or "audio"),
                                        is_animated = is_anim,
                                        mime = MIME_TYPES[ext] or "application/octet-stream",
                                    })
                                end
                            end
                        end
                    end
                end
            end
            C.closedir(d)
        end
    end

    return entries, folders
end

-- =========================================================================
-- 5. Embedded HTML5 / CSS / Vanilla JavaScript Frontend
-- =========================================================================
local function get_index_html(lan_ip, port, default_dir)
    return [===[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>PixWeb Media Gallery</title>
  <style>
    :root {
      --bg: #0b0f14;
      --card-bg: rgba(22, 27, 34, 0.85);
      --card-hover: rgba(30, 38, 48, 0.95);
      --card-border: #30363d;
      --text: #f0f6fc;
      --text-muted: #8b949e;
      --accent: #58a6ff;
      --accent-hover: #79c0ff;
      --danger: #f85149;
      --success: #3fb950;
      --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: var(--font);
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }
    header {
      background: rgba(13, 17, 23, 0.96);
      backdrop-filter: blur(12px);
      border-bottom: 1px solid var(--card-border);
      position: sticky;
      top: 0;
      z-index: 100;
      padding: 12px 20px;
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 10px;
      font-size: 18px;
      font-weight: 700;
      letter-spacing: -0.3px;
      color: #fff;
    }
    .brand span {
      background: linear-gradient(135deg, #58a6ff, #bc8cff);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .header-controls {
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
    }
    .search-box {
      background: #161b22;
      border: 1px solid var(--card-border);
      border-radius: 8px;
      padding: 7px 12px;
      color: var(--text);
      font-size: 13px;
      outline: none;
      width: 220px;
      transition: border-color 0.2s, width 0.2s;
    }
    .search-box:focus {
      border-color: var(--accent);
      width: 260px;
    }
    .btn {
      padding: 7px 14px;
      border-radius: 8px;
      font-size: 13px;
      font-weight: 600;
      border: 1px solid var(--card-border);
      background: #21262d;
      color: var(--text);
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: all 0.15s ease;
      text-decoration: none;
    }
    .btn:hover { background: #30363d; border-color: #8b949e; }
    .btn-primary { background: #1f6feb; border-color: #388bfd; color: #fff; }
    .btn-primary:hover { background: #388bfd; }
    .btn-danger { color: var(--danger); }
    .btn-danger:hover { background: rgba(248, 81, 73, 0.15); border-color: var(--danger); }
    .btn-icon { padding: 7px 10px; }
    .btn-active { background: #388bfd; color: #fff; border-color: #58a6ff; }

    /* Sub-nav breadcrumbs & toolbar */
    .subnav {
      padding: 12px 20px;
      background: rgba(22, 27, 34, 0.5);
      border-bottom: 1px solid var(--card-border);
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 10px;
    }
    .breadcrumbs {
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 13px;
      color: var(--text-muted);
      overflow-x: auto;
      white-space: nowrap;
    }
    .crumb-item {
      color: var(--accent);
      cursor: pointer;
      text-decoration: none;
    }
    .crumb-item:hover { text-decoration: underline; }
    .stats-badge {
      font-size: 12px;
      color: var(--text-muted);
      background: #161b22;
      padding: 4px 10px;
      border-radius: 20px;
      border: 1px solid var(--card-border);
    }

    /* Container & Layouts */
    main {
      flex: 1;
      padding: 20px;
      max-width: 1600px;
      margin: 0 auto;
      width: 100%;
    }
    .folder-section {
      margin-bottom: 24px;
    }
    .folder-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
      gap: 12px;
      margin-top: 10px;
    }
    .folder-card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 10px;
      padding: 12px 14px;
      display: flex;
      align-items: center;
      gap: 10px;
      cursor: pointer;
      transition: background 0.15s, transform 0.15s;
      overflow: hidden;
    }
    .folder-card:hover {
      background: var(--card-hover);
      transform: translateY(-2px);
      border-color: var(--accent);
    }
    .folder-card .icon { font-size: 22px; }
    .folder-card .name {
      font-size: 13px;
      font-weight: 500;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    /* Media Grid View */
    .media-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
      gap: 16px;
    }
    .media-card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 12px;
      overflow: hidden;
      cursor: pointer;
      transition: transform 0.2s, box-shadow 0.2s, border-color 0.2s;
      position: relative;
      display: flex;
      flex-direction: column;
    }
    .media-card:hover {
      transform: translateY(-4px);
      border-color: #58a6ff;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    }
    .thumb-wrap {
      width: 100%;
      aspect-ratio: 16 / 10;
      background: #0d1117;
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;
      overflow: hidden;
    }
    .thumb-wrap img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      transition: transform 0.25s ease;
    }
    .media-card:hover .thumb-wrap img {
      transform: scale(1.05);
    }
    .badge-type {
      position: absolute;
      top: 8px;
      right: 8px;
      padding: 2px 7px;
      border-radius: 6px;
      font-size: 10px;
      font-weight: 700;
      background: rgba(0, 0, 0, 0.75);
      backdrop-filter: blur(4px);
      color: #fff;
      border: 1px solid rgba(255, 255, 255, 0.2);
    }
    .badge-anim {
      position: absolute;
      bottom: 8px;
      left: 8px;
      padding: 2px 6px;
      border-radius: 4px;
      font-size: 9px;
      font-weight: 800;
      background: #8957e5;
      color: #fff;
    }
    .card-info {
      padding: 10px 12px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    .card-title {
      font-size: 13px;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      color: var(--text);
    }
    .card-meta {
      font-size: 11px;
      color: var(--text-muted);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    /* List View Table */
    .media-list {
      width: 100%;
      border-collapse: collapse;
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 12px;
      overflow: hidden;
    }
    .media-list th {
      background: #161b22;
      padding: 10px 16px;
      font-size: 12px;
      text-align: left;
      color: var(--text-muted);
      border-bottom: 1px solid var(--card-border);
      font-weight: 600;
    }
    .media-list td {
      padding: 12px 16px;
      font-size: 13px;
      border-bottom: 1px solid var(--card-border);
    }
    .media-list tr:hover td {
      background: var(--card-hover);
      cursor: pointer;
    }

    /* Modals & Lightbox */
    .modal-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.88);
      backdrop-filter: blur(8px);
      display: none;
      align-items: center;
      justify-content: center;
      z-index: 1000;
      padding: 20px;
    }
    .modal-backdrop.open { display: flex; }
    .lightbox-wrap {
      width: 100%;
      height: 100%;
      display: flex;
      flex-direction: column;
      position: relative;
    }
    .lightbox-toolbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 10px 16px;
      background: rgba(22, 27, 34, 0.85);
      border-radius: 12px;
      margin-bottom: 12px;
      backdrop-filter: blur(10px);
      border: 1px solid var(--card-border);
    }
    .lightbox-title {
      font-size: 14px;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      max-width: 50vw;
    }
    .lightbox-viewport {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      overflow: hidden;
      position: relative;
    }
    .lightbox-img {
      max-width: 95%;
      max-height: 82vh;
      object-fit: contain;
      border-radius: 8px;
      transition: transform 0.15s ease-out;
      user-select: none;
      box-shadow: 0 10px 40px rgba(0,0,0,0.6);
    }
    .lightbox-video {
      max-width: 95%;
      max-height: 82vh;
      border-radius: 10px;
      outline: none;
      box-shadow: 0 10px 40px rgba(0,0,0,0.6);
    }
    .lightbox-audio-card {
      background: #161b22;
      border: 1px solid var(--card-border);
      border-radius: 16px;
      padding: 30px;
      text-align: center;
      width: 100%;
      max-width: 480px;
      box-shadow: 0 10px 40px rgba(0,0,0,0.6);
    }
    .lightbox-nav-btn {
      position: absolute;
      top: 50%;
      transform: translateY(-50%);
      background: rgba(22, 27, 34, 0.7);
      border: 1px solid var(--card-border);
      color: #fff;
      font-size: 26px;
      width: 48px;
      height: 48px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      transition: all 0.2s;
      z-index: 10;
    }
    .lightbox-nav-btn:hover {
      background: #388bfd;
      border-color: #58a6ff;
    }
    .lightbox-nav-prev { left: 20px; }
    .lightbox-nav-next { right: 20px; }

    /* Empty state */
    .empty-state {
      text-align: center;
      padding: 60px 20px;
      color: var(--text-muted);
    }
    .empty-state h3 { font-size: 18px; margin-bottom: 8px; color: var(--text); }

    /* Toast */
    #toast {
      position: fixed;
      bottom: 24px;
      right: 24px;
      background: #1f6feb;
      color: #fff;
      padding: 10px 18px;
      border-radius: 8px;
      font-size: 13px;
      font-weight: 500;
      box-shadow: 0 6px 20px rgba(0,0,0,0.4);
      opacity: 0;
      transform: translateY(20px);
      transition: all 0.25s ease;
      z-index: 2000;
      pointer-events: none;
    }
    #toast.show { opacity: 1; transform: translateY(0); }

    /* Drop Zone Banner */
    .drop-overlay {
      position: fixed;
      inset: 0;
      background: rgba(31, 111, 235, 0.4);
      backdrop-filter: blur(4px);
      border: 3px dashed var(--accent);
      z-index: 5000;
      display: none;
      align-items: center;
      justify-content: center;
      font-size: 24px;
      font-weight: 700;
      color: #fff;
    }
    .drop-overlay.active { display: flex; }
  </style>
</head>
<body>
  <div class="drop-overlay" id="drop-overlay">📤 Drop files here to upload to this directory</div>

  <header>
    <div class="brand">
      <span>🖼️ PixWeb</span>
    </div>

    <div class="header-controls">
      <input type="text" id="search-input" class="search-box" placeholder="🔍 Search media in folder..." oninput="filterMedia(this.value)">
      <button class="btn" onclick="triggerUpload()">📤 Upload</button>
      <input type="file" id="file-uploader" style="display:none;" multiple onchange="uploadFiles(this.files)">
      <button class="btn" onclick="openQRModal()">📱 Connect Phone</button>
      <button class="btn btn-icon" id="btn-toggle-view" title="Toggle Grid/List View" onclick="toggleLayout()">☰</button>
      <button class="btn btn-icon" title="Refresh" onclick="loadMedia()">🔄</button>
    </div>
  </header>

  <div class="subnav">
    <div class="breadcrumbs" id="breadcrumbs">
      <span class="crumb-item" onclick="changeDir('')">🏠 Root</span>
    </div>

    <div style="display:flex; align-items:center; gap:12px;">
      <select id="sort-select" class="btn" onchange="handleSortChange(this.value)">
        <option value="name_asc">Sort: Name (A-Z)</option>
        <option value="name_desc">Sort: Name (Z-A)</option>
        <option value="date_desc" selected>Sort: Date (Newest)</option>
        <option value="date_asc">Sort: Date (Oldest)</option>
        <option value="size_desc">Sort: Size (Largest)</option>
        <option value="size_asc">Sort: Size (Smallest)</option>
      </select>
      <div class="stats-badge" id="stats-badge">Loading...</div>
    </div>
  </div>

  <main>
    <div class="folder-section" id="folder-section" style="display:none;">
      <h4 style="font-size:13px; color:var(--text-muted); margin-bottom:8px;">Subdirectories</h4>
      <div class="folder-grid" id="folder-grid"></div>
    </div>

    <div id="media-container" class="media-grid"></div>
    <div class="empty-state" id="empty-state" style="display:none;">
      <h3>No Media Files Found</h3>
      <p>This directory has no images, videos, or audio tracks matching the current filter.</p>
    </div>
  </main>

  <!-- Lightbox Modal -->
  <div class="modal-backdrop" id="lightbox-modal" onclick="if(event.target===this) closeLightbox()">
    <div class="lightbox-wrap">
      <div class="lightbox-toolbar">
        <div class="lightbox-title" id="lightbox-title">Filename</div>
        <div style="display:flex; gap:8px; align-items:center;">
          <button class="btn btn-icon" id="btn-slideshow" onclick="toggleSlideshow()">▶ Slideshow</button>
          <button class="btn btn-icon" id="btn-zoom-in" onclick="zoomImage(0.25)">🔍+</button>
          <button class="btn btn-icon" id="btn-zoom-out" onclick="zoomImage(-0.25)">🔍-</button>
          <button class="btn btn-icon" id="btn-rotate" onclick="rotateImage(90)">↷ Rotate</button>
          <a id="btn-download" href="#" class="btn btn-primary btn-icon">⬇ Download</a>
          <button class="btn btn-icon btn-danger" onclick="deleteCurrentMedia()">🗑 Delete</button>
          <button class="btn btn-icon" onclick="closeLightbox()">✕ Close</button>
        </div>
      </div>

      <div class="lightbox-viewport" id="lightbox-viewport">
        <button class="lightbox-nav-btn lightbox-nav-prev" onclick="navigateMedia(-1)">‹</button>
        <img id="lightbox-img" class="lightbox-img" style="display:none;" />
        <video id="lightbox-video" class="lightbox-video" controls playsinline autoplay style="display:none;"></video>
        <div id="lightbox-audio-card" class="lightbox-audio-card" style="display:none;">
          <div style="font-size:52px; margin-bottom:12px;">🎵</div>
          <h3 id="audio-title" style="margin-bottom:16px;">Audio Title</h3>
          <audio id="lightbox-audio" controls autoplay style="width:100%;"></audio>
        </div>
        <button class="lightbox-nav-btn lightbox-nav-next" onclick="navigateMedia(1)">›</button>
      </div>
    </div>
  </div>

  <!-- QR Modal -->
  <div class="modal-backdrop" id="qr-modal" onclick="if(event.target===this) closeQRModal()">
    <div style="background:#161b22; border:1px solid var(--card-border); border-radius:16px; padding:24px; max-width:400px; width:100%; text-align:center;">
      <h3 style="margin-bottom:12px;">📱 Connect Mobile Device</h3>
      <div id="qr-svg-wrap" style="background:#fff; padding:16px; border-radius:12px; display:inline-flex; margin-bottom:14px;"></div>
      <div style="font-family:monospace; font-size:13px; color:var(--accent); word-break:break-all; margin-bottom:12px;" id="qr-url-text"></div>
      <p style="font-size:12px; color:var(--text-muted); line-height:1.5; margin-bottom:16px;">Scan to open PixWeb on your phone or tablet on the same Wi-Fi network.</p>
      <div style="display:flex; justify-content:center; gap:8px;">
        <button class="btn btn-primary" onclick="copyLink()">📋 Copy Link</button>
        <button class="btn" onclick="closeQRModal()">Done</button>
      </div>
    </div>
  </div>

  <div id="toast"></div>

  <script>
    const serverUrl = window.location.origin;
    let currentDir = '';
    let currentMediaList = [];
    let activeIndex = -1;
    let isGridView = true;
    let currentZoom = 1;
    let currentRotate = 0;
    let slideshowTimer = null;

    function showToast(msg) {
      const t = document.getElementById('toast');
      t.textContent = msg;
      t.classList.add('show');
      setTimeout(() => t.classList.remove('show'), 2500);
    }

    // QR Code Generator (Compact Pure JS implementation)
    function createQR(text) {
      const size = 25;
      const grid = Array.from({length: size}, () => Array(size).fill(null));
      const isFunc = Array.from({length: size}, () => Array(size).fill(false));
      function setFunc(r, c, val) { grid[r][c] = val; isFunc[r][c] = true; }
      function addFinder(or, oc) {
        for (let r = 0; r < 7; r++) {
          for (let c = 0; c < 7; c++) {
            const val = (r === 0 || r === 6 || c === 0 || c === 6 || (r >= 2 && r <= 4 && c >= 2 && c <= 4)) ? 1 : 0;
            setFunc(or + r, oc + c, val);
          }
        }
        for (let i = 0; i < 8; i++) {
          if (or + 7 < size && oc + i < size) setFunc(or + 7, oc + i, 0);
          if (or + i < size && oc + 7 < size) setFunc(or + i, oc + 7, 0);
          if (or - 1 >= 0 && oc + i < size) setFunc(or - 1, oc + i, 0);
          if (or + i < size && oc - 1 >= 0) setFunc(or + i, oc - 1, 0);
        }
      }
      addFinder(0, 0); addFinder(0, size - 7); addFinder(size - 7, 0);
      for (let r = -2; r <= 2; r++) {
        for (let c = -2; c <= 2; c++) {
          setFunc(18 + r, 18 + c, (Math.max(Math.abs(r), Math.abs(c)) === 1) ? 0 : 1);
        }
      }
      for (let i = 8; i < size - 8; i++) {
        if (!isFunc[6][i]) setFunc(6, i, i % 2 === 0 ? 1 : 0);
        if (!isFunc[i][6]) setFunc(i, 6, i % 2 === 0 ? 1 : 0);
      }
      setFunc(size - 8, 8, 1);
      const exp = new Uint8Array(512), log = new Uint8Array(256);
      let x = 1;
      for (let i = 0; i < 255; i++) {
        exp[i] = exp[i + 255] = x; log[x] = i;
        x = (x << 1) ^ (x >= 128 ? 0x11d : 0);
      }
      function gmul(a, b) { return (a === 0 || b === 0) ? 0 : exp[log[a] + log[b]]; }
      let gen = [1];
      for (let i = 0; i < 10; i++) {
        const next = new Array(gen.length + 1).fill(0);
        for (let j = 0; j < gen.length; j++) {
          next[j] ^= gmul(gen[j], exp[i]);
          next[j + 1] ^= gen[j];
        }
        gen = next;
      }
      const data = [];
      data.push(0x40 | (text.length >> 4));
      data.push(((text.length & 0x0f) << 4) | (text.charCodeAt(0) >> 4));
      for (let i = 0; i < text.length - 1; i++) {
        data.push(((text.charCodeAt(i) & 0x0f) << 4) | (text.charCodeAt(i + 1) >> 4));
      }
      data.push(((text.charCodeAt(text.length - 1) & 0x0f) << 4));
      const pad = [0xec, 0x11]; let pidx = 0;
      while (data.length < 34) data.push(pad[pidx++ % 2]);
      const ec = new Array(10).fill(0);
      for (let i = 0; i < data.length; i++) {
        const factor = data[i] ^ ec[0];
        for (let j = 0; j < 9; j++) ec[j] = ec[j + 1] ^ gmul(gen[j], factor);
        ec[9] = gmul(gen[9], factor);
      }
      const allCodewords = data.concat(ec);
      const formatBits = 0x77c4;
      for (let i = 0; i < 15; i++) {
        const bit = (formatBits >> i) & 1;
        if (i < 6) setFunc(8, i, bit);
        else if (i < 8) setFunc(8, i + 1, bit);
        else if (i === 8) setFunc(7, 8, bit);
        else setFunc(14 - i, 8, bit);
        if (i < 8) setFunc(size - 1 - i, bit);
        else setFunc(8, size - 15 + i, bit);
      }
      let bitIdx = 0;
      for (let right = size - 1; right > 0; right -= 2) {
        if (right === 6) right--;
        for (let vert = 0; vert < size; vert++) {
          for (let j = 0; j < 2; j++) {
            const px = right - j;
            const upwards = ((right + 1) & 2) === 0;
            const py = upwards ? size - 1 - vert : vert;
            if (!isFunc[py][px]) {
              const byte = allCodewords[bitIdx >> 3] || 0;
              let val = (byte >> (7 - (bitIdx & 7))) & 1;
              if ((py + px) % 2 === 0) val ^= 1;
              grid[py][px] = val;
              bitIdx++;
            }
          }
        }
      }
      const modSize = 7, padSvg = 14;
      const totalSvg = size * modSize + padSvg * 2;
      let svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${totalSvg} ${totalSvg}" width="${totalSvg}" height="${totalSvg}"><rect width="100%" height="100%" fill="#ffffff"/>`;
      for (let r = 0; r < size; r++) {
        for (let c = 0; c < size; c++) {
          if (grid[r][c] === 1) {
            svg += `<rect x="${padSvg + c * modSize}" y="${padSvg + r * modSize}" width="${modSize}" height="${modSize}" fill="#000000"/>`;
          }
        }
      }
      svg += "</svg>";
      return svg;
    }

    function openQRModal() {
      const url = `http://]===] .. lan_ip .. ":" .. port .. [===[`;
      document.getElementById('qr-svg-wrap').innerHTML = createQR(url);
      document.getElementById('qr-url-text').textContent = url;
      document.getElementById('qr-modal').classList.add('open');
    }
    function closeQRModal() {
      document.getElementById('qr-modal').classList.remove('open');
    }
    function copyLink() {
      const url = document.getElementById('qr-url-text').textContent;
      navigator.clipboard.writeText(url).then(() => showToast('Copied link to clipboard'));
    }

    // Navigation & Data Fetch
    function updateBreadcrumbs() {
      const b = document.getElementById('breadcrumbs');
      let html = `<span class="crumb-item" onclick="changeDir('')">🏠 Root</span>`;
      if (currentDir) {
        const parts = currentDir.split('/');
        let accum = '';
        for (let i = 0; i < parts.length; i++) {
          accum += (accum ? '/' : '') + parts[i];
          const sub = accum;
          html += ` <span>/</span> <span class="crumb-item" onclick="changeDir('${sub}')">${parts[i]}</span>`;
        }
      }
      b.innerHTML = html;
    }

    function changeDir(dir) {
      currentDir = dir;
      updateBreadcrumbs();
      loadMedia();
    }

    async function loadMedia() {
      const sortVal = document.getElementById('sort-select').value;
      const [sortField, sortOrder] = sortVal.split('_');
      const q = document.getElementById('search-input').value.trim();

      const params = new URLSearchParams({
        dir: currentDir,
        sort: sortField,
        order: sortOrder,
        filter: q
      });

      try {
        const res = await fetch(`/api/media?${params}`);
        const data = await res.json();
        currentMediaList = data.media || [];
        renderFolders(data.folders || []);
        renderMedia(currentMediaList);
        updateStatus();
      } catch (e) {
        console.error(e);
        showToast('Failed to load media list');
      }
    }

    async function updateStatus() {
      try {
        const res = await fetch('/api/status');
        const st = await res.json();
        document.getElementById('stats-badge').textContent =
          `${currentMediaList.length} items | Free: ${st.disk_free_fmt}`;
      } catch (e) {}
    }

    function renderFolders(folders) {
      const sec = document.getElementById('folder-section');
      const grid = document.getElementById('folder-grid');
      if (!folders || folders.length === 0) {
        sec.style.display = 'none';
        return;
      }
      sec.style.display = 'block';
      let html = '';
      if (currentDir) {
        const parent = currentDir.includes('/') ? currentDir.substring(0, currentDir.lastIndexOf('/')) : '';
        html += `<div class="folder-card" onclick="changeDir('${parent}')">
          <div class="icon">📁</div>
          <div class="name">.. (Parent Directory)</div>
        </div>`;
      }
      folders.forEach(f => {
        html += `<div class="folder-card" onclick="changeDir('${f.subpath}')">
          <div class="icon">📁</div>
          <div class="name">${f.name}</div>
        </div>`;
      });
      grid.innerHTML = html;
    }

    function renderMedia(media) {
      const container = document.getElementById('media-container');
      const empty = document.getElementById('empty-state');
      if (!media || media.length === 0) {
        container.innerHTML = '';
        empty.style.display = 'block';
        return;
      }
      empty.style.display = 'none';

      if (isGridView) {
        container.className = 'media-grid';
        let html = '';
        media.forEach((item, idx) => {
          const streamUrl = `/media/${encodeURIComponent(item.subpath)}`;
          let thumbContent = '';
          if (item.type === 'image') {
            thumbContent = `<img src="${streamUrl}" loading="lazy" alt="${item.name}">`;
          } else if (item.type === 'video') {
            thumbContent = `<div style="font-size:42px;">🎬</div><div style="position:absolute; bottom:6px; right:8px; font-size:10px; background:rgba(0,0,0,0.7); padding:2px 6px; border-radius:4px;">VIDEO</div>`;
          } else {
            thumbContent = `<div style="font-size:42px;">🎵</div><div style="position:absolute; bottom:6px; right:8px; font-size:10px; background:rgba(0,0,0,0.7); padding:2px 6px; border-radius:4px;">AUDIO</div>`;
          }

          html += `
            <div class="media-card" onclick="openLightbox(${idx})">
              <div class="thumb-wrap">
                ${thumbContent}
                <div class="badge-type">${item.ext}</div>
                ${item.is_animated ? '<div class="badge-anim">GIF</div>' : ''}
              </div>
              <div class="card-info">
                <div class="card-title" title="${item.name}">${item.name}</div>
                <div class="card-meta">
                  <span>${item.size_fmt}</span>
                  <span>${item.date_str}</span>
                </div>
              </div>
            </div>`;
        });
        container.innerHTML = html;
      } else {
        container.className = '';
        let html = `
          <table class="media-list">
            <thead>
              <tr>
                <th style="width:40px;">#</th>
                <th>Name</th>
                <th>Type</th>
                <th>Size</th>
                <th>Date Modified</th>
                <th style="width:120px;">Actions</th>
              </tr>
            </thead>
            <tbody>`;
        media.forEach((item, idx) => {
          html += `
            <tr onclick="openLightbox(${idx})">
              <td style="color:var(--text-muted);">${idx + 1}</td>
              <td style="font-weight:600; color:var(--text);">${item.name}</td>
              <td><span class="badge-type" style="position:static;">${item.ext}</span></td>
              <td>${item.size_fmt}</td>
              <td>${item.date_str}</td>
              <td onclick="event.stopPropagation()">
                <a href="/download/${encodeURIComponent(item.subpath)}" class="btn btn-icon" title="Download">⬇</a>
                <button class="btn btn-icon btn-danger" onclick="deleteMediaItem('${item.subpath}')" title="Delete">🗑</button>
              </td>
            </tr>`;
        });
        html += `</tbody></table>`;
        container.innerHTML = html;
      }
    }

    function toggleLayout() {
      isGridView = !isGridView;
      document.getElementById('btn-toggle-view').textContent = isGridView ? '☰' : '☷';
      renderMedia(currentMediaList);
    }

    function handleSortChange() {
      loadMedia();
    }

    function filterMedia(q) {
      if (!currentMediaList) return;
      const qLower = q.toLowerCase();
      const filtered = currentMediaList.filter(m => m.name.toLowerCase().includes(qLower));
      renderMedia(filtered);
    }

    // Lightbox & Viewer
    function openLightbox(idx) {
      if (idx < 0 || idx >= currentMediaList.length) return;
      activeIndex = idx;
      currentZoom = 1;
      currentRotate = 0;
      const item = currentMediaList[idx];
      const modal = document.getElementById('lightbox-modal');
      const title = document.getElementById('lightbox-title');
      const img = document.getElementById('lightbox-img');
      const video = document.getElementById('lightbox-video');
      const audioCard = document.getElementById('lightbox-audio-card');
      const audio = document.getElementById('lightbox-audio');
      const dl = document.getElementById('btn-download');

      title.textContent = item.name;
      dl.href = `/download/${encodeURIComponent(item.subpath)}`;

      img.style.display = 'none'; img.src = '';
      video.style.display = 'none'; video.pause(); video.src = '';
      audioCard.style.display = 'none'; audio.pause(); audio.src = '';

      const streamUrl = `/media/${encodeURIComponent(item.subpath)}`;

      if (item.type === 'image') {
        img.src = streamUrl;
        img.style.display = 'block';
        img.style.transform = `scale(1) rotate(0deg)`;
      } else if (item.type === 'video') {
        video.src = streamUrl;
        video.style.display = 'block';
      } else if (item.type === 'audio') {
        document.getElementById('audio-title').textContent = item.name;
        audio.src = streamUrl;
        audioCard.style.display = 'block';
      }

      modal.classList.add('open');
    }

    function closeLightbox() {
      if (slideshowTimer) {
        clearInterval(slideshowTimer);
        slideshowTimer = null;
        document.getElementById('btn-slideshow').textContent = '▶ Slideshow';
      }
      document.getElementById('lightbox-video').pause();
      document.getElementById('lightbox-audio').pause();
      document.getElementById('lightbox-modal').classList.remove('open');
      activeIndex = -1;
    }

    function navigateMedia(dir) {
      if (activeIndex === -1 || currentMediaList.length === 0) return;
      let next = activeIndex + dir;
      if (next < 0) next = currentMediaList.length - 1;
      if (next >= currentMediaList.length) next = 0;
      openLightbox(next);
    }

    function zoomImage(delta) {
      currentZoom = Math.max(0.2, Math.min(4, currentZoom + delta));
      const img = document.getElementById('lightbox-img');
      img.style.transform = `scale(${currentZoom}) rotate(${currentRotate}deg)`;
    }

    function rotateImage(deg) {
      currentRotate = (currentRotate + deg) % 360;
      const img = document.getElementById('lightbox-img');
      img.style.transform = `scale(${currentZoom}) rotate(${currentRotate}deg)`;
    }

    function toggleSlideshow() {
      const btn = document.getElementById('btn-slideshow');
      if (slideshowTimer) {
        clearInterval(slideshowTimer);
        slideshowTimer = null;
        btn.textContent = '▶ Slideshow';
      } else {
        btn.textContent = '⏸ Pause';
        slideshowTimer = setInterval(() => {
          navigateMedia(1);
        }, 3500);
      }
    }

    async function deleteCurrentMedia() {
      if (activeIndex === -1) return;
      const item = currentMediaList[activeIndex];
      await deleteMediaItem(item.subpath);
      closeLightbox();
    }

    async function deleteMediaItem(subpath) {
      if (!confirm(`Delete "${subpath}"? This cannot be undone.`)) return;
      try {
        const res = await fetch(`/api/delete?path=${encodeURIComponent(subpath)}`, { method: 'POST' });
        const data = await res.json();
        if (data.ok) {
          showToast('Deleted file successfully');
          loadMedia();
        } else {
          showToast(data.error || 'Delete failed');
        }
      } catch (e) {
        showToast('Error deleting file');
      }
    }

    // File Upload
    function triggerUpload() {
      document.getElementById('file-uploader').click();
    }

    async function uploadFiles(files) {
      if (!files || files.length === 0) return;
      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        showToast(`Uploading ${file.name}...`);
        try {
          const params = new URLSearchParams({
            dir: currentDir,
            name: file.name
          });
          const res = await fetch(`/api/upload?${params}`, {
            method: 'POST',
            body: file
          });
          const data = await res.json();
          if (!data.ok) showToast(`Failed: ${file.name}`);
        } catch (e) {
          showToast(`Error uploading ${file.name}`);
        }
      }
      showToast('Uploads completed');
      loadMedia();
    }

    // Drag and drop upload
    const dropOverlay = document.getElementById('drop-overlay');
    window.addEventListener('dragover', e => {
      e.preventDefault();
      dropOverlay.classList.add('active');
    });
    window.addEventListener('dragleave', e => {
      if (e.relatedTarget === null) dropOverlay.classList.remove('active');
    });
    window.addEventListener('drop', e => {
      e.preventDefault();
      dropOverlay.classList.remove('active');
      if (e.dataTransfer && e.dataTransfer.files.length > 0) {
        uploadFiles(e.dataTransfer.files);
      }
    });

    // Keyboard navigation
    window.addEventListener('keydown', e => {
      const modalOpen = document.getElementById('lightbox-modal').classList.contains('open');
      if (modalOpen) {
        if (e.key === 'ArrowRight' || e.key === 'n' || e.key === 'N') navigateMedia(1);
        else if (e.key === 'ArrowLeft' || e.key === 'p' || e.key === 'P') navigateMedia(-1);
        else if (e.key === 'Escape' || e.key === 'q' || e.key === 'Q') closeLightbox();
        else if (e.key === '+' || e.key === '=') zoomImage(0.25);
        else if (e.key === '-') zoomImage(-0.25);
        else if (e.key === 'r' || e.key === 'R') rotateImage(90);
        else if (e.key === ' ') {
          e.preventDefault();
          toggleSlideshow();
        }
      }
    });

    // Initialize
    updateBreadcrumbs();
    loadMedia();
  </script>
</body>
</html>]===]
end

-- =========================================================================
-- 6. HTTP Server Engine & Request Handler
-- =========================================================================
local function render_banner(port, lan_ip, root_dir, is_utf8)
    if is_utf8 == nil then
        is_utf8 = not is_windows or (kernel32 and kernel32.GetConsoleOutputCP() == 65001)
    end
    local b_tl = is_utf8 and "╔" or "+"
    local b_tr = is_utf8 and "╗" or "+"
    local b_bl = is_utf8 and "╚" or "+"
    local b_br = is_utf8 and "╝" or "+"
    local b_ml = is_utf8 and "╠" or "+"
    local b_mr = is_utf8 and "╣" or "+"
    local b_h  = is_utf8 and "═" or "-"
    local b_v  = is_utf8 and "║" or "|"
    local b_dot = is_utf8 and "•" or "*"
    local b_dash = is_utf8 and "—" or "--"
    local inner_w = 75

    local function pad_row(content)
        local visual_len = #content:gsub("[\128-\191]", "")
        local pad = math.max(0, inner_w - 2 - visual_len)
        return b_v .. "  " .. content .. string.rep(" ", pad) .. b_v
    end

    local title = "PixWeb " .. b_dash .. " In-Browser Media Gallery & Server"
    local title_len = #title:gsub("[\128-\191]", "")
    local t_pad_left = math.max(0, math.floor((inner_w - title_len) / 2))
    local t_pad_right = math.max(0, inner_w - title_len - t_pad_left)
    local t_row = b_v .. string.rep(" ", t_pad_left) .. title .. string.rep(" ", t_pad_right) .. b_v

    local lines = {
        b_tl .. string.rep(b_h, inner_w) .. b_tr,
        t_row,
        b_ml .. string.rep(b_h, inner_w) .. b_mr,
        pad_row(string.format("%s Local:      http://127.0.0.1:%d", b_dot, port)),
        pad_row(string.format("%s LAN WiFi:   http://%s:%d", b_dot, lan_ip, port)),
        pad_row(string.format("%s Media Root: %s", b_dot, root_dir)),
        b_v .. string.rep(" ", inner_w) .. b_v,
        pad_row("Open the link on your browser or phone to view photos, videos & audio!"),
        b_bl .. string.rep(b_h, inner_w) .. b_br,
    }
    return table.concat(lines, "\n")
end

local function run_server(host, port, root_dir)
    root_dir = root_dir or "."
    root_dir = root_dir:gsub("[/\\]+$", "")
    if root_dir == "" then root_dir = "." end

    local lan_ip = get_local_lan_ip()
    local listen_sock = is_windows and ws2.socket(AF_INET, SOCK_STREAM, 0) or C.socket(AF_INET, SOCK_STREAM, 0)
    if listen_sock == INVALID_SOCK or listen_sock < 0 then
        io.stderr:write("Failed to create listening socket\n")
        return false
    end

    local optval = ffi.new("int[1]", 1)
    if is_windows then
        ws2.setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, optval, ffi.sizeof(optval))
    else
        C.setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, optval, ffi.sizeof(optval))
    end

    local bind_addr = ffi.new("struct sockaddr_in")
    bind_addr.sin_family = AF_INET
    bind_addr.sin_port = is_windows and ws2.htons(port) or C.htons(port)
    bind_addr.sin_addr.s_addr = (host == "0.0.0.0") and 0 or (is_windows and ws2.inet_addr(host) or C.inet_addr(host))

    local bind_res = is_windows and ws2.bind(listen_sock, bind_addr, ffi.sizeof(bind_addr)) or C.bind(listen_sock, bind_addr, ffi.sizeof(bind_addr))
    if bind_res ~= 0 then
        io.stderr:write("Failed to bind socket to " .. host .. ":" .. port .. "\n")
        close_socket(listen_sock)
        return false
    end

    local listen_res = is_windows and ws2.listen(listen_sock, 128) or C.listen(listen_sock, 128)
    if listen_res ~= 0 then
        io.stderr:write("Failed to listen on socket\n")
        close_socket(listen_sock)
        return false
    end

    -- Startup banner
    print(render_banner(port, lan_ip, root_dir))
    io.stdout:flush()

    local buf_size = 65536
    local buf = ffi.new("char[?]", buf_size)

    local function send_response(client_sock, status_code, content_type, body, extra_headers)
        local status_text = (status_code == 200 and "OK") or (status_code == 206 and "Partial Content") or (status_code == 404 and "Not Found") or (status_code == 400 and "Bad Request") or "Server Error"
        local header = string.format("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n", status_code, status_text, content_type, #body)
        if extra_headers then
            for k, v in pairs(extra_headers) do
                header = header .. k .. ": " .. v .. "\r\n"
            end
        end
        header = header .. "\r\n"
        local MSG_NOSIGNAL = is_windows and 0 or 0x4000
        if is_windows then
            ws2.send(client_sock, header, #header, 0)
            if #body > 0 then ws2.send(client_sock, body, #body, 0) end
        else
            C.send(client_sock, header, #header, MSG_NOSIGNAL)
            if #body > 0 then C.send(client_sock, body, #body, MSG_NOSIGNAL) end
        end
    end

    local function stream_file_range(client_sock, file_path, mime_type, range_header, is_download)
        local f = io.open(file_path, "rb")
        if not f then
            send_response(client_sock, 404, "application/json", json.encode({ ok = false, error = "File not found" }))
            return
        end
        local total_size = f:seek("end") or 0

        local start_byte = 0
        local end_byte = total_size - 1
        local is_partial = false

        if range_header then
            local r_start, r_end = range_header:match("bytes=(%d+)%-(%d*)")
            if r_start then
                start_byte = tonumber(r_start) or 0
                if r_end and #r_end > 0 then
                    end_byte = math.min(tonumber(r_end) or end_byte, total_size - 1)
                end
                is_partial = true
            end
        end

        if start_byte > end_byte or start_byte >= total_size then
            f:close()
            local headers = { ["Content-Range"] = string.format("bytes */%d", total_size) }
            send_response(client_sock, 416, "text/plain", "Requested Range Not Satisfiable", headers)
            return
        end

        local content_length = (end_byte - start_byte) + 1
        local status_code = is_partial and 206 or 200
        local status_text = is_partial and "Partial Content" or "OK"

        local header = string.format("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\nConnection: close\r\n", status_code, status_text, mime_type, content_length)
        if is_partial then
            header = header .. string.format("Content-Range: bytes %d-%d/%d\r\n", start_byte, end_byte, total_size)
        end
        if is_download then
            local filename = file_path:match("[^/\\]+$") or "file"
            header = header .. string.format('Content-Disposition: attachment; filename="%s"\r\n', filename)
        end
        header = header .. "\r\n"

        local MSG_NOSIGNAL = is_windows and 0 or 0x4000
        if is_windows then
            ws2.send(client_sock, header, #header, 0)
        else
            C.send(client_sock, header, #header, MSG_NOSIGNAL)
        end

        f:seek("set", start_byte)
        local remaining = content_length
        while remaining > 0 do
            local chunk_sz = math.min(remaining, buf_size)
            local chunk = f:read(chunk_sz)
            if not chunk or #chunk == 0 then break end
            local sent_n
            if is_windows then
                sent_n = ws2.send(client_sock, chunk, #chunk, 0)
            else
                sent_n = C.send(client_sock, chunk, #chunk, MSG_NOSIGNAL)
            end
            if not sent_n or sent_n <= 0 then break end
            remaining = remaining - #chunk
        end
        f:close()
    end

    while true do
        local client_addr = ffi.new("struct sockaddr_in")
        local addr_len = ffi.new(is_windows and "int[1]" or "unsigned int[1]", ffi.sizeof(client_addr))
        local client_sock = is_windows and ws2.accept(listen_sock, client_addr, addr_len) or C.accept(listen_sock, client_addr, addr_len)

        if client_sock ~= INVALID_SOCK and client_sock >= 0 then
            local req_raw = ""
            local header_end = nil
            while not header_end do
                local n = is_windows and ws2.recv(client_sock, buf, buf_size, 0) or C.recv(client_sock, buf, buf_size, 0)
                n = tonumber(n)
                if not n or n <= 0 then break end
                req_raw = req_raw .. ffi.string(buf, n)
                header_end = req_raw:find("\r\n\r\n", 1, true)
            end

            if header_end then
                local header_part = req_raw:sub(1, header_end - 1)
                local body_so_far = req_raw:sub(header_end + 4)
                local method, path = header_part:match("^(%u+)%s+([^%s]+)")

                method = method or "GET"
                path = path or "/"
                local url_path, query_str = path:match("^([^?]+)%??(.*)")
                url_path = url_path or path
                query_str = query_str or ""

                local range_hdr = header_part:match("[Rr]ange:%s*([^\r\n]+)")
                local content_length = tonumber(header_part:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
                local needed = content_length - #body_so_far

                if header_part:find("[Ee]xpect:%s*100%-continue") then
                    local cont = "HTTP/1.1 100 Continue\r\n\r\n"
                    local MSG_NOSIGNAL = is_windows and 0 or 0x4000
                    if is_windows then ws2.send(client_sock, cont, #cont, 0) else C.send(client_sock, cont, #cont, MSG_NOSIGNAL) end
                end

                if url_path == "/api/upload" and method == "POST" then
                    local name = query_str:match("name=([^&]+)")
                    local dir_param = query_str:match("dir=([^&]+)") or ""
                    if name then
                        name = name:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                    end
                    if dir_param then
                        dir_param = dir_param:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                    end
                    local clean_dir = sanitize_subpath(dir_param)
                    local safe_target_dir = (clean_dir == "") and root_dir or (root_dir .. "/" .. clean_dir)
                    local safe_file_name = (name and name:match("[^/\\]+$")) or ("upload_" .. os.time() .. ".bin")
                    local dest_path = safe_target_dir .. "/" .. safe_file_name

                    local out_f = io.open(dest_path, "wb")
                    if not out_f then
                        send_response(client_sock, 500, "application/json", json.encode({ ok = false, error = "Cannot write to destination" }))
                    else
                        if #body_so_far > 0 then out_f:write(body_so_far) end
                        while needed > 0 do
                            local to_read = math.min(needed, buf_size)
                            local n = is_windows and ws2.recv(client_sock, buf, to_read, 0) or C.recv(client_sock, buf, to_read, 0)
                            n = tonumber(n)
                            if not n or n <= 0 then break end
                            out_f:write(ffi.string(buf, n))
                            needed = needed - n
                        end
                        out_f:close()
                        send_response(client_sock, 200, "application/json", json.encode({ ok = true, file = safe_file_name }))
                    end
                else
                    -- Non-upload requests
                    local chunks = { body_so_far }
                    while needed > 0 do
                        local to_read = math.min(needed, buf_size)
                        local n = is_windows and ws2.recv(client_sock, buf, to_read, 0) or C.recv(client_sock, buf, to_read, 0)
                        n = tonumber(n)
                        if not n or n <= 0 then break end
                        table.insert(chunks, ffi.string(buf, n))
                        needed = needed - n
                    end
                    local full_body = table.concat(chunks)

                    if url_path == "/" or url_path == "/index.html" then
                        send_response(client_sock, 200, "text/html; charset=utf-8", get_index_html(lan_ip, port, root_dir))
                    elseif url_path == "/api/status" then
                        local disk = get_disk_space(root_dir)
                        local resp = {
                            lan_ip = lan_ip,
                            port = port,
                            root_dir = root_dir,
                            disk_free = disk.disk_free,
                            disk_free_fmt = disk.disk_free_fmt,
                            disk_total = disk.disk_total,
                            disk_total_fmt = disk.disk_total_fmt,
                            disk_used_percent = disk.disk_used_percent,
                            version = PIXWEB_VERSION,
                        }
                        send_response(client_sock, 200, "application/json", json.encode(resp))
                    elseif url_path == "/api/media" then
                        local dir_param = query_str:match("dir=([^&]*)") or ""
                        local sort_param = query_str:match("sort=([^&]*)") or "date"
                        local order_param = query_str:match("order=([^&]*)") or "desc"
                        local filter_param = query_str:match("filter=([^&]*)") or ""
                        local recur_param = query_str:match("recursive=([01])") == "1"

                        if dir_param ~= "" then
                            dir_param = dir_param:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                        end
                        if filter_param ~= "" then
                            filter_param = filter_param:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                        end

                        local media_entries, sub_folders = scan_media_dir(root_dir, dir_param, recur_param, filter_param)

                        -- Sort
                        table.sort(media_entries, function(a, b)
                            if sort_param == "name" then
                                if order_param == "desc" then return a.name:lower() > b.name:lower()
                                else return a.name:lower() < b.name:lower() end
                            elseif sort_param == "size" then
                                if order_param == "desc" then return a.size > b.size
                                else return a.size < b.size end
                            else -- date
                                if order_param == "desc" then return a.mtime > b.mtime
                                else return a.mtime < b.mtime end
                            end
                        end)

                        table.sort(sub_folders, function(a, b) return a.name:lower() < b.name:lower() end)

                        send_response(client_sock, 200, "application/json", json.encode({
                            media = media_entries,
                            folders = sub_folders,
                            dir = dir_param,
                        }))
                    elseif url_path:find("^/media/") then
                        local rel_file = url_path:sub(8)
                        rel_file = rel_file:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                        local safe_sub = sanitize_subpath(rel_file)
                        local full_target = root_dir .. "/" .. safe_sub
                        stream_file_range(client_sock, full_target, get_mime_type(safe_sub), range_hdr, false)
                    elseif url_path:find("^/download/") then
                        local rel_file = url_path:sub(11)
                        rel_file = rel_file:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                        local safe_sub = sanitize_subpath(rel_file)
                        local full_target = root_dir .. "/" .. safe_sub
                        stream_file_range(client_sock, full_target, get_mime_type(safe_sub), range_hdr, true)
                    elseif url_path == "/api/delete" and method == "POST" then
                        local target_file = query_str:match("path=([^&]+)")
                        if target_file then
                            target_file = target_file:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                        end
                        if not target_file or #target_file == 0 then
                            send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = "Path required" }))
                        else
                            local safe_sub = sanitize_subpath(target_file)
                            local full_target = root_dir .. "/" .. safe_sub
                            local rm_res = is_windows and C.remove(full_target) or C.remove(full_target)
                            if rm_res == 0 then
                                send_response(client_sock, 200, "application/json", json.encode({ ok = true }))
                            else
                                send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = "Failed to remove file" }))
                            end
                        end
                    else
                        send_response(client_sock, 404, "application/json", json.encode({ error = "Not Found" }))
                    end
                end
            end
            close_socket(client_sock)
        end
    end
end

-- =========================================================================
-- 7. CLI Entry Point
-- =========================================================================
local function print_help()
    print("pix-web — Standalone Media Gallery & Streaming Server in LuaJIT FFI")
    print("Usage:")
    print("  luajit pix-web.lua [options] [directory]")
    print("")
    print("Options:")
    print("  -p, --port <port>   Set HTTP server port (default: 8060)")
    print("  -H, --host <host>   Set bind host (default: 0.0.0.0)")
    print("  -d, --dir <path>    Root media directory (default: current directory '.')")
    print("  -v, --version       Display version information")
    print("  -h, --help          Show this help message")
    print("")
    print("Features:")
    print("  • Photo, video, and audio playback with range seek")
    print("  • Responsive dark gallery, zoom, pan, rotate, and slideshow lightbox")
    print("  • Drag-and-drop file upload and subfolder navigation")
    print("  • QR Code mobile pairing for instant LAN browsing")
end

local function main()
    local host = "0.0.0.0"
    local port = 8060
    local root_dir = "."

    local i = 1
    local argv = arg or {}
    while i <= #argv do
        local a = argv[i]
        if a == "-h" or a == "--help" then
            print_help()
            os.exit(0)
        elseif a == "-v" or a == "--version" then
            print("pix-web " .. PIXWEB_VERSION)
            os.exit(0)
        elseif a == "-p" or a == "--port" then
            i = i + 1
            port = tonumber(argv[i]) or port
        elseif a:match("^%-%-port=") then
            port = tonumber(a:sub(8)) or port
        elseif a == "-H" or a == "--host" then
            i = i + 1
            host = argv[i] or host
        elseif a:match("^%-%-host=") then
            host = a:sub(8)
        elseif a == "-d" or a == "--dir" then
            i = i + 1
            root_dir = argv[i] or root_dir
        elseif a:match("^%-%-dir=") then
            root_dir = a:sub(7)
        elseif not a:match("^%-") then
            root_dir = a
        end
        i = i + 1
    end

    run_server(host, port, root_dir)
end

if not pcall(debug.getlocal, 4, 1) then
    main()
end

return {
    scan_media_dir = scan_media_dir,
    get_mime_type = get_mime_type,
    sanitize_subpath = sanitize_subpath,
    get_local_lan_ip = get_local_lan_ip,
    get_index_html = get_index_html,
    render_banner = render_banner,
    IMAGE_EXTENSIONS = IMAGE_EXTENSIONS,
    VIDEO_EXTENSIONS = VIDEO_EXTENSIONS,
    AUDIO_EXTENSIONS = AUDIO_EXTENSIONS,
}
