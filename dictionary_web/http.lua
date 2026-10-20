--------------------------------------------------------------------------------
-- http.lua
-- HTTP/1.1 server via POSIX / Winsock FFI with coroutine-based non-blocking I/O.
--------------------------------------------------------------------------------

local ffi = require('ffi')
local json = require('json')
local bit = require('bit')

--------------------------------------------------------------------------------
-- FFI & OS Socket Definitions
--------------------------------------------------------------------------------

ffi.cdef[[
struct wb_sockaddr_in { uint16_t family; uint16_t port; uint32_t address; unsigned char zero[8]; };
struct wb_sockaddr_in6 { uint16_t family; uint16_t port; uint32_t flow;
    unsigned char address[16]; uint32_t scope; };
struct wb_timespec { long seconds; long nanoseconds; };
typedef struct { unsigned long bits[16]; } wb_sigset;
]]

ffi.cdef(ffi.os == 'Windows'
    and 'struct wb_pollfd { uintptr_t fd; short events; short revents; };'
    or 'struct wb_pollfd { int fd; short events; short revents; };')

if ffi.os ~= 'Windows' then
    ffi.cdef[[
    int clock_gettime(int, struct wb_timespec *);
    int socket(int, int, int);
    int setsockopt(int, int, int, const void *, unsigned int);
    int bind(int, const void *, unsigned int);
    int listen(int, int);
    int accept(int, void *, unsigned int *);
    int getsockname(int, void *, unsigned int *);
    int poll(struct wb_pollfd *, unsigned long, int);
    long recv(int, void *, size_t, int);
    long send(int, const void *, size_t, int);
    long read(int, void *, size_t);
    int close(int);
    uint16_t htons(uint16_t);
    uint16_t ntohs(uint16_t);
    uint32_t htonl(uint32_t);
    int sigemptyset(wb_sigset *);
    int sigaddset(wb_sigset *, int);
    int sigprocmask(int, const wb_sigset *, wb_sigset *);
    int signalfd(int, const wb_sigset *, int);
    ]]
end

local windows = ffi.os == 'Windows' and require('http_windows') or nil
local C = windows and windows.C or ffi.C
local socket_errno = windows and windows.errno or ffi.errno

local function socket_failure(message)
    error(message .. ' (socket error ' .. socket_errno() .. ')')
end

-- ffi_dict also declares poll with its own identically laid-out pollfd type.
local poll_fds = windows and windows.poll or ffi.cast('int (*)(struct wb_pollfd *, unsigned long, int)', C.poll)

local AF_INET         = 2
local SOCK_STREAM     = 1
local SOCK_NONBLOCK   = 0x80000
local SOL_SOCKET      = 1
local SO_REUSEADDR    = 2
local SFD_NONBLOCK    = 0x80000
local POLLIN          = 1
local POLLOUT         = 4
local MSG_NOSIGNAL    = 0x4000
local MSG_DONTWAIT    = 0x40
local INADDR_LOOPBACK = 0x7f000001
local SIGINT          = 2
local SIGTERM         = 15
local SIG_BLOCK       = 0
local SIG_SETMASK     = 2

local M = {}
local owned_fds = {}
local clock_gettime = not windows and ffi.cast('int (*)(int, struct wb_timespec *)', C.clock_gettime)

--------------------------------------------------------------------------------
-- Monotonic Timing & Socket Status Constants
--------------------------------------------------------------------------------

local function now_seconds()
    if windows then
        return windows.now()
    end
    local stamp = ffi.new('struct wb_timespec[1]')
    assert(clock_gettime(1, stamp) == 0, 'Cannot read monotonic clock')
    return tonumber(stamp[0].seconds) + tonumber(stamp[0].nanoseconds) / 1e9
end

function M.close_inherited()
    for fd in pairs(owned_fds) do
        C.close(fd)
    end
end

local reasons = {
    [200] = 'OK',
    [400] = 'Bad Request',
    [403] = 'Forbidden',
    [404] = 'Not Found',
    [405] = 'Method Not Allowed',
    [408] = 'Request Timeout',
    [409] = 'Conflict',
    [413] = 'Payload Too Large',
    [415] = 'Unsupported Media Type',
    [500] = 'Internal Server Error',
}

