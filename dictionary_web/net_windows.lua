-- Built-in Windows HTTPS transport: automatic proxy/authentication, no curl DLL.
local ffi = require('ffi')
ffi.cdef[[
void * __stdcall WinHttpOpen(const uint16_t *, unsigned long, const uint16_t *, const uint16_t *, unsigned long);
int __stdcall WinHttpSetTimeouts(void *, int, int, int, int);
void * __stdcall WinHttpConnect(void *, const uint16_t *, unsigned short, unsigned long);
void * __stdcall WinHttpOpenRequest(void *, const uint16_t *, const uint16_t *, const uint16_t *,
    const uint16_t *, const uint16_t **, unsigned long);
int __stdcall WinHttpSetOption(void *, unsigned long, void *, unsigned long);
int __stdcall WinHttpSendRequest(void *, const uint16_t *, unsigned long, void *, unsigned long,
    unsigned long, uintptr_t);
int __stdcall WinHttpReceiveResponse(void *, void *);
int __stdcall WinHttpQueryHeaders(void *, unsigned long, const uint16_t *, void *, unsigned long *, unsigned long *);
int __stdcall WinHttpReadData(void *, void *, unsigned long, unsigned long *);
int __stdcall WinHttpCloseHandle(void *);
int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, uint16_t *, int);
int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const uint16_t *, int,
    char *, int, const char *, int *);
unsigned long __stdcall GetLastError(void);
uint64_t __stdcall GetTickCount64(void);
]]
local W, K = ffi.load('winhttp'), ffi.load('kernel32')
local M = {}
local ERRORS = {
    [12002] = 'Request timed out', [12007] = 'Host name could not be resolved',
    [12029] = 'Could not connect', [12175] = 'TLS certificate or handshake failed',
    [12180] = 'Automatic proxy could not be resolved',
}

