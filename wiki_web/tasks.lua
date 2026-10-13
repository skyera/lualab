-- Markdown task extraction with source positions, code exclusion and due dates.
local M = {}

--------------------------------------------------------------------------------
-- Dates and task lines
--------------------------------------------------------------------------------

local function valid_date(value)
    local year, month, day = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or year < 1 or month < 1 or month > 12 then return false end
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then days[2] = 29 end
    return day >= 1 and day <= days[month]
end

function M.parse(text)
    local result, fence, offset, number = {}, nil, 1, 0
    for raw in (text .. '\n'):gmatch('(.-)\n') do
        number = number + 1
        local line = raw:gsub('\r$', '')
        local marker = line:match('^ ? ? ?(```+)') or line:match('^ ? ? ?(~~~+)')
        if marker then
            if not fence then fence = marker
            elseif marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence
                and line:match('^%s*[`~]+%s*$') then fence = nil end
        elseif not fence and not line:match('^    ') and not line:match('^\t') then
            local prefix, checked, label = line:match('^( *[-+*]%s+%[)([ xX])%]%s+(.*)$')
            if not prefix then
                prefix, checked, label = line:match('^( *%d+[.)]%s+%[)([ xX])%]%s+(.*)$')
            end
            if prefix then
                local due = ''
                for value in (' ' .. label .. ' '):gmatch('%sdue:([^%s]+)') do
                    if valid_date(value) then due = value; break end
                end
                result[#result + 1] = { line = number, text = label, done = checked ~= ' ',
                    due = due, position = offset + #prefix }
            end
        end
        offset = offset + #raw + 1
    end
    return result
end

return M
