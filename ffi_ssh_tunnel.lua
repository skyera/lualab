#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- ffi_ssh_tunnel.lua
-- High-Performance SSH Tunnel & ProxyJump Config / Tunnel Manager
-- Pure LuaJIT FFI (Zero external dependencies)
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

local is_windows = (ffi.os == "Windows")

if is_windows then
    ffi.cdef[[
        // Win32 Sockets (ws2_32.dll)
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
        int connect(SOCKET s, const void *name, int namelen);
        int closesocket(SOCKET s);
        int setsockopt(SOCKET s, int level, int optname, const void *optval, int optlen);
        int getsockname(SOCKET s, void *name, int *namelen);
        uint32_t inet_addr(const char *cp);

        struct in_addr {
            uint32_t s_addr;
        };
        struct sockaddr_in {
            int16_t        sin_family;
            uint16_t       sin_port;
            struct in_addr sin_addr;
            char           sin_zero[8];
        };

        // Win32 Console & Process (kernel32.dll)
        typedef void *HANDLE;
        typedef uint32_t DWORD;
        typedef int BOOL;

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        DWORD GetFileAttributesA(const char *lpFileName);
        void Sleep(DWORD dwMilliseconds);
        HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
        BOOL TerminateProcess(HANDLE hProcess, uint32_t uExitCode);
        BOOL CloseHandle(HANDLE hObject);

        // Win32 CRT input
        int _kbhit(void);
        int _getch(void);
    ]]
else
    ffi.cdef[[
        // Sockets & Network probing
        int socket(int domain, int type, int protocol);
        int bind(int sockfd, const void *addr, uint32_t addrlen);
        int listen(int sockfd, int backlog);
        int connect(int sockfd, const void *addr, uint32_t addrlen);
        int close(int fd);
        int fcntl(int fd, int cmd, ...);
        int setsockopt(int sockfd, int level, int optname, const void *optval, uint32_t optlen);
        int getsockname(int sockfd, void *addr, uint32_t *addrlen);
        uint32_t inet_addr(const char *cp);

        // Socket address structures
        struct in_addr {
            uint32_t s_addr;
        };
        struct sockaddr_in {
            uint16_t       sin_family;
            uint16_t       sin_port;
            struct in_addr sin_addr;
            char           sin_zero[8];
        };

        // Process & signal management
        int kill(int pid, int sig);

        // POSIX I/O
        int read(int fd, void *buf, size_t count);
        int write(int fd, const void *buf, size_t count);

        // Terminal raw mode (termios)
        typedef unsigned char  cc_t;
        typedef unsigned int   speed_t;
        typedef unsigned int   tcflag_t;

        struct termios {
            tcflag_t c_iflag;
            tcflag_t c_oflag;
            tcflag_t c_cflag;
            tcflag_t c_lflag;
            cc_t     c_line;
            cc_t     c_cc[32];
            speed_t  c_ispeed;
            speed_t  c_ospeed;
        };

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
        int isatty(int fd);
        int access(const char *pathname, int mode);

        // High resolution timer & sleep
        struct timespec {
            long tv_sec;
            long tv_nsec;
        };
        int clock_gettime(int clk_id, struct timespec *tp);
        int usleep(unsigned int usec);
    ]]
end

-- Network socket constants
local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = is_windows and 0xFFFF or 1
local SO_REUSEADDR = is_windows and 0x0004 or 2
local INVALID_SOCKET = is_windows and ffi.cast("uintptr_t", -1) or -1

local TCSANOW = 0
local ICANON  = 2
local ECHO    = 8

-- Windows dynamic libraries
local ws2_32 = nil
local kernel32 = nil
local msvcrt = nil

local function get_kernel32()
    if not kernel32 then
        pcall(function() kernel32 = ffi.load("kernel32") end)
    end
    return kernel32
end

local function get_msvcrt()
    if not msvcrt then
        pcall(function() msvcrt = ffi.load("msvcrt") end)
    end
    return msvcrt
end

local function sleep_ms(ms)
    if is_windows then
        local k32 = get_kernel32()
        if k32 then
            k32.Sleep(ms)
        else
            local t0 = os.clock()
            while os.clock() - t0 < (ms / 1000) do end
        end
    else
        ffi.C.usleep(ms * 1000)
    end
end

local function init_windows_sockets()
    if not is_windows then return true end
    if not ws2_32 then
        local ok, lib = pcall(ffi.load, "ws2_32")
        if not ok then return false, "Failed to load ws2_32.dll" end
        ws2_32 = lib
        local wsaData = ffi.new("WSADATA")
        local res = ws2_32.WSAStartup(0x0202, wsaData)
        if res ~= 0 then
            return false, "WSAStartup failed with code " .. tostring(res)
        end
    end
    return true
end

local function get_sock_api()
    if is_windows then
        init_windows_sockets()
        return ws2_32
    else
        return ffi.C
    end
end

-- ============================================================================
-- 2. Utilities: Byte order, Port Probing, JSON parser/serializer
-- ============================================================================

local function htons(n)
    return bit.bor(bit.lshift(bit.band(n, 0xFF), 8), bit.band(bit.rshift(n, 8), 0xFF))
end

local function ntohs(n)
    return htons(n)
end

-- Fast port availability check using LuaJIT FFI sockets
local function probe_port_available(port, host)
    host = host or "127.0.0.1"
    local sock_api = get_sock_api()
    if not sock_api then
        return false, "network subsystem unavailable"
    end

    local fd = sock_api.socket(AF_INET, SOCK_STREAM, 0)
    if fd == INVALID_SOCKET or fd < 0 then
        return false, "failed to create socket"
    end

    local optval = ffi.new("int[1]", 1)
    sock_api.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, ffi.cast("const void*", optval), ffi.sizeof("int"))

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = htons(port)
    addr.sin_addr.s_addr = sock_api.inet_addr(host)

    local res = sock_api.bind(fd, ffi.cast("const void*", addr), ffi.sizeof("struct sockaddr_in"))
    if is_windows then
        sock_api.closesocket(fd)
    else
        sock_api.close(fd)
    end

    if res == 0 then
        return true, "AVAILABLE"
    else
        return false, "OCCUPIED"
    end
end

-- Find PID holding a local TCP port via system inspection
local function find_pid_by_port(port)
    port = tonumber(port)
    if not port then return nil end

    if is_windows then
        -- netstat -ano -p tcp on Windows (line-by-line check)
        local pipe = io.popen("netstat -ano -p tcp 2>nul")
        if pipe then
            local out = pipe:read("*a") or ""
            pipe:close()
            local port_str = tostring(port)
            for line in out:gmatch("[^\r\n]+") do
                local laddr, faddr, state, pid = line:match("%s*TCP%s+(%S+)%s+(%S+)%s+(%S+)%s+(%d+)")
                if laddr and (laddr:match(":" .. port_str .. "$") or laddr:match(":" .. port_str .. "%s*$")) then
                    local npid = tonumber(pid)
                    if npid and npid > 0 then
                        return npid
                    end
                end
            end
        end
        return nil
    end

    -- POSIX: Try fuser first
    local pipe = io.popen(string.format("fuser %d/tcp 2>/dev/null", port))
    if pipe then
        local out = pipe:read("*a") or ""
        pipe:close()
        local pid = out:match("(%d+)")
        if pid then return tonumber(pid) end
    end

    -- POSIX: Try ss
    local pipe2 = io.popen(string.format("ss -tulpn 2>/dev/null | grep ':%d '", port))
    if pipe2 then
        local out2 = pipe2:read("*a") or ""
        pipe2:close()
        local pid2 = out2:match("pid=(%d+)")
        if pid2 then return tonumber(pid2) end
    end

    -- POSIX: Try lsof
    local pipe3 = io.popen(string.format("lsof -ti tcp:%d 2>/dev/null", port))
    if pipe3 then
        local out3 = pipe3:read("*a") or ""
        pipe3:close()
        local pid3 = out3:match("(%d+)")
        if pid3 then return tonumber(pid3) end
    end

    return nil
end

-- Force terminate a process on Windows using direct Win32 API and multi-stage taskkill fallbacks
local function win32_kill_pid(pid)
    local killed = false
    local k32 = get_kernel32()
    if k32 and k32.OpenProcess and k32.TerminateProcess then
        local PROCESS_TERMINATE = 0x0001
        local hProc = k32.OpenProcess(PROCESS_TERMINATE, 0, pid)
        if hProc ~= nil and hProc ~= ffi.cast("HANDLE", 0) then
            local res = k32.TerminateProcess(hProc, 1)
            k32.CloseHandle(hProc)
            if res ~= 0 then killed = true end
        end
    end
    -- Fallbacks via taskkill: standard and full system root path
    os.execute(string.format("taskkill /F /PID %d >nul 2>&1", pid))
    os.execute(string.format("%%SystemRoot%%\\System32\\taskkill.exe /F /T /PID %d >nul 2>&1", pid))
    return killed
end

