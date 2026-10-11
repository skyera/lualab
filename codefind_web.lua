#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- codefind_web.lua
-- High-Performance Local Code & Document Search Engine — Web Interface
-- Pure LuaJIT FFI & SQLite FTS5 (Zero External Dependencies)
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

-- Ensure modules (codefind.lua, json.lua) are loaded from the script's directory
-- even when launched from an external working directory (e.g. ~/FFmpeg)
local script_source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = script_source:match("^(.*)[/\\][^/\\]*$")
if script_dir and #script_dir > 0 then
    package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path
    package.cpath = script_dir .. "/?.so;" .. package.cpath
end

local json = require("json")
local codefind = require("codefind")

local Database = codefind.Database
local Indexer  = codefind.Indexer

local CODEFIND_WEB_VERSION = "0.1.0"
local is_windows = (ffi.os == "Windows")

--------------------------------------------------------------------------------
-- 1. Sockets FFI Declarations (Cross-platform: Win32 ws2_32 / POSIX libc)
--------------------------------------------------------------------------------
local ws2

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
        char *inet_ntoa(struct in_addr in);
        uint16_t htons(uint16_t hostshort);
        uint16_t ntohs(uint16_t netshort);
        void Sleep(uint32_t dwMilliseconds);
    ]]
    ws2 = ffi.load("ws2_32")
    local wsadata = ffi.new("WSADATA")
    ws2.WSAStartup(0x0202, wsadata)
else
    pcall(ffi.cdef, [[
        typedef int SOCKET;
        int socket(int af, int type, int protocol);
        int bind(int s, const void *name, unsigned int namelen);
        int listen(int s, int backlog);
        int accept(int s, void *addr, unsigned int *addrlen);
        int close(int s);
        int fcntl(int s, int cmd, int arg);
        int setsockopt(int s, int level, int optname, const void *optval, unsigned int optlen);
        int getsockname(int s, void *name, unsigned int *namelen);
        int shutdown(int s, int how);
        long recv(int s, void *buf, size_t len, int flags);
        long send(int s, const void *buf, size_t len, int flags);

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
        char *inet_ntoa(struct in_addr in);
        uint16_t htons(uint16_t hostshort);
        uint16_t ntohs(uint16_t netshort);
        int usleep(unsigned int usec);
    ]])
    -- In case struct pollfd was already declared by codefind.lua, ensure remaining socket APIs are declared
    pcall(ffi.cdef, [[
        int socket(int af, int type, int protocol);
        int bind(int s, const void *name, unsigned int namelen);
        int listen(int s, int backlog);
        int accept(int s, void *addr, unsigned int *addrlen);
        int close(int s);
        int setsockopt(int s, int level, int optname, const void *optval, unsigned int optlen);
        int getsockname(int s, void *name, unsigned int *namelen);
        int shutdown(int s, int how);
        long recv(int s, void *buf, size_t len, int flags);
        long send(int s, const void *buf, size_t len, int flags);

        struct in_addr { uint32_t s_addr; };
        struct sockaddr_in {
            int16_t sin_family;
            uint16_t sin_port;
            struct in_addr sin_addr;
            char sin_zero[8];
        };
        char *inet_ntoa(struct in_addr in);
        uint16_t htons(uint16_t hostshort);
        uint16_t ntohs(uint16_t netshort);
        int usleep(unsigned int usec);
    ]])
end

local function close_socket(sock)
    if not sock then return end
    if is_windows then
        if sock ~= ffi.cast("SOCKET", -1) and sock ~= 0 then
            ws2.closesocket(sock)
        end
    else
        if sock >= 0 then
            ffi.C.close(sock)
        end
    end
end

local function ffi_sleep_ms(ms)
    if is_windows then
        ffi.C.Sleep(ms)
    else
        ffi.C.usleep(ms * 1000)
    end
end

local function socket_wait_readable(sock, timeout_ms)
    timeout_ms = timeout_ms or 50
    if is_windows then
        local fds = ffi.new("fd_set")
        fds.fd_count = 1
        fds.fd_array[0] = sock
        local tv = ffi.new("struct timeval")
        tv.tv_sec = math.floor(timeout_ms / 1000)
        tv.tv_usec = (timeout_ms % 1000) * 1000
        local ret = ws2.select(0, fds, nil, nil, tv)
        return ret > 0
    else
        local pfd = ffi.new("struct pollfd[1]")
        pfd[0].fd = sock
        pfd[0].events = 1 -- POLLIN
        pfd[0].revents = 0
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        return ret > 0 and bit.band(pfd[0].revents, 1) ~= 0
    end
end

