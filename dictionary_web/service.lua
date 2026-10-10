local json = require('json')
local providers = require('providers')
local content = require('content')
local M = {}

function M.normalize(word)
    if type(word) ~= 'string' or word:find('[%z\1-\31\127]') then return nil end
    word = word:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' '):lower()
    local count, bytes = 0, 0
    for char in word:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local first, second = char:byte(1, 2)
        local expected = first < 128 and 1 or first < 224 and 2 or first < 240 and 3 or 4
        if #char ~= expected or (first == 224 and second < 160) or (first == 237 and second >= 160)
            or (first == 240 and second < 144) or (first == 244 and second >= 144) then return nil end
        count, bytes = count + 1, bytes + #char
    end
    if count < 1 or count > 100 or bytes ~= #word then return nil end
    return word
end

function M.search(db, payload, provider, stamp)
    if type(payload) ~= 'table' then return nil, 'Expected a JSON object.' end
    local word = M.normalize(payload.word)
    if not word then return nil, 'Enter a word or short phrase (1–100 characters).' end
    local source = payload.source or 'dict.cn'
    if source == 'all' then
        local results = {}
        for _, name in ipairs({'local', 'dict.cn', 'youdao'}) do
            results[#results + 1] = assert(M.search(db, {word = word, source = name}, provider, stamp))
        end
        return {word = word, source = 'all', results = results}
    end
    if source ~= 'local' and source ~= 'dict.cn' and source ~= 'youdao' then
        return nil, 'Select a valid dictionary source.'
    end
    stamp = stamp or os.time()
    local old, entry, message = db:get(word, source)
    local cached = source ~= 'local' and source ~= 'youdao' and old and old.entry and old.fetched_at and stamp - old.fetched_at < 86400
    if source == 'local' then
        if db.local_lookup then
            entry, message = db:local_lookup(word)
        else
            message = 'Local dictionary is unavailable.'
        end
    elseif cached then
        entry = json.decode(old.entry)
    else
        local ok, result, err = pcall(provider or providers.lookup, source, word)
        if ok then
            entry, message = result, err
        else
            message = 'Dictionary lookup failed. Please try again.'
        end
    end
    local usable = false
    if type(entry) == 'table' and type(entry.definitions) == 'table' then
        for _, definition in ipairs(entry.definitions) do
            if type(definition) == 'string' and definition:find('%S') then
                usable = true
                break
            end
        end
    end
    if not usable then
        return {
            word = word,
            source = source,
            saved = false,
            error = message or 'No usable definition found in this dictionary.',
            stale = source ~= 'youdao' and old and old.entry and json.decode(old.entry) or nil,
            source_url = source ~= 'local' and providers.source_url(source, word) or nil,
        }
    end
    local fresh_entry = entry
    if cached then fresh_entry = nil end -- Reads must not extend cache expiry.
    local saved = db:save(word, source, fresh_entry, stamp)
    return {
        word = word,
        source = source,
        saved = true,
        id = saved.id,
        lookup_count = saved.lookup_count,
        note = saved.note,
        collection = saved.collection or 'web',
        cached = not not cached,
        entry = entry,
        error = message,
        stale = not entry and source ~= 'youdao' and old and old.entry and json.decode(old.entry) or nil,
        source_url = source ~= 'local' and providers.source_url(source, word) or nil,
    }
end

function M.route(db, method, path, params, payload)
    if method == 'GET' then
        if path == '/api/daily' then
            return db.daily and db:daily() or content.daily(), 200
        end
        if path == '/api/words' then
            return {words = db:words(params.q, params.due == '1')}, 200
        end
        if path == '/api/suggest' then
            return {suggestions = db.suggest and db:suggest(params.q, 6) or {}}, 200
        end
    elseif method == 'POST' then
        if type(payload) ~= 'table' then
            return {error = 'Expected a JSON object.'}, 400
        end
        if path == '/api/search' then
            local result, err = M.search(db, payload)
            return result or {error = err}, result and 200 or 400
        end
        if path == '/api/review' or path == '/api/note' or path == '/api/delete' then
            local collection = payload.collection or 'web'
            if collection ~= 'web' and collection ~= 'tui' then
                return {error = 'Invalid word collection.'}, 400
            end
            if type(payload.id) ~= 'number' or payload.id < 1 or payload.id % 1 ~= 0 then
                return {error = 'Invalid word ID.'}, 400
            end
            local result, err
            if path == '/api/delete' then
                result, err = db:delete(payload.id, collection)
            elseif path == '/api/review' then
                if payload.grade ~= nil and (type(payload.grade) ~= 'number' or payload.grade % 1 ~= 0 or payload.grade < 0 or payload.grade > 3) then
                    return {error = 'Invalid review grade.'}, 400
                end
                if type(payload.remembered) ~= 'boolean' then
                    return {error = 'Invalid review grade.'}, 400
                end
                result, err = db:review(payload.id, payload.remembered, nil, collection, payload.grade)
            else
                if type(payload.note) ~= 'string' or #payload.note > 4000 then
                    return {error = 'Study notes must be at most 4000 bytes.'}, 400
                end
                result, err = db:note(payload.id, payload.note, collection)
            end
            return result or {error = err}, result and 200 or 404
        end
    end
    return {error = 'Not found.'}, 404
end
return M
