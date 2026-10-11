-- Original learning notes. Daily selections are independent of provider feeds.
local words = {
    {'serendipity', 'A fortunate discovery made by chance.', 'A wrong turn led us to a wonderful café: pure serendipity.'},
    {'resilient', 'Able to recover after difficulty.', 'The resilient garden grew again after the storm.'},
    {'curiosity', 'A desire to learn or understand.', 'Her curiosity led her to study the night sky.'},
    {'eloquent', 'Expressing ideas clearly and beautifully.', 'His eloquent speech made a complex idea easy to understand.'},
    {'tranquil', 'Calm and peaceful.', 'The lake was tranquil before sunrise.'},
    {'perseverance', 'Continuing to work despite difficulty.', 'Learning a language takes practice and perseverance.'},
    {'ephemeral', 'Lasting only a short time.', 'The rainbow was beautiful but ephemeral.'},
    {'thoughtful', 'Showing careful consideration or kindness.', 'Leaving a welcoming note was a thoughtful gesture.'},
    {'vivid', 'Clear, bright, or full of detail.', 'She gave a vivid description of the mountain trail.'},
    {'versatile', 'Useful in many different situations.', 'This versatile tool works in the kitchen and garden.'},
    {'diligent', 'Working with steady care and effort.', 'The diligent student reviewed a few words every day.'},
    {'wanderlust', 'A strong desire to travel.', 'The map awakened his wanderlust.'},
}
local proverbs = {
    {'Practice makes perfect.', '熟能生巧。', 'Regular practice helps you improve. Review a few words every day.'},
    {'A journey of a thousand miles begins with a single step.', '千里之行，始于足下。', 'Start with one small action, even when your goal feels far away.'},
    {'Where there is a will, there is a way.', '有志者事竟成。', 'Determination helps you find a path through obstacles.'},
    {'Actions speak louder than words.', '行动胜于言语。', 'What you do demonstrates your intentions more clearly than promises.'},
    {'Better late than never.', '迟做总比不做好。', 'Starting late is still better than giving up before you start.'},
    {'Many hands make light work.', '众人拾柴火焰高。', 'Sharing a task makes it easier for everyone.'},
    {'Look before you leap.', '三思而后行。', 'Consider the consequences before making a decision.'},
}
local json = require('json')
local M = {}

