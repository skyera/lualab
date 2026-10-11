#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- landrop_web.lua
-- Fast, Zero-Dependency LAN File Drop & Cross-Device Clipboard Web Service
-- Written in Pure LuaJIT FFI (POSIX sockets on Linux/macOS, Winsock on Windows)
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

-- Ensure local packages (like json.lua) can be loaded relative to script dir
local script_source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = script_source:match("^(.*)[/\\][^/\\]*$")
if script_dir and #script_dir > 0 then
    package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path
    package.cpath = script_dir .. "/?.so;" .. package.cpath
end

local json = require("json")

local LANDROP_VERSION = "0.1.0"
local is_windows = (ffi.os == "Windows")

--------------------------------------------------------------------------------
-- 1. Sockets & System FFI Declarations
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
    ]]
end

local C = ffi.C

local AF_INET      = 2
local SOCK_STREAM  = 1
local SOCK_DGRAM   = 2
local SOL_SOCKET   = is_windows and 0xFFFF or 1
local SO_REUSEADDR = is_windows and 0x0004 or 2
local POLLIN       = 0x0001
local INVALID_SOCK = is_windows and ffi.cast("SOCKET", -1) or -1

local function close_socket(s)
    if is_windows then
        ws2.closesocket(s)
    else
        C.close(s)
    end
end

local function make_dir(path)
    if is_windows then
        C._mkdir(path)
    else
        C.mkdir(path, 493) -- 0755
    end
end

--------------------------------------------------------------------------------
-- 2. Local LAN IP Auto-Detection
--------------------------------------------------------------------------------
local function get_local_lan_ip()
    local s = is_windows and ws2.socket(AF_INET, SOCK_DGRAM, 0) or C.socket(AF_INET, SOCK_DGRAM, 0)
    if s == INVALID_SOCK or s < 0 then
        return "127.0.0.1"
    end

    local dest = ffi.new("struct sockaddr_in")
    dest.sin_family = AF_INET
    dest.sin_port = C.htons(80)
    dest.sin_addr.s_addr = C.inet_addr("8.8.8.8")

    local ok
    if is_windows then
        ok = (ws2.connect(s, dest, ffi.sizeof(dest)) == 0)
    else
        ok = (C.connect(s, dest, ffi.sizeof(dest)) == 0)
    end

    local ip = "127.0.0.1"
    if ok then
        local local_addr = ffi.new("struct sockaddr_in")
        local len = ffi.new(is_windows and "int[1]" or "unsigned int[1]", ffi.sizeof(local_addr))
        local get_ok
        if is_windows then
            get_ok = (ws2.getsockname(s, local_addr, len) == 0)
        else
            get_ok = (C.getsockname(s, local_addr, len) == 0)
        end
        if get_ok then
            local str = C.inet_ntoa(local_addr.sin_addr)
            if str ~= nil then
                ip = ffi.string(str)
            end
        end
    end

    close_socket(s)
    return ip
end

--------------------------------------------------------------------------------
-- 3. File & MIME Helpers
--------------------------------------------------------------------------------
local MIME_TYPES = {
    txt   = "text/plain; charset=utf-8",
    html  = "text/html; charset=utf-8",
    css   = "text/css; charset=utf-8",
    js    = "application/javascript; charset=utf-8",
    json  = "application/json; charset=utf-8",
    png   = "image/png",
    jpg   = "image/jpeg",
    jpeg  = "image/jpeg",
    gif   = "image/gif",
    svg   = "image/svg+xml",
    webp  = "image/webp",
    pdf   = "application/pdf",
    zip   = "application/zip",
    tar   = "application/x-tar",
    gz    = "application/gzip",
    mp3   = "audio/mpeg",
    wav   = "audio/wav",
    mp4   = "video/mp4",
    webm  = "video/webm",
    mkv   = "video/x-matroska",
    md    = "text/markdown; charset=utf-8",
    lua   = "text/plain; charset=utf-8",
    py    = "text/plain; charset=utf-8",
    sh    = "text/plain; charset=utf-8",
}

