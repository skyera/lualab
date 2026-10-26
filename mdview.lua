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
    - Dark and light terminal palettes (--theme) plus NO_COLOR-compatible output.
    - Unicode-aware word wrapping (wide characters, combining marks, tabs).
    - Raw-mode pager via FFI on both POSIX (termios + poll) and Windows
      (Win32 console + VT sequences): alternate screen, resize handling,
      flicker-free differential row updates and a source line-number gutter.
    - Incremental case-insensitive search with match highlighting.
    - Filterable heading outline (t), with source-anchored navigation.
    - Lazy Markdown file tree with folder/file icons and Vim navigation.
    - Pure render/frame functions for headless tests and --snapshot output.
    - Optional Win32 GUI (--gui): a native window that follows the Windows
      theme. The file list is a SysTreeView32 common control with standard
      Explorer folder/file icons from the shell image list; the Markdown page
      is drawn with GDI. No toolkits or extra DLLs; folders load lazily, the
      document re-wraps on resize, and the mouse (click, double-click, wheel)
      plus the keyboard navigate both panes.

    Usage:
      luajit mdview.lua                         # Browse the current directory
      luajit mdview.lua docs/                   # Browse a documentation folder
      luajit mdview.lua README.md
      luajit mdview.lua --width 100 --no-pager README.md
      luajit mdview.lua --snapshot 100x30 README.md
      luajit mdview.lua --gui docs/             # Windows GUI with file tree
      cat README.md | luajit mdview.lua -

    Keys:
      q / Esc       quit                    j / Down      scroll down
      k / Up        scroll up               Ctrl-e/y      scroll line down/up
      d / Ctrl-d    half page down          u / Ctrl-u    half page up
      Space/Ctrl-f  page down               b / Ctrl-b    page up
      g / Home      top                     G / End       bottom
      / and ?       search forward/back     n / N         next / previous
      h             toggle help             t             heading outline
      f             toggle file tree        Tab           switch panes
      Tree: j/k move, h/l collapse/expand/open, gg/G first/last, ? help

    GUI keys:
      Tree: arrows move, Left/Right fold, Enter opens, Tab switches pane
      Document: arrows, PgUp/PgDn, Home/End scroll; mouse wheel scrolls
      Click a folder to expand it; double-click a file or press Enter to open

    Options:
      -w, --width N        wrap width for non-interactive output (default 80)
      --no-pager           render the document and exit
      --color              keep ANSI colors when output is not a tty
      --no-color           disable ANSI colors (also honors NO_COLOR)
      --theme dark|light   terminal palette (default: dark; GUI uses Windows)
      --no-images          show image placeholders instead of block art
      -n, --numbers        show source line numbers (default in the pager)
      --no-numbers         hide source line numbers
      --snapshot [WxH]     print one TUI frame and exit (default 80x24)
      --search PATTERN     pre-fill search (useful with --snapshot)
      --gui                open the Windows GUI (Win32 SDK, requires Windows)
      -h, --help           show this help
]]

local ffi = require("ffi")
local bit = require("bit")

local IS_WINDOWS = (ffi.os == "Windows")
local M = { VERSION = "1.0.0" }

-- =========================================================================
-- 1. Text Utilities: UTF-8 Width, Truncation, ANSI Helpers
-- =========================================================================
local function next_char(text, pos)
    local first = text:byte(pos)
    if not first then
        return nil
    end
    if first < 128 then
        return text:sub(pos, pos)
    end
    local length
    if first >= 194 and first <= 223 then
        length = 2
    elseif first >= 224 and first <= 239 then
        length = 3
    elseif first >= 240 and first <= 244 then
        length = 4
    else
        return nil
    end
    for index = pos + 1, pos + length - 1 do
        local byte = text:byte(index)
        if not byte or byte < 128 or byte > 191 then
            return nil
        end
    end
    local second = text:byte(pos + 1)
    if (first == 224 and second < 160) or (first == 237 and second >= 160)
        or (first == 240 and second < 144) or (first == 244 and second > 143) then
        return nil
    end
    return text:sub(pos, pos + length - 1)
end

