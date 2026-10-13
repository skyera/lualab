-- Dictionary SQLite selection and verified configuration persistence.
local ffi = require('ffi')
local Fs = require('fs')
local json = require('json')
local windows_args = require('windows_args')
local loader = require('sqlite')
local curl_loader = require('curl_loader')
local M = {}

local function report(message)
    print('Wordbook: ' .. message)
    io.stdout:flush()
end

local function read(path)
    if ffi.os == 'Windows' then return Fs.read_file(path) end
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end

function M.configure(root, options)
    local home = windows_args.getenv(ffi.os == 'Windows' and 'USERPROFILE' or 'HOME') or '.'
    local base = windows_args.getenv(ffi.os == 'Windows' and 'APPDATA' or 'XDG_CONFIG_HOME')
        or home .. '/.config'
    local path = Fs.resolve(options.config or base .. '/wordbook/config.json')
    report('Reading configuration: ' .. path)
    local text = read(path)
    if not text then report('Configuration not found; using defaults: ' .. path) end
    local config = text and json.decode(text) or {}
    assert(type(config) == 'table', 'Configuration must be a JSON object: ' .. path)
    local tls_best_effort = options.tls_revoke_best_effort
    if tls_best_effort == nil then tls_best_effort = config.tls_revoke_best_effort end
    assert(tls_best_effort == nil or type(tls_best_effort) == 'boolean',
        'tls_revoke_best_effort must be true or false: ' .. path)
    if options.curl_list then
        print('Curl library candidates (not loaded):')
        local candidates = curl_loader.discover(root, options.script_dir)
        for index, candidate in ipairs(candidates) do
            print(index .. '. ' .. candidate.path .. ' [' .. candidate.source .. ']'
                .. (candidate.reason and ' - ' .. candidate.reason or ''))
        end
        if #candidates == 0 then print('No DLL found. Use --curl-dll PATH.') end
        io.stdout:flush()
        return true
    end
    if options.sqlite_list then
        print('SQLite library candidates (not loaded):')
        local candidates = loader.discover(root, options.script_dir)
        for index, candidate in ipairs(candidates) do
            print(index .. '. ' .. candidate.path .. ' [' .. candidate.source .. ']'
                .. (candidate.reason and ' - ' .. candidate.reason or ''))
        end
        if #candidates == 0 then print('No DLL found. Use --sqlite-dll PATH.') end
        io.stdout:flush()
        return true
    end
    local info
    if not options.curl_select then
        options.require_fts5, options.sqlite_env = true, 'WORDBOOK_SQLITE3'
        info = loader.load(root, options, config, report, function(message)
            io.stderr:write('Wordbook warning: ' .. message .. '\n'); io.stderr:flush()
        end)
        require('ffi_dict').Database.set_library(info.library)
        report('SQLite ' .. info.version .. ' selected (FTS5 verified): ' .. info.path)
    end
    local curl_info
    assert(not (options.curl_select or options.curl_dll) or not options.http_client
        or options.http_client == 'curl', 'Curl selection requires --http-client curl')
    local client = options.http_client or (options.curl_select or options.curl_dll) and 'curl'
        or config.http_client or (ffi.os == 'Windows' and 'native' or 'curl')
    if not options.sqlite_select then
        local net = require('net')
        net.set_client(client)
        local proxy = options.proxy or config.proxy or 'auto'
        net.set_proxy(proxy)
        if client == 'native' then
            report('HTTP client: Windows WinHTTP (' .. (proxy == 'auto' and 'automatic system proxy'
                or proxy == 'none' and 'direct connection' or 'configured proxy') .. ')')
            report('TLS: Windows defaults; certificate and hostname verification enabled')
        else
            local library
            library, curl_info = curl_loader.load(root, options, config, report, function(message)
                io.stderr:write('Wordbook warning: ' .. message .. '\n'); io.stderr:flush()
            end)
            require('net').set_curl(library, curl_info)
            local proxy = options.proxy or config.proxy or 'auto'
            require('net').set_proxy(proxy)
            if proxy == 'auto' and ffi.os == 'Windows' then
                report('HTTP proxy: Windows settings (explicit proxy environment variables take precedence)')
            else
                report('HTTP proxy: ' .. (proxy == 'auto' and 'curl defaults' or proxy == 'none' and 'direct' or 'configured'))
            end
            local active = require('net').set_tls_revoke_best_effort(tls_best_effort == true)
            if active then
                report('TLS revocation: best effort (Schannel); certificate and hostname verification enabled')
            elseif tls_best_effort then
                report('TLS revocation: best-effort setting inactive; selected backend is not Schannel')
            else
                report('TLS revocation: backend defaults; certificate and hostname verification enabled')
            end
            if library then
                report('Curl ' .. curl_info.version .. ' selected (HTTPS, ' .. curl_info.tls .. '): ' .. curl_info.path)
            else
                io.stderr:write('Wordbook warning: ' .. curl_info.error .. '\n'); io.stderr:flush()
            end
        end
    end
    if options.sqlite_select or options.curl_select or options.save_config then
        if info then config.sqlite_dll = info.pin or info.path end
        if curl_info and curl_info.path then config.curl_dll = curl_info.path end
        if options.http_client ~= nil then config.http_client = options.http_client
        elseif options.curl_select or options.curl_dll then config.http_client = 'curl' end
        if options.proxy ~= nil then config.proxy = options.proxy end
        if options.tls_revoke_best_effort ~= nil then
            config.tls_revoke_best_effort = options.tls_revoke_best_effort
        end
        report('Saving configuration: ' .. path)
        local fs = Fs.open(path:match('^(.*)/[^/]+$') or '.')
        local saved, err = pcall(function()
            local name = path:match('[^/]+$')
            local encoded = json.encode(config)
            fs:write(name, encoded)
            assert(fs:read(name) == encoded, 'Saved configuration verification failed: ' .. path)
        end)
        fs:close()
        assert(saved, err)
        report('Configuration saved and verified: ' .. path)
    end
    return options.sqlite_select or options.curl_select or false
end

return M