local function get_mime_type(filename)
    local ext = filename:match("%.([%w_]+)$")
    if ext then
        ext = ext:lower()
        if MIME_TYPES[ext] then
            return MIME_TYPES[ext]
        end
    end
    return "application/octet-stream"
end

local function format_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then
        return bytes .. " B"
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function sanitize_filename(name)
    if not name or #name == 0 then return nil end
    -- Strip path separators, null bytes, backslashes
    name = name:gsub("[\r\n%z]", "")
    name = name:gsub(".*[/\\]", "")
    -- Block directory traversal attempts
    if name == ".." or name == "." or name:find("^%.%./") or name:find("/%.%./") then
        return nil
    end
    -- Limit length
    if #name > 255 then
        name = name:sub(1, 255)
    end
    return #name > 0 and name or nil
end

--------------------------------------------------------------------------------
-- 4. Safe Storage Manager (Files)
--------------------------------------------------------------------------------
local Storage = {}
Storage.__index = Storage

function Storage.new(dir_path)
    local self = setmetatable({}, Storage)
    self.dir = dir_path or "./shared_files"
    make_dir(self.dir)
    return self
end

function Storage:list_files()
    local files = {}
    local p
    if is_windows then
        p = io.popen('dir /b /a-d "' .. self.dir .. '" 2>nul')
    else
        p = io.popen('ls -1 "' .. self.dir .. '" 2>/dev/null')
    end
    if not p then return files end

    for line in p:lines() do
        local fname = line:gsub("[\r\n]", "")
        if #fname > 0 and fname:sub(1, 1) ~= "." then
            local full_path = self.dir .. "/" .. fname
            local f = io.open(full_path, "rb")
            if f then
                local sz = f:seek("end")
                f:close()
                local ext = fname:match("%.([%w_]+)$") or ""
                ext = ext:lower()
                local is_img = (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "webp" or ext == "svg")
                local is_txt = (ext == "txt" or ext == "md" or ext == "lua" or ext == "py" or ext == "json" or ext == "sh" or ext == "html" or ext == "css")
                table.insert(files, {
                    name = fname,
                    size = sz,
                    size_fmt = format_bytes(sz),
                    mime = get_mime_type(fname),
                    is_image = is_img,
                    is_text = is_txt,
                })
            end
        end
    end
    p:close()
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    return files
end

function Storage:save_file(filename, data)
    local safe = sanitize_filename(filename)
    if not safe then return false, "Invalid filename" end
    local full_path = self.dir .. "/" .. safe
    local f, err = io.open(full_path, "wb")
    if not f then return false, err or "Failed to open file for writing" end
    f:write(data)
    f:close()
    return true, safe
end

function Storage:save_file_stream(filename)
    local safe = sanitize_filename(filename)
    if not safe then return nil, "Invalid filename" end
    local tmp_name = ".tmp_" .. os.time() .. "_" .. math.random(1000, 9999)
    local tmp_path = self.dir .. "/" .. tmp_name
    local f, err = io.open(tmp_path, "wb")
    if not f then return nil, err or "Failed to open temporary file" end
    local final_path = self.dir .. "/" .. safe
    return {
        write = function(_, chunk) f:write(chunk) end,
        finish = function(_)
            f:close()
            os.remove(final_path)
            local ok = os.rename(tmp_path, final_path)
            if not ok then
                local src = io.open(tmp_path, "rb")
                local dst = io.open(final_path, "wb")
                if src and dst then
                    dst:write(src:read("*a"))
                    src:close()
                    dst:close()
                    os.remove(tmp_path)
                end
            end
            return true, safe
        end,
        abort = function(_)
            f:close()
            os.remove(tmp_path)
        end,
    }
end

function Storage:read_file(filename)
    local safe = sanitize_filename(filename)
    if not safe then return nil, "Invalid filename" end
    local full_path = self.dir .. "/" .. safe
    local f, err = io.open(full_path, "rb")
    if not f then return nil, err or "File not found" end
    local content = f:read("*a")
    f:close()
    return content, safe
end