local function readable(fd, milliseconds)
    return coroutine.yield({ events = POLLIN, deadline = now_seconds() + milliseconds / 1000 }) ~= false
end

--------------------------------------------------------------------------------
-- HTTP Header Parsing & Request Intake
--------------------------------------------------------------------------------

function M.parse_headers(raw, body_limits)
    local method, target, version = raw:match('^(%u+) ([^%s]+) (HTTP/1%.[01])\r\n')
    if not method or not target:match('^/') then
        return nil, 'Invalid request line.'
    end
    local headers = {}
    for line in raw:sub((raw:find('\r\n', 1, true) or 0) + 2):gmatch('(.-)\r\n') do
        if line ~= '' then
            local key, value = line:match('^([%w%-]+):%s*(.-)%s*$')
            if not key then
                return nil, 'Invalid request header.'
            end
            key = key:lower()
            if headers[key] then
                return nil, 'Duplicate request header.'
            end
            headers[key] = value
        end
    end
    if headers['transfer-encoding'] then
        return nil, 'Chunked request bodies are not supported.'
    end
    local length = headers['content-length'] or '0'
    if not length:match('^%d+$') then
        return nil, 'Invalid content length.'
    end
    length = tonumber(length)
    local path = target:match('^([^?]*)')
    local maximum = body_limits and body_limits[path]
        or (path == '/api/restore' and 16 * 1024 * 1024 or 8192)
    if length > maximum then
        return nil, 'Request body is too large.', 413
    end
    return {
        method = method,
        target = target,
        version = version,
        headers = headers,
        length = length,
    }
end