--------------------------------------------------------------------------------
-- 2. URL & Request Utilities
--------------------------------------------------------------------------------
local function url_decode(str)
    if not str then return "" end
    str = str:gsub("+", " ")
    return (str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function parse_query_params(query_string)
    local params = {}
    if not query_string or #query_string == 0 then return params end
    for pair in query_string:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=(.*)$")
        if k then
            params[url_decode(k)] = url_decode(v)
        else
            params[url_decode(pair)] = ""
        end
    end
    return params
end

local function parse_http_request(raw)
    local first_line, rest = raw:match("^([^\r\n]+)\r?\n(.*)$")
    if not first_line then return nil end
    local method, raw_uri, proto = first_line:match("^(%u+)%s+(%S+)%s+(%S+)$")
    if not method then return nil end

    local path, query_str = raw_uri:match("^([^?]+)%??(.*)$")
    local params = parse_query_params(query_str)

    return {
        method = method,
        uri = raw_uri,
        path = path or "/",
        query = query_str or "",
        params = params,
        raw = raw
    }
end

local function read_http_request(sock, buffer)
    local request = ""
    for _ = 1, 32 do
        if not socket_wait_readable(sock, 100) then
            if #request > 0 then break else return nil end
        end
        local received = is_windows and ws2.recv(sock, buffer, 4095, 0)
                                    or ffi.C.recv(sock, buffer, 4095, 0)
        if received <= 0 then break end
        request = request .. ffi.string(buffer, received)
        if #request > 65536 then return nil end
        local _, header_end = request:find("\r\n\r\n", 1, true)
        if header_end then
            local headers = request:sub(1, header_end):lower()
            local length = tonumber(headers:match("\r\ncontent%-length:%s*(%d+)")) or 0
            if header_end + length > 65536 then return nil end
            if #request >= header_end + length then
                return request:sub(1, header_end + length)
            end
        end
    end
    return #request > 0 and request or nil
end

local function sanitize_path(requested_path)
    if not requested_path or #requested_path == 0 then return nil end
    requested_path = requested_path:gsub("\\", "/"):gsub("^%./", "")
    -- Block absolute path escapes and traversal
    if requested_path:find("^/") or requested_path:find("%.%./") or requested_path:find("/%.%.") or requested_path:find("^%.%.$") then
        return nil
    end
    -- Also block drive letters on Windows (e.g. C:)
    if requested_path:match("^%a%:") then return nil end
    return requested_path
end

local function get_primary_ip()
    local ip = "127.0.0.1"
    if not is_windows then
        local p = io.popen("ip route get 1.1.1.1 2>/dev/null | awk '{print $7}'", "r")
        if p then
            local line = p:read("*l")
            p:close()
            if line and line:match("^%d+%.%d+%.%d+%.%d+$") then
                return line
            end
        end
        local p2 = io.popen("hostname -I 2>/dev/null | awk '{print $1}'", "r")
        if p2 then
            local line = p2:read("*l")
            p2:close()
            if line and line:match("^%d+%.%d+%.%d+%.%d+$") then
                return line
            end
        end
    end
    return ip
end

--------------------------------------------------------------------------------
-- 3. Web UI HTML / CSS / JS Single Page Application
--------------------------------------------------------------------------------
local function render_web_app(meta)
    meta = meta or {}
    local app_title = "CodeFind Web"
    local version = CODEFIND_WEB_VERSION
    local total_files = meta.total_files or 0
    local total_size = meta.total_size or "0 B"
    local db_path = meta.db_path or ".codefind.db"

    return [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>]] .. app_title .. [[</title>
<style>
  :root {
    --bg-main: #0d1117;
    --bg-card: #161b22;
    --bg-panel: #1b2028;
    --bg-active: #21262d;
    --border: #30363d;
    --border-focus: #58a6ff;
    --text-main: #c9d1d9;
    --text-bright: #f0f6fc;
    --text-muted: #8b949e;
    --accent: #58a6ff;
    --accent-hover: #79c0ff;
    --match-hl: #f2cc60;
    --match-hl-bg: rgba(242, 204, 96, 0.25);
    --badge-bg: #238636;
    --badge-text: #ffffff;
    --line-num: #484f58;
    --font-code: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg-main);
    color: var(--text-main);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 13px;
    height: 100vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  header {
    background: var(--bg-card);
    border-bottom: 1px solid var(--border);
    padding: 10px 16px;
    display: flex;
    align-items: center;
    gap: 14px;
    flex-shrink: 0;
  }
  .brand {
    font-weight: 700;
    font-size: 15px;
    color: var(--text-bright);
    display: flex;
    align-items: center;
    gap: 8px;
    white-space: nowrap;
  }
  .brand svg { fill: var(--accent); }
  .search-bar-wrap {
    flex: 1;
    display: flex;
    align-items: center;
    position: relative;
    max-width: 900px;
  }
  .search-input {
    width: 100%;
    background: var(--bg-main);
    border: 1px solid var(--border);
    border-radius: 6px;
    color: var(--text-bright);
    font-family: var(--font-code);
    font-size: 13.5px;
    padding: 7px 12px 7px 34px;
    outline: none;
    transition: border-color 0.15s, box-shadow 0.15s;
  }
  .search-input:focus {
    border-color: var(--border-focus);
    box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.2);
  }
  .search-icon {
    position: absolute;
    left: 10px;
    color: var(--text-muted);
    pointer-events: none;
  }
  .header-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
  }
  .btn {
    background: var(--bg-active);
    border: 1px solid var(--border);
    color: var(--text-bright);
    padding: 6px 12px;
    border-radius: 6px;
    font-size: 12px;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 6px;
    transition: background 0.15s, border-color 0.15s;
  }
  .btn:hover { background: #30363d; border-color: var(--text-muted); }
  .btn-primary { background: #238636; border-color: rgba(240,246,252,0.1); }
  .btn-primary:hover { background: #2ea043; }
  .search-meta {
    font-size: 12px;
    color: var(--text-muted);
    white-space: nowrap;
  }
  .main-split {
    flex: 1;
    display: flex;
    overflow: hidden;
  }
  .results-pane {
    width: 440px;
    min-width: 320px;
    max-width: 600px;
    border-right: 1px solid var(--border);
    background: var(--bg-card);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .pane-header {
    padding: 8px 12px;
    background: var(--bg-panel);
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 11.5px;
    color: var(--text-muted);
    text-transform: uppercase;
    font-weight: 600;
    letter-spacing: 0.5px;
  }
  .results-list {
    flex: 1;
    overflow-y: auto;
    list-style: none;
  }
  .result-item {
    padding: 10px 12px;
    border-bottom: 1px solid var(--border);
    cursor: pointer;
    transition: background 0.1s;
    outline: none;
  }
  .result-item:hover { background: rgba(88, 166, 255, 0.08); }
  .result-item.selected {
    background: var(--bg-active);
    border-left: 3px solid var(--accent);
  }
  .item-title-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 4px;
  }
  .item-fname {
    font-weight: 600;
    color: var(--text-bright);
    font-family: var(--font-code);
    font-size: 13px;
  }
  .item-badge {
    background: #30363d;
    color: #58a6ff;
    padding: 1px 6px;
    border-radius: 10px;
    font-size: 10.5px;
    font-weight: 600;
    font-family: var(--font-code);
  }
  .item-path {
    font-size: 11px;
    color: var(--text-muted);
    font-family: var(--font-code);
    margin-bottom: 6px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .item-snippet {
    font-family: var(--font-code);
    font-size: 11.5px;
    color: #adbac7;
    background: var(--bg-main);
    padding: 6px 8px;
    border-radius: 4px;
    border: 1px solid var(--border);
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 72px;
    overflow: hidden;
  }
  .item-snippet mark, mark.hl {
    background: var(--match-hl-bg);
    color: var(--match-hl);
    font-weight: 600;
    border-radius: 2px;
    padding: 0 1px;
  }
  .preview-pane {
    flex: 1;
    background: var(--bg-main);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    position: relative;
  }
  .preview-pane.fullscreen {
    position: fixed;
    top: 0;
    left: 0;
    width: 100vw;
    height: 100vh;
    z-index: 999;
  }
  .preview-toolbar {
    padding: 6px 14px;
    background: var(--bg-card);
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    flex-wrap: wrap;
  }
  .preview-title {
    font-family: var(--font-code);
    font-size: 12.5px;
    color: var(--text-bright);
    display: flex;
    align-items: center;
    gap: 8px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }
  .toolbar-group {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .btn-sm {
    padding: 3px 8px;
    font-size: 11.5px;
    height: 26px;
  }
  .badge-counter {
    background: var(--bg-main);
    border: 1px solid var(--border);
    color: var(--text-bright);
    font-family: var(--font-code);
    font-size: 11px;
    padding: 2px 7px;
    border-radius: 4px;
    display: flex;
    align-items: center;
    white-space: nowrap;
  }
  .zoom-indicator {
    font-family: var(--font-code);
    font-size: 11px;
    color: var(--text-muted);
    min-width: 38px;
    text-align: center;
    user-select: none;
  }
  .code-viewer-wrap {
    flex: 1;
    overflow: auto;
    font-family: var(--font-code);
    font-size: 13px;
    line-height: 1.5;
  }
  .code-viewer-wrap.wrap-lines .col-code {
    white-space: pre-wrap !important;
    word-break: break-all;
  }
  .code-table {
    width: 100%;
    border-collapse: collapse;
  }
  .code-table tr { transition: background 0.1s; }
  .code-table tr:hover { background: rgba(255,255,255,0.03); }
  .code-table tr.hit-row {
    background: rgba(242, 204, 96, 0.12);
  }
  .code-table tr.hit-row .col-line {
    color: var(--match-hl);
    font-weight: 700;
    border-left: 2px solid var(--match-hl);
  }
  .code-table tr.active-hit-row {
    background: rgba(242, 204, 96, 0.28) !important;
    outline: 1px solid rgba(242, 204, 96, 0.5);
  }
  .code-table tr.active-hit-row .col-marker {
    color: #fff;
    text-shadow: 0 0 6px rgba(242, 204, 96, 0.9);
  }
  .code-table tr.active-hit-row .col-line {
    color: #fff;
    background: var(--match-hl);
    color: #000;
    font-weight: 800;
  }
  .col-marker {
    width: 22px;
    text-align: center;
    color: var(--match-hl);
    user-select: none;
    font-weight: 700;
  }
  .col-line {
    width: 48px;
    text-align: right;
    padding-right: 12px;
    color: var(--line-num);
    user-select: none;
  }
  .col-code {
    padding: 0 12px;
    white-space: pre;
    color: #e6edf3;
  }
  .empty-state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    color: var(--text-muted);
    text-align: center;
    padding: 30px;
  }
  .empty-state svg {
    margin-bottom: 14px;
    fill: var(--text-muted);
    opacity: 0.5;
  }
  .empty-state h3 {
    color: var(--text-bright);
    margin-bottom: 6px;
    font-size: 15px;
  }
  .empty-state p {
    max-width: 420px;
    line-height: 1.5;
    font-size: 12.5px;
  }
  .kbd {
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    padding: 2px 5px;
    font-family: var(--font-code);
    font-size: 11px;
    color: #c9d1d9;
  }
  footer {
    background: var(--bg-card);
    border-top: 1px solid var(--border);
    padding: 4px 14px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 11px;
    color: var(--text-muted);
    flex-shrink: 0;
  }
  .stats-badges {
    display: flex;
    gap: 12px;
    align-items: center;
  }
  .filter-hints {
    display: flex;
    gap: 6px;
    align-items: center;
    margin-left: 10px;
  }
  .filter-chip {
    background: var(--bg-active);
    padding: 2px 6px;
    border-radius: 4px;
    cursor: pointer;
    border: 1px solid transparent;
  }
  .filter-chip:hover {
    border-color: var(--border-focus);
    color: var(--accent);
  }
  .toast {
    position: fixed;
    bottom: 24px;
    right: 24px;
    background: #1f6feb;
    color: #fff;
    padding: 8px 14px;
    border-radius: 6px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.4);
    opacity: 0;
    transition: opacity 0.2s;
    pointer-events: none;
    font-weight: 500;
  }
</style>
</head>
<body>

<header>
  <div class="brand">
    <svg width="18" height="18" viewBox="0 0 16 16"><path d="M10.68 11.74a6 6 0 0 1-7.922-8.982 6 6 0 0 1 8.982 7.922l3.04 3.04a.749.749 0 0 1-.326 1.275.749.749 0 0 1-.734-.215ZM11.5 7a4.499 4.499 0 1 0-8.997 0A4.499 4.499 0 0 0 11.5 7Z"></path></svg>
    CodeFind <span style="font-size:11px; color:var(--accent); font-weight:normal;">Web v]] .. version .. [[</span>
  </div>

  <div class="search-bar-wrap">
    <svg class="search-icon" width="14" height="14" viewBox="0 0 16 16"><path fill="currentColor" d="M10.68 11.74a6 6 0 0 1-7.922-8.982 6 6 0 0 1 8.982 7.922l3.04 3.04a.749.749 0 0 1-.326 1.275.749.749 0 0 1-.734-.215ZM11.5 7a4.499 4.499 0 1 0-8.997 0A4.499 4.499 0 0 0 11.5 7Z"></path></svg>
    <input id="searchInput" class="search-input" type="text" placeholder="Search code (e.g. sqlite3_prepare, @lua, files:*.c) ... [/ to focus]" autofocus autocomplete="off">
  </div>

  <div class="filter-hints">
    <span class="filter-chip" onclick="applyFilter('@lua')">@lua</span>
    <span class="filter-chip" onclick="applyFilter('@c')">@c</span>
    <span class="filter-chip" onclick="applyFilter('files:*.md')">files:*.md</span>
  </div>

  <div class="header-actions">
    <div id="searchMeta" class="search-meta">Ready</div>
    <button class="btn" onclick="triggerReindex()" title="Reindex files in repository">
      <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M1.705 8.001a6.3 6.3 0 0 1 10.39-4.878l.707-.707a7.3 7.3 0 0 0-12.097 5.585H0l2.5 3 2.5-3H1.705ZM14.295 8a6.3 6.3 0 0 1-10.39 4.878l-.707.707a7.3 7.3 0 0 0 12.097-5.585H16l-2.5-3-2.5 3h1.295Z"></path></svg>
      Reindex
    </button>
  </div>
</header>

<div class="main-split">
  <div class="results-pane">
    <div class="pane-header">
      <span id="resultsHeader">Results</span>
      <span style="font-weight:normal;"><span class="kbd">j</span> <span class="kbd">k</span> navigate</span>
    </div>
    <ul id="resultsList" class="results-list">
      <li class="empty-state">
        <svg width="36" height="36" viewBox="0 0 16 16"><path d="M10.68 11.74a6 6 0 0 1-7.922-8.982 6 6 0 0 1 8.982 7.922l3.04 3.04a.749.749 0 0 1-.326 1.275.749.749 0 0 1-.734-.215ZM11.5 7a4.499 4.499 0 1 0-8.997 0A4.499 4.499 0 0 0 11.5 7Z"></path></svg>
        <h3>No Query Entered</h3>
        <p>Type keywords to search across all indexed files using SQLite FTS5 BM25 ranking.<br>Use <span class="kbd">/</span> anytime to focus search.</p>
      </li>
    </ul>
  </div>

  <div id="previewPane" class="preview-pane">
    <div class="preview-toolbar">
      <div id="previewTitle" class="preview-title">No file selected</div>
      
      <div class="toolbar-group">
        <!-- Match traversal n / N -->
        <div id="matchNavGroup" class="toolbar-group" style="display:none;">
          <button class="btn btn-sm" onclick="navMatch(-1)" title="Previous match [N]">&#9664; Prev (N)</button>
          <span id="matchCounter" class="badge-counter">0 / 0</span>
          <button class="btn btn-sm" onclick="navMatch(1)" title="Next match [n]">Next (n) &#9654;</button>
        </div>

        <!-- Zoom controls -->
        <div class="toolbar-group" style="border-left:1px solid var(--border); padding-left:6px;">
          <button class="btn btn-sm" onclick="zoomChange(-1)" title="Zoom out [-]">&#8722;</button>
          <span id="zoomLabel" class="zoom-indicator" onclick="zoomReset()" title="Reset zoom [0]" style="cursor:pointer;">100%</span>
          <button class="btn btn-sm" onclick="zoomChange(1)" title="Zoom in [+/=]">&#43;</button>
        </div>

        <!-- Line wrap toggle -->
        <button id="wrapToggleBtn" class="btn btn-sm" onclick="toggleWrap()" title="Toggle soft line wrap [w]">Wrap: Off</button>

        <!-- Fullscreen expand toggle -->
        <button id="expandToggleBtn" class="btn btn-sm" onclick="toggleFullscreen()" title="Toggle distraction-free reader [f]">⛶ Expand</button>

        <!-- Copy buttons -->
        <button id="copySnippetBtn" class="btn btn-sm" onclick="copySnippet()" style="display:none;">Copy Snippet</button>
        <button id="copyPathBtn" class="btn btn-sm" onclick="copyFilePath()" style="display:none;">Copy Path</button>
      </div>
    </div>
    <div id="codeViewerWrap" class="code-viewer-wrap">
      <div class="empty-state">
        <svg width="36" height="36" viewBox="0 0 16 16"><path d="M2 1.75C2 .784 2.784 0 3.75 0h6.586c.464 0 .909.184 1.237.513l2.914 2.914c.329.328.513.773.513 1.237v9.586A1.75 1.75 0 0 1 13.25 16h-9.5A1.75 1.75 0 0 1 2 14.25Zm1.75-.25a.25.25 0 0 0-.25.25v12.5c0 .25.25.25.25.25h9.5a.25.25 0 0 0 .25-.25V4.707a.25.25 0 0 0-.073-.177L10.464 1.616a.25.25 0 0 0-.177-.073H3.75Z"></path></svg>
        <h3>Document Preview</h3>
        <p>Select a search result from the left pane to view code with line numbers and matched occurrences highlighted.</p>
      </div>
    </div>
  </div>
</div>

<footer>
  <div class="stats-badges">
    <span><b>DB:</b> ]] .. db_path .. [[</span>
    <span><b>Indexed:</b> <span id="statFiles">]] .. total_files .. [[</span> files</span>
    <span><b>Total Size:</b> <span id="statSize">]] .. total_size .. [[</span></span>
  </div>
  <div>
    <span>Accessible on LAN &middot; Pure LuaJIT FFI &middot; SQLite FTS5</span>
  </div>
</footer>

<div id="toast" class="toast"></div>

<script>
let state = {
  results: [],
  selectedIndex: -1,
  currentQuery: "",
  currentFile: null,
  activePreviewSnippet: "",
  hitLinesList: [],
  activeMatchIndex: -1,
  zoomScale: 100,
  wrapLines: false,
  isFullscreen: false
};

const searchInput = document.getElementById("searchInput");
const resultsList = document.getElementById("resultsList");
const resultsHeader = document.getElementById("resultsHeader");
const searchMeta = document.getElementById("searchMeta");
const previewPane = document.getElementById("previewPane");
const previewTitle = document.getElementById("previewTitle");
const codeViewerWrap = document.getElementById("codeViewerWrap");
const copyPathBtn = document.getElementById("copyPathBtn");
const copySnippetBtn = document.getElementById("copySnippetBtn");
const matchNavGroup = document.getElementById("matchNavGroup");
const matchCounter = document.getElementById("matchCounter");
const zoomLabel = document.getElementById("zoomLabel");
const wrapToggleBtn = document.getElementById("wrapToggleBtn");
const expandToggleBtn = document.getElementById("expandToggleBtn");
const toast = document.getElementById("toast");

function showToast(msg) {
  toast.textContent = msg;
  toast.style.opacity = "1";
  setTimeout(() => { toast.style.opacity = "0"; }, 2000);
}

function escapeHtml(str) {
  if (!str) return "";
  return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// --- Zoom Controls ---
function applyZoom(scale) {
  scale = Math.max(70, Math.min(220, scale));
  state.zoomScale = scale;
  const baseSize = 13;
  const newSize = (baseSize * (scale / 100)).toFixed(1);
  codeViewerWrap.style.fontSize = newSize + "px";
  zoomLabel.textContent = scale + "%";
  try { localStorage.setItem("codefind_zoom", scale); } catch(e) {}
}

function zoomChange(delta) {
  applyZoom(state.zoomScale + delta * 15);
}

function zoomReset() {
  applyZoom(100);
}

// --- Line Wrapping & Fullscreen Toggle ---
function toggleWrap() {
  state.wrapLines = !state.wrapLines;
  codeViewerWrap.classList.toggle("wrap-lines", state.wrapLines);
  wrapToggleBtn.textContent = state.wrapLines ? "Wrap: On" : "Wrap: Off";
  wrapToggleBtn.classList.toggle("btn-primary", state.wrapLines);
  showToast(state.wrapLines ? "Soft wrap enabled" : "Soft wrap disabled");
}

function toggleFullscreen() {
  state.isFullscreen = !state.isFullscreen;
  previewPane.classList.toggle("fullscreen", state.isFullscreen);
  expandToggleBtn.textContent = state.isFullscreen ? "🗗 Restore" : "⛶ Expand";
  expandToggleBtn.classList.toggle("btn-primary", state.isFullscreen);
}

// Load saved zoom preference
try {
  const savedZoom = parseInt(localStorage.getItem("codefind_zoom"));
  if (savedZoom && !isNaN(savedZoom)) applyZoom(savedZoom);
} catch(e) {}

let debounceTimer = null;
searchInput.addEventListener("input", () => {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    doSearch(searchInput.value.trim());
  }, 120);
});

async function doSearch(q) {
  state.currentQuery = q;
  if (!q) {
    state.results = [];
    state.selectedIndex = -1;
    renderResults();
    searchMeta.textContent = "Ready";
    return;
  }

  const t0 = performance.now();
  searchMeta.textContent = "Searching...";
  try {
    const res = await fetch("/api/search?q=" + encodeURIComponent(q) + "&limit=50");
    const data = await res.json();
    const elapsed = (performance.now() - t0).toFixed(1);
    state.results = data.results || [];
    state.selectedIndex = state.results.length > 0 ? 0 : -1;
    searchMeta.textContent = `${state.results.length} matches (${elapsed} ms)`;
    renderResults();
    if (state.selectedIndex >= 0) {
      loadFilePreview(state.results[0]);
    } else {
      clearPreview();
    }
  } catch (err) {
    searchMeta.textContent = "Search error: " + err.message;
  }
}

function renderResults() {
  resultsHeader.textContent = `Results (${state.results.length})`;
  if (state.results.length === 0) {
    if (!state.currentQuery) {
      resultsList.innerHTML = `<li class="empty-state"><h3>No Query</h3><p>Type keywords to search code.</p></li>`;
    } else {
      resultsList.innerHTML = `<li class="empty-state"><h3>No matches found</h3><p>Try different keywords or check extension filters.</p></li>`;
    }
    return;
  }

  let html = "";
  state.results.forEach((r, idx) => {
    const isSel = idx === state.selectedIndex;
    const ext = r.filename.includes(".") ? r.filename.split(".").pop().toUpperCase() : "FILE";
    
    // Parse snippet highlighting tags
    let cleanSnippet = escapeHtml(r.snippet || "")
      .replace(/\[\x5bHL\]\x5d/g, '<mark class="hl">')
      .replace(/\[\x5b\/HL\]\x5d/g, '</mark>');

    html += `
      <li class="result-item ${isSel ? 'selected' : ''}" onclick="selectResult(${idx})" data-idx="${idx}">
        <div class="item-title-row">
          <span class="item-fname">${escapeHtml(r.filename)}</span>
          <span class="item-badge">${escapeHtml(ext)}</span>
        </div>
        <div class="item-path" title="${escapeHtml(r.filepath)}">${escapeHtml(r.filepath)}</div>
        ${cleanSnippet ? `<div class="item-snippet">${cleanSnippet}</div>` : ''}
      </li>
    `;
  });
  resultsList.innerHTML = html;
}

function selectResult(idx) {
  if (idx < 0 || idx >= state.results.length) return;
  state.selectedIndex = idx;
  const items = resultsList.querySelectorAll(".result-item");
  items.forEach((el, i) => {
    el.classList.toggle("selected", i === idx);
  });
  const cur = items[idx];
  if (cur) cur.scrollIntoView({ block: "nearest" });
  loadFilePreview(state.results[idx]);
}

async function loadFilePreview(item) {
  state.currentFile = item;
  state.activePreviewSnippet = item.snippet || "";
  previewTitle.innerHTML = `<span>${escapeHtml(item.filename)}</span> <span style="color:var(--text-muted); font-size:11px;">(${escapeHtml(item.filepath)})</span>`;
  copyPathBtn.style.display = "inline-flex";
  copySnippetBtn.style.display = item.snippet ? "inline-flex" : "none";

  codeViewerWrap.innerHTML = `<div class="empty-state"><p>Loading source code...</p></div>`;

  try {
    const res = await fetch("/api/file?path=" + encodeURIComponent(item.filepath) + "&q=" + encodeURIComponent(state.currentQuery));
    const data = await res.json();
    if (data.status !== "ok") {
      codeViewerWrap.innerHTML = `<div class="empty-state"><p>Error: ${escapeHtml(data.message)}</p></div>`;
      matchNavGroup.style.display = "none";
      return;
    }
    renderCode(data.lines, data.hit_lines || {});
  } catch (err) {
    codeViewerWrap.innerHTML = `<div class="empty-state"><p>Failed to load file: ${escapeHtml(err.message)}</p></div>`;
    matchNavGroup.style.display = "none";
  }
}

function renderCode(lines, hitLines) {
  let html = `<table class="code-table">`;
  lines.forEach((lineText, i) => {
    const ln = i + 1;
    const isHit = !!hitLines[ln];
    const marker = isHit ? "▶" : "";
    const rowClass = isHit ? "hit-row" : "";
    html += `
      <tr class="${rowClass}" id="code-line-${ln}">
        <td class="col-marker">${marker}</td>
        <td class="col-line">${ln}</td>
        <td class="col-code">${escapeHtml(lineText)}</td>
      </tr>
    `;
  });
  html += `</table>`;
  codeViewerWrap.innerHTML = html;

  // Track sorted hit lines for n / N navigation
  state.hitLinesList = Object.keys(hitLines).map(Number).sort((a,b)=>a-b);
  if (state.hitLinesList.length > 0) {
    state.activeMatchIndex = 0;
    matchNavGroup.style.display = "inline-flex";
    updateMatchNavUI(true);
  } else {
    state.activeMatchIndex = -1;
    matchNavGroup.style.display = "none";
    codeViewerWrap.scrollTop = 0;
  }
}

function updateMatchNavUI(smoothScroll) {
  const total = state.hitLinesList.length;
  if (total === 0) {
    matchNavGroup.style.display = "none";
    return;
  }
  matchNavGroup.style.display = "inline-flex";
  matchCounter.textContent = `${state.activeMatchIndex + 1} / ${total}`;

  // Clear previous active row highlights
  codeViewerWrap.querySelectorAll(".active-hit-row").forEach(el => {
    el.classList.remove("active-hit-row");
  });

  const activeLine = state.hitLinesList[state.activeMatchIndex];
  const el = document.getElementById("code-line-" + activeLine);
  if (el) {
    el.classList.add("active-hit-row");
    el.scrollIntoView({ block: "center", behavior: smoothScroll ? "smooth" : "auto" });
  }
}

function navMatch(direction) {
  const total = state.hitLinesList.length;
  if (total === 0) return;
  state.activeMatchIndex = (state.activeMatchIndex + direction + total) % total;
  updateMatchNavUI(true);
}

function clearPreview() {
  state.currentFile = null;
  state.activePreviewSnippet = "";
  state.hitLinesList = [];
  state.activeMatchIndex = -1;
  matchNavGroup.style.display = "none";
  previewTitle.textContent = "No file selected";
  copyPathBtn.style.display = "none";
  copySnippetBtn.style.display = "none";
  codeViewerWrap.innerHTML = `
    <div class="empty-state">
      <h3>No Document Selected</h3>
      <p>Select a result from the list to preview.</p>
    </div>
  `;
}

function copyFilePath() {
  if (!state.currentFile) return;
  navigator.clipboard.writeText(state.currentFile.filepath).then(() => {
    showToast("Path copied to clipboard!");
  });
}

function copySnippet() {
  if (!state.currentFile || !state.currentFile.snippet) return;
  const raw = state.currentFile.snippet.replace(/\[\x5b\/?HL\]\x5d/g, "");
  navigator.clipboard.writeText(raw).then(() => {
    showToast("Snippet copied to clipboard!");
  });
}

function applyFilter(f) {
  const cur = searchInput.value.trim();
  if (!cur.includes(f)) {
    searchInput.value = (cur ? cur + " " : "") + f;
    searchInput.focus();
    doSearch(searchInput.value.trim());
  }
}

async function triggerReindex() {
  searchMeta.textContent = "Reindexing repository...";
  try {
    const res = await fetch("/api/reindex", { method: "POST" });
    const data = await res.json();
    if (data.status === "ok") {
      showToast(`Indexed ${data.files_indexed} files in ${data.elapsed_sec}s`);
      updateStats();
      if (state.currentQuery) doSearch(state.currentQuery);
    } else {
      showToast("Reindex failed: " + data.message);
    }
  } catch (err) {
    showToast("Reindex error: " + err.message);
  }
}

async function updateStats() {
  try {
    const res = await fetch("/api/stats");
    const data = await res.json();
    if (data.status === "ok") {
      document.getElementById("statFiles").textContent = data.stats.total_files;
      document.getElementById("statSize").textContent = data.stats.total_size_formatted;
    }
  } catch (e) {}
}

// Global hotkeys (/, j, k, n, N, +, -, 0, w, f, Esc)
window.addEventListener("keydown", (e) => {
  if (e.target === searchInput) {
    if (e.key === "Escape") {
      searchInput.blur();
    } else if (e.key === "Enter" || e.key === "ArrowDown") {
      if (state.results.length > 0) {
        searchInput.blur();
        selectResult(0);
      }
    }
    return;
  }

  // Hotkey navigation
  if (e.key === "/" || e.key === "s") {
    e.preventDefault();
    searchInput.focus();
    searchInput.select();
  } else if (e.key === "j" || e.key === "ArrowDown") {
    if (state.selectedIndex < state.results.length - 1) {
      e.preventDefault();
      selectResult(state.selectedIndex + 1);
    }
  } else if (e.key === "k" || e.key === "ArrowUp") {
    if (state.selectedIndex > 0) {
      e.preventDefault();
      selectResult(state.selectedIndex - 1);
    }
  } else if (e.key === "n" && !e.shiftKey) {
    // Next match in current file
    e.preventDefault();
    navMatch(1);
  } else if (e.key === "N" || (e.key === "n" && e.shiftKey)) {
    // Previous match in current file
    e.preventDefault();
    navMatch(-1);
  } else if (e.key === "+" || e.key === "=") {
    // Zoom in
    e.preventDefault();
    zoomChange(1);
  } else if (e.key === "-" || e.key === "_") {
    // Zoom out
    e.preventDefault();
    zoomChange(-1);
  } else if (e.key === "0") {
    // Reset zoom
    e.preventDefault();
    zoomReset();
  } else if (e.key === "w" || e.key === "W") {
    // Toggle line wrap
    e.preventDefault();
    toggleWrap();
  } else if (e.key === "f" || e.key === "F") {
    // Toggle distraction-free full viewer
    e.preventDefault();
    toggleFullscreen();
  } else if (e.key === "Escape") {
    if (state.isFullscreen) {
      toggleFullscreen();
    }
  }
});

// Periodic background stats poll
updateStats();
</script>
</body>
</html>]]
end