-- Release/kill process holding a given port
local function release_port(port, host)
    port = tonumber(port)
    if not port then return false, "Invalid port" end
    host = host or "127.0.0.1"

    local is_free, _ = probe_port_available(port, host)
    if is_free then
        return true, string.format("Port %d is already free.", port)
    end

    local pid = find_pid_by_port(port)

    if is_windows then
        if pid then
            win32_kill_pid(pid)
        else
            -- If PID couldn't be parsed from netstat, try killing any hanging background ssh.exe
            os.execute("taskkill /F /IM ssh.exe >nul 2>&1")
            os.execute("%SystemRoot%\\System32\\taskkill.exe /F /IM ssh.exe >nul 2>&1")
        end

        -- Give Windows TCP stack and kernel up to 400ms to release socket binding
        for _ = 1, 4 do
            sleep_ms(100)
            local now_free = probe_port_available(port, host)
            if now_free then
                if pid then
                    return true, string.format("Terminated PID %d. Port %d is now FREE & AVAILABLE!", pid, port)
                else
                    return true, string.format("Terminated ssh processes. Port %d is now FREE & AVAILABLE!", port)
                end
            end
        end

        -- Check one more time
        local final_free = probe_port_available(port, host)
        if final_free then
            return true, string.format("Port %d is now FREE & AVAILABLE!", port)
        else
            if pid then
                return false, string.format("Attempted to terminate PID %d, but port %d is still in use.", pid, port)
            else
                return false, string.format("Could not determine PID holding port %d to terminate.", port)
            end
        end
    end

    -- POSIX termination logic
    if not pid then
        -- Fallback to fuser -k
        os.execute(string.format("fuser -k %d/tcp >/dev/null 2>&1", port))
        sleep_ms(150)
        local now_free = probe_port_available(port, host)
        if now_free then
            return true, string.format("Port %d successfully released via fuser!", port)
        else
            return false, string.format("Could not determine PID holding port %d to terminate.", port)
        end
    end

    -- Get process name
    local comm = ""
    local f_comm = io.open(string.format("/proc/%d/comm", pid), "r")
    if f_comm then
        comm = f_comm:read("*l") or ""
        f_comm:close()
    end

    -- Terminate process gracefully first with SIGTERM (15)
    ffi.C.kill(pid, 15)
    sleep_ms(150)

    -- If still alive, terminate with SIGKILL (9)
    local now_free = probe_port_available(port, host)
    if not now_free then
        ffi.C.kill(pid, 9)
        sleep_ms(200)
    end

    now_free = probe_port_available(port, host)
    if now_free then
        local name_info = #comm > 0 and string.format(" (%s)", comm) or ""
        return true, string.format("Terminated PID %d%s. Port %d is now FREE & AVAILABLE!", pid, name_info, port)
    else
        return false, string.format("Sent kill signal to PID %d, but port %d is still in use.", pid, port)
    end
end

-- Minimalist, robust JSON encoder / decoder for standalone usage
local json = {}

local function escape_str(s)
    local matches = {
        ['\\'] = '\\\\',
        ['"']  = '\\"',
        ['\b'] = '\\b',
        ['\f'] = '\\f',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t',
    }
    return s:gsub('[\\"\b\f\n\r\t]', matches)
end

function json.encode(val, indent, depth)
    indent = indent or false
    depth = depth or 0
    local tab = indent and string.rep("  ", depth) or ""
    local next_tab = indent and string.rep("  ", depth + 1) or ""
    local nl = indent and "\n" or ""
    local sp = indent and " " or ""

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
        local n = 0
        for k, _ in pairs(val) do
            n = n + 1
            if type(k) ~= "number" or k ~= n then
                is_array = false
                break
            end
        end

        if is_array then
            if #val == 0 then return "[]" end
            local parts = {}
            for i = 1, #val do
                parts[i] = next_tab .. json.encode(val[i], indent, depth + 1)
            end
            return "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. tab .. "]"
        else
            local count = 0
            for _ in pairs(val) do count = count + 1 end
            if count == 0 then return "{}" end

            local keys = {}
            for k in pairs(val) do table.insert(keys, tostring(k)) end
            table.sort(keys)

            local parts = {}
            for _, k in ipairs(keys) do
                table.insert(parts, next_tab .. '"' .. escape_str(k) .. '":' .. sp .. json.encode(val[k], indent, depth + 1))
            end
            return "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. tab .. "}"
        end
    else
        return '"' .. tostring(val) .. '"'
    end
end

function json.decode(str)
    -- Clean comments if any
    local pos = 1
    local len = #str

    local function skip_whitespace()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1 -- skip opening quote
        local s = ""
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return s
            elseif c == '\\' then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == '"' then s = s .. '"'
                elseif esc == '\\' then s = s .. '\\'
                elseif esc == '/' then s = s .. '/'
                elseif esc == 'b' then s = s .. '\b'
                elseif esc == 'f' then s = s .. '\f'
                elseif esc == 'n' then s = s .. '\n'
                elseif esc == 'r' then s = s .. '\r'
                elseif esc == 't' then s = s .. '\t'
                elseif esc == 'u' then
                    local hex = str:sub(pos + 1, pos + 4)
                    local code = tonumber(hex, 16) or 0
                    if code < 128 then
                        s = s .. string.char(code)
                    else
                        s = s .. "?"
                    end
                    pos = pos + 4
                else
                    s = s .. esc
                end
                pos = pos + 1
            else
                s = s .. c
                pos = pos + 1
            end
        end
        return s
    end

    local function parse_number()
        local s_start = pos
        while pos <= len do
            local c = str:sub(pos, pos)
            if c:match("[0-9%.%-%+eE]") then
                pos = pos + 1
            else
                break
            end
        end
        local num_str = str:sub(s_start, pos - 1)
        return tonumber(num_str) or 0
    end

    local function parse_array()
        pos = pos + 1 -- skip '['
        local arr = {}
        skip_whitespace()
        if pos <= len and str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end

        while pos <= len do
            local val = parse_value()
            table.insert(arr, val)
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == ']' then
                pos = pos + 1
                break
            elseif c == ',' then
                pos = pos + 1
                skip_whitespace()
            else
                pos = pos + 1
            end
        end
        return arr
    end

    local function parse_object()
        pos = pos + 1 -- skip '{'
        local obj = {}
        skip_whitespace()
        if pos <= len and str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end

        while pos <= len do
            skip_whitespace()
            if str:sub(pos, pos) ~= '"' then break end
            local key = parse_string()
            skip_whitespace()
            if str:sub(pos, pos) == ':' then
                pos = pos + 1
            end
            local val = parse_value()
            obj[key] = val
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == '}' then
                pos = pos + 1
                break
            elseif c == ',' then
                pos = pos + 1
                skip_whitespace()
            else
                pos = pos + 1
            end
        end
        return obj
    end

    function parse_value()
        skip_whitespace()
        if pos > len then return nil end
        local c = str:sub(pos, pos)
        if c == '"' then
            return parse_string()
        elseif c == '{' then
            return parse_object()
        elseif c == '[' then
            return parse_array()
        elseif c == 't' and str:sub(pos, pos + 3) == 'true' then
            pos = pos + 4
            return true
        elseif c == 'f' and str:sub(pos, pos + 4) == 'false' then
            pos = pos + 5
            return false
        elseif c == 'n' and str:sub(pos, pos + 3) == 'null' then
            pos = pos + 4
            return nil
        else
            return parse_number()
        end
    end

    return parse_value()
end

-- ============================================================================
-- 3. Profile Management & Command Generation
-- ============================================================================

local DEFAULT_CONFIG_PATH = os.getenv("SSH_TUNNEL_CONFIG") or (function()
    if is_windows then
        local base = os.getenv("USERPROFILE") or os.getenv("LOCALAPPDATA") or os.getenv("APPDATA") or "C:"
        return base:gsub("\\", "/") .. "/.config/lualab/ssh_tunnels.json"
    else
        return (os.getenv("HOME") or "/tmp") .. "/.config/lualab/ssh_tunnels.json"
    end
end)()

local MUX_DIR = (function()
    if is_windows then
        local tmp = os.getenv("TEMP") or os.getenv("TMP") or "C:/Windows/Temp"
        return tmp:gsub("\\", "/")
    else
        return "/tmp"
    end
end)()

local function ensure_dir(path)
    local dir = path:gsub("/[^/]+$", "")
    if is_windows then
        local win_dir = dir:gsub("/", "\\")
        os.execute('if not exist "' .. win_dir .. '" mkdir "' .. win_dir .. '" >nul 2>&1')
    else
        os.execute("mkdir -p '" .. dir .. "' 2>/dev/null")
    end
end

local function get_mux_socket_path(profile_name)
    local safe_name = profile_name:gsub("[^%w_%-]", "_")
    return string.format("%s/ssh_mux_%s", MUX_DIR, safe_name)
end