-- Document bytes must never become terminal commands. Preserve structural
-- newlines/tabs only before parsing; span text is always a single safe row.
local function sanitize_text(text, multiline)
    local out = {}
    local pos = 1
    while pos <= #text do
        local char = next_char(text, pos) or text:sub(pos, pos)
        local byte = char:byte()
        if multiline and (char == "\n" or char == "\t") then
            out[#out + 1] = char
        elseif byte < 32 or byte == 127 then
            out[#out + 1] = byte == 127 and "^?" or "^" .. string.char(byte + 64)
        elseif char:match("^\194[\128-\159]$") then
            out[#out + 1] = string.format("<U+%04X>", char:byte(2))
        elseif #char == 1 and byte >= 128 then
            out[#out + 1] = string.format("<%02X>", byte)
        else
            out[#out + 1] = char
        end
        pos = pos + #char
    end
    return table.concat(out)
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
    "search_current", "link", "code", "code_block", "quote", "fg", "bg", "href",
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
    text = sanitize_text(text)
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
local DARK_PALETTE = {
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
    task_done = "38;2;120;200;140",
    line_number = "38;2;95;105;125",
    search_fg = "30",
    search_bg = "43",
    search_current_fg = "30",
    search_current_bg = "48;2;255;150;60",
    folder_icon = "38;2;240;190;90",
    file_icon = "38;2;120;200;230",
    gui_bg = "48;2;22;26;34",
    gui_panel = "48;2;30;35;44",
    gui_selection = "48;2;52;68;94",
    gui_separator = "48;2;52;60;74",
    gui_accent = "38;2;97;175;239",
}

local LIGHT_PALETTE = {
    text = "38;2;40;46;58",
    heading1 = "38;2;24;74;158",
    heading2 = "38;2;0;110;120",
    heading3 = "38;2;100;55;150",
    heading4 = "38;2;142;88;0",
    rule1 = "38;2;140;168;205",
    rule2 = "38;2;175;184;196",
    block_bar = "38;2;145;155;172",
    code_fg = "38;2;150;92;0",
    code_bg = "48;2;238;241;246",
    code_block_fg = "38;2;58;68;84",
    quote_fg = "38;2;74;100;145",
    link = "38;2;0;90;186",
    marker = "38;2;36;84;164",
    table_border = "38;2;145;155;172",
    table_header = "38;2;28;36;48",
    bar_fg = "38;2;28;36;48",
    bar_bg = "48;2;226;231;238",
    info = "38;2;0;104;132",
    warn = "38;2;154;98;0",
    task_done = "38;2;22;120;70",
    line_number = "38;2;128;138;154",
    search_fg = "30",
    search_bg = "43",
    search_current_fg = "30",
    search_current_bg = "48;2;255;165;70",
    folder_icon = "38;2;180;120;0",
    file_icon = "38;2;0;104;180",
    gui_bg = "48;2;250;251;253",
    gui_panel = "48;2;238;241;246",
    gui_selection = "48;2;208;224;244",
    gui_separator = "48;2;200;207;217",
    gui_accent = "38;2;0;90;186",
}

local THEME = {}
local STYLE = {}
local COLOR_ENABLED = true

local function apply_palette(palette)
    for key in pairs(THEME) do
        THEME[key] = nil
    end
    for key, value in pairs(palette) do
        THEME[key] = value
    end
    STYLE.heading = {
        { bold = true, fg = THEME.heading1 },
        { bold = true, fg = THEME.heading2 },
        { bold = true, fg = THEME.heading3 },
        { bold = true, fg = THEME.heading4 },
        { bold = true, dim = true },
        { dim = true, italic = true },
    }
    STYLE.rule = {
        { fg = THEME.rule1 },
        { fg = THEME.rule2 },
    }
    STYLE.code_block = { code_block = true }
    STYLE.block_bar = { fg = THEME.block_bar }
    STYLE.quote_text = { italic = true, quote = true }
    STYLE.marker = { bold = true, fg = THEME.marker }
    STYLE.table_border = { fg = THEME.table_border }
    STYLE.table_header = { bold = true, fg = THEME.table_header }
    STYLE.task_done = { fg = THEME.task_done }
    STYLE.line_number = { fg = THEME.line_number }
    STYLE.search = { search = true }
    STYLE.search_current = { search_current = true }
    STYLE.bar = { bold = true, fg = THEME.bar_fg, bg = THEME.bar_bg }
    STYLE.info = { fg = THEME.info }
    STYLE.warn = { fg = THEME.warn }
    STYLE.folder_icon = { fg = THEME.folder_icon, bold = true }
    STYLE.file_icon = { fg = THEME.file_icon }
end

apply_palette(DARK_PALETTE)

function M.set_theme(name)
    if name == "dark" then
        apply_palette(DARK_PALETTE)
        return true
    elseif name == "light" then
        apply_palette(LIGHT_PALETTE)
        return true
    end
    return false, "unknown theme: " .. tostring(name)
end

function M.set_color(enabled)
    COLOR_ENABLED = enabled and true or false
    return COLOR_ENABLED
end

function M.color_enabled()
    return COLOR_ENABLED
end

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
    if style.search_current then
        fg = fg or THEME.search_current_fg
        bg = THEME.search_current_bg
        add("1")
    elseif style.search then
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

local function plain_spans(spans, max_width, pad)
    local parts = {}
    local used = 0
    for _, span in ipairs(spans) do
        if used >= max_width then
            break
        end
        local text, width = clip_to_width(sanitize_text(span.text), max_width - used)
        if #text > 0 then
            parts[#parts + 1] = text
            used = used + width
        end
    end
    if pad and used < max_width then
        parts[#parts + 1] = string.rep(" ", max_width - used)
    end
    return table.concat(parts)
end

local function spans_to_ansi(spans, max_width, pad)
    if not COLOR_ENABLED then
        return plain_spans(spans, max_width, pad)
    end
    local parts = {}
    local used = 0
    for _, span in ipairs(spans) do
        if used >= max_width then
            break
        end
        local text, width = clip_to_width(sanitize_text(span.text), max_width - used)
        if #text > 0 then
            local ansi = style_to_ansi(span.style)
            local href = span.style and span.style.href
            if href and sanitize_text(href) ~= href then
                href = nil
            end
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

local function parse_inline(text, base, defs, footnote_state)
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
                append_children(parse_inline(inner, child, defs, footnote_state))
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
                append_children(parse_inline(inner, merge_style(base, { strike = true }),
                    defs, footnote_state))
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
        elseif char == "[" and text:sub(index + 1, index + 1) == "^" then
            local id, stop = text:match("^%[%^([^%]]+)%]()", index)
            local key = id and id:lower()
            if key and footnote_state and footnote_state.definitions[key] then
                local number = footnote_state.order[key]
                if not number then
                    footnote_state.count = footnote_state.count + 1
                    number = footnote_state.count
                    footnote_state.order[key] = number
                    footnote_state.used[number] = key
                end
                flush()
                add_span(spans, string.format("[%d]", number), merge_style(base, {
                    underline = true,
                    href = "#fn-" .. key,
                }))
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
                    }), defs, footnote_state))
                else
                    append_children(parse_inline(label, base, defs, footnote_state))
                end
                index = stop
            else
                local ref_label, reference, ref_stop = text:match(
                    "^%[([^%]]*)%]%[([^%]]*)%]()", index)
                local key = ref_label and (reference == "" and ref_label or reference):lower()
                local definition = key and defs and defs[key]
                if definition then
                    flush()
                    append_children(parse_inline(ref_label, merge_style(base, {
                        underline = true,
                        href = definition.url,
                    }), defs, footnote_state))
                    index = ref_stop
                else
                    buffer[#buffer + 1] = char
                    index = index + 1
                end
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
                tokens[#tokens + 1] = { space = true, style = span.style }
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
    local pending_space_style = nil
    for _, token in ipairs(tokens) do
        if token.space then
            pending_space = has_content
            pending_space_style = token.style
        else
            local word = token.text
            local word_width = display_width(word)
            local need_space = has_content and pending_space

            if has_content and current_width + (need_space and 1 or 0) + word_width > width then
                finish_line()
                need_space = false
            end
            if need_space then
                add_span(current, " ", pending_space_style)
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
            pending_space_style = nil
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

local function collect_definitions(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line:gsub("\r$", "")
    end
    if lines[#lines] == "" then
        lines[#lines] = nil
    end

    local defs = {}
    local footnotes = {}
    local fence_char
    local fence_length = 0

    for index, raw in ipairs(lines) do
        local opening = raw:match("^%s*(`+)%s*.*$") or raw:match("^%s*(~+)%s*.*$")
        if opening and #opening < 3 then
            opening = nil
        end
        if fence_char then
            local closing = raw:match("^%s*(" .. fence_char .. "+)%s*$")
            if closing and #closing >= fence_length then
                fence_char = nil
                fence_length = 0
            end
        elseif opening then
            fence_char = opening:sub(1, 1)
            fence_length = #opening
        else
            local id, rest = raw:match("^%s*%[([^%]]+)%]:%s*(.-)%s*$")
            if id and #rest > 0 then
                if id:sub(1, 1) == "^" then
                    local key = id:sub(2):lower()
                    if #key > 0 and not footnotes[key] then
                        footnotes[key] = { text = rest, line = index }
                    end
                    lines[index] = ""
                else
                    local url = rest:match("^<([^>]*)>") or rest:match("^(%S+)")
                    local is_url = url and (url:match("^%a[%w%+%.%-]*://")
                        or url:sub(1, 1) == "/" or url:sub(1, 1) == "#"
                        or url:sub(1, 2) == "./" or url:sub(1, 3) == "../"
                        or url:match("^mailto:"))
                    if is_url then
                        defs[id:lower()] = { url = url, line = index, label = id }
                        lines[index] = ""
                    end
                end
            end
        end
    end

    return table.concat(lines, "\n"), defs, footnotes
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

local function render_heading(block, width, out, context)
    local level = math.max(1, math.min(6, block.level))
    local style = STYLE.heading[level]
    local spans = parse_inline(block.text, style, context.defs, context.footnote_state)
    context.headings[#context.headings + 1] = {
        text = spans_text(spans),
        level = level,
        line = block.line,
    }
    for position, line in ipairs(wrap_flow(spans, width)) do
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

local function render_list(block, width, out, context)
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
        local wrapped = wrap_flow(parse_inline(text, nil, context.defs, context.footnote_state),
            content_width)
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
    if IS_WINDOWS then
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function read_command_output(command)
    if IS_WINDOWS then
        -- Pipes use text mode on Windows, which would corrupt PPM bytes.
        local temp = os.tmpname()
        os.execute(command .. " > " .. shell_quote(temp) .. " 2>NUL")
        local file = io.open(temp, "rb")
        local data = file and file:read("*a") or nil
        if file then
            file:close()
        end
        os.remove(temp)
        if not data or #data == 0 then
            return nil
        end
        return data
    end
    local pipe = io.popen(command, "r")
    if not pipe then
        return nil
    end
    local data = pipe:read("*a")
    pipe:close()
    return data
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
    local resize = IS_WINDOWS and '"-resize" "256x256>"' or "-resize '256x256>'"
    local commands = {
        "convert " .. escaped .. " " .. resize .. " -depth 8 ppm:-",
        "magick " .. escaped .. " " .. resize .. " -depth 8 ppm:-",
        "ffmpeg -v error -i " .. escaped
            .. ' -vf "scale=min(256\\,iw):min(256\\,ih):force_original_aspect_ratio=decrease"'
            .. " -frames:v 1 -f image2pipe -vcodec ppm -",
    }
    for _, command in ipairs(commands) do
        local data = read_command_output(command)
        if data then
            local image = read_ppm(data)
            if image then
                return image
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
    if IS_WINDOWS and path:match("^/[A-Za-z]:") then
        path = path:sub(2)
    end
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

    -- The GUI paints the decoded bitmap itself, so the block only reserves the
    -- rows it needs and carries the path for the painter.
    if context.gui then
        local pixel_w, pixel_h
        if context.image_size then
            pixel_w, pixel_h = context.image_size(path)
        end
        if not pixel_w then
            local probe = load_image_file(path)
            if probe then
                pixel_w, pixel_h = probe.width, probe.height
            end
        end
        if not pixel_w or not pixel_h or pixel_w <= 0 or pixel_h <= 0 then
            fallback("cannot decode")
            return
        end
        local columns = math.max(1, math.min(width, context.max_image_width or 60, pixel_w))
        local aspect = pixel_h / pixel_w
        local rows = math.max(1, math.floor(columns * aspect * 0.5 + 0.5))
        local max_rows = math.max(1, context.max_image_height or 24)
        if rows > max_rows then
            rows = max_rows
            columns = math.max(1, math.min(width, math.floor(rows * 2 / aspect + 0.5)))
        end
        local spec = {
            path = path,
            src = block.src,
            width = pixel_w,
            height = pixel_h,
            columns = columns,
            rows = rows,
            alt = alt,
        }
        for index = 1, rows do
            local line = make_line({}, index == 1 and block.line or nil)
            line.image = {
                path = spec.path,
                src = spec.src,
                width = spec.width,
                height = spec.height,
                columns = spec.columns,
                rows = spec.rows,
                row = index - 1,
                alt = spec.alt,
            }
            out[#out + 1] = line
        end
        if #alt > 0 then
            local spans = {}
            add_span(spans, alt, { dim = true, italic = true })
            out[#out + 1] = make_line(spans)
        end
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

local function render_table(block, width, out, context)
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
            parsed[row_index][column] = parse_inline(source, nil,
                context.defs, context.footnote_state)
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
            render_heading(block, width, out, context)
        elseif block.kind == "paragraph" then
            local spans = parse_inline(block.text, base_style,
                context.defs, context.footnote_state)
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
            render_list(block, width, out, context)
        elseif block.kind == "table" then
            render_table(block, width, out, context)
        elseif block.kind == "hr" then
            local spans = {}
            add_span(spans, string.rep("─", math.max(1, width)), { fg = THEME.rule2 })
            out[#out + 1] = make_line(spans, block.line)
        end
    end
end

local function append_footnotes(out, width, context)
    local state = context.footnote_state
    if not state or state.count == 0 then
        return
    end
    if #out > 0 then
        out[#out + 1] = make_line({})
    end
    local heading = {}
    add_span(heading, "Notes", STYLE.heading[4])
    out[#out + 1] = make_line(heading)

    for number = 1, state.count do
        local id = state.used[number]
        local definition = state.definitions[id]
        if definition then
            local marker = string.format("[%d] ", number)
            local prefix_width = display_width(marker)
            local body = parse_inline(definition.text, nil, context.defs, state)
            local wrapped = wrap_flow(body, math.max(8, width - prefix_width))
            if #wrapped == 0 then
                wrapped[1] = make_line({})
            end
            for position, line in ipairs(wrapped) do
                local spans = {}
                if position == 1 then
                    add_span(spans, marker, STYLE.marker)
                else
                    add_span(spans, string.rep(" ", prefix_width), nil)
                end
                for _, span in ipairs(line.spans) do
                    add_span(spans, span.text, span.style)
                end
                out[#out + 1] = make_line(spans,
                    position == 1 and definition.line or nil)
            end
        end
    end
end

function M.render(text, width, options)
    text = sanitize_text(text:gsub("\r\n", "\n"), true)
    width = math.max(20, width or 80)
    if type(options) ~= "table" then
        options = {}
    end
    local cleaned, defs, footnotes = collect_definitions(text)
    local footnote_state = {
        definitions = footnotes,
        order = {},
        used = {},
        count = 0,
    }
    local context = {
        base_dir = options.base_dir,
        images = options.images ~= false,
        max_image_width = options.max_image_width or 48,
        max_image_height = options.max_image_height or 16,
        gui = options.gui == true,
        image_size = options.image_size,
        defs = defs,
        footnote_state = footnote_state,
        headings = {},
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
    local content_width = math.max(1, width - gutter)
    local lines = {}
    render_blocks(parse_blocks(cleaned), content_width, lines, nil, context)
    append_footnotes(lines, content_width, context)
    while #lines > 0 and lines[#lines].text == "" do
        lines[#lines] = nil
    end
    lines.gutter_width = gutter
    lines.source = text
    lines.render_options = options
    lines.width = width
    lines.headings = context.headings
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
local function find_matches(lines, query, case_sensitive)
    local matches = {}
    if not query or #query == 0 then
        return matches
    end
    local fold = query:match("^[%z\1-\127]+$") ~= nil and not case_sensitive
    local needle = fold and query:lower() or query
    for line_index, line in ipairs(lines) do
        local haystack = fold and line.text:lower() or line.text
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

local function highlight_spans(spans, ranges, current_index)
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
                local highlight = STYLE.search
                if range.index and range.index == current_index then
                    highlight = STYLE.search_current
                end
                add_span(out, text:sub(local_from, local_to),
                    merge_style(span.style, highlight))
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
| `C` | Toggle case-sensitive search |
| `h` | Toggle this help |
| `t` | Open heading outline |
| `f`, `Tab` | Toggle file tree / switch panes |

In the file tree: j/k or arrows move; h/Left collapses a folder or selects
its parent; l/Right expands a folder or opens a file; Enter opens; gg/G
jumps to first/last; Ctrl-d/u scrolls half a page; r refreshes the selected
folder; ? opens help; Esc returns to the document; q quits.
Folders use 📁/📂 icons and Markdown files use 📄. Hidden files and directory
links are omitted. Narrow terminals show one pane at a time.

In the outline: j/k or arrows select; / filters; Enter jumps to the selected
heading; Esc returns to the document; q quits. Search filters accept spaces
and Unicode text. Help supports the usual scrolling keys.

Search matches are highlighted in yellow. Resize the terminal at any time;
the pager redraws without clearing the screen.
]]

function M.new_view(title, lines)
    return {
        title = sanitize_text(title or "untitled"),
        lines = lines or {},
        gutter_width = lines and lines.gutter_width or 0,
        top = 1,
        search = { query = "", matches = {}, index = 0, direction = 1 },
        case_sensitive = false,
        match_map = {},
        message = "",
        message_kind = "info",
        mode = "normal",
        help_top = 1,
        outline = { query = "", items = {}, selected = 0, top = 1, editing = false },
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
    local matches = find_matches(view.lines, query, view.case_sensitive)
    view.search = {
        query = query,
        matches = matches,
        index = 0,
        direction = direction,
    }
    view.match_map = {}
    for match_index, match in ipairs(matches) do
        local ranges = view.match_map[match.line] or {}
        ranges[#ranges + 1] = {
            start = match.start,
            finish = match.finish,
            index = match_index,
        }
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

local function source_anchor(lines, top)
    for index = math.min(top, #lines), 1, -1 do
        if lines[index].number then
            return lines[index].number
        end
    end
    return 1
end

local function row_for_source(lines, number)
    local nearest = 1
    for index, line in ipairs(lines) do
        if line.number then
            if line.number == number then
                return index
            elseif line.number < number then
                nearest = index
            end
        end
    end
    return nearest
end

function M.reflow(view, width, height)
    width = math.max(20, width)
    local old_lines = view.lines
    if old_lines.source == nil or old_lines.width == width then
        M.clamp_view(view, height)
        return
    end
    local anchor = source_anchor(old_lines, view.top)
    local snapshot = view.prompt_snapshot
    local snapshot_anchor = snapshot and source_anchor(old_lines, snapshot.top)
    view.lines = M.render(old_lines.source, width, old_lines.render_options)
    view.gutter_width = view.lines.gutter_width
    local top = row_for_source(view.lines, anchor)
    local search = view.search
    M.search(view, search.query, height, search.direction, true, top)
    view.top = top
    M.clamp_view(view, height)
    if snapshot then
        local saved = M.new_view(view.title, view.lines)
        saved.case_sensitive = view.case_sensitive
        local saved_top = row_for_source(view.lines, snapshot_anchor)
        M.search(saved, snapshot.search.query, height, snapshot.search.direction, true, saved_top)
        saved.top = saved_top
        M.clamp_view(saved, height)
        view.prompt_snapshot = {
            top = saved.top,
            search = saved.search,
            match_map = saved.match_map,
        }
    end
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

local help_lines

local function clamp_outline(view, height)
    local outline = view.outline
    local count = #outline.items
    if count == 0 then
        outline.selected = 0
        outline.top = 1
        return
    end
    outline.selected = math.max(1, math.min(outline.selected, count))
    local rows = page_rows(height)
    outline.top = math.max(1, math.min(outline.top, count - rows + 1))
    if outline.selected < outline.top then
        outline.top = outline.selected
    elseif outline.selected >= outline.top + rows then
        outline.top = outline.selected - rows + 1
    end
end

local function filter_outline(view, height)
    local outline = view.outline
    local needle = outline.query:lower()
    outline.items = {}
    for _, heading in ipairs(view.lines.headings or {}) do
        if heading.text:lower():find(needle, 1, true) then
            outline.items[#outline.items + 1] = heading
        end
    end
    outline.selected = 1
    outline.top = 1
    clamp_outline(view, height)
end

local function handle_outline_key(view, key, height)
    local outline = view.outline
    if key == "ESC" or (key == "t" and not outline.editing) then
        view.mode = "normal"
    elseif key == "ENTER" then
        local heading = outline.items[outline.selected]
        if heading then
            view.top = row_for_source(view.lines, heading.line)
            M.clamp_view(view, height)
            view.mode = "normal"
            view.message = "heading: " .. heading.text
        end
    elseif key == "UP" or key == "DOWN" then
        outline.selected = outline.selected + (key == "UP" and -1 or 1)
    elseif outline.editing then
        if key == "BACKSPACE" then
            outline.query = outline.query:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
        elseif key == "SPACE" then
            outline.query = outline.query .. " "
        elseif is_printable_key(key) then
            outline.query = outline.query .. key
        end
        filter_outline(view, height)
    elseif key == "q" then
        view.quit = true
    elseif key == "/" then
        outline.editing = true
    elseif key == "j" or key == "k" then
        outline.selected = outline.selected + (key == "k" and -1 or 1)
    elseif key == "g" or key == "HOME" then
        outline.selected = 1
    elseif key == "G" or key == "END" then
        outline.selected = #outline.items
    elseif key == "SPACE" or key == "PAGE_DOWN" or key == "CTRL_F" then
        outline.selected = outline.selected + page_rows(height)
    elseif key == "b" or key == "PAGE_UP" or key == "CTRL_B" then
        outline.selected = outline.selected - page_rows(height)
    end
    clamp_outline(view, height)
end

local function scroll_position(top, key, count, height)
    local rows = page_rows(height)
    if key == "j" or key == "DOWN" or key == "CTRL_E" then
        top = top + 1
    elseif key == "k" or key == "UP" or key == "CTRL_Y" then
        top = top - 1
    elseif key == "d" or key == "CTRL_D" or key == "PAGE_DOWN" then
        top = top + math.max(1, math.floor(rows / 2))
    elseif key == "u" or key == "CTRL_U" or key == "PAGE_UP" then
        top = top - math.max(1, math.floor(rows / 2))
    elseif key == "SPACE" or key == "CTRL_F" then
        top = top + rows
    elseif key == "b" or key == "CTRL_B" then
        top = top - rows
    elseif key == "g" or key == "HOME" or key == "0" or key == "^" then
        top = 1
    elseif key == "G" or key == "END" or key == "$" then
        top = count
    end
    return math.max(1, math.min(top, count - rows + 1))
end

function M.handle_key(view, key, height, width)
    height = height or 24
    if key == "CTRL_C" then
        view.quit = true
        return true
    end
    if view.mode == "outline" then
        handle_outline_key(view, key, height)
        return true
    end
    if view.mode == "help" then
        if key == "q" or key == "CTRL_C" then
            view.quit = true
        elseif key == "h" or key == "ESC" or key == "ENTER" then
            view.mode = "normal"
        else
            view.help_top = scroll_position(view.help_top, key,
                #help_lines(width or view.lines.width or 80), height)
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
    elseif key == "C" then
        view.case_sensitive = not view.case_sensitive
        local query = view.search.query
        if query and #query > 0 then
            M.search(view, query, height, view.search.direction)
            view.message = string.format("%s - %d matches",
                view.case_sensitive and "case-sensitive" or "case-insensitive",
                #view.search.matches)
            view.message_kind = #view.search.matches > 0 and "info" or "warn"
        else
            view.message = view.case_sensitive and "search: case-sensitive"
                or "search: case-insensitive"
            view.message_kind = "info"
        end
    elseif key == "h" then
        view.mode = "help"
        view.help_top = 1
    elseif key == "t" then
        view.mode = "outline"
        view.outline.query = ""
        view.outline.editing = false
        filter_outline(view, height)
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

local function prompt_tail(text, width)
    local pos = 1
    local remaining = display_width(text)
    while remaining > width and pos <= #text do
        local char = next_char(text, pos) or text:sub(pos, pos)
        remaining = remaining - character_width(char)
        pos = pos + #char
    end
    return text:sub(pos)
end

help_lines = function(width)
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

local function render_outline_frame(view, width, height)
    clamp_outline(view, height)
    local outline = view.outline
    local frame = { rows = {}, plain = {} }
    local function set_row(row, text, style)
        frame.rows[row] = pad_styled(text, width, style)
        frame.plain[row] = strip_ansi(frame.rows[row])
    end
    set_row(1, string.format(" Outline  %d/%d  %s",
        outline.selected, #outline.items, view.title), STYLE.bar)
    for row = 1, page_rows(height) do
        local index = outline.top + row - 1
        local heading = outline.items[index]
        if heading then
            local selected = index == outline.selected
            local prefix = (selected and "> " or "  ") .. string.rep("  ", heading.level - 1)
            local suffix = "  " .. heading.line .. " "
            local label_width = math.max(0, width - display_width(suffix))
            local label = clip_to_width(prefix .. heading.text, label_width)
            local text = label .. string.rep(" ", label_width - display_width(label)) .. suffix
            set_row(row + 1, text, selected and { reverse = true } or nil)
        elseif row == 1 then
            local empty = #(view.lines.headings or {}) == 0 and " No headings in this document"
                or " No headings match this filter"
            set_row(row + 1, empty, STYLE.warn)
        else
            set_row(row + 1, "", nil)
        end
    end
    local status = " / filter  j/k select  Enter jump  Esc return  q quit"
    if outline.editing then
        status = " /" .. prompt_tail(outline.query, math.max(0, width - 3))
            .. "▏  Enter jump  Esc return"
    end
    set_row(height, status, STYLE.bar)
    return frame
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
    if view.mode == "outline" then
        return render_outline_frame(view, width, height)
    end

    local rows = page_rows(height)
    M.clamp_view(view, height)

    local content = view.lines
    local gutter = view.gutter_width or 0
    local content_top = view.top
    if view.mode == "help" then
        content = help_lines(width)
        gutter = 0
        view.help_top = math.max(1, math.min(view.help_top, #content - rows + 1))
        content_top = view.help_top
    end

    local percent = 0
    if #content > 1 then
        percent = math.floor((content_top - 1) / (#content - 1) * 100)
    end
    local right = string.format("%3d%%  %d/%d ", percent, content_top, #content)
    local available = math.max(0, width - display_width(right))
    local title = " mdview " .. view.title
    local header_text = clip_to_width(title, available) .. string.rep(" ",
        available - display_width(clip_to_width(title, available))) .. right
    set_row(1, pad_styled(header_text, width, STYLE.bar))

    for row = 1, rows do
        local line = content[content_top + row - 1]
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
                content_spans = highlight_spans(content_spans, ranges, view.search.index)
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
        status_text = " q quit  j/k scroll  / ? search  f files  Tab pane  t outline  h help"
    end

    if view.mode == "normal" and view.search and #view.search.query > 0 then
        local info = string.format(" /%s  %d/%d%s", view.search.query,
            view.search.index, #view.search.matches,
            view.case_sensitive and "  Aa" or "")
        if display_width(info) <= width - 8 then
            local base_width = width - display_width(info)
            local base = clip_to_width(status_text, base_width)
            status_text = base .. string.rep(" ", base_width - display_width(base)) .. info
        end
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
    local kernel32 = ffi.load("kernel32")

    pcall(ffi.cdef, [[
        typedef struct mdview_console_info {
            int16_t  size_x;
            int16_t  size_y;
            int16_t  cursor_x;
            int16_t  cursor_y;
            uint16_t attributes;
            int16_t  left;
            int16_t  top;
            int16_t  right;
            int16_t  bottom;
            int16_t  max_x;
            int16_t  max_y;
        } mdview_console_info;
        void *GetStdHandle(uint32_t nStdHandle);
        int GetConsoleMode(void *handle, uint32_t *mode);
        int SetConsoleMode(void *handle, uint32_t mode);
        int GetConsoleScreenBufferInfo(void *handle, mdview_console_info *info);
        int GetConsoleOutputCP(void);
        int SetConsoleOutputCP(uint32_t code_page);
        void __stdcall Sleep(uint32_t milliseconds);
        int _kbhit(void);
        int _getwch(void);
    ]])

    local STD_INPUT = 0xFFFFFFF6
    local STD_OUTPUT = 0xFFFFFFF5
    local ENABLE_PROCESSED_INPUT = 0x0001
    local ENABLE_LINE_INPUT = 0x0002
    local ENABLE_ECHO_INPUT = 0x0004
    local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

    local original_input_mode = ffi.new("uint32_t[1]")
    local original_output_mode = ffi.new("uint32_t[1]")
    local original_code_page

    local function input_handle()
        return kernel32.GetStdHandle(STD_INPUT)
    end

    local function output_handle()
        return kernel32.GetStdHandle(STD_OUTPUT)
    end

    Terminal.is_tty = function(fd)
        local handle = (fd == 0) and input_handle() or output_handle()
        local mode = ffi.new("uint32_t[1]")
        return kernel32.GetConsoleMode(handle, mode) ~= 0
    end

    Terminal.get_size = function()
        local info = ffi.new("mdview_console_info")
        if kernel32.GetConsoleScreenBufferInfo(output_handle(), info) ~= 0 then
            local width = tonumber(info.right) - tonumber(info.left) + 1
            local height = tonumber(info.bottom) - tonumber(info.top) + 1
            if width > 0 and height > 0 then
                return width, height
            end
        end
        return 80, 24
    end

    local function utf8_from_codepoint(code)
        if code < 0x80 then
            return string.char(code)
        elseif code < 0x800 then
            return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
        elseif code < 0x10000 then
            return string.char(0xE0 + math.floor(code / 4096),
                0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
        end
        return string.char(0xF0 + math.floor(code / 262144),
            0x80 + math.floor(code / 4096) % 64,
            0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end

    local WINDOWS_SPECIAL = {
        [72] = "UP",
        [80] = "DOWN",
        [75] = "LEFT",
        [77] = "RIGHT",
        [71] = "HOME",
        [79] = "END",
        [73] = "PAGE_UP",
        [81] = "PAGE_DOWN",
        [83] = "DELETE",
    }

    local WINDOWS_CONTROL = {
        [3] = "CTRL_C",
        [8] = "BACKSPACE",
        [9] = "TAB",
        [10] = "ENTER",
        [13] = "ENTER",
        [32] = "SPACE",
        [127] = "BACKSPACE",
    }

    Terminal.read_key = function(timeout_ms)
        local waited = 0
        timeout_ms = timeout_ms or 100
        while waited < timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                local code = ffi.C._getwch()
                if code < 0 or code == 0xFFFF then
                    return nil
                end
                if code == 0 or code == 224 then
                    local second = ffi.C._getwch()
                    return WINDOWS_SPECIAL[second] or "UNKNOWN"
                end
                local control = WINDOWS_CONTROL[code]
                if control then
                    return control
                end
                if code >= 1 and code <= 26 then
                    return "CTRL_" .. string.char(64 + code)
                end
                if code >= 0xd800 and code <= 0xdbff then
                    local low = ffi.C._getwch()
                    if low < 0xdc00 or low > 0xdfff then
                        return "\239\191\189"
                    end
                    code = 0x10000 + (code - 0xd800) * 1024 + (low - 0xdc00)
                elseif code >= 0xdc00 and code <= 0xdfff then
                    return "\239\191\189"
                end
                return utf8_from_codepoint(code)
            end
            kernel32.Sleep(10)
            waited = waited + 10
        end
        return nil
    end

    Terminal.enable_raw_mode = function()
        local input = input_handle()
        local output = output_handle()
        if kernel32.GetConsoleMode(input, original_input_mode) == 0 then
            io.stderr:write("mdview: standard input is not a Windows console\n")
            return false
        end
        if kernel32.GetConsoleMode(output, original_output_mode) == 0 then
            io.stderr:write("mdview: standard output is not a Windows console\n")
            return false
        end
        if not pcall(function()
            return ffi.C._kbhit()
        end) then
            io.stderr:write("mdview: console input helpers are unavailable in this LuaJIT build\n")
            return false
        end

        original_code_page = kernel32.GetConsoleOutputCP()
        Terminal.in_raw_mode = true

        local vt_ok = kernel32.SetConsoleMode(output,
            bit.bor(original_output_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING)) ~= 0
        local raw_mode = bit.band(original_input_mode[0],
            bit.bnot(bit.bor(ENABLE_PROCESSED_INPUT, ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT)))
        local input_ok = kernel32.SetConsoleMode(input, raw_mode) ~= 0
        local page_ok = kernel32.SetConsoleOutputCP(65001) ~= 0

        if not (vt_ok and input_ok and page_ok) then
            Terminal.disable_raw_mode()
            io.stderr:write("mdview: this console does not support VT sequences;"
                .. " use Windows Terminal or Windows 10+" .. "\n")
            return false
        end

        io.write("\27[?1049h\27[?25l\27[?7l\27[H\27[2J")
        io.flush()
        return true
    end

    Terminal.disable_raw_mode = function()
        if not Terminal.in_raw_mode then
            return
        end
        Terminal.in_raw_mode = false
        io.write("\27[0m\27[?7h\27[?1049l\27[?25h")
        io.flush()

        local input_ok = kernel32.SetConsoleMode(input_handle(), original_input_mode[0])
        local output_ok = kernel32.SetConsoleMode(output_handle(), original_output_mode[0])
        local page_ok = 1
        if original_code_page then
            page_ok = kernel32.SetConsoleOutputCP(original_code_page)
            original_code_page = nil
        end
        if input_ok == 0 or output_ok == 0 or page_ok == 0 then
            io.stderr:write("mdview: failed to restore console settings;"
                .. " reopen the terminal if needed\n")
        end
    end
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

if not IS_WINDOWS then
    Terminal.read_key = read_key
end

-- =========================================================================
-- 13. Native Directory Browsing (loaded only when needed)
-- =========================================================================
local read_document
local filesystem_cache

local function filesystem()
    if filesystem_cache then
        return filesystem_cache
    end
    local fs = {}
    if IS_WINDOWS then
        ffi.cdef[[
            typedef struct {
                uint32_t attributes;
                uint32_t times[6];
                uint32_t size_high, size_low, reserved0, reserved1;
                uint16_t name[260], alternate[14];
            } mdview_find_data;
            int __stdcall MultiByteToWideChar(unsigned int, uint32_t, const char *, int, uint16_t *, int);
            int __stdcall WideCharToMultiByte(unsigned int, uint32_t, const uint16_t *, int,
                                              char *, int, const char *, int *);
            uint32_t __stdcall GetFullPathNameW(const uint16_t *, uint32_t, uint16_t *, uint16_t **);
            uint32_t __stdcall GetFileAttributesW(const uint16_t *);
            void *__stdcall FindFirstFileW(const uint16_t *, mdview_find_data *);
            int __stdcall FindNextFileW(void *, mdview_find_data *);
            int __stdcall FindClose(void *);
            uint32_t __stdcall GetLastError(void);
            void *__stdcall CreateFileW(const uint16_t *, uint32_t, uint32_t, void *, uint32_t,
                                        uint32_t, void *);
            int __stdcall ReadFile(void *, void *, uint32_t, uint32_t *, void *);
            int __stdcall CloseHandle(void *);
            const uint16_t *__stdcall GetCommandLineW(void);
            uint16_t **__stdcall CommandLineToArgvW(const uint16_t *, int *);
            void *__stdcall LocalFree(void *);
        ]]
        local native = ffi.load("kernel32")
        local invalid = ffi.cast("void *", -1)
        local function failure()
            return "Windows error " .. tonumber(native.GetLastError())
        end
        local function wide(text)
            local count = native.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
            if count == 0 then
                return nil, "invalid UTF-8 path: " .. failure()
            end
            local buffer = ffi.new("uint16_t[?]", count + 1)
            if native.MultiByteToWideChar(65001, 8, text, #text, buffer, count) ~= count then
                return nil, failure()
            end
            return buffer
        end
        local function utf8(buffer)
            local count = native.WideCharToMultiByte(65001, 0, buffer, -1, nil, 0, nil, nil)
            if count == 0 then
                return nil, failure()
            end
            local text = ffi.new("char[?]", count)
            if native.WideCharToMultiByte(65001, 0, buffer, -1, text, count, nil, nil) ~= count then
                return nil, failure()
            end
            return ffi.string(text, count - 1)
        end
        function fs.resolve(path)
            local input, err = wide(path)
            if not input then
                return nil, err
            end
            local buffer = ffi.new("uint16_t[32768]")
            local count = native.GetFullPathNameW(input, 32768, buffer, nil)
            if count == 0 or count >= 32768 then
                return nil, "cannot resolve path: " .. failure()
            end
            local text, encode_error = utf8(buffer)
            if not text then
                return nil, encode_error
            end
            return text:gsub("\\", "/")
        end
        function fs.arguments(argv)
            local shell = ffi.load("shell32")
            local count = ffi.new("int[1]")
            local arguments = shell.CommandLineToArgvW(native.GetCommandLineW(), count)
            if arguments == nil then
                return nil, "cannot read Unicode command line: " .. failure()
            end
            local result = {}
            local decode_error
            -- LuaJIT has already separated interpreter options and the script.
            -- Recover the same trailing script arguments from the Unicode argv.
            local first = tonumber(count[0]) - #argv
            if first < 1 then
                decode_error = "cannot locate script arguments in Unicode command line"
            else
                for index = 1, #argv do
                    local value, err = utf8(arguments[first + index - 1])
                    if not value then
                        decode_error = err
                        break
                    end
                    result[index] = value
                end
            end
            if native.LocalFree(arguments) ~= nil then
                decode_error = decode_error or "cannot release Unicode command line: " .. failure()
            end
            if decode_error then
                return nil, decode_error
            end
            return result
        end
        local function native_path(path)
            local absolute, err = fs.resolve(path)
            if not absolute then
                return nil, err
            end
            absolute = absolute:gsub("/", "\\")
            if absolute:sub(1, 4) ~= "\\\\?\\" then
                if absolute:sub(1, 2) == "\\\\" then
                    absolute = "\\\\?\\UNC\\" .. absolute:sub(3)
                else
                    absolute = "\\\\?\\" .. absolute
                end
            end
            return wide(absolute)
        end
        local function kind(attributes)
            if bit.band(attributes, 0x400) ~= 0 then
                return "link"
            end
            return bit.band(attributes, 0x10) ~= 0 and "directory" or "file"
        end
        function fs.kind(path)
            local input, err = native_path(path)
            if not input then
                return nil, err
            end
            local attributes = native.GetFileAttributesW(input)
            if attributes == 0xffffffff then
                return nil, failure()
            end
            return kind(attributes)
        end
        function fs.list(path)
            local directory, err = fs.kind(path)
            if directory ~= "directory" then
                return nil, err or "not a directory (directory links are not expanded)"
            end
            local pattern, path_error = native_path(path .. "/*")
            if not pattern then
                return nil, path_error
            end
            local data = ffi.new("mdview_find_data[1]")
            local handle = native.FindFirstFileW(pattern, data)
            if handle == invalid then
                if native.GetLastError() == 2 then
                    return {}
                end
                return nil, failure()
            end
            local entries = {}
            local scan_error
            repeat
                local name, name_error = utf8(data[0].name)
                if not name then
                    scan_error = name_error
                    break
                end
                entries[#entries + 1] = {
                    name = name,
                    kind = kind(data[0].attributes),
                    hidden = bit.band(data[0].attributes, 2) ~= 0,
                }
                if native.FindNextFileW(handle, data) == 0 then
                    if native.GetLastError() ~= 18 then
                        scan_error = failure()
                    end
                    break
                end
            until false
            if native.FindClose(handle) == 0 then
                scan_error = scan_error or failure()
            end
            if scan_error then
                return nil, scan_error
            end
            return entries
        end
        function fs.read(path)
            local input, err = native_path(path)
            if not input then
                return nil, err
            end
            local handle = native.CreateFileW(input, 0x80000000, 7, nil, 3, 0x80, nil)
            if handle == invalid then
                return nil, failure()
            end
            local chunks = {}
            local buffer = ffi.new("char[65536]")
            local count = ffi.new("uint32_t[1]")
            local read_error
            while true do
                if native.ReadFile(handle, buffer, 65536, count, nil) == 0 then
                    read_error = failure()
                    break
                end
                if count[0] == 0 then
                    break
                end
                chunks[#chunks + 1] = ffi.string(buffer, count[0])
            end
            if native.CloseHandle(handle) == 0 then
                read_error = read_error or failure()
            end
            if read_error then
                return nil, read_error
            end
            return table.concat(chunks)
        end
    elseif ffi.os == "Linux" then
        ffi.cdef[[
            typedef struct {
                uint64_t ino;
                int64_t offset;
                uint16_t length;
                uint8_t kind;
                char name[256];
            } mdview_dirent;
            typedef struct { int64_t sec; uint32_t nsec; int32_t reserved; } mdview_timestamp;
            typedef struct {
                uint32_t mask, blksize;
                uint64_t attributes;
                uint32_t nlink, uid, gid;
                uint16_t mode, spare0;
                uint64_t ino, size, blocks, attributes_mask;
                mdview_timestamp times[4];
                uint32_t rdev_major, rdev_minor, dev_major, dev_minor;
                uint64_t spare[14];
            } mdview_statx;
            int statx(int, const char *, int, unsigned int, mdview_statx *);
            int open(const char *, int, ...);
            void *fdopendir(int);
            mdview_dirent *readdir64(void *);
            int closedir(void *);
            int close(int);
            char *realpath(const char *, char *);
            char *strerror(int);
        ]]
        local function failure()
            return ffi.string(ffi.C.strerror(ffi.errno()))
        end
        function fs.resolve(path)
            local buffer = ffi.new("char[4096]")
            if ffi.C.realpath(path, buffer) == nil then
                return nil, failure()
            end
            return ffi.string(buffer)
        end
        function fs.kind(path)
            local info = ffi.new("mdview_statx[1]")
            if ffi.C.statx(-100, path, 256, 1, info) ~= 0 then
                return nil, failure()
            end
            local mode = bit.band(info[0].mode, 0xf000)
            if mode == 0x4000 then
                return "directory"
            elseif mode == 0x8000 then
                return "file"
            elseif mode == 0xa000 then
                return "link"
            end
            return "other"
        end
        function fs.list(path)
            -- O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC: never descend through links.
            local fd = ffi.C.open(path, 65536 + 131072 + 524288)
            if fd < 0 then
                return nil, failure()
            end
            local directory = ffi.C.fdopendir(fd)
            if directory == nil then
                local err = failure()
                ffi.C.close(fd)
                return nil, err
            end
            local entries = {}
            local scan_error
            while true do
                ffi.errno(0)
                local entry = ffi.C.readdir64(directory)
                if entry == nil then
                    if ffi.errno() ~= 0 then
                        scan_error = failure()
                    end
                    break
                end
                local name = ffi.string(entry.name)
                local kind
                if entry.kind == 4 then
                    kind = "directory"
                elseif entry.kind == 8 then
                    kind = "file"
                elseif entry.kind == 0 then
                    kind, scan_error = fs.kind(path .. "/" .. name)
                    if not kind then
                        scan_error = name .. ": " .. scan_error
                        break
                    end
                end
                entries[#entries + 1] = { name = name, kind = kind or "other" }
            end
            if ffi.C.closedir(directory) ~= 0 then
                scan_error = scan_error or failure()
            end
            if scan_error then
                return nil, scan_error
            end
            return entries
        end
    else
        return nil, "file browsing supports Linux and Windows on this build"
    end
    filesystem_cache = fs
    return fs
end

-- =========================================================================
-- 14. Browser State and Frames
-- =========================================================================
local function path_parent(path)
    if IS_WINDOWS then
        path = path:gsub("\\", "/")
    end
    return path:match("^(.*[/])[^/]+/?$") or "."
end

local function markdown_name(name)
    local lower = name:lower()
    return lower:match("%.md$") ~= nil or lower:match("%.markdown$") ~= nil
end

function M.new_browser(view, path, is_directory, settings, fs)
    return {
        view = view,
        path = not is_directory and path or nil,
        root_path = is_directory and path or path_parent(path or "."),
        settings = settings or {},
        fs = fs,
        root = nil,
        entries = {},
        selected = 1,
        top = 1,
        tree_visible = is_directory,
        focus = is_directory and "tree" or "document",
        pending = is_directory and { kind = "root" } or nil,
        message = is_directory and ("Loading " .. path .. " ...") or "",
        cache = {},
        pending_g = false,
    }
end

local function browser_layout(browser, width)
    if not browser.tree_visible then
        return 0, width
    end
    if width < 64 then
        return browser.focus == "tree" and width or 0, width
    end
    local tree_width = math.max(24, math.min(32, math.floor(width / 3)))
    return tree_width, width - tree_width - 1
end

function M.resize_browser(browser, width, height)
    local _, document_width = browser_layout(browser, width)
    M.reflow(browser.view, document_width, height)
end

local function clamp_tree(browser, height)
    local count = #browser.entries
    if count == 0 then
        browser.selected = 1
        browser.top = 1
        return
    end
    browser.selected = math.max(1, math.min(browser.selected, count))
    local rows = page_rows(height)
    browser.top = math.max(1, math.min(browser.top, count - rows + 1))
    if browser.selected < browser.top then
        browser.top = browser.selected
    elseif browser.selected >= browser.top + rows then
        browser.top = browser.selected - rows + 1
    end
end

local function rebuild_tree(browser, height, selected_path)
    browser.entries = {}
    local function append(node, depth)
        node.depth = depth
        browser.entries[#browser.entries + 1] = node
        if selected_path and node.path == selected_path then
            browser.selected = #browser.entries
        end
        if node.expanded then
            for _, child in ipairs(node.children or {}) do
                append(child, depth + 1)
            end
        end
    end
    if browser.root then
        append(browser.root, 0)
    end
    clamp_tree(browser, height)
end

local function load_tree_node(browser, node)
    local entries, err = browser.fs.list(node.path)
    if not entries then
        return nil, "Cannot list " .. node.path .. ": " .. tostring(err)
    end
    local children = {}
    for _, entry in ipairs(entries) do
        if entry.name:sub(1, 1) ~= "." and not entry.hidden
            and (entry.kind == "directory" or (entry.kind == "file" and markdown_name(entry.name))) then
            children[#children + 1] = {
                name = entry.name,
                path = node.path:gsub("/$", "") .. "/" .. entry.name,
                directory = entry.kind == "directory",
                parent = node,
            }
        end
    end
    table.sort(children, function(a, b)
        if a.directory ~= b.directory then
            return a.directory
        end
        if a.name:lower() == b.name:lower() then
            return a.name < b.name
        end
        return a.name:lower() < b.name:lower()
    end)
    node.children = children
    node.expanded = true
    return true
end

function M.process_browser_pending(browser, width, height)
    local action = browser.pending
    if not action then
        return true
    end
    browser.pending = nil
    local fs, fs_error = browser.fs, nil
    if not fs then
        fs, fs_error = filesystem()
        browser.fs = fs
    end
    local function fail(message)
        browser.message = sanitize_text(message)
        return nil, browser.message
    end
    if not fs then
        return fail(tostring(fs_error))
    end
    if action.kind == "root" then
        local path, err = fs.resolve(browser.root_path)
        if not path then
            return fail("Cannot open " .. browser.root_path .. ": " .. tostring(err))
        end
        local root = {
            path = path,
            name = path:match("([^/]+)/*$") or path,
            directory = true,
        }
        local ok, list_error = load_tree_node(browser, root)
        if not ok then
            return fail(list_error)
        end
        browser.root = root
        browser.root_path = path
        rebuild_tree(browser, height, browser.path)
    elseif action.kind == "expand" then
        local ok, err = load_tree_node(browser, action.node)
        if not ok then
            return fail(err)
        end
        rebuild_tree(browser, height, action.node.path)
    elseif action.kind == "open" then
        local path = action.node.path
        local kind, kind_error = fs.kind(path)
        if kind ~= "file" then
            return fail("Cannot open " .. path .. ": " .. (kind_error or "not a regular Markdown file"))
        end
        local data, err = (fs.read_document or read_document)(path)
        if not data then
            return fail("Cannot open " .. path .. ": " .. tostring(err))
        end
        if browser.path then
            browser.cache[browser.path] = browser.view
        end
        local view = browser.cache[path]
        if not view or view.document_source ~= data then
            local _, document_width = browser_layout(browser, width)
            local options = {
                base_dir = path_parent(path),
                images = browser.settings.images ~= false,
                numbers = browser.settings.numbers ~= false,
            }
            local ok, lines = pcall(M.render, data, document_width, options)
            if not ok then
                return fail("Cannot render " .. path .. ": " .. tostring(lines))
            end
            view = M.new_view(path, lines)
            view.document_source = data
            view.case_sensitive = browser.settings.case_sensitive or false
        end
        browser.view = view
        browser.path = path
        browser.cache[path] = view
        browser.focus = "document"
        M.resize_browser(browser, width, height)
    end
    browser.message = ""
    return true
end

local function queue_browser_action(browser, kind, node)
    browser.pending = { kind = kind, node = node }
    browser.message = "Loading " .. (node and node.path or browser.root_path) .. " ..."
end

function M.handle_browser_key(browser, key, width, height)
    local view = browser.view
    if key == "CTRL_C" then
        view.quit = true
        return
    end
    if view.mode ~= "normal" then
        local _, document_width = browser_layout(browser, width)
        M.handle_key(view, key, height, document_width)
        if view.mode == "normal" and browser.modal_focus then
            browser.focus = browser.modal_focus
            browser.modal_focus = nil
        end
        return
    end
    if key == "f" then
        browser.tree_visible = not browser.tree_visible
        browser.focus = browser.tree_visible and "tree" or "document"
        browser.pending_g = false
        if browser.tree_visible and not browser.root then
            queue_browser_action(browser, "root")
        end
        M.resize_browser(browser, width, height)
        return
    elseif key == "TAB" and browser.tree_visible then
        browser.focus = browser.focus == "tree" and "document" or "tree"
        browser.pending_g = false
        M.resize_browser(browser, width, height)
        return
    end
    if browser.focus == "document" then
        local _, document_width = browser_layout(browser, width)
        M.handle_key(view, key, height, document_width)
        return
    end
    local node = browser.entries[browser.selected]
    local rows = page_rows(height)
    if key == "g" then
        if browser.pending_g then
            browser.selected = 1
        end
        browser.pending_g = not browser.pending_g
    else
        browser.pending_g = false
    end
    if key == "q" then
        view.quit = true
    elseif key == "ESC" then
        browser.focus = "document"
    elseif key == "j" or key == "DOWN" then
        browser.selected = browser.selected + 1
    elseif key == "k" or key == "UP" then
        browser.selected = browser.selected - 1
    elseif key == "G" or key == "END" then
        browser.selected = #browser.entries
    elseif key == "HOME" then
        browser.selected = 1
    elseif key == "CTRL_D" or key == "d" then
        browser.selected = browser.selected + math.max(1, math.floor(rows / 2))
    elseif key == "CTRL_U" or key == "u" then
        browser.selected = browser.selected - math.max(1, math.floor(rows / 2))
    elseif key == "PAGE_DOWN" or key == "CTRL_F" or key == "SPACE" then
        browser.selected = browser.selected + rows
    elseif key == "PAGE_UP" or key == "CTRL_B" then
        browser.selected = browser.selected - rows
    elseif key == "h" or key == "LEFT" then
        if node and node.directory and node.expanded then
            node.expanded = false
            rebuild_tree(browser, height, node.path)
        elseif node and node.parent then
            rebuild_tree(browser, height, node.parent.path)
        end
    elseif key == "l" or key == "RIGHT" or key == "ENTER" then
        if node and node.directory then
            if not node.expanded then
                if node.children then
                    node.expanded = true
                    rebuild_tree(browser, height, node.path)
                else
                    queue_browser_action(browser, "expand", node)
                end
            elseif #(node.children or {}) > 0 then
                browser.selected = browser.selected + 1
            end
        elseif node then
            queue_browser_action(browser, "open", node)
        end
    elseif key == "r" then
        local directory = node and (node.directory and node or node.parent)
        if directory then
            queue_browser_action(browser, "expand", directory)
        else
            queue_browser_action(browser, "root")
        end
    elseif key == "?" then
        browser.modal_focus = "tree"
        browser.focus = "document"
        M.handle_key(view, "h", height)
    end
    clamp_tree(browser, height)
    M.resize_browser(browser, width, height)
end

local function render_tree_frame(browser, width, height)
    clamp_tree(browser, height)
    local frame = { rows = {}, plain = {} }
    local function set_row(row, text, style)
        frame.rows[row] = pad_styled(sanitize_text(text), width, style)
        frame.plain[row] = strip_ansi(frame.rows[row])
    end
    set_row(1, " Files" .. (browser.focus == "tree" and " [active]" or ""), STYLE.bar)
    for row = 1, page_rows(height) do
        local index = browser.top + row - 1
        local node = browser.entries[index]
        if node then
            local selected = index == browser.selected
            local icon = node.directory and (node.expanded and "📂" or "📁") or "📄"
            local icon_style = node.directory and STYLE.folder_icon or STYLE.file_icon
            local prefix = (selected and "> " or "  ") .. string.rep("  ", math.min(node.depth, 8))
            local name = sanitize_text(node.name)
            local row_style = selected and browser.focus == "tree" and { reverse = true } or nil
            local spans = {}
            add_span(spans, prefix, row_style)
            add_span(spans, icon, merge_style(icon_style, row_style))
            add_span(spans, " " .. name, row_style)
            local formatted = spans_to_ansi(spans, width, false)
            local short = width - display_width(strip_ansi(formatted))
            if short > 0 then
                local pad_spans = {}
                add_span(pad_spans, string.rep(" ", short), row_style)
                formatted = formatted .. spans_to_ansi(pad_spans, short, false)
            end
            frame.rows[row + 1] = formatted
            frame.plain[row + 1] = strip_ansi(formatted)
        elseif row == 1 then
            set_row(row + 1, " No files loaded — r retries", STYLE.warn)
        elseif row == 2 and #browser.entries == 1 and browser.root.expanded then
            set_row(row + 1, " No Markdown files or folders", STYLE.warn)
        else
            set_row(row + 1, "", nil)
        end
    end
    local status = browser.message ~= "" and browser.message
        or " j/k move  h/l fold  gg/G  Enter open  Tab pane  r refresh  ? help"
    set_row(height, status, browser.message ~= "" and STYLE.warn or STYLE.bar)
    return frame
end

function M.render_browser(browser, width, height)
    if width < 24 or height < 4 then
        return M.render_frame(browser.view, width, height)
    end
    local tree_width, document_width = browser_layout(browser, width)
    if tree_width == 0 then
        return M.render_frame(browser.view, width, height)
    end
    local tree = render_tree_frame(browser, tree_width, height)
    if tree_width == width then
        return tree
    end
    local document = M.render_frame(browser.view, document_width, height)
    local frame = { rows = {}, plain = {} }
    for row = 1, height do
        frame.rows[row] = tree.rows[row] .. "│" .. document.rows[row]
        frame.plain[row] = tree.plain[row] .. "│" .. document.plain[row]
    end
    if browser.message ~= "" then
        frame.rows[height] = pad_styled(sanitize_text(browser.message), width, STYLE.warn)
        frame.plain[height] = strip_ansi(frame.rows[height])
    end
    return frame
end

-- =========================================================================
-- 15. Interactive Pager
-- =========================================================================
local function draw_frame(view, width, height, previous_rows)
    local frame = M.render_browser(view, width, height)
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

local function run_pager(browser, initial_search, settings)
    if not Terminal.enable_raw_mode() then
        io.stderr:write("mdview: interactive pager requires a terminal;"
            .. " printing the rendered document instead\n")
        return false
    end

    local view = browser.view
    view.case_sensitive = settings and settings.case_sensitive or false
    if initial_search and #initial_search > 0 then
        local width, height = Terminal.get_size()
        view.top = 1
        M.search(view, initial_search, height)
    end

    local width, height = Terminal.get_size()
    M.resize_browser(browser, math.max(20, width - 1), height)
    local previous_rows = {}
    local redraw = true

    local ok, err = xpcall(function()
        while not browser.view.quit and not Terminal.interrupted do
            local new_width, new_height = Terminal.get_size()
            if new_width ~= width or new_height ~= height then
                width, height = new_width, new_height
                M.resize_browser(browser, math.max(20, width - 1), height)
                previous_rows = {}
                -- A resize is one of the few cases where a full clear is safe.
                io.write("\27[H\27[2J")
                io.flush()
                redraw = true
            end
            if redraw then
                draw_frame(browser, math.max(1, width - 1), height, previous_rows)
                redraw = false
            end

            if browser.pending then
                M.process_browser_pending(browser, math.max(1, width - 1), height)
                redraw = true
            else
                local key = Terminal.read_key(200)
                if key then
                    M.handle_browser_key(browser, key, math.max(1, width - 1), height)
                    redraw = true
                end
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
-- 16. Windows GUI (Win32 SDK + GDI)
-- =========================================================================
-- The GUI is plain LuaJIT FFI over user32/gdi32: no toolkit, no DLLs to ship.
-- It reuses the terminal renderer's span output and palette, so both viewers
-- show the same document. Layout, hit-testing and scrolling stay pure Lua so
-- they can be tested without a window. The whole section lives in one function
-- scope because LuaJIT limits a chunk to 200 active locals.
local gui = (function()
local GUI_CLASS_NAME = "mdviewGuiWindow"
local GUI_DEFAULT_WIDTH = 1120
local GUI_DEFAULT_HEIGHT = 800
local GUI_MIN_WIDTH = 560
local GUI_MIN_HEIGHT = 360
local GUI_SCROLL_LINES = 3
local GUI_TREE_RATIO = 0.28
local GUI_TREE_MIN = 200
local GUI_TREE_MAX = 340
local GUI_TREE_BREAK = 560
local GUI_MIN_DOC_WIDTH = 240

local WM_DESTROY = 0x0002
local WM_SIZE = 0x0005
local WM_SETFOCUS = 0x0007
local WM_KILLFOCUS = 0x0008
local WM_CLOSE = 0x0010
local WM_PAINT = 0x000F
local WM_ERASEBKGND = 0x0014
local WM_GETMINMAXINFO = 0x0024
local WM_TIMER = 0x0113
local WM_MOUSEWHEEL = 0x020A
local WM_LBUTTONDOWN = 0x0201
local WM_LBUTTONUP = 0x0202
local WM_LBUTTONDBLCLK = 0x0203
local WM_KEYDOWN = 0x0100
local WM_VSCROLL = 0x0115
local WM_NOTIFY = 0x004E
local WM_SETFONT = 0x0030
local WM_PRINTCLIENT = 0x0318
local WS_CHILD = 0x40000000
local WS_VISIBLE = 0x10000000
local WS_TABSTOP = 0x00010000
local WS_CLIPCHILDREN = 0x02000000
local SW_HIDE = 0
local SW_SHOW = 5

-- SysTreeView32 (comctl32) constants; verified against commctrl.h on x64.
local TVS_HASBUTTONS = 0x0001
local TVS_HASLINES = 0x0002
local TVS_LINESATROOT = 0x0004
local TVS_SHOWSELALWAYS = 0x0020
local TVM_INSERTITEMW = 0x1132
local TVM_EXPAND = 0x1102
local TVM_SETIMAGELIST = 0x1109
local TVM_GETNEXTITEM = 0x110A
local TVM_SELECTITEM = 0x110B
local TVM_SETITEMW = 0x113F
local TVM_GETITEMW = 0x113E
local TVM_HITTEST = 0x1111
local TVHT_ONITEMBUTTON = 0x0010
local TVM_ENSUREVISIBLE = 0x1114
local TVM_SETBKCOLOR = 0x111D
local TVM_SETTEXTCOLOR = 0x111E
local TVGN_ROOT = 0
local TVGN_CARET = 9
local TVE_EXPAND = 2
local TVE_COLLAPSE = 1
local TVE_TOGGLE = 3
local TVIF_TEXT = 0x0001
local TVIF_IMAGE = 0x0002
local TVIF_SELECTEDIMAGE = 0x0020
local TVIF_CHILDREN = 0x0040
local TVN_SELCHANGEDW = 0xFFFFFE3D
local TVN_ITEMEXPANDINGW = 0xFFFFFE3A
local TVN_ITEMEXPANDEDW = 0xFFFFFE39
local NM_CLICK = 0xFFFFFFFE
local NM_DBLCLK = 0xFFFFFFFD
local NM_RETURN = 0xFFFFFFFC
local NM_SETFOCUS = 0xFFFFFFF9
local NM_KILLFOCUS = 0xFFFFFFF8
local SHGFI_SMALLICON = 0x00000001
local SHGFI_SYSICONINDEX = 0x00004000
local TVI_ROOT = -65536
local TVI_LAST = -2
local SYS_COLOR_WINDOW = 5
local SYS_COLOR_WINDOWTEXT = 8
local SYS_COLOR_HIGHLIGHT = 13
local SYS_COLOR_BTNFACE = 15
local SYS_COLOR_BTNSHADOW = 16
local SYS_COLOR_GRAYTEXT = 17
local SYS_COLOR_BTNTEXT = 18
local SYS_COLOR_HOTLIGHT = 26

local GUI_VIRTUAL_KEYS = {
    [0x25] = "LEFT", [0x26] = "UP", [0x27] = "RIGHT", [0x28] = "DOWN",
    [0x24] = "HOME", [0x23] = "END",
    [0x21] = "PAGE_UP", [0x22] = "PAGE_DOWN",
    [0x0D] = "ENTER", [0x09] = "TAB", [0x20] = "SPACE", [0x1B] = "ESC",
}

local gui_libs
local gui_state
-- Callback objects referenced by the OS (window class, subclass proc) must
-- outlive every window they serve: Windows keeps the raw function pointer, so
-- freeing the Lua callback would crash the next dispatched message.
local gui_wndproc_ref
local gui_treeproc_ref
local gui_class_registered = false
local gui_tree_proc

local function gui_native()
    if gui_libs then
        return gui_libs
    end
    if not IS_WINDOWS then
        return nil
    end
    ffi.cdef[[
        typedef intptr_t (__stdcall *mdview_wndproc)(void *, uint32_t, uintptr_t, intptr_t);
        typedef struct {
            uint32_t cbSize, style;
            mdview_wndproc lpfnWndProc;
            int32_t cbClsExtra, cbWndExtra;
            void *hInstance, *hIcon, *hCursor, *hbrBackground;
            const uint16_t *lpszMenuName;
            const uint16_t *lpszClassName;
            void *hIconSm;
        } mdview_wndclass;
        typedef struct { int32_t left, top, right, bottom; } mdview_rect;
        typedef struct { int32_t cx, cy; } mdview_size;
        typedef struct { int32_t x, y; } mdview_point;
        typedef struct {
            void *hdc; int32_t fErase; mdview_rect rcPaint;
            int32_t fRestore, fIncUpdate; uint8_t rgbReserved[32];
        } mdview_paint_struct;
        typedef struct {
            void *hwnd; uint32_t message; uintptr_t wParam; intptr_t lParam;
            uint32_t time; int32_t x, y; uint32_t private_data;
        } mdview_msg;
        typedef struct {
            uint32_t cbSize, fMask;
            int32_t nMin, nMax, nPage, nPos, nTrackPos;
        } mdview_scroll_info;
        typedef struct {
            mdview_point reserved, max_size, max_position, min_track, max_track;
        } mdview_minmax_info;
        typedef struct {
            uint32_t biSize; int32_t biWidth, biHeight;
            uint16_t biPlanes, biBitCount;
            uint32_t biCompression, biSizeImage;
            int32_t biXPelsPerMeter, biYPelsPerMeter;
            uint32_t biClrUsed, biClrImportant;
        } mdview_bitmap_header;
        typedef struct {
            mdview_bitmap_header header; uint32_t colors[3];
        } mdview_bitmap_info;
        typedef struct { uint32_t dwSize, dwICC; } mdview_init_controls;
        typedef struct { void *hwndFrom; uintptr_t idFrom; uint32_t code; } mdview_nmhdr;
        typedef struct {
            uint32_t mask;
            void *hItem;
            uint32_t state, stateMask;
            const uint16_t *pszText;
            int32_t cchTextMax, iImage, iSelectedImage, cChildren;
            intptr_t lParam;
        } mdview_tvitem;
        typedef struct {
            void *hParent, *hInsertAfter;
            mdview_tvitem item;
            uint8_t tvitem_ex[24];
        } mdview_tvinsert;
        typedef struct {
            mdview_point pt;
            uint32_t flags;
            void *hItem;
        } mdview_tvhittest;
        typedef struct {
            mdview_nmhdr hdr;
            uint32_t action;
            mdview_tvitem itemOld, itemNew;
            mdview_point ptDrag;
        } mdview_nmtreeview;
        typedef struct {
            mdview_nmhdr hdr;
            int32_t iItem, iSubItem;
            uint32_t uNewState, uOldState, uChanged;
            mdview_point ptAction;
            intptr_t lParam;
            uint32_t uKeyFlags;
        } mdview_nmitemactivate;
        typedef struct {
            void *hIcon;
            int32_t iIcon;
            uint32_t dwAttributes;
            uint16_t szDisplayName[260];
            uint16_t szTypeName[80];
        } mdview_shfileinfo;

        void *__stdcall GetModuleHandleW(const uint16_t *);
        int __stdcall MultiByteToWideChar(unsigned int, uint32_t, const char *, int,
                                          uint16_t *, int);
        uint32_t __stdcall GetLastError(void);
        uint16_t __stdcall RegisterClassExW(const mdview_wndclass *);
        void *__stdcall CreateWindowExW(uint32_t, const uint16_t *, const uint16_t *, uint32_t,
                                        int32_t, int32_t, int32_t, int32_t, void *, void *,
                                        void *, void *);
        intptr_t __stdcall DefWindowProcW(void *, uint32_t, uintptr_t, intptr_t);
        int __stdcall DestroyWindow(void *);
        void __stdcall PostQuitMessage(int);
        int __stdcall GetMessageW(mdview_msg *, void *, uint32_t, uint32_t);
        int __stdcall TranslateMessage(const mdview_msg *);
        intptr_t __stdcall DispatchMessageW(const mdview_msg *);
        int __stdcall ShowWindow(void *, int);
        int __stdcall UpdateWindow(void *);
        int __stdcall InvalidateRect(void *, const mdview_rect *, int);
        void *__stdcall BeginPaint(void *, mdview_paint_struct *);
        int __stdcall EndPaint(void *, const mdview_paint_struct *);
        void *__stdcall GetDC(void *);
        int __stdcall ReleaseDC(void *, void *);
        int __stdcall FillRect(void *, const mdview_rect *, void *);
        void *__stdcall LoadCursorW(void *, const uint16_t *);
        void *__stdcall LoadIconW(void *, const uint16_t *);
        int __stdcall SetWindowTextW(void *, const uint16_t *);
        uintptr_t __stdcall SetTimer(void *, uintptr_t, uint32_t, void *);
        int __stdcall KillTimer(void *, uintptr_t);
        int __stdcall PostMessageW(void *, uint32_t, uintptr_t, intptr_t);
        int __stdcall SetScrollInfo(void *, int, const mdview_scroll_info *, int);
        intptr_t __stdcall SendMessageW(void *, uint32_t, uintptr_t, intptr_t);
        intptr_t __stdcall SetWindowLongPtrW(void *, int, intptr_t);
        int __stdcall MoveWindow(void *, int32_t, int32_t, int32_t, int32_t, int);
        int __stdcall PrintWindow(void *, void *, uint32_t);
        uint32_t __stdcall GetSysColor(int);
        int __stdcall InitCommonControlsEx(const mdview_init_controls *);
        uintptr_t __stdcall SHGetFileInfoW(const uint16_t *, uint32_t,
                                           mdview_shfileinfo *, uint32_t, uint32_t);
        intptr_t __stdcall ShellExecuteW(void *, const uint16_t *, const uint16_t *,
                                         const uint16_t *, const uint16_t *, int);
        int __stdcall GetClientRect(void *, mdview_rect *);
        int __stdcall AdjustWindowRectEx(mdview_rect *, uint32_t, int, uint32_t);
        int __stdcall SetProcessDPIAware(void);
        int __stdcall GetSystemMetrics(int);
        void *__stdcall SetFocus(void *);
        int __stdcall ScreenToClient(void *, mdview_point *);
        int __stdcall DrawTextW(void *, const uint16_t *, int, mdview_rect *, uint32_t);

        void *__stdcall CreateCompatibleDC(void *);
        void *__stdcall CreateCompatibleBitmap(void *, int32_t, int32_t);
        void *__stdcall SelectObject(void *, void *);
        int __stdcall DeleteDC(void *);
        int __stdcall DeleteObject(void *);
        int __stdcall BitBlt(void *, int32_t, int32_t, int32_t, int32_t, void *,
                             int32_t, int32_t, uint32_t);
        void *__stdcall CreateSolidBrush(uint32_t);
        void *__stdcall CreateFontW(int32_t, int32_t, int32_t, int32_t, int32_t,
                                    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                    uint32_t, uint32_t, uint32_t, const uint16_t *);
        int __stdcall SetTextColor(void *, uint32_t);
        int __stdcall SetBkMode(void *, int);
        int __stdcall TextOutW(void *, int32_t, int32_t, const uint16_t *, int);
        int __stdcall GetTextExtentPoint32W(void *, const uint16_t *, int, mdview_size *);
        int __stdcall GetDeviceCaps(void *, int);
        int __stdcall SaveDC(void *);
        int __stdcall RestoreDC(void *, int);
        int __stdcall IntersectClipRect(void *, int32_t, int32_t, int32_t, int32_t);
        int __stdcall GetDIBits(void *, void *, uint32_t, uint32_t, void *,
                                mdview_bitmap_info *, uint32_t);
        typedef struct {
            int32_t type, width, height, width_bytes;
            uint16_t planes, bits_pixel;
            void *bits;
        } mdview_bitmap;
        int __stdcall GetObjectW(void *, int, void *);
        int __stdcall SetStretchBltMode(void *, int);
        int __stdcall StretchBlt(void *, int32_t, int32_t, int32_t, int32_t, void *,
                                 int32_t, int32_t, int32_t, int32_t, uint32_t);
    ]]
    gui_libs = {
        kernel32 = ffi.load("kernel32"),
        user32 = ffi.load("user32"),
        gdi32 = ffi.load("gdi32"),
        comctl32 = ffi.load("comctl32"),
        shell32 = ffi.load("shell32"),
    }
    return gui_libs
end

-- Images are decoded with GDI+, which ships with Windows and reads PNG, JPEG,
-- GIF and BMP. When it cannot be loaded the document falls back to text.
local gui_gdiplus_lib
local gui_gdiplus_token

local function gui_gdiplus()
    if gui_gdiplus_lib ~= nil then
        return gui_gdiplus_lib or nil
    end
    local ok, lib = pcall(ffi.load, "gdiplus")
    if not ok then
        gui_gdiplus_lib = false
        return nil
    end
    ffi.cdef[[
        typedef struct {
            uint32_t version;
            void *debug_callback;
            int32_t suppress_background;
            int32_t suppress_codecs;
        } mdview_gdiplus_input;
        int __stdcall GdiplusStartup(uintptr_t *, const mdview_gdiplus_input *, void *);
        void __stdcall GdiplusShutdown(uintptr_t);
        int __stdcall GdipCreateBitmapFromFile(const uint16_t *, void **);
        int __stdcall GdipCreateHBITMAPFromBitmap(void *, void **, uint32_t);
        int __stdcall GdipDisposeImage(void *);
    ]]
    local input = ffi.new("mdview_gdiplus_input[1]")
    input[0].version = 1
    local token = ffi.new("uintptr_t[1]")
    if lib.GdiplusStartup(token, input, nil) ~= 0 then
        gui_gdiplus_lib = false
        return nil
    end
    gui_gdiplus_token = token[0]
    gui_gdiplus_lib = lib
    return lib
end

local gui_wide

local function gui_native_path(path)
    return tostring(path):gsub("/", string.char(92))
end

-- Returns the decoded bitmap handle and its pixel size, or nil and a reason.
-- Decoded images are cached for the lifetime of the GUI state.
local function gui_image(state, path)
    local cache = state.images
    local entry = cache[path]
    if entry ~= nil then
        if entry == false then
            return nil, "cannot decode"
        end
        return entry
    end
    local lib = gui_gdiplus()
    if not lib then
        cache[path] = false
        return nil, "cannot decode"
    end
    local wide, _ = gui_wide(state.libs, gui_native_path(path))
    local image = ffi.new("void *[1]")
    if lib.GdipCreateBitmapFromFile(wide, image) ~= 0 or image[0] == nil then
        cache[path] = false
        return nil, "cannot decode"
    end
    local header = ffi.new("void *[1]")
    local status = lib.GdipCreateHBITMAPFromBitmap(image[0], header, 0x00FFFFFF)
    local width, height = 0, 0
    if status == 0 and header[0] ~= nil then
        -- The GDI bitmap keeps its own copy of the pixels, so the GDI+ image
        -- is only needed while the handle is created.
        local size = ffi.new("mdview_bitmap[1]")
        local gdi = state.libs.gdi32
        if gdi.GetObjectW(header[0], ffi.sizeof("mdview_bitmap"), size) > 0 then
            width = tonumber(size[0].width) or 0
            height = tonumber(size[0].height) or 0
        end
    end
    lib.GdipDisposeImage(image[0])
    if status ~= 0 or header[0] == nil or width <= 0 or height <= 0 then
        if header[0] ~= nil then
            state.libs.gdi32.DeleteObject(header[0])
        end
        cache[path] = false
        return nil, "cannot decode"
    end
    entry = { handle = header[0], width = width, height = height }
    cache[path] = entry
    return entry
end

gui_wide = function(libs, text)
    text = tostring(text or "")
    local count = libs.kernel32.MultiByteToWideChar(65001, 0, text, #text, nil, 0)
    local buffer = ffi.new("uint16_t[?]", math.max(1, count + 1))
    if count > 0 then
        libs.kernel32.MultiByteToWideChar(65001, 0, text, #text, buffer, count)
    end
    return buffer, count
end

-- COLORREF is 0x00BBGGRR; theme values are ANSI 24-bit truecolor.
local function gui_color(spec)
    if type(spec) == "number" then
        return spec
    end
    local r, g, b = tostring(spec or ""):match("^[34]8;2;(%d+);(%d+);(%d+)$")
    if not r then
        return nil
    end
    return tonumber(r) + tonumber(g) * 256 + tonumber(b) * 65536
end

local function gui_system_spec(libs, index, background)
    local value = tonumber(libs.user32.GetSysColor(index)) or 0
    local red = value % 256
    local green = math.floor(value / 256) % 256
    local blue = math.floor(value / 65536) % 256
    return string.format("%s;2;%d;%d;%d", background and "48" or "38", red, green, blue)
end

-- The GUI follows the current Windows colors instead of the terminal palettes.
-- Document styles keep light-background colors so text stays readable.
local function gui_system_palette(libs)
    local palette = {}
    for key, value in pairs(LIGHT_PALETTE) do
        palette[key] = value
    end
    palette.text = gui_system_spec(libs, SYS_COLOR_WINDOWTEXT, false)
    palette.link = gui_system_spec(libs, SYS_COLOR_HOTLIGHT, false)
    palette.bar_fg = gui_system_spec(libs, SYS_COLOR_BTNTEXT, false)
    palette.bar_bg = gui_system_spec(libs, SYS_COLOR_BTNFACE, true)
    palette.line_number = gui_system_spec(libs, SYS_COLOR_GRAYTEXT, false)
    palette.info = gui_system_spec(libs, SYS_COLOR_GRAYTEXT, false)
    palette.folder_icon = gui_system_spec(libs, SYS_COLOR_BTNTEXT, false)
    palette.file_icon = gui_system_spec(libs, SYS_COLOR_BTNTEXT, false)
    palette.gui_bg = gui_system_spec(libs, SYS_COLOR_WINDOW, true)
    palette.gui_panel = gui_system_spec(libs, SYS_COLOR_BTNFACE, true)
    palette.gui_selection = gui_system_spec(libs, SYS_COLOR_HIGHLIGHT, true)
    palette.gui_separator = gui_system_spec(libs, SYS_COLOR_BTNSHADOW, true)
    palette.gui_accent = gui_system_spec(libs, SYS_COLOR_HIGHLIGHT, false)
    return palette
end

local function gui_scale(dpi, value)
    return math.max(1, math.floor(value * dpi / 96 + 0.5))
end

local function gui_clamp(value, low, high)
    if high < low then
        return low
    end
    return math.max(low, math.min(value, high))
end

local function gui_last_error(libs)
    return "Windows error " .. tonumber(libs.kernel32.GetLastError())
end

function M.gui_layout(width, height, metrics)
    width = math.max(1, math.floor(width or 1))
    height = math.max(1, math.floor(height or 1))
    local content_height = math.max(1, height - metrics.status_h)
    local header_height = math.min(metrics.header_h, content_height)
    local body_height = math.max(1, content_height - header_height)
    local tree_width = 0
    if width >= metrics.tree_break then
        tree_width = math.floor(width * metrics.tree_ratio)
        tree_width = gui_clamp(tree_width, metrics.tree_min, metrics.tree_max)
        if width - tree_width < metrics.min_doc_width then
            tree_width = width - metrics.min_doc_width
        end
        if tree_width < metrics.tree_min then
            tree_width = 0
        end
    end
    local separator = tree_width > 0 and 1 or 0
    local doc_x = tree_width + separator
    return {
        width = width,
        height = height,
        content_height = content_height,
        header_height = header_height,
        body_height = body_height,
        tree_width = tree_width,
        separator = separator,
        doc_x = doc_x,
        doc_width = math.max(1, width - doc_x),
        rows = math.max(1, math.floor(body_height / metrics.cell_h)),
        tree_rows = tree_width > 0
            and math.max(1, math.floor(body_height / metrics.tree_row_h)) or 0,
    }
end

function M.gui_document_columns(layout, metrics)
    local available = math.max(1, layout.doc_width - 2 * metrics.padding)
    return math.max(20, math.floor(available / metrics.cell_w))
end

function M.gui_hit_test(layout, metrics, x, y)
    if x < 0 or y < 0 or x >= layout.width or y >= layout.height then
        return { pane = "none" }
    end
    if y >= layout.content_height then
        return { pane = "status" }
    end
    if y < layout.header_height then
        return { pane = "header" }
    end
    if layout.tree_width > 0 and x < layout.tree_width then
        local row = math.floor((y - layout.header_height) / metrics.tree_row_h) + 1
        if row >= 1 and row <= layout.tree_rows then
            return { pane = "tree", row = row }
        end
        return { pane = "tree" }
    end
    if x >= layout.doc_x then
        local row = math.floor((y - layout.header_height) / metrics.cell_h) + 1
        if row >= 1 and row <= layout.rows then
            return { pane = "document", row = row }
        end
        return { pane = "document" }
    end
    return { pane = "separator" }
end

function M.gui_scroll_top(top, total, rows, action)
    total = math.max(1, total or 1)
    rows = math.max(1, rows or 1)
    top = gui_clamp(top or 1, 1, total)
    local maximum = math.max(1, total - rows + 1)
    if action == "up" then
        top = top - 1
    elseif action == "down" then
        top = top + 1
    elseif action == "page_up" then
        top = top - math.max(1, rows - 1)
    elseif action == "page_down" then
        top = top + math.max(1, rows - 1)
    elseif action == "top" then
        top = 1
    elseif action == "bottom" then
        top = maximum
    end
    return gui_clamp(top, 1, maximum)
end

function M.gui_ensure_visible(top, selected, rows, total)
    rows = math.max(1, rows or 1)
    total = math.max(1, total or 1)
    selected = gui_clamp(selected or 1, 1, total)
    top = math.max(1, top or 1)
    if selected < top then
        top = selected
    elseif selected >= top + rows then
        top = selected - rows + 1
    end
    return gui_clamp(top, 1, math.max(1, total - rows + 1))
end

function M.gui_key_action(token, pane)
    if token == "TAB" then
        return "switch"
    elseif token == "ESC" then
        return pane == "tree" and "escape" or nil
    end
    if pane == "tree" then
        if token == "UP" then
            return "up"
        elseif token == "DOWN" then
            return "down"
        elseif token == "LEFT" then
            return "collapse"
        elseif token == "RIGHT" then
            return "expand"
        elseif token == "HOME" then
            return "first"
        elseif token == "END" then
            return "last"
        elseif token == "PAGE_UP" then
            return "page_up"
        elseif token == "PAGE_DOWN" then
            return "page_down"
        elseif token == "ENTER" then
            return "open"
        end
        return nil
    end
    if token == "UP" then
        return "up"
    elseif token == "DOWN" then
        return "down"
    elseif token == "PAGE_UP" then
        return "page_up"
    elseif token == "PAGE_DOWN" or token == "SPACE" then
        return "page_down"
    elseif token == "HOME" then
        return "top"
    elseif token == "END" then
        return "bottom"
    end
    return nil
end

-- =========================================================================
-- 16b. GUI Resources, State and Document Handling
-- =========================================================================
local function gui_create_font(libs, face, pixel_height, weight, italic)
    local name = gui_wide(libs, face)
    return libs.gdi32.CreateFontW(-pixel_height, 0, 0, 0, weight,
        italic and 1 or 0, 0, 0, 1, 4, 0, 5, 49, name)
end

local function gui_create_fonts(libs, dpi)
    local doc_height = math.max(10, gui_scale(dpi, 15))
    local tree_height = math.max(10, gui_scale(dpi, 14))
    return {
        doc = {
            regular = gui_create_font(libs, "Consolas", doc_height, 400, false),
            bold = gui_create_font(libs, "Consolas", doc_height, 700, false),
            italic = gui_create_font(libs, "Consolas", doc_height, 400, true),
            bold_italic = gui_create_font(libs, "Consolas", doc_height, 700, true),
        },
        tree = {
            regular = gui_create_font(libs, "Segoe UI", tree_height, 400, false),
            bold = gui_create_font(libs, "Segoe UI", tree_height, 700, false),
        },
    }
end

local function gui_create_metrics(libs, dc, dpi, fonts)
    local gdi = libs.gdi32
    local size = ffi.new("mdview_size[1]")
    gdi.SelectObject(dc, fonts.doc.regular)
    local sample = gui_wide(libs, string.rep("M", 64))
    gdi.GetTextExtentPoint32W(dc, sample, 64, size)
    local cell_width = math.max(1, math.floor(size[0].cx / 64 + 0.5))
    local cell_height = math.max(1, size[0].cy + gui_scale(dpi, 3))
    gdi.SelectObject(dc, fonts.tree.regular)
    local probe = gui_wide(libs, "M")
    gdi.GetTextExtentPoint32W(dc, probe, 1, size)
    local tree_row_height = math.max(cell_height, size[0].cy + gui_scale(dpi, 5))
    return {
        dpi = dpi,
        cell_w = cell_width,
        cell_h = cell_height,
        tree_row_h = tree_row_height,
        header_h = gui_scale(dpi, 28),
        status_h = gui_scale(dpi, 26),
        padding = gui_scale(dpi, 10),
        tree_indent = gui_scale(dpi, 14),
        tree_marker = gui_scale(dpi, 16),
        text_offset = gui_scale(dpi, 2),
        tree_ratio = GUI_TREE_RATIO,
        tree_min = gui_scale(dpi, GUI_TREE_MIN),
        tree_max = gui_scale(dpi, GUI_TREE_MAX),
        tree_break = gui_scale(dpi, GUI_TREE_BREAK),
        min_doc_width = gui_scale(dpi, GUI_MIN_DOC_WIDTH),
    }
end

local function gui_brush(state, spec)
    local key = spec or "default"
    local cached = state.brush_cache[key]
    if cached then
        return cached
    end
    local brush = state.libs.gdi32.CreateSolidBrush(gui_color(spec) or 0)
    state.brush_cache[key] = brush
    return brush
end

local function gui_span_colors(style)
    local fg = style and style.fg
    local bg = style and style.bg
    if style then
        if style.search_current then
            fg = fg or THEME.search_current_fg
            bg = bg or THEME.search_current_bg
        elseif style.search then
            fg = fg or THEME.search_fg
            bg = bg or THEME.search_bg
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
    end
    return fg or THEME.text, bg
end

local function gui_span_font(state, style)
    local key = "regular"
    if style then
        if style.bold and style.italic then
            key = "bold_italic"
        elseif style.bold then
            key = "bold"
        elseif style.italic then
            key = "italic"
        end
    end
    return state.fonts.doc[key]
end

local function gui_placeholder()
    return "# Markdown browser\n\n"
        .. "Select a Markdown file in the tree and press Enter, or double-click it.\n\n"
        .. "Tab switches panes. Arrow keys move in the tree; PgUp/PgDn scroll the document.\n"
end

local function gui_release_buffer(state)
    local buffer = state.buffer
    if not buffer then
        return
    end
    local gdi = state.libs.gdi32
    if buffer.previous then
        gdi.SelectObject(buffer.dc, buffer.previous)
    end
    if buffer.bitmap then
        gdi.DeleteObject(buffer.bitmap)
    end
    if buffer.dc then
        gdi.DeleteDC(buffer.dc)
    end
    state.buffer = nil
end

local function gui_release_state(state)
    if not state then
        return
    end
    local gdi = state.libs and state.libs.gdi32
    if gdi then
        gui_release_buffer(state)
        for _, font in pairs(state.fonts.doc) do
            gdi.DeleteObject(font)
        end
        for _, font in pairs(state.fonts.tree) do
            gdi.DeleteObject(font)
        end
        for _, brush in pairs(state.brushes) do
            gdi.DeleteObject(brush)
        end
        for _, brush in pairs(state.brush_cache) do
            gdi.DeleteObject(brush)
        end
        for _, entry in pairs(state.images or {}) do
            if entry and entry.handle then
                gdi.DeleteObject(entry.handle)
            end
        end
    end
    state.images = {}
    state.fonts = { doc = {}, tree = {} }
    state.brushes = {}
    state.brush_cache = {}
end

local function gui_document_title(name)
    return sanitize_text(name or "untitled")
end

local function gui_document_options(state)
    return {
        base_dir = state.path ~= "-" and path_parent(state.path) or ".",
        images = state.settings.images,
        numbers = state.settings.numbers,
        gui = true,
        image_size = function(path)
            local entry = gui_image(state, path)
            if not entry then
                return nil
            end
            return entry.width, entry.height
        end,
    }
end

local function gui_clamp_document(state)
    local view = state.view
    if not view then
        return
    end
    local maximum = math.max(1, #view.lines - state.layout.rows + 1)
    view.top = gui_clamp(view.top or 1, 1, maximum)
end

local function gui_sync_document(state)
    local columns = M.gui_document_columns(state.layout, state.metrics)
    if state.view and state.doc_cols == columns then
        gui_clamp_document(state)
        return
    end
    if state.view then
        M.reflow(state.view, columns, state.layout.rows + 2)
    else
        local ok, lines = pcall(M.render, state.source, columns, gui_document_options(state))
        if not ok then
            state.message = "Cannot render " .. state.title .. ": " .. tostring(lines)
            state.message_kind = "warn"
            return
        end
        state.view = M.new_view(state.title, lines)
        state.view.document_source = state.source
        state.view.case_sensitive = state.settings.case_sensitive
        state.view.top = 1
    end
    state.doc_cols = columns
    gui_clamp_document(state)
end

local function gui_update_window_title(state)
    if state.hwnd == nil then
        return
    end
    local title = gui_wide(state.libs, "mdview — " .. state.path)
    state.libs.user32.SetWindowTextW(state.hwnd, title)
end

local function gui_open_node(state, node)
    if not node or node.directory then
        return false
    end
    local data, err = (state.fs.read_document or read_document)(node.path)
    if not data then
        state.message = "Cannot open " .. node.name .. ": " .. tostring(err)
        state.message_kind = "warn"
        return false
    end
    state.source = data
    state.path = node.path
    state.title = gui_document_title(node.name)
    state.view = nil
    state.doc_cols = 0
    state.message = ""
    state.message_kind = "info"
    gui_sync_document(state)
    gui_update_window_title(state)
    return true
end

function M.gui_open_path(state, path)
    if not state or not path then
        return false
    end
    return gui_open_node(state, {
        name = path:match("([^/\\]+)$") or path,
        path = path,
    })
end

-- =========================================================================
-- 16c. Native Win32 File Tree (SysTreeView32 + shell icons)
-- =========================================================================
-- The tree is the common-controls tree view, so selection, keyboard
-- navigation, expanders and mouse clicks are native Windows behavior. Icons
-- come from the shell system image list via SHGetFileInfo, so folders and
-- Markdown files look like Explorer items.
local function gui_item_key(handle)
    return tonumber(ffi.cast("intptr_t", handle))
end

local function gui_item_pointer(key)
    return ffi.cast("void *", ffi.cast("intptr_t", key))
end

local function gui_icon_index(state, path)
    local libs = state.libs
    local info = ffi.new("mdview_shfileinfo[1]")
    local native_path = tostring(path):gsub("/", string.char(92))
    local ok = libs.shell32.SHGetFileInfoW(gui_wide(libs, native_path), 0, info,
        ffi.sizeof("mdview_shfileinfo"), SHGFI_SYSICONINDEX + SHGFI_SMALLICON)
    if tonumber(ok) == 0 then
        return 0
    end
    return tonumber(info[0].iIcon) or 0
end

local function gui_tree_insert(state, node, parent)
    local libs = state.libs
    local insert = ffi.new("mdview_tvinsert[1]")
    insert[0].hParent = parent or gui_item_pointer(TVI_ROOT)
    insert[0].hInsertAfter = gui_item_pointer(TVI_LAST)
    local text, length = gui_wide(libs, sanitize_text(node.name))
    local icon = gui_icon_index(state, node.path)
    insert[0].item.mask = TVIF_TEXT + TVIF_IMAGE + TVIF_SELECTEDIMAGE + TVIF_CHILDREN
    insert[0].item.pszText = text
    insert[0].item.cchTextMax = length
    insert[0].item.iImage = icon
    insert[0].item.iSelectedImage = icon
    insert[0].item.cChildren = node.directory and 1 or 0
    local result = libs.user32.SendMessageW(state.tree_hwnd, TVM_INSERTITEMW, 0,
        ffi.cast("intptr_t", insert))
    local handle = ffi.cast("void *", result)
    if handle == nil then
        return nil
    end
    local key = gui_item_key(handle)
    state.tree_items[node.path] = key
    state.tree_nodes[key] = node
    return key
end

local function gui_tree_set_children_flag(state, key, has_children)
    local item = ffi.new("mdview_tvitem[1]")
    item[0].mask = TVIF_CHILDREN
    item[0].hItem = gui_item_pointer(key)
    item[0].cChildren = has_children and 1 or 0
    state.libs.user32.SendMessageW(state.tree_hwnd, TVM_SETITEMW, 0,
        ffi.cast("intptr_t", item))
end

local function gui_tree_fill(state, node)
    local key = state.tree_items[node.path]
    if not key or state.tree_filled[key] then
        return true
    end
    state.tree_filled[key] = true
    local children = node.children
    if not children then
        local ok, err = load_tree_node(state.browser, node)
        if not ok then
            state.tree_filled[key] = nil
            state.message = sanitize_text(err)
            state.message_kind = "warn"
            return false
        end
        children = node.children
    end
    local parent = gui_item_pointer(key)
    for _, child in ipairs(children or {}) do
        gui_tree_insert(state, child, parent)
    end
    if #(children or {}) == 0 then
        gui_tree_set_children_flag(state, key, false)
    end
    return true
end

-- TreeView hit testing is repeated here because the selection itself must
-- not depend on the control's internal mouse state: a synthetic or posted
-- WM_LBUTTONDOWN can leave the control with no caret at all.
local function gui_tree_hit_node(state, lparam)
    local tree = state.tree_hwnd
    if not tree then
        return nil, 0
    end
    local packed = tonumber(ffi.cast("intptr_t", lparam)) or 0
    local hit = ffi.new("mdview_tvhittest[1]")
    hit[0].pt.x = packed % 65536
    hit[0].pt.y = math.floor(packed / 65536) % 65536
    local found = state.libs.user32.SendMessageW(tree, TVM_HITTEST, 0,
        ffi.cast("intptr_t", hit))
    local flags = tonumber(hit[0].flags) or 0
    if tonumber(ffi.cast("intptr_t", found)) == 0 or flags == 0 then
        return nil, flags
    end
    return state.tree_nodes[gui_item_key(ffi.cast("void *", found))], flags
end

local function gui_tree_toggle(state, node)
    local key = node and state.tree_items[node.path]
    if not key then
        return false
    end
    state.libs.user32.SendMessageW(state.tree_hwnd, TVM_EXPAND, TVE_TOGGLE,
        ffi.cast("intptr_t", key))
    return true
end

local function gui_tree_select(state, node)
    local key = node and state.tree_items[node.path]
    if not key then
        return false
    end
    state.libs.user32.SendMessageW(state.tree_hwnd, TVM_SELECTITEM, TVGN_CARET,
        ffi.cast("intptr_t", key))
    state.libs.user32.SendMessageW(state.tree_hwnd, TVM_ENSUREVISIBLE, 0,
        ffi.cast("intptr_t", key))
    if state.focus ~= "tree" then
        state.focus = "tree"
        state.libs.user32.InvalidateRect(state.hwnd, nil, 0)
    end
    return true
end

local function gui_tree_selected_node(state)
    if not state.tree_hwnd then
        return nil
    end
    local result = state.libs.user32.SendMessageW(state.tree_hwnd, TVM_GETNEXTITEM,
        TVGN_CARET, 0)
    return state.tree_nodes[gui_item_key(ffi.cast("void *", result))]
end

local function gui_tree_activate(state, node)
    if not node then
        return false
    end
    if node.directory then
        local key = state.tree_items[node.path]
        if not key then
            return false
        end
        state.libs.user32.SendMessageW(state.tree_hwnd, TVM_EXPAND, TVE_TOGGLE,
            ffi.cast("intptr_t", key))
        return true
    end
    return gui_open_node(state, node)
end

local function gui_tree_build(state)
    local browser = state.browser
    local root = browser.root
    if not state.tree_hwnd or not root then
        return false
    end
    state.tree_building = true
    local key = gui_tree_insert(state, root, nil)
    local ok = key ~= nil and gui_tree_fill(state, root)
    if ok then
        state.libs.user32.SendMessageW(state.tree_hwnd, TVM_EXPAND, TVE_EXPAND,
            ffi.cast("intptr_t", key))
        local selected = browser.path and state.tree_items[browser.path]
        if selected then
            state.libs.user32.SendMessageW(state.tree_hwnd, TVM_SELECTITEM, TVGN_CARET,
                ffi.cast("intptr_t", selected))
            state.libs.user32.SendMessageW(state.tree_hwnd, TVM_ENSUREVISIBLE, 0,
                ffi.cast("intptr_t", selected))
        end
    end
    state.tree_building = false
    if not ok then
        state.message = "Cannot build the file tree"
        state.message_kind = "warn"
    end
    return ok
end

local function gui_sync_tree_bounds(state)
    local tree = state.tree_hwnd
    if not tree then
        return
    end
    local layout = state.layout
    if layout.tree_width <= 0 then
        state.libs.user32.ShowWindow(tree, SW_HIDE)
        return
    end
    state.libs.user32.ShowWindow(tree, SW_SHOW)
    local height = math.max(1, layout.content_height - layout.header_height)
    state.libs.user32.MoveWindow(tree, 0, layout.header_height, layout.tree_width,
        height, 1)
end

local function gui_tree_create(state)
    local libs = state.libs
    local init = ffi.new("mdview_init_controls[1]")
    init[0].dwSize = ffi.sizeof("mdview_init_controls")
    init[0].dwICC = 0x00000002 -- ICC_TREEVIEW_CLASSES
    libs.comctl32.InitCommonControlsEx(init)
    local style = WS_CHILD + WS_VISIBLE + WS_TABSTOP
        + TVS_HASBUTTONS + TVS_HASLINES + TVS_LINESATROOT + TVS_SHOWSELALWAYS
    local tree = libs.user32.CreateWindowExW(0, gui_wide(libs, "SysTreeView32"),
        gui_wide(libs, ""), style, 0, state.metrics.header_h, 10, 10,
        state.hwnd, nil, libs.kernel32.GetModuleHandleW(nil), nil)
    if tree == nil then
        return nil, "cannot create the file tree control (" .. gui_last_error(libs) .. ")"
    end
    state.tree_hwnd = tree
    libs.user32.SendMessageW(tree, WM_SETFONT,
        ffi.cast("uintptr_t", state.fonts.tree.regular), 1)
    local info = ffi.new("mdview_shfileinfo[1]")
    local image_list = libs.shell32.SHGetFileInfoW(gui_wide(libs, ""), 0, info,
        ffi.sizeof("mdview_shfileinfo"), SHGFI_SYSICONINDEX + SHGFI_SMALLICON)
    if tonumber(image_list) ~= 0 then
        libs.user32.SendMessageW(tree, TVM_SETIMAGELIST, 0,
            ffi.cast("intptr_t", image_list))
    end
    libs.user32.SendMessageW(tree, TVM_SETBKCOLOR, 0, gui_color(THEME.gui_bg) or 0)
    libs.user32.SendMessageW(tree, TVM_SETTEXTCOLOR, 0, gui_color(THEME.text) or 0)
    if not gui_treeproc_ref then
        gui_treeproc_ref = ffi.cast("mdview_wndproc", gui_tree_proc)
    end
    local previous = libs.user32.SetWindowLongPtrW(tree, -4, -- GWLP_WNDPROC
        ffi.cast("intptr_t", gui_treeproc_ref))
    state.tree_original_proc = ffi.cast("mdview_wndproc", previous)
    gui_tree_build(state)
    gui_sync_tree_bounds(state)
    return tree
end

local function gui_handle_notify(state, hwnd, lparam)
    local hdr = ffi.cast("mdview_nmhdr *", lparam)
    if hdr == nil or hdr.hwndFrom ~= state.tree_hwnd then
        return false
    end
    local code = tonumber(hdr.code) or 0
    local libs = state.libs
    if code == NM_CLICK or code == NM_SETFOCUS or code == TVN_SELCHANGEDW then
        if not state.tree_building and state.focus ~= "tree" then
            state.focus = "tree"
            libs.user32.InvalidateRect(hwnd, nil, 0)
        end
        return true
    elseif code == NM_KILLFOCUS then
        return true
    elseif code == NM_DBLCLK then
        local detail = ffi.cast("mdview_nmitemactivate *", lparam)
        if detail.iItem and tonumber(detail.iItem) and tonumber(detail.iItem) >= 0 then
            -- The control already toggles folders on a double click; only
            -- files need an explicit open here.
            local node = gui_tree_selected_node(state)
            if node and not node.directory then
                gui_open_node(state, node)
                libs.user32.InvalidateRect(hwnd, nil, 0)
            end
        end
        return true
    elseif code == TVN_ITEMEXPANDEDW then
        return true
    elseif code == TVN_ITEMEXPANDINGW then
        -- Children must exist before the control expands an item, so folders
        -- are filled here; returning TRUE would cancel the expansion.
        local detail = ffi.cast("mdview_nmtreeview *", lparam)
        local node = state.tree_nodes[gui_item_key(detail.itemNew.hItem)]
        if tonumber(detail.action) ~= TVE_COLLAPSE and node and node.directory
            and not state.tree_building then
            gui_tree_fill(state, node)
        end
        return false
    end
    return false
end

-- Tab and Enter are not forwarded to the parent by the tree control, so the
-- control is subclassed to switch panes and open the selected file.
gui_tree_proc = function(hwnd, message, wparam, lparam)
    local state = gui_state
    if not state or state.tree_hwnd ~= hwnd then
        local libs = gui_libs
        if not libs then
            return 0
        end
        return tonumber(libs.user32.DefWindowProcW(hwnd, message, wparam, lparam)) or 0
    end
    local ok, result = pcall(function()
        -- Mouse input is handled entirely here instead of being forwarded:
        -- the control's own button handling starts a drag loop that blocks the
        -- message loop until more mouse input arrives. Selecting the row and
        -- opening the document here keeps clicks immediate and predictable.
        if message == WM_LBUTTONDOWN then
            local node, flags = gui_tree_hit_node(state, lparam)
            if node then
                if bit.band(flags, TVHT_ONITEMBUTTON) ~= 0 then
                    gui_tree_toggle(state, node)
                else
                    gui_tree_select(state, node)
                    state.libs.user32.SetFocus(hwnd)
                end
            end
            return 0
        elseif message == WM_LBUTTONUP then
            return 0
        elseif message == WM_LBUTTONDBLCLK then
            local node, flags = gui_tree_hit_node(state, lparam)
            if node and bit.band(flags, TVHT_ONITEMBUTTON) == 0 then
                gui_tree_select(state, node)
                if node.directory then
                    gui_tree_toggle(state, node)
                else
                    gui_open_node(state, node)
                end
                state.libs.user32.InvalidateRect(state.hwnd, nil, 0)
            end
            return 0
        elseif message == WM_KEYDOWN then
            local token = GUI_VIRTUAL_KEYS[tonumber(wparam) or 0]
            if token == "TAB" or token == "ESC" then
                state.focus = "document"
                state.libs.user32.SetFocus(state.hwnd)
                state.libs.user32.InvalidateRect(state.hwnd, nil, 0)
                return 0
            elseif token == "ENTER" then
                M.gui_activate(state)
                return 0
            end
        end
        local original = state.tree_original_proc
        if original then
            return tonumber(original(hwnd, message, wparam, lparam)) or 0
        end
        return tonumber(state.libs.user32.DefWindowProcW(hwnd, message, wparam, lparam)) or 0
    end)
    if ok then
        return tonumber(result) or 0
    end
    io.stderr:write("mdview: GUI tree callback failed: " .. tostring(result) .. "\n")
    io.stderr:flush()
    state.message = "GUI tree error: " .. tostring(result)
    state.message_kind = "warn"
    return 0
end

local function gui_activate_selection(state)
    local node = gui_tree_selected_node(state)
    if not node then
        return false
    end
    local ok = gui_tree_activate(state, node)
    state.libs.user32.InvalidateRect(state.hwnd, nil, 0)
    return ok
end

function M.gui_tree_item(state, path)
    if not state or not state.tree_items then
        return nil
    end
    return state.tree_items[path]
end

function M.gui_activate(state)
    if not state or not state.tree_hwnd then
        return false
    end
    return gui_activate_selection(state)
end

local function gui_create_state(options)
    if not IS_WINDOWS then
        return nil, "--gui requires Windows (Win32 GUI)"
    end
    local libs = gui_native()
    if not libs then
        return nil, "--gui requires Windows (Win32 GUI)"
    end
    -- The window follows the Windows theme, never the terminal palette.
    apply_palette(gui_system_palette(libs))
    local fs, fs_error = filesystem()
    if not fs then
        return nil, "file browsing is unavailable: " .. tostring(fs_error)
    end
    local requested = options.file or "."
    local kind, kind_error = fs.kind(requested)
    if not kind then
        return nil, "cannot open '" .. requested .. "': " .. tostring(kind_error)
    end
    local path, resolve_error = fs.resolve(requested)
    if not path then
        return nil, "cannot resolve '" .. requested .. "': " .. tostring(resolve_error)
    end
    local is_directory = kind == "directory"
    local source
    local title
    if is_directory then
        source = gui_placeholder()
        title = "Select a Markdown file"
    else
        local data, read_error = (fs.read_document or read_document)(path)
        if not data then
            return nil, "cannot open '" .. requested .. "': " .. tostring(read_error)
        end
        source = data
        title = gui_document_title(path:match("([^/\\]+)$") or path)
    end

    -- System-DPI awareness must be set before measuring fonts, or GDI metrics
    -- come back virtualized while the window is created at physical pixels.
    libs.user32.SetProcessDPIAware()
    local screen = libs.user32.GetDC(nil)
    if screen == nil then
        return nil, "cannot query the screen device context (" .. gui_last_error(libs) .. ")"
    end
    local dpi = tonumber(libs.gdi32.GetDeviceCaps(screen, 90))
    if not dpi or dpi <= 0 then
        dpi = 96
    end
    local fonts = gui_create_fonts(libs, dpi)
    local metrics = gui_create_metrics(libs, screen, dpi, fonts)
    libs.user32.ReleaseDC(nil, screen)

    local settings = {
        images = options.images ~= false,
        numbers = options.numbers ~= false,
        case_sensitive = options.case_sensitive or false,
    }
    local view = M.new_view(title, {})
    local browser = M.new_browser(view, path, is_directory, settings, fs)
    browser.tree_visible = true
    browser.pending = { kind = "root" }
    local state = {
        libs = libs,
        fs = fs,
        browser = browser,
        path = path,
        source = source,
        title = title,
        is_directory = is_directory,
        settings = settings,
        fonts = fonts,
        metrics = metrics,
        brushes = {},
        brush_cache = {},
        images = {},
        layout = M.gui_layout(GUI_DEFAULT_WIDTH, GUI_DEFAULT_HEIGHT, metrics),
        view = nil,
        doc_cols = 0,
        focus = is_directory and "tree" or "document",
        message = "",
        message_kind = "info",
        hook_error = nil,
        hwnd = nil,
        tree_hwnd = nil,
        tree_items = {},
        tree_nodes = {},
        tree_filled = {},
        tree_building = false,
        tree_original_proc = nil,
        buffer = nil,
        paints = 0,
    }
    local brush_specs = {
        background = THEME.gui_bg,
        panel = THEME.gui_panel,
        bar = THEME.bar_bg,
        selection = THEME.gui_selection,
        separator = THEME.gui_separator,
        accent = THEME.gui_accent,
    }
    for name, spec in pairs(brush_specs) do
        state.brushes[name] = libs.gdi32.CreateSolidBrush(gui_color(spec) or 0)
    end

    M.process_browser_pending(browser, state.layout.width, state.layout.height)
    if browser.message ~= "" then
        local message = browser.message
        gui_release_state(state)
        return nil, message
    end
    gui_sync_document(state)
    return state
end

M.gui_create_state = gui_create_state
M.gui_destroy = gui_release_state

local function gui_fill(state, hdc, x, y, width, height, brush)
    if width <= 0 or height <= 0 then
        return
    end
    local rect = ffi.new("mdview_rect[1]")
    rect[0].left = x
    rect[0].top = y
    rect[0].right = x + width
    rect[0].bottom = y + height
    state.libs.user32.FillRect(hdc, rect, brush)
end

local function gui_text_color(state, hdc, font, color)
    local gdi = state.libs.gdi32
    if font then
        gdi.SelectObject(hdc, font)
    end
    gdi.SetBkMode(hdc, 1)
    gdi.SetTextColor(hdc, color or gui_color(THEME.text) or 0)
end

local function gui_draw_text(state, hdc, text, x, y, color, font)
    local wide, length = gui_wide(state.libs, text)
    if length == 0 then
        return
    end
    gui_text_color(state, hdc, font, color)
    state.libs.gdi32.TextOutW(hdc, x, y, wide, length)
end

local function gui_draw_text_box(state, hdc, text, left, top, right, bottom, color, font,
                                 align)
    local wide, length = gui_wide(state.libs, text)
    local rect = ffi.new("mdview_rect[1]")
    rect[0].left = left
    rect[0].top = top
    rect[0].right = right
    rect[0].bottom = bottom
    local format = 0x0020 + 0x0004 + 0x0800
    if align == "right" then
        format = format + 0x0002
    end
    gui_text_color(state, hdc, font, color)
    state.libs.user32.DrawTextW(hdc, wide, length, rect, format)
end

local function gui_measure_text(state, hdc, text, font)
    local wide, length = gui_wide(state.libs, text)
    if length == 0 then
        return 0
    end
    state.libs.gdi32.SelectObject(hdc, font)
    local size = ffi.new("mdview_size[1]")
    state.libs.gdi32.GetTextExtentPoint32W(hdc, wide, length, size)
    return size[0].cx
end

local function gui_gutter_text(line, gutter)
    if gutter <= 0 then
        return ""
    end
    if line.number then
        return string.format("%" .. (gutter - 1) .. "d ", line.number)
    end
    return string.rep(" ", gutter)
end

-- The tree body is a real SysTreeView32 child window, so only its header bar
-- and the focus accent are painted by the parent.
local function gui_paint_tree(state, hdc)
    local layout = state.layout
    local metrics = state.metrics
    gui_fill(state, hdc, 0, 0, layout.tree_width, layout.header_height,
        state.brushes.bar)
    gui_draw_text_box(state, hdc, "FILES", metrics.padding, 0, layout.tree_width - 4,
        layout.header_height, gui_color(THEME.bar_fg), state.fonts.tree.bold, "left")
    if state.focus == "tree" then
        gui_fill(state, hdc, 0, 0, 3, layout.header_height, state.brushes.accent)
    end
end

local function gui_document_position(state)
    local view = state.view
    if not view or #view.lines == 0 then
        return "0/0"
    end
    local percent = 0
    if #view.lines > 1 then
        percent = math.floor((view.top - 1) / (#view.lines - 1) * 100)
    end
    return string.format("%3d%%  %d/%d", percent, view.top, #view.lines)
end

-- Draws a decoded image block: the pixels are stretched into the reserved
-- character cells with the aspect ratio preserved and a frame around them.
local function gui_paint_image(state, hdc, spec, x, y, metrics)
    local gdi = state.libs.gdi32
    local entry = gui_image(state, spec.path)
    if not entry then
        return false
    end
    local box_w = math.max(1, spec.columns * metrics.cell_w)
    local box_h = math.max(1, spec.rows * metrics.cell_h)
    local scale = math.min(box_w / entry.width, box_h / entry.height)
    local width = math.max(1, math.floor(entry.width * scale + 0.5))
    local height = math.max(1, math.floor(entry.height * scale + 0.5))
    local left = x + math.floor((box_w - width) / 2)
    local top = y + math.floor((box_h - height) / 2)
    local memory = gdi.CreateCompatibleDC(hdc)
    if memory == nil then
        return false
    end
    local previous = gdi.SelectObject(memory, entry.handle)
    gdi.SetStretchBltMode(hdc, 4) -- HALFTONE
    gdi.StretchBlt(hdc, left, top, width, height, memory, 0, 0, entry.width,
        entry.height, 0x00CC0020)
    gdi.SelectObject(memory, previous)
    gdi.DeleteDC(memory)
    gui_fill(state, hdc, left - 1, top - 1, width + 2, 1, state.brushes.separator)
    gui_fill(state, hdc, left - 1, top + height, width + 2, 1, state.brushes.separator)
    gui_fill(state, hdc, left - 1, top, 1, height, state.brushes.separator)
    gui_fill(state, hdc, left + width, top, 1, height, state.brushes.separator)
    return true
end

local function gui_paint_document(state, hdc)
    local libs = state.libs
    local layout = state.layout
    local metrics = state.metrics
    gui_fill(state, hdc, layout.doc_x, 0, layout.doc_width, layout.content_height,
        state.brushes.background)
    gui_fill(state, hdc, layout.doc_x, 0, layout.doc_width, layout.header_height,
        state.brushes.bar)
    if state.focus == "document" then
        gui_fill(state, hdc, layout.doc_x, 0, 3, layout.content_height,
            state.brushes.accent)
    end
    local position = gui_document_position(state)
    local position_width = gui_measure_text(state, hdc, position, state.fonts.tree.regular)
    local header_right = layout.doc_x + layout.doc_width - metrics.padding
    gui_draw_text_box(state, hdc, state.title, layout.doc_x + metrics.padding, 0,
        header_right - position_width - metrics.padding, layout.header_height,
        gui_color(THEME.bar_fg), state.fonts.tree.regular, "left")
    gui_draw_text_box(state, hdc, position, header_right - position_width, 0,
        header_right, layout.header_height,
        gui_color(THEME.bar_fg), state.fonts.tree.regular, "right")

    local view = state.view
    if not view then
        return
    end
    local gutter = view.gutter_width or 0
    local text_x = layout.doc_x + metrics.padding
    local top = view.top
    local saved = libs.gdi32.SaveDC(hdc)
    libs.gdi32.IntersectClipRect(hdc, layout.doc_x, layout.header_height,
        layout.doc_x + layout.doc_width, layout.content_height)
    for row = 1, layout.rows do
        local line = view.lines[top + row - 1]
        if not line then
            break
        end
        local y = layout.header_height + (row - 1) * metrics.cell_h
        if line.image then
            local block_top = y - (line.image.row or 0) * metrics.cell_h
            if not gui_paint_image(state, hdc, line.image, text_x + gutter * metrics.cell_w,
                block_top, metrics) then
                gui_draw_text(state, hdc, "[image] " .. (line.image.src or ""), text_x,
                    y + metrics.text_offset, gui_color(THEME.line_number),
                    state.fonts.doc.regular)
            end
        elseif gutter > 0 then
            gui_draw_text(state, hdc, gui_gutter_text(line, gutter), text_x,
                y + metrics.text_offset, gui_color(THEME.line_number),
                state.fonts.doc.regular)
        end
        local x = text_x + gutter * metrics.cell_w
        for _, span in ipairs(line.spans) do
            local cells = display_width(span.text)
            if cells > 0 then
                local fg_spec, bg_spec = gui_span_colors(span.style)
                if bg_spec then
                    gui_fill(state, hdc, x, y, cells * metrics.cell_w, metrics.cell_h,
                        gui_brush(state, bg_spec))
                end
                gui_draw_text(state, hdc, span.text, x, y + metrics.text_offset,
                    gui_color(fg_spec), gui_span_font(state, span.style))
                if span.style and (span.style.strike or span.style.underline) then
                    local line_brush = gui_brush(state, fg_spec)
                    if span.style.strike then
                        gui_fill(state, hdc, x, y + math.floor(metrics.cell_h * 0.55),
                            cells * metrics.cell_w, 1, line_brush)
                    end
                    if span.style.underline then
                        gui_fill(state, hdc, x, y + metrics.cell_h - gui_scale(metrics.dpi, 3),
                            cells * metrics.cell_w, 1, line_brush)
                    end
                end
                x = x + cells * metrics.cell_w
            end
        end
    end
    libs.gdi32.RestoreDC(hdc, saved)
end

local function gui_status_text(state)
    if state.message ~= "" then
        return state.message, state.message_kind == "warn" and THEME.warn or THEME.info
    end
    if #state.browser.entries == 0 then
        return "No Markdown files or folders here", THEME.warn
    end
    if state.focus == "tree" then
        return "Tree: click to select · double-click or Enter opens · Tab switches pane",
            THEME.info
    end
    return "Wheel or keys scroll · Tab switches to the file tree", THEME.info
end

local function gui_paint_status(state, hdc)
    local libs = state.libs
    local layout = state.layout
    local metrics = state.metrics
    gui_fill(state, hdc, 0, layout.content_height, layout.width, layout.height
        - layout.content_height, state.brushes.bar)
    local text, color = gui_status_text(state)
    local view = state.view
    local right = view and string.format("%d lines", #view.lines) or ""
    local right_width = right ~= "" and gui_measure_text(state, hdc, right,
        state.fonts.tree.regular) or 0
    local status_right = layout.width - metrics.padding - right_width
    gui_draw_text_box(state, hdc, sanitize_text(text), metrics.padding,
        layout.content_height, status_right - metrics.padding, layout.height,
        gui_color(color), state.fonts.tree.regular, "left")
    if right ~= "" then
        gui_draw_text_box(state, hdc, right, status_right,
            layout.content_height, layout.width - metrics.padding, layout.height,
            gui_color(THEME.bar_fg), state.fonts.tree.regular, "right")
    end
end

local function gui_paint(state, hdc)
    local layout = state.layout
    gui_sync_document(state)
    gui_fill(state, hdc, 0, 0, layout.width, layout.height, state.brushes.background)
    if layout.tree_width > 0 then
        gui_paint_tree(state, hdc)
        gui_fill(state, hdc, layout.tree_width, 0, layout.separator,
            layout.content_height, state.brushes.separator)
    end
    gui_paint_document(state, hdc)
    gui_paint_status(state, hdc)
end

local function gui_sync_scrollbar(state)
    if state.hwnd == nil or not state.view then
        return
    end
    local info = ffi.new("mdview_scroll_info[1]")
    info[0].cbSize = ffi.sizeof("mdview_scroll_info")
    info[0].fMask = 1 + 2 + 4
    info[0].nMin = 1
    info[0].nMax = math.max(1, #state.view.lines)
    info[0].nPage = math.max(1, state.layout.rows)
    info[0].nPos = state.view.top
    state.libs.user32.SetScrollInfo(state.hwnd, 1, info, 1)
end

local function gui_present(state, hdc)
    local libs = state.libs
    local layout = state.layout
    if layout.width <= 0 or layout.height <= 0 then
        return
    end
    local buffer = state.buffer
    if not buffer or buffer.width ~= layout.width or buffer.height ~= layout.height then
        gui_release_buffer(state)
        local mem = libs.gdi32.CreateCompatibleDC(hdc)
        local bitmap = libs.gdi32.CreateCompatibleBitmap(hdc, layout.width, layout.height)
        if mem == nil or bitmap == nil then
            if mem then
                libs.gdi32.DeleteDC(mem)
            end
            if bitmap then
                libs.gdi32.DeleteObject(bitmap)
            end
            return
        end
        buffer = {
            dc = mem,
            bitmap = bitmap,
            previous = libs.gdi32.SelectObject(mem, bitmap),
            width = layout.width,
            height = layout.height,
        }
        state.buffer = buffer
    end
    gui_paint(state, buffer.dc)
    state.paints = (state.paints or 0) + 1
    libs.gdi32.BitBlt(hdc, 0, 0, layout.width, layout.height, buffer.dc, 0, 0, 0x00CC0020)
end

local function gui_apply_layout(state, width, height)
    state.layout = M.gui_layout(width, height, state.metrics)
    gui_sync_tree_bounds(state)
    gui_sync_document(state)
    gui_sync_scrollbar(state)
end

local function gui_handle_paint(state, hwnd)
    local libs = state.libs
    local paint = ffi.new("mdview_paint_struct[1]")
    local hdc = libs.user32.BeginPaint(hwnd, paint)
    if hdc ~= nil then
        gui_present(state, hdc)
        libs.user32.EndPaint(hwnd, paint)
    end
end

local function gui_handle_size(state, hwnd)
    local rect = ffi.new("mdview_rect[1]")
    if state.libs.user32.GetClientRect(hwnd, rect) == 0 then
        return
    end
    local width = rect[0].right - rect[0].left
    local height = rect[0].bottom - rect[0].top
    if width < 1 or height < 1 then
        return
    end
    gui_apply_layout(state, width, height)
    state.libs.user32.InvalidateRect(hwnd, nil, 0)
end

-- Clicks inside the tree are handled by SysTreeView32 itself (selection and
-- double-click already behave natively); the parent only reacts to the
-- document pane.
-- Web links open in the default browser through the shell. Only absolute
-- web/mail addresses are handed over; anything else is left alone.
local function gui_web_link(url)
    if type(url) ~= "string" then
        return false
    end
    local scheme = url:lower():match("^([%a][%w+.-]*):")
    return scheme == "http" or scheme == "https" or scheme == "mailto"
end

-- Returns the link under a client point and the URL it points at.
function M.gui_link_at(state, x, y)
    if not state or not state.view then
        return nil
    end
    local layout = state.layout
    local metrics = state.metrics
    local target = M.gui_hit_test(layout, metrics, x, y)
    if target.pane ~= "document" or not target.row then
        return nil
    end
    local line = state.view.lines[state.view.top + target.row - 1]
    if not line or line.image then
        return nil
    end
    local gutter = state.view.gutter_width or 0
    local text_x = layout.doc_x + metrics.padding + gutter * metrics.cell_w
    local column = math.floor((x - text_x) / metrics.cell_w) + 1
    if column < 1 then
        return nil
    end
    local offset = 0
    for _, span in ipairs(line.spans) do
        local cells = display_width(span.text)
        if cells > 0 and column >= offset + 1 and column <= offset + cells then
            local href = span.style and span.style.href
            if href and gui_web_link(href) then
                return href
            end
            return nil
        end
        offset = offset + cells
    end
    return nil
end

local function gui_open_url(state, url)
    if not gui_web_link(url) then
        return false
    end
    local wide_verb = gui_wide(state.libs, "open")
    local wide_url = gui_wide(state.libs, url)
    local result = state.libs.shell32.ShellExecuteW(state.hwnd, wide_verb, wide_url,
        nil, nil, 1)
    if tonumber(result) <= 32 then
        state.message = "Cannot open " .. url
        state.message_kind = "warn"
        return false
    end
    state.message = "Opened " .. url .. " in the browser"
    state.message_kind = "info"
    return true
end

M.gui_open_url = gui_open_url

local function gui_handle_click(state, hwnd, lparam)
    local point = ffi.new("mdview_point[1]")
    local value = tonumber(lparam) or 0
    point[0].x = bit.band(value, 0xFFFF)
    if point[0].x >= 0x8000 then
        point[0].x = point[0].x - 0x10000
    end
    point[0].y = bit.band(bit.rshift(value, 16), 0xFFFF)
    if point[0].y >= 0x8000 then
        point[0].y = point[0].y - 0x10000
    end
    local target = M.gui_hit_test(state.layout, state.metrics, point[0].x, point[0].y)
    if target.pane == "document" then
        state.focus = "document"
        state.libs.user32.SetFocus(hwnd)
        local url = M.gui_link_at(state, point[0].x, point[0].y)
        if url then
            local opener = state.open_link or gui_open_url
            opener(state, url)
        end
    end
    state.libs.user32.InvalidateRect(hwnd, nil, 0)
end

local function gui_handle_wheel(state, hwnd, wparam, lparam)
    local libs = state.libs
    local value = tonumber(wparam) or 0
    local delta = bit.band(bit.rshift(value, 16), 0xFFFF)
    if delta >= 0x8000 then
        delta = delta - 0x10000
    end
    if delta == 0 then
        return
    end
    local steps = math.floor(delta * GUI_SCROLL_LINES / 120 + 0.5)
    if steps == 0 then
        steps = delta > 0 and 1 or -1
    end
    local point = ffi.new("mdview_point[1]")
    local position = tonumber(lparam) or 0
    point[0].x = bit.band(position, 0xFFFF)
    if point[0].x >= 0x8000 then
        point[0].x = point[0].x - 0x10000
    end
    point[0].y = bit.band(bit.rshift(position, 16), 0xFFFF)
    if point[0].y >= 0x8000 then
        point[0].y = point[0].y - 0x10000
    end
    libs.user32.ScreenToClient(hwnd, point)
    local target = M.gui_hit_test(state.layout, state.metrics, point[0].x, point[0].y)
    if target.pane == "tree" and state.tree_hwnd then
        libs.user32.SendMessageW(state.tree_hwnd, WM_MOUSEWHEEL, wparam, lparam)
        return
    elseif state.view then
        local action = steps > 0 and "up" or "down"
        for _ = 1, math.abs(steps) do
            state.view.top = M.gui_scroll_top(state.view.top, #state.view.lines,
                state.layout.rows, action)
        end
    end
    gui_sync_scrollbar(state)
    libs.user32.InvalidateRect(hwnd, nil, 0)
end

-- Keys for the tree control are handled inside the control (arrows, Home/End,
-- PageUp/PageDown, +/-, type-ahead) and by its subclass for Tab/Enter.
local function gui_handle_key(state, hwnd, wparam, lparam)
    local token = GUI_VIRTUAL_KEYS[tonumber(wparam) or 0]
    if not token then
        return false
    end
    local repeated = bit.band(bit.rshift(tonumber(lparam) or 0, 30), 1) == 1
    if repeated and token == "TAB" then
        return true
    end
    if token == "TAB" then
        state.focus = "tree"
        if state.tree_hwnd then
            state.libs.user32.SetFocus(state.tree_hwnd)
        end
        state.libs.user32.InvalidateRect(hwnd, nil, 0)
        return true
    end
    if state.focus ~= "document" or not state.view then
        return false
    end
    local action = M.gui_key_action(token, "document")
    if not action then
        return false
    end
    state.view.top = M.gui_scroll_top(state.view.top, #state.view.lines,
        state.layout.rows, action)
    gui_sync_scrollbar(state)
    state.libs.user32.InvalidateRect(hwnd, nil, 0)
    return true
end

local function gui_handle_scrollbar(state, hwnd, wparam)
    local view = state.view
    if not view then
        return
    end
    local value = tonumber(wparam) or 0
    local code = bit.band(value, 0xFFFF)
    local action
    if code == 0 then
        action = "up"
    elseif code == 1 then
        action = "down"
    elseif code == 2 then
        action = "page_up"
    elseif code == 3 then
        action = "page_down"
    elseif code == 6 then
        action = "top"
    elseif code == 7 then
        action = "bottom"
    end
    if code == 4 or code == 5 then
        local position = bit.band(bit.rshift(value, 16), 0xFFFF)
        view.top = gui_clamp(position, 1, math.max(1, #view.lines - state.layout.rows + 1))
    elseif action then
        view.top = M.gui_scroll_top(view.top, #view.lines, state.layout.rows, action)
    end
    gui_sync_scrollbar(state)
    state.libs.user32.InvalidateRect(hwnd, nil, 0)
end

local function gui_dispatch(state, hwnd, message, wparam, lparam)
    local libs = state.libs
    if message == WM_PAINT then
        gui_handle_paint(state, hwnd)
        return 0
    elseif message == WM_PRINTCLIENT then
        gui_present(state, ffi.cast("void *", wparam))
        return 0
    elseif message == WM_ERASEBKGND then
        return 1
    elseif message == WM_SIZE then
        gui_handle_size(state, hwnd)
        return 0
    elseif message == WM_MOUSEWHEEL then
        gui_handle_wheel(state, hwnd, wparam, lparam)
        return 0
    elseif message == WM_LBUTTONDOWN or message == WM_LBUTTONDBLCLK then
        gui_handle_click(state, hwnd, lparam)
        return 0
    elseif message == WM_NOTIFY then
        if gui_handle_notify(state, hwnd, lparam) then
            return 0
        end
    elseif message == WM_KEYDOWN then
        gui_handle_key(state, hwnd, wparam, lparam)
        return 0
    elseif message == WM_VSCROLL then
        gui_handle_scrollbar(state, hwnd, wparam)
        return 0
    elseif message == WM_TIMER then
        libs.user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
        return 0
    elseif message == WM_CLOSE then
        libs.user32.DestroyWindow(hwnd)
        return 0
    elseif message == WM_DESTROY then
        gui_release_buffer(state)
        libs.user32.PostQuitMessage(0)
        return 0
    elseif message == WM_GETMINMAXINFO then
        local info = ffi.cast("mdview_minmax_info *", lparam)
        info.min_track.x = gui_scale(state.metrics.dpi, GUI_MIN_WIDTH)
        info.min_track.y = gui_scale(state.metrics.dpi, GUI_MIN_HEIGHT)
        return 0
    elseif message == WM_SETFOCUS or message == WM_KILLFOCUS then
        libs.user32.InvalidateRect(hwnd, nil, 0)
        return 0
    end
    return tonumber(libs.user32.DefWindowProcW(hwnd, message, wparam, lparam)) or 0
end

local function gui_window_proc(hwnd, message, wparam, lparam)
    local state = gui_state
    if not state then
        local libs = gui_libs
        if not libs then
            return 0
        end
        return tonumber(libs.user32.DefWindowProcW(hwnd, message, wparam, lparam)) or 0
    end
    local ok, result = pcall(gui_dispatch, state, hwnd, message, wparam, lparam)
    if not ok then
        io.stderr:write("mdview: GUI callback failed: " .. tostring(result) .. "\n")
        io.stderr:flush()
        state.message = "GUI error: " .. tostring(result)
        state.message_kind = "warn"
        return 0
    end
    return tonumber(result) or 0
end

function M.gui_run(state, options)
    if not IS_WINDOWS then
        return 1, "--gui requires Windows (Win32 GUI)"
    end
    if not state then
        return 1, "no GUI state"
    end
    local libs = state.libs
    local instance = libs.kernel32.GetModuleHandleW(nil)
    local class_name = gui_wide(libs, GUI_CLASS_NAME)
    if not gui_wndproc_ref then
        gui_wndproc_ref = ffi.cast("mdview_wndproc", gui_window_proc)
    end
    local wndclass = ffi.new("mdview_wndclass[1]")
    wndclass[0].cbSize = ffi.sizeof("mdview_wndclass")
    wndclass[0].style = 0x0001 + 0x0002
    wndclass[0].lpfnWndProc = gui_wndproc_ref
    wndclass[0].hInstance = instance
    wndclass[0].hCursor = libs.user32.LoadCursorW(nil, ffi.cast("const uint16_t *", 32512))
    wndclass[0].hbrBackground = nil
    wndclass[0].lpszClassName = class_name
    local icon = libs.user32.LoadIconW(nil, ffi.cast("const uint16_t *", 32512))
    wndclass[0].hIcon = icon
    wndclass[0].hIconSm = icon
    if not gui_class_registered then
        local atom = libs.user32.RegisterClassExW(wndclass)
        if atom ~= 0 then
            gui_class_registered = true
        elseif tonumber(libs.kernel32.GetLastError()) == 1410 then
            -- ERROR_CLASS_ALREADY_EXISTS: reopen a window from a previous run.
            gui_class_registered = true
        else
            return 1, "cannot register the mdview window class (" .. gui_last_error(libs) .. ")"
        end
    end

    local style = 0x00CF0000 + 0x00200000 + WS_CLIPCHILDREN
    local dpi = state.metrics.dpi
    local screen_width = math.max(640, tonumber(libs.user32.GetSystemMetrics(0)) or 1024)
    local screen_height = math.max(480, tonumber(libs.user32.GetSystemMetrics(1)) or 768)
    local rect = ffi.new("mdview_rect[1]")
    rect[0].left = 0
    rect[0].top = 0
    rect[0].right = math.max(gui_scale(dpi, GUI_MIN_WIDTH), math.min(
        gui_scale(dpi, GUI_DEFAULT_WIDTH), math.floor(screen_width * 0.94)))
    rect[0].bottom = math.max(gui_scale(dpi, GUI_MIN_HEIGHT), math.min(
        gui_scale(dpi, GUI_DEFAULT_HEIGHT), math.floor(screen_height * 0.90)))
    libs.user32.AdjustWindowRectEx(rect, style, 0, 0)
    local window_title = gui_wide(libs, "mdview — " .. state.path)
    gui_state = state
    local hwnd = libs.user32.CreateWindowExW(0, class_name, window_title, style, 100, 100,
        rect[0].right - rect[0].left, rect[0].bottom - rect[0].top, nil, nil, instance, nil)
    if hwnd == nil then
        local message = "cannot create the mdview window (" .. gui_last_error(libs) .. ")"
        gui_state = nil
        return 1, message
    end
    state.hwnd = hwnd
    local tree, tree_error = gui_tree_create(state)
    if not tree then
        libs.user32.DestroyWindow(hwnd)
        state.hwnd = nil
        gui_state = nil
        return 1, tree_error
    end
    libs.user32.ShowWindow(hwnd, SW_SHOW)
    libs.user32.UpdateWindow(hwnd)
    if state.focus == "tree" then
        libs.user32.SetFocus(tree)
    else
        libs.user32.SetFocus(hwnd)
    end
    if options and options.auto_close_ms then
        libs.user32.SetTimer(hwnd, 1, options.auto_close_ms, nil)
    end
    if options and options.on_ready then
        local ready, hook_error = pcall(options.on_ready, state, hwnd)
        if not ready then
            -- Surface the failure instead of silently keeping the window: a
            -- broken startup hook usually means the caller's own checks ran
            -- against a half-initialised window.
            state.hook_error = tostring(hook_error)
            state.message = "GUI hook failed: " .. tostring(hook_error)
            state.message_kind = "warn"
            io.stderr:write("mdview: GUI hook failed: " .. tostring(hook_error) .. "\n")
            io.stderr:flush()
        end
    end

    local message = ffi.new("mdview_msg[1]")
    local code = 0
    local run_error
    while true do
        local result = libs.user32.GetMessageW(message, nil, 0, 0)
        if result == 0 then
            break
        elseif result == -1 then
            code = 1
            run_error = "message loop failed (" .. gui_last_error(libs) .. ")"
            break
        end
        libs.user32.TranslateMessage(message)
        libs.user32.DispatchMessageW(message)
    end
    gui_release_buffer(state)
    state.hwnd = nil
    state.tree_hwnd = nil
    gui_state = nil
    -- The registered class and the tree subclass still hold these function
    -- pointers, so they stay alive for the rest of the process.
    return code, run_error
end

local function gui_le16(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function gui_le32(value)
    value = value % 4294967296
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function gui_save_bitmap(state, dc, bitmap, width, height, path)
    local libs = state.libs
    local stride = math.floor((width * 3 + 3) / 4) * 4
    local image = ffi.new("mdview_bitmap_info[1]")
    image[0].header.biSize = ffi.sizeof("mdview_bitmap_header")
    image[0].header.biWidth = width
    image[0].header.biHeight = height
    image[0].header.biPlanes = 1
    image[0].header.biBitCount = 24
    image[0].header.biCompression = 0
    local pixels = ffi.new("uint8_t[?]", stride * height)
    if libs.gdi32.GetDIBits(dc, bitmap, 0, height, pixels, image, 0) == 0 then
        return nil, "cannot read the rendered pixels (" .. gui_last_error(libs) .. ")"
    end
    local data = ffi.string(pixels, stride * height)
    local header = "BM" .. gui_le32(54 + #data) .. gui_le16(0) .. gui_le16(0)
        .. gui_le32(54) .. gui_le32(40) .. gui_le32(width) .. gui_le32(height)
        .. gui_le16(1) .. gui_le16(24) .. gui_le32(0) .. gui_le32(#data)
        .. gui_le32(2835) .. gui_le32(2835) .. gui_le32(0) .. gui_le32(0)
    local file, open_error = io.open(path, "wb")
    if not file then
        return nil, "cannot write " .. path .. ": " .. tostring(open_error)
    end
    local wrote, write_error = file:write(header, data)
    local closed, close_error = file:close()
    if not wrote or not closed then
        return nil, "cannot write " .. path .. ": " .. tostring(write_error or close_error)
    end
    local check = io.open(path, "rb")
    if not check then
        return nil, "cannot verify " .. path
    end
    local size = check:seek("end")
    check:close()
    if size ~= 54 + #data then
        return nil, string.format("incomplete image write: %s has %d of %d bytes",
            path, size or -1, 54 + #data)
    end
    return true
end

function M.gui_snapshot(state, width, height, path)
    if not IS_WINDOWS or not state then
        return nil, "GUI snapshots require Windows and a GUI state"
    end
    width = math.floor(tonumber(width) or 0)
    height = math.floor(tonumber(height) or 0)
    if width < 2 or height < 2 then
        return nil, "snapshot size must be at least 2x2"
    end
    local libs = state.libs
    local screen = libs.user32.GetDC(nil)
    if screen == nil then
        return nil, "cannot acquire the screen device context"
    end
    local mem = libs.gdi32.CreateCompatibleDC(screen)
    local bitmap = libs.gdi32.CreateCompatibleBitmap(screen, width, height)
    if mem == nil or bitmap == nil then
        if mem then
            libs.gdi32.DeleteDC(mem)
        end
        if bitmap then
            libs.gdi32.DeleteObject(bitmap)
        end
        libs.user32.ReleaseDC(nil, screen)
        return nil, "cannot allocate a " .. width .. "x" .. height .. " bitmap"
    end
    local previous = libs.gdi32.SelectObject(mem, bitmap)
    state.layout = M.gui_layout(width, height, state.metrics)
    gui_sync_document(state)
    gui_paint(state, mem)
    local ok, err = gui_save_bitmap(state, mem, bitmap, width, height, path)
    libs.gdi32.SelectObject(mem, previous)
    libs.gdi32.DeleteObject(bitmap)
    libs.gdi32.DeleteDC(mem)
    libs.user32.ReleaseDC(nil, screen)
    return ok, err
end

-- Capture the live window's client area (including the native tree control)
-- so the real rendering can be inspected without screen grabbing.
function M.gui_capture(state, path)
    if not IS_WINDOWS or not state or not state.hwnd then
        return nil, "gui_capture requires a live GUI window"
    end
    local libs = state.libs
    local rect = ffi.new("mdview_rect[1]")
    if libs.user32.GetClientRect(state.hwnd, rect) == 0 then
        return nil, "cannot measure the window (" .. gui_last_error(libs) .. ")"
    end
    local width = rect[0].right - rect[0].left
    local height = rect[0].bottom - rect[0].top
    if width < 2 or height < 2 then
        return nil, "window is too small to capture"
    end
    local screen = libs.user32.GetDC(nil)
    if screen == nil then
        return nil, "cannot acquire the screen device context"
    end
    local mem = libs.gdi32.CreateCompatibleDC(screen)
    local bitmap = libs.gdi32.CreateCompatibleBitmap(screen, width, height)
    if mem == nil or bitmap == nil then
        if mem then
            libs.gdi32.DeleteDC(mem)
        end
        if bitmap then
            libs.gdi32.DeleteObject(bitmap)
        end
        libs.user32.ReleaseDC(nil, screen)
        return nil, "cannot allocate a " .. width .. "x" .. height .. " bitmap"
    end
    local previous = libs.gdi32.SelectObject(mem, bitmap)
    local printed = libs.user32.PrintWindow(state.hwnd, mem, 1)
    if tonumber(printed) ~= 1 then
        local window_dc = libs.user32.GetDC(state.hwnd)
        if window_dc ~= nil then
            libs.gdi32.BitBlt(mem, 0, 0, width, height, window_dc, 0, 0, 0x00CC0020)
            libs.user32.ReleaseDC(state.hwnd, window_dc)
        end
    end
    local ok, err = gui_save_bitmap(state, mem, bitmap, width, height, path)
    libs.gdi32.SelectObject(mem, previous)
    libs.gdi32.DeleteObject(bitmap)
    libs.gdi32.DeleteDC(mem)
    libs.user32.ReleaseDC(nil, screen)
    return ok, err
end

local function run_gui(options)
    if not IS_WINDOWS then
        io.stderr:write("mdview: --gui requires Windows (Win32); use the terminal pager instead\n")
        return 1
    end
    if options.file == "-" then
        io.stderr:write("mdview: --gui cannot read from stdin; pass a Markdown file or a folder\n")
        return 1
    end
    if options.theme_set then
        io.stderr:write("mdview: --gui always follows the Windows theme; "
            .. "--theme applies to the terminal pager only\n")
        return 1
    end
    local state, state_error = gui_create_state(options)
    if not state then
        io.stderr:write("mdview: " .. tostring(state_error) .. "\n")
        return 1
    end
    local code, run_error = M.gui_run(state, nil)
    M.gui_destroy(state)
    if code ~= 0 and run_error then
        io.stderr:write("mdview: " .. tostring(run_error) .. "\n")
    end
    return code
end

return { run = run_gui }
end)()

-- =========================================================================
-- 17. CLI
-- =========================================================================
local function usage(stream)
    stream:write([[
mdview - terminal Markdown viewer (LuaJIT + FFI)

USAGE:
  luajit mdview.lua [OPTIONS] [FILE.md | DIRECTORY]

  No path opens the current directory tree. A Markdown file opens directly.

OPTIONS:
  -w, --width N        Wrap width for non-interactive output (default 80)
  --no-pager           Render the document and exit
  --color              Keep ANSI colors when output is not a tty
  --no-color           Disable ANSI colors (also honors NO_COLOR)
  --theme dark|light   Terminal palette (default: dark; --gui uses the
                       Windows theme)
  --no-images          Show image placeholders instead of block art
  -n, --numbers        Show source line numbers (default in the pager)
  --no-numbers         Hide source line numbers
  --snapshot [WxH]     Print one TUI frame and exit (default 80x24)
  --case-sensitive     Search matches case exactly
  --search PATTERN     Pre-fill search (useful with --snapshot)
  --gui                Open the Windows GUI (Win32 SDK, requires Windows)
  -h, --help           Show this help

KEYS:
  q/Esc quit   j/k scroll   d/u half-page   Space/b page
  g/G ends     / search      n/N next match   t outline   h help
  f files      Tab switch panes
  Tree: j/k move, h/l collapse/expand/open, gg/G first/last,
        Enter open, Ctrl-d/u half-page, r refresh, ? help, Esc document

GUI:
  --gui opens a native window in the current Windows theme. The file list
  is the Windows tree control with standard folder and file icons: click to
  select, double-click a folder to expand, double-click a file or press
  Enter to open it. Tab switches panes and the wheel or keyboard scrolls.
  Requires Windows; conflicts with --snapshot and --theme.

NOTES:
  Windows pager support needs Windows 10+ with VT sequences enabled
  (Windows Terminal or conhost). Image decoding uses ImageMagick
  (convert or magick) or ffmpeg when installed.
]])
    stream:flush()
end

read_document = function(path)
    local data
    if path == "-" then
        data = io.read("*a")
        if not data then
            return nil, "cannot read standard input"
        end
    elseif IS_WINDOWS then
        local fs, err = filesystem()
        if not fs then
            return nil, err
        end
        data, err = fs.read(path)
        if not data then
            return nil, err
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
        gui = false,
        images = true,
        numbers = nil,
        theme = "dark",
        theme_set = false,
        no_color = false,
        case_sensitive = false,
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
        elseif value == "--gui" then
            options.gui = true
        elseif value == "--color" then
            options.color = true
        elseif value == "--no-color" then
            options.no_color = true
        elseif value == "--case-sensitive" then
            options.case_sensitive = true
        elseif value == "--theme" then
            local following = argv[index + 1]
            if not following then
                return nil, "--theme requires dark or light"
            end
            options.theme = following
            options.theme_set = true
            index = index + 1
        elseif value:match("^%-%-theme=") then
            options.theme = value:sub(#"--theme=" + 1)
            options.theme_set = true
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
    if options.theme ~= "dark" and options.theme ~= "light" then
        return nil, "unknown theme: " .. tostring(options.theme)
    end
    if options.gui and options.snapshot then
        return nil, "--gui cannot be combined with --snapshot"
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

local function snapshot_size(specification)
    local columns, rows = specification:match("^(%d+)x(%d+)$")
    columns = math.max(1, math.min(500, tonumber(columns) or 80))
    rows = math.max(1, math.min(200, tonumber(rows) or 24))
    return columns, rows
end

local function run_snapshot(browser, specification, search, settings)
    local columns, rows = snapshot_size(specification)
    local view = browser.view
    view.case_sensitive = settings and settings.case_sensitive or false
    if search and #search > 0 then
        M.search(view, search, rows)
    end
    M.resize_browser(browser, columns, rows)
    local frame = M.render_browser(browser, columns, rows)
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
    options.file = options.file or "."
    if options.gui then
        return gui.run(options)
    end
    local interactive = options.pager and Terminal.is_tty(1) and Terminal.is_tty(0)
    local is_directory = false
    local fs
    if interactive and options.file ~= "-" then
        io.stderr:write("mdview: inspecting " .. sanitize_text(options.file) .. "\n")
        io.stderr:flush()
    end
    if options.file ~= "-" and (IS_WINDOWS or ffi.os == "Linux") then
        fs = filesystem()
        is_directory = fs.kind(options.file) == "directory"
    end
    if is_directory and not interactive and not options.snapshot then
        io.stderr:write("mdview: directory browsing requires a terminal; use --snapshot 80x24 "
            .. "or provide a Markdown file\n")
        return 1
    end
    local data, read_error
    if is_directory then
        data = "# Markdown browser\n\nSelect a Markdown file in the tree and press Enter.\n\n"
            .. "Tab switches panes. f toggles the tree. Press ? in the tree for help."
    else
        data, read_error = read_document(options.file)
    end
    if not data then
        io.stderr:write("mdview: cannot open '" .. options.file .. "': "
            .. tostring(read_error) .. "\n")
        return 1
    end

    local theme_ok, theme_error = M.set_theme(options.theme)
    if not theme_ok then
        io.stderr:write("mdview: " .. tostring(theme_error) .. "\n")
        return 1
    end
    local color_enabled = options.color
        or (not options.no_color and os.getenv("NO_COLOR") == nil)
    M.set_color(color_enabled)

    local title = is_directory and "Select a Markdown file" or document_title(options.file)
    local width = options.width
    if interactive then
        local columns = Terminal.get_size()
        width = math.max(20, columns - 1)
    end
    if options.snapshot then
        width = snapshot_size(options.snapshot)
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
    local view = M.new_view(title, lines)
    view.document_source = data
    local path = options.file
    if fs then
        path = fs.resolve(path) or path
    end
    local browser = M.new_browser(view, path, is_directory, {
        images = show_images,
        numbers = show_numbers,
        case_sensitive = options.case_sensitive,
    }, fs)
    if browser.pending then
        if interactive then
            io.stderr:write("mdview: loading directory " .. sanitize_text(path) .. "\n")
            io.stderr:flush()
        end
        local columns, rows = width, 24
        if options.snapshot then
            columns, rows = snapshot_size(options.snapshot)
        end
        local ok, err = M.process_browser_pending(browser, columns, rows)
        if not ok then
            io.stderr:write("mdview: " .. err .. "\n")
            return 1
        end
    end

    if options.snapshot then
        run_snapshot(browser, options.snapshot, options.search, options)
        return 0
    end

    if interactive then
        local ok = run_pager(browser, options.search, options)
        if ok then
            return 0
        end
    end

    print_document(title, M.render(data, options.width, render_options), options)
    return 0
end

-- =========================================================================
-- 18. Entry Point
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
M.filesystem = filesystem

local script_name = arg and arg[0] and arg[0]:match("([^/\\]+)$") or ""
if script_name ~= "mdview.lua" then
    return M
end

local ok, result = xpcall(function()
    local arguments = arg or {}
    if IS_WINDOWS then
        local fs = filesystem()
        local decoded, err = fs.arguments(arguments)
        if not decoded then
            error(err, 0)
        end
        arguments = decoded
    end
    return main(arguments)
end, debug.traceback)

Terminal.disable_raw_mode()

if not ok then
    io.stderr:write("mdview: " .. tostring(result) .. "\n")
    io.stderr:flush()
    os.exit(1)
end

os.exit(tonumber(result) or 0)
