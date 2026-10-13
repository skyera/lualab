-- Search query parser, tag/path filtering and contextual snippet extraction.
local links = require('links')
local M = {}

--------------------------------------------------------------------------------
-- Query parsing and normalization
--------------------------------------------------------------------------------

local function clean_path(p)
    return (p:gsub(':', '/'):gsub('^/+', ''):gsub('/+$', ''))
end

function M.parse(str)
    local tags, paths, terms = {}, {}, {}
    if not str or str == '' then return { tags = tags, paths = paths, terms = terms } end
    local i = 1
    while i <= #str do
        local s, e = str:find('%S+', i)
        if not s then break end
        local prefix, quote = str:match('^(%w+):([\"\'])', s)
        if prefix and quote then
            prefix = prefix:lower()
            local qend = str:find(quote, s + #prefix + 2, true)
            if qend then
                local val = str:sub(s + #prefix + 2, qend - 1)
                if prefix == 'tag' then tags[#tags + 1] = val:lower():gsub('^#', '')
                elseif prefix == 'path' then paths[#paths + 1] = clean_path(val) end
                i = qend + 1
            else
                local val = str:sub(s + #prefix + 2)
                if prefix == 'tag' then tags[#tags + 1] = val:lower():gsub('^#', '')
                elseif prefix == 'path' then paths[#paths + 1] = clean_path(val) end
                break
            end
        elseif str:sub(s, s) == '"' or str:sub(s, s) == "'" then
            local q = str:sub(s, s)
            local qend = str:find(q, s + 1, true)
            if qend then
                local val = str:sub(s + 1, qend - 1)
                if #val > 0 then terms[#terms + 1] = val end
                i = qend + 1
            else
                local val = str:sub(s + 1)
                if #val > 0 then terms[#terms + 1] = val end
                break
            end
        else
            local word = str:sub(s, e)
            local tag = word:match('^[Tt][Aa][Gg]:(.+)$')
            local path_val = word:match('^[Pp][Aa][Tt][Hh]:(.+)$')
            local hash_tag = word:match('^#([%w_\128-\255][%w_%-\128-\255]*)$')
            if tag then tags[#tags + 1] = tag:lower():gsub('^#', '')
            elseif hash_tag then tags[#tags + 1] = hash_tag:lower()
            elseif path_val then paths[#paths + 1] = clean_path(path_val)
            else terms[#terms + 1] = word end
            i = e + 1
        end
    end
    return { tags = tags, paths = paths, terms = terms }
end

--------------------------------------------------------------------------------
-- Tag and path matching
--------------------------------------------------------------------------------

function M.matches_tags(page_tags, query_tags)
    if not query_tags or #query_tags == 0 then return true end
    if not page_tags or #page_tags == 0 then return false end
    local set = {}
    for _, t in ipairs(page_tags) do set[t:lower()] = true end
    for _, q in ipairs(query_tags) do
        if not set[q:lower()] then return false end
    end
    return true
end

--------------------------------------------------------------------------------
-- Contextual snippet extraction
--------------------------------------------------------------------------------

function M.snippet(content, terms)
    if not content or content == '' then return '' end
    local lower_content = content:lower()
    local best_pos, best_len
    if terms and #terms > 0 then
        for _, term in ipairs(terms) do
            if #term > 0 then
                local pos = lower_content:find(term:lower(), 1, true)
                if pos and (not best_pos or pos < best_pos) then
                    best_pos = pos
                    best_len = #term
                end
            end
        end
    end
    if best_pos then
        local s = math.max(1, best_pos - 45)
        local e = math.min(#content, best_pos + best_len + 65)
        if s > 1 then
            local space = content:find('%s', s, true)
            if space and space < best_pos then s = space + 1 end
        end
        if e < #content then
            local rev_space = content:sub(1, e):match('.*()%s')
            if rev_space and rev_space > best_pos + best_len then e = rev_space - 1 end
        end
        while s > 1 and content:byte(s) >= 128 and content:byte(s) < 192 do s = s - 1 end
        while e < #content and content:byte(e + 1) >= 128 and content:byte(e + 1) < 192 do e = e + 1 end
        local piece = content:sub(s, e):gsub('[\r\n]+', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
        if s > 1 then piece = '… ' .. piece end
        if e < #content then piece = piece .. ' …' end
        return piece
    else
        local e = math.min(#content, 140)
        while e < #content and content:byte(e + 1) >= 128 and content:byte(e + 1) < 192 do e = e + 1 end
        local piece = content:sub(1, e):gsub('[\r\n]+', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
        if #content > e then piece = piece .. ' …' end
        return piece
    end
end

return M
