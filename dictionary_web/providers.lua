local json = require('json')
local net = require('net')
local M = {sources = {'dict.cn', 'youdao'}}

function M.source_url(source, word)
    local encoded = net.encode(word)
    if source == 'dict.cn' then return 'https://dict.cn/' .. encoded end
    if source == 'youdao' then return 'https://www.youdao.com/result?word=' .. encoded .. '&lang=en' end
    return nil
end

local function utf8(code)
    if code < 128 then return string.char(code) end
    if code < 2048 then return string.char(192 + math.floor(code / 64), 128 + code % 64) end
    if code < 65536 then
        return string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
    end
    return string.char(240 + math.floor(code / 262144), 128 + math.floor(code / 4096) % 64,
        128 + math.floor(code / 64) % 64, 128 + code % 64)
end

local entities = {amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", nbsp = ' ',
    rsquo = '’', lsquo = '‘', ndash = '–', mdash = '—'}
local function clean(text)
    text = text:gsub('<[bB][rR]%s*/?>', ' / '):gsub('<[^>]*>', '')
    text = text:gsub('&(#?[%w]+);', function(entity)
        if entities[entity] then return entities[entity] end
        local code = entity:sub(1, 2):lower() == '#x' and tonumber(entity:sub(3), 16)
            or entity:sub(1, 1) == '#' and tonumber(entity:sub(2))
        if code and code >= 0 and code <= 0x10ffff and not (code >= 0xd800 and code <= 0xdfff) then return utf8(code) end
        return '&' .. entity .. ';'
    end)
    return (text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end
M.clean = clean

function M.parse_dict(html)
    local basic = html:match('<ul[^>]*class=["\'][^"\']*dict%-basic%-ul[^"\']*["\'][^>]*>(.-)</ul>')
    -- Phrase entries omit dict-basic-ul but retain the enclosing basic block.
    if not basic then
        basic = html:match('<div[^>]*class=["\']basic clearfix["\'][^>]*>%s*<ul[^>]*>(.-)</ul>')
    end
    local definitions, phonetics, examples = {}, {}, {}
    for definition in (basic or ''):gmatch('<strong[^>]*>(.-)</strong>') do
        local text = clean(definition)
        if text ~= '' and #definitions < 12 then definitions[#definitions + 1] = text end
    end
    -- Chinese-to-English pages put basic translations in a separate layout.
    local chinese = html:match('<div[^>]*class=["\']layout cn["\'][^>]*>(.-)</ul>')
    if #definitions == 0 then
        for definition in (chinese or ''):gmatch('<li[^>]*>(.-)</li>') do
            local text = clean(definition)
            if text ~= '' and #definitions < 12 then definitions[#definitions + 1] = text end
        end
    end
    if #definitions == 0 then return nil, 'No definition found on dict.cn. Try another word or open the source page.' end
    local seen = {}
    local pronunciation = html:match('<div[^>]*class=["\']phonetic["\'][^>]*>(.-)</div>')
    if chinese and (not pronunciation or not pronunciation:find('<bdo', 1, true)) then
        pronunciation = html:match('<div[^>]*class=["\']layout ref["\'][^>]*>(.-)</dt>')
    end
    for phonetic in (pronunciation or ''):gmatch('<bdo[^>]*>(.-)</bdo>') do
        local text = clean(phonetic)
        if not seen[text] and #phonetics < 2 then phonetics[#phonetics + 1] = text; seen[text] = true end
    end
    local sentences = html:match('<div[^>]*class=["\']section sent["\'][^>]*>(.-)</ol>')
    for sentence in (sentences or ''):gmatch('<li[^>]*>(.-)</li>') do
        if #examples < 4 then examples[#examples + 1] = clean(sentence) end
    end
    local synonyms, syn_seen = {}, {}
    local rel_section = html:match('<div[^>]*class=["\'][^"\']*rel[^"\']*["\'][^>]*>(.-)</div>')
        or html:match('<div[^>]*class=["\'][^"\']*ncs[^"\']*["\'][^>]*>(.-)</div>')
    for syn in (rel_section or ''):gmatch('<a[^>]*>(.-)</a>') do
        local text = clean(syn)
        if text ~= '' and not syn_seen[text:lower()] and #synonyms < 8 then
            syn_seen[text:lower()] = true
            synonyms[#synonyms + 1] = text
        end
    end
    return {
        definitions = definitions,
        phonetic = table.concat(phonetics, ' · '),
        examples = examples,
        synonyms = #synonyms > 0 and synonyms or nil,
    }
end

function M.parse_youdao(data)
    if type(data) ~= 'table' then return nil, 'Invalid response from Youdao.' end
    if data.errorCode and tostring(data.errorCode) ~= '0' then
        return nil, 'Youdao error ' .. tostring(data.errorCode) .. '. Check your account and dictionary service access.'
    end
    local definitions, examples, phonetic, seen = {}, {}, '', {}
    local synonyms, syn_seen = {}, {}
    local function add(value)
        if type(value) == 'string' then
            local text = clean(value)
            if text ~= '' and not seen[text] and #definitions < 12 then
                definitions[#definitions + 1] = text
                seen[text] = true
            end
        elseif type(value) == 'table' then
            for _, item in ipairs(value) do add(item) end
        end
    end
    local function add_syn(w)
        if type(w) == 'string' then
            local text = clean(w)
            if text ~= '' and not syn_seen[text:lower()] and #synonyms < 8 then
                syn_seen[text:lower()] = true
                synonyms[#synonyms + 1] = text
            end
        elseif type(w) == 'table' then
            for _, item in ipairs(w) do add_syn(item) end
        end
    end
    local function walk(node)
        if type(node) ~= 'table' then return end
        if type(node.sentence) == 'string' and #examples < 4 then
            examples[#examples + 1] = clean(node.sentence) .. (type(node.translation) == 'string' and ' / ' .. clean(node.translation) or '')
        end
        for key, value in pairs(node) do
            if key == 'phonetic' and type(value) == 'string' and phonetic == '' then
                phonetic = value
            end
            if key == 'explains' or key == 'explain' or key == 'trans' or key == 'i' then
                add(value)
            elseif key == 'syno' or key == 'synonyms' then
                if type(value) == 'table' then
                    for _, item in ipairs(value) do
                        if type(item) == 'table' and item.ws then
                            add_syn(item.ws)
                        elseif type(item) == 'string' then
                            add_syn(item)
                        end
                    end
                end
            elseif type(value) == 'table' then
                walk(value)
            end
        end
    end
    walk(data.result or data.data or data)
    if #definitions == 0 then
        return nil, 'Youdao returned no readable definitions. Open the source page for the full entry.'
    end
    return {
        definitions = definitions,
        phonetic = phonetic,
        examples = examples,
        synonyms = #synonyms > 0 and synonyms or nil,
    }
end

function M.youdao_input(word)
    local chars = {}
    for char in word:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = char end
    if #chars <= 20 then return word end
    return table.concat(chars, '', 1, 10) .. #chars .. table.concat(chars, '', #chars - 9)
end

local function class_elements(html, tag, class_name, limit)
    local values, position = {}, 1
    while #values < (limit or 12) do
        local first, last, attrs = html:find('<' .. tag .. '(%s[^>]*)>', position)
        if not first then break end
        position = last + 1
        local classes = attrs:match('class%s*=%s*["\']([^"\']*)["\']') or ''
        local matches = false
        for token in classes:gmatch('%S+') do
            if token == class_name then
                matches = true
                break
            end
        end
        if matches then
            local finish, ending = html:find('</' .. tag .. '%s*>', position)
            if finish then
                values[#values + 1] = html:sub(position, finish - 1)
                position = ending + 1
            end
        end
    end
    return values
end

function M.parse_youdao_public(html)
    -- Ignore JavaScript, CSS and comments; only inspect server-rendered content.
    html = html:gsub('<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>', '')
        :gsub('<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>', '')
        :gsub('<!%-%-.-%-%->', '')
    local basic = class_elements(html, 'ul', 'basic', 1)[1]
    if not basic then
        return nil, 'No definition found on Youdao’s public page. Open the source page or try another dictionary.'
    end
    local definitions, phonetics, examples, seen = {}, {}, {}, {}
    local function add(text)
        text = clean(text)
        if text ~= '' and not seen[text] and #definitions < 12 then
            definitions[#definitions + 1] = text
            seen[text] = true
        end
    end
    for _, text in ipairs(class_elements(basic, 'span', 'trans')) do
        add(text)
    end
    -- Chinese queries have linked English translations instead of trans spans.
    if #definitions == 0 then
        for _, text in ipairs(class_elements(basic, 'div', 'trans-ce')) do
            add(text)
        end
    end
    if #definitions == 0 then
        return nil, 'No definition found on Youdao’s public page. Open the source page or try another dictionary.'
    end
    for _, text in ipairs(class_elements(html, 'span', 'phonetic', 2)) do
        phonetics[#phonetics + 1] = clean(text)
    end
    local english = class_elements(html, 'div', 'sen-eng', 4)
    local chinese = class_elements(html, 'div', 'sen-ch', 4)
    for index, text in ipairs(english) do
        examples[#examples + 1] = clean(text) .. (chinese[index] and ' / ' .. clean(chinese[index]) or '')
    end
    return {
        definitions = definitions,
        phonetic = table.concat(phonetics, ' · '),
        examples = examples,
        via = 'public-page',
    }
end

local function decorate(entry, source, word)
    entry.word, entry.source, entry.source_url = word, source, M.source_url(source, word)
    return entry
end

local function youdao_public_lookup(word, fetch)
    local raw, message = fetch(M.source_url('youdao', word))
    if not raw then return nil, message end
    local ok, entry, err = pcall(M.parse_youdao_public, raw)
    if not ok then
        return nil, 'Youdao’s public page could not be read. Open the source page for this word.'
    end
    if not entry then return nil, err end
    return decorate(entry, 'youdao', word)
end

local function nonce()
    local file = assert(io.open('/dev/urandom', 'rb'))
    local bytes = assert(file:read(16))
    file:close()
    return (bytes:gsub('.', function(char) return string.format('%02x', char:byte()) end))
end

function M.lookup(source, word, options)
    options = options or {}
    local fetch = options.fetch or net.fetch
    local env = options.env or os.getenv
    local url, body, parser
    if source == 'dict.cn' then
        url, parser = M.source_url(source, word), M.parse_dict
    elseif source == 'youdao' then
        local key, secret = env('YOUDAO_APP_KEY'), env('YOUDAO_APP_SECRET')
        if not key or key == '' or not secret or secret == '' then
            return youdao_public_lookup(word, fetch)
        end
        local salt, stamp = nonce(), tostring(os.time())
        local sign = net.sha256(key .. M.youdao_input(word) .. salt .. stamp .. secret)
        body = net.form({q = word, langType = 'auto', dicts = word:find('[\228-\233]') and 'ce' or 'ec',
            appKey = key, salt = salt, curtime = stamp, sign = sign, signType = 'v3', docType = 'json'})
        url, parser = 'https://openapi.youdao.com/v2/dict', M.parse_youdao
    else
        return nil, 'Unknown dictionary source.'
    end
    local raw, message = fetch(url, body)
    if not raw then
        if source == 'youdao' then return youdao_public_lookup(word, fetch) end
        return nil, message
    end
    local data = raw
    if source ~= 'dict.cn' then
        local ok, decoded = pcall(json.decode, raw)
        if not ok then
            if source == 'youdao' then return youdao_public_lookup(word, fetch) end
            return nil, 'The dictionary returned an invalid response.'
        end
        data = decoded
    end
    local ok, entry, err = pcall(parser, data)
    if source == 'youdao' and (not ok or not entry) then return youdao_public_lookup(word, fetch) end
    if not ok then return nil, 'The dictionary returned an unexpected response.' end
    if not entry then return nil, err end
    if source == 'youdao' then entry.via = 'api' end
    return decorate(entry, source, word)
end
return M
