local directory = (arg[0]:match('^(.*)/') or '.') .. '/..'
package.path = directory .. '/?.lua;' .. directory .. '/../?.lua;' .. package.path
local json = require('json')
local DB = require('db')
local providers = require('providers')
local net = require('net')
local service = require('service')
local content = require('content')
local http = require('http')
local count = 0
local function test(name, run)
    local ok, err = pcall(run)
    assert(ok, name .. ': ' .. tostring(err))
    count = count + 1
    print('ok ' .. count .. ' - ' .. name)
end
local function read(path)
    local file = assert(io.open(path, 'rb')); local text = file:read('*a'); file:close(); return text
end
local schema = read(directory .. '/schema.sql')
local function entry(word)
    return {word = word, definitions = {'A test meaning'}, phonetic = '', examples = {}, source_url = 'https://dict.cn/' .. net.encode(word)}
end

test('UTF-8 validation and normalized queries', function()
    assert(service.normalize('  HELLO   World ') == 'hello world')
    assert(service.normalize('学习') == '学习')
    for _, word in ipairs({'', ' ', '\0bad', 'line\nbreak', string.rep('a', 101), '\255', '\192\128', '\237\160\128', '\244\144\128\128'}) do
        assert(not service.normalize(word), 'Accepted invalid query')
    end
    assert(service.normalize(string.rep('词', 100)))
    assert(not service.normalize(string.rep('词', 101)))
end)

test('HTML parsing isolates definitions, pronunciation and bilingual examples', function()
    local html = [[<div class="phonetic"><bdo>[test]</bdo><bdo>[test]</bdo></div>
        <ul class="dict-basic-ul"><li><strong>n. &lt;meaning&gt; &amp; &#x4e2d;&#25991;</strong></li></ul>
        <div class="section rel"><ol><li><a href="/syn1">synonym1</a></li><li><a href="/syn2">synonym2</a></li></ol></div>
        <div class="section sent"><ol><li>Example.<br/>例句。</li></ol></div>
        <bdo>not a pronunciation</bdo><strong>not a definition</strong>]]
    local result = assert(providers.parse_dict(html))
    assert(result.definitions[1] == 'n. <meaning> & 中文')
    assert(result.phonetic == '[test]')
    assert(result.examples[1] == 'Example. / 例句。')
    assert(result.synonyms and result.synonyms[1] == 'synonym1' and result.synonyms[2] == 'synonym2')
    assert(not providers.parse_dict('<html>Not found</html>'))
end)

