#!/usr/bin/env luajit
-- Local dictionary web app: LuaJIT + SQLite/libcurl, Linux workers or Windows inline requests.
local script = arg[0]:gsub('\\', '/')
local root = script:match('^(.*)/[^/]+$') or '.'
package.path = root .. '/?.lua;' .. root .. '/../?.lua;' .. root .. '/../wiki_web/?.lua;' .. package.path
local function main()
    local windows_args = require('windows_args')
    windows_args.normalize()
    local json = require('json')
    local service = require('service')
    local http = require('http')
    local ffi = require('ffi')
    local workers = ffi.os ~= 'Windows' and require('workers').new(http.close_inherited) or nil

    local function read_file(path)
        local file, err = io.open(path, 'rb')
        if not file then return nil, err end
        local data = file:read('*a')
        file:close()
        return data
    end

    local port, database, bind_host = 8030, root .. '/wordbook.db', '127.0.0.1'
    local dictionary_path = root .. '/../.dict.db'
    local auto_import, force_import = true, false
    local sqlite_options = { script_dir = root }
    local index = 1
    while index <= #arg do
        if arg[index] == '--help' then
            print('Usage: luajit dictionary_web/app.lua [--host 127.0.0.1|0.0.0.0] [--port 8030] '
                .. '[--db /path/wordbook.db] [--dict-db /path/.dict.db|none] [--import-dict] '
                .. '[--no-auto-import] [--sqlite-list] [--sqlite-select] [--sqlite-dll PATH] '
                .. '[--config FILE] [--save-config]')
            os.exit(0)
        elseif arg[index] == '--sqlite-list' then sqlite_options.sqlite_list = true
        elseif arg[index] == '--sqlite-select' then sqlite_options.sqlite_select = true
        elseif arg[index] == '--save-config' then sqlite_options.save_config = true
        elseif arg[index] == '--sqlite-dll' or arg[index] == '--config' then
            local flag = arg[index]
            index = index + 1
            assert(arg[index] and arg[index]:sub(1, 2) ~= '--', 'Missing value for ' .. flag)
            sqlite_options[flag:sub(3):gsub('-', '_')] = arg[index]
        elseif arg[index] == '--port' then
            index = index + 1
            port = tonumber(arg[index])
            if not port or port < 0 or port > 65535 or port % 1 ~= 0 then
                error('Invalid --port (0-65535).')
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

    if require('sqlite_config').configure(root .. '/..', sqlite_options) then return end
    local Store = require('store')
    local schema = assert(read_file(root .. '/schema.sql'))
    if ffi.os == 'Windows' then
        print('Windows: provider requests run inline; other requests may wait during online lookups.')
        io.stdout:flush()
    end
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
        ['/theme.js']   = { 'theme.js', 'text/javascript; charset=utf-8' },
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
        if path == '/api/export' then
            if request.method ~= 'GET' and request.method ~= 'HEAD' then
                return reply({ error = 'Method not allowed.' }, 405)
            end
            local format = params.format or 'json'
            if format ~= 'json' and format ~= 'csv' then return reply({ error = 'Invalid export format.' }, 400) end
            local data = format == 'json' and json.encode(db:export_backup()) or db:export_csv()
            if format == 'json' and #data > 16 * 1024 * 1024 then
                return reply({ error = 'JSON backups are limited to 16 MB. Back up the database files directly.' }, 413)
            end
            local filename = 'wordbook-' .. os.date('!%Y-%m-%d') .. '.' .. format
            return data, 200, format == 'csv' and 'text/csv; charset=utf-8' or 'application/json; charset=utf-8',
                { ['Content-Disposition'] = 'attachment; filename="' .. filename .. '"' }
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
            local generation = db.lookup_generation
            local word = type(payload) == 'table' and service.normalize(payload.word) or nil
            local version = word and (db.word_versions[word] or 0) or 0
            local background = request.background and { run = request.background, guard = function()
                return db.lookup_generation == generation and (not word or (db.word_versions[word] or 0) == version)
            end } or nil
            local data, status = service.route(db, request.method == 'HEAD' and 'GET' or request.method,
                path, params, payload, background)
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
    end, bind_host, workers)
    db:close()
    if not ok then
        io.stderr:write(tostring(err) .. '\n')
        os.exit(1)
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    io.stderr:write('Wordbook failed: ' .. tostring(err) .. '\n'
        .. 'SQLite recovery: use --sqlite-list or --sqlite-select [--config FILE],\n'
        .. 'or --sqlite-dll PATH --save-config. DLL must match LuaJIT and support FTS5.\n')
    io.stderr:flush()
    os.exit(1)
end
