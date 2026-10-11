#!/usr/bin/env luajit
-- Organization, review session, backup validation and rollback regression tests.
local directory = (arg[0]:match('^(.*)/') or '.') .. '/..'
package.path = directory .. '/?.lua;' .. directory .. '/../?.lua;' .. package.path
local Store = require('store')
local DB = require('db')
local dictionary = require('ffi_dict')
local service = require('service')
local backup = require('backup')
local json = require('json')
local file = assert(io.open(directory .. '/schema.sql', 'rb'))
local schema = file:read('*a'); file:close()
local count = 0

local function test(name, run)
    local ok, err = pcall(run)
    assert(ok, name .. ': ' .. tostring(err))
    count = count + 1
    print('ok ' .. count .. ' - ' .. name)
end

local function fixture(shared, run)
    local web_path, shared_path = os.tmpname(), os.tmpname()
    local native = shared and assert(dictionary.Database.open(shared_path)) or nil
    local store = Store.open(web_path, schema, shared and shared_path or 'none')
    local ok, err = pcall(run, store, native, web_path, shared_path)
    store:close()
    if native then native:close() end
    for _, path in ipairs({ web_path, shared_path }) do
        os.remove(path); os.remove(path .. '-wal'); os.remove(path .. '-shm')
    end
    assert(ok, err)
end

local function save(store, word, source, stamp)
    return store:save(word, source or 'dict.cn', { definitions = { 'Meaning of ' .. word }, examples = {} }, stamp or 100)
end

local function clone(value)
    return json.decode(json.encode(value))
end

test('old journals upgrade without changing notes or review progress', function()
    local path = os.tmpname()
    local old = DB.open(path, assert(schema:match('^(.-)CREATE TABLE IF NOT EXISTS word_organization')))
    local row = old:save('legacy', 'dict.cn', nil, 100)
    assert(old:note(row.id, 'before\0after').saved)
    old:query('UPDATE words SET streak=1,review_count=1,due_at=86500 WHERE id=?', { row.id })
    local prior = old:get('legacy', 'dict.cn')
    old:close()
    local store = Store.open(path, schema, 'none')
    local after = store.web:get('legacy', 'dict.cn')
    for key, value in pairs(prior) do assert(after[key] == value, key) end
    assert(store:organize(row.id, 'web', 'Books', { 'study' }).saved)
    store:close(); os.remove(path)
end)

