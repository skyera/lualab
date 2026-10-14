-- Wiki link parsing: absolute namespaces and explicit ./ or ../ relative links.
local M = {}

function M.valid_utf8(text)
    if type(text) ~= 'string' then return false end
    local bytes = 0
    for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local first, second = char:byte(1, 2)
        local expected = first < 128 and 1 or first < 224 and 2 or first < 240 and 3 or 4
        if #char ~= expected or (first == 224 and second < 160) or (first == 237 and second >= 160)
            or (first == 240 and second < 144) or (first == 244 and second >= 144) then return false end
        bytes = bytes + #char
    end
    return bytes == #text
end

function M.page_id(value)
    if not M.valid_utf8(value) or #value > 240 or value == '' or value:find('[%z\1-\31\127\\:#%[%]|]')
        or value:sub(1, 1) == '/' or value:sub(-1) == '/' or value:find('//', 1, true) then return nil end
    local count = 0
    for part in value:gmatch('[^/]+') do
        count = count + 1
        if part:sub(1, 1) == '.' or part:match('^%s') or part:match('%s$')
            or part:match('%.attachments$') then return nil end
        if package.config:sub(1, 1) == '\\' then
            local stem = part:match('^([^.]*)'):upper()
            if part:find('[<>"|?*]') or part:match('[ .]$') or stem == 'CON' or stem == 'PRN'
                or stem == 'AUX' or stem == 'NUL' or stem:match('^COM[1-9]$')
                or stem:match('^LPT[1-9]$') then return nil end
        end
    end
    return count <= 16 and value or nil
end

function M.resolve(source, target)
    local name, anchor = target:match('^([^#]*)#?(.*)$')
    name = name:gsub(':', '/'):gsub('^/', '')
    if name == '' and anchor ~= '' then return source, anchor end
    if name:sub(1, 2) == './' or name:sub(1, 3) == '../' then
        name = (source:match('^(.*)/') or '') .. '/' .. name
        local parts = {}
        for part in name:gmatch('[^/]+') do
            if part == '..' then
                if #parts == 0 then return nil end
                table.remove(parts)
            elseif part ~= '.' then parts[#parts + 1] = part end
        end
        name = table.concat(parts, '/')
    end
    return M.page_id(name), anchor
end

-- Only transform prose; fenced code and inline backtick spans stay untouched.
function M.prose(text, transform)
    local result, fence = {}, nil
    for line in (text .. '\n'):gmatch('(.-)\n') do
        local marker = line:match('^ ? ? ?(```+)') or line:match('^ ? ? ?(~~~+)')
        if marker then
            if not fence then fence = marker
            elseif fence:sub(1, 1) == marker:sub(1, 1) and #marker >= #fence
                and line:match('^%s*[`~]+%s*$') then fence = nil end
            result[#result + 1] = line
        elseif fence or line:match('^    ') or line:match('^\t') then result[#result + 1] = line
        else
            local pieces, start = {}, 1
            while true do
                local first, last, ticks = line:find('(`+)', start)
                if not first then pieces[#pieces + 1] = transform(line:sub(start)); break end
                pieces[#pieces + 1] = transform(line:sub(start, first - 1))
                local ending = line:find(ticks, last + 1, true)
                if not ending then pieces[#pieces + 1] = transform(line:sub(first)); break end
                pieces[#pieces + 1] = line:sub(first, ending + #ticks - 1)
                start = ending + #ticks
            end
            result[#result + 1] = table.concat(pieces)
        end
    end
    return table.concat(result, '\n')
end

function M.targets(source, text)
    local found = {}
    M.prose(text, function(piece)
        for inner in piece:gmatch('%[%[([^%[%]]+)%]%]') do
            local target = M.resolve(source, inner:match('^([^|]+)') or inner)
            if target then found[target] = true end
        end
        return piece
    end)
    return found
end

function M.rename(text, source, old, new)
    return M.prose(text, function(piece)
        return (piece:gsub('%[%[([^%[%]]+)%]%]', function(inner)
            local address, label = inner:match('^([^|]+)(|.*)$')
            address = address or inner
            local target, anchor = M.resolve(source, address)
            if not target then return '[[' .. inner .. ']]' end
            if target == old then target = new
            elseif source ~= old then return '[[' .. inner .. ']]' end
            return '[[' .. target:gsub('/', ':') .. (anchor ~= '' and '#' .. anchor or '') .. (label or '') .. ']]'
        end))
    end)
end

-- Resolve against the original source and apply every destination in one pass.
function M.relocate(text, source, mapping)
    return M.prose(text, function(piece)
        return (piece:gsub('%[%[([^%[%]]+)%]%]', function(inner)
            local address, label = inner:match('^([^|]+)(|.*)$')
            address = address or inner
            local target, anchor = M.resolve(source, address)
            if not target or (not mapping[source] and not mapping[target]) then return '[[' .. inner .. ']]' end
            target = mapping[target] or target
            return '[[' .. target:gsub('/', ':') .. (anchor ~= '' and '#' .. anchor or '') .. (label or '') .. ']]'
        end))
    end)
end
return M