function Storage:delete_file(filename)
    local safe = sanitize_filename(filename)
    if not safe then return false, "Invalid filename" end
    local full_path = self.dir .. "/" .. safe
    local ok = (C.remove(full_path) == 0)
    return ok
end

--------------------------------------------------------------------------------
-- 5. Shared Clipboard Store
--------------------------------------------------------------------------------
local ClipboardStore = {}
ClipboardStore.__index = ClipboardStore

function ClipboardStore.new()
    local self = setmetatable({}, ClipboardStore)
    self.items = {}
    self.active = nil
    return self
end

function ClipboardStore:set_text(text, source)
    if not text or #text == 0 then return false end
    local now = os.time()
    local item = {
        id = now .. "_" .. math.random(1000, 9999),
        text = text,
        source = source or "Web / LAN",
        time = os.date("%H:%M:%S", now),
        date = os.date("%Y-%m-%d", now),
        is_url = (text:find("^https?://") ~= nil),
    }
    self.active = item
    table.insert(self.items, 1, item)
    if #self.items > 50 then
        table.remove(self.items)
    end
    return true, item
end

function ClipboardStore:get_data()
    return {
        current = self.active,
        history = self.items,
    }
end

function ClipboardStore:clear()
    self.items = {}
    self.active = nil
end

