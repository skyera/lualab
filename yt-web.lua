#!/usr/bin/env luajit
-- =========================================================================
-- yt-web.lua
-- Cross-Platform YouTube & YouTube Music Web Server & Browser in LuaJIT FFI
--
-- Features:
-- 1. In-Browser Audio & Video Streaming:
--    - Direct stream extraction via yt-dlp -g for native HTML5 <video>/<audio>.
--    - Zero-dependency YouTube Privacy-Enhanced iframe embed fallback.
--    - Full browser navigator.mediaSession support (lock screen & media keys).
-- 2. Powerful Dual Search Engine:
--    - Primary: yt-dlp with flat-playlist JSON extraction (YouTube, SoundCloud, Twitch).
--    - Automatic Fallback: Direct YouTube HTML scraping via curl (no keys needed).
--    - Search filters: Music/Video modes, Duration, Sort order, and Site.
-- 3. Queue & Playlist Management:
--    - Interactive Up Next queue, auto-advance, shuffle, and repeat modes.
-- 4. Instant Mobile Pairing:
--    - QR Code modal encoding local Wi-Fi IP for one-tap phone connect.
-- 5. Offline Download Center:
--    - Download tracks as MP3 (audio) or MP4 (video) via yt-dlp.
-- =========================================================================

local ffi = require("ffi")

local script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
if script_dir and script_dir ~= "" then
    package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path
end

local json
local has_json, json_mod = pcall(require, "json")
if has_json and type(json_mod) == "table" and json_mod.encode and json_mod.decode then
    json = json_mod
else
    -- Minimal fallback JSON serializer & parser
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
                local s_start = pos
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

local YTWEB_VERSION = "0.1.0"
local is_windows = (ffi.os == "Windows")
local POPEN_READ_BIN = is_windows and "rb" or "r"
local ws2

-- =========================================================================
-- 1. Sockets & Networking FFI (POSIX & Windows)
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
local INVALID_SOCK = is_windows and ffi.cast("SOCKET", -1) or -1

local function cmd_exists(cmd)
    local check_cmd = is_windows and ("where " .. cmd .. " >nul 2>nul") or ("which " .. cmd .. " >/dev/null 2>&1")
    return os.execute(check_cmd) == 0
end

local HAS_YTDLP  = cmd_exists("yt-dlp")
local HAS_FFMPEG = cmd_exists("ffmpeg")

local function close_socket(sock)
    if is_windows then
        ws2.closesocket(sock)
    else
        C.close(sock)
    end
end

-- =========================================================================
-- 2. Encoding, Decoding & Text Normalization Helpers
-- =========================================================================
local function sanitize_filename(name)
    if not name or type(name) ~= "string" or #name == 0 then return nil end
    local clean = name:gsub("^.*[/\\]", ""):gsub("[^%w%._%- ]", "_")
    if clean == "" or clean == "." or clean == ".." then return nil end
    return clean
end

