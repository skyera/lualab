#!/usr/bin/env luajit
--[[
    mdview.lua — a fast terminal Markdown viewer built on LuaJIT + FFI.

    Features:
    - Dependency-free Markdown parser: headings, paragraphs, emphasis, inline
      code, fenced code blocks, blockquotes, nested ordered/unordered/task
      lists, tables with alignment, horizontal rules and YAML front matter.
    - Styled rendering with truecolor ANSI palettes and OSC 8 hyperlinks.
    - Block images rendered as truecolor half-block art: PPM/PGM natively,
      PNG/JPEG/GIF/WebP through ImageMagick or ffmpeg when installed.
    - Source line-number gutter (wrapped continuation rows stay blank).
    - Unicode-aware word wrapping (wide characters, combining marks, tabs).
    - POSIX termios raw-mode pager via FFI: poll()-driven keys, alternate
      screen, resize handling, flicker-free differential row updates.
    - Incremental case-insensitive search with match highlighting.
    - Pure render/frame functions for headless tests and --snapshot output.

    Usage:
      luajit mdview.lua README.md
      luajit mdview.lua --width 100 --no-pager README.md
      luajit mdview.lua --snapshot 100x30 README.md
      cat README.md | luajit mdview.lua -

    Keys:
      q / Esc       quit                    j / Down      scroll down
      k / Up        scroll up               Ctrl-e/y      scroll line down/up
      d / Ctrl-d    half page down          u / Ctrl-u    half page up
      Space/Ctrl-f  page down               b / Ctrl-b    page up
      g / Home      top                     G / End       bottom
      / and ?       search forward/back     n / N         next / previous
      h             toggle help

    Options:
      -w, --width N        wrap width for non-interactive output (default 80)
      --no-pager           render the document and exit
      --color              keep ANSI colors when output is not a tty
      --no-images          show image placeholders instead of block art
      -n, --numbers        show source line numbers (default in the pager)
      --no-numbers         hide source line numbers
      --snapshot [WxH]     print one TUI frame and exit (default 80x24)
      --search PATTERN     pre-fill search (useful with --snapshot)
      -h, --help           show this help
]]

local ffi = require("ffi")
local bit = require("bit")

local IS_WINDOWS = (ffi.os == "Windows")
local M = { VERSION = "1.0.0" }

-- =========================================================================
-- 1. Text Utilities: UTF-8 Width, Truncation, ANSI Helpers
-- =========================================================================
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function next_char(text, pos)
    return text:match(UTF8_CHAR, pos)
end

