-- Quick-capture validation and Markdown formatting for dated journal pages.
local links = require('links')
local M = {}
local WEEKDAYS = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }

--------------------------------------------------------------------------------
-- Validate the destination and format a single appended entry
--------------------------------------------------------------------------------

function M.entry(date, text, kind)
    assert(type(date) == 'string', 'Capture date is required')
    local year, month, day = date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    assert(year and year >= 1970 and month >= 1 and month <= 12 and day >= 1 and day <= 31,
        'Invalid capture date; use YYYY-MM-DD (1970 or later)')
    local stamp = os.time({ year = year, month = month, day = day, hour = 12 })
    assert(stamp and os.date('%Y-%m-%d', stamp) == date, 'Invalid capture date')
    assert(type(text) == 'string' and #text <= 16000 and text:find('%S')
        and not text:find('%z') and links.valid_utf8(text), 'Capture must contain UTF-8 text up to 16000 bytes')
    assert(kind == 'note' or kind == 'task', 'Capture kind must be note or task')
    text = text:gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('\n+$', '')
    if kind == 'task' then text = '- [ ] ' .. text:gsub('\n', '\n  ') end
    local id = 'Journal/' .. date:sub(1, 4) .. '/' .. date:sub(6, 7) .. '/' .. date
    local heading = '# ' .. date .. ' ' .. WEEKDAYS[tonumber(os.date('%w', stamp)) + 1]
    return id, heading, text
end

return M