test('dict.cn phrase definitions use plain lists inside the basic block', function()
    local result = assert(providers.parse_dict([[<strong>unrelated heading</strong>
        <div class="basic clearfix"><ul ><li><strong>供 ... 使用； 可以自由处理</strong></li></ul></div>
        <div class="section sent"><ol><li>Her property is at her disposition.<br/>她的财产由她自由处理。</li></ol></div>
        <strong>unrelated footer</strong>]]))
    assert(#result.definitions == 1 and result.definitions[1] == '供 ... 使用； 可以自由处理')
    assert(result.examples[1] == 'Her property is at her disposition. / 她的财产由她自由处理。')
    assert(not providers.parse_dict('<ul><li><strong>unrelated bold text</strong></li></ul>'))
end)

test('dict.cn Chinese queries use English translations and reference pronunciation', function()
    local result = assert(providers.parse_dict([[<div class="phonetic"></div><div class="layout cn"><ul>
        <li><a href="/study">to study</a></li><li><a href="/learn">to learn</a></li></ul></div>
        <div class="layout ref"><dt><b>学习</b><bdo>[xué xí]</bdo></dt></div>
        <div class="section sent"><ol><li>I study.<br/>我学习。</li></ol></div>]]))
    assert(result.definitions[1] == 'to study' and result.definitions[2] == 'to learn')
    assert(result.phonetic == '[xué xí]' and result.examples[1] == 'I study. / 我学习。')
end)

test('removed Merriam-Webster source is rejected without credentials or network access', function()
    local entry, err = providers.lookup('merriam-webster', 'hello', {
        env = function() error('Must not read removed source credentials') end,
        fetch = function() error('Must not query removed source') end})
    assert(not entry and err == 'Unknown dictionary source.')
    assert(not providers.source_url('merriam-webster', 'hello') and not providers.parse_merriam)
    local db = DB.open(':memory:', schema)
    local result, code = service.route(db, 'POST', '/api/search', {}, {word = 'hello', source = 'merriam-webster'})
    assert(code == 400 and result.error and #db:words() == 0)
    db:close()
end)

test('Youdao documented response shape and service errors', function()
    local result = assert(providers.parse_youdao({errorCode = '0', result = {{ec = {basic = {
        explains = {'释义'}, phonetic = 'test', syno = {{ws = {'peaceful', 'calm'}}}}, sentenceSample = {{sentence = 'Example.', translation = '例句。'}}}}}}))
    assert(result.definitions[1] == '释义' and result.phonetic == 'test')
    assert(result.examples[1] == 'Example. / 例句。')
    assert(result.synonyms and result.synonyms[1] == 'peaceful' and result.synonyms[2] == 'calm')
    assert(not providers.parse_youdao({errorCode = '401'}))
    assert(not providers.parse_youdao({errorCode = '0'}))
end)

test('SHA256, URL/form encoding and Unicode Youdao truncation', function()
    assert(net.sha256('abc') == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    assert(net.encode('a b&') == 'a%20b%26')
    assert(net.form({q = 'hello world', key = 'a&b'}) == 'key=a%26b&q=hello%20world')
    assert(providers.youdao_input(string.rep('词', 21)) == string.rep('词', 10) .. '21' .. string.rep('词', 10))
    assert(providers.youdao_input('hello') == 'hello')
end)

test('Provider credentials, signed payload and malformed upstream errors', function()
    local function no_env() return nil end
    local public = assert(providers.lookup('youdao', 'hello', {env = no_env, fetch = function(url, body)
        assert(url == providers.source_url('youdao', 'hello') and not body)
        return '<ul class="basic"><li><span class="trans">你好</span></li></ul>'
    end}))
    assert(public.via == 'public-page' and public.definitions[1] == '你好')
    local function env(key) return ({YOUDAO_APP_KEY = 'key', YOUDAO_APP_SECRET = 'secret'})[key] end
    local options = {env = env, fetch = function(url, body)
        assert(url == 'https://openapi.youdao.com/v2/dict')
        local _, params = http.target('/?' .. body)
        assert(params.q == '学习' and params.dicts == 'ce')
        assert(params.sign == net.sha256('key' .. providers.youdao_input(params.q) .. params.salt .. params.curtime .. 'secret'))
        return json.encode({errorCode = '0', result = {{basic = {explains = {'study'}}}}})
    end}
    assert(providers.lookup('youdao', '学习', options).definitions[1] == 'study')
    assert(not providers.lookup('youdao', 'word', {env = env, fetch = function() return 'bad JSON' end}))
    assert(not providers.lookup('dict.cn', 'word', {fetch = function() return nil, 'timeout' end}))
    assert(not providers.lookup('youdao', 'word', {env = env, fetch = function() return '{"unexpected":true}' end}))
end)

test('SQLite duplicate lookup, literal filtering, notes and injection safety', function()
    local db = DB.open(':memory:', schema)
    local word = "word'); DROP TABLE words;--"
    local first = db:save(word, 'dict.cn', entry(word), 100)
    local second = db:save(word, 'dict.cn', nil, 200)
    assert(first.id == second.id and second.lookup_count == 2 and second.entry and second.first_seen == 100)
    db:save('100%_literal', 'dict.cn', entry('literal'), 300)
    assert(#db:words('%_', false) == 1)
    assert(#db:words('nomatch', false) == 0)
    assert(db:note(first.id, '<script>not executable</script>').saved)
    assert(db:get(word, 'dict.cn').note == '<script>not executable</script>')
    assert(not db:note(999, 'missing'))
    db:close()
end)

test('Review intervals, due boundaries and maximum spacing', function()
    local db = DB.open(':memory:', schema)
    local row = db:save('word', 'dict.cn', entry('word'), 100)
    assert(#db:words('', true, 99) == 0 and #db:words('', true, 100) == 1)
    assert(db:review(row.id, true, 100).due_at == 86500)
    assert(db:review(row.id, true, 100).due_at == 172900)
    assert(db:review(row.id, false, 100).due_at == 700)
    assert(db:get('word', 'dict.cn').streak == 0)
    for _ = 1, 10 do db:review(row.id, true, 100) end
    assert(db:get('word', 'dict.cn').due_at == 100 + 30 * 86400)
    assert(not db:review(999, true, 100)); db:close()
end)

test('Cache expiry, failure history, stale fallback and no Youdao caching', function()
    local db = DB.open(':memory:', schema)
    local calls = 0
    local function provider(_, word) calls = calls + 1; return entry(word) end
    local first = assert(service.search(db, {word = ' HELLO ', source = 'dict.cn'}, provider, 100))
    assert(first.word == 'hello' and not first.cached)
    assert(service.search(db, {word = 'hello'}, provider, 200).cached and calls == 1)
    assert(not service.search(db, {word = 'hello'}, provider, 86500).cached and calls == 2)
    local failed = service.search(db, {word = 'hello'}, function() return nil, 'timeout' end, 200000)
    assert(failed.error == 'timeout' and failed.stale and not failed.saved and not failed.id)
    assert(db:get('hello', 'dict.cn').lookup_count == 3 and db:get('hello', 'dict.cn').last_seen == 86500)
    local crashing = service.search(db, {word = 'new'}, function() error('private internals') end, 200001)
    assert(not crashing.id and not crashing.saved and not db:get('new', 'dict.cn') and not crashing.error:find('private', 1, true))
    for _ = 1, 2 do assert(service.search(db, {word = 'hello', source = 'youdao'}, provider, 200).entry) end
    assert(calls == 4 and not db:get('hello', 'youdao').entry)
    assert(not service.search(db, {word = 'hello', source = 'bad'}, provider))
    db:close()
end)

test('Database restart preserves words, notes and review state', function()
    local path = os.tmpname()
    local db = DB.open(path, schema)
    local row = db:save('persistent', 'dict.cn', entry('persistent'), 100)
    db:note(row.id, 'My meaning'); db:review(row.id, true, 100); db:close()
    db = DB.open(path, schema)
    local saved = db:get('persistent', 'dict.cn')
    assert(saved.note == 'My meaning' and saved.review_count == 1 and saved.due_at == 86500)
    db:close(); os.remove(path)
end)

test('Daily content is deterministic, rolls over at UTC midnight', function()
    local first, same, next_day = content.daily(86400), content.daily(86401), content.daily(172800)
    assert(first.word.word == same.word.word and first.proverb.text == same.proverb.text)
    assert(first.word.word ~= next_day.word.word and first.proverb.text ~= next_day.proverb.text)
    assert(first.date == '1970-01-02')
end)

test('HTTP parser rejects ambiguous headers and decodes query parameters', function()
    assert(http.parse_headers('POST /api/search HTTP/1.1\r\nHost: localhost:8765\r\nContent-Length: 2\r\n\r\n').length == 2)
    for _, raw in ipairs({
        'GET / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n',
        'POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n',
        'POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n',
        'POST / HTTP/1.1\r\nContent-Length: 9000\r\n\r\n',
        'GET https://evil.test/ HTTP/1.1\r\n\r\n'}) do assert(not http.parse_headers(raw)) end
    local path, params = http.target('/api/words?q=%E5%AD%A6%E4%B9%A0+word&due=1')
    assert(path == '/api/words' and params.q == '学习 word' and params.due == '1')
end)

test('API validates notes, review grades, query types and missing rows', function()
    local db = DB.open(':memory:', schema)
    local function status(method, path, payload)
        local _, code = service.route(db, method, path, {}, payload); return code
    end
    assert(status('POST', '/api/search', {word = {}, source = 'dict.cn'}) == 400)
    assert(status('POST', '/api/search', {word = 'a', source = {}}) == 400)
    assert(status('POST', '/api/review', {id = 1, remembered = 'yes'}) == 400)
    assert(status('POST', '/api/review', {id = -1, remembered = true}) == 400)
    assert(status('POST', '/api/review', {id = 1, remembered = true}) == 404)
    assert(status('POST', '/api/note', {id = 1, note = string.rep('a', 4001)}) == 400)
    assert(status('GET', '/api/unknown') == 404)
    db:close()
end)
test('all dictionaries keeps independent successes, errors, caches and lookup counts', function()
    local db = DB.open(':memory:', schema)
    local calls = 0
    local failing = false
    local function provider(source, word)
        calls = calls + 1
        if failing and source == 'youdao' then error('private provider failure') end
        return entry(word)
    end
    local all = assert(service.search(db, {word = ' HELLO ', source = 'all'}, provider, 100))
    assert(all.word == 'hello' and all.source == 'all' and #all.results == 3)
    assert(all.results[1].source == 'local' and all.results[1].error)
    assert(all.results[2].source == 'dict.cn' and all.results[2].entry)
    assert(all.results[3].source == 'youdao' and all.results[3].entry)
    assert(calls == 2 and #db:words() == 2)
    assert(not db:get('hello', 'youdao').entry)
    local again = assert(service.search(db, {word = 'hello', source = 'all'}, provider, 200))
    assert(again.results[2].cached and calls == 3)
    for _, result in ipairs(again.results) do
        if result.entry then assert(result.saved and result.lookup_count == 2)
        else assert(not result.saved and not result.id) end
    end
    failing = true
    local failed = assert(service.search(db, {word = 'hello', source = 'all'}, provider, 300))
    assert(not failed.results[3].saved and not failed.results[3].id and failed.results[3].error)
    assert(not failed.results[3].error:find('private', 1, true))
    assert(db:get('hello', 'youdao').lookup_count == 2)
    assert(not service.search(db, {word = '', source = 'all'}, function() error('must not fetch') end))
    db:close()
end)
test('delete removes only the selected web entry and handles missing IDs', function()
    local db = DB.open(':memory:', schema)
    local first = db:save('hello', 'dict.cn', entry('hello'), 100)
    local second = db:save('hello', 'youdao', nil, 100)
    db:note(first.id, 'To delete'); db:review(first.id, true, 100)
    assert(db:delete(first.id).deleted)
    assert(not db:get('hello', 'dict.cn') and db:get('hello', 'youdao').id == second.id)
    assert(not db:delete(first.id))
    local _, invalid = service.route(db, 'POST', '/api/delete', {}, {id = -1})
    assert(invalid == 400)
    local _, unknown = service.route(db, 'POST', '/api/delete', {}, {id = second.id, collection = 'unknown'})
    assert(unknown == 400)
    local result, code = service.route(db, 'POST', '/api/delete', {}, {id = second.id, collection = 'web'})
    assert(code == 200 and result.deleted and #db:words() == 0)
    db:close()
end)
test('Youdao public parsing handles class tokens, nested formatting and ignores scripts', function()
    local result = assert(providers.parse_youdao_public([[<script>const fake='<ul class="basic"><span class="trans">fake</span></ul>';</script>
        <!-- <ul class="basic"><span class="trans">comment</span></ul> -->
        <span class="phonetic">/ hello /</span><span class="phonetic">/ hullo /</span>
        <ul data-test="value" class='extra basic'><li><span class='trans extra'>你好 &amp; 问候</span></li>
        <li><span class="trans">你好 &amp; 问候</span></li></ul>
        <span class="translation">Unrelated</span><span class="trans">Outside basic section</span>
        <div class="sen-eng">Say <b>hello</b>.</div><div class="sen-ch">说你好。</div>]]))
    assert(#result.definitions == 1 and result.definitions[1] == '你好 & 问候')
    assert(result.phonetic == '/ hello / · / hullo /' and result.examples[1] == 'Say hello. / 说你好。')
    assert(result.via == 'public-page')
    assert(not providers.parse_youdao_public('<html>Verification required</html>'))
    assert(not providers.parse_youdao_public('<ul class="basic"></ul>'))
end)

test('Youdao public parsing supports Chinese queries and phrases', function()
    local chinese = assert(providers.parse_youdao_public([[<ul class="basic"><li><div class="trans-ce"><a>study</a></div>
        <div class="trans-ce"><a>learn</a></div></li></ul>]]))
    assert(chinese.definitions[1] == 'study' and chinese.definitions[2] == 'learn')
    local phrase = assert(providers.parse_youdao_public('<ul class="basic"><li><span class="trans">可供使用</span></li></ul>'))
    assert(phrase.definitions[1] == '可供使用')
end)

test('Youdao falls back after API transport, authentication and parse failures', function()
    for _, kind in ipairs({'transport', 'authentication', 'json', 'empty'}) do
        local calls = 0
        local result = assert(providers.lookup('youdao', 'hello', {env = function() return 'configured-key' end,
            fetch = function(url, body)
                calls = calls + 1
                if url == 'https://openapi.youdao.com/v2/dict' then
                    assert(body)
                    if kind == 'transport' then return nil, 'timeout' end
                    if kind == 'authentication' then return '{"errorCode":"108"}' end
                    if kind == 'json' then return 'not JSON' end
                    return '{"errorCode":"0","result":[]}'
                end
                assert(url == providers.source_url('youdao', 'hello') and not body)
                return '<ul class="basic"><li><span class="trans">你好</span></li></ul>'
            end}))
        assert(calls == 2 and result.via == 'public-page' and result.definitions[1] == '你好')
    end
    local missing, message = providers.lookup('youdao', 'hello', {env = function() return nil end,
        fetch = function() return nil, 'HTTP 403' end})
    assert(not missing and message == 'HTTP 403')
end)
test('missing, empty, whitespace-only and malformed definitions never create history', function()
    local db = DB.open(':memory:', schema)
    for _, value in ipairs({false, {}, {definitions = {}}, {definitions = {'', '   '}}, {definitions = {false, 42}}}) do
        local result = assert(service.search(db, {word = 'missing', source = 'dict.cn'}, function()
            if value == false then return nil, 'Not found' end
            return value
        end))
        assert(not result.saved and not result.id and result.error and #db:words() == 0)
    end
    local all = assert(service.search(db, {word = 'missing', source = 'all'}, function() return nil, 'Not found' end))
    for _, result in ipairs(all.results) do assert(not result.saved and not result.id) end
    assert(#db:words() == 0)
    db:close()
end)

test('failed refresh preserves every existing history field and does not change reviews', function()
    local db = DB.open(':memory:', schema)
    local row = db:save('saved', 'dict.cn', entry('saved'), 100)
    db:note(row.id, 'Keep this note'); db:review(row.id, true, 100)
    local before = db:get('saved', 'dict.cn')
    local failed = assert(service.search(db, {word = 'saved', source = 'dict.cn'}, function() return nil, 'Not found' end, 100000))
    assert(not failed.saved and not failed.id and failed.stale)
    local after = db:get('saved', 'dict.cn')
    for key, value in pairs(before) do assert(after[key] == value, 'Changed existing field: ' .. key) end
    db:close()
end)

test('prefix suggestions return matching words and handle empty queries', function()
    local db = DB.open(':memory:', schema)
    db:save('apple', 'dict.cn', entry('apple'), 100)
    db:save('application', 'dict.cn', entry('application'), 200)
    db:save('banana', 'dict.cn', entry('banana'), 150)
    local empty = assert(service.route(db, 'GET', '/api/suggest', {q = ''}))
    assert(#empty.suggestions == 0)
    local app = assert(service.route(db, 'GET', '/api/suggest', {q = 'app'}))
    assert(#app.suggestions == 2)
    local ban = assert(service.route(db, 'GET', '/api/suggest', {q = 'ban'}))
    assert(#ban.suggestions == 1 and ban.suggestions[1].word == 'banana')
    local nomatch = assert(service.route(db, 'GET', '/api/suggest', {q = 'xyz'}))
    assert(#nomatch.suggestions == 0)
    db:close()
end)
print('Passed ' .. count .. ' tests.')