-- Build SSH command from profile
local function build_ssh_command(p, extra_flags)
    local parts = {"ssh", "-N"}
    if not is_windows then
        table.insert(parts, "-f")
        -- ControlMaster multiplexing (POSIX only)
        local mux_path = get_mux_socket_path(p.name)
        table.insert(parts, "-M")
        table.insert(parts, "-S")
        table.insert(parts, mux_path)
    end
    table.insert(parts, "-o")
    table.insert(parts, "ExitOnForwardFailure=yes")

    -- ProxyJump (-J)
    if p.proxy_jump and p.proxy_jump:match("%S+") then
        table.insert(parts, "-J")
        table.insert(parts, (p.proxy_jump:gsub("%s+", "")))
    end

    -- Identity key (-i)
    if p.identity_key and #p.identity_key > 0 then
        table.insert(parts, "-i")
        table.insert(parts, p.identity_key)
    end

    -- Custom SSH port
    if p.ssh_port and tonumber(p.ssh_port) and tonumber(p.ssh_port) ~= 22 then
        table.insert(parts, "-p")
        table.insert(parts, tostring(p.ssh_port))
    end

    -- Tunnel Mode (-L, -R, -D)
    local mode = (p.type or "local"):lower()
    if mode == "local" or mode == "-l" then
        local bind = p.local_bind or "127.0.0.1"
        local lport = tonumber(p.local_port) or 0
        local rhost = p.remote_host or "127.0.0.1"
        local rport = tonumber(p.remote_port) or 0
        table.insert(parts, "-L")
        table.insert(parts, string.format("%s:%d:%s:%d", bind, lport, rhost, rport))
    elseif mode == "remote" or mode == "-r" then
        local rbind = p.remote_bind or "0.0.0.0"
        local rport = tonumber(p.remote_port) or 0
        local lhost = p.local_host or "127.0.0.1"
        local lport = tonumber(p.local_port) or 0
        table.insert(parts, "-R")
        table.insert(parts, string.format("%s:%d:%s:%d", rbind, rport, lhost, lport))
    elseif mode == "socks" or mode == "dynamic" or mode == "-d" then
        local bind = p.local_bind or "127.0.0.1"
        local lport = tonumber(p.local_port) or 0
        table.insert(parts, "-D")
        table.insert(parts, string.format("%s:%d", bind, lport))
    end

    if extra_flags then
        for _, f in ipairs(extra_flags) do
            table.insert(parts, f)
        end
    end

    -- Target host
    local target = ""
    if p.ssh_user and #p.ssh_user > 0 then
        target = p.ssh_user .. "@"
    end
    target = target .. (p.ssh_host or "localhost")
    table.insert(parts, target)

    return parts
end

local function command_parts_to_string(parts)
    local quoted = {}
    for _, part in ipairs(parts) do
        if part:match("[^%w_%-%.%/:%@,=]") then
            table.insert(quoted, "'" .. part:gsub("'", "'\\''") .. "'")
        else
            table.insert(quoted, part)
        end
    end
    return table.concat(quoted, " ")
end

local function wrap_command_lines(cmd_str, max_width)
    max_width = max_width or 70
    local words = {}
    for w in cmd_str:gmatch("%S+") do
        table.insert(words, w)
    end
    if #words == 0 then return {""} end

    local lines = {}
    local cur_line = words[1]
    for i = 2, #words do
        local w = words[i]
        if #cur_line + 1 + #w <= max_width then
            cur_line = cur_line .. " " .. w
        else
            table.insert(lines, cur_line)
            cur_line = w
        end
    end
    table.insert(lines, cur_line)
    return lines
end

local function file_exists(path)
    if is_windows then
        local k32 = get_kernel32()
        if k32 then
            local attr = k32.GetFileAttributesA(path)
            return attr ~= 0xFFFFFFFF
        end
        local f = io.open(path, "r")
        if f then f:close(); return true end
        return false
    else
        return ffi.C.access(path, 0) == 0
    end
end

-- Check live status of a profile (via OpenSSH control socket or local port fallback)
local function get_tunnel_status(profile_or_name)
    local p = (type(profile_or_name) == "table") and profile_or_name or nil
    local profile_name = p and p.name or profile_or_name
    local mux_path = get_mux_socket_path(profile_name)

    -- Strategy 1: Check ControlMaster socket (Linux/macOS)
    if file_exists(mux_path) then
        local cmd = string.format("ssh -O check -S '%s' dummy_host 2>&1", mux_path)
        local pipe = io.popen(cmd)
        local output = pipe and pipe:read("*a") or ""
        if pipe then pipe:close() end

        local pid = output:match("pid=(%d+)")
        if pid then
            return { is_up = true, status = "UP", pid = tonumber(pid) }
        elseif output:lower():match("running") then
            return { is_up = true, status = "UP", pid = nil }
        end
    end

    -- Strategy 2: Fallback to local listening port inspection (Windows or direct background tunnels)
    if p and p.local_port then
        local port = tonumber(p.local_port)
        if port then
            local pid = find_pid_by_port(port)
            if pid then
                return { is_up = true, status = "UP", pid = pid }
            end
        end
    end

    return { is_up = false, status = "DOWN", pid = nil }
end

-- Stop a tunnel gracefully via ssh -O exit or port termination
local function stop_tunnel(profile_or_name)
    local p = (type(profile_or_name) == "table") and profile_or_name or nil
    local profile_name = p and p.name or profile_or_name
    local mux_path = get_mux_socket_path(profile_name)
    local out = ""

    if file_exists(mux_path) then
        local cmd = string.format("ssh -O exit -S '%s' dummy_host 2>&1", mux_path)
        local pipe = io.popen(cmd)
        out = pipe and pipe:read("*a") or ""
        if pipe then pipe:close() end
        os.remove(mux_path)
    end

    -- If profile has local port, ensure port is released
    if p and p.local_port then
        local port = tonumber(p.local_port)
        if port then
            local ok_free, _ = probe_port_available(port, p.local_bind)
            if not ok_free then
                local _, rel_msg = release_port(port, p.local_bind)
                if #out > 0 then out = out .. " " .. rel_msg else out = rel_msg end
            end
        end
    end

    return out
end

-- Build interactive SSH shell command (reusing active ControlMaster socket if UP)
local function build_interactive_ssh_command(p, extra_cmd_args)
    local parts = {"ssh"}

    -- Check if mux socket exists and is UP
    local st = get_tunnel_status(p.name)
    local mux_path = get_mux_socket_path(p.name)
    if st.is_up then
        table.insert(parts, "-S")
        table.insert(parts, mux_path)
    else
        -- ProxyJump (-J)
        if p.proxy_jump and p.proxy_jump:match("%S+") then
            table.insert(parts, "-J")
            table.insert(parts, (p.proxy_jump:gsub("%s+", "")))
        end

        -- Identity key (-i)
        if p.identity_key and #p.identity_key > 0 then
            table.insert(parts, "-i")
            table.insert(parts, p.identity_key)
        end

        -- Custom SSH port
        if p.ssh_port and tonumber(p.ssh_port) and tonumber(p.ssh_port) ~= 22 then
            table.insert(parts, "-p")
            table.insert(parts, tostring(p.ssh_port))
        end
    end

    -- Target host
    local target = ""
    if p.ssh_user and #p.ssh_user > 0 then
        target = p.ssh_user .. "@"
    end
    target = target .. (p.ssh_host or "localhost")
    table.insert(parts, target)

    -- Extra remote command arguments (if any)
    if extra_cmd_args and #extra_cmd_args > 0 then
        for _, arg in ipairs(extra_cmd_args) do
            table.insert(parts, arg)
        end
    end

    return parts
end

-- Start a tunnel
local function start_tunnel(p)
    -- First check port conflicts if local or socks
    local mode = (p.type or "local"):lower()
    if mode == "local" or mode == "socks" or mode == "dynamic" then
        local port = tonumber(p.local_port) or 8080
        local host = p.local_bind or "127.0.0.1"
        local ok, reason = probe_port_available(port, host)
        if not ok then
            return false, string.format("Local port %d is already %s!", port, reason)
        end
    end

    local parts = build_ssh_command(p)
    local cmd = command_parts_to_string(parts)
    if is_windows then
        cmd = 'start /B "" ' .. cmd
    end
    local ret = os.execute(cmd)
    if ret == 0 then
        -- Small pause to allow socket creation / port binding
        sleep_ms(250)
        local status = get_tunnel_status(p)
        if status.is_up then
            return true, string.format("Tunnel '%s' active! (PID %s)", p.name, tostring(status.pid or "unknown"))
        else
            return true, string.format("Tunnel '%s' launched (socket initialized).", p.name)
        end
    else
        return false, string.format("SSH command exited with error code %s: %s", tostring(ret), cmd)
    end
end

-- Load or create default configuration
local function load_profiles(filepath)
    filepath = filepath or DEFAULT_CONFIG_PATH
    local f = io.open(filepath, "r")
    if not f then
        return { profiles = {} }
    end
    local content = f:read("*a")
    f:close()
    local data = json.decode(content)
    if not data or not data.profiles then
        data = { profiles = {} }
    end
    return data
end

local function save_profiles(data, filepath)
    filepath = filepath or DEFAULT_CONFIG_PATH
    ensure_dir(filepath)
    local content = json.encode(data, true)
    local f, err = io.open(filepath, "w")
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
end

