-- Markdown source files, recoverable maintenance operations and local SQLite index.
local ffi = require('ffi')
local Fs = require('fs')
local DB = require('db')
local links = require('links')
local net = require('net')
local json = require('json')
local Notebook = {}
Notebook.__index = Notebook
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS pages(id TEXT PRIMARY KEY, title TEXT NOT NULL,
    content TEXT NOT NULL, revision TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS links(source TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY(source,target));
CREATE INDEX IF NOT EXISTS links_target ON links(target);
]]

function Notebook.open(data_dir, cache_dir)
    local fs = Fs.open(data_dir)
    local lock_parent, lock_name = fs:parent('.leaf/lock', true)
    local lock = ffi.C.openat(lock_parent, lock_name, 2 + 64 + 131072 + 524288, ffi.new('int', 384))
    ffi.C.close(lock_parent)
    if lock < 0 or ffi.C.flock(lock, 2 + 4) ~= 0 then
        if lock >= 0 then ffi.C.close(lock) end
        fs:close(); error('Notebook is already open or its lock cannot be acquired')
    end
    local self = setmetatable({ fs = fs, lock = lock }, Notebook)
    local ok, err = pcall(function()
        local cache = Fs.absolute(cache_dir)
        assert(cache ~= fs.root and cache:sub(1, #fs.root + 1) ~= fs.root .. '/', 'Cache must be outside the notebook')
        local index_dir = Fs.absolute(cache .. '/' .. net.sha256(fs.root):sub(1, 24))
        self.index_path = index_dir .. '/index.db'
        self.db = DB.open(self.index_path, SCHEMA)
        self:recover()
        self:sync()
    end)
    if not ok then self:close(); error(err) end
    return self
end

local function require_id(id)
    assert(links.page_id(id), 'Invalid page name')
    return id
end

function Notebook:page(id)
    require_id(id)
    local text = self.fs:read(id .. '.md')
    if not text then return nil end
    assert(links.valid_utf8(text) and not text:find('%z'), 'Page must be UTF-8 text without NUL bytes')
    return { id = id, title = id:match('[^/]+$'), content = text, revision = net.sha256(text) }
end

function Notebook:sync()
    local seen = {}
    self.db:query('BEGIN;')
    local ok, err = pcall(function()
        for _, path in ipairs(self.fs:list()) do
            local id = path:sub(1, -4)
            if links.page_id(id) then
                local page = self:page(id)
                seen[id] = true
                local old = self.db:query('SELECT revision FROM pages WHERE id=?', { id })[1]
                if not old or old.revision ~= page.revision then
                    self.db:query([[INSERT INTO pages VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                        title=excluded.title,content=excluded.content,revision=excluded.revision]],
                        { id, page.title, page.content, page.revision })
                    self.db:query('DELETE FROM links WHERE source=?', { id })
                    for target in pairs(links.targets(id, page.content)) do
                        self.db:query('INSERT INTO links VALUES(?,?)', { id, target })
                    end
                end
            end
        end
        for _, row in ipairs(self.db:query('SELECT id FROM pages')) do
            if not seen[row.id] then
                self.db:query('DELETE FROM pages WHERE id=?', { row.id })
                self.db:query('DELETE FROM links WHERE source=?', { row.id })
            end
        end
        self.db:query('COMMIT;')
    end)
    if not ok then self.db:query('ROLLBACK;'); error(err) end
end

function Notebook:state(query)
    self:sync()
    local rows
    if query and query ~= '' then
        local escaped = query:gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_')
        rows = self.db:query([[SELECT id,title,revision,substr(content,1,160) AS snippet FROM pages
            WHERE id LIKE ? ESCAPE '\' OR content LIKE ? ESCAPE '\' ORDER BY id]],
            { '%' .. escaped .. '%', '%' .. escaped .. '%' })
    else rows = self.db:query('SELECT id,title,revision FROM pages ORDER BY id') end
    return { pages = rows, data_dir = self.fs.root, index_path = self.index_path, trash = self:trash_list() }
end

function Notebook:backlinks(id)
    require_id(id); self:sync()
    return self.db:query('SELECT source AS id FROM links WHERE target=? ORDER BY source', { id })
end

function Notebook:save(id, content, revision)
    require_id(id)
    assert(type(content) == 'string' and #content <= 1024 * 1024 and not content:find('%z')
        and links.valid_utf8(content), 'Page must be UTF-8 text up to 1 MiB')
    assert(type(revision) == 'string', 'Revision is required')
    local old = self:page(id)
    if (old and old.revision or '') ~= revision then
        return nil, 'This page changed outside this editor. Copy your draft before reloading.', 409
    end
    self.fs:write(id .. '.md', content)
    self:sync()
    return self:page(id)
end

function Notebook:image(id, bytes)
    require_id(id)
    assert(self:page(id), 'Save or create the page before attaching an image')
    assert(#bytes > 0 and #bytes <= 5 * 1024 * 1024, 'Images are limited to 5 MiB')
    local extension
    if bytes:sub(1, 8) == '\137PNG\r\n\26\n' then extension = 'png'
    elseif bytes:sub(1, 3) == '\255\216\255' then extension = 'jpg'
    elseif bytes:sub(1, 6) == 'GIF87a' or bytes:sub(1, 6) == 'GIF89a' then extension = 'gif'
    elseif bytes:sub(1, 4) == 'RIFF' and bytes:sub(9, 12) == 'WEBP' then extension = 'webp' end
    assert(extension, 'Use a PNG, JPEG, GIF or WebP image')
    local name = net.sha256(bytes):sub(1, 24) .. '.' .. extension
    self.fs:write(id .. '.attachments/' .. name, bytes)
    return { file = name, markdown = '![' .. 'Image' .. '](' .. id:match('[^/]+$') .. '.attachments/' .. name .. ')' }
end

function Notebook:attachment(id, name)
    require_id(id)
    assert(type(name) == 'string' and name:match('^[%w_-]+%.[%a]+$'), 'Invalid attachment name')
    local extension = name:match('%.(%a+)$')
    local mime = ({ png = 'image/png', jpg = 'image/jpeg', gif = 'image/gif', webp = 'image/webp' })[extension]
    assert(mime, 'Invalid attachment type')
    return self.fs:read(id .. '.attachments/' .. name, 5 * 1024 * 1024), mime
end

-- Journal before changing multiple files. Startup rolls interrupted operations back.
function Notebook:recover()
    local raw = self.fs:read('.leaf/transaction.json', 32 * 1024 * 1024)
    if not raw then return end
    local transaction = json.decode(raw)
    for _, operation in ipairs(transaction.files) do
        assert(links.page_id(operation.id), 'Invalid recovery journal')
        local current = self.fs:read(operation.id .. '.md') or false
        assert(current == operation.before or current == operation.after,
            'Recovery stopped: a transaction page was edited externally. Preserve the files and recovery journal.')
    end
    for _, operation in ipairs(transaction.files) do
        assert(links.page_id(operation.id), 'Invalid recovery journal')
        if operation.before ~= false then self.fs:write(operation.id .. '.md', operation.before)
        elseif self.fs:read(operation.id .. '.md') then self.fs:remove(operation.id .. '.md') end
    end
    if transaction.moved then
        local moved = transaction.moved
        if self.fs:directory_exists(moved.to) then
            assert(not self.fs:directory_exists(moved.from), 'Attachment recovery destination is occupied')
            self.fs:move(moved.to, moved.from)
        end
    end
    if transaction.trash_before then
        self.fs:write('.leaf/trash.json', transaction.trash_before)
        if transaction.trash_file and self.fs:read('.leaf/trash/' .. transaction.trash_file .. '.md') then
            self.fs:remove('.leaf/trash/' .. transaction.trash_file .. '.md')
        end
    end
    self.fs:remove('.leaf/transaction.json')
end

function Notebook:rename(id, destination, revision)
    require_id(id); require_id(destination)
    local page = self:page(id)
    assert(page, 'Page not found')
    if page.revision ~= revision then return nil, 'Page changed. Reload before renaming.', 409 end
    if self:page(destination) then return nil, 'A page already exists at the destination.', 409 end
    assert(not self.fs:directory_exists(destination .. '.attachments'), 'Destination attachment directory already exists')
    local files = {
        { id = destination, before = false, after = page.content },
        { id = id, before = page.content, after = false },
    }
    for _, path in ipairs(self.fs:list()) do
        local source = path:sub(1, -4)
        local before = self:page(source).content
        local after = links.rename(before, source, id, destination)
        if source == id then
            local old_name, new_name = id:match('[^/]+$'), destination:match('[^/]+$')
            after = links.prose(after, function(piece)
                return (piece:gsub('(!%[[^%]]*%]%()([^%)]+)(%))', function(first, target, last)
                    if target:sub(1, #old_name + 13) == old_name .. '.attachments/' then
                        target = new_name .. '.attachments/' .. target:sub(#old_name + 14)
                    end
                    return first .. target .. last
                end))
            end)
            files[1].after = after
        elseif after ~= before then files[#files + 1] = { id = source, before = before, after = after } end
    end
    local transaction = { files = files }
    local encoded = json.encode(transaction)
    assert(#encoded <= 32 * 1024 * 1024, 'Rename affects too much content; rename fewer linked pages first')
    self.fs:write('.leaf/transaction.json', encoded)
    local ok, err = pcall(function()
        for _, operation in ipairs(files) do
            if operation.after == false then self.fs:remove(operation.id .. '.md')
            else self.fs:write(operation.id .. '.md', operation.after) end
        end
        -- No attachments is common; move only if the directory exists.
        if self.fs:directory_exists(id .. '.attachments') then
            transaction.moved = { from = id .. '.attachments', to = destination .. '.attachments' }
            self.fs:write('.leaf/transaction.json', json.encode(transaction))
            self.fs:move(transaction.moved.from, transaction.moved.to)
        end
        self.fs:remove('.leaf/transaction.json')
    end)
    if not ok then self:recover(); error(err) end
    self:sync()
    return self:page(destination)
end

function Notebook:trash_list()
    local raw = self.fs:read('.leaf/trash.json', 1024 * 1024)
    return raw and json.decode(raw) or {}
end

function Notebook:trash(id, revision)
    require_id(id)
    local page = self:page(id)
    assert(page, 'Page not found')
    if page.revision ~= revision then return nil, 'Page changed. Reload before deleting.', 409 end
    local entries = self:trash_list()
    local token = net.sha256(id .. page.revision .. os.time() .. #entries):sub(1, 24)
    local transaction = { files = { { id = id, before = page.content, after = false } },
        trash_before = json.encode(entries), trash_file = token }
    if self.fs:directory_exists(id .. '.attachments') then
        transaction.moved = { from = id .. '.attachments', to = '.leaf/trash/' .. token .. '.attachments' }
    end
    self.fs:write('.leaf/transaction.json', json.encode(transaction))
    local ok, err = pcall(function()
        self.fs:write('.leaf/trash/' .. token .. '.md', page.content)
        if transaction.moved then self.fs:move(transaction.moved.from, transaction.moved.to) end
        entries[#entries + 1] = { token = token, id = id, deleted_at = os.time(), attachments = transaction.moved ~= nil }
        self.fs:write('.leaf/trash.json', json.encode(entries))
        self.fs:remove(id .. '.md')
        self.fs:remove('.leaf/transaction.json')
    end)
    if not ok then self:recover(); error(err) end
    self:sync()
    return { deleted = true }
end

function Notebook:restore(token)
    local entries = self:trash_list()
    for index, entry in ipairs(entries) do
        if entry.token == token then
            require_id(entry.id)
            if self:page(entry.id) then return nil, 'A page already exists. Rename it before restoring.', 409 end
            assert(token:match('^%x+$'), 'Invalid trash token')
            local text = assert(self.fs:read('.leaf/trash/' .. token .. '.md'), 'Trashed page is missing')
            local transaction = { files = { { id = entry.id, before = false, after = text } },
                trash_before = json.encode(entries) }
            if entry.attachments then
                assert(not self.fs:directory_exists(entry.id .. '.attachments'),
                    'Restore attachment destination is occupied')
                assert(self.fs:directory_exists('.leaf/trash/' .. token .. '.attachments'),
                    'Trashed attachments are missing')
                transaction.moved = { from = '.leaf/trash/' .. token .. '.attachments', to = entry.id .. '.attachments' }
            end
            self.fs:write('.leaf/transaction.json', json.encode(transaction))
            local ok, err = pcall(function()
                if transaction.moved then self.fs:move(transaction.moved.from, transaction.moved.to) end
                self.fs:write(entry.id .. '.md', text)
                table.remove(entries, index)
                self.fs:write('.leaf/trash.json', json.encode(entries))
                self.fs:remove('.leaf/transaction.json')
            end)
            if not ok then self:recover(); error(err) end
            self.fs:remove('.leaf/trash/' .. token .. '.md')
            self:sync()
            return self:page(entry.id)
        end
    end
    return nil, 'Trashed page not found.', 404
end

function Notebook:close()
    if self.db then self.db:close(); self.db = nil end
    if self.lock then ffi.C.close(self.lock); self.lock = nil end
    if self.fs then self.fs:close() end
end
return Notebook