local function character_width(char)
    local a, b, c, d = char:byte(1, 4)
    local code = a
    if a and a >= 240 and d then
        code = (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128
    elseif a and a >= 224 and c then
        code = (a - 224) * 4096 + (b - 128) * 64 + c - 128
    elseif a and a >= 192 and b then
        code = (a - 192) * 64 + b - 128
    end
    if code == nil then
        return 1
    end
    if (code >= 0x0300 and code <= 0x036f) or (code >= 0xfe00 and code <= 0xfe0f)
        or (code >= 0x200b and code <= 0x200f) or code == 0xfeff then
        return 0
    end
    if code >= 0x1100 and (code <= 0x115f or code == 0x2329 or code == 0x232a
        or (code >= 0x2e80 and code <= 0xa4cf) or (code >= 0xac00 and code <= 0xd7a3)
        or (code >= 0xf900 and code <= 0xfaff) or (code >= 0xfe10 and code <= 0xfe6f)
        or (code >= 0xff01 and code <= 0xff60) or (code >= 0xffe0 and code <= 0xffe6)
        or (code >= 0x1f300 and code <= 0x1faff) or code >= 0x20000) then
        return 2
    end
    return 1
end

local function display_width(text)
    local width = 0
    local pos = 1
    while pos <= #text do
        local char = next_char(text, pos) or text:sub(pos, pos)
        width = width + character_width(char)
        pos = pos + #char
    end
    return width
end

local function strip_ansi(text)
    text = text:gsub("\27%]8;;[^\7\27]*\27\\", "")
    text = text:gsub("\27%[[%d;?]*[A-Za-z]", "")
    return text
end

local function expand_tabs(line)
    if not line:find("\t", 1, true) then
        return line
    end
    local out = {}
    local column = 0
    local pos = 1
    while pos <= #line do
        local char = next_char(line, pos) or line:sub(pos, pos)
        if char == "\t" then
            local spaces = 4 - (column % 4)
            out[#out + 1] = string.rep(" ", spaces)
            column = column + spaces
        else
            out[#out + 1] = char
            column = column + character_width(char)
        end
        pos = pos + #char
    end
    return table.concat(out)
end

local function clip_to_width(text, max_width)
    if max_width <= 0 then
        return "", 0
    end
    local out = {}
    local used = 0
    local pos = 1
    while pos <= #text do
        local char = next_char(text, pos) or text:sub(pos, pos)
        local width = character_width(char)
        if used + width > max_width then
            break
        end
        out[#out + 1] = char
        used = used + width
        pos = pos + #char
    end
    return table.concat(out), used
end

-- =========================================================================
-- 2. Styled Spans
-- =========================================================================
local STYLE_ORDER = {
    "bold", "dim", "italic", "underline", "strike", "reverse", "search",
    "link", "code", "code_block", "quote", "fg", "bg", "href",
}

local function style_signature(style)
    if not style then
        return ""
    end
    local parts = {}
    for _, key in ipairs(STYLE_ORDER) do
        local value = style[key]
        if value then
            parts[#parts + 1] = key .. "=" .. tostring(value)
        end
    end
    return table.concat(parts, "|")
end

local function merge_style(base, extra)
    local style = {}
    if base then
        for key, value in pairs(base) do
            style[key] = value
        end
    end
    if extra then
        for key, value in pairs(extra) do
            if value ~= nil then
                style[key] = value
            end
        end
    end
    return style
end

local function add_span(spans, text, style)
    if text == nil or text == "" then
        return
    end
    local last = spans[#spans]
    if last and style_signature(last.style) == style_signature(style) then
        last.text = last.text .. text
        return
    end
    spans[#spans + 1] = { text = text, style = style }
end

local function spans_text(spans)
    local parts = {}
    for _, span in ipairs(spans) do
        parts[#parts + 1] = span.text
    end
    return table.concat(parts)
end

local function make_line(spans, number)
    return { spans = spans, text = spans_text(spans), number = number }
end

local function truncate_spans(spans, max_width)
    if max_width <= 0 then
        return {}
    end
    local total = 0
    for _, span in ipairs(spans) do
        total = total + display_width(span.text)
    end
    if total <= max_width then
        return spans
    end
    local out = {}
    local budget = math.max(0, max_width - 1)
    for _, span in ipairs(spans) do
        if budget <= 0 then
            break
        end
        local text, width = clip_to_width(span.text, budget)
        add_span(out, text, span.style)
        budget = budget - width
    end
    add_span(out, "…", nil)
    return out
end

-- =========================================================================
-- 3. ANSI Theme and Span Serialization
-- =========================================================================
local THEME = {
    text = "38;2;200;208;222",
    heading1 = "38;2;130;170;255",
    heading2 = "38;2;86;182;194",
    heading3 = "38;2;179;157;219",
    heading4 = "38;2;229;192;123",
    rule1 = "38;2;56;90;160",
    rule2 = "38;2;60;80;100",
    block_bar = "38;2;80;90;120",
    code_fg = "38;2;229;192;123",
    code_bg = "48;2;42;46;56",
    code_block_fg = "38;2;180;190;205",
    quote_fg = "38;2;150;170;205",
    link = "38;2;97;175;239",
    marker = "38;2;120;160;220",
    table_border = "38;2;80;90;120",
    table_header = "38;2;205;220;240",
    bar_fg = "38;2;205;215;230",
    bar_bg = "48;2;32;38;48",
    info = "38;2;120;200;230",
    warn = "38;2;240;190;90",
    search_fg = "30",
    search_bg = "43",
}

local STYLE = {
    heading = {
        { bold = true, fg = THEME.heading1 },
        { bold = true, fg = THEME.heading2 },
        { bold = true, fg = THEME.heading3 },
        { bold = true, fg = THEME.heading4 },
        { bold = true, dim = true },
        { dim = true, italic = true },
    },
    rule = {
        { fg = THEME.rule1 },
        { fg = THEME.rule2 },
    },
    code_block = { code_block = true },
    block_bar = { fg = THEME.block_bar },
    quote_text = { italic = true, quote = true },
    marker = { bold = true, fg = THEME.marker },
    table_border = { fg = THEME.table_border },
    table_header = { bold = true, fg = THEME.table_header },
    task_done = { fg = "38;2;120;200;140" },
    line_number = { fg = "38;2;95;105;125" },
    search = { search = true },
    bar = { bold = true, fg = THEME.bar_fg, bg = THEME.bar_bg },
    info = { fg = THEME.info },
    warn = { fg = THEME.warn },
}

local function style_to_ansi(style)
    if not style then
        return ""
    end
    local codes = {}
    local seen = {}
    local function add(code)
        if not seen[code] then
            seen[code] = true
            codes[#codes + 1] = code
        end
    end
    if style.reverse then add("7") end
    if style.bold then add("1") end
    if style.dim then add("2") end
    if style.italic then add("3") end
    if style.underline then add("4") end
    if style.strike then add("9") end

    local fg = style.fg
    local bg = style.bg
    if style.search then
        fg = fg or THEME.search_fg
        bg = THEME.search_bg
        add("1")
    end
    if not bg and style.code and not style.code_block then
        bg = THEME.code_bg
    end
    if not fg then
        if style.link then
            fg = THEME.link
        elseif style.code or style.code_block then
            fg = THEME.code_block_fg
        elseif style.quote then
            fg = THEME.quote_fg
        end
    end
    if fg then add(fg) end
    if bg then add(bg) end
    if #codes == 0 then
        return ""
    end
    return "\27[" .. table.concat(codes, ";") .. "m"
end

local function spans_to_ansi(spans, max_width, pad)
    local parts = {}
    local used = 0
    for _, span in ipairs(spans) do
        if used >= max_width then
            break
        end
        local text, width = clip_to_width(span.text, max_width - used)
        if #text > 0 then
            local ansi = style_to_ansi(span.style)
            local href = span.style and span.style.href
            if href then
                parts[#parts + 1] = "\27]8;;" .. href .. "\27\\"
            end
            if ansi ~= "" then
                parts[#parts + 1] = ansi
            end
            parts[#parts + 1] = text
            if ansi ~= "" then
                parts[#parts + 1] = "\27[0m"
            end
            if href then
                parts[#parts + 1] = "\27]8;;\27\\"
            end
            used = used + width
        end
    end
    if pad and used < max_width then
        parts[#parts + 1] = string.rep(" ", max_width - used)
    end
    return table.concat(parts)
end

-- =========================================================================
-- 4. Inline Markdown Parser
-- =========================================================================
local PUNCTUATION = "!\"#$%%&'()*+,-./:;<=>?@[\\]^_`{|}~"

local function parse_inline(text, base)
    local spans = {}
    local buffer = {}
    local index = 1
    local length = #text

    local function flush()
        if #buffer > 0 then
            add_span(spans, table.concat(buffer), base)
            buffer = {}
        end
    end

    local function append_children(children)
        for _, span in ipairs(children) do
            add_span(spans, span.text, span.style)
        end
    end

    while index <= length do
        local char = text:sub(index, index)

        if char == "\\" and index < length then
            local following = text:sub(index + 1, index + 1)
            if following:match("[%p]") then
                buffer[#buffer + 1] = following
                index = index + 2
            else
                buffer[#buffer + 1] = char
                index = index + 1
            end
        elseif char == "`" then
            local ticks = text:match("^(`+)", index)
            local close_start = text:find(ticks, index + #ticks, true)
            if close_start then
                flush()
                local code = text:sub(index + #ticks, close_start - 1)
                if #code > 2 and code:sub(1, 1) == " " and code:sub(-1) == " " then
                    code = code:sub(2, -2)
                end
                add_span(spans, code, merge_style(base, { code = true }))
                index = close_start + #ticks
            else
                buffer[#buffer + 1] = char
                index = index + 1
            end
        elseif char == "*" or char == "_" then
            local double = text:sub(index + 1, index + 1) == char
            local marker = double and (char .. char) or char
            local close = text:find(marker, index + #marker, true)
            if close and close > index + #marker then
                flush()
                local inner = text:sub(index + #marker, close - 1)
                local child = merge_style(base, double and { bold = true } or { italic = true })
                append_children(parse_inline(inner, child))
                index = close + #marker
            else
                buffer[#buffer + 1] = char
                index = index + 1
            end
        elseif char == "~" and text:sub(index + 1, index + 1) == "~" then
            local close = text:find("~~", index + 2, true)
            if close then
                flush()
                local inner = text:sub(index + 2, close - 1)
                append_children(parse_inline(inner, merge_style(base, { strike = true })))
                index = close + 2
            else
                buffer[#buffer + 1] = char
                index = index + 1
            end
        elseif char == "!" and text:sub(index + 1, index + 1) == "[" then
            local label, url, stop = text:match("^!%[([^%]]*)%]%(([^%)]*)%)()", index)
            if label then
                flush()
                local safe_url = url:gsub("[%z\1-\31\127]", "")
                if #label > 0 then
                    add_span(spans, label, merge_style(base, { underline = true, href = safe_url }))
                end
                if #safe_url > 0 then
                    add_span(spans, " (" .. safe_url .. ")", merge_style(base, { dim = true }))
                end
                index = stop
            else
                buffer[#buffer + 1] = char
                index = index + 1
            end
        elseif char == "[" then
            local label, url, stop = text:match("^%[([^%]]*)%]%(([^%)]*)%)()", index)
            if label then
                flush()
                local safe_url = url:gsub("[%z\1-\31\127]", "")
                if #safe_url > 0 then
                    append_children(parse_inline(label, merge_style(base, {
                        underline = true,
                        href = safe_url,
                    })))
                else
                    append_children(parse_inline(label, base))
                end
                index = stop
            else
                buffer[#buffer + 1] = char
                index = index + 1
            end
        elseif char == "<" and text:match("^<([%w%+%-%.]+@[%w%.%-]+)>", index) then
            local address = text:match("^<([%w%+%-%.]+@[%w%.%-]+)>", index)
            flush()
            add_span(spans, address, merge_style(base, { underline = true, href = "mailto:" .. address }))
            index = index + #address + 2
        elseif char == "<" and text:match("^<([%a][%w%+%-%.]*:[^%s<>]+)>", index) then
            local url = text:match("^<([%a][%w%+%-%.]*:[^%s<>]+)>", index)
            flush()
            add_span(spans, url, merge_style(base, { underline = true, href = url }))
            index = index + #url + 2
        else
            buffer[#buffer + 1] = char
            index = index + 1
        end
    end
    flush()
    if #spans == 0 then
        add_span(spans, "", base)
    end
    return spans
end

-- =========================================================================
-- 5. Word and Code Wrapping
-- =========================================================================
local function wrap_flow(spans, width, first_indent, next_indent)
    width = math.max(8, width)
    first_indent = first_indent or 0
    next_indent = next_indent or 0

    local lines = {}
    local current = {}
    local current_width = 0
    local has_content = false
    local indent = first_indent

    local function start_line()
        current = {}
        current_width = 0
        has_content = false
        if indent > 0 then
            add_span(current, string.rep(" ", indent), nil)
            current_width = indent
        end
    end

    local function finish_line()
        if has_content then
            lines[#lines + 1] = make_line(current)
        end
        indent = next_indent
        start_line()
    end

    start_line()

    local tokens = {}
    for _, span in ipairs(spans) do
        local pos = 1
        while pos <= #span.text do
            local char = next_char(span.text, pos) or span.text:sub(pos, pos)
            if char:match("%s") then
                local stop = pos
                while stop <= #span.text do
                    local c = next_char(span.text, stop) or span.text:sub(stop, stop)
                    if not c:match("%s") then
                        break
                    end
                    stop = stop + #c
                end
                tokens[#tokens + 1] = { space = true }
                pos = stop
            else
                local stop = pos
                while stop <= #span.text do
                    local c = next_char(span.text, stop) or span.text:sub(stop, stop)
                    if c:match("%s") then
                        break
                    end
                    stop = stop + #c
                end
                tokens[#tokens + 1] = { text = span.text:sub(pos, stop - 1), style = span.style }
                pos = stop
            end
        end
    end

    local pending_space = false
    for _, token in ipairs(tokens) do
        if token.space then
            pending_space = has_content
        else
            local word = token.text
            local word_width = display_width(word)
            local need_space = has_content and pending_space

            if has_content and current_width + (need_space and 1 or 0) + word_width > width then
                finish_line()
                need_space = false
            end
            if need_space then
                add_span(current, " ", nil)
                current_width = current_width + 1
            end

            if current_width + word_width <= width then
                add_span(current, word, token.style)
                current_width = current_width + word_width
                has_content = true
            else
                local pos = 1
                while pos <= #word do
                    if width - current_width <= 0 then
                        finish_line()
                    end
                    local room = width - current_width
                    local chunk, chunk_width = clip_to_width(word:sub(pos), room)
                    if #chunk == 0 then
                        finish_line()
                        room = width - current_width
                        chunk, chunk_width = clip_to_width(word:sub(pos), room)
                        if #chunk == 0 then
                            break
                        end
                    end
                    add_span(current, chunk, token.style)
                    current_width = current_width + chunk_width
                    has_content = true
                    pos = pos + #chunk
                    if pos <= #word then
                        finish_line()
                    end
                end
            end
            pending_space = false
        end
    end

    if has_content then
        lines[#lines + 1] = make_line(current)
    end
    return lines
end

local function wrap_pre(spans, width)
    width = math.max(4, width)
    local lines = {}
    local current = {}
    local current_width = 0

    local function finish_line()
        lines[#lines + 1] = make_line(current)
        current = {}
        current_width = 0
    end

    for _, span in ipairs(spans) do
        local pos = 1
        while pos <= #span.text do
            local char = next_char(span.text, pos) or span.text:sub(pos, pos)
            local char_width = character_width(char)
            if current_width + char_width > width then
                finish_line()
            end
            add_span(current, char, span.style)
            current_width = current_width + char_width
            pos = pos + #char
        end
    end
    if #current > 0 or #lines == 0 then
        lines[#lines + 1] = make_line(current)
    end
    return lines
end

-- =========================================================================
-- 6. Block Markdown Parser
-- =========================================================================
local function is_blank(line)
    return line:match("^%s*$") ~= nil
end

local function trim(line)
    return line:match("^%s*(.-)%s*$")
end

local function is_hr(line)
    local stripped = line:gsub("%s+", "")
    if #stripped < 3 then
        return false
    end
    return stripped:match("^%-+$") ~= nil
        or stripped:match("^%*+$") ~= nil
        or stripped:match("^_+$") ~= nil
end

local function match_list_item(line)
    local indent, bullet, text = line:match("^(%s*)([-*+])%s+(.*)$")
    if bullet then
        return { ordered = false, indent = #indent, text = text }
    end
    local indent2, number, text2 = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
    if number then
        return { ordered = true, indent = #indent2, number = tonumber(number), text = text2 }
    end
    return nil
end

local function is_table_delimiter(line)
    if not line:find("|", 1, true) then
        return false
    end
    local cells = {}
    local inner = trim(line):gsub("^|", ""):gsub("|$", "")
    for cell in (inner .. "|"):gmatch("([^|]*)|") do
        cells[#cells + 1] = trim(cell)
    end
    if #cells == 0 then
        return false
    end
    for _, cell in ipairs(cells) do
        if not cell:match("^:?%-+:?$") then
            return false
        end
    end
    return true
end

local function split_table_row(line)
    local inner = trim(line):gsub("^|", ""):gsub("|$", "")
    local cells = {}
    local buffer = {}
    local pos = 1
    while pos <= #inner do
        local char = inner:sub(pos, pos)
        if char == "\\" and inner:sub(pos + 1, pos + 1) == "|" then
            buffer[#buffer + 1] = "|"
            pos = pos + 2
        elseif char == "|" then
            cells[#cells + 1] = trim(table.concat(buffer))
            buffer = {}
            pos = pos + 1
        else
            buffer[#buffer + 1] = char
            pos = pos + 1
        end
    end
    cells[#cells + 1] = trim(table.concat(buffer))
    return cells
end

local function table_alignment(cell)
    local left = cell:sub(1, 1) == ":"
    local right = cell:sub(-1) == ":"
    if left and right then
        return "center"
    elseif right then
        return "right"
    end
    return "left"
end

local function match_standalone_image(line)
    local alt, inner = line:match("^%s*!%[([^%]]*)%]%((.-)%)%s*$")
    if not alt then
        return nil
    end
    local source = trim(inner)
    local without_title = source:match('^(.-)%s+"[^"]*"%s*$')
    if without_title then
        source = trim(without_title)
    end
    if #source == 0 then
        return nil
    end
    return alt, source
end

local function starts_block(line)
    return line:match("^%s*```") ~= nil
        or line:match("^%s*~~~") ~= nil
        or line:match("^%s*#+%s") ~= nil
        or line:match("^%s*>") ~= nil
        or is_hr(line)
        or match_list_item(line) ~= nil
end

local function parse_blocks(text, line_offset)
    line_offset = line_offset or 0
    local raw_lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        raw_lines[#raw_lines + 1] = expand_tabs(line:gsub("\r$", ""))
    end
    if raw_lines[#raw_lines] == "" then
        raw_lines[#raw_lines] = nil
    end

    local blocks = {}
    local index = 1

    -- YAML front matter is shown verbatim instead of being mistaken for rules.
    if raw_lines[1] == "---" then
        local close
        for probe = 2, #raw_lines do
            if raw_lines[probe] == "---" or raw_lines[probe] == "..." then
                close = probe
                break
            end
        end
        if close then
            local content = {}
            for probe = 2, close - 1 do
                content[#content + 1] = raw_lines[probe]
            end
            blocks[#blocks + 1] = {
                kind = "code",
                lang = "front matter",
                lines = content,
                line = line_offset + 1,
                fence_line = line_offset + 1,
            }
            index = close + 1
        end
    end

    while index <= #raw_lines do
        local line = raw_lines[index]

        if is_blank(line) then
            index = index + 1
        elseif line:match("^%s*(```+)%s*(.*)$") or line:match("^%s*(~~~+)%s*(.*)$") then
            local fence, info = line:match("^%s*(```+)%s*(.*)$")
            if not fence then
                fence, info = line:match("^%s*(~~~+)%s*(.*)$")
            end
            local fence_char = fence:sub(1, 1)
            local lang = info:match("^([%w_+%-%.]*)") or ""
            local content = {}
            local fence_line = line_offset + index
            index = index + 1
            while index <= #raw_lines do
                local closing = raw_lines[index]:match("^%s*(" .. fence_char:rep(#fence) .. fence_char .. "-)%s*$")
                if closing then
                    index = index + 1
                    break
                end
                content[#content + 1] = raw_lines[index]
                index = index + 1
            end
            blocks[#blocks + 1] = {
                kind = "code",
                lang = lang,
                lines = content,
                line = fence_line,
                fence_line = fence_line,
            }
        elseif line:match("^%s*(#+)%s*(.-)%s*$") then
            local hashes, heading = line:match("^%s*(#+)%s*(.-)%s*$")
            local block_line = line_offset + index
            if #hashes <= 6 and (#heading > 0 or line:match("#%s*$")) then
                heading = heading:gsub("%s+#+%s*$", "")
                blocks[#blocks + 1] = {
                    kind = "heading",
                    level = #hashes,
                    text = heading,
                    line = block_line,
                }
                index = index + 1
            else
                -- More than six hashes is a paragraph.
                local paragraph = { line }
                index = index + 1
                while index <= #raw_lines and not is_blank(raw_lines[index])
                    and not starts_block(raw_lines[index]) do
                    paragraph[#paragraph + 1] = trim(raw_lines[index])
                    index = index + 1
                end
                blocks[#blocks + 1] = {
                    kind = "paragraph",
                    text = table.concat(paragraph, " "),
                    line = block_line,
                }
            end
        elseif index < #raw_lines and raw_lines[index + 1]:match("^%s*=+%s*$")
            and not is_blank(line) then
            blocks[#blocks + 1] = {
                kind = "heading",
                level = 1,
                text = trim(line),
                line = line_offset + index,
            }
            index = index + 2
        elseif index < #raw_lines and raw_lines[index + 1]:match("^%s*%-+%s*$")
            and not is_blank(line) and not match_list_item(line) then
            blocks[#blocks + 1] = {
                kind = "heading",
                level = 2,
                text = trim(line),
                line = line_offset + index,
            }
            index = index + 2
        elseif is_hr(line) then
            blocks[#blocks + 1] = { kind = "hr", line = line_offset + index }
            index = index + 1
        elseif match_standalone_image(line) then
            local alt, source = match_standalone_image(line)
            blocks[#blocks + 1] = {
                kind = "image",
                alt = alt,
                src = source,
                line = line_offset + index,
            }
            index = index + 1
        elseif line:match("^%s*>") then
            local quoted = {}
            local quote_start = index
            while index <= #raw_lines do
                local current = raw_lines[index]
                if current:match("^%s*>") then
                    quoted[#quoted + 1] = current:gsub("^%s*> ?", "")
                    index = index + 1
                elseif is_blank(current) and raw_lines[index + 1]
                    and raw_lines[index + 1]:match("^%s*>") then
                    quoted[#quoted + 1] = ""
                    index = index + 1
                else
                    break
                end
            end
            blocks[#blocks + 1] = {
                kind = "quote",
                line = line_offset + quote_start,
                blocks = parse_blocks(table.concat(quoted, "\n"), line_offset + quote_start - 1),
            }
        elseif line:find("|", 1, true) and index < #raw_lines
            and is_table_delimiter(raw_lines[index + 1]) then
            local headers = split_table_row(line)
            local aligns = {}
            for cell_index, cell in ipairs(split_table_row(raw_lines[index + 1])) do
                aligns[cell_index] = table_alignment(cell)
            end
            local header_line = line_offset + index
            index = index + 2
            local rows = {}
            local row_lines = {}
            while index <= #raw_lines and not is_blank(raw_lines[index])
                and raw_lines[index]:find("|", 1, true) do
                rows[#rows + 1] = split_table_row(raw_lines[index])
                row_lines[#row_lines + 1] = line_offset + index
                index = index + 1
            end
            blocks[#blocks + 1] = {
                kind = "table",
                headers = headers,
                aligns = aligns,
                rows = rows,
                row_lines = row_lines,
                line = header_line,
            }
        elseif match_list_item(line) then
            local items = {}
            local indent_stack = {}
            while index <= #raw_lines do
                local current = raw_lines[index]
                local item = match_list_item(current)
                if item then
                    while #indent_stack > 0 and item.indent < indent_stack[#indent_stack] do
                        table.remove(indent_stack)
                    end
                    if #indent_stack == 0 or item.indent > indent_stack[#indent_stack] then
                        indent_stack[#indent_stack + 1] = item.indent
                    end
                    item.depth = #indent_stack
                    item.line = line_offset + index
                    items[#items + 1] = item
                    index = index + 1
                elseif is_blank(current) then
                    local following = raw_lines[index + 1]
                    if following and (match_list_item(following)
                        or (following:match("^%s+%S") and not starts_block(following))) then
                        index = index + 1
                    else
                        break
                    end
                elseif current:match("^%s+%S") and #items > 0 and not starts_block(current) then
                    local last = items[#items]
                    last.text = last.text .. " " .. trim(current)
                    index = index + 1
                else
                    break
                end
            end
            blocks[#blocks + 1] = { kind = "list", items = items }
        else
            local paragraph = { trim(line) }
            local paragraph_line = line_offset + index
            index = index + 1
            while index <= #raw_lines and not is_blank(raw_lines[index])
                and not starts_block(raw_lines[index]) do
                local following = raw_lines[index]
                if raw_lines[index + 1] and (raw_lines[index + 1]:match("^%s*=+%s*$")
                    or raw_lines[index + 1]:match("^%s*%-+%s*$")) then
                    break
                end
                if following:find("|", 1, true) and raw_lines[index + 1]
                    and is_table_delimiter(raw_lines[index + 1]) then
                    break
                end
                paragraph[#paragraph + 1] = trim(following)
                index = index + 1
            end
            blocks[#blocks + 1] = {
                kind = "paragraph",
                text = table.concat(paragraph, " "),
                line = paragraph_line,
            }
        end
    end
    return blocks
end

-- =========================================================================
-- 7. Block Renderer
-- =========================================================================
local function pad_cell(spans, target_width, align)
    local text_width = 0
    for _, span in ipairs(spans) do
        text_width = text_width + display_width(span.text)
    end
    local padding = math.max(0, target_width - text_width)
    local left = 0
    local right = padding
    if align == "right" then
        left = padding
        right = 0
    elseif align == "center" then
        left = math.floor(padding / 2)
        right = padding - left
    end
    local out = {}
    if left > 0 then
        add_span(out, string.rep(" ", left), nil)
    end
    for _, span in ipairs(spans) do
        add_span(out, span.text, span.style)
    end
    if right > 0 then
        add_span(out, string.rep(" ", right), nil)
    end
    return out
end

local render_blocks

local function render_heading(block, width, out)
    local level = math.max(1, math.min(6, block.level))
    local style = STYLE.heading[level]
    for position, line in ipairs(wrap_flow(parse_inline(block.text, style), width)) do
        if position == 1 then
            line.number = block.line
        end
        out[#out + 1] = line
    end
    if level <= 2 then
        local rule = level == 1 and "━" or "─"
        local rule_width = math.min(width, math.max(display_width(block.text), 8))
        local spans = {}
        add_span(spans, string.rep(rule, math.max(1, rule_width)), STYLE.rule[level])
        out[#out + 1] = make_line(spans)
    end
end

local function render_code(block, width, out)
    if block.lang and #block.lang > 0 then
        local spans = {}
        add_span(spans, "  " .. block.lang, { dim = true, italic = true })
        out[#out + 1] = make_line(spans)
    end
    if #block.lines == 0 then
        local spans = {}
        add_span(spans, "│", STYLE.block_bar)
        out[#out + 1] = make_line(spans)
        return
    end
    for code_index, code_line in ipairs(block.lines) do
        local content = {}
        if #code_line > 0 then
            add_span(content, code_line, STYLE.code_block)
        end
        local wrapped = #code_line > 0 and wrap_pre(content, math.max(4, width - 2))
            or { make_line({}) }
        for position, line in ipairs(wrapped) do
            local spans = {}
            add_span(spans, "│ ", STYLE.block_bar)
            for _, span in ipairs(line.spans) do
                add_span(spans, span.text, span.style)
            end
            local number = position == 1 and (block.fence_line + code_index) or nil
            out[#out + 1] = make_line(spans, number)
        end
    end
end

local function render_quote(block, width, out, context)
    local inner = {}
    render_blocks(block.blocks, math.max(8, width - 2), inner, STYLE.quote_text, context)
    if #inner == 0 then
        inner[1] = make_line({})
    end
    for _, line in ipairs(inner) do
        local spans = {}
        add_span(spans, "│", STYLE.block_bar)
        if #line.text > 0 then
            add_span(spans, " ", nil)
            for _, span in ipairs(line.spans) do
                add_span(spans, span.text, span.style)
            end
        end
        out[#out + 1] = make_line(spans, line.number)
    end
end

local function render_list(block, width, out)
    local counters = {}
    for _, item in ipairs(block.items) do
        local depth = math.max(1, item.depth or 1)
        local indent = string.rep("  ", depth - 1)
        local marker
        local marker_style = STYLE.marker
        local text = item.text

        if item.ordered then
            if item.number and counters[depth] == nil then
                counters[depth] = item.number - 1
            end
            counters[depth] = (counters[depth] or 0) + 1
            for deeper = depth + 1, 9 do
                counters[deeper] = nil
            end
            marker = tostring(counters[depth]) .. "."
            marker_style = { fg = THEME.marker }
        else
            marker = "•"
        end

        local box, rest = text:match("^%[([ xX])%]%s+(.*)$")
        if box then
            text = rest
            if box == " " then
                marker = "☐"
                marker_style = { dim = true }
            else
                marker = "☑"
                marker_style = STYLE.task_done
            end
        end

        local prefix_width = display_width(indent) + display_width(marker) + 1
        local content_width = math.max(8, width - prefix_width)
        local wrapped = wrap_flow(parse_inline(text), content_width)
        if #wrapped == 0 then
            wrapped[1] = make_line({})
        end
        for line_index, line in ipairs(wrapped) do
            local spans = {}
            if line_index == 1 then
                add_span(spans, indent, nil)
                add_span(spans, marker, marker_style)
                add_span(spans, " ", nil)
            else
                add_span(spans, string.rep(" ", prefix_width), nil)
            end
            for _, span in ipairs(line.spans) do
                add_span(spans, span.text, span.style)
            end
            local number = line_index == 1 and item.line or nil
            out[#out + 1] = make_line(spans, number)
        end
    end
end

-- =========================================================================
-- 7b. Image Loading and Half-Block Rendering
-- =========================================================================
local IMAGE_CACHE = {}

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function read_ppm(data)
    local position = 1

    local function next_token()
        while position <= #data do
            local char = data:sub(position, position)
            if char == "#" then
                local newline = data:find("\n", position, true)
                position = newline and (newline + 1) or (#data + 1)
            elseif char:match("%s") then
                position = position + 1
            else
                break
            end
        end
        if position > #data then
            return nil
        end
        local start = position
        while position <= #data and not data:sub(position, position):match("%s") do
            position = position + 1
        end
        return data:sub(start, position - 1)
    end

    local magic = next_token()
    if magic ~= "P6" and magic ~= "P3" then
        return nil, "unsupported image data (expected PPM)"
    end
    local width = tonumber(next_token())
    local height = tonumber(next_token())
    local max_value = tonumber(next_token())
    if not width or not height or not max_value or width < 1 or height < 1 then
        return nil, "corrupt PPM header"
    end
    if max_value ~= 255 then
        return nil, "only 8-bit PPM images are supported"
    end

    local count = width * height
    local pixels
    if magic == "P6" then
        if data:sub(position, position) == "\r" and data:sub(position + 1, position + 1) == "\n" then
            position = position + 2
        elseif data:sub(position, position):match("%s") then
            position = position + 1
        end
        pixels = data:sub(position, position + count * 3 - 1)
        if #pixels < count * 3 then
            return nil, "truncated PPM pixel data"
        end
    else
        local parts = {}
        for _ = 1, count * 3 do
            local token = next_token()
            if not token then
                return nil, "truncated PPM ASCII data"
            end
            parts[#parts + 1] = string.char(math.max(0, math.min(255, tonumber(token) or 0)))
        end
        pixels = table.concat(parts)
    end
    return { width = width, height = height, pixels = pixels }
end

local function decode_with_tool(path)
    local escaped = shell_quote(path)
    local commands = {
        "convert " .. escaped .. " -resize '256x256>' -depth 8 ppm:-",
        "magick " .. escaped .. " -resize '256x256>' -depth 8 ppm:-",
        "ffmpeg -v error -i " .. escaped
            .. ' -vf "scale=min(256\\,iw):min(256\\,ih):force_original_aspect_ratio=decrease"'
            .. " -frames:v 1 -f image2pipe -vcodec ppm -",
    }
    for _, command in ipairs(commands) do
        local pipe = io.popen(command, "r")
        if pipe then
            local data = pipe:read("*a")
            pipe:close()
            if data and #data > 0 then
                local image = read_ppm(data)
                if image then
                    return image
                end
            end
        end
    end
    return nil, "install ImageMagick or ffmpeg to decode this format"
end

local function load_image_file(path)
    local cached = IMAGE_CACHE[path]
    if cached then
        return cached.image, cached.error
    end

    local file = io.open(path, "rb")
    if not file then
        local error_message = "cannot open image"
        IMAGE_CACHE[path] = { error = error_message }
        return nil, error_message
    end
    local signature = file:read(2)
    file:close()

    local image, decode_error
    if signature == "P6" or signature == "P3" then
        local handle = io.open(path, "rb")
        local data = handle:read("*a")
        handle:close()
        image, decode_error = read_ppm(data)
    else
        image, decode_error = decode_with_tool(path)
    end

    IMAGE_CACHE[path] = { image = image, error = decode_error }
    return image, decode_error
end

local function resolve_image_path(source, base_dir)
    if source:match("^%a[%w%+%-%.]*://") then
        return nil, "remote image not loaded"
    end
    local path = source:gsub("^file://", "")
    if path:sub(1, 1) ~= "/" and not path:match("^%a:[/\\]") then
        path = (base_dir or ".") .. "/" .. path
    end
    return path
end

local function image_pixel(image, x, y)
    local offset = (y * image.width + x) * 3 + 1
    return image.pixels:byte(offset), image.pixels:byte(offset + 1), image.pixels:byte(offset + 2)
end

local function render_image(block, width, out, context)
    context = context or {}
    local alt = block.alt or ""

    local function fallback(reason)
        local label = "[image]"
        if #alt > 0 then
            label = label .. " " .. alt
        end
        label = label .. " (" .. block.src .. ")"
        if reason and #reason > 0 then
            label = label .. " - " .. reason
        end
        local spans = {}
        add_span(spans, label, { dim = true })
        out[#out + 1] = make_line(spans)
    end

    if context.images == false then
        fallback("disabled")
        return
    end
    local path, path_error = resolve_image_path(block.src, context.base_dir)
    if not path then
        fallback(path_error)
        return
    end
    local image, decode_error = load_image_file(path)
    if not image then
        fallback(decode_error)
        return
    end

    local columns = math.max(1, math.min(width, context.max_image_width or 48, image.width))
    local aspect = image.height / image.width
    local rows = math.max(1, math.floor(columns * aspect * 0.5 + 0.5))
    local max_rows = math.max(1, context.max_image_height or 16)
    if rows > max_rows then
        rows = max_rows
        columns = math.max(1, math.min(width, math.floor(rows * 2 / aspect + 0.5)))
    end

    for row = 0, rows - 1 do
        local spans = {}
        for column = 0, columns - 1 do
            local x = math.min(image.width - 1, math.floor(column * image.width / columns))
            local top_y = math.min(image.height - 1,
                math.floor(row * 2 * image.height / (rows * 2)))
            local bottom_y = math.min(image.height - 1,
                math.floor((row * 2 + 1) * image.height / (rows * 2)))
            local top_r, top_g, top_b = image_pixel(image, x, top_y)
            local bottom_r, bottom_g, bottom_b = image_pixel(image, x, bottom_y)
            add_span(spans, "▀", {
                fg = string.format("38;2;%d;%d;%d", top_r, top_g, top_b),
                bg = string.format("48;2;%d;%d;%d", bottom_r, bottom_g, bottom_b),
            })
        end
        local number = row == 0 and block.line or nil
        out[#out + 1] = make_line(spans, number)
    end

    if #alt > 0 then
        local spans = {}
        add_span(spans, alt, { dim = true, italic = true })
        out[#out + 1] = make_line(spans)
    end
end

local function render_table(block, width, out)
    local columns = math.max(1, #block.headers)
    local parsed = {}
    local widths = {}

    local function ensure_cell(row_index, column)
        parsed[row_index] = parsed[row_index] or {}
        if not parsed[row_index][column] then
            local source = ""
            if row_index == 0 then
                source = block.headers[column] or ""
            else
                local row = block.rows[row_index] or {}
                source = row[column] or ""
            end
            parsed[row_index][column] = parse_inline(source)
        end
        return parsed[row_index][column]
    end

    for column = 1, columns do
        local w = display_width(spans_text(ensure_cell(0, column)))
        widths[column] = math.max(3, w)
    end
    for row_index = 1, #block.rows do
        for column = 1, columns do
            local w = display_width(spans_text(ensure_cell(row_index, column)))
            widths[column] = math.max(widths[column], w)
        end
    end

    local total = 3 * columns + 1
    for column = 1, columns do
        total = total + widths[column]
    end
    while total > width do
        local widest = 1
        for column = 2, columns do
            if widths[column] > widths[widest] then
                widest = column
            end
        end
        if widths[widest] <= 3 then
            break
        end
        widths[widest] = widths[widest] - 1
        total = total - 1
    end

    local function border(left, middle, right)
        local parts = { left }
        for column = 1, columns do
            parts[#parts + 1] = string.rep("─", widths[column] + 2)
            if column < columns then
                parts[#parts + 1] = middle
            end
        end
        parts[#parts + 1] = right
        return make_line({ { text = table.concat(parts), style = STYLE.table_border } })
    end

    out[#out + 1] = border("┌", "┬", "┐")

    local function render_row(row_index, header)
        local spans = {}
        add_span(spans, "│", STYLE.table_border)
        for column = 1, columns do
            local cell = truncate_spans(ensure_cell(row_index, column), widths[column])
            if header then
                local styled = {}
                for _, span in ipairs(cell) do
                    add_span(styled, span.text, merge_style(span.style, STYLE.table_header))
                end
                cell = styled
            end
            cell = pad_cell(cell, widths[column], block.aligns[column] or "left")
            add_span(spans, " ", nil)
            for _, span in ipairs(cell) do
                add_span(spans, span.text, span.style)
            end
            add_span(spans, " ", nil)
            add_span(spans, "│", STYLE.table_border)
        end
        local number
        if header then
            number = block.line
        else
            number = block.row_lines[row_index]
        end
        out[#out + 1] = make_line(spans, number)
    end

    render_row(0, true)
    out[#out + 1] = border("├", "┼", "┤")
    for row_index = 1, #block.rows do
        render_row(row_index, false)
    end
    out[#out + 1] = border("└", "┴", "┘")
end

render_blocks = function(blocks, width, out, base_style, context)
    for block_index, block in ipairs(blocks) do
        if block_index > 1 then
            local previous = out[#out]
            if previous and #previous.text > 0 then
                out[#out + 1] = make_line({})
            end
        end

        if block.kind == "heading" then
            render_heading(block, width, out)
        elseif block.kind == "paragraph" then
            local spans = parse_inline(block.text, base_style)
            local lines = wrap_flow(spans, width)
            if #lines == 0 then
                lines[1] = make_line({})
            end
            for position, line in ipairs(lines) do
                if position == 1 then
                    line.number = block.line
                end
                out[#out + 1] = line
            end
        elseif block.kind == "code" then
            render_code(block, width, out)
        elseif block.kind == "quote" then
            render_quote(block, width, out, context)
        elseif block.kind == "image" then
            render_image(block, width, out, context)
        elseif block.kind == "list" then
            render_list(block, width, out)
        elseif block.kind == "table" then
            render_table(block, width, out)
        elseif block.kind == "hr" then
            local spans = {}
            add_span(spans, string.rep("─", math.max(1, width)), { fg = THEME.rule2 })
            out[#out + 1] = make_line(spans, block.line)
        end
    end
end

function M.render(text, width, options)
    width = math.max(20, width or 80)
    if type(options) ~= "table" then
        options = {}
    end
    local context = {
        base_dir = options.base_dir,
        images = options.images ~= false,
        max_image_width = options.max_image_width or 48,
        max_image_height = options.max_image_height or 16,
    }
    local gutter = 0
    if options.numbers == true then
        local newlines = select(2, text:gsub("\n", ""))
        local source_lines = newlines + 1
        if text:sub(-1) == "\n" then
            source_lines = source_lines - 1
        end
        gutter = #tostring(math.max(1, source_lines)) + 1
    end
    local content_width = math.max(20, width - gutter)
    local lines = {}
    render_blocks(parse_blocks(text), content_width, lines, nil, context)
    while #lines > 0 and lines[#lines].text == "" do
        lines[#lines] = nil
    end
    lines.gutter_width = gutter
    return lines
end

function M.render_text(text, width, options)
    local parts = {}
    for _, line in ipairs(M.render(text, width, options)) do
        parts[#parts + 1] = line.text
    end
    return table.concat(parts, "\n")
end

-- =========================================================================
-- 8. Search
-- =========================================================================
local function find_matches(lines, query)
    local matches = {}
    if not query or #query == 0 then
        return matches
    end
    local ascii = query:match("^[%z\1-\127]+$") ~= nil
    local needle = ascii and query:lower() or query
    for line_index, line in ipairs(lines) do
        local haystack = ascii and line.text:lower() or line.text
        local init = 1
        while true do
            local start_pos, end_pos = haystack:find(needle, init, true)
            if not start_pos then
                break
            end
            matches[#matches + 1] = { line = line_index, start = start_pos, finish = end_pos }
            init = end_pos + 1
        end
    end
    return matches
end

local function highlight_spans(spans, ranges)
    if not ranges or #ranges == 0 then
        return spans
    end
    local out = {}
    local offset = 1
    for _, span in ipairs(spans) do
        local text = span.text
        local span_start = offset
        local span_finish = offset + #text - 1
        local cursor = 1
        for _, range in ipairs(ranges) do
            local from = math.max(range.start, span_start)
            local to = math.min(range.finish, span_finish)
            if from <= to then
                local local_from = from - span_start + 1
                local local_to = to - span_start + 1
                if local_from > cursor then
                    add_span(out, text:sub(cursor, local_from - 1), span.style)
                end
                add_span(out, text:sub(local_from, local_to),
                    merge_style(span.style, STYLE.search))
                cursor = local_to + 1
            end
        end
        if cursor <= #text then
            add_span(out, text:sub(cursor), span.style)
        end
        offset = offset + #text
    end
    return out
end

-- =========================================================================
-- 9. Pager View State
-- =========================================================================
local HELP_TEXT = [[
# mdview keys

| Key | Action |
| --- | ------ |
| `q` / `Esc` | Quit the viewer |
| `j` / `↓`, `k` / `↑` | Scroll one line |
| `Ctrl-e`, `Ctrl-y` | Scroll one line down / up |
| `d` / `Ctrl-d`, `u` / `Ctrl-u` | Scroll half a page down / up |
| `Space` / `Ctrl-f`, `b` / `Ctrl-b` | Page down / page up |
| `g` / `Home`, `G` / `End` | Jump to top / bottom |
| `0` / `^`, `$` | Jump to top / bottom |
| `/`, `?` | Search forward / backward |
| `n` / `N` | Next / previous match |
| `h` | Toggle this help |

Search matches are highlighted in yellow. Resize the terminal at any time;
the pager redraws without clearing the screen.
]]

function M.new_view(title, lines)
    return {
        title = title or "untitled",
        lines = lines or {},
        gutter_width = lines and lines.gutter_width or 0,
        top = 1,
        search = { query = "", matches = {}, index = 0, direction = 1 },
        match_map = {},
        message = "",
        message_kind = "info",
        mode = "normal",
        prompt = "",
        prompt_direction = 1,
        prompt_snapshot = nil,
        help_cache = {},
        quit = false,
    }
end

local function page_rows(height)
    return math.max(1, height - 2)
end

local function max_top(view, height)
    return math.max(1, #view.lines - page_rows(height) + 1)
end

function M.clamp_view(view, height)
    view.top = math.max(1, math.min(view.top, max_top(view, height)))
end

local function goto_match(view, index, height)
    local total = #view.search.matches
    if total == 0 then
        return
    end
    index = ((index - 1) % total) + 1
    view.search.index = index
    local match = view.search.matches[index]
    local rows = page_rows(height)
    if match.line < view.top or match.line >= view.top + rows then
        view.top = math.max(1, match.line - math.floor(rows / 2))
    end
    local target = view.lines[match.line]
    local label = (target and target.number) or match.line
    view.message = string.format("match %d/%d - line %d", index, total, label)
    view.message_kind = "info"
end

function M.search(view, query, height, direction, incremental, anchor)
    direction = direction or 1
    local reference = anchor or view.top
    local matches = find_matches(view.lines, query)
    view.search = {
        query = query,
        matches = matches,
        index = 0,
        direction = direction,
    }
    view.match_map = {}
    for _, match in ipairs(matches) do
        local ranges = view.match_map[match.line] or {}
        ranges[#ranges + 1] = { start = match.start, finish = match.finish }
        view.match_map[match.line] = ranges
    end
    if #matches == 0 then
        if not incremental then
            view.message = "pattern not found: " .. query
            view.message_kind = "warn"
        end
        return 0
    end

    local index
    if direction < 0 then
        index = #matches
        for position = #matches, 1, -1 do
            if matches[position].line < reference then
                index = position
                break
            end
        end
    else
        index = 1
        for position, match in ipairs(matches) do
            if match.line >= reference then
                index = position
                break
            end
        end
    end
    goto_match(view, index, height)
    return #matches
end

local function begin_search(view, direction)
    view.mode = "search"
    view.prompt_direction = direction or 1
    view.prompt = ""
    view.prompt_snapshot = {
        top = view.top,
        search = view.search,
        match_map = view.match_map,
    }
end

local function preview_search(view, height)
    if #view.prompt == 0 then
        view.search = {
            query = "",
            matches = {},
            index = 0,
            direction = view.prompt_direction or 1,
        }
        view.match_map = {}
        return
    end
    local anchor = view.prompt_snapshot and view.prompt_snapshot.top or view.top
    M.search(view, view.prompt, height, view.prompt_direction, true, anchor)
end

local function is_printable_key(key)
    if not key or #key == 0 then
        return false
    end
    if #key == 1 then
        local byte = key:byte()
        return byte >= 32 and byte < 127
    end
    return key:match("^[\194-\244][\128-\191]+$") ~= nil
end

function M.handle_key(view, key, height)
    height = height or 24
    if view.mode == "help" then
        if key == "q" or key == "h" or key == "ESC" or key == "ENTER" then
            view.mode = "normal"
        end
        return true
    end

    if view.mode == "search" then
        if key == "ESC" then
            local snapshot = view.prompt_snapshot
            if snapshot then
                view.top = snapshot.top
                view.search = snapshot.search
                view.match_map = snapshot.match_map
            end
            view.prompt_snapshot = nil
            view.mode = "normal"
            view.prompt = ""
            view.message = "search cancelled"
            view.message_kind = "info"
        elseif key == "ENTER" then
            local query = view.prompt
            local direction = view.prompt_direction or 1
            view.mode = "normal"
            view.prompt = ""
            view.prompt_snapshot = nil
            if #query == 0 then
                view.search = { query = "", matches = {}, index = 0, direction = direction }
                view.match_map = {}
                view.message = "search cleared"
                view.message_kind = "info"
            elseif #view.search.matches == 0 then
                view.message = "pattern not found: " .. query
                view.message_kind = "warn"
            else
                local index = view.search.index
                if index < 1 then
                    index = direction < 0 and #view.search.matches or 1
                end
                goto_match(view, index, height)
            end
        elseif key == "BACKSPACE" then
            view.prompt = view.prompt:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
            preview_search(view, height)
        elseif key == "SPACE" then
            view.prompt = view.prompt .. " "
            preview_search(view, height)
        elseif key == "TAB" then
            view.prompt = view.prompt .. "    "
            preview_search(view, height)
        elseif is_printable_key(key) then
            view.prompt = view.prompt .. key
            preview_search(view, height)
        end
        return true
    end

    view.message = ""
    view.message_kind = "info"
    local rows = page_rows(height)

    local half = math.max(1, math.floor(rows / 2))
    if key == "q" or key == "ESC" or key == "CTRL_C" then
        view.quit = true
    elseif key == "j" or key == "DOWN" or key == "CTRL_E" then
        view.top = view.top + 1
    elseif key == "k" or key == "UP" or key == "CTRL_Y" then
        view.top = view.top - 1
    elseif key == "d" or key == "CTRL_D" or key == "PAGE_DOWN" then
        view.top = view.top + half
    elseif key == "u" or key == "CTRL_U" or key == "PAGE_UP" then
        view.top = view.top - half
    elseif key == "SPACE" or key == "CTRL_F" then
        view.top = view.top + rows
    elseif key == "b" or key == "CTRL_B" then
        view.top = view.top - rows
    elseif key == "g" or key == "HOME" or key == "0" or key == "^" then
        view.top = 1
    elseif key == "G" or key == "END" or key == "$" then
        view.top = max_top(view, height)
    elseif key == "/" then
        begin_search(view, 1)
    elseif key == "?" then
        begin_search(view, -1)
    elseif key == "n" then
        if #view.search.matches > 0 then
            goto_match(view, view.search.index + (view.search.direction or 1), height)
        else
            view.message = "no active search - press / or ? to search"
            view.message_kind = "warn"
        end
    elseif key == "N" then
        if #view.search.matches > 0 then
            goto_match(view, view.search.index - (view.search.direction or 1), height)
        else
            view.message = "no active search - press / or ? to search"
            view.message_kind = "warn"
        end
    elseif key == "h" then
        view.mode = "help"
    end

    M.clamp_view(view, height)
    return true
end

-- =========================================================================
-- 10. Frame Renderer (pure, headless-friendly)
-- =========================================================================
local function pad_styled(text, width, style)
    local clipped = clip_to_width(text, width)
    local padding = width - display_width(clipped)
    local spans = {}
    add_span(spans, clipped .. string.rep(" ", math.max(0, padding)), style)
    return spans_to_ansi(spans, width, false)
end

local function help_lines(width)
    local cache = M._help_cache
    if not cache then
        cache = {}
        M._help_cache = cache
    end
    if not cache[width] then
        cache[width] = M.render(HELP_TEXT, width)
    end
    return cache[width]
end

function M.render_frame(view, width, height)
    width = math.max(1, math.floor(width))
    height = math.max(1, math.floor(height))
    local frame = { rows = {}, plain = {} }

    local function set_row(row, ansi)
        frame.rows[row] = ansi
        frame.plain[row] = strip_ansi(ansi)
    end

    if width < 24 or height < 4 then
        set_row(1, pad_styled("terminal too small (24x4 required) - q quits", width, STYLE.warn))
        for row = 2, height do
            set_row(row, string.rep(" ", width))
        end
        return frame
    end

    local rows = page_rows(height)
    M.clamp_view(view, height)

    local percent = 0
    if #view.lines > 1 then
        percent = math.floor((view.top - 1) / (#view.lines - 1) * 100)
    end
    local right = string.format("%3d%%  %d/%d ", percent, view.top, #view.lines)
    local available = math.max(0, width - display_width(right))
    local title = " mdview " .. view.title
    local header_text = clip_to_width(title, available) .. string.rep(" ",
        available - display_width(clip_to_width(title, available))) .. right
    set_row(1, pad_styled(header_text, width, STYLE.bar))

    local content = view.lines
    local gutter = view.gutter_width or 0
    if view.mode == "help" then
        content = help_lines(width)
        gutter = 0
    end

    for row = 1, rows do
        local line = content[view.top + row - 1]
        if line then
            local spans = {}
            if gutter > 0 then
                if line.number then
                    add_span(spans,
                        string.format("%" .. (gutter - 1) .. "d ", line.number),
                        STYLE.line_number)
                else
                    add_span(spans, string.rep(" ", gutter), nil)
                end
            end
            local content_spans = line.spans
            local ranges = view.match_map[view.top + row - 1]
            if view.mode ~= "help" and ranges then
                content_spans = highlight_spans(content_spans, ranges)
            end
            for _, span in ipairs(content_spans) do
                add_span(spans, span.text, span.style)
            end
            set_row(row + 1, spans_to_ansi(spans, width, true))
        else
            set_row(row + 1, string.rep(" ", width))
        end
    end

    local status_text
    local status_style = STYLE.bar
    if view.mode == "search" then
        local marker = (view.prompt_direction or 1) < 0 and " ?" or " /"
        status_text = marker .. view.prompt .. "▏  Enter: search   Esc: cancel"
        status_style = merge_style(STYLE.bar, { fg = THEME.warn })
    elseif view.mode == "help" then
        status_text = " help - press h or Esc to close, q to quit"
    elseif view.message and #view.message > 0 then
        status_text = " " .. view.message
        status_style = merge_style(STYLE.bar,
            view.message_kind == "warn" and { fg = THEME.warn } or { fg = THEME.info })
    else
        status_text = " q quit  j/k scroll  Ctrl-d/u  Space/b page  g/G  / ? search  n/N  h help"
    end
    set_row(height, pad_styled(status_text, width, status_style))

    return frame
end

-- =========================================================================
-- 11. POSIX Terminal Layer
-- =========================================================================
local Terminal = {
    in_raw_mode = false,
    interrupted = false,
}

local signal_handler_ref
local pending_input = ""
local poll_fd
local read_buffer

if not IS_WINDOWS then
    local function posix_termios_cdef(def)
        if ffi.os == "OSX" or ffi.os == "BSD" then
            def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
            def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
            def = def:gsub("c_cc%[32%]", "c_cc[20]")
        end
        return def
    end

    pcall(ffi.cdef, posix_termios_cdef([[
        struct mdview_winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        typedef unsigned char mdview_cc_t;
        typedef unsigned int mdview_speed_t;
        typedef unsigned int mdview_tcflag_t;
        struct mdview_termios {
            mdview_tcflag_t c_iflag;
            mdview_tcflag_t c_oflag;
            mdview_tcflag_t c_cflag;
            mdview_tcflag_t c_lflag;
            mdview_cc_t     c_line;
            mdview_cc_t     c_cc[32];
            mdview_speed_t  c_ispeed;
            mdview_speed_t  c_ospeed;
        };
        struct mdview_pollfd {
            int   fd;
            short events;
            short revents;
        };
        typedef void (*mdview_signal_handler)(int);
        int tcgetattr(int fd, struct mdview_termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct mdview_termios *termios_p);
        int ioctl(int fd, unsigned long request, ...);
        int poll(struct mdview_pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, unsigned long count);
        int isatty(int fd);
        mdview_signal_handler signal(int signum, mdview_signal_handler handler);
    ]]))

    local STDIN = 0
    local STDOUT = 1
    local TCSANOW = 0
    local ICANON = 0x0002
    local ECHO = 0x0008
    local ISIG = 0x0001
    local POLLIN = 0x0001
    local TIOCGWINSZ = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413

    local original_termios = ffi.new("struct mdview_termios")
    local raw_termios = ffi.new("struct mdview_termios")
    poll_fd = ffi.new("struct mdview_pollfd", { fd = STDIN, events = POLLIN, revents = 0 })
    read_buffer = ffi.new("char[256]")
    local original_signals = {}

    signal_handler_ref = ffi.cast("mdview_signal_handler", function()
        Terminal.interrupted = true
    end)

    Terminal.is_tty = function(fd)
        return ffi.C.isatty(fd or STDOUT) == 1
    end

    Terminal.get_size = function()
        local size = ffi.new("struct mdview_winsize")
        if ffi.C.ioctl(STDOUT, TIOCGWINSZ, size) == 0
            and tonumber(size.ws_col) > 0 and tonumber(size.ws_row) > 0 then
            return tonumber(size.ws_col), tonumber(size.ws_row)
        end
        return 80, 24
    end

    Terminal.enable_raw_mode = function()
        if ffi.C.isatty(STDIN) ~= 1 then
            return false
        end
        if ffi.C.tcgetattr(STDIN, original_termios) ~= 0 then
            io.stderr:write("mdview: cannot read terminal attributes (errno "
                .. ffi.errno() .. ")\n")
            return false
        end
        ffi.copy(raw_termios, original_termios, ffi.sizeof(raw_termios))
        raw_termios.c_lflag = bit.band(raw_termios.c_lflag,
            bit.bnot(bit.bor(ICANON, ECHO, ISIG)))
        if ffi.C.tcsetattr(STDIN, TCSANOW, raw_termios) ~= 0 then
            io.stderr:write("mdview: cannot enable raw mode (errno "
                .. ffi.errno() .. ")\n")
            return false
        end

        Terminal.in_raw_mode = true
        for _, number in ipairs({ 1, 2, 15 }) do
            local previous = ffi.C.signal(number, signal_handler_ref)
            if previous ~= ffi.cast("mdview_signal_handler", -1) then
                original_signals[number] = previous
            end
        end

        io.write("\27[?1049h\27[?25l\27[?7l\27[H\27[2J")
        io.flush()
        return true
    end

    Terminal.disable_raw_mode = function()
        pending_input = ""
        if not Terminal.in_raw_mode then
            return
        end
        Terminal.in_raw_mode = false
        io.write("\27[0m\27[?7h\27[?1049l\27[?25h")
        io.flush()
        if ffi.C.tcsetattr(STDIN, TCSANOW, original_termios) ~= 0 then
            io.stderr:write("mdview: cannot restore terminal attributes; run 'stty sane'\n")
        end
        for number, handler in pairs(original_signals) do
            ffi.C.signal(number, handler)
        end
        original_signals = {}
    end
else
    Terminal.is_tty = function()
        return false
    end
    Terminal.get_size = function()
        return 80, 24
    end
    Terminal.enable_raw_mode = function()
        return false
    end
    Terminal.disable_raw_mode = function() end
end

-- =========================================================================
-- 12. Key Decoding
-- =========================================================================
local KEY_SEQUENCES = {
    ["\27[A"] = "UP",
    ["\27[B"] = "DOWN",
    ["\27[C"] = "RIGHT",
    ["\27[D"] = "LEFT",
    ["\27OA"] = "UP",
    ["\27OB"] = "DOWN",
    ["\27OC"] = "RIGHT",
    ["\27OD"] = "LEFT",
    ["\27[H"] = "HOME",
    ["\27[F"] = "END",
    ["\27OH"] = "HOME",
    ["\27OF"] = "END",
    ["\27[1~"] = "HOME",
    ["\27[4~"] = "END",
    ["\27[7~"] = "HOME",
    ["\27[8~"] = "END",
    ["\27[5~"] = "PAGE_UP",
    ["\27[6~"] = "PAGE_DOWN",
    ["\27[3~"] = "DELETE",
}

local KEY_TOKENS = {
    [" "] = "SPACE",
    ["\t"] = "TAB",
    ["\r"] = "ENTER",
    ["\n"] = "ENTER",
    ["\8"] = "BACKSPACE",
    ["\127"] = "BACKSPACE",
    ["\3"] = "CTRL_C",
}

local function decode_key(pending, final)
    for sequence, token in pairs(KEY_SEQUENCES) do
        if pending:sub(1, #sequence) == sequence then
            return token, pending:sub(#sequence + 1)
        end
    end

    if pending == "\27" then
        if final then
            return "ESC", ""
        end
        return nil, pending
    end

    if not final then
        for sequence in pairs(KEY_SEQUENCES) do
            if #pending < #sequence and sequence:sub(1, #pending) == pending then
                return nil, pending
            end
        end
    end

    local first = pending:byte(1)
    if not first then
        return nil, ""
    end
    local length = 1
    if first >= 240 then
        length = 4
    elseif first >= 224 then
        length = 3
    elseif first >= 192 then
        length = 2
    end
    if length > 1 and #pending < length and not final then
        return nil, pending
    end
    local char = pending:sub(1, math.min(length, #pending))
    local token = KEY_TOKENS[char]
    if not token and #char == 1 and first >= 1 and first <= 26 then
        token = "CTRL_" .. string.char(64 + first)
    end
    return token or char, pending:sub(#char + 1)
end

local function read_key(timeout_ms)
    if Terminal.interrupted or IS_WINDOWS then
        return nil
    end
    if not Terminal.is_tty() then
        return nil
    end

    if #pending_input > 0 then
        local key
        key, pending_input = decode_key(pending_input, false)
        if key then
            return key
        end
    end

    local wait = #pending_input > 0 and 25 or (timeout_ms or 100)
    local ready = ffi.C.poll(poll_fd, 1, wait)
    if ready > 0 and bit.band(poll_fd.revents, 0x0001) ~= 0 then
        local count = ffi.C.read(0, read_buffer, 256)
        if count > 0 then
            pending_input = pending_input .. ffi.string(read_buffer, tonumber(count))
        elseif count == 0 then
            return "EOF"
        else
            local errno = ffi.errno()
            if errno ~= 4 then
                error("mdview: cannot read terminal input (errno " .. errno .. ")", 0)
            end
        end
    elseif ready < 0 and ffi.errno() ~= 4 then
        error("mdview: cannot poll terminal input (errno " .. ffi.errno() .. ")", 0)
    end

    if #pending_input > 0 then
        local key
        key, pending_input = decode_key(pending_input, ready == 0)
        return key
    end
    return nil
end

-- =========================================================================
-- 13. Interactive Pager
-- =========================================================================
local function draw_frame(view, width, height, previous_rows)
    local frame = M.render_frame(view, width, height)
    local parts = { "\27[?2026h" }
    for row = 1, height do
        local content = frame.rows[row] or ""
        if previous_rows[row] ~= content then
            parts[#parts + 1] = string.format("\27[%d;1H%s\27[K", row, content)
            previous_rows[row] = content
        end
    end
    parts[#parts + 1] = "\27[?2026l"
    io.write(table.concat(parts))
    io.flush()
end

local function run_pager(title, lines, initial_search)
    if not Terminal.enable_raw_mode() then
        io.stderr:write("mdview: interactive pager requires a POSIX terminal;"
            .. " printing the rendered document instead\n")
        return false
    end

    local view = M.new_view(title, lines)
    if initial_search and #initial_search > 0 then
        local width, height = Terminal.get_size()
        view.top = 1
        M.search(view, initial_search, height)
    end

    local width, height = Terminal.get_size()
    local previous_rows = {}
    local redraw = true

    local ok, err = xpcall(function()
        while not view.quit and not Terminal.interrupted do
            local new_width, new_height = Terminal.get_size()
            if new_width ~= width or new_height ~= height then
                width, height = new_width, new_height
                previous_rows = {}
                -- A resize is one of the few cases where a full clear is safe.
                io.write("\27[H\27[2J")
                io.flush()
                redraw = true
            end
            if redraw then
                draw_frame(view, math.max(1, width - 1), height, previous_rows)
                redraw = false
            end

            local key = read_key(200)
            if key then
                M.handle_key(view, key, height)
                M.clamp_view(view, height)
                redraw = true
            end
        end
    end, debug.traceback)

    Terminal.disable_raw_mode()
    if not ok then
        error(err, 0)
    end
    io.write("\n")
    io.flush()
    return true
end

-- =========================================================================
-- 14. CLI
-- =========================================================================
local function usage(stream)
    stream:write([[
mdview - terminal Markdown viewer (LuaJIT + FFI)

USAGE:
  luajit mdview.lua [OPTIONS] FILE.md

OPTIONS:
  -w, --width N        Wrap width for non-interactive output (default 80)
  --no-pager           Render the document and exit
  --color              Keep ANSI colors when output is not a tty
  --no-images          Show image placeholders instead of block art
  -n, --numbers        Show source line numbers (default in the pager)
  --no-numbers         Hide source line numbers
  --snapshot [WxH]     Print one TUI frame and exit (default 80x24)
  --search PATTERN     Pre-fill search (useful with --snapshot)
  -h, --help           Show this help

KEYS:
  q/Esc quit   j/k scroll   d/u half-page   Space/b page
  g/G ends     / search      n/N next match   h/? help
]])
    stream:flush()
end

local function read_document(path)
    local data
    if path == "-" then
        data = io.read("*a")
        if not data then
            return nil, "cannot read standard input"
        end
    else
        local file, err = io.open(path, "rb")
        if not file then
            return nil, err or "cannot open file"
        end
        data = file:read("*a")
        file:close()
        if not data then
            return nil, "cannot read file contents"
        end
    end
    if data:find("%z") then
        return nil, "not a text file (contains NUL bytes)"
    end
    return data
end

local function document_title(path)
    if path == "-" then
        return "stdin"
    end
    return path:match("([^/\\]+)$") or path
end

local function parse_arguments(argv)
    local options = {
        width = 80,
        color = false,
        pager = true,
        images = true,
        numbers = nil,
        snapshot = nil,
        search = nil,
    }
    local index = 1
    while index <= #argv do
        local value = argv[index]
        if value == "-h" or value == "--help" then
            options.help = true
        elseif value == "--no-pager" then
            options.pager = false
        elseif value == "--color" then
            options.color = true
        elseif value == "--no-images" then
            options.images = false
        elseif value == "-n" or value == "--numbers" then
            options.numbers = true
        elseif value == "--no-numbers" then
            options.numbers = false
        elseif value == "--snapshot" then
            local following = argv[index + 1]
            if following and following:match("^%d+x%d+$") then
                options.snapshot = following
                index = index + 1
            else
                options.snapshot = "80x24"
            end
        elseif value:match("^%-%-snapshot=") then
            options.snapshot = value:sub(#"--snapshot=" + 1)
        elseif value == "--search" then
            options.search = argv[index + 1]
            if not options.search then
                return nil, "--search requires a pattern"
            end
            index = index + 1
        elseif value:match("^%-%-search=") then
            options.search = value:sub(#"--search=" + 1)
        elseif value == "-w" or value == "--width" then
            local following = argv[index + 1]
            if not following or not tonumber(following) then
                return nil, value .. " requires a numeric width"
            end
            options.width = tonumber(following)
            index = index + 1
        elseif value:match("^%-%-width=") then
            options.width = tonumber(value:sub(#"--width=" + 1))
        elseif value:sub(1, 1) == "-" and value ~= "-" then
            return nil, "unknown option: " .. value
        elseif options.file then
            return nil, "unexpected extra argument: " .. value
        else
            options.file = value
        end
        index = index + 1
    end
    if options.width < 20 then
        return nil, "--width must be at least 20"
    end
    return options
end

local function gutter_text(line, gutter)
    if gutter <= 0 then
        return ""
    end
    if line.number then
        return string.format("%" .. (gutter - 1) .. "d ", line.number)
    end
    return string.rep(" ", gutter)
end

local function print_document(title, lines, options)
    local gutter = lines.gutter_width or 0
    for _, line in ipairs(lines) do
        local prefix = gutter_text(line, gutter)
        if options.color then
            local spans = {}
            if #prefix > 0 then
                add_span(spans, prefix, line.number and STYLE.line_number or nil)
            end
            for _, span in ipairs(line.spans) do
                add_span(spans, span.text, span.style)
            end
            io.write(spans_to_ansi(spans, math.huge, false), "\n")
        else
            io.write(prefix .. line.text:gsub("[ \t]+$", ""), "\n")
        end
    end
    io.flush()
end

local function run_snapshot(title, lines, specification, search)
    local columns, rows = specification:match("^(%d+)x(%d+)$")
    columns = math.max(1, math.min(500, tonumber(columns) or 80))
    rows = math.max(1, math.min(200, tonumber(rows) or 24))
    local view = M.new_view(title, lines)
    if search and #search > 0 then
        M.search(view, search, rows)
    end
    local frame = M.render_frame(view, columns, rows)
    for row = 1, rows do
        io.write(frame.rows[row] or string.rep(" ", columns), "\n")
    end
    io.flush()
    return frame
end

local function main(argv)
    local options, option_error = parse_arguments(argv)
    if not options then
        io.stderr:write("mdview: " .. option_error .. "\n")
        io.stderr:write("Try 'luajit mdview.lua --help' for usage.\n")
        return 1
    end
    if options.help then
        usage(io.stdout)
        return 0
    end
    if not options.file then
        io.stderr:write("mdview: no input file given\n")
        usage(io.stderr)
        return 1
    end

    local data, read_error = read_document(options.file)
    if not data then
        io.stderr:write("mdview: cannot open '" .. options.file .. "': "
            .. tostring(read_error) .. "\n")
        return 1
    end

    local title = document_title(options.file)
    local interactive = options.pager and not IS_WINDOWS and Terminal.is_tty(1)
        and Terminal.is_tty(0)
    local width = options.width
    if interactive then
        local columns = Terminal.get_size()
        width = math.max(20, columns - 1)
    end

    local base_dir = "."
    if options.file ~= "-" then
        base_dir = options.file:match("^(.*[/\\])") or "."
    end
    local show_images = options.images
        and (options.snapshot ~= nil or options.color or interactive)
    local show_numbers = options.numbers
    if show_numbers == nil then
        show_numbers = interactive or options.snapshot ~= nil
    end
    local render_options = {
        base_dir = base_dir,
        images = show_images,
        numbers = show_numbers,
    }
    local lines = M.render(data, width, render_options)

    if options.snapshot then
        run_snapshot(title, lines, options.snapshot, options.search)
        return 0
    end

    if interactive then
        local ok = run_pager(title, lines, options.search)
        if ok then
            return 0
        end
    elseif options.pager and IS_WINDOWS and Terminal.is_tty(1) then
        io.stderr:write("mdview: interactive pager is unavailable on Windows;"
            .. " showing plain output\n")
    end

    print_document(title, M.render(data, options.width, render_options), options)
    return 0
end

-- =========================================================================
-- 15. Entry Point
-- =========================================================================
M.Terminal = Terminal
M.parse_blocks = parse_blocks
M.parse_inline = parse_inline
M.find_matches = find_matches
M.highlight_spans = highlight_spans
M.spans_to_ansi = spans_to_ansi
M.style_to_ansi = style_to_ansi
M.strip_ansi = strip_ansi
M.display_width = display_width
M.clip_to_width = clip_to_width
M.expand_tabs = expand_tabs
M.render_frame = M.render_frame
M.handle_key = M.handle_key
M.search = M.search
M.new_view = M.new_view
M.HELP_TEXT = HELP_TEXT
M.main = main
M.usage = usage
M.read_document = read_document

local script_name = arg and arg[0] and arg[0]:match("([^/\\]+)$") or ""
if script_name ~= "mdview.lua" then
    return M
end

local ok, result = xpcall(function()
    return main(arg or {})
end, debug.traceback)

Terminal.disable_raw_mode()

if not ok then
    io.stderr:write("mdview: " .. tostring(result) .. "\n")
    io.stderr:flush()
    os.exit(1)
end

os.exit(tonumber(result) or 0)
