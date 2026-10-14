--------------------------------------------------------------------------------
-- learning.lua
-- Word organization and bounded review sessions across web and shared TUI decks.
--------------------------------------------------------------------------------

local json = require('json')
local M = {}

--------------------------------------------------------------------------------
-- Organization Validation & Persistence
--------------------------------------------------------------------------------

local function label(value)
    if type(value) ~= 'string' or value:find('[%z\1-\31\127]') then
        return nil
    end
    value = value:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    local count, bytes = 0, 0
    for char in value:gmatch('[\1-\127\194-\244][\128-\191]*') do
        local first, second = char:byte(1, 2)
        local expected = first < 128 and 1 or first < 224 and 2 or first < 240 and 3 or 4
        if #char ~= expected or (first == 224 and second < 160) or (first == 237 and second >= 160)
            or (first == 240 and second < 144) or (first == 244 and second >= 144) then
            return nil
        end
        count, bytes = count + 1, bytes + #char
    end
    if count > 64 or bytes ~= #value then
        return nil
    end
    return value
end

function M.validate(folder, tags)
    folder = label(folder)
    if not folder then
        return nil, 'Use a collection name of at most 64 characters.'
    end
    if type(tags) ~= 'table' or #tags > 8 then
        return nil, 'Use at most eight tags.'
    end
    local count = 0
    for key in pairs(tags) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 or key > #tags then
            return nil, 'Tags must be a list.'
        end
        count = count + 1
    end
    if count ~= #tags then
        return nil, 'Tags must be a list.'
    end
    local clean, seen = {}, {}
    for _, value in ipairs(tags) do
        local tag = label(value)
        if not tag or tag == '' or tag:find(',', 1, true) then
            return nil, 'Use nonempty tags of at most 64 characters, without commas.'
        end
        if not seen[tag:lower()] then
            seen[tag:lower()] = true
            clean[#clean + 1] = tag
        end
    end
    return { folder = folder, tags = clean }
end

function M.decorate(store, rows)
    local metadata = {}
    for _, row in ipairs(store.web:query('SELECT * FROM word_organization')) do
        metadata[row.word] = { folder = row.folder, tags = json.decode(row.tags) }
    end
    for _, row in ipairs(rows) do
        local saved = metadata[row.word:lower()]
        row.folder = saved and saved.folder or ''
        row.tags = saved and saved.tags or {}
    end
    return rows
end

function M.organize(store, id, collection, folder, tags)
    local data, err = M.validate(folder, tags)
    if not data then
        return nil, err, 400
    end
    local row
    if collection == 'tui' and store.shared then
        local rows, failure = store.shared:query('SELECT word FROM words WHERE id=?', { id })
        assert(rows, failure)
        row = rows[1]
    elseif collection == 'web' then
        row = store.web:query('SELECT word FROM words WHERE id=?', { id })[1]
    end
    if not row then
        return nil, 'Word not found.', 404
    end
    store.web:query([[INSERT INTO word_organization(word,folder,tags) VALUES(?,?,?)
        ON CONFLICT(word) DO UPDATE SET folder=excluded.folder,tags=excluded.tags]],
        { row.word:lower(), data.folder, json.encode(data.tags) })
    return { saved = true, folder = data.folder, tags = data.tags }
end

--------------------------------------------------------------------------------
-- Review Selection (Spaced Repetition Sessions)
--------------------------------------------------------------------------------

function M.session(store, params, stamp)
    params = params or {}
    stamp = stamp or os.time()
    local mode = params.mode or 'due'
    if mode ~= 'due' and mode ~= 'new' and mode ~= 'overdue' and mode ~= 'all' then
        return nil, 'Select a valid review mode.'
    end
    local limit = tonumber(params.limit or '20')
    if not limit or limit < 1 or limit > 200 or limit % 1 ~= 0 then
        return nil, 'Choose between 1 and 200 cards.'
    end
    local folder, tag = params.folder or '', params.tag or ''
    folder, tag = label(folder), label(tag)
    if not folder or not tag then
        return nil, 'Invalid collection or tag filter.'
    end
    local matches = {}
    for _, row in ipairs(store:words()) do
        local due = (row.due_at or 0) <= stamp
        local reviewed = (row.review_count or 0) > 0
        local keep = mode == 'all' or (mode == 'due' and due)
            or (mode == 'new' and not reviewed) or (mode == 'overdue' and due and reviewed)
        if folder ~= '' and row.folder:lower() ~= folder:lower() then
            keep = false
        end
        if tag ~= '' then
            local found = false
            for _, value in ipairs(row.tags) do
                if value:lower() == tag:lower() then
                    found = true
                end
            end
            if not found then
                keep = false
            end
        end
        if keep then
            matches[#matches + 1] = row
        end
    end
    table.sort(matches, function(a, b)
        if a.due_at ~= b.due_at then
            return a.due_at < b.due_at
        end
        if a.word ~= b.word then
            return a.word < b.word
        end
        if a.collection ~= b.collection then
            return a.collection < b.collection
        end
        return a.id < b.id
    end)
    local total = #matches
    while #matches > limit do
        table.remove(matches)
    end
    return {
        words = matches,
        total_matching = total,
        mode = mode,
        limit = limit,
    }
end

return M