-- Export OpenSSH config block
local function export_ssh_config(profiles)
    local lines = {
        "# ==================================================================",
        "# Generated by LuaJIT SSH Tunnel Manager (ffi_ssh_tunnel.lua)",
        "# ==================================================================",
        ""
    }
    for _, p in ipairs(profiles) do
        table.insert(lines, string.format("Host tunnel-%s", p.name))
        table.insert(lines, string.format("  HostName %s", p.ssh_host or "localhost"))
        if p.ssh_user and #p.ssh_user > 0 then
            table.insert(lines, string.format("  User %s", p.ssh_user))
        end
        if p.ssh_port and tonumber(p.ssh_port) ~= 22 then
            table.insert(lines, string.format("  Port %d", tonumber(p.ssh_port)))
        end
        if p.proxy_jump and p.proxy_jump:match("%S+") then
            table.insert(lines, string.format("  ProxyJump %s", (p.proxy_jump:gsub("%s+", ""))))
        end
        if p.identity_key and #p.identity_key > 0 then
            table.insert(lines, string.format("  IdentityFile %s", p.identity_key))
        end

        local mode = (p.type or "local"):lower()
        if mode == "local" then
            table.insert(lines, string.format("  LocalForward %s:%d %s:%d",
                p.local_bind or "127.0.0.1", p.local_port or 8080,
                p.remote_host or "127.0.0.1", p.remote_port or 8080))
        elseif mode == "remote" then
            table.insert(lines, string.format("  RemoteForward %s:%d %s:%d",
                p.remote_bind or "0.0.0.0", p.remote_port or 8080,
                p.local_host or "127.0.0.1", p.local_port or 8080))
        elseif mode == "socks" or mode == "dynamic" then
            table.insert(lines, string.format("  DynamicForward %s:%d",
                p.local_bind or "127.0.0.1", p.local_port or 1080))
        end

        table.insert(lines, string.format("  ControlMaster auto"))
        table.insert(lines, string.format("  ControlPath %s", get_mux_socket_path(p.name)))
        table.insert(lines, "  ExitOnForwardFailure yes")
        table.insert(lines, "")
    end
    return table.concat(lines, "\n")
end

-- ============================================================================
-- 4. Interactive Terminal UI (TUI) & Forms
-- ============================================================================

local TUI = {}

local orig_win_in_mode = nil
local orig_win_out_mode = nil

