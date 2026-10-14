--------------------------------------------------------------------------------
-- backup.lua
-- Versioned journal backups, validated restore, and spreadsheet-safe CSV export.
--------------------------------------------------------------------------------

local json = require('json')
local learning = require('learning')
local M = {}

--------------------------------------------------------------------------------
-- Explicit Table/Column Allowlist: Imported Dictionaries & Credentials Stay Out
--------------------------------------------------------------------------------

local WEB = {
    {
        name = 'words',
        columns = {
            { 'id', 'id' },
            { 'word', 'text' },
            { 'source', 'text' },
            { 'entry', 'optional' },
            { 'lookup_count', 'integer' },
            { 'first_seen', 'integer' },
            { 'last_seen', 'integer' },
            { 'fetched_at', 'optional_integer' },
            { 'note', 'text' },
            { 'review_count', 'integer' },
            { 'streak', 'integer' },
            { 'due_at', 'integer' },
        },
    },
    {
        name = 'proverbs',
        columns = {
            { 'id', 'id' },
            { 'date', 'text' },
            { 'text', 'text' },
            { 'chinese', 'text' },
            { 'explanation', 'text' },
            { 'audio_url', 'optional' },
            { 'created_at', 'integer' },
        },
    },
    {
        name = 'word_organization',
        columns = {
            { 'word', 'text' },
            { 'folder', 'text' },
            { 'tags', 'text' },
        },
    },
}

local WEB_V1 = { WEB[1], WEB[2], WEB[3] }

WEB[#WEB + 1] = {
    name = 'study_meanings',
    columns = {
        { 'word', 'text' },
        { 'meaning', 'text' },
    },
}

WEB[#WEB + 1] = {
    name = 'review_log',
    columns = {
        { 'id', 'id' },
        { 'word_id', 'id' },
        { 'rated_at', 'integer' },
        { 'grade', 'integer' },
    },
}

local WEB_V2 = { WEB[1], WEB[2], WEB[3], WEB[4], WEB[5] }

WEB[#WEB + 1] = {
    name = 'study_examples',
    columns = {
        { 'word', 'text' },
        { 'example', 'text' },
    },
}

local SHARED = {
    {
        name = 'words',
        columns = {
            { 'id', 'id' },
            { 'word', 'text' },
            { 'pos', 'optional' },
            { 'definition', 'optional' },
            { 'example', 'optional' },
            { 'mnem', 'optional' },
            { 'syn', 'optional' },
            { 'ant', 'optional' },
            { 'tags', 'optional' },
            { 'added_at', 'integer' },
        },
    },
    {
        name = 'srs',
        columns = {
            { 'word_id', 'id' },
            { 'ease', 'number' },
            { 'interval_days', 'number' },
            { 'due_at', 'integer' },
            { 'reps', 'integer' },
            { 'lapses', 'integer' },
        },
    },
    {
        name = 'reviews',
        columns = {
            { 'id', 'id' },
            { 'word_id', 'id' },
            { 'rated_at', 'integer' },
            { 'grade', 'integer' },
        },
    },
    {
        name = 'study_plan',
        columns = {
            { 'id', 'id' },
            { 'track', 'text' },
            { 'daily_new', 'integer' },
            { 'updated_at', 'integer' },
        },
    },
    {
        name = 'study_plan_words',
        columns = {
            { 'word_id', 'id' },
            { 'source_track', 'text' },
            { 'plan_date', 'text' },
        },
    },
}

--------------------------------------------------------------------------------
-- Database Attachment & Snapshot Helpers
--------------------------------------------------------------------------------

local function attach(store)
    if store.shared and not store.deletion_attached then
        store.web:query('ATTACH DATABASE ? AS shared_deletion', { store.shared.path })
        store.deletion_attached = true
    end
end

