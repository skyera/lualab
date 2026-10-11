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

return M