--------------------------------------------------------------------------------
-- 6. Embedded Web UI (HTML5, Responsive CSS, Vanilla JS)
--------------------------------------------------------------------------------
local function get_index_html(lan_ip, port)
    return [[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>LAN Drop & Clipboard</title>
  <style>
    :root {
      --bg: #0d1117;
      --card-bg: rgba(22, 27, 34, 0.85);
      --card-border: #30363d;
      --text: #f0f6fc;
      --text-muted: #8b949e;
      --accent: #58a6ff;
      --accent-hover: #79c0ff;
      --success: #3fb950;
      --danger: #f85149;
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
      align-items: center;
      padding: 16px;
    }
    .container {
      width: 100%;
      max-width: 860px;
      display: flex;
      flex-direction: column;
      gap: 16px;
    }
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 12px 18px;
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 12px;
      backdrop-filter: blur(8px);
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .brand h1 {
      font-size: 19px;
      font-weight: 700;
      letter-spacing: -0.3px;
    }
    .badge {
      font-size: 11px;
      background: rgba(88, 166, 255, 0.15);
      color: var(--accent);
      padding: 4px 10px;
      border-radius: 20px;
      font-family: monospace;
      font-weight: 600;
    }
    .tabs {
      display: flex;
      gap: 8px;
      border-bottom: 1px solid var(--card-border);
      padding-bottom: 8px;
    }
    .tab-btn {
      background: none;
      border: none;
      color: var(--text-muted);
      font-size: 14px;
      font-weight: 600;
      padding: 8px 16px;
      cursor: pointer;
      border-radius: 8px;
      transition: all 0.2s;
    }
    .tab-btn.active {
      background: var(--card-border);
      color: var(--text);
    }
    .panel { display: none; flex-direction: column; gap: 16px; }
    .panel.active { display: flex; }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 12px;
      padding: 18px;
      backdrop-filter: blur(8px);
    }
    /* Drop Zone */
    .dropzone {
      border: 2px dashed var(--card-border);
      border-radius: 12px;
      padding: 32px 16px;
      text-align: center;
      cursor: pointer;
      transition: border-color 0.2s, background 0.2s;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 8px;
    }
    .dropzone.dragover {
      border-color: var(--accent);
      background: rgba(88, 166, 255, 0.08);
    }
    .dropzone-icon { font-size: 36px; }
    .dropzone p { color: var(--text-muted); font-size: 13px; }
    .dropzone input { display: none; }
    /* File List */
    .file-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 12px 14px;
      border-bottom: 1px solid rgba(48, 54, 61, 0.5);
      transition: background 0.15s;
    }
    .file-item:last-child { border-bottom: none; }
    .file-item:hover { background: rgba(255, 255, 255, 0.02); }
    .file-info { display: flex; align-items: center; gap: 12px; min-width: 0; }
    .file-icon { font-size: 22px; flex-shrink: 0; }
    .file-name {
      font-size: 14px;
      font-weight: 500;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .file-meta { font-size: 12px; color: var(--text-muted); }
    .file-actions { display: flex; gap: 6px; flex-shrink: 0; }
    /* Buttons */
    .btn {
      padding: 6px 12px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 600;
      border: 1px solid var(--card-border);
      background: #21262d;
      color: var(--text);
      cursor: pointer;
      text-decoration: none;
      display: inline-flex;
      align-items: center;
      gap: 4px;
      transition: background 0.15s;
    }
    .btn:hover { background: #30363d; }
    .btn-primary { background: #1f6feb; border-color: #388bfd; color: #fff; }
    .btn-primary:hover { background: #388bfd; }
    .btn-danger { color: var(--danger); }
    .btn-danger:hover { background: rgba(248, 81, 73, 0.15); border-color: var(--danger); }
    /* Clipboard Panel */
    .clip-textarea {
      width: 100%;
      height: 120px;
      background: #0d1117;
      border: 1px solid var(--card-border);
      border-radius: 8px;
      color: var(--text);
      font-family: var(--font);
      font-size: 14px;
      padding: 12px;
      resize: vertical;
      outline: none;
    }
    .clip-textarea:focus { border-color: var(--accent); }
    .clip-history-item {
      background: #161b22;
      border: 1px solid var(--card-border);
      border-radius: 8px;
      padding: 12px;
      margin-top: 10px;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .clip-text-preview {
      font-family: monospace;
      font-size: 13px;
      word-break: break-all;
      white-space: pre-wrap;
      max-height: 140px;
      overflow-y: auto;
    }
    .clip-footer {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 11px;
      color: var(--text-muted);
      margin-top: 4px;
    }
    /* Toast Notification */
    #toast {
      position: fixed;
      bottom: 24px;
      right: 24px;
      background: #1f6feb;
      color: white;
      padding: 10px 18px;
      border-radius: 8px;
      font-size: 13px;
      font-weight: 500;
      opacity: 0;
      transform: translateY(10px);
      transition: all 0.2s ease;
      pointer-events: none;
      z-index: 1000;
    }
    #toast.show { opacity: 1; transform: translateY(0); }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="brand">
        <span style="font-size:24px;">⚡</span>
        <div>
          <h1>LAN Drop</h1>
          <div style="font-size:11px; color:var(--text-muted)">Cross-Device Sharing</div>
        </div>
      </div>
      <div class="badge" id="lan-badge">]] .. lan_ip .. ":" .. port .. [[</div>
    </header>

    <div class="tabs">
      <button class="tab-btn active" onclick="switchTab('files')">📁 Files (<span id="files-count">0</span>)</button>
      <button class="tab-btn" onclick="switchTab('clipboard')">📋 Clipboard (<span id="clips-count">0</span>)</button>
    </div>

    <!-- Files Panel -->
    <div id="panel-files" class="panel active">
      <div class="dropzone" id="dropzone" onclick="document.getElementById('file-input').click()">
        <span class="dropzone-icon">📥</span>
        <div style="font-weight:600; font-size:15px;">Tap to choose or drag files here</div>
        <p>Send photos, videos, and documents instantly across your local network</p>
        <input type="file" id="file-input" multiple onchange="handleFileSelect(this.files)">
      </div>

      <div class="card" id="file-list-card">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
          <h2 style="font-size:15px; font-weight:600;">Shared Files</h2>
          <button class="btn" onclick="loadFiles()">Refresh ↻</button>
        </div>
        <div id="file-list-container">
          <p style="text-align:center; color:var(--text-muted); padding:20px 0;">Loading shared files...</p>
        </div>
      </div>
    </div>

    <!-- Clipboard Panel -->
    <div id="panel-clipboard" class="panel">
      <div class="card">
        <h2 style="font-size:15px; font-weight:600; margin-bottom:10px;">Send Text to LAN</h2>
        <textarea id="clip-input" class="clip-textarea" placeholder="Paste or type text, code, or link here..."></textarea>
        <div style="display:flex; justify-content:space-between; margin-top:10px;">
          <button class="btn" onclick="clearInput()">Clear</button>
          <button class="btn btn-primary" onclick="sendClipboard()">🚀 Broadcast to LAN</button>
        </div>
      </div>

      <div class="card">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
          <h2 style="font-size:15px; font-weight:600;">Shared Clipboard History</h2>
          <div style="display:flex; gap:6px;">
            <button class="btn" onclick="loadClipboard()">Refresh ↻</button>
            <button class="btn btn-danger" onclick="clearClipboardHistory()">Clear All</button>
          </div>
        </div>
        <div id="clipboard-container">
          <p style="text-align:center; color:var(--text-muted); padding:20px 0;">No text shared yet.</p>
        </div>
      </div>
    </div>
  </div>

  <div id="toast"></div>

  <script>
    function showToast(msg) {
      const t = document.getElementById('toast');
      t.textContent = msg;
      t.classList.add('show');
      setTimeout(() => t.classList.remove('show'), 2500);
    }

    function switchTab(tab) {
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
      if (tab === 'files') {
        document.querySelector('.tab-btn:nth-child(1)').classList.add('active');
        document.getElementById('panel-files').classList.add('active');
      } else {
        document.querySelector('.tab-btn:nth-child(2)').classList.add('active');
        document.getElementById('panel-clipboard').classList.add('active');
      }
    }

    function clearInput() {
      document.getElementById('clip-input').value = '';
    }

    // Drag and Drop
    const dz = document.getElementById('dropzone');
    ['dragenter', 'dragover'].forEach(e => {
      dz.addEventListener(e, (evt) => { evt.preventDefault(); dz.classList.add('dragover'); });
    });
    ['dragleave', 'drop'].forEach(e => {
      dz.addEventListener(e, (evt) => { evt.preventDefault(); dz.classList.remove('dragover'); });
    });
    dz.addEventListener('drop', (evt) => {
      if (evt.dataTransfer && evt.dataTransfer.files) {
        handleFileSelect(evt.dataTransfer.files);
      }
    });

    async function handleFileSelect(files) {
      if (!files || files.length === 0) return;
      for (const file of files) {
        showToast('Uploading ' + file.name + '...');
        try {
          const res = await fetch('/api/upload?name=' + encodeURIComponent(file.name), {
            method: 'POST',
            body: file
          });
          const data = await res.json();
          if (data.ok) {
            showToast('Uploaded: ' + file.name);
          } else {
            showToast('Error: ' + (data.error || 'Upload failed'));
          }
        } catch (e) {
          showToast('Upload error: ' + e.message);
        }
      }
      loadFiles();
    }

    async function loadFiles() {
      try {
        const res = await fetch('/api/files');
        const list = await res.json();
        document.getElementById('files-count').textContent = list.length;
        const container = document.getElementById('file-list-container');
        if (list.length === 0) {
          container.innerHTML = '<p style="text-align:center; color:var(--text-muted); padding:20px 0;">No shared files yet. Drag or choose a file above!</p>';
          return;
        }
        let html = '';
        list.forEach(f => {
          let icon = '📄';
          if (f.is_image) icon = '🖼️';
          else if (f.name.match(/\.(zip|tar|gz|rar|7z)$/i)) icon = '📦';
          else if (f.name.match(/\.(mp3|wav|ogg)$/i)) icon = '🎵';
          else if (f.name.match(/\.(mp4|webm|mkv)$/i)) icon = '🎬';

          html += `
            <div class="file-item">
              <div class="file-info">
                <span class="file-icon">${icon}</span>
                <div>
                  <div class="file-name" title="${f.name}">${f.name}</div>
                  <div class="file-meta">${f.size_fmt}</div>
                </div>
              </div>
              <div class="file-actions">
                ${(f.is_image || f.is_text) ? `<a href="/view/${encodeURIComponent(f.name)}" target="_blank" class="btn">View</a>` : ''}
                <a href="/download/${encodeURIComponent(f.name)}" class="btn btn-primary">Download</a>
                <button class="btn btn-danger" onclick="deleteFile('${encodeURIComponent(f.name)}')">Delete</button>
              </div>
            </div>`;
        });
        container.innerHTML = html;
      } catch (err) {
        console.error(err);
      }
    }

    async function deleteFile(name) {
      if (!confirm('Delete file ' + decodeURIComponent(name) + '?')) return;
      try {
        const res = await fetch('/api/delete?name=' + name, { method: 'POST' });
        const data = await res.json();
        if (data.ok) {
          showToast('Deleted file');
          loadFiles();
        } else {
          showToast('Delete failed: ' + (data.error || ''));
        }
      } catch (e) {
        showToast('Error: ' + e.message);
      }
    }

    // Clipboard Logic
    async function sendClipboard() {
      const text = document.getElementById('clip-input').value.trim();
      if (!text) return;
      try {
        const res = await fetch('/api/clipboard', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text: text })
        });
        const data = await res.json();
        if (data.ok) {
          showToast('Text broadcasted to LAN!');
          clearInput();
          loadClipboard();
        }
      } catch (e) {
        showToast('Error broadcasting text');
      }
    }

    async function copyToClipboard(text) {
      try {
        await navigator.clipboard.writeText(text);
        showToast('Copied to device clipboard!');
      } catch (e) {
        showToast('Failed to copy');
      }
    }

    async function loadClipboard() {
      try {
        const res = await fetch('/api/clipboard');
        const data = await res.json();
        const history = data.history || [];
        document.getElementById('clips-count').textContent = history.length;
        const container = document.getElementById('clipboard-container');
        if (history.length === 0) {
          container.innerHTML = '<p style="text-align:center; color:var(--text-muted); padding:20px 0;">No text shared yet.</p>';
          return;
        }
        let html = '';
        history.forEach(item => {
          const safeText = item.text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
          const rawEscaped = encodeURIComponent(item.text);
          html += `
            <div class="clip-history-item">
              <div class="clip-text-preview">${safeText}</div>
              <div class="clip-footer">
                <span>${item.date} ${item.time}</span>
                <div style="display:flex; gap:6px;">
                  ${item.is_url ? `<a href="${item.text}" target="_blank" class="btn">Open Link ↗</a>` : ''}
                  <button class="btn btn-primary" onclick="copyToClipboard(decodeURIComponent('${rawEscaped}'))">📋 Copy</button>
                </div>
              </div>
            </div>`;
        });
        container.innerHTML = html;
      } catch (e) {
        console.error(e);
      }
    }

    async function clearClipboardHistory() {
      if (!confirm('Clear all clipboard history?')) return;
      try {
        await fetch('/api/clipboard/clear', { method: 'POST' });
        showToast('Cleared clipboard history');
        loadClipboard();
      } catch (e) {
        showToast('Error clearing clipboard');
      }
    }

    // Polling updates every 3 seconds
    loadFiles();
    loadClipboard();
    setInterval(() => {
      loadFiles();
      loadClipboard();
    }, 3000);
  </script>
</body>
</html>]]
end

