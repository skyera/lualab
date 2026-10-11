-- Adapter over the web lookup journal and ffi_dict's shared vocabulary deck.
local DB = require('db')
local dictionary = require('ffi_dict')
local content = require('content')
local net = require('net')
local Store = {}
Store.__index = Store

local function checked(value, err)
    if value == nil or value == false then
        error(err or 'Shared dictionary operation failed')
    end
    return value
end

function Store.open(path, schema, dictionary_path)
    local self = setmetatable({web = DB.open(path, schema)}, Store)
    if dictionary_path and dictionary_path ~= 'none' then
        local file = io.open(dictionary_path, 'rb')
        if file then
            file:close()
            local shared, err = dictionary.Database.open(dictionary_path)
            if not shared then
                self.web:close()
                error(err)
            end
            self.shared = shared
            -- The existing TUI connection also benefits from a bounded busy wait.
            checked(shared:exec('PRAGMA busy_timeout=5000;'))
        end
    end
    return self
end

function Store:close()
    if self.shared then
        self.shared:close()
    end
    self.web:close()
end

local function parse_synonyms(text)
    if not text or text == '' then return nil end
    local list = {}
    local seen = {}
    for s in text:gmatch('[^,;]+') do
        local trimmed = s:gsub('^%s+', ''):gsub('%s+$', '')
        if trimmed ~= '' and not seen[trimmed:lower()] and #list < 8 then
            seen[trimmed:lower()] = true
            list[#list + 1] = trimmed
        end
    end
    return #list > 0 and list or nil
end

local function deck_entry(row)
    return {
        word = row.word,
        source = 'local',
        phonetic = '',
        pos = row.pos,
        syn = row.syn,
        synonyms = parse_synonyms(row.syn),
        ant = row.ant,
        definitions = row.definition and row.definition ~= '' and {row.definition} or {},
        examples = row.example and row.example ~= '' and {row.example} or {},
    }
end

local function deck_row(row)
    return {
        id = row.id,
        collection = 'tui',
        source = 'local',
        word = row.word,
        entry = deck_entry(row),
        note = row.mnem or '',
        due_at = row.due_at or 0,
        review_count = row.review_count or 0,
        first_seen = row.added_at,
        last_seen = row.added_at,
        lookup_count = 0,
        interval_days = row.interval_days or 0,
    }
end

function Store:get(word, source)
    return self.web:get(word, source)
end

function Store:local_lookup(word)
    if not self.shared then
        return nil, 'Local dictionary is unavailable. Import a dictionary with ffi_dict or configure --dict-db.'
    end
    local deck = self.shared:deck_get(word)
    if deck and deck.definition and deck.definition ~= '' then
        return deck_entry(deck)
    end
    local senses = checked(self.shared:dict_lookup(word))
    local definitions, examples, synonyms, antonyms = {}, {}, {}, {}
    for _, sense in ipairs(senses) do
        if sense.definition and sense.definition ~= '' and #definitions < 12 then
            definitions[#definitions + 1] = (sense.pos and sense.pos ~= '' and sense.pos .. ' · ' or '') .. sense.definition
        end
        if sense.example and sense.example ~= '' and #examples < 4 then
            examples[#examples + 1] = sense.example
        end
        if sense.syn and sense.syn ~= '' then
            synonyms[#synonyms + 1] = sense.syn
        end
        if sense.ant and sense.ant ~= '' then
            antonyms[#antonyms + 1] = sense.ant
        end
    end
    if #definitions == 0 then
        return nil, 'Word not found in the local dictionary. Try an online source.'
    end
    local syn_combined = table.concat(synonyms, ', ')
    return {
        word = word,
        source = 'local',
        phonetic = '',
        definitions = definitions,
        examples = examples,
        pos = senses[1].pos or '',
        syn = syn_combined,
        synonyms = parse_synonyms(syn_combined),
        ant = table.concat(antonyms, ', '),
    }
end

function Store:daily(stamp, fetch_fn)
    local daily = content.daily(stamp)
    if self.shared then
        local word = self.shared:wotd(stamp)
        if word then
            daily.word = {word = word.word, meaning = word.definition or '', example = word.example or '', source = 'local'}
        end
    end
    -- Check local database for today's saved proverb first
    local proverb = self.web:get_proverb(daily.date)
    if not proverb then
        -- Fetch online from Kingsoft dsapi and save to database
        local online = content.fetch_online(fetch_fn or net.fetch, daily.date)
        if online then
            online.date = daily.date
            proverb = self.web:save_proverb(online, stamp)
        end
    end
    if proverb then
        daily.proverb = proverb
    end
    return daily
end

function Store:proverbs(query)
    return self.web:proverbs(query)
end

function Store:random_proverb(fetch_fn, source)
    -- Try fetching from online quote / proverb services first
    local online = content.fetch_quote(fetch_fn or net.fetch, source)
    if online and online.text and online.text ~= '' then
        online.date = os.date('!%Y-%m-%d %H:%M:%S', os.time()) .. '-' .. math.random(100, 999)
        local saved = self.web:save_proverb(online)
        if saved then return saved end
        return online
    end
    -- Fallback: pick a historical or curated proverb
    local offset = math.random(1, 365) * 86400
    local target_date = os.date('!%Y-%m-%d', os.time() - offset)
    local proverb = self.web:get_proverb(target_date)
    if not proverb then
        local curated = content.daily(os.time() - offset).proverb
        curated.date = target_date
        proverb = self.web:save_proverb(curated)
    end
    return proverb
end

function Store:random_word()
    if self.shared then
        local now = os.time() - math.random(1, 10000) * 86400
        local word = self.shared:wotd(now)
        if word then
            return {
                word = word.word,
                meaning = word.definition or '',
                example = word.example or '',
                source = 'local',
            }
        end
    end
    return content.random_word()
end

function Store:save(word, source, entry, stamp)
    local saved = self.web:save(word, source, entry, stamp)
    saved.collection = 'web'
    if self.shared then
        local deck = self.shared:deck_get(word)
        if source == 'local' and entry and not deck then
            checked(self.shared:exec('BEGIN IMMEDIATE;'))
            local ok, err = pcall(function()
                checked(self.shared:deck_add({
                    word = word,
                    definition = table.concat(entry.definitions, '\n'),
                    example = table.concat(entry.examples or {}, '\n'),
                    pos = entry.pos,
                    syn = entry.syn,
                    ant = entry.ant,
                }, stamp))
                checked(self.shared:commit())
            end)
            if not ok then
                self.shared:rollback()
                error(err)
            end
            deck = self.shared:deck_get(word)
        end
        if deck then
            saved.id, saved.collection, saved.note = deck.id, 'tui', deck.mnem or ''
        end
    end
    return saved
end

function Store:words(query, due, stamp)
    stamp = stamp or os.time()
    local rows, shared_words = {}, {}
    local history = {}
    for _, row in ipairs(self.web:query([[SELECT lower(word) AS word,SUM(lookup_count) AS lookups,
        MAX(last_seen) AS last_seen FROM words GROUP BY lower(word)]])) do
        history[row.word] = row
    end
    if self.shared then
        local escaped = (query or ''):gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_')
        local sql = [[SELECT w.*,s.due_at,s.interval_days,
            (SELECT count(*) FROM reviews r WHERE r.word_id=w.id) AS review_count
            FROM words w LEFT JOIN srs s ON s.word_id=w.id WHERE w.word LIKE ? ESCAPE '\']]
        local params = {'%' .. escaped .. '%'}
        if due then
            sql = sql .. ' AND s.due_at<=?'
            params[2] = stamp
        end
        for _, row in ipairs(checked(self.shared:query(sql .. ' ORDER BY w.added_at DESC,w.id DESC', params))) do
            local item = deck_row(row)
            local lookups = history[row.word:lower()]
            if lookups then
                item.lookup_count = lookups.lookups
                item.last_seen = math.max(item.last_seen, lookups.last_seen)
            end
            rows[#rows + 1] = item
        end
        -- Exclude web duplicates even if their shared deck row is not due yet.
        for _, row in ipairs(checked(self.shared:query('SELECT word FROM words'))) do
            shared_words[row.word:lower()] = true
        end
    end
    for _, row in ipairs(self.web:words(query, due, stamp)) do
        if not shared_words[row.word:lower()] then
            row.collection = 'web'
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b)
        if a.last_seen ~= b.last_seen then return a.last_seen > b.last_seen end
        return a.word < b.word
    end)
    return rows
end

function Store:suggest(prefix, limit)
    limit = limit or 6
    if not prefix or #prefix == 0 then return {} end
    local results = {}
    local seen = {}
    local escaped = (prefix or ''):gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_')
    local pattern = escaped:lower() .. '%'

    if self.shared then
        local sql = [[SELECT word, pos, definition FROM dict
            WHERE lower(word) LIKE ? ESCAPE '\'
            GROUP BY lower(word)
            ORDER BY length(word) ASC, word ASC LIMIT ?]]
        local rows = self.shared:query(sql, { pattern, limit })
        if rows then
            for _, r in ipairs(rows) do
                local w_lower = r.word:lower()
                if not seen[w_lower] then
                    seen[w_lower] = true
                    local snippet = (r.pos and r.pos ~= '' and r.pos .. ' · ' or '') .. (r.definition or '')
                    results[#results + 1] = { word = r.word, snippet = snippet }
                end
            end
        end
    end

    local web_rows = self.web:suggest(prefix, limit)
    for _, r in ipairs(web_rows or {}) do
        local w_lower = r.word:lower()
        if not seen[w_lower] and #results < limit then
            seen[w_lower] = true
            results[#results + 1] = { word = r.word, snippet = r.snippet or '' }
        end
    end

    return results
end

function Store:review(id, remembered, stamp, collection, grade)
    if collection ~= 'tui' then
        return self.web:review(id, remembered, stamp)
    end
    if not self.shared then
        return nil, 'Shared dictionary is unavailable.'
    end
    stamp = stamp or os.time()
    grade = grade or (remembered and dictionary.SM2.GRADE_GOOD or dictionary.SM2.GRADE_AGAIN)
    local old = self.shared:srs_state(id)
    if not old then
        return nil, 'Word not found.'
    end
    local next_state, err = dictionary.SM2.schedule(old, grade, stamp)
    if not next_state then return nil, err end
    -- Update scheduling and review history atomically in the shared database.
    checked(self.shared:exec('BEGIN IMMEDIATE;'))
    local ok, failure = pcall(function()
        -- Re-read after acquiring the write lock so another interface cannot
        -- update the schedule between our state read and write.
        next_state = checked(dictionary.SM2.schedule(checked(self.shared:srs_state(id)), grade, stamp))
        checked(self.shared:run([[UPDATE srs SET ease=?,interval_days=?,due_at=?,reps=?,lapses=? WHERE word_id=?]],
            {next_state.ease, next_state.interval_days, next_state.due_at, next_state.reps, next_state.lapses, id}))
        checked(self.shared:run('INSERT INTO reviews(word_id,rated_at,grade) VALUES(?,?,?)', {id, stamp, grade}))
        checked(self.shared:commit())
    end)
    if not ok then
        self.shared:rollback()
        error(failure)
    end
    return next_state
end

function Store:note(id, note, collection)
    if collection ~= 'tui' then
        return self.web:note(id, note)
    end
    if not self.shared then
        return nil, 'Shared dictionary is unavailable.'
    end
    if not checked(self.shared:query('SELECT id FROM words WHERE id=?', {id}))[1] then
        return nil, 'Word not found.'
    end
    checked(self.shared:run('UPDATE words SET mnem=? WHERE id=?', {note, id}))
    return {saved = true}
end

function Store:delete(id, collection)
    if collection ~= 'tui' then
        return self.web:delete(id)
    end
    if not self.shared then
        return nil, 'Shared dictionary is unavailable.'
    end
    -- One SQLite connection coordinates rollback across the two databases.
    if not self.deletion_attached then
        self.web:query('ATTACH DATABASE ? AS shared_deletion', {self.shared.path})
        self.deletion_attached = true
    end
    self.web:query('BEGIN IMMEDIATE;')
    local ok, result = pcall(function()
        local row = self.web:query('SELECT word FROM shared_deletion.words WHERE id=?', {id})[1]
        if not row then return nil end
        for _, name in ipairs({'study_plan_words', 'reviews', 'srs'}) do
            self.web:query('DELETE FROM shared_deletion.' .. name .. ' WHERE word_id=?', {id})
        end
        self.web:query('DELETE FROM shared_deletion.words WHERE id=?', {id})
        self.web:query('DELETE FROM main.words WHERE lower(word)=lower(?)', {row.word})
        self.web:query('COMMIT;')
        return {deleted = true, word = row.word, collection = 'tui'}
    end)
    if not ok or not result then
        self.web:query('ROLLBACK;')
    end
    if not ok then error(result) end
    return result, not result and 'Word not found.' or nil
end
return Store