local function columns(spec)
    local names = {}
    for _, column in ipairs(spec.columns) do
        names[#names + 1] = column[1]
    end
    return table.concat(names, ',')
end

local function snapshot(db, schema, specs)
    local data = {}
    for _, spec in ipairs(specs) do
        data[spec.name] = db:query('SELECT ' .. columns(spec) .. ' FROM ' .. schema .. '.' .. spec.name
            .. ' ORDER BY ' .. spec.columns[1][1])
    end
    return data
end

function M.export(store)
    attach(store)
    store.web:query('BEGIN IMMEDIATE;')
    local ok, data = pcall(function()
        local result = {
            format = 'wordbook',
            version = 3,
            created_at = os.time(),
            web = snapshot(store.web, 'main', WEB),
        }
        if store.shared then
            result.shared = snapshot(store.web, 'shared_deletion', SHARED)
        end
        for _, row in ipairs(result.web.words) do
            if row.source == 'youdao' then
                row.entry = nil
                row.fetched_at = nil
            end
        end
        store.web:query('COMMIT;')
        return result
    end)
    if not ok then
        store.web:query('ROLLBACK;')
        error(data)
    end
    return data
end

--------------------------------------------------------------------------------
-- Backup Validation
--------------------------------------------------------------------------------

local function array(value)
    if type(value) ~= 'table' or #value > 100000 then
        return false
    end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key > #value or key % 1 ~= 0 then
            return false
        end
        count = count + 1
    end
    return count == #value
end

local function valid_number(value, kind)
    return type(value) == 'number' and value == value and value >= (kind == 'id' and 1 or 0)
        and value <= 9007199254740991 and (kind == 'number' or value % 1 == 0)
end

local function valid_entry(raw)
    local ok, entry = pcall(json.decode, raw)
    if not ok or type(entry) ~= 'table' or not array(entry.definitions) then
        return false
    end
    for _, text in ipairs(entry.definitions) do
        if type(text) ~= 'string' then
            return false
        end
    end
    if entry.examples ~= nil then
        if not array(entry.examples) then
            return false
        end
        for _, example in ipairs(entry.examples) do
            if type(example) ~= 'string' and (type(example) ~= 'table' or type(example.text) ~= 'string'
                or (example.en ~= nil and type(example.en) ~= 'string')
                or (example.audio_url ~= nil and type(example.audio_url) ~= 'string')) then
                return false
            end
        end
    end
    for _, key in ipairs({ 'phonetic', 'syn', 'source_url', 'audio_url' }) do
        if entry[key] ~= nil and type(entry[key]) ~= 'string' then
            return false
        end
    end
    if entry.synonyms ~= nil then
        if not array(entry.synonyms) then
            return false
        end
        for _, text in ipairs(entry.synonyms) do
            if type(text) ~= 'string' then
                return false
            end
        end
    end
    return true
end

local function validate_tables(data, specs)
    if type(data) ~= 'table' then
        return nil, 'Missing backup data.'
    end
    local allowed_tables = {}
    for _, spec in ipairs(specs) do
        allowed_tables[spec.name] = true
        local rows = data[spec.name]
        if not array(rows) then
            return nil, 'Invalid backup table: ' .. spec.name
        end
        local seen = {}
        for _, row in ipairs(rows) do
            if type(row) ~= 'table' then
                return nil, 'Invalid backup row.'
            end
            local allowed = {}
            for _, column in ipairs(spec.columns) do
                local name, kind = column[1], column[2]
                allowed[name] = true
                local value = row[name]
                local optional = kind == 'optional' or kind == 'optional_integer'
                if not (optional and value == nil) then
                    local valid
                    if kind == 'text' or kind == 'optional' then
                        valid = type(value) == 'string' and #value <= 2 * 1024 * 1024
                    else
                        valid = valid_number(value, kind)
                    end
                    if not valid then
                        return nil, 'Invalid backup field: ' .. spec.name .. '.' .. name
                    end
                end
            end
            for key in pairs(row) do
                if not allowed[key] then
                    return nil, 'Unknown backup field.'
                end
            end
            local key = row[spec.columns[1][1]]
            if seen[key] then
                return nil, 'Duplicate backup row.'
            end
            seen[key] = true
            if row.word and (row.word == '' or #row.word > 400 or row.word:find('[%z\1-\31\127]')) then
                return nil, 'Invalid backup word.'
            end
            if spec.name == 'words' and row.entry and not valid_entry(row.entry) then
                return nil, 'Invalid saved definition.'
            end
            if spec.name == 'word_organization' then
                local ok, tags = pcall(json.decode, row.tags)
                local normalized = ok and learning.validate(row.folder, tags)
                if not normalized or normalized.folder ~= row.folder or #normalized.tags ~= #tags
                    or json.encode(normalized.tags) ~= json.encode(tags) or row.word ~= row.word:lower() then
                    return nil, 'Invalid saved organization.'
                end
            end
            if (spec.name == 'reviews' or spec.name == 'review_log') and row.grade > 3 then
                return nil, 'Invalid review grade.'
            end
            if spec.name == 'study_meanings' and (#row.meaning > 4000 or row.word ~= row.word:lower()) then
                return nil, 'Invalid study meaning.'
            end
            if spec.name == 'study_examples' and (#row.example > 4000 or row.word ~= row.word:lower()) then
                return nil, 'Invalid study example.'
            end
            if spec.name == 'study_plan' and row.id ~= 1 then
                return nil, 'Invalid study plan.'
            end
        end
    end
    for key in pairs(data) do
        if not allowed_tables[key] then
            return nil, 'Unknown backup table.'
        end
    end
    return true
end

function M.validate(payload)
    if type(payload) ~= 'table' or payload.format ~= 'wordbook'
        or (payload.version ~= 1 and payload.version ~= 2 and payload.version ~= 3) then
        return nil, 'Select a Wordbook version 1, 2 or 3 JSON backup.'
    end
    local specs = payload.version == 1 and WEB_V1 or payload.version == 2 and WEB_V2 or WEB
    local ok, err = validate_tables(payload.web, specs)
    if not ok then
        return nil, err
    end
    if payload.shared ~= nil then
        ok, err = validate_tables(payload.shared, SHARED)
        if not ok then
            return nil, err
        end
        local words, states, names = {}, {}, {}
        for _, row in ipairs(payload.shared.words) do
            if names[row.word] then
                return nil, 'Duplicate shared word.'
            end
            words[row.id] = true
            names[row.word] = true
        end
        for _, spec in ipairs({ 'srs', 'reviews', 'study_plan_words' }) do
            for _, row in ipairs(payload.shared[spec]) do
                if not words[row.word_id] then
                    return nil, 'Review data references a missing word.'
                end
                if spec == 'srs' then
                    if row.ease < 1.3 then
                        return nil, 'Invalid review ease.'
                    end
                    states[row.word_id] = true
                end
            end
        end
        for id in pairs(words) do
            if not states[id] then
                return nil, 'Missing shared review state.'
            end
        end
    end
    local ids = {}
    for _, row in ipairs(payload.web.words) do
        ids[row.id] = true
    end
    for _, row in ipairs(payload.web.review_log or {}) do
        if not ids[row.word_id] then
            return nil, 'Review data references a missing word.'
        end
    end
    local names, dates = {}, {}
    for _, row in ipairs(payload.web.words) do
        local key = row.word .. '\0' .. row.source
        if names[key] then
            return nil, 'Duplicate word/source entry.'
        end
        names[key] = true
    end
    for _, row in ipairs(payload.web.proverbs) do
        if dates[row.date] then
            return nil, 'Duplicate proverb date.'
        end
        dates[row.date] = true
    end
    return true
end

--------------------------------------------------------------------------------
-- Backup Restore
--------------------------------------------------------------------------------

local function replace(db, schema, specs, data)
    for index = #specs, 1, -1 do
        db:query('DELETE FROM ' .. schema .. '.' .. specs[index].name)
    end
    for _, spec in ipairs(specs) do
        local placeholders = {}
        for _ in ipairs(spec.columns) do
            placeholders[#placeholders + 1] = '?'
        end
        local sql = 'INSERT INTO ' .. schema .. '.' .. spec.name .. '(' .. columns(spec)
            .. ') VALUES(' .. table.concat(placeholders, ',') .. ')'
        for _, row in ipairs(data[spec.name]) do
            local params = {}
            for _, column in ipairs(spec.columns) do
                local value = row[column[1]]
                if spec.name == 'words' and row.source == 'youdao'
                    and (column[1] == 'entry' or column[1] == 'fetched_at') then
                    value = nil
                end
                if value == nil then
                    value = false
                end
                params[#params + 1] = value
            end
            db:query(sql, params)
        end
    end
end

function M.restore(store, payload)
    local ok, err = M.validate(payload)
    if not ok then
        return nil, err
    end
    if payload.shared and not store.shared then
        return nil, 'Enable the local dictionary before restoring a backup with shared TUI words.'
    end
    attach(store)
    store.web:query('BEGIN IMMEDIATE;')
    local restored, failure = pcall(function()
        local web = payload.web
        if payload.version < 3 then
            web = {
                words = web.words,
                proverbs = web.proverbs,
                word_organization = web.word_organization,
                study_meanings = payload.version == 2 and web.study_meanings or {},
                review_log = payload.version == 2 and web.review_log or {},
                study_examples = {},
            }
        end
        replace(store.web, 'main', WEB, web)
        if payload.shared then
            replace(store.web, 'shared_deletion', SHARED, payload.shared)
        end
        store.web:query('COMMIT;')
    end)
    if not restored then
        store.web:query('ROLLBACK;')
        error(failure)
    end
    return {
        restored = true,
        web_words = #payload.web.words,
        shared_words = payload.shared and #payload.shared.words or 0,
    }
end

--------------------------------------------------------------------------------
-- CSV Serialization (Spreadsheet-Safe Export)
--------------------------------------------------------------------------------

local function cell(value)
    local text = tostring(value or ''):gsub('%z', '\\0')
    if text:match('^%s*[=+%-@]') or text:find('^[\t\r\n]') then
        text = "'" .. text
    end
    return '"' .. text:gsub('"', '""') .. '"'
end

function M.csv(store)
    local lines = {
        'word,source,origin,collection,tags,note,definition,review_count,due_at,'
            .. 'lookup_count,study_meaning,study_example',
    }
    for _, row in ipairs(store:words()) do
        local fields = {
            row.word,
            row.source,
            row.collection,
            row.folder,
            table.concat(row.tags, ', '),
            row.note,
            row.entry and table.concat(row.entry.definitions or {}, '\n') or '',
            row.review_count,
            row.due_at,
            row.lookup_count,
            row.study_meaning,
            row.study_example,
        }
        local cells = {}
        for index = 1, 12 do
            cells[index] = cell(fields[index])
        end
        lines[#lines + 1] = table.concat(cells, ',')
    end
    return table.concat(lines, '\r\n') .. '\r\n'
end

return M
