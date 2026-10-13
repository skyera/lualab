-- Leaf Wiki launcher, persistent folder configuration and same-origin HTTP API.
local direct_script = arg[0]:gsub('\\', '/'):match('([^/]+)$') == 'app.lua'
local direct_root
if direct_script then
    local script_path = arg[0]:gsub('\\', '/')
    local script_dir = script_path:match('^(.*)/[^/]+$') or '.'
    direct_root = script_dir .. '/..'
    package.path = script_dir .. '/?.lua;' .. direct_root .. '/dictionary_web/?.lua;'
        .. direct_root .. '/?.lua;' .. package.path
end
local startup = require('startup')
if direct_script and not startup.running then
    if not startup.launch(function() require('app').run(direct_root) end) then os.exit(1) end
    return
end
local windows_args = require('windows_args')
windows_args.normalize()
local getenv = windows_args.getenv
local json = require('json')
local Fs = require('fs')
local Notebook = require('notebook')
local http = require('http')
local dictionary = require('dictionary')
local is_windows = package.config:sub(1, 1) == '\\'
local function quote(value)
    return "'" .. value:gsub("'", is_windows and "''" or "'\\''") .. "'"
end
local M = {}
local STATIC = {
    ['/'] = { 'index.html', 'text/html; charset=utf-8' },
    ['/app.js'] = { 'app.js', 'text/javascript; charset=utf-8' },
    ['/markdown.js'] = { 'markdown.js', 'text/javascript; charset=utf-8' },
    ['/export.js'] = { 'export.js', 'text/javascript; charset=utf-8' },
    ['/style.css'] = { 'style.css', 'text/css; charset=utf-8' },
}

local function read(path)
    if is_windows then return Fs.read_file(path) end
    local file = io.open(path, 'rb')
    if not file then return nil end
    local value = file:read('*a'); file:close(); return value
end

local function is_allowed_host(host, port)
    if host == '127.0.0.1:' .. port or host == 'localhost:' .. port then return true end
    local first, second, third, fourth, supplied_port = host:match(
        '^(%d+)%.(%d+)%.(%d+)%.(%d+):(%d+)$')
    if first then
        if tonumber(supplied_port) ~= port then return false end
        for _, octet in ipairs({ first, second, third, fourth }) do
            local value = tonumber(octet)
            if value < 0 or value > 255 then return false end
        end
        return true
    end
    local name, name_port = host:match('^([%a%d%.%-]+):(%d+)$')
    if not name or tonumber(name_port) ~= port or #name > 253
        or name:sub(1, 1) == '.' or name:sub(-1) == '.'
        or name:match('^[%d%.%-]+$') then return false end
    for label in name:gmatch('[^.]+') do
        if #label > 63 or label:sub(1, 1) == '-' or label:sub(-1) == '-' then
            return false
        end
    end
    return not name:find('%.%.')
end