function M.daily(stamp)
    stamp = stamp or os.time()
    local day = math.floor(stamp / 86400)
    local word = words[day % #words + 1]
    local proverb = proverbs[day % #proverbs + 1]
    return {
        date = os.date('!%Y-%m-%d', stamp),
        word = {
            word = word[1],
            meaning = word[2],
            example = word[3],
        },
        proverb = {
            text = proverb[1],
            chinese = proverb[2],
            explanation = proverb[3],
        },
    }
end

function M.random_word()
    local idx = math.random(1, #words)
    local item = words[idx]
    return {
        word = item[1],
        meaning = item[2],
        example = item[3],
    }
end

function M.fetch_online(fetch_fn, date_str)
    if not fetch_fn then return nil, 'No fetch function provided' end
    local url = 'https://open.iciba.com/dsapi/' .. (date_str and ('?date=' .. date_str) or '')
    local ok, res, code = pcall(fetch_fn, url)
    if not ok or not res or (code ~= nil and code ~= 200) then
        return nil, 'Failed to fetch online proverb'
    end
    local parse_ok, data = pcall(json.decode, res)
    if not parse_ok or type(data) ~= 'table' or not data.content or data.content == '' then
        return nil, 'Invalid response from proverb service'
    end
    local audio = (data.tts and data.tts ~= '') and data.tts or nil
    if audio and audio:sub(1, 7) == 'http://' then
        audio = 'https://' .. audio:sub(8)
    end
    return {
        text = data.content,
        chinese = data.note or '',
        explanation = (data.translation and data.translation ~= '' and data.translation ~= '新版每日一句') and data.translation or '',
        audio_url = audio,
    }
end

function M.fetch_zenquotes(fetch_fn)
    if not fetch_fn then return nil, 'No fetch function provided' end
    local ok, res, code = pcall(fetch_fn, 'https://zenquotes.io/api/random')
    if not ok or not res or (code ~= nil and code ~= 200) then return nil end
    local parse_ok, data = pcall(json.decode, res)
    if not parse_ok or type(data) ~= 'table' or not data[1] or not data[1].q then return nil end
    local item = data[1]
    return {
        text = item.q,
        chinese = '',
        explanation = (item.a and item.a ~= '') and ('— ' .. item.a .. ' · ZenQuotes') or 'ZenQuotes',
        audio_url = nil,
    }
end

function M.fetch_dummyjson(fetch_fn)
    if not fetch_fn then return nil, 'No fetch function provided' end
    local ok, res, code = pcall(fetch_fn, 'https://dummyjson.com/quotes/random')
    if not ok or not res or (code ~= nil and code ~= 200) then return nil end
    local parse_ok, data = pcall(json.decode, res)
    if not parse_ok or type(data) ~= 'table' or not data.quote then return nil end
    return {
        text = data.quote,
        chinese = '',
        explanation = (data.author and data.author ~= '') and ('— ' .. data.author .. ' · Quotes') or 'Quotes',
        audio_url = nil,
    }
end

function M.fetch_favqs(fetch_fn)
    if not fetch_fn then return nil, 'No fetch function provided' end
    local ok, res, code = pcall(fetch_fn, 'https://favqs.com/api/qotd')
    if not ok or not res or (code ~= nil and code ~= 200) then return nil end
    local parse_ok, data = pcall(json.decode, res)
    if not parse_ok or type(data) ~= 'table' or not data.quote or not data.quote.body then return nil end
    local q = data.quote
    local author = q.author and q.author ~= '' and ('— ' .. q.author) or ''
    return {
        text = q.body,
        chinese = '',
        explanation = author ~= '' and (author .. ' · FavQs') or 'FavQs',
        audio_url = nil,
    }
end

function M.fetch_wikiquote(fetch_fn)
    if not fetch_fn then return nil, 'No fetch function provided' end
    local url = 'https://en.wikiquote.org/w/api.php?action=parse&format=json&page=English_proverbs&prop=text'
    local ok, res, code = pcall(fetch_fn, url)
    if not ok or not res or (code ~= nil and code ~= 200) then return nil end
    local parse_ok, data = pcall(json.decode, res)
    if not parse_ok or type(data) ~= 'table' or not data.parse or not data.parse.text or not data.parse.text['*'] then
        return nil
    end
    local html = data.parse.text['*']
    local proverbs_list = {}
    for li in html:gmatch('<li>(.-)</li>') do
        local clean_text = li:gsub('<[^>]+>', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
        clean_text = clean_text:gsub('^["“”\']', ''):gsub('["“”\']$', '')
        if #clean_text >= 15 and #clean_text <= 140 and not clean_text:find('^Adapted') and not clean_text:find('^Source') then
            proverbs_list[#proverbs_list + 1] = clean_text
        end
    end
    if #proverbs_list == 0 then return nil end
    local selected = proverbs_list[math.random(1, #proverbs_list)]
    return {
        text = selected,
        chinese = '',
        explanation = 'English Proverb · Wikiquote',
        audio_url = nil,
    }
end

function M.fetch_quote(fetch_fn, source)
    if source == 'zenquotes' then return M.fetch_zenquotes(fetch_fn) end
    if source == 'dummyjson' then return M.fetch_dummyjson(fetch_fn) end
    if source == 'favqs' then return M.fetch_favqs(fetch_fn) end
    if source == 'wikiquote' then return M.fetch_wikiquote(fetch_fn) end
    if source == 'iciba' then return M.fetch_online(fetch_fn) end
    -- Randomly choose among available quote services
    local choices = {M.fetch_online, M.fetch_zenquotes, M.fetch_dummyjson, M.fetch_favqs, M.fetch_wikiquote}
    local start_idx = math.random(1, #choices)
    for i = 0, #choices - 1 do
        local fn = choices[(start_idx + i - 1) % #choices + 1]
        local quote = fn(fetch_fn)
        if quote and quote.text and quote.text ~= '' then
            return quote
        end
    end
    return nil
end

return M
