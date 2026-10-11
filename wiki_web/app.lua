-- Leaf Wiki launcher, persistent folder configuration and same-origin HTTP API.
local json = require('json')
local Fs = require('fs')
local Notebook = require('notebook')
local http = require('http')
local M = {}
local STATIC = {
    ['/'] = { 'index.html', 'text/html; charset=utf-8' },
    ['/app.js'] = { 'app.js', 'text/javascript; charset=utf-8' },
    ['/markdown.js'] = { 'markdown.js', 'text/javascript; charset=utf-8' },
    ['/style.css'] = { 'style.css', 'text/css; charset=utf-8' },
}

local function read(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local value = file:read('*a'); file:close(); return value
end

function M.run(root)
    local home = os.getenv('HOME') or '.'
    local config_path = (os.getenv('XDG_CONFIG_HOME') or home .. '/.config') .. '/leaf-wiki/config.json'
    local cache = (os.getenv('XDG_CACHE_HOME') or home .. '/.cache') .. '/leaf-wiki'
    local options = { port = 8770 }
    local index = 1
    while index <= #arg do
        local flag = arg[index]
        if flag == '--help' then
            print('Usage: luajit wiki_web.lua [--data-dir PATH] [--cache-dir PATH] '
                .. '[--config FILE] [--save-config] [--port 8770]')
            return
        elseif flag == '--save-config' then options.save_config = true
        elseif flag == '--data-dir' or flag == '--cache-dir' or flag == '--config' or flag == '--port' then
            index = index + 1
            assert(arg[index] and arg[index]:sub(1, 2) ~= '--', 'Missing value for ' .. flag)
            options[flag:sub(3):gsub('-', '_')] = arg[index]
        else error('Unknown option: ' .. flag) end
        index = index + 1
    end
    config_path = options.config or config_path
    local raw = read(config_path)
    local config = raw and json.decode(raw) or {}
    assert(type(config) == 'table', 'Configuration must be a JSON object')
    local data_dir = options.data_dir or os.getenv('LEAF_WIKI_DATA_DIR') or config.data_dir or home .. '/Leaf Wiki'
    local port = tonumber(options.port)
    assert(port and port >= 0 and port <= 65535 and port % 1 == 0, 'Invalid port')
    local notebook = Notebook.open(data_dir, options.cache_dir or cache)
    if options.save_config then
        local parent = config_path:match('^(.*)/[^/]+$') or '.'
        local fs = Fs.open(parent)
        fs:write(config_path:match('[^/]+$'), json.encode({ data_dir = notebook.fs.root }))
        fs:close()
    end
    local function reply(value, status) return json.encode(value), status or 200, 'application/json; charset=utf-8' end
    local function route(request, actual_port)
        local host = request.headers.host
        if host ~= '127.0.0.1:' .. actual_port and host ~= 'localhost:' .. actual_port then
            return reply({ error = 'Invalid Host header.' }, 403)
        end
        if request.headers.origin and request.headers.origin ~= 'http://' .. host then
            return reply({ error = 'Cross-origin requests are not allowed.' }, 403)
        end
        local path, params = http.target(request.target)
        local method = request.method == 'HEAD' and 'GET' or request.method
        if method ~= 'GET' and method ~= 'POST' then return reply({ error = 'Method not allowed.' }, 405) end
        if method == 'GET' then
            if STATIC[path] then
                return assert(read(root .. '/wiki_web/static/' .. STATIC[path][1])), 200, STATIC[path][2]
            end
            if path == '/api/state' then return reply(notebook:state(params.q)) end
            if path == '/api/page' then
                local page = notebook:page(params.id)
                if not page then return reply({ error = 'Page not found.' }, 404) end
                page.backlinks = notebook:backlinks(page.id)
                return reply(page)
            end
            if path == '/api/attachment' then
                local bytes, mime = notebook:attachment(params.page, params.file)
                if not bytes then return reply({ error = 'Attachment not found.' }, 404) end
                return bytes, 200, mime
            end
        elseif path == '/api/image' then
            return reply(notebook:image(params.page, request.body))
        elseif path:sub(1, 5) == '/api/' then
            local media_type = (request.headers['content-type'] or ''):lower():match('^%s*([^;]+)') or ''
            if media_type:gsub('%s+$', '') ~= 'application/json' then
                return reply({ error = 'Send application/json.' }, 415)
            end
            local payload = json.decode(request.body)
            assert(type(payload) == 'table', 'Expected a JSON object')
            local value, err, status
            if path == '/api/page' then value, err, status = notebook:save(payload.id, payload.content, payload.revision)
            elseif path == '/api/rename' then
                value, err, status = notebook:rename(payload.id, payload.destination, payload.revision)
            elseif path == '/api/trash' then value, err, status = notebook:trash(payload.id, payload.revision)
            elseif path == '/api/restore' then value, err, status = notebook:restore(payload.token)
            else return reply({ error = 'Not found.' }, 404) end
            return reply(value or { error = err }, status or 200)
        end
        return reply({ error = 'Not found.' }, 404)
    end
    local function handler(request, actual_port)
        local result = { pcall(route, request, actual_port) }
        if not result[1] then return reply({ error = tostring(result[2]):gsub('^.-:%d+: ', '') }, 400) end
        return result[2], result[3], result[4], result[5]
    end
    local ok, err = pcall(http.serve, port, handler, function(actual_port)
        print('Leaf Wiki: http://127.0.0.1:' .. actual_port .. ' | Notebook: ' .. notebook.fs.root)
        io.stdout:flush()
    end, '127.0.0.1', nil, { body_limits = { ['/api/page'] = 7 * 1024 * 1024, ['/api/image'] = 5 * 1024 * 1024 } })
    notebook:close()
    if not ok then error(err) end
end
return M