--------------------------------------------------------------------------------
-- 4. HTTP API Handlers
--------------------------------------------------------------------------------
local function format_bytes(bytes)
    if not bytes or bytes <= 0 then return "0 B" end
    if bytes < 1024 then return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024)
    else return string.format("%.2f MB", bytes / (1024 * 1024))
    end
end

local function handle_search_api(db, params)
    local q = params.q or ""
    local ext = params.ext
    local limit = tonumber(params.limit) or 50
    local op = params.op or "AND"

    -- Also check inline filters in query like @ext
    local inline_ext = q:match("@(%w+)") or q:match("ext:(%w+)")
    if inline_ext then
        ext = inline_ext
    end

    local t0 = os.clock()
    local results, err = db:search(q, {
        limit = limit,
        extension = ext,
        op = op
    })
    local elapsed_ms = math.floor((os.clock() - t0) * 10000) / 10

    if not results then
        return {
            status = "error",
            message = err or "Search failed",
            results = {},
            count = 0,
            elapsed_ms = elapsed_ms
        }
    end

    return {
        status = "ok",
        query = q,
        extension = ext,
        count = #results,
        results = results,
        elapsed_ms = elapsed_ms
    }
end

local function handle_file_api(params)
    local raw_path = params.path
    local clean_path = sanitize_path(raw_path)
    if not clean_path then
        return 403, { status = "error", message = "Access denied: invalid or forbidden file path" }
    end

    local f = io.open(clean_path, "r")
    if not f then
        return 404, { status = "error", message = "File not found: " .. clean_path }
    end

    local lines = {}
    local line_count = 0
    for line in f:lines() do
        line_count = line_count + 1
        -- Cap file preview lines to 10,000 to prevent massive memory allocations
        if line_count <= 10000 then
            table.insert(lines, line)
        end
    end
    f:close()

    -- Detect hit lines for query highlighting
    local query_str = params.q or ""
    local hit_lines = {}
    if #query_str > 0 then
        local tokens = {}
        local clean_q = query_str:gsub("@%w+", ""):gsub("files:%S+", "")
        for tok in clean_q:gmatch("[%w_%-]+") do
            if tok ~= "AND" and tok ~= "OR" and tok ~= "NOT" then
                local w = tok:lower():gsub("%*$", "")
                if #w > 0 then table.insert(tokens, w) end
            end
        end

        if #tokens > 0 then
            for idx, text in ipairs(lines) do
                local lower = text:lower()
                for _, tok in ipairs(tokens) do
                    if lower:find(tok, 1, true) then
                        hit_lines[tostring(idx)] = true
                        break
                    end
                end
            end
        end
    end

    return 200, {
        status = "ok",
        filepath = clean_path,
        total_lines = line_count,
        lines = lines,
        hit_lines = hit_lines
    }