test('organization follows word identity across providers and overlapping shared IDs', function()
    fixture(true, function(store, native)
        local id = assert(native:deck_add({ word = 'hello', definition = 'A greeting.' }, 100))
        save(store, 'hello', 'dict.cn')
        save(store, 'hello', 'youdao')
        local other = save(store, 'other')
        local result, status = service.route(store, 'POST', '/api/organize', {},
            { id = id, collection = 'tui', folder = '  Books  ', tags = { ' Travel ', 'travel', '学习' } })
        assert(status == 200 and result.folder == 'Books' and #result.tags == 2)
        local words = store:words('hello')
        assert(#words == 1 and words[1].folder == 'Books' and words[1].tags[2] == '学习')
        assert(store:words('other')[1].folder == '')
        assert(store:organize(other.id, 'web', '', {}).saved)
        local missing, _, missing_status = store:organize(99999, 'web', 'Books', {})
        assert(not missing and missing_status == 404)
    end)
end)

test('invalid tags and collections never overwrite saved organization', function()
    fixture(false, function(store)
        local row = save(store, 'word')
        assert(store:organize(row.id, 'web', 'Books', { 'valid' }).saved)
        for _, tags in ipairs({ { '' }, { 'a,b' }, { '\255' }, { key = 'bad' },
            { '1', '2', '3', '4', '5', '6', '7', '8', '9' }, { string.rep('词', 65) } }) do
            local result, _, status = store:organize(row.id, 'web', 'Other', tags)
            assert(not result and status == 400)
        end
        assert(not store:organize(row.id, 'web', 'bad\0name', {}))
        assert(store:words()[1].folder == 'Books' and store:words()[1].tags[1] == 'valid')
        assert(store:organize(row.id, 'web', string.rep('词', 64), { string.rep('词', 64) }))
    end)
end)

test('sessions select new, due, reviewed-overdue and future cards with filters and limits', function()
    fixture(true, function(store, native)
        local first, second, future = save(store, 'first'), save(store, 'second'), save(store, 'future')
        assert(store:organize(first.id, 'web', 'Books', { 'Travel' }))
        assert(store:organize(second.id, 'web', 'Books', { 'Travel' }))
        store.web:review(second.id, false, 100)
        store.web:review(future.id, true, 100)
        local shared = assert(native:deck_add({ word = 'shared', definition = 'Shared meaning.' }, 50))
        assert(store:organize(shared, 'tui', 'Books', { 'travel' }))
        assert(native:srs_apply(shared, 0, 100))
        local due = assert(store:session({ mode = 'due' }, 700))
        assert(#due.words == 3 and due.total_matching == 3)
        assert(#assert(store:session({ mode = 'new' }, 700)).words == 1)
        assert(#assert(store:session({ mode = 'overdue' }, 700)).words == 2)
        assert(#assert(store:session({ mode = 'all' }, 700)).words == 4)
        local limited = assert(store:session({ folder = 'books', tag = 'TRAVEL', limit = '1' }, 700))
        assert(#limited.words == 1 and limited.total_matching == 3 and limited.words[1].word == 'first')
        assert(#assert(store:session({ folder = 'missing' }, 700)).words == 0)
        assert(#assert(store:session({ tag = 'missing' }, 700)).words == 0)
        for _, limit in ipairs({ '0', '201', '1.5', 'bad' }) do assert(not store:session({ limit = limit })) end
        assert(not store:session({ mode = 'bad' }))
        assert(not store:session({ tag = '\0' }))
    end)
end)

test('full backup restores both decks, notes, schedules, study plans and organization', function()
    fixture(true, function(store, native)
        local id = assert(native:deck_add({ word = 'shared', definition = 'Shared', mnem = 'note\0tail' }, 100))
        assert(native:srs_apply(id, 3, 200))
        assert(native:run('INSERT INTO study_plan(id,track,daily_new,updated_at) VALUES(1,?,?,?)', { 'custom', 5, 100 }))
        assert(native:run('INSERT INTO study_plan_words(word_id,source_track,plan_date) VALUES(?,?,?)',
            { id, 'custom', '2026-10-11' }))
        assert(native:dict_replace_word('dictionary-only', { { definition = 'Keep this imported entry.' } }) == 1)
        local row = save(store, 'web')
        store:note(row.id, 'web\0note', 'web'); store:review(row.id, true, 100, 'web')
        store:organize(id, 'tui', 'Books', { 'study' })
        store.web:save_proverb({ date = '2026-10-11', text = 'Practice.', chinese = '学习', explanation = '' })
        save(store, 'private-provider', 'youdao')
        local exported = clone(store:export_backup())
        assert(exported.format == 'wordbook' and exported.shared.words[1].mnem == 'note\0tail')
        for _, value in ipairs(exported.web.words) do
            if value.source == 'youdao' then assert(not value.entry and not value.fetched_at) end
        end
        assert(not exported.shared.dict and not exported.credentials)
        save(store, 'extra')
        store:note(id, 'changed', 'tui'); store:organize(id, 'tui', 'Other', {})
        local restored = assert(store:restore(exported))
        assert(restored.web_words == 2 and restored.shared_words == 1)
        assert(not store.web:get('extra', 'dict.cn'))
        assert(native:deck_get('shared').mnem == 'note\0tail')
        assert(native:srs_state(id).due_at == exported.shared.srs[1].due_at)
        assert(native:scalar('SELECT count(*) FROM reviews') == 1)
        assert(native:scalar('SELECT daily_new FROM study_plan') == 5)
        assert(native:scalar('SELECT count(*) FROM study_plan_words') == 1)
        assert(#native:dict_lookup('dictionary-only') == 1)
        assert(store:words('shared')[1].folder == 'Books')
        assert(store.web:get('web', 'dict.cn').note == 'web\0note')
        assert(store.web:get_proverb('2026-10-11').text == 'Practice.')
        fixture(true, function(destination, other)
            assert(other:dict_replace_word('keep', { { definition = 'Bulk dictionary stays.' } }) == 1)
            assert(destination:restore(exported))
            assert(destination:words('shared')[1].note == 'note\0tail')
            assert(other:srs_state(id).due_at == exported.shared.srs[1].due_at)
            assert(#other:dict_lookup('keep') == 1)
        end)
    end)
end)

test('malformed backups and missing shared integration leave existing data untouched', function()
    fixture(false, function(store)
        save(store, 'original')
        local original = store:export_backup()
        local invalid = {}
        local bad = clone(original); bad.version = 99; invalid[#invalid + 1] = bad
        bad = clone(original); bad.web.words[1].due_at = -1; invalid[#invalid + 1] = bad
        bad = clone(original); bad.web.words[1].entry = '{bad'; invalid[#invalid + 1] = bad
        bad = clone(original); bad.web.words[2] = clone(bad.web.words[1]); invalid[#invalid + 1] = bad
        bad = clone(original); bad.web['evil;DROP TABLE words'] = {}; invalid[#invalid + 1] = bad
        bad = clone(original); bad.web.words[1].id = 1.5; invalid[#invalid + 1] = bad
        for _, payload in ipairs(invalid) do
            assert(not store:restore(payload))
            assert(store.web:get('original', 'dict.cn'))
        end
        fixture(true, function(other, native)
            assert(native:deck_add({ word = 'shared', definition = 'Meaning' }, 100))
            local shared = other:export_backup()
            assert(not store:restore(shared))
            shared.shared.srs[1].word_id = 999
            assert(not backup.validate(shared))
        end)
        assert(store.web:get('original', 'dict.cn'))
    end)
end)

test('restore rolls back changes to both databases after an actual SQL failure', function()
    fixture(true, function(store, native)
        local id = assert(native:deck_add({ word = 'shared', definition = 'Meaning', mnem = 'original' }, 100))
        local row = save(store, 'web')
        store:note(row.id, 'original', 'web')
        local payload = store:export_backup()
        payload.web.words[1].note = 'replacement'
        payload.shared.words[1].mnem = 'replacement'
        assert(native:exec([[CREATE TRIGGER block_restore BEFORE INSERT ON words
            BEGIN SELECT RAISE(ABORT,'simulated failure'); END;]]))
        local ok = pcall(store.restore, store, payload)
        assert(not ok)
        assert(store.web:get('web', 'dict.cn').note == 'original')
        assert(native:deck_get('shared').mnem == 'original' and native:srs_state(id))
        assert(native:exec('DROP TRIGGER block_restore;'))
        assert(store:restore(payload))
        assert(native:deck_get('shared').mnem == 'replacement')
    end)
end)

test('CSV quotes Unicode, multiline notes and formula-like text safely', function()
    fixture(false, function(store)
        local row = save(store, 'hello')
        store:note(row.id, '=HYPERLINK("evil")\n学习\0tail', 'web')
        store:organize(row.id, 'web', 'Books', { 'travel' })
        local csv = store:export_csv()
        assert(csv:find('word,source,origin,collection,tags', 1, true))
        assert(csv:find('"Books","travel"', 1, true))
        assert(csv:find('"\'=HYPERLINK(""evil"")\n学习\\0tail"', 1, true))
    end)
end)
print('Passed ' .. count .. ' learning/backup tests.')