function TUI.set_raw_mode(enable)
    if is_windows then
        local k32 = get_kernel32()
        if not k32 then return end
        local STD_INPUT_HANDLE = ffi.cast("uint32_t", -10)
        local STD_OUTPUT_HANDLE = ffi.cast("uint32_t", -11)
        local hIn = k32.GetStdHandle(STD_INPUT_HANDLE)
        local hOut = k32.GetStdHandle(STD_OUTPUT_HANDLE)

        if enable then
            local in_mode = ffi.new("DWORD[1]")
            local out_mode = ffi.new("DWORD[1]")
            if k32.GetConsoleMode(hIn, in_mode) ~= 0 then
                orig_win_in_mode = in_mode[0]
                -- ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200
                -- Clear ENABLE_LINE_INPUT (0x0002) and ENABLE_ECHO_INPUT (0x0004)
                local new_in = bit.band(in_mode[0], bit.bnot(0x0002 + 0x0004))
                new_in = bit.bor(new_in, 0x0200)
                k32.SetConsoleMode(hIn, new_in)
            end
            if k32.GetConsoleMode(hOut, out_mode) ~= 0 then
                orig_win_out_mode = out_mode[0]
                -- ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
                local new_out = bit.bor(out_mode[0], 0x0004)
                k32.SetConsoleMode(hOut, new_out)
            end
        else
            if orig_win_in_mode then
                k32.SetConsoleMode(hIn, orig_win_in_mode)
            end
            if orig_win_out_mode then
                k32.SetConsoleMode(hOut, orig_win_out_mode)
            end
        end
        return
    end

    local termios = ffi.new("struct termios")
    if ffi.C.tcgetattr(0, termios) ~= 0 then return end
    if enable then
        termios.c_lflag = bit.band(termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        ffi.C.tcsetattr(0, TCSANOW, termios)
    else
        termios.c_lflag = bit.bor(termios.c_lflag, bit.bor(ICANON, ECHO))
        ffi.C.tcsetattr(0, TCSANOW, termios)
    end
end

function TUI.read_key()
    if is_windows then
        local crt = get_msvcrt()
        if crt then
            local c = crt._getch()
            if c == 0 or c == 224 then
                local code = crt._getch()
                if code == 72 then return "UP"
                elseif code == 80 then return "DOWN"
                elseif code == 75 then return "LEFT"
                elseif code == 77 then return "RIGHT"
                elseif code == 15 then return "SHIFT_TAB"
                end
            elseif c == 13 or c == 10 then
                return "ENTER"
            elseif c == 27 then
                return "ESC"
            elseif c == 9 then
                return "TAB"
            elseif c == 8 then
                return "BACKSPACE"
            elseif c == 21 then
                return "CTRL_U"
            elseif c == 19 then
                return "CTRL_S"
            else
                return string.char(c)
            end
        end
        -- Fallback to standard input read
        local ch = io.read(1)
        if ch == "\r" or ch == "\n" then return "ENTER"
        elseif ch == "\27" then return "ESC"
        elseif ch == "\t" then return "TAB"
        elseif ch == "\8" then return "BACKSPACE"
        elseif ch == "\21" then return "CTRL_U"
        elseif ch == "\19" then return "CTRL_S"
        else return ch end
    end

    local buf = ffi.new("char[16]")
    local n = ffi.C.read(0, buf, 16)
    if n <= 0 then return nil end
    local s = ffi.string(buf, n)
    if s == "\27[A" then return "UP"
    elseif s == "\27[B" then return "DOWN"
    elseif s == "\27[C" then return "RIGHT"
    elseif s == "\27[D" then return "LEFT"
    elseif s == "\27" then return "ESC"
    elseif s == "\r" or s == "\n" then return "ENTER"
    elseif s == "\t" then return "TAB"
    elseif s == "\27[Z" then return "SHIFT_TAB"
    elseif s == "\127" or s == "\8" then return "BACKSPACE"
    elseif s == "\21" then return "CTRL_U"
    elseif s == "\19" then return "CTRL_S"
    else return s end
end

function TUI.clear()
    -- Reposition to top-left and clear to end of screen without full blanking
    io.write("\27[H\27[J")
    io.flush()
end

function TUI.hide_cursor()
    io.write("\27[?25l")
    io.flush()
end

function TUI.show_cursor()
    io.write("\27[?25h")
    io.flush()
end

local function visual_len(s)
    local clean = tostring(s):gsub("\27%[[%d;]*[mK]", "")
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function pad_right(s, width)
    local vlen = visual_len(s)
    if vlen >= width then return s end
    return s .. string.rep(" ", width - vlen)
end

-- Render the Main Dashboard (Flicker-Free with single-pass buffered output)
function TUI.render_dashboard(profiles, cursor_idx, status_msg)
    local out_buf = {}
    local function emit(str)
        table.insert(out_buf, str)
    end

    -- Move cursor to top-left (1,1) without erasing entire screen (eradicates terminal flash)
    emit("\27[H")

    local W = 100
    local line_sep = string.rep("─", W)
    local line_box = string.rep("═", W)

    emit("\27[1;36m╔" .. line_box .. "╗\27[0m\27[K\n")
    local title_content = pad_right("🚀 LuaJIT SSH Tunnel & ProxyJump Studio", W - 2)
    emit(string.format("\27[1;36m║\27[1;37m %s \27[1;36m║\27[0m\27[K\n", title_content))
    local meta_str = string.format("Profiles: %-2d │ Socket Mux: %-30s │ OS: %s",
        #profiles, MUX_DIR .. "/ssh_mux_*", ffi.os)
    emit(string.format("\27[1;36m║\27[0;33m %s \27[1;36m║\27[0m\27[K\n", pad_right(meta_str, W - 2)))
    emit("\27[1;36m╠" .. line_sep .. "╣\27[0m\27[K\n")

    -- Header row
    local hdr_row = "║ " .. pad_right("#", 4) .. " │ "
                         .. pad_right("Profile Name", 18) .. " │ "
                         .. pad_right("Type", 10) .. " │ "
                         .. pad_right("Local Endpoint", 18) .. " │ "
                         .. pad_right("Target / Route", 22) .. " │ "
                         .. pad_right("Status", 10) .. " ║"
    emit("\27[1;37m" .. hdr_row .. "\27[0m\27[K\n")
    emit("\27[1;36m╟" .. line_sep .. "╢\27[0m\27[K\n")

    if #profiles == 0 then
        local empty_msg = pad_right("  (No profiles configured. Press [n] to create a new profile!)", W - 2)
        emit(string.format("║ %s ║\27[K\n", empty_msg))
    else
        for i, p in ipairs(profiles) do
            local marker = (i == cursor_idx) and "▶" or " "
            local st = get_tunnel_status(p)
            local status_str = st.is_up and "\27[1;32m● UP\27[0m" or "\27[1;31m○ DOWN\27[0m"

            local type_str = (p.type or "local"):upper()
            if type_str == "LOCAL" then type_str = "-L Local"
            elseif type_str == "REMOTE" then type_str = "-R Remot"
            elseif type_str == "SOCKS" or type_str == "DYNAMIC" then type_str = "-D Socks"
            end

            local local_ep = string.format("%s:%s", p.local_bind or "127.0.0.1", tostring(p.local_port or "8080"))
            if (p.type or ""):lower() == "remote" then
                local_ep = string.format("%s:%s", p.local_host or "127.0.0.1", tostring(p.local_port or "8080"))
            end

            local target_ep = string.format("%s:%s", p.remote_host or "-", tostring(p.remote_port or "-"))
            if (p.type or ""):lower() == "socks" then
                target_ep = "[Dynamic SOCKS5]"
            end

            local c1 = pad_right(string.format("%s %d", marker, i), 4)
            local c2 = pad_right(p.name:sub(1, 18), 18)
            local c3 = pad_right(type_str:sub(1, 10), 10)
            local c4 = pad_right(local_ep:sub(1, 18), 18)
            local c5 = pad_right(target_ep:sub(1, 22), 22)
            local c6 = pad_right(status_str, 10)

            local row_line = "║ " .. c1 .. " │ " .. c2 .. " │ " .. c3 .. " │ " .. c4 .. " │ " .. c5 .. " │ " .. c6 .. " ║"
            if i == cursor_idx then
                emit("\27[1;33m" .. row_line .. "\27[0m\27[K\n")
            else
                emit(row_line .. "\27[K\n")
            end
        end
    end

    emit("\27[1;36m╠" .. line_sep .. "╣\27[0m\27[K\n")

    -- Details & Route Inspection for selected profile
    local sel = profiles[cursor_idx]
    if sel then
        local jump_str = (sel.proxy_jump and #sel.proxy_jump > 0) and sel.proxy_jump or "(Direct / None)"
        local ssh_tgt = string.format("%s@%s:%s", sel.ssh_user or "", sel.ssh_host or "localhost", tostring(sel.ssh_port or 22))
        local cmd = command_parts_to_string(build_ssh_command(sel))
        local route_content = pad_right(string.format("\27[1;34mRoute Detail:\27[0m ProxyJump: %-30s SSH Host: %s", jump_str:sub(1, 30), ssh_tgt), W - 2)
        emit(string.format("║ %s ║\27[K\n", route_content))

        local wrapped = wrap_command_lines(cmd, W - 16)
        for line_idx, line_txt in ipairs(wrapped) do
            local prefix = (line_idx == 1) and "\27[1;34mCommand:     \27[0;37m" or "             \27[0;37m"
            local suffix = (line_idx < #wrapped) and " \\" or ""
            local display_txt = pad_right(prefix .. line_txt .. suffix, W - 2)
            emit(string.format("║ %s\27[0m ║\27[K\n", display_txt))
        end
        emit("\27[1;36m╠" .. line_sep .. "╣\27[0m\27[K\n")
    end

    -- Keybindings help bar
    local keys_bar = pad_right("\27[1;32m[Enter]\27[0m Toggle  \27[1;32m[s]\27[0m Connect  \27[1;32m[n]\27[0m New  \27[1;32m[e]\27[0m Edit  \27[1;32m[k]\27[0m Release Port  \27[1;32m[v]\27[0m View Cmd  \27[1;32m[d]\27[0m Del  \27[1;31m[q]\27[0m Quit", W - 2)
    emit(string.format("║ %s ║\27[K\n", keys_bar))
    emit("\27[1;36m╚" .. line_box .. "╝\27[0m\27[K\n")

    if status_msg and #status_msg > 0 then
        emit(string.format("\27[1;33m[STATUS] %s\27[0m\27[K\n", status_msg))
    else
        emit("\27[K\n")
    end
    -- Erase any trailing lines below if list shrank
    emit("\27[J")

    io.write(table.concat(out_buf))
    io.flush()
end

-- Interactive Edit / Create Profile Modal (Flicker-Free, High-Definition Editable Fields)
function TUI.edit_profile_modal(existing_profile)
    local p = {
        name = existing_profile and existing_profile.name or "new-tunnel",
        type = existing_profile and existing_profile.type or "local",
        local_bind = existing_profile and existing_profile.local_bind or "127.0.0.1",
        local_port = existing_profile and existing_profile.local_port or 8080,
        remote_host = existing_profile and existing_profile.remote_host or "127.0.0.1",
        remote_port = existing_profile and existing_profile.remote_port or 8080,
        ssh_user = existing_profile and existing_profile.ssh_user or "ubuntu",
        ssh_host = existing_profile and existing_profile.ssh_host or "server.example.com",
        ssh_port = existing_profile and existing_profile.ssh_port or 22,
        proxy_jump = existing_profile and existing_profile.proxy_jump or "",
        identity_key = existing_profile and existing_profile.identity_key or ""
    }

    local fields = {
        { key = "name",        label = "Profile Name",       badge = "[TEXT]  ", type = "text" },
        { key = "type",        label = "Tunnel Type",        badge = "[CHOICE]", type = "choice", options = {"local", "remote", "socks"} },
        { key = "local_bind",  label = "Local Bind Host",    badge = "[HOST]  ", type = "text" },
        { key = "local_port",  label = "Local Port",         badge = "[PORT]  ", type = "number" },
        { key = "remote_host", label = "Remote Target Host", badge = "[HOST]  ", type = "text" },
        { key = "remote_port", label = "Remote Target Port", badge = "[PORT]  ", type = "number" },
        { key = "ssh_user",    label = "SSH User",           badge = "[USER]  ", type = "text" },
        { key = "ssh_host",    label = "SSH Host",           badge = "[HOST]  ", type = "text" },
        { key = "ssh_port",    label = "SSH Port",           badge = "[PORT]  ", type = "number" },
        { key = "proxy_jump",  label = "ProxyJump (-J)",     badge = "[ROUTE] ", type = "text" },
        { key = "identity_key",label = "Identity Key (-i)",  badge = "[PATH]  ", type = "text" },
    }

    local field_idx = 1
    local col_pos = nil -- cursor position within text, nil = at end

    -- Initial screen prep
    io.write("\27[2J")

    while true do
        local out_buf = {}
        local function emit(str)
            table.insert(out_buf, str)
        end

        emit("\27[H")
        local W = 96
        local inner_w = W - 2
        local box_top = string.rep("═", inner_w)
        local box_mid = string.rep("─", inner_w)

        emit("\27[1;35m╔" .. box_top .. "╗\27[0m\27[K\n")
        local mode_title = existing_profile and ("✏️  Edit Tunnel Profile — [" .. p.name .. "]") or "✨ Create New Tunnel Profile"
        local header_txt = pad_right(mode_title, inner_w - 2)
        emit(string.format("\27[1;35m║\27[1;37m %s \27[1;35m║\27[0m\27[K\n", header_txt))
        emit("\27[1;35m╠" .. box_mid .. "╣\27[0m\27[K\n")

        -- Subheader explanation
        local subhdr = pad_right("  Field Name          Type     Editable Value Container                               Validation", inner_w - 2)
        emit(string.format("║\27[2;37m %s \27[0m║\27[K\n", subhdr))
        emit("\27[1;35m╟" .. box_mid .. "╢\27[0m\27[K\n")

        -- Port status preview
        local port_probe_res = ""
        local is_port_ok = true
        if p.type ~= "remote" then
            local pnum = tonumber(p.local_port) or 0
            if pnum <= 0 or pnum > 65535 then
                port_probe_res = "\27[1;31m✖ Invalid port (1-65535)\27[0m"
                is_port_ok = false
            else
                local ok, _ = probe_port_available(pnum, p.local_bind)
                if ok then
                    port_probe_res = "\27[1;32m● FREE & AVAILABLE\27[0m"
                else
                    port_probe_res = "\27[1;31m✖ OCCUPIED / IN USE\27[0m"
                    is_port_ok = false
                end
            end
        else
            port_probe_res = "\27[1;34mℹ Reverse Bind Port\27[0m"
        end

        local box_width = 38
        for idx, fld in ipairs(fields) do
            local is_active = (idx == field_idx)
            local marker = is_active and "\27[1;33m▶\27[0m" or " "
            local val_raw = tostring(p[fld.key] or "")
            local fld_label = pad_right(fld.label, 18)
            local badge_color = is_active and "\27[1;33m" or "\27[2;37m"
            local badge_str = badge_color .. fld.badge .. "\27[0m"

            local row_content
            if fld.type == "choice" then
                local opt_local  = (p.type == "local")  and "\27[1;32m(●) LOCAL (-L)\27[0m"  or "\27[2m( ) LOCAL (-L)\27[0m"
                local opt_remote = (p.type == "remote") and "\27[1;32m(●) REMOTE (-R)\27[0m" or "\27[2m( ) REMOTE (-R)\27[0m"
                local opt_socks  = (p.type == "socks")  and "\27[1;32m(●) SOCKS5 (-D)\27[0m" or "\27[2m( ) SOCKS5 (-D)\27[0m"
                local choice_str = string.format("%s   %s   %s", opt_local, opt_remote, opt_socks)
                if is_active then
                    row_content = string.format("%s \27[1;37m%s\27[0m %s  \27[48;5;236;1;37m %s \27[0m  \27[1;33m<Space to Cycle>\27[0m",
                        marker, fld_label, badge_str, choice_str)
                else
                    row_content = string.format("%s %s %s  \27[2m%s\27[0m",
                        marker, fld_label, badge_str, choice_str)
                end
            elseif p.type == "socks" and (fld.key == "remote_host" or fld.key == "remote_port") then
                row_content = string.format("%s \27[2m%s\27[0m %s  \27[2;37m[ N/A - Dynamically resolved by SOCKS5 client ]\27[0m",
                    marker, fld_label, badge_str)
            else
                local val_len = #val_raw
                local pos = col_pos or val_len
                if pos > val_len then pos = val_len end
                if pos < 0 then pos = 0 end

                local display_val = val_raw
                if #display_val > (box_width - 1) then
                    display_val = display_val:sub(#display_val - box_width + 2)
                end

                if is_active then
                    -- High-definition active editable input field container
                    -- Clearly shows distinct background, border, active cursor, and editing hint
                    local before = display_val:sub(1, pos)
                    local at_cursor = (pos < #display_val) and display_val:sub(pos + 1, pos + 1) or " "
                    local after = (pos < #display_val) and display_val:sub(pos + 2) or ""
                    local cursor_repr = "\27[7m" .. at_cursor .. "\27[27m"
                    local styled_val = before .. cursor_repr .. after

                    local padded_val = styled_val .. string.rep(" ", math.max(0, box_width - visual_len(styled_val)))
                    local input_container = "\27[1;36m│\27[48;5;236;1;37m ✎ " .. padded_val .. " \27[0;1;36m│\27[0m"

                    local validation = ""
                    if fld.key == "local_port" then
                        validation = " " .. port_probe_res
                    elseif fld.type == "number" then
                        local n = tonumber(p[fld.key])
                        if not n or n <= 0 or n > 65535 then
                            validation = " \27[1;31m✖ Valid port required (1-65535)\27[0m"
                        else
                            validation = " \27[1;32m✔ Valid port\27[0m"
                        end
                    else
                        validation = " \27[2;33m[EDITING]\27[0m"
                    end

                    row_content = string.format("%s \27[1;33m%s\27[0m %s %s%s",
                        marker, fld_label, badge_str, input_container, validation)
                else
                    -- Idle editable container: clearly framed with visible boundaries and placeholder
                    local padded_val = pad_right(val_raw, box_width)
                    local input_container = "\27[2;37m│   " .. padded_val .. " │\27[0m"
                    local validation = ""
                    if fld.key == "local_port" then
                        validation = " " .. port_probe_res
                    end
                    row_content = string.format("%s %s %s %s%s",
                        marker, fld_label, badge_str, input_container, validation)
                end
            end

            emit(string.format("║ %s ║\27[K\n", pad_right(row_content, inner_w - 2)))
        end

        emit("\27[1;35m╠" .. box_mid .. "╣\27[0m\27[K\n")

        -- Live Generated Command Preview
        local cmd = command_parts_to_string(build_ssh_command(p))
        local wrapped = wrap_command_lines(cmd, inner_w - 24)
        for line_idx, line_txt in ipairs(wrapped) do
            local prefix = (line_idx == 1) and "  ⚡ Generated SSH Command : \27[0;36m" or "                            \27[0;36m"
            local suffix = (line_idx < #wrapped) and " \\" or ""
            local display_txt = pad_right(prefix .. line_txt .. suffix, inner_w - 2)
            emit(string.format("║ %s\27[0m ║\27[K\n", display_txt))
        end

        emit("\27[1;35m╠" .. box_mid .. "╣\27[0m\27[K\n")
        local help_line = pad_right("  \27[1;32m[Tab/↓]\27[0m Next  \27[1;32m[Shift-Tab/↑]\27[0m Prev  \27[1;32m[Space]\27[0m Cycle  \27[1;32m[Ctrl+U]\27[0m Clear  \27[1;32m[Enter/Ctrl+S]\27[0m Save  \27[1;31m[Esc]\27[0m Cancel", inner_w - 2)
        emit(string.format("║ %s ║\27[K\n", help_line))
        emit("\27[1;35m╚" .. box_top .. "╝\27[0m\27[K\n")
        emit("\27[J")

        io.write(table.concat(out_buf))
        io.flush()

        local key = TUI.read_key()
        if not key or key == "ESC" then
            TUI.clear()
            return nil
        end
        local cur_fld = fields[field_idx]

        if key == "TAB" or key == "DOWN" then
            field_idx = field_idx + 1
            if field_idx > #fields then field_idx = 1 end
            col_pos = nil
        elseif key == "UP" or key == "SHIFT_TAB" then
            field_idx = field_idx - 1
            if field_idx < 1 then field_idx = #fields end
            col_pos = nil
        elseif key == "ENTER" or key == "CTRL_S" then
            -- If user pressed enter on last field or used Ctrl+S, save; if earlier field, advance to next
            if key == "CTRL_S" or field_idx == #fields then
                p.local_port = tonumber(p.local_port) or 8080
                p.remote_port = tonumber(p.remote_port) or 8080
                p.ssh_port = tonumber(p.ssh_port) or 22
                TUI.clear()
                return p
            else
                field_idx = field_idx + 1
                col_pos = nil
            end
        elseif key == " " and cur_fld.type == "choice" then
            local curr = p.type
            if curr == "local" then p.type = "remote"
            elseif curr == "remote" then p.type = "socks"
            else p.type = "local" end
        elseif key == "LEFT" then
            local cur_val = tostring(p[cur_fld.key] or "")
            local pos = col_pos or #cur_val
            pos = math.max(0, pos - 1)
            col_pos = pos
        elseif key == "RIGHT" then
            local cur_val = tostring(p[cur_fld.key] or "")
            local pos = col_pos or #cur_val
            pos = math.min(#cur_val, pos + 1)
            col_pos = pos
        elseif key == "CTRL_U" then
            p[cur_fld.key] = ""
            col_pos = 0
        elseif key == "BACKSPACE" then
            local cur_val = tostring(p[cur_fld.key] or "")
            local pos = col_pos or #cur_val
            if pos > 0 and #cur_val > 0 then
                local before = cur_val:sub(1, pos - 1)
                local after = cur_val:sub(pos + 1)
                p[cur_fld.key] = before .. after
                col_pos = pos - 1
            end
        elseif key and #key == 1 and string.byte(key) >= 32 and string.byte(key) <= 126 then
            if cur_fld.type ~= "number" or key:match("%d") then
                local cur_val = tostring(p[cur_fld.key] or "")
                local pos = col_pos or #cur_val
                local before = cur_val:sub(1, pos)
                local after = cur_val:sub(pos + 1)
                p[cur_fld.key] = before .. key .. after
                col_pos = pos + 1
            end
        end
    end
end

-- ============================================================================
-- 5. CLI Execution Modes
-- ============================================================================

local function print_help()
    print([[
ffi_ssh_tunnel.lua - High-Performance SSH Tunnel & ProxyJump Manager (LuaJIT FFI)

Usage:
  luajit ffi_ssh_tunnel.lua [command] [options]

Commands:
  list                  List configured tunnel profiles, endpoints, and live status
  up <name>             Start an SSH tunnel by profile name (with port collision check)
  down <name>           Stop an active tunnel via ControlMaster socket
  restart <name>        Restart a tunnel
  connect <name> [cmd]  Open interactive SSH session or run remote command (via proxy/mux)
  ssh <name> [cmd]      Alias for connect
  check <port> [host]   Probe if a local TCP port is free or occupied using FFI sockets
  release <port>        Release/terminate the process holding an occupied TCP port
  export                Export all profiles to standard OpenSSH ~/.ssh/config format
  add <json_str>        Add or update a profile from JSON string
  del <name>            Delete a tunnel profile
  tui                   Launch interactive terminal dashboard & visual config modal
  --test                Execute self-test verification suite
  --help                Show this help message

Examples:
  ./ffi_ssh_tunnel.lua list
  ./ffi_ssh_tunnel.lua check 5432
  ./ffi_ssh_tunnel.lua up prod-postgres
  ./ffi_ssh_tunnel.lua connect prod-postgres
  ./ffi_ssh_tunnel.lua connect prod-postgres uptime
  ./ffi_ssh_tunnel.lua down prod-postgres
  ./ffi_ssh_tunnel.lua export
]])
end

local function run_tui()
    local data = load_profiles()
    save_profiles(data) -- Ensure file exists

    local cursor = 1
    local status_msg = "Ready. Use arrows to browse profiles."

    TUI.set_raw_mode(true)
    TUI.hide_cursor()
    local ok, err = pcall(function()
        while true do
            if cursor > #data.profiles then cursor = math.max(1, #data.profiles) end
            TUI.render_dashboard(data.profiles, cursor, status_msg)
            status_msg = ""

            local key = TUI.read_key()
            if not key or key == "q" or key == "ESC" then
                break
            elseif key == "UP" then
                cursor = cursor - 1
                if cursor < 1 then cursor = #data.profiles end
            elseif key == "DOWN" then
                cursor = cursor + 1
                if cursor > #data.profiles then cursor = 1 end
            elseif key == "ENTER" then
                local sel = data.profiles[cursor]
                if sel then
                    local st = get_tunnel_status(sel)
                    if st.is_up then
                        stop_tunnel(sel)
                        status_msg = string.format("Stopped tunnel '%s'.", sel.name)
                    else
                        local success, msg = start_tunnel(sel)
                        status_msg = msg
                    end
                end
            elseif key == "n" then
                local new_p = TUI.edit_profile_modal(nil)
                if new_p then
                    table.insert(data.profiles, new_p)
                    save_profiles(data)
                    cursor = #data.profiles
                    status_msg = string.format("Added profile '%s'.", new_p.name)
                end
            elseif key == "e" then
                local sel = data.profiles[cursor]
                if sel then
                    local updated = TUI.edit_profile_modal(sel)
                    if updated then
                        data.profiles[cursor] = updated
                        save_profiles(data)
                        status_msg = string.format("Updated profile '%s'.", updated.name)
                    end
                end
            elseif key == "d" then
                local sel = data.profiles[cursor]
                if sel then
                    stop_tunnel(sel)
                    table.remove(data.profiles, cursor)
                    save_profiles(data)
                    status_msg = string.format("Deleted profile '%s'.", sel.name)
                end
            elseif key == "c" then
                local sel = data.profiles[cursor]
                if sel then
                    local port = tonumber(sel.local_port) or 8080
                    local free, res = probe_port_available(port, sel.local_bind)
                    status_msg = string.format("Port %d on %s: %s", port, sel.local_bind or "127.0.0.1", res)
                end
            elseif key == "s" then
                local sel = data.profiles[cursor]
                if sel then
                    local cmd_parts = build_interactive_ssh_command(sel)
                    local cmd = command_parts_to_string(cmd_parts)
                    TUI.set_raw_mode(false)
                    TUI.show_cursor()
                    TUI.clear()
                    print("\27[1;36m=== Connecting to '" .. sel.name .. "' ===\27[0m")
                    print("\27[2mExecuting: " .. cmd .. "\27[0m\n")
                    os.execute(cmd)
                    print("\n\27[1;33m[Session closed. Press any key to return to dashboard...]\27[0m")
                    TUI.set_raw_mode(true)
                    TUI.hide_cursor()
                    TUI.read_key()
                    local post_st = get_tunnel_status(sel)
                    status_msg = string.format("Exited SSH session '%s'. Tunnel status: %s", sel.name, post_st.is_up and "● UP" or "○ DOWN")
                end
            elseif key == "k" then
                local sel = data.profiles[cursor]
                if sel then
                    local port = tonumber(sel.local_port) or 8080
                    local ok, msg = release_port(port, sel.local_bind)
                    sleep_ms(200)
                    local post_st = get_tunnel_status(sel)
                    status_msg = msg .. string.format(" (Tunnel: %s)", post_st.is_up and "● UP" or "○ DOWN")
                else
                    status_msg = "No profile selected to release port."
                end
            elseif key == "v" then
                local sel = data.profiles[cursor]
                if sel then
                    local cmd = command_parts_to_string(build_ssh_command(sel))
                    TUI.clear()
                    print("\27[1;36m╔══════════════════════════════════════════════════════════════════════════════╗\27[0m")
                    print(string.format("\27[1;36m║\27[1;37m %-76s \27[1;36m║\27[0m", "📋 Complete SSH Command for Profile: " .. sel.name))
                    print("\27[1;36m╠══════════════════════════════════════════════════════════════════════════════╣\27[0m")
                    print("\n\27[1;32m" .. cmd .. "\27[0m\n")
                    print("\27[1;36m╚══════════════════════════════════════════════════════════════════════════════╝\27[0m")
                    io.write("\n\27[1;33m(Ready to copy/paste) Press any key to return to dashboard...\27[0m")
                    io.flush()
                    TUI.read_key()
                end
            elseif key == "x" then
                local exp = export_ssh_config(data.profiles)
                TUI.clear()
                print(exp)
                io.write("\n\27[1;33mPress any key to return to dashboard...\27[0m")
                io.flush()
                TUI.read_key()
            end
        end
    end)
    TUI.show_cursor()
    TUI.set_raw_mode(false)
    TUI.clear()
    if not ok then
        io.stderr:write("TUI Error: " .. tostring(err) .. "\n")
    end
end

-- ============================================================================
-- 6. Self-Test Suite (--test)
-- ============================================================================

local function run_self_tests()
    print("================================================================================")
    print("  Running Self-Tests for ffi_ssh_tunnel.lua (LuaJIT FFI)")
    print("================================================================================")

    local passed = 0
    local failed = 0

    local function assert_eq(desc, actual, expected)
        if actual == expected then
            print(string.format("  [PASS] %s", desc))
            passed = passed + 1
        else
            print(string.format("  [FAIL] %s: expected '%s', got '%s'", desc, tostring(expected), tostring(actual)))
            failed = failed + 1
        end
    end

    local function assert_true(desc, cond)
        if cond then
            print(string.format("  [PASS] %s", desc))
            passed = passed + 1
        else
            print(string.format("  [FAIL] %s", desc))
            failed = failed + 1
        end
    end

    -- 1. Byte Order Conversions
    assert_eq("htons(80) == 20480", htons(80), 20480)
    assert_eq("ntohs(20480) == 80", ntohs(20480), 80)
    assert_eq("htons(22) roundtrip", ntohs(htons(22)), 22)

    -- 2. JSON Encoder / Decoder
    local sample = {
        name = "test-tunnel",
        port = 5432,
        active = true,
        hops = {"jump1", "jump2"}
    }
    local encoded = json.encode(sample)
    local decoded = json.decode(encoded)
    assert_eq("JSON roundtrip name", decoded.name, "test-tunnel")
    assert_eq("JSON roundtrip port", decoded.port, 5432)
    assert_eq("JSON roundtrip boolean", decoded.active, true)
    assert_eq("JSON roundtrip array length", #decoded.hops, 2)
    assert_eq("JSON roundtrip array element", decoded.hops[1], "jump1")

    -- 3. SSH Command Generation: Local Forward (-L)
    local p_local = {
        name = "pg-tunnel",
        type = "local",
        local_bind = "127.0.0.1",
        local_port = 5432,
        remote_host = "db.internal",
        remote_port = 5432,
        ssh_user = "admin",
        ssh_host = "gateway.corp.com",
        ssh_port = 2222,
        proxy_jump = "jump1.corp.com,jump2.corp.com",
        identity_key = "/home/user/.ssh/id_rsa"
    }
    local cmd_parts = build_ssh_command(p_local)
    local cmd_str = command_parts_to_string(cmd_parts)
    assert_true("Command contains -L forward", cmd_str:find("%-L 127%.0%.0%.1:5432:db%.internal:5432") ~= nil)
    assert_true("Command contains -J ProxyJump", cmd_str:find("%-J jump1%.corp%.com,jump2%.corp%.com") ~= nil)
    assert_true("Command contains -p 2222", cmd_str:find("%-p 2222") ~= nil)
    assert_true("Command contains -i identity", cmd_str:find("%-i /home/user/%.ssh/id_rsa") ~= nil)
    assert_true("Command ends with admin@gateway.corp.com", cmd_str:find("admin@gateway%.corp%.com") ~= nil)

    -- 4. SSH Command Generation: Dynamic SOCKS5 (-D)
    local p_socks = {
        name = "vpn-socks",
        type = "socks",
        local_bind = "0.0.0.0",
        local_port = 1080,
        ssh_user = "user",
        ssh_host = "proxy.host"
    }
    local s_parts = build_ssh_command(p_socks)
    local s_str = command_parts_to_string(s_parts)
    assert_true("Command contains -D forward", s_str:find("%-D 0%.0%.0%.0:1080") ~= nil)

    -- 5. Interactive SSH Command Generation (Direct & with remote command)
    local conn_parts = build_interactive_ssh_command(p_local)
    local conn_str = command_parts_to_string(conn_parts)
    assert_true("Interactive command uses ssh binary", conn_str:find("^ssh") ~= nil)
    assert_true("Interactive command includes -J ProxyJump", conn_str:find("%-J jump1%.corp%.com,jump2%.corp%.com") ~= nil)
    assert_true("Interactive command includes -p 2222", conn_str:find("%-p 2222") ~= nil)
    assert_true("Interactive command target host", conn_str:find("admin@gateway%.corp%.com$") ~= nil)

    local conn_with_cmd = build_interactive_ssh_command(p_local, {"uptime"})
    local conn_cmd_str = command_parts_to_string(conn_with_cmd)
    assert_true("Interactive command appends remote command", conn_cmd_str:find("admin@gateway%.corp%.com uptime$") ~= nil)

    -- 6. Socket Port Probing via FFI
    -- Bind an ephemeral listening socket, verify probe detects OCCUPIED, then close and verify AVAILABLE
    local sock_api = get_sock_api()
    assert_true("Socket subsystem initialized", sock_api ~= nil)
    local test_fd = sock_api.socket(AF_INET, SOCK_STREAM, 0)
    assert_true("Created test socket", test_fd ~= INVALID_SOCKET and test_fd >= 0)
    local test_addr = ffi.new("struct sockaddr_in")
    test_addr.sin_family = AF_INET
    test_addr.sin_port = htons(0) -- ephemeral port
    test_addr.sin_addr.s_addr = sock_api.inet_addr("127.0.0.1")
    local b_res = sock_api.bind(test_fd, ffi.cast("const void*", test_addr), ffi.sizeof("struct sockaddr_in"))
    assert_eq("Ephemeral socket bind success", b_res, 0)
    sock_api.listen(test_fd, 1)

    -- Find allocated port
    local addr_len = ffi.new("int[1]", ffi.sizeof("struct sockaddr_in"))
    sock_api.getsockname(test_fd, ffi.cast("void*", test_addr), addr_len)
    local bound_port = ntohs(test_addr.sin_port)
    assert_true("Bound to valid port", bound_port > 0)

    local ok_busy, busy_msg = probe_port_available(bound_port, "127.0.0.1")
    assert_eq("Bound port is OCCUPIED", ok_busy, false)
    assert_eq("Bound port status OCCUPIED", busy_msg, "OCCUPIED")

    if is_windows then
        sock_api.closesocket(test_fd)
    else
        sock_api.close(test_fd)
    end

    local ok_free, free_msg = probe_port_available(bound_port, "127.0.0.1")
    assert_true("Freed port is now AVAILABLE", ok_free)

    -- 6. OpenSSH Config Export
    local exported = export_ssh_config({p_local, p_socks})
    assert_true("Export contains Host tunnel-pg-tunnel", exported:find("Host tunnel%-pg%-tunnel") ~= nil)
    assert_true("Export contains LocalForward", exported:find("LocalForward 127%.0%.0%.1:5432 db%.internal:5432") ~= nil)
    assert_true("Export contains DynamicForward", exported:find("DynamicForward 0%.0%.0%.0:1080") ~= nil)

    -- 7. Cross-Platform File Exists Verification
    assert_true("file_exists on current script", file_exists("ffi_ssh_tunnel.lua"))
    assert_true("file_exists returns false on nonexistent", not file_exists("/nonexistent_dummy_file_path_12345"))

    print("--------------------------------------------------------------------------------")
    print(string.format("Total: %d | Passed: %d | Failed: %d", passed + failed, passed, failed))
    if failed == 0 then
        print("\27[1;32mAll ffi_ssh_tunnel unit tests passed successfully!\27[0m")
        return true
    else
        print("\27[1;31mSome tests failed!\27[0m")
        return false
    end
end

-- ============================================================================
-- 7. Main CLI Dispatcher
-- ============================================================================

local function main(args)
    local cmd = args[1] or "list"

    if cmd == "--help" or cmd == "-h" or cmd == "help" then
        print_help()
        os.exit(0)
    elseif cmd == "--test" then
        local ok = run_self_tests()
        os.exit(ok and 0 or 1)
    elseif cmd == "tui" then
        run_tui()
        os.exit(0)
    elseif cmd == "list" or cmd == "ls" then
        local data = load_profiles()
        if #data.profiles == 0 then
            print("No tunnel profiles configured yet.")
            print("Run 'ffi_ssh_tunnel.lua tui' (press [n]) or edit ~/.config/lualab/ssh_tunnels.json to add one.")
            return
        end
        print(string.format("%-18s %-8s %-18s %-24s %-22s %-8s",
            "NAME", "TYPE", "LOCAL", "TARGET", "VIA (JUMP)", "STATUS"))
        print(string.rep("─", 102))
        for _, p in ipairs(data.profiles) do
            local st = get_tunnel_status(p)
            local status_str = st.is_up and (st.pid and string.format("UP (PID %d)", st.pid) or "UP") or "DOWN"

            local type_str = (p.type or "local"):upper()
            local local_ep = string.format("%s:%s", p.local_bind or "127.0.0.1", tostring(p.local_port or "8080"))
            local target_ep = string.format("%s:%s", p.remote_host or "-", tostring(p.remote_port or "-"))
            if type_str == "SOCKS" or type_str == "DYNAMIC" then
                target_ep = "[Dynamic SOCKS5]"
            end
            local via_str = (p.proxy_jump and #p.proxy_jump > 0) and p.proxy_jump or "-"

            print(string.format("%-18s %-8s %-18s %-24s %-22s %-8s",
                p.name:sub(1, 18), type_str:sub(1, 8), local_ep:sub(1, 18), target_ep:sub(1, 24), via_str:sub(1, 22), status_str))
        end
    elseif cmd == "up" or cmd == "start" then
        local name = args[2]
        if not name then
            print("Error: Missing profile name. Usage: ffi_ssh_tunnel.lua up <name>")
            os.exit(1)
        end
        local data = load_profiles()
        local found = nil
        for _, p in ipairs(data.profiles) do
            if p.name == name then found = p; break end
        end
        if not found then
            print(string.format("Error: Profile '%s' not found.", name))
            os.exit(1)
        end
        local ok, msg = start_tunnel(found)
        print(msg)
        os.exit(ok and 0 or 1)
    elseif cmd == "down" or cmd == "stop" then
        local name = args[2]
        if not name then
            print("Error: Missing profile name. Usage: ffi_ssh_tunnel.lua down <name>")
            os.exit(1)
        end
        local data = load_profiles()
        local found = nil
        for _, p in ipairs(data.profiles) do
            if p.name == name then found = p; break end
        end
        local out = stop_tunnel(found or name)
        print(string.format("Tunnel '%s' stopped. %s", name, out:gsub("%s+", " ")))
    elseif cmd == "restart" then
        local name = args[2]
        if not name then
            print("Error: Missing profile name. Usage: ffi_ssh_tunnel.lua restart <name>")
            os.exit(1)
        end
        local data = load_profiles()
        local found = nil
        for _, p in ipairs(data.profiles) do
            if p.name == name then found = p; break end
        end
        stop_tunnel(found or name)
        sleep_ms(200)
        local data = load_profiles()
        for _, p in ipairs(data.profiles) do
            if p.name == name then
                local ok, msg = start_tunnel(p)
                print(msg)
                os.exit(ok and 0 or 1)
            end
        end
        print("Profile not found.")
        os.exit(1)
    elseif cmd == "connect" or cmd == "ssh" then
        local name = args[2]
        if not name then
            print("Error: Missing profile name. Usage: ffi_ssh_tunnel.lua connect <name> [remote_cmd...]")
            os.exit(1)
        end
        local data = load_profiles()
        local found = nil
        for _, p in ipairs(data.profiles) do
            if p.name == name then found = p; break end
        end
        if not found then
            print(string.format("Error: Profile '%s' not found.", name))
            os.exit(1)
        end
        local extra_args = {}
        for i = 3, #args do
            table.insert(extra_args, args[i])
        end
        local cmd_parts = build_interactive_ssh_command(found, extra_args)
        local full_cmd = command_parts_to_string(cmd_parts)
        local ret = os.execute(full_cmd)
        os.exit(ret == 0 and 0 or 1)
    elseif cmd == "check" then
        local port = tonumber(args[2])
        if not port then
            print("Usage: ffi_ssh_tunnel.lua check <port> [host]")
            os.exit(1)
        end
        local host = args[3] or "127.0.0.1"
        local ok, reason = probe_port_available(port, host)
        if ok then
            print(string.format("[CHECK] Port %d on %s is AVAILABLE (Free to bind)", port, host))
        else
            print(string.format("[CHECK] Port %d on %s is OCCUPIED (%s)", port, host, reason))
        end
    elseif cmd == "release" or cmd == "kill-port" then
        local port = tonumber(args[2])
        if not port then
            print("Usage: ffi_ssh_tunnel.lua release <port> [host]")
            os.exit(1)
        end
        local host = args[3] or "127.0.0.1"
        local ok, msg = release_port(port, host)
        print(msg)
        os.exit(ok and 0 or 1)
    elseif cmd == "add" then
        local raw = args[2]
        if not raw then
            print("Usage: ffi_ssh_tunnel.lua add '{\"name\":\"my-tunnel\",\"type\":\"local\",...}'")
            os.exit(1)
        end
        local new_p = json.decode(raw)
        if not new_p or not new_p.name then
            print("Error: Invalid JSON profile object.")
            os.exit(1)
        end
        local data = load_profiles()
        local replaced = false
        for i, p in ipairs(data.profiles) do
            if p.name == new_p.name then
                data.profiles[i] = new_p
                replaced = true
                break
            end
        end
        if not replaced then
            table.insert(data.profiles, new_p)
        end
        save_profiles(data)
        print(string.format("Saved profile '%s'.", new_p.name))
    elseif cmd == "export" then
        local data = load_profiles()
        print(export_ssh_config(data.profiles))
    elseif cmd == "del" or cmd == "rm" then
        local name = args[2]
        local data = load_profiles()
        local idx = nil
        local found = nil
        for i, p in ipairs(data.profiles) do
            if p.name == name then idx = i; found = p; break end
        end
        if idx then
            stop_tunnel(found or name)
            table.remove(data.profiles, idx)
            save_profiles(data)
            print(string.format("Deleted profile '%s'.", name))
        else
            print(string.format("Profile '%s' not found.", name))
            os.exit(1)
        end
    else
        print("Unknown command: " .. tostring(cmd))
        print_help()
        os.exit(1)
    end
end

-- Export module or run main
if pcall(debug.getlocal, 4, 1) then
    -- Required as a module
    return {
        build_ssh_command = build_ssh_command,
        build_interactive_ssh_command = build_interactive_ssh_command,
        command_parts_to_string = command_parts_to_string,
        probe_port_available = probe_port_available,
        export_ssh_config = export_ssh_config,
        json = json,
        htons = htons,
        ntohs = ntohs,
        get_tunnel_status = get_tunnel_status,
        load_profiles = load_profiles,
        save_profiles = save_profiles
    }
else
    main(arg)
end
