#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- ffi_ssh_tunnel.lua
-- High-Performance SSH Tunnel & ProxyJump Config / Tunnel Manager
-- Pure LuaJIT FFI (Zero external dependencies)
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

-- ============================================================================
-- 1. FFI C-Declarations (POSIX sockets, processes, terminal)
-- ============================================================================
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

    // High resolution timer
    struct timespec {
        long tv_sec;
        long tv_nsec;
    };
    int clock_gettime(int clk_id, struct timespec *tp);
    int usleep(unsigned int usec);
]]

local AF_INET = 2
local SOCK_STREAM = 1
local SOL_SOCKET = 1
local SO_REUSEADDR = 2
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048

local TCSANOW = 0
local ICANON  = 2
local ECHO    = 8
local CLOCK_MONOTONIC = 1

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
    local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 then
        return false, "failed to create socket"
    end

    local optval = ffi.new("int[1]", 1)
    ffi.C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, optval, ffi.sizeof("int"))

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = htons(port)
    addr.sin_addr.s_addr = ffi.C.inet_addr(host)

    local res = ffi.C.bind(fd, ffi.cast("const void*", addr), ffi.sizeof("struct sockaddr_in"))
    ffi.C.close(fd)
    if res == 0 then
        return true, "AVAILABLE"
    else
        return false, "OCCUPIED"
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

local DEFAULT_CONFIG_PATH = os.getenv("SSH_TUNNEL_CONFIG") or ((os.getenv("HOME") or "/tmp") .. "/.config/lualab/ssh_tunnels.json")
local MUX_DIR = "/tmp"

local function ensure_dir(path)
    os.execute("mkdir -p '" .. path:gsub("/[^/]+$", "") .. "' 2>/dev/null")
end

local function get_mux_socket_path(profile_name)
    local safe_name = profile_name:gsub("[^%w_%-]", "_")
    return string.format("%s/ssh_mux_%s", MUX_DIR, safe_name)
end

-- Build SSH command from profile
local function build_ssh_command(p, extra_flags)
    local parts = {"ssh", "-N", "-f"}
    
    -- ControlMaster multiplexing
    local mux_path = get_mux_socket_path(p.name)
    table.insert(parts, "-M")
    table.insert(parts, "-S")
    table.insert(parts, mux_path)
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

-- Check live status of an OpenSSH control socket
local function get_tunnel_status(profile_name)
    local mux_path = get_mux_socket_path(profile_name)
    -- Check if socket file exists
    local f = io.open(mux_path, "r")
    if not f then
        return { is_up = false, status = "DOWN", pid = nil }
    end
    f:close()

    -- Check with ssh -O check
    local cmd = string.format("ssh -O check -S '%s' dummy_host 2>&1", mux_path)
    local pipe = io.popen(cmd)
    local output = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end

    local pid = output:match("pid=(%d+)")
    if pid then
        return { is_up = true, status = "UP", pid = tonumber(pid) }
    elseif output:lower():match("running") then
        return { is_up = true, status = "UP", pid = nil }
    else
        return { is_up = false, status = "DOWN", pid = nil }
    end
end

-- Stop a tunnel gracefully via ssh -O exit
local function stop_tunnel(profile_name)
    local mux_path = get_mux_socket_path(profile_name)
    local cmd = string.format("ssh -O exit -S '%s' dummy_host 2>&1", mux_path)
    local pipe = io.popen(cmd)
    local out = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end

    -- Clean up lingering socket file if necessary
    os.remove(mux_path)
    return out
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
    local ret = os.execute(cmd)
    if ret == 0 then
        -- Small pause to allow socket creation
        ffi.C.usleep(150000)
        local status = get_tunnel_status(p.name)
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

function TUI.set_raw_mode(enable)
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
    else return s end
end

function TUI.clear()
    io.write("\27[2J\27[H")
    io.flush()
end

