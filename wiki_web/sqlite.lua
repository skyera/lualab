-- Concrete SQLite library selection, adapted from CodeFind's explicit pin,
-- Windows candidate discovery and validation. Never load a DLL just to list it.
local ffi = require('ffi')
local Fs = require('fs')
local windows_args = require('windows_args')
local DB = require('db') -- declares every probed symbol, without loading a library
local M = {}
local WINDOWS = ffi.os == 'Windows'
local FILE_NAMES = { 'sqlite3.dll', 'sqlite3-3.dll', 'libsqlite3.dll' }
local REQUIRED = {
    'sqlite3_open', 'sqlite3_open_v2', 'sqlite3_close', 'sqlite3_errmsg', 'sqlite3_libversion',
    'sqlite3_busy_timeout', 'sqlite3_prepare_v2', 'sqlite3_step', 'sqlite3_finalize',
    'sqlite3_bind_text', 'sqlite3_bind_double', 'sqlite3_bind_null', 'sqlite3_column_count',
    'sqlite3_column_type', 'sqlite3_column_name', 'sqlite3_column_text', 'sqlite3_column_double',
    'sqlite3_column_bytes', 'sqlite3_exec', 'sqlite3_free',
}

local function word(text, offset)
    local a, b = text:byte(offset, offset + 1)
    return a and b and a + b * 256 or nil
end

function M.inspect(path)
    local ok, text = pcall(Fs.read_file, path)
    if not ok or not text then return nil, 'File is missing or unreadable' end
    if text:sub(1, 2) ~= 'MZ' or #text < 64 then return nil, 'Not a Windows PE library' end
    local low, high = word(text, 61), word(text, 63)
    local offset = low + high * 65536
    if text:sub(offset + 1, offset + 4) ~= 'PE\0\0' then return nil, 'Invalid PE header' end
    local machine = word(text, offset + 5)
    local expected = ({ x64 = 0x8664, x86 = 0x14c, arm64 = 0xaa64 })[ffi.arch]
    if machine ~= expected then return nil, 'Architecture does not match LuaJIT ' .. ffi.arch end
    return true
end

