#!/usr/bin/env luajit
-- Local dictionary web app: LuaJIT + SQLite/libcurl/POSIX FFI.
local script = arg[0]:gsub('\\', '/')
local root = script:match('^(.*)/[^/]+$') or '.'
package.path = root .. '/?.lua;' .. root .. '/../?.lua;' .. package.path
local json = require('json')
local Store = require('store')
local service = require('service')
local http = require('http')

local function read_file(path)
    local file, err = io.open(path, 'rb')
    if not file then return nil, err end
    local data = file:read('*a')
    file:close()
    return data
end

local port, database, bind_host = 8765, root .. '/wordbook.db', '127.0.0.1'
local dictionary_path = root .. '/../.dict.db'
local auto_import, force_import = true, false
local index = 1
while index <= #arg do
    if arg[index] == '--help' then
        print('Usage: luajit dictionary_web/app.lua [--host 127.0.0.1|0.0.0.0] [--port 8765] [--db /path/wordbook.db] [--dict-db /path/.dict.db|none] [--import-dict] [--no-auto-import]')
        os.exit(0)
    elseif arg[index] == '--port' then
        index = index + 1
        port = tonumber(arg[index])
        if not port or port < 0 or port > 65535 or port % 1 ~= 0 then
            error('Invalid --port (0–65535).')
        end
    elseif arg[index] == '--host' then
        index = index + 1
        bind_host = arg[index]
        if bind_host ~= '127.0.0.1' and bind_host ~= '0.0.0.0' then
            error('Invalid --host (127.0.0.1 or 0.0.0.0).')
        end
    elseif arg[index] == '--auto-import' then
        auto_import = true
    elseif arg[index] == '--no-auto-import' then
        auto_import = false
    elseif arg[index] == '--import-dict' then
        force_import = true
    elseif arg[index] == '--dict-db' then
        index = index + 1
        dictionary_path = assert(arg[index], 'Missing --dict-db path')
    elseif arg[index] == '--db' then
        index = index + 1
        database = assert(arg[index], 'Missing --db path')
    else
        error('Unknown argument: ' .. arg[index])
    end
    index = index + 1
end

local schema = assert(read_file(root .. '/schema.sql'))
if force_import then
    assert(dictionary_path ~= 'none', '--import-dict requires a local dictionary database.')
end
if dictionary_path ~= 'none' and (auto_import or force_import) then
    require('download_dict').ensure({db = dictionary_path, force = force_import})
end
local db = Store.open(database, schema, dictionary_path)
local files = {
    ['/']           = {'index.html', 'text/html; charset=utf-8'},
    ['/index.html'] = {'index.html', 'text/html; charset=utf-8'},
    ['/app.js']     = {'app.js',     'text/javascript; charset=utf-8'},
    ['/style.css']  = {'style.css',  'text/css; charset=utf-8'},
}

local function handler(request, actual_port)
    local function reply(data, status)
        return json.encode(data), status, 'application/json; charset=utf-8'
    end
    local host = request.headers.host
    local allowed = {['127.0.0.1:' .. actual_port] = true, ['localhost:' .. actual_port] = true}
    local hostname, host_port = (host or ''):match('^([%w%.%-]+):(%d+)$')
    local network_host = bind_host == '0.0.0.0' and hostname and tonumber(host_port) == actual_port
    if not allowed[host] and not network_host then
        return reply({error = 'Invalid Host header.'}, 403)
    end
    local origin = request.headers.origin
    if origin and origin ~= 'http://' .. host then
        return reply({error = 'Cross-origin requests are not allowed.'}, 403)
    end
    local path, params = http.target(request.target)
    if request.method ~= 'GET' and request.method ~= 'POST' and request.method ~= 'HEAD' then
        return reply({error = 'Method not allowed.'}, 405)
    end
    if path:sub(1, 5) == '/api/' then
        local payload
        if request.method == 'POST' then
            local kind = request.headers['content-type'] or ''
            local media_type = kind:lower():match('^%s*([^;]+)') or ''
            media_type = media_type:gsub('%s+$', '')
            if media_type ~= 'application/json' then
                return reply({error = 'Send application/json.'}, 415)
            end
            local ok, result = pcall(json.decode, request.body)
            if not ok then
                return reply({error = 'Invalid JSON request.'}, 400)
            end
            payload = result
        end
        local data, status = service.route(db, request.method == 'HEAD' and 'GET' or request.method, path, params, payload)
        return reply(data, status)
    end
    if request.method == 'POST' then
        return reply({error = 'Not found.'}, 404)
    end
    local file = files[path]
    if not file then
        return reply({error = 'Not found.'}, 404)
    end
    local data = read_file(root .. '/static/' .. file[1])
    if not data then
        return reply({error = 'File not found.'}, 404)
    end
    return data, 200, file[2]
end

local ok, err = pcall(http.serve, port, handler, function(actual_port)
    print('Wordbook: http://127.0.0.1:' .. actual_port .. ' | Listening: ' .. bind_host .. ':' .. actual_port .. ' | SQLite: ' .. database)
    io.stdout:flush()
end, bind_host)
db:close()
if not ok then
    io.stderr:write(tostring(err) .. '\n')
    os.exit(1)
end