local function url_decode(str)
    if not str then return "" end
    str = str:gsub("+", " ")
    return (str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function url_encode(str)
    if not str then return "" end
    return (str:gsub("([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function parse_query_params(url_str)
    local params = {}
    local q_start = url_str:find("?", 1, true)
    if not q_start then return params end
    local query = url_str:sub(q_start + 1)
    for pair in query:gmatch("[^&]+") do
        local k, v = pair:match("^(.-)=(.*)$")
        if k then
            params[url_decode(k)] = url_decode(v or "")
        else
            params[url_decode(pair)] = ""
        end
    end
    return params
end

local function format_duration(sec)
    sec = tonumber(sec) or 0
    if sec <= 0 then return "--:--" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = math.floor(sec % 60)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

local function format_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return string.format("%d B", bytes) end
    if bytes < 1048576 then return string.format("%.1f KB", bytes / 1024) end
    if bytes < 1073741824 then return string.format("%.1f MB", bytes / 1048576) end
    return string.format("%.2f GB", bytes / 1073741824)
end

local function unescape_unicode(s)
    if not s or type(s) ~= "string" then return "" end
    s = s:gsub("\\u([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])", function(code)
        local n = tonumber(code, 16)
        if not n then return "" end
        if n < 0x80 then
            return string.char(n)
        elseif n < 0x800 then
            return string.char(0xC0 + math.floor(n / 0x40), 0x80 + (n % 0x40))
        else
            return string.char(0xE0 + math.floor(n / 0x1000),
                               0x80 + (math.floor(n / 0x40) % 0x40),
                               0x80 + (n % 0x40))
        end
    end)
    return s
end

local function sanitize_display_text(s)
    if not s or type(s) ~= "string" then return "" end
    s = s:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&#([0-9]+);", function(code)
        local n = tonumber(code)
        if n and n > 0 and n < 128 then return string.char(n) end
        return ""
    end)
    s = s:gsub("{[^}]-}", ""):gsub("<[^>]->", "")
    return s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_json_field(line, key)
    local pat = '"' .. key .. '"%s*:%s*"'
    local s, e = line:find(pat)
    if s then
        local pos = e + 1
        local chars = {}
        local len = #line
        while pos <= len do
            local b = line:sub(pos, pos)
            if b == "\\" then
                pos = pos + 1
                local next_b = line:sub(pos, pos)
                if next_b == '"' then table.insert(chars, '"')
                elseif next_b == "\\" then table.insert(chars, "\\")
                elseif next_b == "/" then table.insert(chars, "/")
                elseif next_b == "n" then table.insert(chars, "\n")
                elseif next_b == "r" then table.insert(chars, "\r")
                elseif next_b == "t" then table.insert(chars, "\t")
                elseif next_b == "u" then
                    local u_part = line:sub(pos - 1, pos + 4)
                    table.insert(chars, u_part)
                    pos = pos + 4
                else table.insert(chars, next_b) end
            elseif b == '"' then
                local res = unescape_unicode(table.concat(chars))
                if key == "title" or key == "uploader" or key == "channel" then
                    res = sanitize_display_text(res)
                end
                return res
            else
                table.insert(chars, b)
            end
            pos = pos + 1
        end
    end
    local num = line:match('"' .. key .. '"%s*:%s*([%d%.]+)')
    if num then return tonumber(num) end
    local bool = line:match('"' .. key .. '"%s*:%s*(true)') or line:match('"' .. key .. '"%s*:%s*(false)')
    if bool == "true" then return true end
    if bool == "false" then return false end
    return nil
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

-- =========================================================================
-- 3. YouTube Search Engine (yt-dlp + Direct Scrape Fallback)
-- =========================================================================
local SITE_SEARCH_PREFIXES = {
    youtube = "ytsearch",
    soundcloud = "scsearch",
    twitch = "twsearch",
}

local function normalize_site(site)
    site = (site or "youtube"):lower():gsub("^https?://", ""):gsub("^www%.", "")
    if site == "youtube.com" or site == "music.youtube.com" then return "youtube" end
    if site == "soundcloud.com" then return "soundcloud" end
    if site == "twitch.tv" then return "twitch" end
    return site
end

local function scrape_youtube_search(query, max_results, proxy, insecure)
    if not query or #query == 0 then return nil end
    max_results = max_results or 20
    local encoded = url_encode(query)
    local proxy_opt = (proxy and #proxy > 0) and string.format(" -x %q", proxy) or ""
    local sec_opt = insecure and " -k" or ""
    local url = "https://www.youtube.com/results?search_query=" .. encoded
    local cmd = string.format('curl -s -L --max-time 8%s%s -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" %q',
        sec_opt, proxy_opt, url)
    local p = io.popen(cmd, POPEN_READ_BIN)
    if not p then return nil end
    local html = p:read("*a")
    p:close()
    if not html or #html < 500 then return nil end

    local items = {}
    local seen = {}
    for block in html:gmatch('"videoRenderer":%b{}') do
        local id = block:match('"videoId"%s*:%s*"([%w%-_]+)"')
        local title_part = block:match('"title"%s*:%s*%b{}')
        local title = title_part and title_part:match('"text"%s*:%s*"(.-)"')
        local owner_part = block:match('"ownerText"%s*:%s*%b{}') or block:match('"longBylineText"%s*:%s*%b{}')
        local channel = owner_part and owner_part:match('"text"%s*:%s*"(.-)"') or "YouTube"
        local len_part = block:match('"lengthText"%s*:%s*%b{}')
        local duration_str = len_part and len_part:match('"simpleText"%s*:%s*"(.-)"') or "--:--"

        if id and title and not seen[id] then
            seen[id] = true
            table.insert(items, {
                id = id,
                url = "https://www.youtube.com/watch?v=" .. id,
                title = sanitize_display_text(unescape_unicode(title)),
                uploader = sanitize_display_text(unescape_unicode(channel)),
                duration = 0,
                duration_str = duration_str,
                thumbnail = string.format("https://i.ytimg.com/vi/%s/hqdefault.jpg", id),
                site = "youtube",
            })
            if #items >= max_results then break end
        end
    end
    return items
end

local function build_search_spec(query, mode, max_results, filters, site)
    site = normalize_site(site)
    local is_direct_url = query:match("^https?://") or query:match("^www%.") or query:match("^youtu%.be/")
    if is_direct_url then
        return string.format("%q", query)
    elseif filters and filters.sort and filters.sort ~= "relevance" and site == "youtube" then
        local sp_map = {
            views = "CAM%253D",
            date = "CAI%253D",
            rating = "CAE%253D"
        }
        local sp = sp_map[filters.sort]
        if sp then
            local enc_term = query:gsub("%s+", "+")
            return string.format('"https://www.youtube.com/results?search_query=%s&sp=%s"', enc_term, sp)
        else
            return string.format('"ytsearch%d:%s"', max_results, query:gsub('"', '\\"'))
        end
    elseif SITE_SEARCH_PREFIXES[site] then
        return string.format('"%s%d:%s"', SITE_SEARCH_PREFIXES[site], max_results, query:gsub('"', '\\"'))
    else
        return string.format('"ytsearch%d:%s"', max_results, query:gsub('"', '\\"'))
    end
end

local function fetch_search_results(query, mode, browser, cookies_file, max_results, proxy, insecure, filters, site)
    max_results = max_results or 20
    site = normalize_site(site)
    local is_direct_url = query:match("^https?://") or query:match("^www%.") or query:match("^youtu%.be/")

    local items = {}
    local err_lines = {}

    if HAS_YTDLP then
        local search_spec = build_search_spec(query, mode, max_results, filters, site)
        local extra_opts = ""
        if browser and #browser > 0 then
            extra_opts = extra_opts .. string.format(" --cookies-from-browser %s", browser)
        elseif cookies_file and #cookies_file > 0 then
            extra_opts = extra_opts .. string.format(" --cookies %q", cookies_file)
        end
        if insecure then extra_opts = extra_opts .. " --no-check-certificates" end
        if proxy and #proxy > 0 then extra_opts = extra_opts .. string.format(" --proxy %q", proxy) end

        local redirect = "2>&1"
        local cmd = string.format('yt-dlp --dump-json --flat-playlist --skip-download%s %s %s',
            extra_opts, search_spec, redirect)

        local p = io.popen(cmd, POPEN_READ_BIN)
        if p then
            for line in p:lines() do
                if line:sub(1, 1) == "{" then
                    local id = parse_json_field(line, "id")
                    local title = parse_json_field(line, "title")
                    if id and title then
                        local uploader = parse_json_field(line, "uploader") or parse_json_field(line, "channel") or site
                        local duration = parse_json_field(line, "duration") or 0
                        local thumb = parse_json_field(line, "thumbnail")
                        local item_url = parse_json_field(line, "webpage_url") or parse_json_field(line, "url")
                        if not item_url and site == "youtube" then
                            item_url = "https://www.youtube.com/watch?v=" .. id
                        end
                        if not thumb and site == "youtube" then
                            thumb = string.format("https://i.ytimg.com/vi/%s/hqdefault.jpg", id)
                        end
                        if item_url then
                            table.insert(items, {
                                id = id,
                                url = item_url,
                                title = title,
                                uploader = uploader,
                                duration = duration,
                                duration_str = format_duration(duration),
                                thumbnail = thumb or "",
                                site = site,
                            })
                        end
                    end
                else
                    if line:find("ERROR") or line:find("WARNING") or line:find("SSL") or line:find("bot") then
                        table.insert(err_lines, line)
                    end
                end
            end
            p:close()
        end
    end

    if filters and filters.duration and filters.duration ~= "all" then
        local filtered = {}
        for _, it in ipairs(items) do
            local d = it.duration or 0
            if filters.duration == "short" and (d == 0 or d < 240) then
                table.insert(filtered, it)
            elseif filters.duration == "medium" and d >= 240 and d <= 1200 then
                table.insert(filtered, it)
            elseif filters.duration == "long" and d > 1200 then
                table.insert(filtered, it)
            end
        end
        items = filtered
    end

    if #items > 0 then return items, nil end

    -- Fallback: Direct Web Scrape via curl
    if site == "youtube" and not is_direct_url and query and #query > 0 then
        local fallback = scrape_youtube_search(query, max_results, proxy, insecure)
        if fallback and #fallback > 0 then return fallback, nil end
    end

    local err_msg = "No results found for '" .. query .. "'."
    if #err_lines > 0 then
        err_msg = err_lines[1]:gsub("^ERROR:%s*", "")
    end
    return {}, err_msg
end

-- =========================================================================
-- 4. Stream & Direct Media URL Resolver
-- =========================================================================
local function resolve_stream_url(id_or_url, mode, browser, cookies_file, proxy, insecure)
    if not id_or_url or #id_or_url == 0 then return nil, "Invalid track identifier" end
    local target_url = id_or_url
    if not target_url:match("^https?://") then
        target_url = "https://www.youtube.com/watch?v=" .. id_or_url
    end

    if not HAS_YTDLP then
        -- Return embed player fallback
        local clean_id = id_or_url:match("v=([%w%-_]+)") or id_or_url:match("youtu%.be/([%w%-_]+)") or id_or_url
        return {
            ok = true,
            is_embed = true,
            embed_url = string.format("https://www.youtube-nocookie.com/embed/%s?autoplay=1&enablejsapi=1", clean_id),
            id = clean_id,
            url = target_url,
        }
    end

    local extra_opts = ""
    if browser and #browser > 0 then extra_opts = extra_opts .. string.format(" --cookies-from-browser %s", browser)
    elseif cookies_file and #cookies_file > 0 then extra_opts = extra_opts .. string.format(" --cookies %q", cookies_file) end
    if insecure then extra_opts = extra_opts .. " --no-check-certificates" end
    if proxy and #proxy > 0 then extra_opts = extra_opts .. string.format(" --proxy %q", proxy) end

    -- Audio prefers high quality AAC/M4A/Opus stream playable in browser HTML5 audio element
    -- Video prefers MP4 with video+audio muxed (format 18 / 22) or best mp4 container
    local format_opt = (mode == "music")
        and '-f "bestaudio[ext=m4a]/bestaudio/best[ext=mp4]/best"'
        or '-f "best[ext=mp4][height<=1080]/best[height<=720]/best"'

    local cmd = string.format('yt-dlp -g %s%s %q 2>&1', format_opt, extra_opts, target_url)
    local p = io.popen(cmd, POPEN_READ_BIN)
    if not p then return nil, "Failed to invoke stream resolver" end

    local out_urls = {}
    for line in p:lines() do
        line = line:gsub("%s+$", "")
        if line:match("^https?://") then
            table.insert(out_urls, line)
        end
    end
    p:close()

    local clean_id = id_or_url:match("v=([%w%-_]+)") or id_or_url:match("youtu%.be/([%w%-_]+)") or id_or_url
    if #out_urls > 0 then
        return {
            ok = true,
            is_embed = false,
            stream_url = out_urls[1],
            id = clean_id,
            url = target_url,
            mode = mode or "music",
        }
    else
        -- Fallback to embed
        return {
            ok = true,
            is_embed = true,
            embed_url = string.format("https://www.youtube-nocookie.com/embed/%s?autoplay=1&enablejsapi=1", clean_id),
            id = clean_id,
            url = target_url,
        }
    end
end

-- =========================================================================
-- 5. Embedded Web UI (HTML5, Responsive CSS, Vanilla JS)
-- =========================================================================
local function get_index_html(lan_ip, port, default_mode)
    return [===[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>YouTube Web Player</title>
  <style>
    :root {
      --bg: #0b0f14;
      --card-bg: rgba(22, 27, 34, 0.88);
      --card-border: #30363d;
      --text: #f0f6fc;
      --text-muted: #8b949e;
      --accent: #58a6ff;
      --accent-hover: #79c0ff;
      --accent-red: #ff4d4f;
      --success: #3fb950;
      --player-bg: rgba(13, 17, 23, 0.96);
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
      padding-bottom: 96px; /* Space for bottom player */
    }
    header {
      background: rgba(13, 17, 23, 0.95);
      border-bottom: 1px solid var(--card-border);
      backdrop-filter: blur(12px);
      position: sticky;
      top: 0;
      z-index: 100;
      padding: 12px 18px;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .header-logo {
      display: flex;
      align-items: center;
      gap: 10px;
      cursor: pointer;
    }
    .logo-icon {
      font-size: 24px;
      color: var(--accent-red);
      line-height: 1;
    }
    .logo-title {
      font-weight: 700;
      font-size: 18px;
      letter-spacing: -0.3px;
    }
    .mode-pills {
      display: flex;
      background: #1c2128;
      border-radius: 20px;
      padding: 3px;
      border: 1px solid var(--card-border);
    }
    .mode-pill {
      padding: 5px 14px;
      font-size: 13px;
      font-weight: 600;
      border-radius: 16px;
      cursor: pointer;
      color: var(--text-muted);
      transition: all 0.2s ease;
      user-select: none;
    }
    .mode-pill.active {
      background: var(--accent);
      color: #0b0f14;
    }
    .btn {
      background: #21262d;
      color: var(--text);
      border: 1px solid var(--card-border);
      padding: 7px 14px;
      border-radius: 6px;
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: background 0.15s, border-color 0.15s;
    }
    .btn:hover { background: #30363d; border-color: #8b949e; }
    .btn-primary { background: var(--accent); color: #0b0f14; border: none; font-weight: 600; }
    .btn-primary:hover { background: var(--accent-hover); }

    .container {
      max-width: 1240px;
      width: 100%;
      margin: 0 auto;
      padding: 18px;
      display: flex;
      flex-direction: column;
      gap: 18px;
    }

    /* Search Bar */
    .search-box {
      display: flex;
      gap: 8px;
      position: relative;
    }
    .search-input {
      flex: 1;
      background: #161b22;
      border: 1px solid var(--card-border);
      color: var(--text);
      padding: 12px 18px;
      border-radius: 28px;
      font-size: 15px;
      outline: none;
      transition: border-color 0.2s, box-shadow 0.2s;
    }
    .search-input:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.2);
    }
    .search-btn {
      border-radius: 28px;
      padding: 0 24px;
    }

    /* Filters Bar */
    .filter-bar {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      align-items: center;
      font-size: 13px;
    }
    .filter-select {
      background: #161b22;
      border: 1px solid var(--card-border);
      color: var(--text);
      padding: 6px 12px;
      border-radius: 6px;
      outline: none;
      font-size: 13px;
      cursor: pointer;
    }

    /* Main Layout */
    .main-grid {
      display: grid;
      grid-template-columns: 1fr 340px;
      gap: 20px;
    }
    @media (max-width: 900px) {
      .main-grid { grid-template-columns: 1fr; }
    }

    /* Video Player Pane (Embedded or Native) */
    .player-pane {
      background: #000;
      border-radius: 12px;
      overflow: hidden;
      display: none;
      margin-bottom: 16px;
      box-shadow: 0 8px 24px rgba(0,0,0,0.5);
      position: relative;
    }
    .player-pane.active { display: block; }
    .video-viewport {
      width: 100%;
      height: 480px;
      max-height: 56vw;
      background: #000;
    }
    .video-viewport iframe, .video-viewport video {
      width: 100%;
      height: 100%;
      border: none;
      object-fit: contain;
    }

    /* Results Grid */
    .results-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
      gap: 16px;
    }
    .video-card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 10px;
      overflow: hidden;
      cursor: pointer;
      display: flex;
      flex-direction: column;
      transition: transform 0.15s, border-color 0.15s, box-shadow 0.15s;
    }
    .video-card:hover {
      transform: translateY(-2px);
      border-color: var(--accent);
      box-shadow: 0 6px 18px rgba(0,0,0,0.3);
    }
    .thumb-wrap {
      position: relative;
      width: 100%;
      padding-top: 56.25%; /* 16:9 ratio */
      background: #161b22;
    }
    .thumb-img {
      position: absolute;
      top: 0; left: 0;
      width: 100%; height: 100%;
      object-fit: cover;
    }
    .thumb-duration {
      position: absolute;
      bottom: 6px; right: 6px;
      background: rgba(0,0,0,0.8);
      color: #fff;
      font-size: 11px;
      font-weight: 600;
      padding: 2px 6px;
      border-radius: 4px;
      letter-spacing: 0.3px;
    }
    .card-body {
      padding: 10px 12px;
      display: flex;
      flex-direction: column;
      flex: 1;
    }
    .card-title {
      font-size: 14px;
      font-weight: 600;
      line-height: 1.35;
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      overflow: hidden;
      margin-bottom: 6px;
      color: var(--text);
    }
    .card-meta {
      font-size: 12px;
      color: var(--text-muted);
      margin-top: auto;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .card-actions {
      display: flex;
      gap: 6px;
      margin-top: 8px;
    }
    .card-actions button {
      flex: 1;
      padding: 4px 8px;
      font-size: 12px;
    }

    /* Queue Sidebar */
    .queue-card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 12px;
      padding: 14px;
      display: flex;
      flex-direction: column;
      max-height: 720px;
    }
    .queue-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
      padding-bottom: 8px;
      border-bottom: 1px solid var(--card-border);
    }
    .queue-list {
      overflow-y: auto;
      flex: 1;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .queue-item {
      display: flex;
      gap: 10px;
      align-items: center;
      padding: 8px;
      border-radius: 8px;
      background: rgba(255,255,255,0.03);
      border: 1px solid transparent;
      cursor: pointer;
    }
    .queue-item.active {
      border-color: var(--accent);
      background: rgba(88, 166, 255, 0.08);
    }
    .queue-thumb {
      width: 54px;
      height: 36px;
      border-radius: 4px;
      object-fit: cover;
      background: #1c2128;
    }
    .queue-info {
      flex: 1;
      min-width: 0;
    }
    .queue-title {
      font-size: 12px;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .queue-sub {
      font-size: 11px;
      color: var(--text-muted);
    }

    /* Persistent Bottom Player Bar */
    .bottom-player {
      position: fixed;
      bottom: 0; left: 0; right: 0;
      height: 84px;
      background: var(--player-bg);
      border-top: 1px solid var(--card-border);
      backdrop-filter: blur(14px);
      z-index: 200;
      display: flex;
      align-items: center;
      padding: 0 20px;
      gap: 16px;
    }
    .track-meta {
      display: flex;
      align-items: center;
      gap: 12px;
      width: 280px;
      min-width: 180px;
    }
    .track-thumb {
      width: 52px;
      height: 52px;
      border-radius: 6px;
      object-fit: cover;
      background: #1c2128;
    }
    .track-text {
      min-width: 0;
    }
    .track-title {
      font-size: 13px;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .track-artist {
      font-size: 11px;
      color: var(--text-muted);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .player-controls {
      flex: 1;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 6px;
      max-width: 640px;
    }
    .ctrl-btns {
      display: flex;
      align-items: center;
      gap: 14px;
    }
    .ctrl-btn {
      background: none;
      border: none;
      color: var(--text);
      cursor: pointer;
      font-size: 16px;
      transition: color 0.15s, transform 0.1s;
      outline: none;
    }
    .ctrl-btn:hover { color: var(--accent); }
    .play-btn {
      width: 38px;
      height: 38px;
      border-radius: 50%;
      background: var(--accent);
      color: #0b0f14;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 18px;
      font-weight: bold;
    }
    .play-btn:hover { background: var(--accent-hover); transform: scale(1.05); }
    .progress-wrap {
      width: 100%;
      display: flex;
      align-items: center;
      gap: 10px;
      font-size: 11px;
      color: var(--text-muted);
      font-family: monospace;
    }
    .progress-bar {
      flex: 1;
      height: 4px;
      background: #30363d;
      border-radius: 2px;
      position: relative;
      cursor: pointer;
    }
    .progress-bar:hover { height: 6px; }
    .progress-fill {
      height: 100%;
      background: var(--accent);
      border-radius: 2px;
      width: 0%;
      position: relative;
    }
    .player-extra {
      display: flex;
      align-items: center;
      gap: 12px;
      width: 220px;
      justify-content: flex-end;
    }
    .vol-slider {
      width: 80px;
      accent-color: var(--accent);
      cursor: pointer;
    }

    /* Modal */
    .modal-backdrop {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: rgba(0,0,0,0.7);
      backdrop-filter: blur(4px);
      z-index: 1000;
      display: none;
      align-items: center;
      justify-content: center;
      padding: 16px;
    }
    .modal-backdrop.open { display: flex; }
    .modal-card {
      background: #161b22;
      border: 1px solid var(--card-border);
      border-radius: 12px;
      max-width: 420px;
      width: 100%;
      padding: 20px;
      text-align: center;
      box-shadow: 0 16px 40px rgba(0,0,0,0.6);
    }
    .toast {
      position: fixed;
      bottom: 96px;
      right: 20px;
      background: #21262d;
      border: 1px solid var(--accent);
      color: var(--text);
      padding: 10px 18px;
      border-radius: 8px;
      font-size: 13px;
      z-index: 1000;
      display: none;
      box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    }
    .toast.show { display: block; animation: fadeIn 0.2s ease; }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: translateY(0); } }
  </style>
</head>
<body>
  <header>
    <div class="header-logo" onclick="window.scrollTo({top:0, behavior:'smooth'})">
      <span class="logo-icon">▶</span>
      <span class="logo-title">YouTube Web</span>
    </div>
    <div class="mode-pills">
      <div class="mode-pill active" id="pill-music" onclick="setMode('music')">🎵 Music</div>
      <div class="mode-pill" id="pill-video" onclick="setMode('video')">🎬 Video</div>
    </div>
    <div style="display:flex; align-items:center; gap:8px;">
      <button class="btn btn-primary" onclick="openQRModal()" title="Connect Mobile Phone">📱 Connect Phone</button>
      <div class="btn" style="cursor:default; font-family:monospace; color:var(--accent);">]===] .. lan_ip .. ":" .. port .. [===[</div>
    </div>
  </header>

  <div class="container">
    <!-- Search Bar -->
    <div class="search-box">
      <input type="text" id="search-input" class="search-input" placeholder="Search songs, artists, videos, or paste YouTube/SoundCloud URL..." onkeydown="if(event.key==='Enter') executeSearch()">
      <button class="btn btn-primary search-btn" onclick="executeSearch()">🔍 Search</button>
    </div>

    <!-- Filters Bar -->
    <div class="filter-bar">
      <span>Filters:</span>
      <select id="filter-site" class="filter-select" onchange="executeSearch()">
        <option value="youtube">YouTube</option>
        <option value="soundcloud">SoundCloud</option>
        <option value="twitch">Twitch</option>
      </select>
      <select id="filter-duration" class="filter-select" onchange="executeSearch()">
        <option value="all">All Durations</option>
        <option value="short">Short (&lt; 4m)</option>
        <option value="medium">Medium (4 - 20m)</option>
        <option value="long">Long (&gt; 20m)</option>
      </select>
      <select id="filter-sort" class="filter-select" onchange="executeSearch()">
        <option value="relevance">Sort: Relevance</option>
        <option value="date">Sort: Upload Date</option>
        <option value="views">Sort: View Count</option>
        <option value="rating">Sort: Rating</option>
      </select>
      <button class="btn" onclick="clearFilters()" style="padding:4px 10px; font-size:12px;">Reset</button>
    </div>

    <!-- Video Theater Pane (Active when playing Video mode) -->
    <div class="player-pane" id="player-pane">
      <div class="video-viewport" id="video-viewport">
        <!-- Replaced dynamically with <video> or <iframe> -->
      </div>
    </div>

    <!-- Main Content Grid -->
    <div class="main-grid">
      <!-- Search Results -->
      <div>
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
          <h2 style="font-size:16px; font-weight:600;" id="results-heading">Featured &amp; Search Results</h2>
          <span style="font-size:12px; color:var(--text-muted);" id="results-count">0 items</span>
        </div>
        <div class="results-grid" id="results-container">
          <p style="color:var(--text-muted); grid-column:1/-1; text-align:center; padding:40px 0;">
            Type a query or paste a URL above to explore YouTube &amp; Music streams.
          </p>
        </div>
      </div>

      <!-- Up Next Queue Sidebar -->
      <div>
        <div class="queue-card">
          <div class="queue-header">
            <h3 style="font-size:14px; font-weight:600;">Up Next (<span id="queue-count">0</span>)</h3>
            <div style="display:flex; gap:6px;">
              <button class="btn" style="padding:3px 8px; font-size:11px;" onclick="clearQueue()">Clear</button>
            </div>
          </div>
          <div class="queue-list" id="queue-container">
            <p style="color:var(--text-muted); font-size:12px; text-align:center; padding:20px 0;">Queue is empty.</p>
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- Persistent Bottom Player Bar -->
  <div class="bottom-player" id="bottom-player">
    <audio id="audio-elem" preload="auto" style="display:none;"></audio>
    <div class="track-meta">
      <img id="player-thumb" class="track-thumb" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='52' height='52' fill='%2321262d'%3E%3Crect width='52' height='52'/%3E%3C/svg%3E" alt="Thumbnail">
      <div class="track-text">
        <div id="player-title" class="track-title">Nothing playing</div>
        <div id="player-artist" class="track-artist">Select a track to start</div>
      </div>
    </div>

    <div class="player-controls">
      <div class="ctrl-btns">
        <button class="ctrl-btn" onclick="prevTrack()" title="Previous Track">⏮</button>
        <button class="ctrl-btn" onclick="seekRelative(-10)" title="Rewind 10s">↺ 10</button>
        <button class="ctrl-btn play-btn" id="play-pause-btn" onclick="togglePlayPause()" title="Play / Pause">▶</button>
        <button class="ctrl-btn" onclick="seekRelative(10)" title="Forward 10s">10 ↻</button>
        <button class="ctrl-btn" onclick="nextTrack()" title="Next Track">⏭</button>
      </div>
      <div class="progress-wrap">
        <span id="time-current">00:00</span>
        <div class="progress-bar" id="progress-bar" onclick="seekAbsolute(event)">
          <div class="progress-fill" id="progress-fill"></div>
        </div>
        <span id="time-total">00:00</span>
      </div>
    </div>

    <div class="player-extra">
      <button class="ctrl-btn" id="loop-btn" onclick="toggleLoop()" title="Loop Track">🔁</button>
      <span style="font-size:13px; cursor:pointer;" onclick="toggleMute()">🔊</span>
      <input type="range" class="vol-slider" min="0" max="1" step="0.05" value="1" oninput="setVolume(this.value)">
      <button class="btn" style="padding:4px 8px; font-size:11px;" id="mode-toggle-btn" onclick="togglePlayerView()">🎬 View</button>
    </div>
  </div>

  <!-- QR Code Modal -->
  <div class="modal-backdrop" id="qr-modal" onclick="if(event.target===this) closeQRModal()">
    <div class="modal-card">
      <h3 style="font-size:16px; font-weight:600; margin-bottom:12px;">📱 Connect Phone or Tablet</h3>
      <div id="qr-svg-wrap" style="background:#fff; padding:14px; border-radius:12px; display:inline-flex; box-shadow:0 4px 16px rgba(0,0,0,0.4);"></div>
      <div style="font-family:monospace; font-size:14px; color:var(--accent); margin:12px 0; word-break:break-all;">http://]===] .. lan_ip .. ":" .. port .. [===[</div>
      <p style="font-size:12px; color:var(--text-muted); line-height:1.5; margin-bottom:16px;">Scan this QR code with your phone camera to stream music and videos over Wi-Fi.</p>
      <div style="display:flex; justify-content:center; gap:8px;">
        <button class="btn btn-primary" onclick="copyLink('http://]===] .. lan_ip .. ":" .. port .. [===[' )">📋 Copy Link</button>
        <button class="btn" onclick="closeQRModal()">Done</button>
      </div>
    </div>
  </div>

  <div class="toast" id="toast"></div>

  <script>
    let activeMode = ']===] .. default_mode .. [===[';
    let currentTrack = null;
    let queue = [];
    let queueIndex = -1;
    let isLooping = false;
    let isMuted = false;

    const audio = document.getElementById('audio-elem');

    // Minimal Zero-Dependency SVG QR Generator
    function createQR(text) {
      const size = 25;
      const matrix = Array.from({ length: size }, () => new Uint8Array(size));
      const isFunc = Array.from({ length: size }, () => new Uint8Array(size));
      function setFunc(r, c, v) { matrix[r][c] = v; isFunc[r][c] = 1; }
      function addFinder(or, oc) {
        for (let r = 0; r < 7; r++) {
          for (let c = 0; c < 7; c++) {
            const edge = (r === 0 || r === 6 || c === 0 || c === 6);
            const mid = (r >= 2 && r <= 4 && c >= 2 && c <= 4);
            setFunc(or + r, oc + c, (edge || mid) ? 1 : 0);
          }
        }
        for (let r = -1; r <= 7; r++) {
          for (let c = -1; c <= 7; c++) {
            const rr = or + r, cc = oc + c;
            if (rr >= 0 && rr < size && cc >= 0 && cc < size && !isFunc[rr][cc]) setFunc(rr, cc, 0);
          }
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
      function gmul(a, b) { return (a === 0 || b === 0) ? 0 : exp[log[a] + log[b] ]; }
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
      data.push((text.charCodeAt(text.length - 1) & 0x0f) << 4);
      while (data.length < 16) data.push(data.length % 2 === 0 ? 0xec : 0x11);
      const rem = new Array(gen.length).fill(0);
      for (let i = 0; i < data.length; i++) {
        const factor = data[i] ^ rem[0];
        rem.shift(); rem.push(0);
        for (let j = 0; j < gen.length; j++) rem[j] ^= gmul(gen[j], factor);
      }
      const allBits = [];
      for (const b of data) { for (let bit = 7; bit >= 0; bit--) allBits.push((b >> bit) & 1); }
      for (const b of rem.slice(0, 10)) { for (let bit = 7; bit >= 0; bit--) allBits.push((b >> bit) & 1); }
      let bIdx = 0;
      for (let right = size - 1; right > 0; right -= 2) {
        if (right === 6) right--;
        for (let vert = 0; vert < size; vert++) {
          for (let j = 0; j < 2; j++) {
            const c = right - j;
            const r = ((right + 1) / 2) % 2 === 1 ? (size - 1 - vert) : vert;
            if (!isFunc[r][c]) {
              const bit = bIdx < allBits.length ? allBits[bIdx++] : 0;
              matrix[r][c] = (bit ^ ((r + c) % 2 === 0 ? 1 : 0));
            }
          }
        }
      }
      const scale = 7, pad = 2;
      const totalSize = (size + pad * 2) * scale;
      let svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${totalSize} ${totalSize}" width="200" height="200">`;
      svg += `<rect width="${totalSize}" height="${totalSize}" fill="#ffffff"/>`;
      for (let r = 0; r < size; r++) {
        for (let c = 0; c < size; c++) {
          if (matrix[r][c]) {
            svg += `<rect x="${(c + pad) * scale}" y="${(r + pad) * scale}" width="${scale}" height="${scale}" fill="#000000"/>`;
          }
        }
      }
      svg += `</svg>`;
      return svg;
    }

    function showToast(msg) {
      const t = document.getElementById('toast');
      t.textContent = msg;
      t.classList.add('show');
      setTimeout(() => t.classList.remove('show'), 2500);
    }

    function copyLink(url) {
      navigator.clipboard.writeText(url).then(() => showToast('Link copied to clipboard!'));
    }

    function openQRModal() {
      const wrap = document.getElementById('qr-svg-wrap');
      wrap.innerHTML = createQR(window.location.origin);
      document.getElementById('qr-modal').classList.add('open');
    }

    function closeQRModal() {
      document.getElementById('qr-modal').classList.remove('open');
    }

    function setMode(mode) {
      activeMode = mode;
      document.getElementById('pill-music').classList.toggle('active', mode === 'music');
      document.getElementById('pill-video').classList.toggle('active', mode === 'video');
      const pane = document.getElementById('player-pane');
      if (mode === 'video' && currentTrack) {
        pane.classList.add('active');
      } else if (mode === 'music') {
        pane.classList.remove('active');
      }
      showToast('Switched to ' + (mode === 'music' ? '🎵 Music Mode' : '🎬 Video Mode'));
    }

    function clearFilters() {
      document.getElementById('filter-site').value = 'youtube';
      document.getElementById('filter-duration').value = 'all';
      document.getElementById('filter-sort').value = 'relevance';
      executeSearch();
    }

    async function executeSearch() {
      const q = document.getElementById('search-input').value.trim();
      if (!q) return;
      const site = document.getElementById('filter-site').value;
      const dur = document.getElementById('filter-duration').value;
      const sort = document.getElementById('filter-sort').value;
      const container = document.getElementById('results-container');
      container.innerHTML = '<p style="color:var(--text-muted); grid-column:1/-1; text-align:center; padding:40px 0;">Searching ' + site + ' for &quot;' + q + '&quot;...</p>';

      try {
        const url = `/api/search?q=${encodeURIComponent(q)}&mode=${activeMode}&site=${site}&duration=${dur}&sort=${sort}`;
        const res = await fetch(url);
        const data = await res.json();
        renderResults(data);
      } catch (err) {
        container.innerHTML = '<p style="color:var(--accent-red); grid-column:1/-1; text-align:center; padding:40px 0;">Error fetching search results: ' + err + '</p>';
      }
    }

    function renderResults(items) {
      const container = document.getElementById('results-container');
      document.getElementById('results-count').textContent = items.length + ' items';
      if (!items || items.length === 0) {
        container.innerHTML = '<p style="color:var(--text-muted); grid-column:1/-1; text-align:center; padding:40px 0;">No results found.</p>';
        return;
      }

      container.innerHTML = items.map((it, idx) => {
        const safeTitle = it.title.replace(/'/g, "\\'").replace(/"/g, '&quot;');
        const safeUploader = (it.uploader || 'YouTube').replace(/'/g, "\\'").replace(/"/g, '&quot;');
        const thumb = it.thumbnail || `https://i.ytimg.com/vi/${it.id}/hqdefault.jpg`;
        return `
          <div class="video-card" onclick="playNow(${JSON.stringify(it).replace(/"/g, '&quot;')})">
            <div class="thumb-wrap">
              <img class="thumb-img" src="${thumb}" loading="lazy" alt="thumb">
              <span class="thumb-duration">${it.duration_str || '--:--'}</span>
            </div>
            <div class="card-body">
              <div class="card-title" title="${safeTitle}">${it.title}</div>
              <div class="card-meta">
                <span>${safeUploader}</span>
              </div>
              <div class="card-actions" onclick="event.stopPropagation()">
                <button class="btn btn-primary" onclick='playNow(${JSON.stringify(it)})'>▶ Play</button>
                <button class="btn" onclick='addToQueue(${JSON.stringify(it)})'>+ Queue</button>
                <button class="btn" onclick='downloadTrack(${JSON.stringify(it)})'>⬇ Save</button>
              </div>
            </div>
          </div>
        `;
      }).join('');
    }

    async function playNow(track) {
      currentTrack = track;
      updatePlayerUI(track);

      // Check if already in queue; if not, add it
      let foundIdx = queue.findIndex(x => x.id === track.id);
      if (foundIdx === -1) {
        queue.push(track);
        foundIdx = queue.length - 1;
      }
      queueIndex = foundIdx;
      renderQueue();

      showToast('Resolving stream for ' + track.title + '...');
      try {
        const res = await fetch(`/api/stream?id=${encodeURIComponent(track.id)}&mode=${activeMode}`);
        const data = await res.json();
        if (data.ok) {
          if (data.is_embed || activeMode === 'video') {
            loadVideoViewport(data.is_embed ? data.embed_url : data.stream_url, data.is_embed);
          } else {
            loadAudioStream(data.stream_url);
          }
        } else {
          showToast('Failed to resolve stream: ' + (data.error || 'unknown'));
        }
      } catch (err) {
        showToast('Stream error: ' + err);
      }
    }

    function loadAudioStream(streamUrl) {
      document.getElementById('player-pane').classList.remove('active');
      audio.src = streamUrl;
      audio.play().then(() => {
        document.getElementById('play-pause-btn').textContent = '⏸';
      }).catch(e => console.log('Autoplay policy prevented audio play:', e));
    }

    function loadVideoViewport(url, isEmbed) {
      const pane = document.getElementById('player-pane');
      const viewport = document.getElementById('video-viewport');
      pane.classList.add('active');
      if (isEmbed) {
        viewport.innerHTML = `<iframe src="${url}" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>`;
      } else {
        viewport.innerHTML = `<video controls autoplay playsinline src="${url}"></video>`;
        const vid = viewport.querySelector('video');
        vid.onended = () => nextTrack();
      }
      window.scrollTo({ top: pane.offsetTop - 70, behavior: 'smooth' });
    }

    function updatePlayerUI(track) {
      document.getElementById('player-title').textContent = track.title;
      document.getElementById('player-artist').textContent = track.uploader || 'YouTube';
      const thumb = track.thumbnail || `https://i.ytimg.com/vi/${track.id}/hqdefault.jpg`;
      document.getElementById('player-thumb').src = thumb;

      // Update navigator.mediaSession
      if ('mediaSession' in navigator) {
        navigator.mediaSession.metadata = new MediaMetadata({
          title: track.title,
          artist: track.uploader || 'YouTube',
          artwork: [{ src: thumb, sizes: '512x512', type: 'image/jpeg' }]
        });
        navigator.mediaSession.setActionHandler('play', () => audio.play());
        navigator.mediaSession.setActionHandler('pause', () => audio.pause());
        navigator.mediaSession.setActionHandler('previoustrack', () => prevTrack());
        navigator.mediaSession.setActionHandler('nexttrack', () => nextTrack());
      }
    }

    function togglePlayPause() {
      const vid = document.querySelector('#video-viewport video');
      if (vid) {
        if (vid.paused) { vid.play(); document.getElementById('play-pause-btn').textContent = '⏸'; }
        else { vid.pause(); document.getElementById('play-pause-btn').textContent = '▶'; }
        return;
      }
      if (audio.paused) {
        audio.play();
        document.getElementById('play-pause-btn').textContent = '⏸';
      } else {
        audio.pause();
        document.getElementById('play-pause-btn').textContent = '▶';
      }
    }

    function seekRelative(sec) {
      const vid = document.querySelector('#video-viewport video');
      const elem = vid || audio;
      elem.currentTime = Math.max(0, Math.min(elem.duration || 0, elem.currentTime + sec));
    }

    function seekAbsolute(e) {
      const bar = document.getElementById('progress-bar');
      const rect = bar.getBoundingClientRect();
      const pos = (e.clientX - rect.left) / rect.width;
      const vid = document.querySelector('#video-viewport video');
      const elem = vid || audio;
      if (elem.duration) elem.currentTime = pos * elem.duration;
    }

    function setVolume(val) {
      audio.volume = val;
      const vid = document.querySelector('#video-viewport video');
      if (vid) vid.volume = val;
    }

    function toggleMute() {
      isMuted = !isMuted;
      audio.muted = isMuted;
      const vid = document.querySelector('#video-viewport video');
      if (vid) vid.muted = isMuted;
    }

    function toggleLoop() {
      isLooping = !isLooping;
      audio.loop = isLooping;
      document.getElementById('loop-btn').style.color = isLooping ? 'var(--accent)' : 'var(--text)';
      showToast(isLooping ? 'Loop Track Enabled' : 'Loop Track Disabled');
    }

    function togglePlayerView() {
      const pane = document.getElementById('player-pane');
      pane.classList.toggle('active');
    }

    function addToQueue(track) {
      queue.push(track);
      renderQueue();
      showToast('Added to Up Next: ' + track.title);
    }

    function clearQueue() {
      queue = [];
      queueIndex = -1;
      renderQueue();
      showToast('Queue cleared.');
    }

    function renderQueue() {
      document.getElementById('queue-count').textContent = queue.length;
      const container = document.getElementById('queue-container');
      if (queue.length === 0) {
        container.innerHTML = '<p style="color:var(--text-muted); font-size:12px; text-align:center; padding:20px 0;">Queue is empty.</p>';
        return;
      }
      container.innerHTML = queue.map((it, idx) => `
        <div class="queue-item ${idx === queueIndex ? 'active' : ''}" onclick="playQueueIndex(${idx})">
          <img class="queue-thumb" src="${it.thumbnail || ''}" alt="thumb">
          <div class="queue-info">
            <div class="queue-title">${it.title}</div>
            <div class="queue-sub">${it.uploader || 'YouTube'} · ${it.duration_str || ''}</div>
          </div>
        </div>
      `).join('');
    }

    function playQueueIndex(idx) {
      if (idx >= 0 && idx < queue.length) {
        queueIndex = idx;
        playNow(queue[idx]);
      }
    }

    function nextTrack() {
      if (queueIndex + 1 < queue.length) {
        playQueueIndex(queueIndex + 1);
      } else if (isLooping && queue.length > 0) {
        playQueueIndex(0);
      } else {
        showToast('Reached end of playlist.');
      }
    }

    function prevTrack() {
      if (queueIndex > 0) {
        playQueueIndex(queueIndex - 1);
      } else {
        seekRelative(-999);
      }
    }

    function downloadTrack(track) {
      showToast('Downloading ' + track.title + ' via server...');
      window.open(`/api/download?id=${encodeURIComponent(track.id)}&mode=${activeMode}`, '_blank');
    }

    // Audio element event listeners
    audio.ontimeupdate = () => {
      if (audio.duration) {
        const pct = (audio.currentTime / audio.duration) * 100;
        document.getElementById('progress-fill').style.width = pct + '%';
        document.getElementById('time-current').textContent = formatTime(audio.currentTime);
        document.getElementById('time-total').textContent = formatTime(audio.duration);
      }
    };
    audio.onended = () => nextTrack();
    audio.onplay = () => document.getElementById('play-pause-btn').textContent = '⏸';
    audio.onpause = () => document.getElementById('play-pause-btn').textContent = '▶';

    function formatTime(s) {
      s = Math.floor(s || 0);
      const m = Math.floor(s / 60);
      const sec = s % 60;
      return `${m < 10 ? '0' : ''}${m}:${sec < 10 ? '0' : ''}${sec}`;
    }

    // On Load: execute initial trending / popular search
    window.onload = () => {
      document.getElementById('search-input').value = 'Top Hits 2026';
      executeSearch();
    };
  </script>
</body>
</html>]===]
end

-- =========================================================================
-- 6. HTTP Server & Connection Handler
-- =========================================================================
local function send_response(sock, status_code, content_type, body, extra_headers)
    local status_text = ({
        [200] = "OK",
        [206] = "Partial Content",
        [302] = "Found",
        [400] = "Bad Request",
        [404] = "Not Found",
        [500] = "Internal Server Error",
    })[status_code] or "OK"

    local headers = {
        string.format("HTTP/1.1 %d %s", status_code, status_text),
        string.format("Content-Type: %s", content_type),
        string.format("Content-Length: %d", #body),
        "Connection: close",
        "Access-Control-Allow-Origin: *",
    }
    if extra_headers then
        for k, v in pairs(extra_headers) do
            table.insert(headers, string.format("%s: %s", k, v))
        end
    end

    local raw = table.concat(headers, "\r\n") .. "\r\n\r\n" .. body
    if is_windows then
        ws2.send(sock, raw, #raw, 0)
    else
        C.send(sock, raw, #raw, 0)
    end
end

local function run_server(host, port, default_mode, browser, cookies_file, proxy, insecure, download_dir)
    download_dir = download_dir or "./yt_downloads"
    if is_windows then
        C._mkdir(download_dir)
    else
        C.mkdir(download_dir, 511)
    end

    local server_sock
    if is_windows then
        server_sock = ws2.socket(AF_INET, SOCK_STREAM, 0)
    else
        server_sock = C.socket(AF_INET, SOCK_STREAM, 0)
    end
    if server_sock == INVALID_SOCK or server_sock < 0 then
        io.stderr:write("Error: Failed to create server socket\n")
        return 1
    end

    local optval = ffi.new("int[1]", 1)
    if is_windows then
        ws2.setsockopt(server_sock, SOL_SOCKET, SO_REUSEADDR, optval, ffi.sizeof(optval))
    else
        C.setsockopt(server_sock, SOL_SOCKET, SO_REUSEADDR, optval, ffi.sizeof(optval))
    end

    local saddr = ffi.new("struct sockaddr_in")
    saddr.sin_family = AF_INET
    if is_windows then
        saddr.sin_port = ws2.htons(port)
        saddr.sin_addr.s_addr = (host == "0.0.0.0" or host == "") and 0 or ws2.inet_addr(host)
        if ws2.bind(server_sock, saddr, ffi.sizeof(saddr)) ~= 0 then
            io.stderr:write(string.format("Error: Port %d already in use\n", port))
            close_socket(server_sock)
            return 1
        end
        if ws2.listen(server_sock, 128) ~= 0 then
            io.stderr:write("Error: Failed to listen\n")
            close_socket(server_sock)
            return 1
        end
    else
        saddr.sin_port = C.htons(port)
        saddr.sin_addr.s_addr = (host == "0.0.0.0" or host == "") and 0 or C.inet_addr(host)
        if C.bind(server_sock, saddr, ffi.sizeof(saddr)) ~= 0 then
            io.stderr:write(string.format("Error: Port %d already in use\n", port))
            close_socket(server_sock)
            return 1
        end
        if C.listen(server_sock, 128) ~= 0 then
            io.stderr:write("Error: Failed to listen\n")
            close_socket(server_sock)
            return 1
        end
    end

    local lan_ip = get_local_lan_ip()
    io.write(string.format("\27[1;36m▶ YouTube Web Server v%s\27[0m\n", YTWEB_VERSION))
    io.write(string.format("  * Local URL:  \27[1;32mhttp://localhost:%d\27[0m\n", port))
    io.write(string.format("  * Wi-Fi / LAN: \27[1;32mhttp://%s:%d\27[0m\n", lan_ip, port))
    io.write(string.format("  * Engine:     %s\n", HAS_YTDLP and "\27[32myt-dlp (Installed)\27[0m" or "\27[33mcurl scraper fallback\27[0m"))
    io.write(string.format("  * Downloads:  %s\n", download_dir))
    io.write("  * Press Ctrl+C to terminate\n\n")
    io.flush()

    local buf_size = 16384
    local buf = ffi.new("char[?]", buf_size)

    while true do
        local client_sock
        if is_windows then
            client_sock = ws2.accept(server_sock, nil, nil)
        else
            client_sock = C.accept(server_sock, nil, nil)
        end
        if client_sock ~= INVALID_SOCK and client_sock >= 0 then
            local n
            if is_windows then
                n = ws2.recv(client_sock, buf, buf_size - 1, 0)
            else
                n = C.recv(client_sock, buf, buf_size - 1, 0)
            end
            n = tonumber(n)
            if n and n > 0 then
                local raw_req = ffi.string(buf, n)
                local req_line = raw_req:match("^[^\r\n]+") or ""
                local method, full_url = req_line:match("^(%u+)%s+(%S+)")

                if method and full_url then
                    local url_path = full_url:match("^([^%?]+)") or full_url
                    local params = parse_query_params(full_url)

                    if url_path == "/" or url_path == "/index.html" then
                        send_response(client_sock, 200, "text/html; charset=utf-8", get_index_html(lan_ip, port, default_mode))
                    elseif url_path == "/api/status" then
                        local resp = {
                            ok = true,
                            version = YTWEB_VERSION,
                            port = port,
                            lan_ip = lan_ip,
                            has_ytdlp = HAS_YTDLP,
                            has_ffmpeg = HAS_FFMPEG,
                            mode = default_mode,
                        }
                        send_response(client_sock, 200, "application/json", json.encode(resp))
                    elseif url_path == "/api/search" then
                        local q = params.q or ""
                        local req_mode = params.mode or default_mode
                        local site = params.site or "youtube"
                        local filters = { duration = params.duration, sort = params.sort }
                        local items, s_err = fetch_search_results(q, req_mode, browser, cookies_file, 24, proxy, insecure, filters, site)
                        send_response(client_sock, 200, "application/json", json.encode(items or {}))
                    elseif url_path == "/api/stream" then
                        local track_id = params.id or ""
                        local req_mode = params.mode or default_mode
                        local s_data, s_err = resolve_stream_url(track_id, req_mode, browser, cookies_file, proxy, insecure)
                        if s_data then
                            send_response(client_sock, 200, "application/json", json.encode(s_data))
                        else
                            send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = s_err or "Resolution failed" }))
                        end
                    elseif url_path == "/api/download" then
                        local track_id = params.id or ""
                        local req_mode = params.mode or default_mode
                        if HAS_YTDLP and #track_id > 0 then
                            local fmt = (req_mode == "music")
                                and '-x --audio-format mp3 --add-metadata'
                                or '-f "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" --merge-output-format mp4'
                            local dl_cmd = string.format('yt-dlp %s -P %q %q >/dev/null 2>&1 &', fmt, download_dir, "https://www.youtube.com/watch?v=" .. track_id)
                            os.execute(dl_cmd)
                            send_response(client_sock, 200, "application/json", json.encode({ ok = true, message = "Download queued in " .. download_dir }))
                        else
                            send_response(client_sock, 400, "application/json", json.encode({ ok = false, error = "yt-dlp required for background downloads" }))
                        end
                    else
                        send_response(client_sock, 404, "text/plain", "Not Found")
                    end
                end
            end
            close_socket(client_sock)
        end
    end
    close_socket(server_sock)
    return 0
end

-- =========================================================================
-- 7. Command-Line Interface & Entry Point
-- =========================================================================
local function print_help()
    print(string.format([[
yt-web.lua v%s — YouTube & YouTube Music Web Server & Browser

Usage:
  luajit yt-web.lua [options]

Options:
  --port <p>          Port to listen on (default: 8050)
  --host <ip>         Host address to bind to (default: 0.0.0.0)
  --mode <m>          Default mode: 'music' (default) or 'video'
  --browser <b>       Extract cookies from browser (chrome, firefox, edge, brave)
  --cookies <file>    Path to cookies.txt file
  --proxy <url>       HTTP/SOCKS proxy URL
  --insecure          Skip SSL certificate verification
  --dir <path>        Download destination directory (default: ./yt_downloads)
  --test              Run internal unit and integration test suite
  -h, --help          Show this help message
]], YTWEB_VERSION))
end

local function main(args)
    local port = 8050
    local host = "0.0.0.0"
    local mode = "music"
    local browser = nil
    local cookies_file = nil
    local proxy = nil
    local insecure = false
    local download_dir = "./yt_downloads"

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--port" and i < #args then
            port = tonumber(args[i + 1]) or 8050
            i = i + 1
        elseif a == "--host" and i < #args then
            host = args[i + 1]
            i = i + 1
        elseif a == "--mode" and i < #args then
            mode = args[i + 1]:lower() == "video" and "video" or "music"
            i = i + 1
        elseif a == "--browser" and i < #args then
            browser = args[i + 1]
            i = i + 1
        elseif a == "--cookies" and i < #args then
            cookies_file = args[i + 1]
            i = i + 1
        elseif a == "--proxy" and i < #args then
            proxy = args[i + 1]
            i = i + 1
        elseif a == "--insecure" then
            insecure = true
        elseif a == "--dir" and i < #args then
            download_dir = args[i + 1]
            i = i + 1
        elseif a == "--test" then
            local ok, test_runner = pcall(require, "test_yt_web")
            if not ok then
                os.execute("luajit test_yt_web.lua")
            end
            return 0
        elseif a == "-h" or a == "--help" then
            print_help()
            return 0
        end
        i = i + 1
    end

    return run_server(host, port, mode, browser, cookies_file, proxy, insecure, download_dir)
end

-- Export module for tests & run main if executed directly
local mod = {
    sanitize_filename = sanitize_filename,
    url_decode = url_decode,
    url_encode = url_encode,
    parse_query_params = parse_query_params,
    format_duration = format_duration,
    format_bytes = format_bytes,
    unescape_unicode = unescape_unicode,
    sanitize_display_text = sanitize_display_text,
    parse_json_field = parse_json_field,
    build_search_spec = build_search_spec,
    scrape_youtube_search = scrape_youtube_search,
    fetch_search_results = fetch_search_results,
    resolve_stream_url = resolve_stream_url,
    get_local_lan_ip = get_local_lan_ip,
    get_index_html = get_index_html,
    VERSION = YTWEB_VERSION,
}

if pcall(debug.getlocal, 4, 1) then
    return mod
else
    local is_script = (arg and arg[0] and (arg[0]:find("yt%-web%.lua") or arg[0]:find("yt_web%.lua")))
    if is_script then
        os.exit(main(arg))
    end
    return mod
end
