#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_insights.lua
-- Personal meanings, recorded learning metrics and backup compatibility checks.
--------------------------------------------------------------------------------

local directory = (arg[0]:match('^(.*)/') or '.') .. '/..'
package.path = directory .. '/?.lua;' .. directory .. '/../?.lua;' .. package.path

local Store = require('store')
local dictionary = require('ffi_dict')
local service = require('service')
local json = require('json')

local file = assert(io.open(directory .. '/schema.sql', 'rb'))
local schema = file:read('*a')
file:close()

--------------------------------------------------------------------------------
-- Test Harness & Fixture Setup
--------------------------------------------------------------------------------

local count = 0

local function test(name, run)
    local ok, err = pcall(run)
    assert(ok, name .. ': ' .. tostring(err))
    count = count + 1
    print('ok ' .. count .. ' - ' .. name)
end

local function fixture(run)
    local web_path, shared_path = os.tmpname(), os.tmpname()
    local native = assert(dictionary.Database.open(shared_path))
    local store = Store.open(web_path, schema, shared_path)
    local ok, err = pcall(run, store, native, web_path, shared_path)
    store:close()
    native:close()
    for _, path in ipairs({ web_path, shared_path }) do
        os.remove(path)
        os.remove(path .. '-wal')
        os.remove(path .. '-shm')
    end
    assert(ok, err)
end

local function save(store, word, source)
    return store:save(word, source or 'youdao', { definitions = { 'Provider definition' }, examples = {} }, 100)
end

--------------------------------------------------------------------------------
-- Personal Meanings & Lookup Guards
--------------------------------------------------------------------------------

test('personal meanings are independent of provider definitions, notes and shared schedules', function()
    fixture(function(store, native)
        local row = save(store, 'hello')
        store:note(row.id, 'Study note', 'web')
        local meaning = 'My own meaning\0tail · 学习'
        local result, status = service.route(store, 'POST', '/api/meaning', {},
            { id = row.id, collection = 'web', meaning = meaning })
        assert(status == 200 and result.study_meaning == meaning)
        assert(store.web:get('hello', 'youdao').note == 'Study note')
        assert(not store.web:get('hello', 'youdao').entry)
        local another = save(store, 'hello', 'iciba')
        assert(another.study_meaning == meaning)
        assert(store:words('hello')[1].study_meaning == meaning)
        local id = assert(native:deck_add(
            { word = 'hello', definition = 'Original TUI meaning', mnem = 'TUI note' },
            100
        ))
        local prior = native:srs_state(id)
        assert(store:meaning(id, 'tui', 'Shared personal meaning').saved)
        local item = store:words('hello')[1]
        assert(item.collection == 'tui' and item.study_meaning == 'Shared personal meaning')
        assert(item.entry.definitions[1] == 'Original TUI meaning' and item.note == 'TUI note')
        assert(native:srs_state(id).due_at == prior.due_at)
        assert(store:meaning(id, 'tui', '').saved and store:words('hello')[1].study_meaning == '')
    end)
end)

test('meanings reject invalid mutations and survive reopening and refreshed lookups', function()
    fixture(function(store, _, web_path, shared_path)
        local row = save(store, 'hello')
        for _, value in ipairs({ 12, {}, string.rep('x', 4001) }) do
            local _, status = service.route(store, 'POST', '/api/meaning', {}, { id = row.id, meaning = value })
            assert(status == 400)
        end
        local _, missing = service.route(store, 'POST', '/api/meaning', {}, { id = 99999, meaning = 'missing' })
        assert(missing == 404)
        store:meaning(row.id, 'web', 'Personal')
        local result = assert(service.search(store, { word = 'hello', source = 'youdao' }, function()
            return { definitions = { 'New provider meaning' } }
        end, 200))
        assert(result.study_meaning == 'Personal' and result.entry.definitions[1] == 'New provider meaning')
        local reopened = Store.open(web_path, schema, shared_path)
        assert(reopened:words('hello')[1].study_meaning == 'Personal')
        reopened:close()
    end)
end)

