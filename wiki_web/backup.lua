-- Portable, checksummed notebook bundles and verified restore into a fresh sibling.
local Fs = require('fs')
local json = require('json')
local hash = require('hash')
local links = require('links')
local M = {}
local MAX_BYTES = 32 * 1024 * 1024
local MAX_BUNDLE = 63 * 1024 * 1024
local MARKER = '.leaf/restore-incomplete.json'
local EXCLUDED = { ['.leaf/lock'] = true, ['.leaf/transaction.json'] = true, [MARKER] = true }

-- ============================================================================
-- Portable paths and archive validation
-- ============================================================================

local function valid_path(path)
    if type(path) ~= 'string' or #path > 1024 or path == '' or path:sub(1, 1) == '/'
        or path:sub(-1) == '/' or path:find('//', 1, true) or not links.valid_utf8(path)
        or path:find('[%z\1-\31\127\\:<>"|?*]') then return false end
    local depth = 0
    for part in path:gmatch('[^/]+') do
        depth = depth + 1
        local stem = part:match('^([^.]*)'):upper()
        if part == '.' or part == '..' or part:match('[ .]$') or part:match('^%s')
            or stem == 'CON' or stem == 'PRN' or stem == 'AUX' or stem == 'NUL'
            or stem:match('^COM[1-9]$') or stem:match('^LPT[1-9]$') then return false end
    end
    return depth <= 32 and not EXCLUDED[path] and not path:find('%.leaf%-write%-')
end

