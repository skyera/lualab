#!/usr/bin/env luajit
-- lua_highlight.lua: split Lua source into highlighted spans.
--
-- highlight_lines(lines) returns, for each line, an array of
-- { text = ..., kind = ... } spans whose texts join back into exactly
-- that line. Kinds: keyword, constant, builtin, string, number, comment
-- and plain. Long strings and long comments ([[ ]], [==[ ]==],
-- --[[ ]]) carry over to the following lines, so a whole file should be
-- highlighted at once. Pure Lua, no terminal output.

local M = {}

-- =========================================================================
-- Constants
-- =========================================================================

local KEYWORDS = {}
for word in ([[and break do else elseif end for function goto if in local
    not or repeat return then until while]]):gmatch("%a+") do
    KEYWORDS[word] = true
end

-- Values rather than control flow; `self` is included as editors do.
local CONSTANTS = { ["nil"] = true, ["true"] = true, ["false"] = true,
    self = true }

local BUILTINS = {}
for word in ([[assert collectgarbage dofile error getmetatable ipairs load
    loadfile loadstring next pairs pcall print rawequal rawget rawlen rawset
    require select setmetatable tonumber tostring type unpack xpcall
    string table math io os coroutine debug package bit jit ffi arg
    _G]]):gmatch("[%w_]+") do
    BUILTINS[word] = true
end

-- Number forms, tried in order at a digit or at "." followed by a digit.
local NUMBER_PATTERNS = {
    "^0[xX][%x%.]*[pP][+-]?%d+",
    "^0[xX][%x%.]*",
    "^%d+%.?%d*[eE][+-]?%d+",
    "^%.%d+[eE][+-]?%d+",
    "^%d+%.?%d*",
    "^%.%d+",
}
local NUMBER_SUFFIX = "^[uUlLi]+" -- LuaJIT 64-bit and imaginary literals

-- =========================================================================
-- Helpers
-- =========================================================================

local function add_span(spans, text, kind)
    if text == "" then
        return
    end
    local last = spans[#spans]
    if last and last.kind == kind then
        last.text = last.text .. text
        return
    end
    spans[#spans + 1] = { text = text, kind = kind }
end

--- Find the end of a long bracket closed by `close` in `line` from
--- `start`. Returns the index of its last character, or nil.
local function find_long_close(line, start, close)
    local _, last = line:find(close, start, true)
    return last
end

--- Return the end index of a quoted string that starts at `start`.
--- An unterminated string ends at the end of the line.
local function find_quote_end(line, start)
    local quote = line:sub(start, start)
    local position = start + 1
    while position <= #line do
        local char = line:sub(position, position)
        if char == "\\" then
            position = position + 2
        elseif char == quote then
            return position
        else
            position = position + 1
        end
    end
    return #line
end

local function find_number_end(line, start)
    for _, pattern in ipairs(NUMBER_PATTERNS) do
        local _, last = line:find(pattern, start)
        if last then
            local _, suffix_last = line:find(NUMBER_SUFFIX, last + 1)
            return suffix_last or last
        end
    end
    return start
end

local function classify_word(line, start, word)
    if KEYWORDS[word] then
        return "keyword"
    end
    if CONSTANTS[word] then
        return "constant"
    end
    -- obj.print or obj:type are fields, not the global functions.
    local before = line:sub(start - 1, start - 1)
    if BUILTINS[word] and before ~= "." and before ~= ":" then
        return "builtin"
    end
    return "plain"
end

-- =========================================================================
-- Tokenizer
-- =========================================================================

--- Scan one token of `line` at `position` outside any long bracket.
--- Returns the token's last index, its kind, and the closing bracket
--- when the token opens a long string or comment not closed on this line.
local function scan_token(line, position)
    local char = line:sub(position, position)
    local level = line:match("^%[(=*)%[", position + 2)
    if line:sub(position, position + 1) == "--" then
        if level then
            local close = "]" .. level .. "]"
            local last = find_long_close(line, position + 4 + #level, close)
            return last or #line, "comment", (not last) and close or nil
        end
        return #line, "comment"
    end
    level = line:match("^%[(=*)%[", position)
    if level then
        local close = "]" .. level .. "]"
        local last = find_long_close(line, position + 2 + #level, close)
        return last or #line, "string", (not last) and close or nil
    end
    if char == '"' or char == "'" then
        return find_quote_end(line, position), "string"
    end
    if char:match("%d") or line:match("^%.%d", position) then
        return find_number_end(line, position), "number"
    end
    local word = line:match("^[%a_][%w_]*", position)
    if word then
        return position + #word - 1, classify_word(line, position, word)
    end
    local _, space_last = line:find("^%s+", position)
    return space_last or position, "plain"
end

--- Highlight one `line`, continuing an open long bracket described by
--- `open` ({ kind, close } or nil). Returns the spans and the long
--- bracket still open at the end of the line (or nil).
local function highlight_line(line, open)
    local spans = {}
    local position = 1
    if open then
        local last = find_long_close(line, 1, open.close)
        if not last then
            add_span(spans, line, open.kind)
            return spans, open
        end
        add_span(spans, line:sub(1, last), open.kind)
        position = last + 1
    end
    while position <= #line do
        local last, kind, close = scan_token(line, position)
        add_span(spans, line:sub(position, last), kind)
        if close then
            return spans, { kind = kind, close = close }
        end
        position = last + 1
    end
    return spans, nil
end

--- Highlight every line of a Lua source given as an array of `lines`
--- (without newlines). Returns an array of span arrays, one per line.
function M.highlight_lines(lines)
    local result = {}
    local open = nil
    for index, line in ipairs(lines) do
        result[index], open = highlight_line(line, open)
    end
    return result
end

return M
