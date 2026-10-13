-- HTTPS via libcurl FFI. No shells, temporary credentials, or command arguments.
local ffi = require('ffi')
local jit = require('jit')
ffi.cdef[[
typedef void WB_CURL;
int curl_global_init(long);
WB_CURL *curl_easy_init(void);
void curl_easy_cleanup(WB_CURL *);
int curl_easy_setopt(WB_CURL *, int, ...);
int curl_easy_perform(WB_CURL *);
int curl_easy_getinfo(WB_CURL *, int, ...);
const char *curl_easy_strerror(int);
unsigned char *SHA256(const unsigned char *, size_t, unsigned char *);
]]
local curl, curl_info
local tls_revoke_best_effort = false
local proxy_mode = 'auto'
local CURLOPT = {
    TIMEOUT         = 13,
    FOLLOWLOCATION  = 52,
    POSTFIELDSIZE   = 60,
    MAXREDIRS       = 68,
    CONNECTTIMEOUT  = 78,
    NOSIGNAL        = 99,
    PROTOCOLS       = 181,
    REDIR_PROTOCOLS = 182,
    SSL_VERIFYPEER  = 64,
    SSL_VERIFYHOST  = 81,
    SSL_OPTIONS     = 216,
    HTTP_VERSION    = 84,
    PROXY           = 10004,
    ACCEPT_ENCODING = 10102,
    URL             = 10002,
    ERRORBUFFER     = 10010,
    POSTFIELDS      = 10015,
    USERAGENT       = 10018,
    WRITEFUNCTION   = 20011,
}
local CURLINFO_RESPONSE_CODE = 0x200002
local CURLPROTO_HTTPS = 2

local M = {}

function M.set_curl(library, info)
    assert(not curl or curl == library, 'Curl library is already in use')
    curl, curl_info = library, info
end

function M.set_tls_revoke_best_effort(enabled)
    assert(type(enabled) == 'boolean', 'TLS revocation setting must be true or false')
    local schannel = curl_info and curl_info.tls and curl_info.tls:find('Schannel', 1, true)
    if enabled and schannel then
        assert(curl_info.version_num and curl_info.version_num >= 0x074600,
            'Best-effort revocation requires Schannel curl 7.70 or newer. Use --curl-select.')
    end
    tls_revoke_best_effort = enabled
    return enabled and schannel ~= nil
end

function M.set_proxy(value)
    assert(type(value) == 'string' and #value > 0 and #value <= 2048
        and not value:find('[%z\1-\31\127]'), 'Invalid proxy setting')
    assert(value == 'auto' or value == 'none' or value:match('^https?://.+')
        or value:match('^socks[45]h?://.+'), 'Proxy must be auto, none, or an HTTP/HTTPS/SOCKS URL')
    proxy_mode = value
end