--------------------------------------------------------------------------------
-- 7. HTTP Server Engine
--------------------------------------------------------------------------------
local function run_server(host, port, storage_dir)
    local storage = Storage.new(storage_dir)
    local clips = ClipboardStore.new()
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
    bind_addr.sin_port = C.htons(port)
    bind_addr.sin_addr.s_addr = (host == "0.0.0.0") and 0 or C.inet_addr(host)

    local bind_res
    if is_windows then
        bind_res = ws2.bind(listen_sock, bind_addr, ffi.sizeof(bind_addr))
    else
        bind_res = C.bind(listen_sock, bind_addr, ffi.sizeof(bind_addr))
    end
    if bind_res ~= 0 then
        io.stderr:write("Failed to bind to " .. host .. ":" .. port .. "\n")
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
    print("╔═══════════════════════════════════════════════════════════════════════════╗")
    print("║                   LAN Drop & Cross-Device Clipboard                       ║")
    print("╠═══════════════════════════════════════════════════════════════════════════╣")
    print(string.format("║  • Local:      http://127.0.0.1:%-43d║", port))
    print(string.format("║  • LAN WiFi:   http://%s:%-37d║", lan_ip, port))
    print(string.format("║  • Shared Dir: %-58s║", storage.dir))
    print("║                                                                           ║")
    print("║  Open the link on your phone, laptop, or tablet to start sharing!         ║")
    print("╚═══════════════════════════════════════════════════════════════════════════╝")
    io.stdout:flush()

    local buf_size = 65536
    local buf = ffi.new("char[?]", buf_size)

    local function send_response(client_sock, status_code, content_type, body, extra_headers)
        local status_text = (status_code == 200 and "OK") or (status_code == 404 and "Not Found") or (status_code == 400 and "Bad Request") or "Server Error"
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

    while true do
        local client_addr = ffi.new("struct sockaddr_in")
        local addr_len = ffi.new(is_windows and "int[1]" or "unsigned int[1]", ffi.sizeof(client_addr))
        local client_sock
        if is_windows then
            client_sock = ws2.accept(listen_sock, client_addr, addr_len)
        else
            client_sock = C.accept(listen_sock, client_addr, addr_len)
        end

        if client_sock ~= INVALID_SOCK and client_sock >= 0 then
            -- Read headers
            local req_raw = ""
            local header_end = nil
            while not header_end do
                local n
                if is_windows then
                    n = ws2.recv(client_sock, buf, buf_size, 0)
                else
                    n = C.recv(client_sock, buf, buf_size, 0)
                end
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

                -- Respond to Expect: 100-continue if requested by client
                if header_part:find("[Ee]xpect:%s*100%-continue") then
                    local cont = "HTTP/1.1 100 Continue\r\n\r\n"
                    local MSG_NOSIGNAL = is_windows and 0 or 0x4000
                    if is_windows then ws2.send(client_sock, cont, #cont, 0) else C.send(client_sock, cont, #cont, MSG_NOSIGNAL) end
                end

                local content_length = tonumber(header_part:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
                local needed = content_length - #body_so_far

                -- Handle file uploads via streaming write directly to disk
                if url_path == "/api/upload" and method == "POST" then
                    local name = query_str:match("name=([^&]+)")
                    if name then
                        name = name:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                    end
                    if not name or #name == 0 then
                        name = "upload_" .. os.time() .. ".bin"
                    end
                    local stream, s_err = storage:save_file_stream(name)
                    if not stream then
                        send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = s_err or "Invalid filename" }))
                    else
                        if #body_so_far > 0 then
                            stream:write(body_so_far)
                        end
                        while needed > 0 do
                            local to_read = math.min(needed, buf_size)
                            local n
                            if is_windows then
                                n = ws2.recv(client_sock, buf, to_read, 0)
                            else
                                n = C.recv(client_sock, buf, to_read, 0)
                            end
                            n = tonumber(n)
                            if not n or n <= 0 then break end
                            stream:write(ffi.string(buf, n))
                            needed = needed - n
                        end
                        if needed <= 0 then
                            local ok_fin, res_name = stream:finish()
                            if ok_fin then
                                send_response(client_sock, 200, "application/json", json.encode({ ok = true, file = res_name }))
                            else
                                send_response(client_sock, 500, "application/json", json.encode({ ok = false, error = "Save failed" }))
                            end
                        else
                            stream:abort()
                            send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = "Incomplete upload" }))
                        end
                    end
                else
                    -- For non-streaming endpoints, buffer body chunks
                    local chunks = { body_so_far }
                    while needed > 0 do
                        local to_read = math.min(needed, buf_size)
                        local n
                        if is_windows then
                            n = ws2.recv(client_sock, buf, to_read, 0)
                        else
                            n = C.recv(client_sock, buf, to_read, 0)
                        end
                        n = tonumber(n)
                        if not n or n <= 0 then break end
                        table.insert(chunks, ffi.string(buf, n))
                        needed = needed - n
                    end
                    local full_body = table.concat(chunks)

                    -- Route handling
                    if url_path == "/" or url_path == "/index.html" then
                        send_response(client_sock, 200, "text/html; charset=utf-8", get_index_html(lan_ip, port))
                    elseif url_path == "/api/status" then
                        local files = storage:list_files()
                        local resp = {
                            lan_ip = lan_ip,
                            port = port,
                            dir = storage.dir,
                            files_count = #files,
                            version = LANDROP_VERSION,
                        }
                        send_response(client_sock, 200, "application/json", json.encode(resp))
                    elseif url_path == "/api/files" then
                        local files = storage:list_files()
                        send_response(client_sock, 200, "application/json", json.encode(files))
                elseif url_path:find("^/download/") then
                    local req_file = url_path:sub(11)
                    req_file = req_file:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                    local content, safe_name = storage:read_file(req_file)
                    if content then
                        local headers = {
                            ["Content-Disposition"] = 'attachment; filename="' .. safe_name .. '"'
                        }
                        send_response(client_sock, 200, get_mime_type(safe_name), content, headers)
                    else
                        send_response(client_sock, 404, "application/json", json.encode({ ok = false, error = "File not found" }))
                    end
                elseif url_path:find("^/view/") then
                    local req_file = url_path:sub(7)
                    req_file = req_file:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                    local content, safe_name = storage:read_file(req_file)
                    if content then
                        send_response(client_sock, 200, get_mime_type(safe_name), content)
                    else
                        send_response(client_sock, 404, "application/json", json.encode({ ok = false, error = "File not found" }))
                    end
                elseif url_path == "/api/delete" and method == "POST" then
                    local name = query_str:match("name=([^&]+)")
                    if name then
                        name = name:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
                    end
                    if name and storage:delete_file(name) then
                        send_response(client_sock, 200, "application/json", json.encode({ ok = true }))
                    else
                        send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = "Could not delete file" }))
                    end
                elseif url_path == "/api/clipboard" then
                    if method == "GET" then
                        send_response(client_sock, 200, "application/json", json.encode(clips:get_data()))
                    elseif method == "POST" then
                        local ok_json, payload = pcall(json.decode, full_body)
                        local text = (ok_json and type(payload) == "table" and payload.text) or full_body
                        local ok, item = clips:set_text(text)
                        if ok then
                            send_response(client_sock, 200, "application/json", json.encode({ ok = true, item = item }))
                        else
                            send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = "Empty text" }))
                        end
                    end
                elseif url_path == "/api/clipboard/clear" and method == "POST" then
                    clips:clear()
                    send_response(client_sock, 200, "application/json", json.encode({ ok = true }))
                else
                    send_response(client_sock, 404, "application/json", json.encode({ error = "Not Found" }))
                end
            end
        end
        close_socket(client_sock)
        end
    end
