-- Durable Markdown snapshots inside the notebook; content-addressed blobs and
-- atomic per-page manifests. History writes must finish before live pages change.
local hash = require('hash')
local links = require('links')
local json = require('json')
local History = {}
History.__index = History
local MAX_MANIFEST = 32 * 1024 * 1024

local function manifest_path(id)
    assert(links.page_id(id), 'Invalid page name')
    return '.leaf/history/pages/' .. hash.sha256(id) .. '.json'
end

local function valid_revision(value)
    return type(value) == 'string' and #value == 64 and value:match('^[a-f0-9]+$')
end

function History.open(fs) return setmetatable({ fs = fs }, History) end

function History:list(id)
    local raw = self.fs:read(manifest_path(id), MAX_MANIFEST)
    if not raw then return {} end
    local entries = json.decode(raw)
    assert(type(entries) == 'table', 'Invalid page history')
    for key in pairs(entries) do
        assert(type(key) == 'number' and key >= 1 and key <= #entries and key % 1 == 0, 'Invalid page history')
    end
    local seen = {}
    for _, entry in ipairs(entries) do
        assert(type(entry) == 'table' and valid_revision(entry.revision) and links.page_id(entry.source)
            and type(entry.saved_at) == 'number' and entry.saved_at >= 0
            and type(entry.bytes) == 'number' and entry.bytes >= 0 and entry.bytes <= 1024 * 1024,
            'Invalid page history')
        assert(not seen[entry.revision], 'Duplicate history revision')
        seen[entry.revision] = true
    end
    return entries
end

function History:write_manifest(id, entries)
    local encoded = json.encode(entries)
    assert(#encoded <= MAX_MANIFEST, 'Page history is too large; back it up before continuing')
    self.fs:write(manifest_path(id), encoded)
end

function History:remember(page)
    local entries = self:list(page.id)
    local blob = '.leaf/history/blobs/' .. page.revision .. '.md'
    if self.fs:read(blob) ~= page.content then self.fs:write(blob, page.content) end
    for index, entry in ipairs(entries) do
        if entry.revision == page.revision then table.remove(entries, index); break end
    end
    table.insert(entries, 1, { revision = page.revision, source = page.id, saved_at = os.time(), bytes = #page.content })
    self:write_manifest(page.id, entries)
end

function History:inherit(source, destination)
    local entries, seen = self:list(source), {}
    for _, entry in ipairs(entries) do seen[entry.revision] = true end
    for _, entry in ipairs(self:list(destination)) do
        if not seen[entry.revision] then entries[#entries + 1] = entry; seen[entry.revision] = true end
    end
    if #entries > 0 then self:write_manifest(destination, entries) end
end

function History:version(id, revision)
    assert(valid_revision(revision), 'Invalid history revision')
    for _, entry in ipairs(self:list(id)) do
        if entry.revision == revision then
            local text = assert(self.fs:read('.leaf/history/blobs/' .. revision .. '.md'), 'History snapshot is missing')
            assert(hash.sha256(text) == revision and links.valid_utf8(text) and not text:find('%z'),
                'History snapshot is damaged; preserve it for recovery')
            return { content = text, revision = revision, source = entry.source, saved_at = entry.saved_at }
        end
    end
    return nil
end
return History