--------------------------------------------------------------------------------
-- Review Log Statistics & Historical Metrics
--------------------------------------------------------------------------------

test('review history is recorded atomically with scheduling and never fabricates legacy days', function()
    fixture(function(store)
        local row = save(store, 'web')
        store.web:query('UPDATE words SET review_count=7 WHERE id=?', { row.id })
        local empty = store:statistics(40 * 86400)
        assert(empty.lifetime_reviews == 7 and empty.period_reviews == 0 and empty.recall_rate == nil)
        assert(empty.streak == 0 and #empty.days == 30)
        store.web:query([[CREATE TRIGGER break_log BEFORE INSERT ON review_log
            BEGIN SELECT RAISE(ABORT,'simulated failure'); END;]])
        local old = store.web:get('web', 'youdao')
        assert(not pcall(store.review, store, row.id, true, 100, 'web'))
        local after = store.web:get('web', 'youdao')
        assert(after.due_at == old.due_at and after.review_count == 7)
        store.web:query('DROP TRIGGER break_log;')
        assert(store:review(row.id, true, 100, 'web'))
        assert(store.web:query('SELECT count(*) AS total FROM review_log')[1].total == 1)
    end)
end)

test('UTC activity, recall rate, streak and difficult words combine web and TUI grades', function()
    fixture(function(store, native)
        local day, now = 40, 40 * 86400 + 1000
        local row = save(store, 'web')
        store.web:query('UPDATE words SET review_count=7 WHERE id=?', { row.id })
        store:review(row.id, false, (day - 2) * 86400 + 100, 'web')
        store:review(row.id, true, (day - 1) * 86400 + 100, 'web')
        store:review(row.id, true, now, 'web')
        local id = assert(native:deck_add({ word = 'shared', definition = 'Meaning' }, 100))
        assert(native:srs_apply(id, 0, (day - 1) * 86400 + 100))
        assert(native:srs_apply(id, 3, now))
        local stats = store:statistics(now)
        assert(stats.period_reviews == 5 and stats.recalled == 3 and stats.recall_rate == 60)
        assert(stats.today_reviews == 2 and stats.streak == 3 and stats.lifetime_reviews == 12)
        assert(stats.saved_words == 2 and stats.due_cards == 0 and #stats.difficult == 2)
        assert(stats.mastery.new == 0 and stats.mastery.mastered == 1)
        assert(stats.mastery.learning + stats.mastery.reviewing == 1)
        assert(#stats.forecast == 7 and stats.forecast[1].due == 0)
        assert(stats.days[30].total == 2 and stats.days[29].total == 2 and stats.days[28].total == 1)
        assert(store:statistics((day + 1) * 86400).streak == 3)
        assert(store:statistics((day + 2) * 86400).streak == 0)
        store.web:query('INSERT INTO review_log(word_id,rated_at,grade) VALUES(?,?,?)', { row.id, now + 2000, 2 })
        assert(store:statistics(now).today_reviews == 2)
    end)
end)

--------------------------------------------------------------------------------
-- Versioned Backups & Proverb Deduplication Tests
--------------------------------------------------------------------------------

test('new backups preserve meanings and dated grades; v1 backups remain restorable', function()
    fixture(function(store)
        local row = save(store, 'hello')
        store:meaning(row.id, 'web', 'Original personal meaning')
        store:review(row.id, true, 100, 'web')
        local exported = json.decode(json.encode(store:export_backup()))
        assert(exported.version == 3 and #exported.web.study_meanings == 1 and #exported.web.review_log == 1)
        store:meaning(row.id, 'web', 'Changed')
        assert(store:restore(exported))
        assert(store:study_meaning('hello') == 'Original personal meaning')
        assert(store.web:query('SELECT count(*) AS total FROM review_log')[1].total == 1)
        assert(store:export_csv():find('Original personal meaning', 1, true))
        exported.version = 1
        exported.web.study_meanings = nil
        exported.web.review_log = nil
        exported.web.study_examples = nil
        assert(store:restore(exported))
        assert(store:study_meaning('hello') == '')
        assert(store.web:query('SELECT count(*) AS total FROM review_log')[1].total == 0)
        assert(store.web:get('hello', 'youdao').review_count == 1)
    end)
end)

test('deletion removes personal meaning on the last source and lookup guards prevent re-adding', function()
    fixture(function(store)
        local first, second = save(store, 'hello'), save(store, 'hello', 'iciba')
        store:meaning(first.id, 'web', 'Personal')
        store:review(first.id, false, 100, 'web')
        assert(store:delete(first.id, 'web'))
        assert(store:study_meaning('hello') == 'Personal')
        assert(store.web:query('SELECT count(*) AS total FROM review_log')[1].total == 0)
        assert(store:delete(second.id, 'web'))
        assert(store:study_meaning('hello') == '')
        local result = assert(service.search(store, { word = 'hello', source = 'youdao' }, function()
            return { definitions = { 'Late result' } }
        end, 100, function()
            return false
        end))
        assert(not result.saved and not store.web:get('hello', 'youdao'))
    end)
end)

test('distinct random proverbs cannot overwrite a colliding timestamp', function()
    fixture(function(store)
        local original = math.random
        math.random = function()
            return 728
        end
        local ok, err = pcall(function()
            local first = store:random_proverb(nil, nil, function()
                return { text = 'First quote.', chinese = '' }
            end)
            local second = store:random_proverb(nil, nil, function()
                return { text = 'Second quote.', chinese = '' }
            end)
            assert(first.id ~= second.id and #store:proverbs() == 2)
            assert(store.web:get_proverb(first.date).text == 'First quote.')
        end)
        math.random = original
        assert(ok, err)
    end)
end)

test('personal examples persist across sources and shared entries without changing provider data', function()
    fixture(function(store, native, web_path, shared_path)
        local first = save(store, 'hello', 'iciba')
        store:meaning(first.id, 'web', 'Own meaning')
        store:note(first.id, 'Mnemonic', 'web')
        local example = 'I said hello.\0学习 <literal>'
        local result, status = service.route(store, 'POST', '/api/example', {},
            { id = first.id, example = example })
        assert(status == 200 and result.study_example == example)
        local another = save(store, 'hello', 'youdao')
        assert(another.study_example == example and another.study_meaning == 'Own meaning')
        assert(store.web:get('hello', 'iciba').note == 'Mnemonic')
        assert(json.decode(store.web:get('hello', 'iciba').entry).definitions[1] == 'Provider definition')
        assert(store:session({ mode = 'all' }).words[1].study_example == example)
        store:delete(another.id, 'web')
        assert(store:study_example('hello') == example)
        local id = assert(native:deck_add({
            word = 'hello',
            definition = 'TUI meaning',
            example = 'TUI example',
            mnem = 'TUI mnemonic',
        }, 100))
        local before = native:srs_state(id)
        assert(store:example(id, 'tui', 'Shared personal example').saved)
        assert(store:words('hello')[1].study_example == 'Shared personal example')
        assert(native:deck_get('hello').example == 'TUI example')
        assert(native:deck_get('hello').mnem == 'TUI mnemonic' and native:srs_state(id).due_at == before.due_at)
        local reopened = Store.open(web_path, schema, shared_path)
        assert(reopened:study_example('hello') == 'Shared personal example')
        reopened:close()
        assert(store:example(id, 'tui', '').saved and store:study_example('hello') == '')
        store:example(id, 'tui', 'Delete me')
        assert(store:delete(id, 'tui') and store:study_example('hello') == '')
        local only = save(store, 'solo')
        store:example(only.id, 'web', 'Solo example')
        assert(store:delete(only.id, 'web') and store:study_example('solo') == '')
    end)
end)

test('example API validation and v3/v2/v1 backup round trips preserve the correct fields', function()
    fixture(function(store)
        local row = save(store, 'hello')
        for _, value in ipairs({ 12, {}, string.rep('x', 4001), string.rep('字', 1334) }) do
            local _, status = service.route(store, 'POST', '/api/example', {}, { id = row.id, example = value })
            assert(status == 400)
        end
        local _, missing = service.route(store, 'POST', '/api/example', {}, { id = 9999, example = 'Missing' })
        assert(missing == 404)
        store:example(row.id, 'web', '=personal,"example"\n学习')
        store:meaning(row.id, 'web', 'Keep meaning')
        store:review(row.id, true, 200, 'web')
        local backup = json.decode(json.encode(store:export_backup()))
        assert(backup.version == 3 and #backup.web.study_examples == 1)
        store:example(row.id, 'web', 'Changed')
        assert(store:restore(backup) and store:study_example('hello') == '=personal,"example"\n学习')
        assert(store:export_csv():find("'" .. '=personal,""example""', 1, true))
        local invalid = json.decode(json.encode(backup))
        invalid.web.study_examples[1].example = string.rep('x', 4001)
        assert(not store:restore(invalid) and store:study_example('hello') == '=personal,"example"\n学习')
        backup.version = 2
        backup.web.study_examples = nil
        assert(store:restore(backup) and store:study_example('hello') == '')
        assert(store:study_meaning('hello') == 'Keep meaning')
        assert(store.web:query('SELECT count(*) AS total FROM review_log')[1].total == 1)
        backup.version = 1
        backup.web.study_meanings = nil
        backup.web.review_log = nil
        store:example(row.id, 'web', 'Clear on v1')
        assert(store:restore(backup) and store:study_example('hello') == '' and store:study_meaning('hello') == '')
    end)
end)

test('random proverbs reuse normalized content and legacy duplicates stay out of the list', function()
    fixture(function(store)
        local text = "Manners maketh the man. 'Manners makyth man' - the motto of William of Wykeham(1320 - 1404)"
        local old = store.web:save_proverb({
            date = '2026-10-11 22:30:00-777',
            text = text,
            chinese = '',
            explanation = 'English Proverb · Wikiquote',
        }, 100)
        local latest = store.web:save_proverb({
            date = '2026-10-11 22:51:48-728',
            text = text,
            chinese = '',
            explanation = 'English Proverb · Wikiquote',
        }, 200)
        assert(#store:proverbs() == 1 and store:proverbs()[1].id == latest.id)
        assert(#store:proverbs('Manners') == 1 and #store:proverbs('absent') == 0)
        local repeated = store:random_proverb(nil, 'wikiquote', function()
            return {
                text = '  ' .. text:gsub(' ', '  ') .. '\n',
                chinese = '  ',
                explanation = 'Updated attribution',
            }
        end)
        assert(repeated.id == latest.id and repeated.date == latest.date)
        assert(store.web:query('SELECT count(*) AS total FROM proverbs')[1].total == 2)
        local translated = store:random_proverb(nil, nil, function()
            return {
                text = text,
                chinese = '礼貌造就人。',
                explanation = 'Different translation',
            }
        end)
        assert(translated.id ~= latest.id and #store:proverbs() == 2)
        assert(#store:proverbs('礼貌') == 1)
        local distinct = store:random_proverb(nil, nil, function()
            return {
                text = 'Manners maketh a man.',
                chinese = '',
            }
        end)
        assert(distinct.id ~= latest.id and #store:proverbs() == 3)
        local daily = store.web:save_proverb({
            date = '2026-10-11',
            text = text,
            chinese = '',
        }, 300)
        assert(store.web:get_proverb('2026-10-11').id == daily.id)
        assert(store.web:get_proverb(old.date).id == old.id and #store:proverbs() == 3)
        local exported = store:export_backup()
        assert(#exported.web.proverbs == 5)
        assert(store:restore(exported))
        assert(#store:proverbs() == 3 and store.web:get_proverb('2026-10-11').id == daily.id)
    end)
end)

print('Passed ' .. count .. ' meaning/statistics tests.')