end

local function handle_stats_api(db)
    local s = db:get_stats()
    return {
        status = "ok",
        stats = {
            total_files = s.total_files,
            total_size = s.total_size,
            total_size_formatted = format_bytes(s.total_size),
            extensions = s.extensions,
            last_index = s.last_index
        }
    }
end

local function handle_reindex_api(db, root_dir)
    local t0 = os.clock()
    local files_indexed, files_scanned = Indexer.run(db, root_dir, false, false, "auto")
    local elapsed_sec = math.floor((os.clock() - t0) * 100) / 100
    return {
        status = "ok",
        files_indexed = files_indexed or 0,
        files_scanned = files_scanned or 0,
        elapsed_sec = elapsed_sec
    }
end

--------------------------------------------------------------------------------
-- 5. Embedded Web Server Loop
--------------------------------------------------------------------------------
local function run_server(options)
    options = options or {}
    local port = options.port or 8010
    local host = options.host or "0.0.0.0" -- Bind to INADDR_ANY: accessible from any computer
    local db_path = options.db_path or ".codefind.db"
    local root_dir = options.root_dir or "."

    -- Ensure database is initialized
    local db = Database.open(db_path)
    if not db then
        io.stderr:write("Error: Could not open database " .. db_path .. "\n")
        return false
    end

    local server_sock = is_windows and ws2.socket(2, 1, 6) or ffi.C.socket(2, 1, 6)
    local server_sock_invalid = is_windows and (server_sock == 0 or tostring(server_sock):find("0xffffffffffffffff") ~= nil)
                                           or (server_sock < 0)
    if server_sock_invalid then
        io.stderr:write("Error: Failed to create server socket\n")
        db:close()
        return false
    end

    if not is_windows then
        local opt = ffi.new("int[1]", 1)
        ffi.C.setsockopt(server_sock, 1, 2, opt, ffi.sizeof(opt)) -- SO_REUSEADDR
    end

    local server_addr = ffi.new("struct sockaddr_in")
    server_addr.sin_family = 2
    server_addr.sin_port = is_windows and ws2.htons(port) or ffi.C.htons(port)
    server_addr.sin_addr.s_addr = 0 -- INADDR_ANY (0.0.0.0): accessible from all interfaces / any computer

    local bind_res = is_windows and ws2.bind(server_sock, server_addr, ffi.sizeof(server_addr))
                                or ffi.C.bind(server_sock, server_addr, ffi.sizeof(server_addr))
    if bind_res ~= 0 then
        -- Check if port is occupied, try fallback if requested
        if options.auto_port then
            local found_port = nil
            for try_port = port + 1, port + 20 do
                server_addr.sin_port = is_windows and ws2.htons(try_port) or ffi.C.htons(try_port)
                if (is_windows and ws2.bind(server_sock, server_addr, ffi.sizeof(server_addr))
                               or ffi.C.bind(server_sock, server_addr, ffi.sizeof(server_addr))) == 0 then
                    found_port = try_port
                    break
                end
            end
            if not found_port then
                io.stderr:write(string.format("Error: Could not bind to port %d or fallback ports.\n", port))
                close_socket(server_sock)
                db:close()
                return false
            end
            port = found_port
        else
            io.stderr:write(string.format("Error: Port %d is already in use.\n", port))
            close_socket(server_sock)
            db:close()
            return false
        end
    end

    local listen_res = is_windows and ws2.listen(server_sock, 32) or ffi.C.listen(server_sock, 32)
    if listen_res ~= 0 then
        io.stderr:write("Error: Failed to listen on socket\n")
        close_socket(server_sock)
        db:close()
        return false
    end

    local primary_ip = get_primary_ip()
    local stats = db:get_stats()

    print("================================================================================")
    print("  \27[1;36mCodeFind Web v" .. CODEFIND_WEB_VERSION .. " — High-Performance Local Code Search Web UI\27[0m")
    print("  \27[90mPowered by LuaJIT FFI & SQLite FTS5 (Zero External Dependencies)\27[0m")
    print("================================================================================")
    print(string.format("  \27[1mDatabase:\27[0m        %s (%d files, %s indexed)", db_path, stats.total_files, format_bytes(stats.total_size)))
    print(string.format("  \27[1;32mLocal Access:\27[0m    http://127.0.0.1:%d/", port))
    if primary_ip ~= "127.0.0.1" then
        print(string.format("  \27[1;33mLAN Access:\27[0m      http://%s:%d/ \27[90m(Accessible from any computer)\27[0m", primary_ip, port))
    end
    print(string.format("  \27[1mAPI Endpoint:\27[0m    http://127.0.0.1:%d/api/search?q=...", port))
    print("")
    print("  \27[90mPress [Ctrl+C] to stop web server\27[0m")
    print("--------------------------------------------------------------------------------")
    io.stdout:flush()

    local client_buffer = ffi.new("char[4096]")
    local client_addr = ffi.new("struct sockaddr_in")
    local addr_len = ffi.new(is_windows and "int[1]" or "unsigned int[1]", ffi.sizeof(client_addr))

    local running = true
    while running do
        if socket_wait_readable(server_sock, 50) then
            addr_len[0] = ffi.sizeof(client_addr)
            local client_sock = is_windows and ws2.accept(server_sock, client_addr, addr_len)
                                           or ffi.C.accept(server_sock, client_addr, addr_len)
            local invalid_client = is_windows and (client_sock == 0 or tostring(client_sock):find("0xffffffffffffffff") ~= nil)
                                               or (client_sock < 0)

            if not invalid_client then
                local client_ip = "127.0.0.1"
                local ntoa_res = is_windows and ws2.inet_ntoa(client_addr.sin_addr)
                                            or ffi.C.inet_ntoa(client_addr.sin_addr)
                if ntoa_res ~= nil then client_ip = ffi.string(ntoa_res) end

                local raw_req = read_http_request(client_sock, client_buffer)
                if raw_req then
                    local req = parse_http_request(raw_req)
                    if req then
                        local status_code = "200 OK"
                        local content_type = "application/json"
                        local resp_body = ""

                        if req.method == "OPTIONS" then
                            status_code = "204 No Content"
                            resp_body = ""
                        elseif req.path == "/" or req.path == "/index.html" then
                            status_code = "200 OK"
                            content_type = "text/html; charset=utf-8"
                            resp_body = render_web_app({
                                total_files = stats.total_files,
                                total_size = format_bytes(stats.total_size),
                                db_path = db_path
                            })
                        elseif req.path == "/api/search" then
                            local data = handle_search_api(db, req.params)
                            resp_body = json.encode(data)
                        elseif req.path == "/api/file" then
                            local code, data = handle_file_api(req.params)
                            status_code = (code == 200) and "200 OK" or (code == 403 and "403 Forbidden" or "404 Not Found")
                            resp_body = json.encode(data)
                        elseif req.path == "/api/stats" then
                            local data = handle_stats_api(db)
                            resp_body = json.encode(data)
                        elseif req.path == "/api/reindex" and req.method == "POST" then
                            local data = handle_reindex_api(db, root_dir)
                            stats = db:get_stats() -- refresh stats
                            resp_body = json.encode(data)
                        elseif req.path == "/api/ping" then
                            resp_body = json.encode({ status = "ok", version = CODEFIND_WEB_VERSION, time = os.time() })
                        else
                            status_code = "404 Not Found"
                            resp_body = json.encode({ status = "error", message = "Not Found" })
                        end

                        local header = string.format(
                            "HTTP/1.1 %s\r\n" ..
                            "Content-Type: %s\r\n" ..
                            "Content-Length: %d\r\n" ..
                            "Access-Control-Allow-Origin: *\r\n" ..
                            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ..
                            "Access-Control-Allow-Headers: Content-Type\r\n" ..
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

                        print(string.format("[%s] %-15s %-4s %-32s -> %s (%d B)",
                            os.date("%H:%M:%S"), client_ip, req.method, req.uri:sub(1, 32), status_code, #resp_body))
                        io.stdout:flush()
                    end
                end
                close_socket(client_sock)
            end
        else
            ffi_sleep_ms(20)
        end

        if options.max_requests then
            options.max_requests = options.max_requests - 1
            if options.max_requests <= 0 then running = false end
        end
    end

    close_socket(server_sock)
    db:close()
    return true
end

--------------------------------------------------------------------------------
-- 6. CLI Entry Point
--------------------------------------------------------------------------------
local function print_help()
    print([[
CodeFind Web — High-Performance Local Code Search Web Interface
Pure LuaJIT FFI & SQLite FTS5 (Zero External Dependencies)

Usage:
  luajit codefind_web.lua [options]

Options:
  -p, --port <number>     Set HTTP port to listen on (default: 8010)
  --host <ip>             Set host to bind (default: 0.0.0.0, accessible on all interfaces)
  --db <path>             Path to SQLite index database (default: .codefind.db)
  --dir <path>            Root directory to index if reindexed (default: .)
  -h, --help              Show this help message and exit
  -v, --version           Print version information and exit

Examples:
  luajit codefind_web.lua                  # Starts on http://0.0.0.0:8010
  luajit codefind_web.lua --port 8010      # Explicitly specify port 8010
  luajit codefind_web.lua --db /my/code.db # Use custom database path
]])
end

local function main(args)
    local port = 8010
    local host = "0.0.0.0"
    local db_path = ".codefind.db"
    local root_dir = "."

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            print_help()
            return
        elseif a == "--version" or a == "-v" then
            print("codefind_web " .. CODEFIND_WEB_VERSION)
            return
        elseif (a == "--port" or a == "-p") and args[i+1] then
            port = tonumber(args[i+1]) or port
            i = i + 1
        elseif a == "--host" and args[i+1] then
            host = args[i+1]
            i = i + 1
        elseif a == "--db" and args[i+1] then
            db_path = args[i+1]
            i = i + 1
        elseif a == "--dir" and args[i+1] then
            root_dir = args[i+1]
            i = i + 1
        end
        i = i + 1
    end

    run_server({
        port = port,
        host = host,
        db_path = db_path,
        root_dir = root_dir,
        auto_port = false
    })
end

-- Export module or run main
if pcall(debug.getlocal, 4, 1) then
    return {
        run_server = run_server,
        handle_search_api = handle_search_api,
        handle_file_api = handle_file_api,
        handle_stats_api = handle_stats_api,
        handle_reindex_api = handle_reindex_api,
        render_web_app = render_web_app,
        sanitize_path = sanitize_path,
        parse_query_params = parse_query_params,
        parse_http_request = parse_http_request,
        url_decode = url_decode,
        get_primary_ip = get_primary_ip,
        format_bytes = format_bytes,
        VERSION = CODEFIND_WEB_VERSION
    }
else
    main(arg)
end