local function request_proxy(url)
    if proxy_mode == 'none' then return '', 'direct override' end
    if proxy_mode ~= 'auto' then return proxy_mode, 'configured proxy' end
    if ffi.os ~= 'Windows' then return nil, 'curl defaults' end
    local windows_args = require('windows_args')
    for _, name in ipairs({ 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY' }) do
        local value = windows_args.getenv(name)
        if value and value ~= '' then return nil, 'curl environment proxy' end
    end
    local proxy, source, warning = require('windows_proxy').resolve(url)
    if warning then io.stderr:write('Wordbook warning: ' .. warning .. '\n'); io.stderr:flush() end
    return proxy, source
end

local function load_curl()
    if curl_info then return end
    local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
    local directory = source:match('^(.*)/') or '.'
    curl, curl_info = require('curl_loader').load(directory .. '/..', { script_dir = directory }, {})
end

function M.fetch(url, body)
    load_curl()
    if curl_info and curl_info.error then return nil, curl_info.error end
    if not curl then
        return nil, 'No HTTPS-capable curl library available. Use --curl-select.'
    end
    local handle = curl.curl_easy_init()
    if handle == nil then
        return nil, 'Could not initialize HTTPS request.'
    end
    local route = 'unresolved'
    local error_buffer = ffi.new('char[256]')
    local chunks, size = {}, 0
    local callback = ffi.cast('size_t (*)(char *, size_t, size_t, void *)', function(data, unit, count)
        local bytes = tonumber(unit * count)
        size = size + bytes
        if size > 2 * 1024 * 1024 then return 0 end
        chunks[#chunks + 1] = ffi.string(data, bytes)
        return bytes
    end)
    local function option(key, value)
        local rc = curl.curl_easy_setopt(handle, key, value)
        if rc ~= 0 then
            error('libcurl option failed: ' .. ffi.string(curl.curl_easy_strerror(rc)))
        end
    end
    local ok, result, message = pcall(function()
        option(CURLOPT.URL, url)
        option(CURLOPT.ERRORBUFFER, error_buffer)
        local proxy
        proxy, route = request_proxy(url)
        if proxy ~= nil then option(CURLOPT.PROXY, proxy) end
        local public_page = url:match('^https://www%.iciba%.com/') or url:match('^https://dict%.cn/')
            or url:match('^https://www%.youdao%.com/')
        local agent = public_page and 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            .. 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
            or 'Wordbook/1.0 (personal dictionary)'
        option(CURLOPT.USERAGENT, agent)
        option(CURLOPT.ACCEPT_ENCODING, '')
        if public_page then option(CURLOPT.HTTP_VERSION, ffi.new('long', 2)) end -- HTTP/1.1
        option(CURLOPT.WRITEFUNCTION, callback)
        option(CURLOPT.FOLLOWLOCATION, ffi.new('long', 1))
        option(CURLOPT.MAXREDIRS, ffi.new('long', 4))
        option(CURLOPT.PROTOCOLS, ffi.new('long', CURLPROTO_HTTPS))
        option(CURLOPT.REDIR_PROTOCOLS, ffi.new('long', CURLPROTO_HTTPS))
        option(CURLOPT.SSL_VERIFYPEER, ffi.new('long', 1))
        option(CURLOPT.SSL_VERIFYHOST, ffi.new('long', 2))
        if tls_revoke_best_effort and curl_info.tls and curl_info.tls:find('Schannel', 1, true) then
            option(CURLOPT.SSL_OPTIONS, ffi.new('long', 8)) -- CURLSSLOPT_REVOKE_BEST_EFFORT
        end
        option(CURLOPT.NOSIGNAL, ffi.new('long', 1))
        option(CURLOPT.CONNECTTIMEOUT, ffi.new('long', 5))
        option(CURLOPT.TIMEOUT, ffi.new('long', 12))
        if body then
            option(CURLOPT.POSTFIELDS, body)
            option(CURLOPT.POSTFIELDSIZE, ffi.new('long', #body))
        end
        local rc = curl.curl_easy_perform(handle)
        if rc ~= 0 then
            local detail = ffi.string(error_buffer)
            if detail == '' then detail = ffi.string(curl.curl_easy_strerror(rc)) end
            return nil, 'Dictionary connection failed: ' .. detail .. ' (curl ' .. curl_info.version
                .. ', ' .. curl_info.path .. ', route: ' .. route .. ', URL: ' .. url .. ')'
        end
        local status = ffi.new('long[1]')
        assert(curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, status) == 0, 'Cannot read HTTP status')
        if status[0] ~= 200 then
            return nil, 'Dictionary returned HTTP ' .. tonumber(status[0]) .. '.'
        end
        return table.concat(chunks)
    end)
    curl.curl_easy_cleanup(handle)
    callback:free()
    if not ok then
        return nil, 'HTTPS request failed: ' .. tostring(result)
    end
    return result, message
end
-- curl_easy_perform invokes Lua callbacks; keep this FFI call off JIT traces.
jit.off(M.fetch, true)

local crypto_names = {
    'crypto',
    'libcrypto.so.3',
    'libcrypto.so',
    'libcrypto-3.dll',
    'libcrypto.dll',
    'libcrypto.dylib',
}
local crypto
local function get_crypto()
    if crypto ~= nil then return crypto end
    for _, name in ipairs(crypto_names) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            crypto = lib
            return crypto
        end
    end
    return nil
end

function M.sha256(text)
    local crypt = get_crypto()
    if not crypt then error('OpenSSL crypto library not found') end
    local digest = ffi.new('unsigned char[32]')
    assert(crypt.SHA256(text, #text, digest) ~= nil, 'SHA256 failed')
    local hex = {}
    for index = 0, 31 do
        hex[#hex + 1] = string.format('%02x', digest[index])
    end
    return table.concat(hex)
end

function M.encode(text)
    return (text:gsub('[^%w%-_%.~]', function(char)
        return string.format('%%%02X', char:byte())
    end))
end

function M.form(values)
    local keys, parts = {}, {}
    for key in pairs(values) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = M.encode(key) .. '=' .. M.encode(tostring(values[key]))
    end
    return table.concat(parts, '&')
end
return M
