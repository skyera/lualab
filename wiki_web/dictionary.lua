-- Read-only access to ffi_dict's imported SQLite dictionary, without TUI/network modules.
local DB = require('db')
local links = require('links')
local M = {}

function M.lookup(path, value)
    if type(value) ~= 'string' or not links.valid_utf8(value) or #value > 240
        or value:find('[%z\1-\31\127]') then
        return { error = 'Enter a word or short phrase up to 240 UTF-8 bytes.' }, 400
    end
    local word = value:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    if word == '' then return { error = 'Enter a word to look up.' }, 400 end
    if not path or path == 'none' then
        return { error = 'Local dictionary is disabled. Configure --dict-db with an imported dictionary.' }, 503
    end
    local opened, db = pcall(DB.open, path, nil, true)
    if not opened then
        return { error = 'Local dictionary is unavailable. Configure --dict-db with an existing imported dictionary.' }, 503
    end
    local ok, rows = pcall(db.query, db, [[
        SELECT word, pos, definition, example, syn, ant FROM dict
        WHERE lower(word) = lower(?) ORDER BY id LIMIT 12
    ]], { word })
    db:close()
    if not ok then
        return { error = 'Cannot read this dictionary. Use a database imported with ffi_dict or download_dict.' }, 503
    end
    local senses = {}
    for _, row in ipairs(rows) do
        if row.definition and row.definition:find('%S') then senses[#senses + 1] = row end
    end
    return { word = word, source = 'local', senses = senses,
        message = #senses == 0 and 'No definition found in the local dictionary.' or nil }, 200
end
return M
