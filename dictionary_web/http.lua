-- Linux HTTP/1.1 server through POSIX FFI. One bounded request at a time.
local ffi = require('ffi')
local json = require('json')
ffi.cdef[[
struct wb_sockaddr_in { uint16_t family; uint16_t port; uint32_t address; unsigned char zero[8]; };
struct wb_pollfd { int fd; short events; short revents; };
typedef struct { unsigned long bits[16]; } wb_sigset;
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
local C = ffi.C
-- ffi_dict also declares poll with its own identically laid-out pollfd type.
local poll_fds = ffi.cast('int (*)(struct wb_pollfd *, unsigned long, int)', C.poll)

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
local reasons = {
    [200] = 'OK',
    [400] = 'Bad Request',
    [403] = 'Forbidden',
    [404] = 'Not Found',
    [405] = 'Method Not Allowed',
    [408] = 'Request Timeout',
    [413] = 'Payload Too Large',
    [415] = 'Unsupported Media Type',
    [500] = 'Internal Server Error',
}

local function readable(fd, milliseconds)
    local poll = ffi.new('struct wb_pollfd[1]', {{fd, POLLIN, 0}})
    return poll_fds(poll, 1, milliseconds) > 0 and poll[0].revents ~= 0
end

function M.parse_headers(raw)
    local method, target, version = raw:match('^(%u+) ([^%s]+) (HTTP/1%.[01])\r\n')
    if not method or not target:match('^/') then
        return nil, 'Invalid request line.'
    end
    local headers = {}
    for line in raw:sub((raw:find('\r\n', 1, true) or 0) + 2):gmatch('(.-)\r\n') do
        if line ~= '' then
            local key, value = line:match('^([%w%-]+):%s*(.-)%s*$')
            if not key then return nil, 'Invalid request header.' end
            key = key:lower()
            if headers[key] then return nil, 'Duplicate request header.' end
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
    if length > 8192 then
        return nil, 'Request body is too large.', 413
    end
    return {method = method, target = target, version = version, headers = headers, length = length}
end

local function read_request(fd)
    local buffer, deadline = '', os.time() + 6
    local chunk = ffi.new('char[4096]')
    local header_end
    while not header_end do
        if os.time() >= deadline or not readable(fd, 1000) then
            return nil, 'Request timed out.', 408
        end
        local bytes = tonumber(C.recv(fd, chunk, 4096, 0))
        if bytes <= 0 then
            return nil, 'Incomplete request.', 400
        end
        buffer = buffer .. ffi.string(chunk, bytes)
        header_end = buffer:find('\r\n\r\n', 1, true)
        if (header_end and header_end > 16384) or (not header_end and #buffer > 16384) then
            return nil, 'Request headers are too large.', 413
        end
    end
    local request, err, status = M.parse_headers(buffer:sub(1, header_end + 3))
    if not request then
        return nil, err, status or 400
    end
    local body = buffer:sub(header_end + 4)
    while #body < request.length do
        if os.time() >= deadline or not readable(fd, 1000) then
            return nil, 'Request timed out.', 408
        end
        local bytes = tonumber(C.recv(fd, chunk, math.min(4096, request.length - #body), 0))
        if bytes <= 0 then
            return nil, 'Incomplete request body.', 400
        end
        body = body .. ffi.string(chunk, bytes)
    end
    request.body = body:sub(1, request.length)
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

function M.respond(fd, status, body, content_type, head)
    local frame = 'HTTP/1.1 ' .. status .. ' ' .. (reasons[status] or 'Error') .. '\r\n'
        .. 'Content-Type: ' .. (content_type or 'application/json; charset=utf-8') .. '\r\n'
        .. 'Content-Length: ' .. #body .. '\r\nConnection: close\r\nCache-Control: no-store\r\n'
        .. 'X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n'
        .. "Content-Security-Policy: default-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'\r\n\r\n"
        .. (head and '' or body)
    local offset, deadline = 0, os.time() + 5
    local pointer = ffi.cast('const char *', frame)
    while offset < #frame and os.time() <= deadline do
        local poll = ffi.new('struct wb_pollfd[1]', {{fd, POLLOUT, 0}})
        if poll_fds(poll, 1, 1000) <= 0 then return false end
        local bytes = tonumber(C.send(fd, pointer + offset, #frame - offset, MSG_NOSIGNAL + MSG_DONTWAIT))
        if bytes <= 0 then return false end
        offset = offset + bytes
    end
    return offset == #frame
end

function M.serve(port, handler, ready, host)
    assert(ffi.os == 'Linux', 'This HTTP server currently supports Linux.')
    host = host or '127.0.0.1'
    assert(host == '127.0.0.1' or host == '0.0.0.0', 'Host must be 127.0.0.1 or 0.0.0.0.')
    local listener, signals = -1, -1
    local previous = ffi.new('wb_sigset[1]')
    local blocked = false
    local ok, err = xpcall(function()
        local mask = ffi.new('wb_sigset[1]')
        assert(C.sigemptyset(mask) == 0 and C.sigaddset(mask, SIGINT) == 0 and C.sigaddset(mask, SIGTERM) == 0, 'Signal setup failed')
        assert(C.sigprocmask(SIG_BLOCK, mask, previous) == 0, 'Signal mask failed')
        blocked = true
        signals = C.signalfd(-1, mask, SFD_NONBLOCK)
        assert(signals >= 0, 'Cannot create signal descriptor')
        listener = C.socket(AF_INET, SOCK_STREAM + SOCK_NONBLOCK, 0)
        assert(listener >= 0, 'Cannot create server socket')
        local enabled = ffi.new('int[1]', 1)
        assert(C.setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, enabled, 4) == 0, 'Cannot configure server socket')
        local address = ffi.new('struct wb_sockaddr_in', {
            AF_INET,
            C.htons(port),
            C.htonl(host == '0.0.0.0' and 0 or INADDR_LOOPBACK),
            {0},
        })
        assert(C.bind(listener, address, ffi.sizeof(address)) == 0, 'Cannot bind port ' .. port .. ' (already in use?)')
        assert(C.listen(listener, 16) == 0, 'Cannot listen')
        local length = ffi.new('unsigned int[1]', ffi.sizeof(address))
        assert(C.getsockname(listener, address, length) == 0, 'Cannot read server port')
        port = tonumber(C.ntohs(address.port))
        ready(port)
        local fds = ffi.new('struct wb_pollfd[2]', {{listener, POLLIN, 0}, {signals, POLLIN, 0}})
        while true do
            local result = poll_fds(fds, 2, 1000)
            if result > 0 then
                if fds[1].revents ~= 0 then
                    local signal = ffi.new('char[128]')
                    C.read(signals, signal, 128)
                    break
                end
                if fds[0].revents ~= 0 then
                    local client = C.accept(listener, nil, nil)
                    if client >= 0 then
                        local served, failure = pcall(function()
                            local request, message, status = read_request(client)
                            if not request then
                                M.respond(client, status, json.encode({error = message}))
                                return
                            end
                            local body, code, mime = handler(request, port)
                            M.respond(client, code, body, mime, request.method == 'HEAD')
                        end)
                        if not served then
                            io.stderr:write('Request failed: ' .. tostring(failure) .. '\n')
                            M.respond(client, 500, json.encode({error = 'Internal server error.'}))
                        end
                        C.close(client)
                    end
                end
            elseif result < 0 and ffi.errno() ~= 4 then
                error('Server poll failed')
            end
        end
    end, debug.traceback)
    if listener >= 0 then C.close(listener) end
    if signals >= 0 then C.close(signals) end
    if blocked then C.sigprocmask(SIG_SETMASK, previous, nil) end
    if not ok then error(err) end
end
return M