local function read_request(fd, body_limits)
    local buffer, deadline = '', now_seconds() + 6
    local chunk = ffi.new('char[4096]')
    local header_end
    while not header_end do
        if now_seconds() >= deadline or not readable(fd, 1000) then
            return nil, 'Request timed out.', 408
        end
        local bytes = tonumber(C.recv(fd, chunk, 4096, MSG_DONTWAIT))
        if bytes <= 0 then
            return nil, 'Incomplete request.', 400
        end
        buffer = buffer .. ffi.string(chunk, bytes)
        header_end = buffer:find('\r\n\r\n', 1, true)
        if (header_end and header_end > 16384) or (not header_end and #buffer > 16384) then
            return nil, 'Request headers are too large.', 413
        end
    end
    local request, err, status = M.parse_headers(buffer:sub(1, header_end + 3), body_limits)
    if not request then
        return nil, err, status or 400
    end
    -- Receive into one preallocated buffer; string concatenation here is
    -- quadratic and dominates large image uploads and notebook backups.
    local rest = buffer:sub(header_end + 4)
    local body = ffi.new('char[?]', math.max(request.length, 1))
    local filled = math.min(#rest, request.length)
    if filled > 0 then ffi.copy(body, rest, filled) end
    while filled < request.length do
        if now_seconds() >= deadline or not readable(fd, 1000) then
            return nil, 'Request timed out.', 408
        end
        local bytes = tonumber(C.recv(fd, body + filled, request.length - filled, MSG_DONTWAIT))
        if bytes <= 0 then
            return nil, 'Incomplete request body.', 400
        end
        filled = filled + bytes
    end
    request.body = ffi.string(body, request.length)
    return request
end

local function decode(text)
    return (text:gsub('%+', ' '):gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function M.target(target)
    local path, query = target:match('^([^?]*)%??(.*)$')
    local params = {}
    for key, value in query:gmatch('([^&=]+)=([^&]*)') do
        params[decode(key)] = decode(value)
    end
    return path, params
end

--------------------------------------------------------------------------------
-- Response Serialization & Content-Security-Policy
--------------------------------------------------------------------------------

function M.respond(fd, status, body, content_type, head, extra_headers)
    local headers = extra_headers or {}
    local custom_csp
    for key, value in pairs(headers) do
        if key:lower() == 'content-security-policy' then
            custom_csp = value
        end
    end
    local csp = custom_csp or ("default-src 'self'; style-src 'self'; script-src 'self'; "
        .. "connect-src 'self' https://bible-api.com; "
        .. "media-src 'self' https://audio.dict.cn https://dict.youdao.com https://iciba.com https://*.iciba.com; "
        .. "frame-ancestors 'none'")
    local frame = 'HTTP/1.1 ' .. status .. ' ' .. (reasons[status] or 'Error') .. '\r\n'
        .. 'Content-Type: ' .. (content_type or 'application/json; charset=utf-8') .. '\r\n'
        .. 'Content-Length: ' .. #body .. '\r\nConnection: close\r\nCache-Control: no-store\r\n'
        .. 'X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n'
        .. 'Content-Security-Policy: ' .. csp .. '\r\n'
    for key, value in pairs(headers) do
        if key:lower() ~= 'content-security-policy' then
            assert(key:match('^[%w%-]+$') and not value:find('[\r\n]'), 'Invalid response header')
            frame = frame .. key .. ': ' .. value .. '\r\n'
        end
    end
    frame = frame .. '\r\n' .. (head and '' or body)
    local offset, deadline = 0, now_seconds() + 5
    local pointer = ffi.cast('const char *', frame)
    while offset < #frame and now_seconds() <= deadline do
        if coroutine.yield({ events = POLLOUT, deadline = deadline }) == false then
            return false
        end
        local bytes = tonumber(C.send(fd, pointer + offset, #frame - offset, MSG_NOSIGNAL + MSG_DONTWAIT))
        if bytes > 0 then
            offset = offset + bytes
        elseif bytes == 0 or (socket_errno() ~= 4 and socket_errno() ~= 11) then
            return false
        end
    end
    return offset == #frame
end

--------------------------------------------------------------------------------
-- Server Event Loop & Client Dispatch
--------------------------------------------------------------------------------

function M.serve(port, handler, ready, host, workers, options)
    assert(ffi.os == 'Linux' or windows, 'This HTTP server supports Linux and Windows.')
    host = host or '127.0.0.1'
    assert(host == '127.0.0.1' or host == '0.0.0.0', 'Host must be 127.0.0.1 or 0.0.0.0.')
    local listener, signals = -1, -1
    local previous = ffi.new('wb_sigset[1]')
    local blocked = false
    local clients = {}
    local ok, err = xpcall(function()
        local mask = ffi.new('wb_sigset[1]')
        assert(C.sigemptyset(mask) == 0 and C.sigaddset(mask, SIGINT) == 0 and C.sigaddset(mask, SIGTERM) == 0,
            'Signal setup failed')
        assert(C.sigprocmask(SIG_BLOCK, mask, previous) == 0, 'Signal mask failed')
        blocked = true
        signals = C.signalfd(-1, mask, SFD_NONBLOCK)
        assert(signals >= 0, 'Cannot create signal descriptor')
        local dual_stack = host == '0.0.0.0' and options and options.dual_stack
        local family = dual_stack and (windows and 23 or 10) or AF_INET
        listener = C.socket(family, SOCK_STREAM + SOCK_NONBLOCK, 0)
        if listener < 0 then
            socket_failure(dual_stack
                and 'Cannot create IPv4 + IPv6 server socket; enable operating system IPv6 support '
                    .. 'or use --host 127.0.0.1'
                or 'Cannot create server socket')
        end
        local enabled = ffi.new('int[1]', 1)
        if C.setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, enabled, 4) ~= 0 then
            socket_failure('Cannot configure server socket')
        end
        if dual_stack then
            local disabled = ffi.new('int[1]', 0)
            if C.setsockopt(listener, 41, windows and 27 or 26, disabled, 4) ~= 0 then
                socket_failure('Cannot enable IPv4 + IPv6; check operating system IPv6 support')
            end
        end
        local address = dual_stack and ffi.new('struct wb_sockaddr_in6', {
            family, C.htons(port), 0, { 0 }, 0,
        }) or ffi.new('struct wb_sockaddr_in', {
            AF_INET,
            C.htons(port),
            C.htonl(host == '0.0.0.0' and 0 or INADDR_LOOPBACK),
            { 0 },
        })
        if C.bind(listener, address, ffi.sizeof(address)) ~= 0 then
            socket_failure('Cannot bind port ' .. port .. ' on ' .. host)
        end
        if C.listen(listener, 16) ~= 0 then
            socket_failure('Cannot listen on ' .. host .. ':' .. port)
        end
        local length = ffi.new('unsigned int[1]', ffi.sizeof(address))
        if C.getsockname(listener, address, length) ~= 0 then
            socket_failure('Cannot read server port')
        end
        port = tonumber(C.ntohs(address.port))
        ready(port)
        owned_fds[listener], owned_fds[signals] = true, true

        local function discard(index)
            local client = clients[index]
            if workers then
                workers:cancel(client)
            end
            owned_fds[client.fd] = nil
            C.close(client.fd)
            table.remove(clients, index)
        end

        local function serve_client(client)
            local request, message, status = read_request(client.fd, options and options.body_limits)
            if not request then
                M.respond(client.fd, status, json.encode({ error = message }))
                return
            end
            request.background = workers and function(run, timeout)
                if client.cancelled then
                    return nil, 'Request cancelled.'
                end
                return workers:run(client, run, timeout)
            end or nil
            local body, code, mime, headers = handler(request, port)
            M.respond(client.fd, code, body, mime, request.method == 'HEAD', headers)
        end

        while true do
            if workers then
                workers:tick()
            end
            local count = #clients
            local fds = ffi.new('struct wb_pollfd[?]', count + 2)
            fds[0].fd, fds[0].events = listener, POLLIN
            fds[1].fd, fds[1].events = signals, POLLIN
            for i, client in ipairs(clients) do
                fds[i + 1].fd = client.fd
                fds[i + 1].events = client.pending.events or (client.eof and 0 or POLLIN)
            end
            local result = poll_fds(fds, count + 2, 50)
            if result < 0 and socket_errno() ~= 4 then
                error('Server poll failed')
            end
            if fds[1].revents ~= 0 then
                local signal = ffi.new('char[128]')
                C.read(signals, signal, 128)
                break
            end
            for i = count, 1, -1 do
                local client, pending = clients[i], clients[i].pending
                local events, now = tonumber(fds[i + 1].revents), now_seconds()
                if bit.band(events, 24) ~= 0 then
                    discard(i)
                else
                    local expired = pending.deadline and now >= pending.deadline
                    local resume = pending.events and (events ~= 0 or expired) or pending.done
                    if not pending.events and now - client.started >= 120 then
                        client.cancelled = true
                        if workers then
                            workers:cancel(client)
                        end
                        resume = true
                    end
                    if not pending.events and events ~= 0 and not resume then
                        -- TCP half-close is legal after sending a complete request.
                        local probe = ffi.new('char[4096]')
                        if C.recv(client.fd, probe, 4096, MSG_DONTWAIT) == 0 then
                            client.eof = true
                        end
                    end
                    if resume then
                        local served, waiting = coroutine.resume(client.thread, not expired)
                        if not served or coroutine.status(client.thread) == 'dead' then
                            if not served then
                                io.stderr:write('Request failed: ' .. tostring(waiting) .. '\n')
                            end
                            discard(i)
                        else
                            client.pending = waiting
                        end
                    end
                end
            end
            if fds[0].revents ~= 0 then
                local fd = C.accept(listener, nil, nil)
                if fd >= 0 then
                    if #clients >= 64 then
                        C.close(fd)
                    else
                        local client = { fd = tonumber(fd), started = now_seconds() }
                        owned_fds[client.fd] = true
                        client.thread = coroutine.create(function()
                            local served, failure = pcall(serve_client, client)
                            if not served then
                                io.stderr:write('Request failed: ' .. tostring(failure) .. '\n')
                                M.respond(client.fd, 500, json.encode({ error = 'Internal server error.' }))
                            end
                        end)
                        local served, waiting = coroutine.resume(client.thread)
                        if served and coroutine.status(client.thread) ~= 'dead' then
                            client.pending = waiting
                            clients[#clients + 1] = client
                        else
                            owned_fds[client.fd] = nil
                            C.close(client.fd)
                        end
                    end
                end
            end
        end
    end, debug.traceback)

    if workers then
        workers:close()
    end
    for _, client in ipairs(clients) do
        C.close(client.fd)
    end
    owned_fds = {}
    if listener >= 0 then
        C.close(listener)
    end
    if signals >= 0 then
        C.close(signals)
    end
    if blocked then
        C.sigprocmask(SIG_SETMASK, previous, nil)
    end
    if windows then
        windows.cleanup()
    end
    if not ok then
        error(err)
    end
end

return M