function M.run(root)
    root = Fs.resolve(root)
    local home = (is_windows and getenv('USERPROFILE')) or getenv('HOME') or '.'
    local config_base = (is_windows and getenv('APPDATA')) or getenv('XDG_CONFIG_HOME') or home .. '/.config'
    local cache_base = (is_windows and getenv('LOCALAPPDATA')) or getenv('XDG_CACHE_HOME') or home .. '/.cache'
    local config_path = config_base .. '/leaf-wiki/config.json'
    local cache = cache_base .. '/leaf-wiki'
    local options = { port = 8020, host = '127.0.0.1' }
    local index = 1
    while index <= #arg do
        local flag = arg[index]
        if flag == '-h' or flag == '--help' then
            print('Usage: luajit wiki_web.lua [--data-dir PATH] [--cache-dir PATH] '
                .. '[--config FILE] [--save-config] [--dict-db PATH|none] '
                .. '[--host 127.0.0.1|0.0.0.0] [--port 8020]')
            return
        elseif flag == '--save-config' then options.save_config = true
        elseif flag == '--data-dir' or flag == '--cache-dir' or flag == '--config'
            or flag == '--dict-db' or flag == '--host' or flag == '--port' then
            index = index + 1
            assert(arg[index] and arg[index]:sub(1, 2) ~= '--', 'Missing value for ' .. flag)
            options[flag:sub(3):gsub('-', '_')] = arg[index]
        else error('Unknown option: ' .. flag) end
        index = index + 1
    end
    config_path = Fs.resolve(options.config or config_path)
    local launcher = 'luajit ' .. quote(Fs.resolve(arg[0]))
    local config_help = 'Configuration path: ' .. config_path
        .. '\nTo create the config and its directory automatically:\n  ' .. launcher
        .. ' --config ' .. quote(config_path) .. ' --dict-db none --save-config'
        .. '\nFor an existing unreadable or malformed file, check permissions and back it up before repairing it.'
        .. '\nMinimal JSON example:\n' .. json.encode({ data_dir = home:gsub('\\', '/') .. '/LeafWiki', dict_db = 'none' })
    startup.set_recovery(config_help)
    startup.report('Reading configuration: ' .. config_path)
    local raw = read(config_path)
    if not raw then
        local message = 'Configuration not found; using defaults: ' .. config_path
        if options.config and not options.save_config then startup.warn(message)
        else startup.report(message) end
        if not options.save_config then startup.show_help(config_help) end
    end
    local config = raw and json.decode(raw) or {}
    assert(type(config) == 'table', 'Configuration must be a JSON object')
    local data_dir = Fs.resolve(options.data_dir or getenv('LEAF_WIKI_DATA_DIR') or config.data_dir or home .. '/LeafWiki')
    cache = Fs.resolve(cache)
    local cache_dir = Fs.resolve(options.cache_dir or cache)
    local dictionary_path = options.dict_db or config.dict_db or root .. '/.dict.db'
    assert(type(dictionary_path) == 'string' and dictionary_path ~= '' and not dictionary_path:find('%z'),
        'Invalid dictionary path')
    if dictionary_path ~= 'none' then
        dictionary_path = Fs.resolve(dictionary_path)
        assert(dictionary_path:match('[^/]+$'), 'Dictionary path must name a file')
    end
    local port = tonumber(options.port)
    startup.set_recovery('Use --help to check command options:\n  ' .. launcher .. ' --help')
    startup.report('Validating startup options')
    assert(port and port >= 0 and port <= 65535 and port % 1 == 0, 'Invalid port')
    assert(options.host == '127.0.0.1' or options.host == '0.0.0.0', 'Host must be 127.0.0.1 or 0.0.0.0')
    local dictionary_help = 'Dictionary path: ' .. dictionary_path
        .. '\nA dictionary needs imported definitions; an empty SQLite file is not sufficient.'
        .. '\nFrom the repository root on Linux or WSL, create/import it with:\n  luajit download_dict.lua --db .dict.db'
        .. '\nRequires Git and internet access. Then use the imported file on Windows or Linux:\n  '
        .. launcher .. ' --dict-db ' .. quote(root:gsub('\\', '/') .. '/.dict.db')
        .. '\nTo use another imported file, pass its path to --dict-db. Back up invalid databases before replacing them.'
        .. '\nTo disable lookup:\n  ' .. launcher .. ' --dict-db none'
    if dictionary_path == 'none' then startup.report('Dictionary lookup disabled')
    else
        startup.set_recovery(dictionary_help)
        startup.report('Checking dictionary: ' .. dictionary_path)
        local available, err = dictionary.check(dictionary_path)
        if available then startup.report('Dictionary available: ' .. dictionary_path)
        else
            startup.warn('Dictionary unavailable: ' .. dictionary_path .. ' (' .. err
                .. '). Notebook editing remains available; configure --dict-db with an imported dictionary or use none.')
            startup.show_help(dictionary_help)
        end
    end
    local index_help = 'The SQLite search index is created automatically; no dictionary import is needed.'
        .. '\nChoose a fresh writable cache folder outside the notebook to rebuild it:\n  ' .. launcher
        .. ' --config ' .. quote(config_path) .. ' --data-dir ' .. quote(data_dir)
        .. ' --cache-dir ' .. quote(cache:gsub('\\', '/') .. '-recovery') .. ' --dict-db none'
        .. '\nCheck folder permissions and available disk space. Preserve the old cache when diagnosing corruption.'
        .. '\nYour Markdown pages, images, and .leaf history stay in the notebook; do not delete them.'
    local function progress(message)
        if message:find('SQLite', 1, true) or message:find('Preparing search cache', 1, true) then
            startup.set_recovery(index_help)
        elseif message == 'Acquiring notebook lock' then
            startup.set_recovery('Close the other Leaf Wiki server using this notebook (Ctrl-C), then retry. Do not delete its lock file.')
        elseif message:find('Opening notebook:', 1, true) then
            startup.set_recovery('Check the notebook folder path and permissions. --data-dir selects a folder and creates it when missing.')
        elseif message:find('Recovering', 1, true) or message:find('Indexing', 1, true) or message:find('Scanning', 1, true) then
            startup.set_recovery('Inspect the named Markdown file or recovery journal. Preserve your notebook files and correct the reported error before retrying.')
        end
        startup.report(message)
    end
    local notebook = Notebook.open(data_dir, cache_dir, progress)
    startup.track(notebook)
    if options.save_config then
        startup.set_recovery(config_help)
        startup.report('Saving configuration: ' .. config_path)
        local parent = config_path:match('^(.*)/[^/]+$') or '.'
        local fs = Fs.open(parent)
        local name = config_path:match('[^/]+$')
        local saved_path = fs.root .. '/' .. name
        local expected = { data_dir = notebook.fs.root, dict_db = dictionary_path }
        local saved, err = pcall(function()
            fs:write(name, json.encode(expected))
            startup.report('Verifying saved configuration: ' .. saved_path)
            local contents = assert(fs:read(name), 'Saved configuration file is missing')
            local actual = json.decode(contents)
            assert(type(actual) == 'table' and actual.data_dir == expected.data_dir
                and actual.dict_db == expected.dict_db, 'Saved configuration verification failed')
        end)
        fs:close()
        assert(saved, err)
        startup.report('Configuration saved and verified: ' .. saved_path)
    end
    local function reply(value, status) return json.encode(value), status or 200, 'application/json; charset=utf-8' end
    local function route(request, actual_port)
        local host = request.headers.host
        if not is_allowed_host(host, actual_port) then
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
            if path == '/api/dictionary' then
                local value, status = dictionary.lookup(dictionary_path, params.word)
                return reply(value, status)
            end
            if path == '/api/page' then
                local page = notebook:page(params.id)
                if not page then return reply({ error = 'Page not found.' }, 404) end
                page.backlinks = notebook:backlinks(page.id)
                return reply(page)
            end
            if path == '/api/history' or path == '/api/version' then
                local value, err, status
                if path == '/api/history' then value, err, status = notebook:versions(params.id)
                else value, err, status = notebook:version(params.id, params.revision) end
                return reply(value or { error = err }, status or 200)
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
            elseif path == '/api/history/restore' then
                value, err, status = notebook:restore_version(payload.id, payload.selected, payload.revision)
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
    startup.set_recovery('Close the process using this port, or choose a free port:\n  ' .. launcher .. ' --port 0')
    startup.report('Starting HTTP server on ' .. options.host .. ':' .. port)
    local ok, err = pcall(http.serve, port, handler, function(actual_port)
        startup.report('Server running')
        print('Leaf Wiki: http://127.0.0.1:' .. actual_port
            .. ' (listening on ' .. options.host .. ') | Notebook: ' .. notebook.fs.root)
        io.stdout:flush()
    end, options.host, nil, { body_limits = { ['/api/page'] = 7 * 1024 * 1024, ['/api/image'] = 5 * 1024 * 1024 } })
    notebook:close()
    if not ok then error(err) end
end
return M