function M.discover(root, script_dir, file_names)
    if not WINDOWS then return { { path = 'sqlite3', source = 'loader' }, { path = 'libsqlite3.so.0', source = 'loader' } } end
    ffi.cdef[[unsigned long __stdcall GetModuleFileNameW(void *, uint16_t *, unsigned long);
    int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const uint16_t *, int,
        char *, int, const char *, int *);]]
    local kernel = ffi.load('kernel32')
    local buffer = ffi.new('uint16_t[32768]')
    local length = kernel.GetModuleFileNameW(nil, buffer, 32768)
    assert(length > 0 and length < 32768, 'Cannot find LuaJIT executable directory')
    local size = kernel.WideCharToMultiByte(65001, 0, buffer, length, nil, 0, nil, nil)
    local bytes = ffi.new('char[?]', size)
    kernel.WideCharToMultiByte(65001, 0, buffer, length, bytes, size, nil, nil)
    local executable = ffi.string(bytes, size):gsub('\\', '/')
    local dirs = { { path = root, source = 'repository' }, { path = script_dir or root .. '/wiki_web', source = 'script' },
        { path = executable:match('^(.*)/'), source = 'LuaJIT directory' }, { path = '.', source = 'current directory' } }
    local system_root = windows_args.getenv('SystemRoot')
    if system_root then dirs[#dirs + 1] = { path = system_root .. '/System32', source = 'Windows system directory' } end
    for dir in (windows_args.getenv('PATH') or ''):gmatch('[^;]+') do
        dir = dir:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^"(.*)"$', '%1')
        if dir ~= '' then dirs[#dirs + 1] = { path = dir, source = 'PATH' } end
    end
    local candidates, seen = {}, {}
    for _, dir in ipairs(dirs) do
        local resolved, folder = pcall(Fs.resolve, dir.path)
        if resolved then
            for _, name in ipairs(file_names or FILE_NAMES) do
                local path = folder:gsub('/$', '') .. '/' .. name
                local key = path:lower()
                if not seen[key] then
                    seen[key] = true
                    local readable, text = pcall(Fs.read_file, path)
                    if readable and text then
                        local compatible, reason = M.inspect(path)
                        candidates[#candidates + 1] = { path = path, source = dir.source,
                            compatible = not not compatible, reason = reason }
                    end
                end
            end
        end
    end
    return candidates
end

function M.open_library(path)
    local load_path = path
    if WINDOWS and path:find('[\128-\255]') then
        ffi.cdef[[unsigned long __stdcall GetShortPathNameW(const uint16_t *, uint16_t *, unsigned long);]]
        local kernel = ffi.load('kernel32')
        local count = kernel.MultiByteToWideChar(65001, 8, path, #path, nil, 0)
        local wide = ffi.new('uint16_t[?]', count + 1)
        assert(kernel.MultiByteToWideChar(65001, 8, path, #path, wide, count) == count, 'Invalid DLL path')
        local short = ffi.new('uint16_t[32768]')
        local length = kernel.GetShortPathNameW(wide, short, 32768)
        if length > 0 and length < 32768 then
            local size = kernel.WideCharToMultiByte(0, 0, short, length, nil, 0, nil, nil)
            local bytes = ffi.new('char[?]', size)
            kernel.WideCharToMultiByte(0, 0, short, length, bytes, size, nil, nil)
            load_path = ffi.string(bytes, size)
        end
    end
    local loaded, library = pcall(ffi.load, load_path)
    assert(loaded, 'Cannot load native library ' .. path .. ': ' .. tostring(library))
    return library
end

function M.validate(path, report, require_fts5)
    if WINDOWS then
        local compatible, reason = M.inspect(path)
        assert(compatible, path .. ': ' .. tostring(reason))
    end
    if report then report('Validating SQLite library: ' .. path) end
    local library = M.open_library(path)
    for _, symbol in ipairs(REQUIRED) do
        assert(pcall(function() return library[symbol] end), 'SQLite library is missing ' .. symbol .. ': ' .. path)
    end
    local version = ffi.string(library.sqlite3_libversion())
    local db = ffi.new('sqlite3 *[1]')
    local status = library.sqlite3_open(':memory:', db)
    if status ~= 0 then
        if db[0] ~= nil then library.sqlite3_close(db[0]) end
        error('SQLite cannot open an in-memory database: ' .. path)
    end
    local err = ffi.new('char *[1]')
    local probe_sql = [[CREATE TABLE probe(value TEXT PRIMARY KEY);
        INSERT INTO probe VALUES('test');
        INSERT INTO probe VALUES('test') ON CONFLICT(value) DO UPDATE SET value=excluded.value;]]
    if require_fts5 then
        for _, symbol in ipairs({ 'sqlite3_reset', 'sqlite3_bind_int', 'sqlite3_bind_int64',
            'sqlite3_column_int', 'sqlite3_column_int64', 'sqlite3_last_insert_rowid' }) do
            if not pcall(function() return library[symbol] end) then
                library.sqlite3_close(db[0])
                error('SQLite library is missing ' .. symbol .. ': ' .. path)
            end
        end
        probe_sql = probe_sql .. [[CREATE VIRTUAL TABLE search_probe USING fts5(value);
            INSERT INTO search_probe VALUES('test');
            SELECT value FROM search_probe WHERE search_probe MATCH 'test';]]
    end
    status = library.sqlite3_exec(db[0], probe_sql, nil, nil, err)
    local message = err[0] ~= nil and ffi.string(err[0]) or (require_fts5 and 'SQLite FTS5/UPSERT validation failed' or 'SQLite UPSERT validation failed')
    if err[0] ~= nil then library.sqlite3_free(err[0]) end
    library.sqlite3_close(db[0])
    assert(status == 0, path .. ': ' .. message)
    return library, { path = path, version = version, library = library }
end

function M.load(root, options, config, report, warn)
    local environment = windows_args.getenv(options.sqlite_env or 'LEAF_WIKI_SQLITE3')
    if environment == '' then environment = nil end
    local override = options.sqlite_dll or (not options.sqlite_select and (environment or config.sqlite_dll))
    if override then
        local path = not WINDOWS and not override:find('/', 1, true) and override or Fs.resolve(override)
        local library, info = M.validate(path, report, options.require_fts5)
        DB.set_library(library); info.pin = path
        return info
    end
    local candidates = M.discover(root, options.script_dir)
    if options.sqlite_select or (WINDOWS and #candidates > 1) then
        local interactive = options.sqlite_select
        if WINDOWS then
            ffi.cdef[[void * __stdcall GetStdHandle(unsigned long);
        int __stdcall GetConsoleMode(void *, unsigned long *);]]
            local kernel, mode = ffi.load('kernel32'), ffi.new('unsigned long[1]')
            interactive = interactive or kernel.GetConsoleMode(kernel.GetStdHandle(0xfffffff6), mode) ~= 0
        end
        if #candidates > 0 and interactive then
            for index, candidate in ipairs(candidates) do
                print(index .. '. ' .. candidate.path .. ' [' .. candidate.source .. ']'
                    .. (candidate.reason and ' - ' .. candidate.reason or ''))
            end
            io.write('Select SQLite library [1-' .. #candidates .. '] (default 1): '); io.stdout:flush()
            local choice = io.read('*l')
            local selected = choice == '' and 1 or tonumber(choice)
            assert(selected and selected % 1 == 0 and candidates[selected], 'Invalid SQLite selection')
            local library, info = M.validate(candidates[selected].path, report, options.require_fts5)
            DB.set_library(library); info.pin = info.path
            return info
        end
    end
    for _, candidate in ipairs(candidates) do
        local ok, library, info = pcall(M.validate, candidate.path, report, options.require_fts5)
        if ok then DB.set_library(library); info.pin = WINDOWS and info.path or nil; return info end
        if warn and WINDOWS then warn(tostring(library)) end
    end
    error('No usable SQLite library found. Use --sqlite-list, --sqlite-select, or --sqlite-dll PATH.')
end
return M
