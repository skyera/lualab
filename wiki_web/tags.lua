--------------------------------------------------------------------------------
-- tags.lua
-- Inline notebook hashtags outside Markdown code; ASCII case normalization and
-- UTF-8 tag names. Tags remain part of ordinary Markdown, without sidecar files.
--------------------------------------------------------------------------------

local links = require('links')

local M = {}

function M.parse(text)
    local found = {}
    links.prose(text, function(piece)
        for tag in (' ' .. piece):gmatch('%s#([%w_\128-\255][%w_%-\128-\255]*)') do
            if #tag <= 64 and links.valid_utf8(tag) then
                found[tag:lower()] = true
            end
        end
        return piece
    end)
    local result = {}
    for tag in pairs(found) do
        result[#result + 1] = tag
    end
    table.sort(result)
    return result
end

return M