-- Render the Main Dashboard
function TUI.render_dashboard(profiles, cursor_idx, status_msg)
    TUI.clear()
    local W = 88
    local line_sep = string.rep("─", W)
    local line_box = string.rep("═", W)

    io.write("\27[1;36m╔" .. line_box .. "╗\27[0m\n")
    io.write(string.format("\27[1;36m║\27[1;37m %-86s \27[1;36m║\27[0m\n", "🚀 LuaJIT SSH Tunnel & ProxyJump Studio"))
    io.write(string.format("\27[1;36m║\27[0;33m Profiles: %-2d │ Socket Mux: %-30s │ OS: %-12s \27[1;36m║\27[0m\n",
        #profiles, MUX_DIR .. "/ssh_mux_*", ffi.os))
    io.write("\27[1;36m╠" .. line_sep .. "╣\27[0m\n")

    -- Header row
    io.write(string.format("\27[1;37m║ %-3s │ %-16s │ %-8s │ %-17s │ %-20s │ %-8s ║\27[0m\n",
        "#", "Profile Name", "Type", "Local Endpoint", "Target / Route", "Status"))
    io.write("\27[1;36m╟" .. line_sep .. "╢\27[0m\n")

    if #profiles == 0 then
        io.write(string.format("║ %-86s ║\n", "  (No profiles configured. Press [n] to create a new profile!)"))
    else
        for i, p in ipairs(profiles) do
            local marker = (i == cursor_idx) and "▶" or " "
            local st = get_tunnel_status(p.name)
            local status_str = st.is_up and "\27[1;32m● UP   \27[0m" or "\27[1;31m○ DOWN \27[0m"

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

            local row_fmt
            if i == cursor_idx then
                row_fmt = string.format("\27[1;33m║ %s%-2d │ %-16s │ %-8s │ %-17s │ %-20s │ %s \27[1;33m║\27[0m\n",
                    marker, i, p.name:sub(1, 16), type_str:sub(1, 8), local_ep:sub(1, 17), target_ep:sub(1, 20), status_str)
            else
                row_fmt = string.format("║ %s%-2d │ %-16s │ %-8s │ %-17s │ %-20s │ %s ║\n",
                    marker, i, p.name:sub(1, 16), type_str:sub(1, 8), local_ep:sub(1, 17), target_ep:sub(1, 20), status_str)
            end
            io.write(row_fmt)
        end
    end

    io.write("\27[1;36m╠" .. line_sep .. "╣\27[0m\n")

    -- Details & Route Inspection for selected profile
    local sel = profiles[cursor_idx]
    if sel then
        local jump_str = (sel.proxy_jump and #sel.proxy_jump > 0) and sel.proxy_jump or "(Direct / None)"
        local ssh_tgt = string.format("%s@%s:%s", sel.ssh_user or "", sel.ssh_host or "localhost", tostring(sel.ssh_port or 22))
        local cmd = command_parts_to_string(build_ssh_command(sel))
        if #cmd > 82 then cmd = cmd:sub(1, 79) .. "..." end

        io.write(string.format("║ \27[1;34mRoute Detail:\27[0m ProxyJump: %-30s SSH Host: %-25s ║\n", jump_str:sub(1, 30), ssh_tgt:sub(1, 25)))
        io.write(string.format("║ \27[1;34mCommand:     \27[0;37m%-72s\27[0m ║\n", cmd))
        io.write("\27[1;36m╠" .. line_sep .. "╣\27[0m\n")
    end

    -- Keybindings help bar
    io.write("║ \27[1;32m[Enter]\27[0m Toggle  \27[1;32m[n]\27[0m New  \27[1;32m[e]\27[0m Edit  \27[1;32m[d]\27[0m Delete  \27[1;32m[c]\27[0m Check Port  \27[1;32m[x]\27[0m Export SSH  \27[1;31m[q]\27[0m Quit ║\n")
    io.write("\27[1;36m╚" .. line_box .. "╝\27[0m\n")

    if status_msg and #status_msg > 0 then
        io.write(string.format("\27[1;33m[STATUS] %s\27[0m\n", status_msg))
    end
    io.flush()
end

-- Interactive Edit / Create Profile Modal
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
        { key = "name",        label = "Profile Name",       type = "text" },
        { key = "type",        label = "Tunnel Type",        type = "choice", options = {"local", "remote", "socks"} },
        { key = "local_bind",  label = "Local Bind Host",    type = "text" },
        { key = "local_port",  label = "Local Port",         type = "number" },
        { key = "remote_host", label = "Remote Target Host", type = "text" },
        { key = "remote_port", label = "Remote Target Port", type = "number" },
        { key = "ssh_user",    label = "SSH User",           type = "text" },
        { key = "ssh_host",    label = "SSH Host",           type = "text" },
        { key = "ssh_port",    label = "SSH Port",           type = "number" },
        { key = "proxy_jump",  label = "ProxyJump (-J)",     type = "text" },
        { key = "identity_key",label = "Identity Key (-i)",  type = "text" },
    }

    local field_idx = 1

    while true do
        TUI.clear()
        local W = 84
        local box_top = string.rep("═", W)
        local box_mid = string.rep("─", W)

        io.write("\27[1;35m╔" .. box_top .. "╗\27[0m\n")
        io.write(string.format("\27[1;35m║\27[1;37m %-82s \27[1;35m║\27[0m\n", "✏️  SSH Tunnel Profile Editor (Tab: Move, Space: Cycle Type, Enter: Save)"))
        io.write("\27[1;35m╠" .. box_mid .. "╣\27[0m\n")

        -- Port status preview
        local port_probe_res = ""
        if p.type ~= "remote" then
            local ok, state = probe_port_available(tonumber(p.local_port) or 0, p.local_bind)
            if ok then
                port_probe_res = "\27[1;32m● Port is FREE & AVAILABLE\27[0m"
            else
                port_probe_res = "\27[1;31m✖ Port is OCCUPIED / IN USE\27[0m"
            end
        else
            port_probe_res = "\27[1;34mℹ Remote reverse bind port\27[0m"
        end

        for idx, fld in ipairs(fields) do
            local marker = (idx == field_idx) and "\27[1;33m▶\27[0m " or "  "
            local val_str = tostring(p[fld.key] or "")
            if fld.type == "choice" then
                val_str = string.format("[%s] (local / remote / socks)", val_str:upper())
            elseif p.type == "socks" and (fld.key == "remote_host" or fld.key == "remote_port") then
                val_str = "\27[2;37m(Dynamic SOCKS5 - resolved by client)\27[0m"
            end

            local line
            if idx == field_idx then
                line = string.format("║ %s\27[1;33m%-18s: \27[1;37m%-58s\27[1;35m ║\27[0m", marker, fld.label, val_str)
            else
                line = string.format("║ %s%-18s: %-58s ║", marker, fld.label, val_str)
            end
            io.write(line .. "\n")
        end

        io.write("\27[1;35m╠" .. box_mid .. "╣\27[0m\n")
        io.write(string.format("║  Local Port Probe : %-67s ║\n", port_probe_res))
        
        -- Live Command Preview
        local cmd = command_parts_to_string(build_ssh_command(p))
        if #cmd > 76 then cmd = cmd:sub(1, 73) .. "..." end
        io.write(string.format("║  Preview Command  : \27[0;36m%-63s\27[0m ║\n", cmd))

        io.write("\27[1;35m╠" .. box_mid .. "╣\27[0m\n")
        io.write("║  \27[1;32m[Tab/Shift-Tab]\27[0m Next/Prev Field   \27[1;32m[Space]\27[0m Cycle Option   \27[1;32m[Enter]\27[0m Save   \27[1;31m[Esc]\27[0m Cancel  ║\n")
        io.write("\27[1;35m╚" .. box_top .. "╝\27[0m\n")
        io.flush()

        local key = TUI.read_key()
        if key == "ESC" then
            return nil
        elseif key == "TAB" or key == "DOWN" then
            field_idx = field_idx + 1
            if field_idx > #fields then field_idx = 1 end
        elseif key == "UP" or key == "SHIFT_TAB" then
            field_idx = field_idx - 1
            if field_idx < 1 then field_idx = #fields end
        elseif key == "ENTER" then
            p.local_port = tonumber(p.local_port) or 8080
            p.remote_port = tonumber(p.remote_port) or 8080
            p.ssh_port = tonumber(p.ssh_port) or 22
            return p
        elseif key == " " and fields[field_idx].type == "choice" then
            local curr = p.type
            if curr == "local" then p.type = "remote"
            elseif curr == "remote" then p.type = "socks"
            else p.type = "local" end
        elseif key == "BACKSPACE" then
            local cur_val = tostring(p[fields[field_idx].key] or "")
            if #cur_val > 0 then
                p[fields[field_idx].key] = cur_val:sub(1, #cur_val - 1)
            end
        elseif key and #key == 1 and string.byte(key) >= 32 and string.byte(key) <= 126 then
            local fld = fields[field_idx]
            if fld.type ~= "number" or key:match("%d") then
                local cur_val = tostring(p[fld.key] or "")
                p[fld.key] = cur_val .. key
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
  check <port> [host]   Probe if a local TCP port is free or occupied using FFI sockets
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
    local ok, err = pcall(function()
        while true do
            if cursor > #data.profiles then cursor = math.max(1, #data.profiles) end
            TUI.render_dashboard(data.profiles, cursor, status_msg)
            status_msg = ""

            local key = TUI.read_key()
            if key == "q" or key == "ESC" then
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
                    local st = get_tunnel_status(sel.name)
                    if st.is_up then
                        stop_tunnel(sel.name)
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
                    stop_tunnel(sel.name)
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

    -- 5. Socket Port Probing via FFI
    -- Bind an ephemeral listening socket, verify probe detects OCCUPIED, then close and verify AVAILABLE
    local test_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    assert_true("Created test socket", test_fd >= 0)
    local test_addr = ffi.new("struct sockaddr_in")
    test_addr.sin_family = AF_INET
    test_addr.sin_port = htons(0) -- ephemeral port
    test_addr.sin_addr.s_addr = ffi.C.inet_addr("127.0.0.1")
    local b_res = ffi.C.bind(test_fd, ffi.cast("const void*", test_addr), ffi.sizeof("struct sockaddr_in"))
    assert_eq("Ephemeral socket bind success", b_res, 0)
    ffi.C.listen(test_fd, 1)

    -- Find allocated port
    local addr_len = ffi.new("uint32_t[1]", ffi.sizeof("struct sockaddr_in"))
    ffi.C.getsockname(test_fd, ffi.cast("void*", test_addr), addr_len)
    local bound_port = ntohs(test_addr.sin_port)
    assert_true("Bound to valid port", bound_port > 0)

    local ok_busy, busy_msg = probe_port_available(bound_port, "127.0.0.1")
    assert_eq("Bound port is OCCUPIED", ok_busy, false)
    assert_eq("Bound port status OCCUPIED", busy_msg, "OCCUPIED")

    ffi.C.close(test_fd)

    local ok_free, free_msg = probe_port_available(bound_port, "127.0.0.1")
    assert_true("Freed port is now AVAILABLE", ok_free)

    -- 6. OpenSSH Config Export
    local exported = export_ssh_config({p_local, p_socks})
    assert_true("Export contains Host tunnel-pg-tunnel", exported:find("Host tunnel%-pg%-tunnel") ~= nil)
    assert_true("Export contains LocalForward", exported:find("LocalForward 127%.0%.0%.1:5432 db%.internal:5432") ~= nil)
    assert_true("Export contains DynamicForward", exported:find("DynamicForward 0%.0%.0%.0:1080") ~= nil)

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
            local st = get_tunnel_status(p.name)
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
        local out = stop_tunnel(name)
        print(string.format("Tunnel '%s' stopped. %s", name, out:gsub("%s+", " ")))
    elseif cmd == "restart" then
        local name = args[2]
        if not name then
            print("Error: Missing profile name. Usage: ffi_ssh_tunnel.lua restart <name>")
            os.exit(1)
        end
        stop_tunnel(name)
        ffi.C.usleep(200000)
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
        for i, p in ipairs(data.profiles) do
            if p.name == name then idx = i; break end
        end
        if idx then
            stop_tunnel(name)
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
