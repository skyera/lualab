--------------------------------------------------------------------------------
-- curl_loader.lua
-- libcurl DLL discovery and validation: concrete paths, HTTPS capability and saved pins.
--------------------------------------------------------------------------------

local directory = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/'):match('^(.*)/') or '.'
package.path = directory .. '/../wiki_web/?.lua;' .. package.path

local ffi = require('ffi')
local Fs = require('fs')
local windows_args = require('windows_args')
local native = require('sqlite')
require('net') -- declares curl APIs without loading a library

--------------------------------------------------------------------------------
-- FFI Declarations & Constants
--------------------------------------------------------------------------------

ffi.cdef[[
typedef struct {
    int age; const char *version; unsigned int version_num; const char *host;
    int features; const char *ssl_version; long ssl_version_num;
    const char *libz_version; const char *const *protocols;
} wb_curl_version_info;
const wb_curl_version_info *curl_version_info(int);
int curl_global_init(long);
]]

local M = {}
local WINDOWS = ffi.os == 'Windows'
local NAMES = { 'libcurl.dll', 'libcurl-4.dll', 'curl.dll' }
local SYMBOLS = {
    'curl_global_init',
    'curl_version_info',
    'curl_easy_init',
    'curl_easy_cleanup',
    'curl_easy_setopt',
    'curl_easy_perform',
    'curl_easy_getinfo',
    'curl_easy_strerror',
}

--------------------------------------------------------------------------------
-- Library Discovery & Validation
--------------------------------------------------------------------------------

function M.discover(root, script_dir)
    if WINDOWS then
        return native.discover(root, script_dir, NAMES)
    end
    return {
        { path = 'libcurl.so.4', source = 'loader' },
        { path = 'libcurl.so', source = 'loader' },
        { path = 'libcurl-gnutls.so.4', source = 'loader' },
    }
end

function M.validate(path, report)
    if WINDOWS then
        local valid, err = native.inspect(path)
        assert(valid, path .. ': ' .. tostring(err))
    end
    if report then
        report('Validating curl library: ' .. path)
    end
    local library = native.open_library(path)
    for _, symbol in ipairs(SYMBOLS) do
        assert(pcall(function() return library[symbol] end), 'Curl library is missing ' .. symbol .. ': ' .. path)
    end
    if report then
        report('Reading curl capability metadata')
    end
    local info = library.curl_version_info(0)
    assert(info ~= nil and info.protocols ~= nil, 'Cannot inspect curl protocols: ' .. path)
    local https, protocols = false, {}
    local index = 0
    while index < 128 and info.protocols[index] ~= nil do
        local protocol = ffi.string(info.protocols[index])
        protocols[#protocols + 1] = protocol
        if protocol == 'https' then
            https = true
        end
        index = index + 1
    end
    assert(https, 'Curl library lacks HTTPS support: ' .. path
        .. ' (protocols: ' .. table.concat(protocols, ', ') .. ')')
    assert(library.curl_global_init(ffi.new('long', 3)) == 0, 'Curl initialization failed: ' .. path)
    return library, {
        path = path,
        version = ffi.string(info.version),
        version_num = tonumber(info.version_num),
        tls = info.ssl_version ~= nil and ffi.string(info.ssl_version) or 'unknown TLS backend',
    }
end

--------------------------------------------------------------------------------
-- Library Loading & Resolution
--------------------------------------------------------------------------------

function M.load(root, options, config, report, warn)
    local environment = windows_args.getenv('WORDBOOK_CURL_DLL')
    if environment == '' then
        environment = nil
    end
    local override = options.curl_dll or (not options.curl_select and (environment or config.curl_dll))
    if override then
        local path = not WINDOWS and not override:find('/', 1, true) and override or Fs.resolve(override)
        return M.validate(path, report)
    end
    local candidates = M.discover(root, options.script_dir)
    if options.curl_select then
        assert(#candidates > 0, 'No curl library found. Use --curl-dll PATH.')
        for index, candidate in ipairs(candidates) do
            print(index .. '. ' .. candidate.path .. ' [' .. candidate.source .. ']'
                .. (candidate.reason and ' - ' .. candidate.reason or ''))
        end
        io.write('Select curl library [1-' .. #candidates .. '] (default 1): ')
        io.stdout:flush()
        local choice = io.read('*l')
        local selected = choice == '' and 1 or tonumber(choice)
        assert(selected and selected % 1 == 0 and candidates[selected], 'Invalid curl selection')
        return M.validate(candidates[selected].path, report)
    end
    local errors = {}
    for _, candidate in ipairs(candidates) do
        local ok, library, info = pcall(M.validate, candidate.path, report)
        if ok then
            return library, info
        end
        errors[#errors + 1] = tostring(library)
        if WINDOWS and warn then
            warn(tostring(library))
        end
    end
    return nil, {
        error = 'No HTTPS-capable curl library found. Use --curl-list or --curl-select, '
            .. 'or configure --curl-dll PATH. ' .. table.concat(errors, '; '),
    }
end

return M