end

--------------------------------------------------------------------------------
-- 8. Main CLI & Module Dispatcher
--------------------------------------------------------------------------------
local M = {
    Storage = Storage,
    ClipboardStore = ClipboardStore,
    sanitize_filename = sanitize_filename,
    format_bytes = format_bytes,
    get_mime_type = get_mime_type,
    get_local_lan_ip = get_local_lan_ip,
}

local function parse_args(argv)
    local opts = {
        port = 8040,
        host = "0.0.0.0",
        dir  = "./shared_files",
        test = false,
    }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--port" or a == "-p" then
            i = i + 1
            opts.port = tonumber(argv[i]) or 8040
        elseif a == "--host" or a == "-h" then
            i = i + 1
            opts.host = argv[i] or "0.0.0.0"
        elseif a == "--dir" or a == "-d" then
            i = i + 1
            opts.dir = argv[i] or "./shared_files"
        elseif a == "--test" then
            opts.test = true
        elseif a == "--help" then
            print("Usage: luajit landrop_web.lua [--port 8040] [--host 0.0.0.0] [--dir ./shared_files] [--test]")
            os.exit(0)
        end
        i = i + 1
    end
    return opts
end

if pcall(debug.getlocal, 4, 1) then
    return M
else
    local opts = parse_args(arg)
    if opts.test then
        print("Run test suite: luajit test_landrop_web.lua")
        os.exit(0)
    end
    run_server(opts.host, opts.port, opts.dir)
end
