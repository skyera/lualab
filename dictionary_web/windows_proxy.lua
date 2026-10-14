--------------------------------------------------------------------------------
-- windows_proxy.lua
-- Windows user proxy and per-URL PAC resolution for libcurl requests.
--------------------------------------------------------------------------------

local ffi = require('ffi')

--------------------------------------------------------------------------------
-- FFI & WinHTTP API Declarations
--------------------------------------------------------------------------------

ffi.cdef[[
typedef struct { int auto_detect; uint16_t *auto_url, *proxy, *bypass; } dict_ie_proxy;
typedef struct { unsigned long access; uint16_t *proxy, *bypass; } dict_proxy_info;
typedef struct {
    unsigned long flags, detect_flags; const uint16_t *auto_url; void *reserved;
    unsigned long reserved_flags; int auto_logon;
} dict_auto_proxy;
int __stdcall WinHttpGetIEProxyConfigForCurrentUser(dict_ie_proxy *);
void * __stdcall WinHttpOpen(const uint16_t *, unsigned long, const uint16_t *, const uint16_t *, unsigned long);
int __stdcall WinHttpSetTimeouts(void *, int, int, int, int);
int __stdcall WinHttpGetProxyForUrl(void *, const uint16_t *, dict_auto_proxy *, dict_proxy_info *);
int __stdcall WinHttpCloseHandle(void *);
int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, uint16_t *, int);
int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const uint16_t *, int,
    char *, int, const char *, int *);
void * __stdcall GlobalFree(void *);
unsigned long __stdcall GetLastError(void);
]]

local winhttp, kernel = ffi.load('winhttp'), ffi.load('kernel32')
local M = {}

--------------------------------------------------------------------------------
-- Unicode Conversion & Memory Helpers
--------------------------------------------------------------------------------

local function wide(text)
    local count = kernel.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
    assert(count > 0, 'Invalid UTF-8 proxy URL')
    local value = ffi.new('uint16_t[?]', count + 1)
    assert(kernel.MultiByteToWideChar(65001, 8, text, #text, value, count) == count, 'Cannot encode proxy URL')
    return value
end

local function utf8(value)
    if value == nil then
        return nil
    end
    local count = kernel.WideCharToMultiByte(65001, 0, value, -1, nil, 0, nil, nil)
    assert(count > 0, 'Cannot read Windows proxy settings')
    local text = ffi.new('char[?]', count)
    assert(kernel.WideCharToMultiByte(65001, 0, value, -1, text, count, nil, nil) == count,
        'Cannot convert Windows proxy settings')
    return ffi.string(text)
end

local function release(record, names)
    for _, name in ipairs(names) do
        if record[name] ~= nil then
            kernel.GlobalFree(record[name])
            record[name] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Windows Proxy Discovery & Filtering
--------------------------------------------------------------------------------

function M.settings()
    local record = ffi.new('dict_ie_proxy')
    if winhttp.WinHttpGetIEProxyConfigForCurrentUser(record) == 0 then
        local code = tonumber(kernel.GetLastError())
        if code == 2 then
            return {}
        end
        error('Cannot read Windows proxy settings (Windows error ' .. code .. ')')
    end
    local ok, result = pcall(function()
        return {
            auto_detect = record.auto_detect ~= 0,
            auto_url = utf8(record.auto_url),
            proxy = utf8(record.proxy),
            bypass = utf8(record.bypass),
        }
    end)
    release(record, { 'auto_url', 'proxy', 'bypass' })
    assert(ok, result)
    return result
end

function M.select_proxy(text, scheme)
    if not text or text == '' then
        return ''
    end
    local generic, selected
    for token in text:gmatch('[^;%s]+') do
        local protocol, address = token:match('^(%a+)=(.+)$')
        if protocol == scheme then
            selected = address
        elseif not protocol and not generic then
            generic = token
        end
    end
    return selected or generic or ''
end

function M.bypassed(url, patterns)
    local host = url:match('^%a+://([^/:]+)')
    if not host or not patterns then
        return false
    end
    host = host:lower()
    for token in patterns:lower():gmatch('[^;%s]+') do
        if token == '<local>' then
            if not host:find('.', 1, true) then
                return true
            end
        else
            local pattern = token:gsub('([%^%$%(%)%%%.%[%]%+%-])', '%%%1'):gsub('%*', '.*'):gsub('%?', '.')
            if host:match('^' .. pattern .. '$') then
                return true
            end
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- PAC URL Resolution
--------------------------------------------------------------------------------

function M.resolve(url, settings)
    settings = settings or M.settings()
    local scheme = assert(url:match('^(%a+)://'), 'Invalid proxy request URL')
    if settings.auto_url or settings.auto_detect then
        local session = winhttp.WinHttpOpen(wide('Wordbook/1.0'), 1, nil, nil, 0)
        assert(session ~= nil, 'Cannot open Windows proxy resolver')
        local options, result = ffi.new('dict_auto_proxy'), ffi.new('dict_proxy_info')
        -- Keep the PAC URL buffer alive through the native call.
        local auto_url = settings.auto_url and wide(settings.auto_url) or nil
        options.flags = (settings.auto_url and 2 or 0) + (settings.auto_detect and 1 or 0)
        options.detect_flags, options.auto_url = 3, auto_url
        local timed = winhttp.WinHttpSetTimeouts(session, 5000, 5000, 5000, 5000)
        local resolved = timed ~= 0 and winhttp.WinHttpGetProxyForUrl(session, wide(url), options, result) ~= 0
        local code = tonumber(kernel.GetLastError())
        winhttp.WinHttpCloseHandle(session)
        if resolved then
            local ok, proxy = pcall(function()
                if result.access == 1 or M.bypassed(url, utf8(result.bypass)) then
                    return ''
                end
                return M.select_proxy(utf8(result.proxy), scheme)
            end)
            release(result, { 'proxy', 'bypass' })
            assert(ok, proxy)
            return proxy, 'Windows PAC'
        end
        release(result, { 'proxy', 'bypass' })
        if settings.proxy then
            local proxy = M.bypassed(url, settings.bypass) and '' or M.select_proxy(settings.proxy, scheme)
            return proxy, 'Windows static proxy',
                'PAC resolution failed (Windows error ' .. code .. '); using static settings'
        end
        if not settings.auto_url and code == 12180 then
            return '', 'Windows direct'
        end
        error('Windows PAC resolution failed (Windows error ' .. code .. '). Configure --proxy URL or --proxy none.')
    end
    if M.bypassed(url, settings.bypass) then
        return '', 'Windows direct'
    end
    return M.select_proxy(settings.proxy, scheme), settings.proxy and 'Windows static proxy' or 'Windows direct'
end

return M