function M.validate(bundle)
    assert(type(bundle) == 'table' and bundle.format == 'leaf-wiki-backup' and bundle.version == 1,
        'Select a Leaf Wiki version 1 JSON backup')
    assert(type(bundle.files) == 'table' and #bundle.files <= 10000, 'Invalid backup file list')
    for key in pairs(bundle.files) do
        assert(type(key) == 'number' and key >= 1 and key <= #bundle.files and key % 1 == 0,
            'Backup files must be an array')
    end
    local files, seen, size = {}, {}, 0
    for _, entry in ipairs(bundle.files) do
        assert(type(entry) == 'table' and valid_path(entry.path), 'Invalid or unsafe backup path')
        local key = entry.path:lower()
        assert(not seen[key], 'Duplicate backup path: ' .. entry.path)
        seen[key] = true
        assert(type(entry.data) == 'string' and type(entry.sha256) == 'string'
            and #entry.sha256 == 64 and entry.sha256:match('^[a-f0-9]+$'),
            'Invalid backup contents: ' .. entry.path)
        local data
        if entry.encoding == 'utf8' then
            assert(links.valid_utf8(entry.data) and not entry.data:find('%z'), 'Invalid UTF-8: ' .. entry.path)
            data = entry.data
        else
            assert(entry.encoding == 'hex' and #entry.data % 2 == 0 and not entry.data:find('[^a-f0-9]')
                and #entry.data <= MAX_BYTES * 2, 'Invalid binary encoding: ' .. entry.path)
            data = entry.data:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)
        end
        size = size + #data
        assert(size <= MAX_BYTES, 'Backup contents exceed 32 MiB')
        assert(entry.bytes == #data and hash.sha256(data) == entry.sha256,
            'Backup checksum or size mismatch: ' .. entry.path)
        files[#files + 1] = { path = entry.path, data = data, sha256 = entry.sha256 }
    end
    for key in pairs(seen) do
        local parent = key:match('^(.*)/[^/]+$')
        while parent do
            assert(not seen[parent], 'Backup file/directory collision: ' .. key)
            parent = parent:match('^(.*)/[^/]+$')
        end
    end
    return files, size
end

-- ============================================================================
-- Snapshot construction and verified fresh-folder restore
-- ============================================================================

function M.export(notebook, progress)
    progress = progress or function() end
    assert(not notebook.fs:read('.leaf/transaction.json'), 'Finish notebook recovery before backing up')
    assert(not notebook.fs:read(MARKER), 'Cannot back up an incomplete restore')
    progress('Scanning notebook for backup: ' .. notebook.fs.root)
    local files, size = {}, 0
    local paths = notebook.fs:list('', 0, 'backup')
    for _, path in ipairs(paths) do
        if not EXCLUDED[path] and not path:find('%.leaf%-write%-') then
            assert(valid_path(path), 'Cannot back up non-portable path: ' .. path)
            progress('Backing up ' .. path)
            local data = assert(notebook.fs:read(path, MAX_BYTES), 'Backup file disappeared: ' .. path)
            size = size + #data
            assert(size <= MAX_BYTES, 'Notebook backup exceeds 32 MiB; copy the notebook folder directly')
            local text = links.valid_utf8(data) and not data:find('%z')
            files[#files + 1] = { path = path, bytes = #data, sha256 = hash.sha256(data),
                encoding = text and 'utf8' or 'hex', data = text and data or data:gsub('.', function(char)
                    return string.format('%02x', char:byte())
                end) }
        end
    end
    -- Detect visible external edits across the snapshot window instead of shipping partial data.
    for _, entry in ipairs(files) do
        assert(hash.sha256(assert(notebook.fs:read(entry.path, MAX_BYTES),
            'Backup file disappeared: ' .. entry.path)) == entry.sha256,
            'File changed during backup: ' .. entry.path .. '; retry with external writers paused')
    end
    assert(json.encode(paths) == json.encode(notebook.fs:list('', 0, 'backup')),
        'Notebook file list changed during backup; retry with external writers paused')
    local encoded = json.encode({ format = 'leaf-wiki-backup', version = 1, files = files })
    assert(#encoded <= MAX_BUNDLE, 'Encoded backup exceeds 63 MiB; copy the notebook folder directly')
    progress('Backup verified: ' .. #files .. ' files')
    return encoded
end

function M.restore(notebook, bundle, name, progress)
    progress = progress or function() end
    local files, size = M.validate(bundle)
    assert(valid_path(name) and #name <= 120 and not name:find('/', 1, true) and name:sub(1, 1) ~= '.',
        'Use a new sibling folder name without path separators')
    local parent_path = assert(notebook.fs.root:match('^(.*)/[^/]+$'), 'Notebook root has no sibling folder')
    if parent_path == '' then parent_path = '/' end
    if parent_path:match('^%a:$') then parent_path = parent_path .. '/' end
    local destination = parent_path:gsub('/$', '') .. '/' .. name
    progress('Creating new restore folder: ' .. destination)
    local parent = Fs.open(parent_path)
    local created, err = pcall(parent.create_directory, parent, name)
    parent:close()
    assert(created, err)
    local target, unlock
    local ok, failure = pcall(function()
        target = Fs.open(destination)
        unlock = target:lock()
        local marker = json.encode({ files = #files, status = 'incomplete' })
        target:write(MARKER, marker)
        assert(target:read(MARKER) == marker, 'Cannot verify incomplete-restore marker')
        for index, entry in ipairs(files) do
            progress('Restoring ' .. index .. '/' .. #files .. ': ' .. entry.path)
            target:write(entry.path, entry.data)
            assert(hash.sha256(assert(target:read(entry.path, MAX_BYTES),
                'Restored file is missing: ' .. entry.path)) == entry.sha256,
                'Restored file verification failed: ' .. entry.path)
        end
        for _, entry in ipairs(files) do
            assert(hash.sha256(assert(target:read(entry.path, MAX_BYTES),
                'Restored file is missing: ' .. entry.path)) == entry.sha256,
                'Restored file changed before completion: ' .. entry.path)
        end
        target:remove(MARKER)
        assert(not target:read(MARKER), 'Incomplete-restore marker could not be removed')
    end)
    if unlock then unlock() end
    if target then target:close() end
    assert(ok, 'Restore failed at ' .. destination .. ': ' .. tostring(failure)
        .. '. Preserve the incomplete folder for inspection; retry with a different new folder name.')
    progress('Restore saved and verified: ' .. destination)
    return { path = destination, files = #files, bytes = size }
end

return M