local function wide(text)
    local count = K.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
    assert(count > 0, 'Invalid UTF-8 request URL')
    local value = ffi.new('uint16_t[?]', count + 1)
    assert(K.MultiByteToWideChar(65001, 8, text, #text, value, count) == count, 'Cannot encode request URL')
    return value
end

local function check(value, operation)
    if value == nil or value == 0 then
        local code = tonumber(K.GetLastError())
        error(operation .. ': ' .. (ERRORS[code] or 'Windows HTTP failure') .. ' (Windows error ' .. code .. ')')
    end
    return value
end

local function location(request)
    local size = ffi.new('unsigned long[1]')
    W.WinHttpQueryHeaders(request, 33, nil, nil, size, nil)
    assert(K.GetLastError() == 122 and size[0] > 0 and size[0] < 65536, 'Redirect has no valid Location header')
    local buffer = ffi.new('uint16_t[?]', math.ceil(tonumber(size[0]) / 2))
    check(W.WinHttpQueryHeaders(request, 33, nil, buffer, size, nil), 'Read redirect')
    local count = K.WideCharToMultiByte(65001, 0, buffer, -1, nil, 0, nil, nil)
    assert(count > 0, 'Invalid redirect encoding')
    local text = ffi.new('char[?]', count)
    check(K.WideCharToMultiByte(65001, 0, buffer, -1, text, count, nil, nil), 'Decode redirect')
    return ffi.string(text)
end

function M.fetch(url, body, proxy)
    local handles = {}
    local deadline = tonumber(K.GetTickCount64()) + 18000
    local function budget(handle)
        local remaining = deadline - tonumber(K.GetTickCount64())
        assert(remaining > 0, 'Request timed out (18-second total limit)')
        check(W.WinHttpSetTimeouts(handle, math.min(5000, remaining), math.min(5000, remaining),
            math.min(12000, remaining), math.min(12000, remaining)), 'Set request deadline')
    end
    local function own(value, operation)
        check(value, operation); handles[#handles + 1] = value; return value
    end
    local function close()
        for index = #handles, 1, -1 do W.WinHttpCloseHandle(handles[index]); handles[index] = nil end
    end
    local ok, result = pcall(function()
        local access, proxy_name = 4, nil -- automatic system/per-user proxies on Windows 8.1+
        if proxy == 'none' then access = 1
        elseif proxy and proxy ~= 'auto' then
            assert(proxy:match('^http://'), 'Windows HTTP supports HTTP proxies. Use --http-client curl for other proxy types.')
            access, proxy_name = 3, wide(proxy:sub(8))
        end
        for redirects = 0, 4 do
            assert(type(url) == 'string' and not url:find('[%z\1-\32\127]'), 'Invalid request URL')
            local authority, path = url:match('^https://([^/?#]+)(.*)$')
            path = path and path:gsub('#.*$', '') or '/'
            if path == '' then path = '/' elseif path:sub(1, 1) == '?' then path = '/' .. path end
            assert(authority, 'Only HTTPS URLs and redirects are allowed')
            local host, port = authority:match('^([^:]+):(%d+)$')
            host, port = host or authority, tonumber(port) or 443
            assert(not host:find('[@?#]') and port >= 1 and port <= 65535, 'Invalid HTTPS host or port')
            local agent = wide('Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                .. 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
            local session = own(W.WinHttpOpen(agent, access, proxy_name, nil, 0), 'Open Windows HTTP')
            budget(session)
            local connection = own(W.WinHttpConnect(session, wide(host), port, 0), 'Connect')
            local request = own(W.WinHttpOpenRequest(connection, wide(body and 'POST' or 'GET'), wide(path),
                nil, nil, nil, 0x800000), 'Open HTTPS request')
            local never = ffi.new('unsigned long[1]', 0)
            check(W.WinHttpSetOption(request, 88, never, 4), 'Require manual HTTPS redirects')
            local decompression = ffi.new('unsigned long[1]', 3)
            check(W.WinHttpSetOption(request, 118, decompression, 4), 'Enable decompression')
            local headers = body and wide('Content-Type: application/x-www-form-urlencoded\r\n') or nil
            budget(request)
            check(W.WinHttpSendRequest(request, headers, headers and 0xffffffff or 0,
                body and ffi.cast('void *', ffi.cast('const char *', body)) or nil,
                body and #body or 0, body and #body or 0, 0), 'Send HTTPS request')
            budget(request)
            check(W.WinHttpReceiveResponse(request, nil), 'Receive HTTPS response')
            local status, size = ffi.new('unsigned long[1]'), ffi.new('unsigned long[1]', 4)
            check(W.WinHttpQueryHeaders(request, 19 + 0x20000000, nil, status, size, nil), 'Read HTTP status')
            local code = tonumber(status[0])
            if not body and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
                assert(redirects < 4, 'Too many HTTPS redirects')
                local target = location(request)
                if target:sub(1, 2) == '//' then target = 'https:' .. target
                elseif target:sub(1, 1) == '/' then target = 'https://' .. authority .. target
                elseif not target:match('^%a[%w+.-]*:') then
                    target = 'https://' .. authority .. (path:match('^(.*)/') or '') .. '/' .. target
                end
                assert(target:match('^https://'), 'Blocked non-HTTPS redirect')
                url = target
                close()
            else
                assert(code == 200, 'Dictionary returned HTTP ' .. code)
                local buffer, read = ffi.new('char[16384]'), ffi.new('unsigned long[1]')
                local chunks, total = {}, 0
                repeat
                    budget(request)
                    check(W.WinHttpReadData(request, buffer, 16384, read), 'Read HTTPS response')
                    total = total + tonumber(read[0])
                    assert(total <= 2 * 1024 * 1024, 'Dictionary response exceeds 2 MB')
                    if read[0] > 0 then chunks[#chunks + 1] = ffi.string(buffer, read[0]) end
                until read[0] == 0
                return table.concat(chunks)
            end
        end
    end)
    close()
    if not ok then return nil, 'Dictionary connection failed: ' .. tostring(result)
        .. ' (Windows WinHTTP, proxy: ' .. (proxy == 'none' and 'direct' or proxy == 'auto' and 'automatic' or 'configured')
        .. ', URL: ' .. tostring(url) .. ')' end
    return result
end
return M
