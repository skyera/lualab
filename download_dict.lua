#!/usr/bin/env luajit
-- Download Wordset and populate the shared dictionary without changing the deck.
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/') or '.'
package.path = root .. '/?.lua;' .. package.path
local dictionary = require('ffi_dict')
local M = {}
local repository = 'https://github.com/wordset/wordset-dictionary.git'
local names = {}
for code = string.byte('a'), string.byte('z') do names[#names + 1] = string.char(code) .. '.json' end
names[#names + 1] = 'misc.json'

function M.quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.run(argv)
    local parts = {}
    for _, value in ipairs(argv) do parts[#parts + 1] = M.quote(value) end
    local status = os.execute(table.concat(parts, ' '))
    if status ~= 0 then error(argv[1] .. ' failed (status ' .. tostring(status) .. ').') end
end

local function exists(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close(); return true
end

local function read_object(path)
    local file = assert(io.open(path, 'rb'), 'Missing dictionary file: ' .. path)
    local text = file:read('*a'); file:close()
    local ok, object = pcall(dictionary.JSON.decode, text)
    if not ok or type(object) ~= 'table' then error('Invalid dictionary JSON: ' .. path) end
    local words, senses = 0, 0
    for word, entry in pairs(object) do
        if type(word) ~= 'string' or type(entry) ~= 'table' then
            error('Invalid Wordset entry in ' .. path)
        end
        -- Wordset includes a few entries without meanings. Match the existing
        -- importer's behavior: skip those while validating real definitions.
        local meanings = entry.meanings or entry
        if type(meanings) ~= 'table' then error('Invalid meanings in ' .. path) end
        local count = 0
        for _, meaning in ipairs(meanings) do
            local definition = type(meaning) == 'string' and meaning or type(meaning) == 'table'
                and (meaning.def or meaning.definition or meaning.text) or nil
            if type(definition) == 'string' and #definition > 0 then count = count + 1 end
        end
        if count > 0 then words, senses = words + 1, senses + count end
    end
    if senses == 0 then error('Dictionary file contains no definitions: ' .. path) end
    return object, words, senses
end

local function counts(db)
    return {words = assert(db:scalar('SELECT count(DISTINCT lower(word)) FROM dict;')),
        senses = assert(db:scalar('SELECT count(*) FROM dict;'))}
end

function M.ensure(options)
    options = options or {}
    local path = options.db or root .. '/.dict.db'
    local cache = options.cache_dir or root .. '/downloads/wordset-dictionary'
    local run = options.run or M.run
    local report = options.report or function(message) print(message); io.stdout:flush() end
    if exists(path) and not options.force then
        local db = assert(dictionary.Database.open(path))
        local result = counts(db); db:close()
        if result.senses > 0 then
            result.skipped = true
            report(string.format('Offline dictionary already available: %d words / %d meanings.', result.words, result.senses))
            return result
        end
    end
    report('Downloading Wordset…')
    if exists(cache .. '/.git/config') then
        run({'git', '-C', cache, 'pull', '--ff-only', repository, 'master'})
    else
        run({'mkdir', '-p', cache:match('^(.*)/') or '.'})
        run({'git', 'clone', '--depth', '1', '--branch', 'master', '--', repository, cache})
    end
    report('Validating dictionary files…')
    local files, expected = options.files or names, {}
    for _, name in ipairs(files) do
        local _, words, senses = read_object(cache .. '/data/' .. name)
        expected[name] = {words = words, senses = senses}
    end
    if #files == 0 then error('No dictionary files selected.') end
    report('Importing definitions and rebuilding the search index…')
    local db = assert(dictionary.Database.open(path))
    local begun, begin_err = db:exec('BEGIN IMMEDIATE;')
    if not begun then db:close(); error(begin_err) end
    local ok, result = pcall(function()
        local total_words, total_senses = 0, 0
        for index, name in ipairs(files) do
            local object = read_object(cache .. '/data/' .. name)
            local words, senses = dictionary.Importer.ingest_wordset(db, object, true)
            if words ~= expected[name].words or senses ~= expected[name].senses then
                error('Incomplete import for ' .. name .. ': ' .. db:errmsg())
            end
            total_words, total_senses = total_words + words, total_senses + senses
            report(string.format('[%d/%d] %s: %d words / %d meanings', index, #files, name, words, senses))
        end
        assert(db:run('DELETE FROM dict_fts;'))
        assert(db:run([[INSERT INTO dict_fts(rowid,word,definition,example,syn)
            SELECT id,word,definition,example,syn FROM dict;]]))
        local result = counts(db)
        assert(db:scalar('SELECT count(*) FROM dict_fts;') == result.senses, 'Search index does not match dictionary')
        assert(db:run("INSERT OR REPLACE INTO meta(key,value) VALUES('last_import',?);",
            {string.format('wordset %d words / %d senses / %d files @ %s', total_words, total_senses, #files, os.date('!%Y-%m-%dT%H:%M:%SZ'))}))
        assert(db:commit())
        return result
    end)
    if not ok then db:rollback() end
    db:close()
    if not ok then error(result) end
    report(string.format('Ready: %d words / %d meanings. Saved vocabulary and reviews preserved.', result.words, result.senses))
    return result
end

function M.main(args)
    local options, index = {}, 1
    while index <= #args do
        local value = args[index]
        if value == '--help' then
            print('Usage: luajit download_dict.lua [--db PATH] [--cache-dir PATH] [--force]')
            print('Downloads and imports Wordset only when the dictionary is empty. --force refreshes it.')
            print('Requires git, LuaJIT and SQLite. Saved vocabulary, notes and review history are preserved.')
            return
        elseif value == '--force' then options.force = true
        elseif value == '--db' or value == '--cache-dir' then
            index = index + 1
            local path = assert(args[index], 'Missing path for ' .. value)
            options[value == '--db' and 'db' or 'cache_dir'] = path
        else error('Unknown argument: ' .. tostring(value)) end
        index = index + 1
    end
    return M.ensure(options)
end

if pcall(debug.getlocal, 4, 1) then return M end
local ok, err = pcall(M.main, arg)
if not ok then io.stderr:write('Dictionary setup failed: ' .. tostring(err) .. '\n'); os.exit(1) end
