#!/usr/bin/env luajit
--[[
    test_mdview.lua — headless test suite for mdview.lua

    Covers the Markdown parser, inline styles, wrapping, tables, lists,
    search highlighting, pager navigation, frame rendering (including
    help/too-small/viewport transitions), CLI behavior and bytecode scoping.
]]

local script_dir = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. package.path
local mdview = require("mdview")
local ffi = require("ffi")
local IS_WINDOWS = (ffi.os == "Windows")
local NULL_DEVICE = IS_WINDOWS and "NUL" or "/dev/null"

local function ensure_directory(path)
    if IS_WINDOWS then
        return os.execute('mkdir "' .. path .. '"')
    end
    return os.execute("mkdir -p '" .. path .. "'")
end

local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end

local function eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error(label or "expected truthy value", 2)
    end
end

local function render_lines(markdown, width)
    return mdview.render(markdown, width or 60)
end

local function render_plain(markdown, width)
    local parts = {}
    for _, line in ipairs(render_lines(markdown, width)) do
        parts[#parts + 1] = line.text
    end
    return table.concat(parts, "\n")
end

local function contains(lines, needle)
    for _, line in ipairs(lines) do
        if line.text:find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function spans_of(spans, text)
    local found = {}
    for _, span in ipairs(spans) do
        if span.text:find(text, 1, true) then
            found[#found + 1] = span
        end
    end
    return found
end

local function assert_widths(lines, width, label)
    for index, line in ipairs(lines) do
        local measured = mdview.display_width(line.text)
        if measured > width then
            error(string.format("%s: line %d is %d columns (limit %d): %s",
                label or "width", index, measured, width, line.text))
        end
    end
end

local function write_ppm(path, width, height, pixel)
    local file = assert(io.open(path, "wb"))
    file:write(string.format("P6\n%d %d\n255\n", width, height))
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local r, g, b = pixel(x, y)
            file:write(string.char(r, g, b))
        end
    end
    file:close()
end

local luajit_bin = "luajit"
if arg and arg[-1] and #arg[-1] > 0 then
    luajit_bin = arg[-1]
end

-- =========================================================================
-- Rendering: headings and paragraphs
-- =========================================================================
test("ATX headings parse levels and strip closing hashes", function()
    local blocks = mdview.parse_blocks("# One\n\n## Two ##\n\n###### Six\n\n####### Seven")
    eq(blocks[1].kind, "heading", "first block kind")
    eq(blocks[1].level, 1, "h1 level")
    eq(blocks[1].text, "One", "h1 text")
    eq(blocks[2].level, 2, "h2 level")
    eq(blocks[2].text, "Two", "closing hashes stripped")
    eq(blocks[3].level, 6, "h6 level")
    eq(blocks[4].kind, "paragraph", "seven hashes is a paragraph")

    local lines = render_lines("# Alpha\n\n## Beta\n\n### Gamma", 50)
    truthy(contains(lines, "Alpha"), "h1 rendered")
    truthy(contains(lines, "━"), "h1 rule rendered")
    truthy(contains(lines, "Beta"), "h2 rendered")
    truthy(contains(lines, "Gamma"), "h3 rendered")
end)

test("setext headings render as levels 1 and 2", function()
    local lines = render_lines("Title\n=====\n\nSubtitle\n--------", 40)
    truthy(contains(lines, "Title"), "setext h1")
    truthy(contains(lines, "Subtitle"), "setext h2")
    local blocks = mdview.parse_blocks("Title\n=====\n\nSubtitle\n--------")
    eq(blocks[1].level, 1, "setext level 1")
    eq(blocks[2].level, 2, "setext level 2")
end)

test("paragraph wrapping respects width and keeps all words", function()
    local markdown = "The quick brown fox jumps over the lazy dog and keeps "
        .. "running through the long green field until it reaches the river bank."
    local lines = render_lines(markdown, 30)
    assert_widths(lines, 30, "paragraph")
    local plain = render_plain(markdown, 30):gsub("%s+", " ")
    truthy(plain:find("The quick brown fox", 1, true), "start preserved")
    truthy(plain:find("river bank.", 1, true), "end preserved")
    truthy(#lines > 1, "wrapped into multiple lines")
end)

test("long words break instead of overflowing", function()
    local lines = render_lines(string.rep("x", 120), 24)
    assert_widths(lines, 24, "long word")
    eq(#lines, 5, "120 chars at 24 columns")
end)

test("wide and combining UTF-8 characters respect cell widths", function()
    local markdown = string.rep("漢字テスト ", 12) .. "\n\n" .. "e\204\129" .. string.rep("界", 40)
    local lines = render_lines(markdown, 32)
    assert_widths(lines, 32, "utf8")
    eq(mdview.display_width("漢字"), 4, "CJK double width")
    eq(mdview.display_width("e\204\129"), 1, "combining mark zero width")
end)

-- =========================================================================
-- Rendering: inline styles, code, lists, quotes, tables, rules
-- =========================================================================
test("inline emphasis, code, strike and links produce styles and hrefs", function()
    local spans = mdview.parse_inline("**bold** *italic* `code` ~~gone~~ [site](https://example.com)")

    local bold = spans_of(spans, "bold")
    eq(#bold, 1, "bold span count")
    truthy(bold[1].style and bold[1].style.bold, "bold flag")

    local italic = spans_of(spans, "italic")
    truthy(italic[1].style and italic[1].style.italic, "italic flag")

    local code = spans_of(spans, "code")
    truthy(code[1].style and code[1].style.code, "code flag")

    local strike = spans_of(spans, "gone")
    truthy(strike[1].style and strike[1].style.strike, "strike flag")

    local link = spans_of(spans, "site")
    truthy(link[1].style and link[1].style.underline, "link underline")
    eq(link[1].style.href, "https://example.com", "link href")
end)

test("nested emphasis keeps parent and child styles", function()
    local spans = mdview.parse_inline("**bold with *italic* inside**")
    local inner = spans_of(spans, "italic")
    truthy(inner[1].style and inner[1].style.bold and inner[1].style.italic,
        "nested bold+italic")
end)

test("unmatched emphasis and code markers stay literal", function()
    eq(mdview.parse_inline("*not closed")[1].text, "*not closed", "literal asterisk")
    eq(mdview.parse_inline("`open")[1].text, "`open", "literal backtick")
    eq(mdview.parse_inline("a \\* b")[1].text, "a * b", "backslash escape")
end)

test("fenced code blocks preserve whitespace and language", function()
    local markdown = "```lua\nlocal x = 1\n    indented()\n```\n"
    local blocks = mdview.parse_blocks(markdown)
    eq(blocks[1].kind, "code", "code block kind")
    eq(blocks[1].lang, "lua", "code language")
    eq(blocks[1].lines[1], "local x = 1", "first code line")
    eq(blocks[1].lines[2], "    indented()", "indentation preserved")

    local lines = render_lines(markdown, 40)
    truthy(contains(lines, "local x = 1"), "code rendered")
    truthy(contains(lines, "    indented()"), "code indentation rendered")
end)

test("unterminated fence consumes the rest of the document", function()
    local blocks = mdview.parse_blocks("```text\none\ntwo\n")
    eq(#blocks, 1, "single block")
    eq(#blocks[1].lines, 2, "remaining lines captured")
end)

test("YAML front matter renders as code, not a rule", function()
    local blocks = mdview.parse_blocks("---\ntitle: Demo\n---\n\n# Body\n")
    eq(blocks[1].kind, "code", "front matter kind")
    eq(blocks[1].lines[1], "title: Demo", "front matter line")
    eq(blocks[2].kind, "heading", "body heading follows")
end)

test("unordered, ordered and nested lists render markers", function()
    local markdown = "- one\n- two\n  - nested\n1. first\n2. second\n"
    local lines = render_lines(markdown, 40)
    truthy(contains(lines, "• one"), "bullet one")
    truthy(contains(lines, "• nested"), "nested bullet")
    truthy(contains(lines, "1. first"), "ordered first")
    truthy(contains(lines, "2. second"), "ordered second")
end)

test("task list items use checkbox glyphs", function()
    local lines = render_lines("- [ ] todo\n- [x] done", 40)
    truthy(contains(lines, "☐ todo"), "unchecked box")
    truthy(contains(lines, "☑ done"), "checked box")
end)

test("blockquotes prefix every line and nest recursively", function()
    local markdown = "> quoted text\n>\n> > nested quote\n"
    local lines = render_lines(markdown, 40)
    for _, line in ipairs(lines) do
        truthy(line.text:sub(1, 3) == "│", "quote bar missing: " .. line.text)
    end
    truthy(contains(lines, "nested quote"), "nested quote text")
end)

test("tables render borders, header separator and alignment", function()
    local markdown = "| Item | Qty |\n| :--- | ---: |\n| apple | 3 |\n| pear | 12 |\n"
    local lines = render_lines(markdown, 40)
    truthy(contains(lines, "┌"), "top border")
    truthy(contains(lines, "├"), "header separator")
    truthy(contains(lines, "└"), "bottom border")
    truthy(contains(lines, "Item"), "header cell")

    local apple
    for _, line in ipairs(lines) do
        if line.text:find("apple", 1, true) then
            apple = line.text
        end
    end
    truthy(apple, "apple row present")
    truthy(apple:find("3 │$") ~= nil, "right aligned quantity: " .. tostring(apple))
end)

test("wide table cells truncate to the requested width", function()
    local markdown = "| Key | Value |\n| --- | --- |\n| a | "
        .. string.rep("long value ", 10) .. "|\n"
    local lines = render_lines(markdown, 30)
    assert_widths(lines, 30, "table truncation")
    truthy(contains(lines, "…"), "ellipsis on truncated cell")
end)

test("horizontal rules and empty documents are safe", function()
    local lines = render_lines("before\n\n---\n\nafter", 20)
    truthy(contains(lines, string.rep("─", 20)), "full-width rule")
    eq(#render_lines("", 40), 0, "empty document has no lines")
    eq(#render_lines("   \n\n\t\n", 40), 0, "whitespace-only document has no lines")
end)

-- =========================================================================
-- Search and highlighting
-- =========================================================================
test("search is case-insensitive and counts every occurrence", function()
    local lines = render_lines("Alpha beta\n\nalpha BETA\n\ngamma", 40)
    local matches = mdview.find_matches(lines, "alpha")
    eq(#matches, 2, "two matches")
    eq(matches[1].line, 1, "first line")
    eq(matches[2].line, 3, "second line")
    eq(#mdview.find_matches(lines, "ALPHA"), 2, "upper-case query")
    eq(#mdview.find_matches(lines, "missing"), 0, "no matches")
end)

test("highlighting splits spans and marks only matched bytes", function()
    local line = render_lines("prefix target suffix", 40)[1]
    local ranges = mdview.find_matches({ line }, "target")
    local spans = mdview.highlight_spans(line.spans, ranges)
    local highlighted, plain = "", ""
    for _, span in ipairs(spans) do
        if span.style and span.style.search then
            highlighted = highlighted .. span.text
        else
            plain = plain .. span.text
        end
    end
    eq(highlighted, "target", "highlighted text")
    eq(plain, "prefix  suffix", "remaining text")
end)

test("search state builds a match map and jumps to the first hit", function()
    local lines = mdview.render(string.rep("line\n\n", 60) .. "needle here\n", 40)
    local view = mdview.new_view("test", lines)
    local count = mdview.search(view, "needle", 12)
    eq(count, 1, "match count")
    eq(view.search.index, 1, "current match index")
    truthy(view.match_map[#lines] ~= nil, "match map entry")
    truthy(view.top > 1, "viewport moved to match")
    truthy(view.message:find("match 1/1", 1, true) ~= nil, "status message")
end)

test("no-match search reports a warning and leaves the viewport alone", function()
    local view = mdview.new_view("test", render_lines(string.rep("alpha\n\n", 40), 30))
    view.top = 5
    local count = mdview.search(view, "zzz", 10)
    eq(count, 0, "no matches")
    eq(view.top, 5, "viewport unchanged")
    eq(view.message_kind, "warn", "warning kind")
    truthy(view.message:find("pattern not found", 1, true) ~= nil, "warning text")
end)

-- =========================================================================
-- Pager navigation and key handling
-- =========================================================================
test("navigation clamps at first and last page", function()
    local lines = render_lines(string.rep("row\n\n", 100), 40)
    local view = mdview.new_view("nav", lines)
    eq(view.top, 1, "initial top")

    mdview.handle_key(view, "k", 10)
    eq(view.top, 1, "cannot scroll above first line")

    mdview.handle_key(view, "j", 10)
    eq(view.top, 2, "j scrolls one line")

    mdview.handle_key(view, "G", 10)
    eq(view.top, #lines - 8 + 1, "G jumps to last page")

    mdview.handle_key(view, "j", 10)
    eq(view.top, #lines - 8 + 1, "cannot scroll past last page")

    mdview.handle_key(view, "g", 10)
    eq(view.top, 1, "g jumps home")
end)

test("paging and half-page keys move by viewport size", function()
    local lines = render_lines(string.rep("row\n\n", 100), 40)
    local view = mdview.new_view("page", lines)

    mdview.handle_key(view, "SPACE", 12)
    eq(view.top, 11, "space pages down by content rows")

    mdview.handle_key(view, "b", 12)
    eq(view.top, 1, "b pages back")

    mdview.handle_key(view, "d", 12)
    eq(view.top, 6, "d half page down")

    mdview.handle_key(view, "u", 12)
    eq(view.top, 1, "u half page up")

    mdview.handle_key(view, "PAGE_DOWN", 12)
    eq(view.top, 6, "PgDn half page")
end)

test("vim control and boundary keys scroll like a pager", function()
    local lines = render_lines(string.rep("row\n\n", 100), 40)
    local view = mdview.new_view("vim", lines)

    mdview.handle_key(view, "CTRL_D", 12)
    eq(view.top, 6, "Ctrl-d half page down")
    mdview.handle_key(view, "CTRL_U", 12)
    eq(view.top, 1, "Ctrl-u half page up")

    mdview.handle_key(view, "CTRL_F", 12)
    eq(view.top, 11, "Ctrl-f full page down")
    mdview.handle_key(view, "CTRL_B", 12)
    eq(view.top, 1, "Ctrl-b full page up")

    mdview.handle_key(view, "CTRL_E", 12)
    eq(view.top, 2, "Ctrl-e one line down")
    mdview.handle_key(view, "CTRL_Y", 12)
    eq(view.top, 1, "Ctrl-y one line up")

    mdview.handle_key(view, "$", 12)
    eq(view.top, #lines - 10 + 1, "$ jumps to the bottom page")
    mdview.handle_key(view, "0", 12)
    eq(view.top, 1, "0 jumps to the top")
    mdview.handle_key(view, "$", 12)
    mdview.handle_key(view, "^", 12)
    eq(view.top, 1, "^ jumps to the top")
end)

test("search prompt is incremental, handles tokens, and cancels cleanly", function()
    local lines = render_lines("needle one\n\nneedle two\n", 40)
    local view = mdview.new_view("prompt", lines)

    mdview.handle_key(view, "/", 10)
    eq(view.mode, "search", "search mode")
    eq(view.prompt, "", "prompt starts empty")

    mdview.handle_key(view, "n", 10)
    mdview.handle_key(view, "e", 10)
    mdview.handle_key(view, "SPACE", 10)
    eq(view.prompt, "ne ", "space token appended")

    mdview.handle_key(view, "BACKSPACE", 10)
    mdview.handle_key(view, "BACKSPACE", 10)
    mdview.handle_key(view, "BACKSPACE", 10)
    eq(view.prompt, "", "backspace clears the prompt")
    eq(#view.search.matches, 0, "empty prompt clears matches")

    for _, key in ipairs({ "n", "e", "e", "d", "l", "e" }) do
        mdview.handle_key(view, key, 10)
    end
    eq(view.prompt, "needle", "typed query")
    eq(#view.search.matches, 2, "matches update while typing")
    truthy(view.message:find("match", 1, true) ~= nil, "incremental jump message")

    mdview.handle_key(view, "ESC", 10)
    eq(view.mode, "normal", "escape leaves search")
    eq(view.prompt, "", "escape clears the pending prompt")
    eq(#view.search.matches, 0, "escape restores the previous search")

    mdview.handle_key(view, "/", 10)
    for _, key in ipairs({ "n", "e", "e", "d", "l", "e" }) do
        mdview.handle_key(view, key, 10)
    end
    mdview.handle_key(view, "ENTER", 10)
    eq(view.mode, "normal", "enter leaves search mode")
    eq(#view.search.matches, 2, "enter keeps the search")
    eq(view.search.direction, 1, "forward direction")

    mdview.handle_key(view, "n", 10)
    eq(view.search.index, 2, "n advances to next match")
    mdview.handle_key(view, "n", 10)
    eq(view.search.index, 1, "n wraps around")
    mdview.handle_key(view, "N", 10)
    eq(view.search.index, 2, "N wraps backwards")
end)

test("backward search starts above the viewport and n/N follow its direction", function()
    local markdown = "needle first\n\n" .. string.rep("filler\n\n", 20) .. "needle second\n"
    local lines = render_lines(markdown, 60)
    local second
    for index, line in ipairs(lines) do
        if line.text:find("needle second", 1, true) then
            second = index
        end
    end
    truthy(second, "second match line found")

    local view = mdview.new_view("back", lines)
    view.top = second
    mdview.handle_key(view, "?", 10)
    for _, key in ipairs({ "n", "e", "e", "d", "l", "e" }) do
        mdview.handle_key(view, key, 10)
    end
    eq(view.search.direction, -1, "backward direction")
    mdview.handle_key(view, "ENTER", 10)
    eq(view.search.index, 1, "selected the match above the viewport")
    truthy(view.top < second, "viewport moved backwards")

    mdview.handle_key(view, "n", 10)
    eq(view.search.index, 2, "n continues backwards and wraps")
    mdview.handle_key(view, "N", 10)
    eq(view.search.index, 1, "N moves the other way")
end)

test("help mode round trip restores the previous viewport", function()
    local lines = render_lines(string.rep("payload\n\n", 80), 40)
    local view = mdview.new_view("help", lines)
    view.top = 21
    mdview.handle_key(view, "h", 12)
    eq(view.mode, "help", "help opened")
    mdview.handle_key(view, "j", 12)
    eq(view.mode, "help", "navigation keys are ignored in help")
    mdview.handle_key(view, "h", 12)
    eq(view.mode, "normal", "help closed")
    eq(view.top, 21, "viewport preserved")
end)

-- =========================================================================
-- Source line numbers
-- =========================================================================
test("line numbers track source lines and leave wrapped rows blank", function()
    local markdown = table.concat({
        "# Head",
        "",
        "First paragraph that wraps onto another line here.",
        "",
        "```lua",
        "local x = 1",
        "local y = 2",
        "```",
        "",
        "| A | B |",
        "| --- | --- |",
        "| 1 | 2 |",
    }, "\n") .. "\n"
    local lines = mdview.render(markdown, 32, { numbers = true })
    eq(lines.gutter_width, 3, "gutter width for twelve source lines")

    local numbered = {}
    for _, line in ipairs(lines) do
        if line.number then
            numbered[line.number] = line
        end
    end
    truthy(numbered[1], "heading numbered")
    truthy(numbered[1].text:find("Head", 1, true), "heading text")
    truthy(numbered[3], "paragraph numbered")
    truthy(numbered[3].text:find("First", 1, true), "paragraph text")
    truthy(numbered[6] and numbered[6].text:find("local x", 1, true), "first code line")
    truthy(numbered[7] and numbered[7].text:find("local y", 1, true), "second code line")
    truthy(numbered[10], "table header numbered")
    truthy(numbered[12], "table row numbered")

    local paragraph_index
    for position, line in ipairs(lines) do
        if line == numbered[3] then
            paragraph_index = position
        end
    end
    eq(lines[paragraph_index + 1].number, nil, "wrapped continuation has no number")
end)

test("footnote references become numbered links and append notes", function()
    local lines = render_lines("Text[^a] and again[^a].\n\n[^a]: Note **body**.\n", 60)
    local paragraph
    for _, line in ipairs(lines) do
        if line.text:find("Text", 1, true) then
            paragraph = line
        end
    end
    truthy(paragraph, "paragraph rendered")
    truthy(paragraph.text:find("[1] and again[1]", 1, true), "both refs share a number")

    local marker
    for _, span in ipairs(paragraph.spans) do
        if span.text == "[1]" then
            marker = span
        end
    end
    truthy(marker, "marker span present")
    eq(marker.style.href, "#fn-a", "marker href")
    truthy(contains(lines, "Notes"), "notes heading appended")
    truthy(contains(lines, "[1] Note body."), "note body rendered")

    local note
    for _, line in ipairs(lines) do
        if line.text:find("[1] Note", 1, true) then
            note = line
        end
    end
    eq(note.number, 3, "note keeps its source line")
    truthy(not contains(lines, "[^a]:"), "definition line not rendered in place")
end)

test("footnotes number by first reference and append in order", function()
    local lines = render_lines("B[^b] A[^a].\n\n[^a]: Note A.\n[^b]: Note B.\n", 60)
    truthy(lines[1].text:find("B[1] A[2]", 1, true), "reference order numbering")

    local notes = {}
    for _, line in ipairs(lines) do
        local number, text = line.text:match("^%[(%d+)%] (.*)$")
        if number then
            notes[#notes + 1] = { number = tonumber(number), text = text }
        end
    end
    eq(#notes, 2, "two notes")
    eq(notes[1].number, 1, "first note number")
    eq(notes[1].text, "Note B.", "first note is the first referenced")
    eq(notes[2].text, "Note A.", "second note follows")
end)

test("reference links resolve and definitions stay hidden", function()
    local lines = render_lines("See [the docs][docs] and [docs][].\n\n"
        .. "[docs]: https://example.com/docs\n", 60)
    local links = {}
    for _, span in ipairs(lines[1].spans) do
        if span.style and span.style.href then
            links[#links + 1] = span
        end
    end
    eq(#links, 2, "both reference links resolved")
    eq(links[1].style.href, "https://example.com/docs", "full reference href")
    eq(links[2].style.href, "https://example.com/docs", "collapsed reference href")
    truthy(not contains(lines, "[docs]:"), "definition line hidden")
end)

test("undefined footnotes and reference links stay literal", function()
    local lines = render_lines("Undefined[^missing] and [text][nope].\n", 60)
    truthy(contains(lines, "[^missing]"), "undefined footnote literal")
    truthy(contains(lines, "[text][nope]"), "undefined reference literal")
end)

test("code spans and code fences do not define or resolve notes", function()
    local markdown = "Use `[^a]` literally, but real[^a].\n\n```text\n[docs]: https://example.com\n```\n\n"
        .. "[^a]: Note.\n"
    local lines = render_lines(markdown, 60)
    local literal
    for _, span in ipairs(lines[1].spans) do
        if span.style and span.style.code and span.text == "[^a]" then
            literal = true
        end
    end
    truthy(literal, "footnote syntax inside a code span stays literal")
    truthy(contains(lines, "[docs]: https://example.com"), "fenced definition stays code")
    truthy(contains(lines, "Notes"), "real note still appended")
end)

test("themes switch the palette colors", function()
    local function ansi_for(theme)
        mdview.set_theme(theme)
        local parts = {}
        for _, line in ipairs(mdview.render("# Heading\n\n`code`\n", 40)) do
            parts[#parts + 1] = mdview.spans_to_ansi(line.spans, 40, false)
        end
        return table.concat(parts, "\n")
    end

    local dark = ansi_for("dark")
    local light = ansi_for("light")
    truthy(dark ~= light, "palettes produce different output")
    truthy(dark:find("38;2;130;170;255", 1, true), "dark heading color")
    truthy(light:find("38;2;24;74;158", 1, true), "light heading color")
    truthy(mdview.set_theme("dark"), "dark theme restored")
    local ok = mdview.set_theme("neon")
    eq(ok, false, "unknown theme rejected")
end)

test("NO_COLOR mode drops ANSI and OSC sequences but keeps layout", function()
    mdview.set_color(false)
    local lines = mdview.render("**bold** [link](https://example.com)\n", 40)
    local view = mdview.new_view("plain.md", lines)
    local frame = mdview.render_frame(view, 40, 8)
    for row = 1, 8 do
        truthy(frame.rows[row]:find("\27", 1, true) == nil, "no escapes in row " .. row)
        eq(mdview.display_width(frame.plain[row]), 40, "row width " .. row)
    end
    mdview.set_color(true)
    truthy(mdview.color_enabled(), "color restored")
end)

test("search ignores the line-number gutter", function()
    local markdown = "alpha\n\n" .. string.rep("beta\n\n", 15) .. "alpha\n"
    local lines = mdview.render(markdown, 40, { numbers = true })
    local view = mdview.new_view("numbers.md", lines)
    eq(mdview.search(view, "1", 10), 0, "gutter digits are not searchable")
    eq(mdview.search(view, "beta", 10), 15, "content search still works")
end)

-- =========================================================================
-- Frame rendering
-- =========================================================================
test("frame fills every row to the terminal width", function()
    local lines = render_lines(string.rep("A paragraph of text.\n\n", 40), 60)
    local view = mdview.new_view("frame.md", lines)
    for _, size in ipairs({ { 80, 24 }, { 24, 4 }, { 120, 40 }, { 25, 5 } }) do
        local frame = mdview.render_frame(view, size[1], size[2])
        eq(#frame.rows, size[2], "row count")
        for row = 1, size[2] do
            eq(mdview.display_width(frame.plain[row]), size[1],
                string.format("row %d width at %dx%d", row, size[1], size[2]))
        end
    end
end)

test("frame renders the line-number gutter and help stays unnumbered", function()
    local lines = mdview.render("# Head\n\nBody text\n", 40, { numbers = true })
    local view = mdview.new_view("numbers.md", lines)
    local frame = mdview.render_frame(view, 40, 10)
    truthy(frame.plain[2]:match("^%s*1 Head") ~= nil, "heading row: " .. frame.plain[2])
    local paragraph_row
    for row = 2, 9 do
        if frame.plain[row]:find("Body text", 1, true) then
            paragraph_row = row
        end
    end
    truthy(paragraph_row, "paragraph row rendered")
    truthy(frame.plain[paragraph_row]:match("^%s*3 Body") ~= nil,
        "paragraph row: " .. frame.plain[paragraph_row])
    eq(mdview.display_width(frame.plain[2]), 40, "gutter row width")

    mdview.handle_key(view, "h", 10)
    local help = mdview.render_frame(view, 40, 10)
    truthy(help.plain[2]:match("^mdview keys") ~= nil, "help ignores the gutter")
end)

test("frame header, status bar and content are present", function()
    local lines = render_lines("# Title\n\nBody text\n", 60)
    local view = mdview.new_view("doc.md", lines)
    local frame = mdview.render_frame(view, 70, 12)
    truthy(frame.plain[1]:find("mdview", 1, true), "header title")
    truthy(frame.plain[1]:find("doc.md", 1, true), "file name")
    truthy(frame.plain[1]:find("1/" .. #lines, 1, true), "line position")
    truthy(frame.plain[2]:find("Title", 1, true), "first content row")
    truthy(frame.plain[12]:find("q quit", 1, true), "status keys")
end)

test("frame handles empty documents and tiny terminals", function()
    local view = mdview.new_view("empty.md", {})
    local frame = mdview.render_frame(view, 40, 10)
    eq(#frame.rows, 10, "empty frame rows")
    for row = 1, 10 do
        eq(mdview.display_width(frame.plain[row]), 40, "padded empty row")
    end

    local tiny = mdview.render_frame(view, 20, 3)
    truthy(tiny.plain[1]:find("too small", 1, true), "too-small warning")
    eq(#tiny.rows, 3, "tiny frame rows")
    eq(mdview.display_width(tiny.plain[1]), 20, "tiny frame width")
end)

test("help overlay renders the key table and closes cleanly", function()
    local view = mdview.new_view("help.md", render_lines("# Doc\n\n" .. string.rep("text\n\n", 30), 40))
    mdview.handle_key(view, "h", 24)
    local frame = mdview.render_frame(view, 80, 24)
    truthy(frame.plain[2]:find("mdview keys", 1, true), "help heading")
    truthy(frame.plain[24]:find("close", 1, true), "help status")

    mdview.handle_key(view, "ESC", 24)
    local restored = mdview.render_frame(view, 80, 24)
    truthy(restored.plain[2]:find("Doc", 1, true), "document restored")
end)

test("search highlights appear in rendered frames", function()
    local lines = render_lines("alpha beta\n\nalpha gamma\n", 40)
    local view = mdview.new_view("search.md", lines)
    mdview.search(view, "alpha", 10)
    local frame = mdview.render_frame(view, 60, 10)
    truthy(frame.rows[2]:find("255;150;60", 1, true) ~= nil, "current match colour")
    truthy(frame.rows[4]:find("43m", 1, true) ~= nil, "other match colour")
    truthy(frame.plain[10]:find("match 1/2", 1, true), "match status")
end)

test("current match is highlighted separately from other matches", function()
    local lines = render_lines("alpha beta\n\nalpha gamma\n", 40)
    local view = mdview.new_view("match.md", lines)
    mdview.search(view, "alpha", 10)
    local current, other = false, false
    for _, span in ipairs(mdview.highlight_spans(lines[1].spans, view.match_map[1],
        view.search.index)) do
        if span.style and span.style.search_current then
            current = true
        end
        if span.style and span.style.search then
            other = true
        end
    end
    truthy(current, "current match style")
    truthy(not other, "first line only carries the current style")

    local second = false
    for _, span in ipairs(mdview.highlight_spans(lines[3].spans, view.match_map[3],
        view.search.index)) do
        if span.style and span.style.search then
            second = true
        end
    end
    truthy(second, "other matches keep the standard style")
end)

test("case-sensitive search can be toggled at runtime", function()
    local lines = render_lines("Alpha alpha\n", 40)
    eq(#mdview.find_matches(lines, "alpha"), 2, "case-insensitive by default")
    eq(#mdview.find_matches(lines, "alpha", true), 1, "case-sensitive match count")

    local view = mdview.new_view("case.md", lines)
    mdview.search(view, "alpha", 10)
    eq(#view.search.matches, 2, "view search is insensitive")
    mdview.handle_key(view, "C", 10)
    truthy(view.case_sensitive, "toggle enables case sensitivity")
    eq(#view.search.matches, 1, "search re-runs when toggled")
    truthy(view.message:find("case-sensitive", 1, true), "toggle status message")
    mdview.handle_key(view, "C", 10)
    eq(#view.search.matches, 2, "toggle disables case sensitivity")
end)

test("status bar keeps the query and match count visible", function()
    local lines = render_lines("alpha beta\n\nalpha gamma\n", 40)
    local view = mdview.new_view("status.md", lines)
    mdview.search(view, "alpha", 10)
    view.message = ""
    local frame = mdview.render_frame(view, 80, 10)
    truthy(frame.plain[10]:find("/alpha", 1, true), "query visible")
    truthy(frame.plain[10]:find("1/2", 1, true), "match count visible")

    view.case_sensitive = true
    local sensitive = mdview.render_frame(view, 80, 10)
    truthy(sensitive.plain[10]:find("Aa", 1, true), "case marker visible")
end)

test("search prompt renders the typed query with a cursor", function()
    local view = mdview.new_view("prompt.md", render_lines("alpha\n", 40))
    mdview.handle_key(view, "/", 10)
    mdview.handle_key(view, "a", 10)
    mdview.handle_key(view, "SPACE", 10)
    mdview.handle_key(view, "b", 10)
    local frame = mdview.render_frame(view, 60, 10)
    truthy(frame.plain[10]:find("/a b", 1, true), "prompt text")
    truthy(frame.plain[10]:find("▏", 1, true), "prompt cursor")

    mdview.handle_key(view, "ESC", 10)
    mdview.handle_key(view, "?", 10)
    mdview.handle_key(view, "a", 10)
    local backward = mdview.render_frame(view, 60, 10)
    truthy(backward.plain[10]:find("?a", 1, true), "backward prompt marker")
end)

test("viewport transitions leave no stale content behind", function()
    local long_lines = render_lines(string.rep("XXXXXXX\n\n", 50), 40)
    local view = mdview.new_view("transition.md", long_lines)
    local frame = mdview.render_frame(view, 40, 10)
    truthy(frame.plain[2]:find("XXXXXXX", 1, true), "content before")

    view.lines = render_lines("short", 40)
    mdview.clamp_view(view, 10)
    local short_frame = mdview.render_frame(view, 40, 10)
    truthy(short_frame.plain[2]:find("short", 1, true), "new content")
    for row = 3, 9 do
        eq(short_frame.plain[row]:match("^%s*$") ~= nil, true, "row " .. row .. " cleared")
    end
end)

-- =========================================================================
-- Inline images
-- =========================================================================
test("standalone image syntax parses alt text and source", function()
    local blocks = mdview.parse_blocks('![Chart](pics/chart.png "A title")\n\nAfter')
    eq(blocks[1].kind, "image", "image block kind")
    eq(blocks[1].alt, "Chart", "alt text")
    eq(blocks[1].src, "pics/chart.png", "title stripped from source")
    eq(blocks[2].kind, "paragraph", "following paragraph preserved")
end)

test("image blocks render half-block art from native PPM", function()
    local path = os.tmpname() .. ".ppm"
    write_ppm(path, 4, 4, function(x)
        if x < 2 then
            return 255, 0, 0
        end
        return 0, 0, 255
    end)
    local lines = mdview.render("![swatch](" .. path .. ")", 40)
    local art = {}
    for _, line in ipairs(lines) do
        if line.text:find("▀", 1, true) then
            art[#art + 1] = line
        end
    end
    eq(#art, 2, "4x4 image occupies two cell rows")
    eq(#art[1].spans, 2, "equal colours merge into two runs")
    eq(art[1].spans[1].style.fg, "38;2;255;0;0", "red foreground")
    eq(art[1].spans[1].style.bg, "48;2;255;0;0", "red background")
    eq(art[1].spans[2].style.fg, "38;2;0;0;255", "blue foreground")
    truthy(contains(lines, "swatch"), "alt caption rendered")
    os.remove(path)
end)

test("relative image paths resolve against the document directory", function()
    local directory = os.tmpname()
    os.remove(directory)
    eq(ensure_directory(directory), 0, "temp directory")
    local path = directory .. "/dot.ppm"
    write_ppm(path, 2, 2, function()
        return 0, 255, 0
    end)
    local lines = mdview.render("![dot](dot.ppm)", 30, { base_dir = directory })
    local art = 0
    for _, line in ipairs(lines) do
        if line.text:find("▀", 1, true) then
            art = art + 1
        end
    end
    eq(art, 1, "2x2 image is one cell row")
    os.remove(path)
    os.remove(directory)
end)

test("missing, remote and disabled images show visible placeholders", function()
    local missing = mdview.render("![chart](no-such-image.png)", 40)
    truthy(contains(missing, "[image] chart"), "alt in placeholder")
    truthy(contains(missing, "no-such-image.png"), "path in placeholder")
    truthy(contains(missing, "cannot open image"), "failure reason shown")

    local remote = mdview.render("![diagram](https://example.com/x.png)", 40)
    truthy(contains(remote, "remote image not loaded"), "remote fallback")
    truthy(contains(remote, "diagram"), "remote alt text")

    local disabled = mdview.render("![chart](x.png)", 40, { images = false })
    truthy(contains(disabled, "disabled"), "disabled fallback")
end)

test("wide images are capped and fit the requested width", function()
    local path = os.tmpname() .. ".ppm"
    write_ppm(path, 100, 10, function()
        return 200, 200, 200
    end)
    local lines = mdview.render("![wide](" .. path .. ")", 24)
    local art = 0
    for _, line in ipairs(lines) do
        if line.text:find("▀", 1, true) then
            art = art + 1
            truthy(mdview.display_width(line.text) <= 24, "image row width")
        end
    end
    truthy(art >= 1, "image rendered")
    os.remove(path)
end)

test("PNG images decode through ImageMagick or ffmpeg", function()
    local ppm = os.tmpname() .. ".ppm"
    local png = os.tmpname() .. ".png"
    write_ppm(ppm, 4, 4, function()
        return 255, 128, 0
    end)
    local converted = os.execute("convert '" .. ppm .. "' '" .. png
        .. "' > " .. NULL_DEVICE .. " 2>&1")
    if converted ~= 0 then
        os.remove(ppm)
        print("  (skipped PNG decode: no ImageMagick 'convert')")
        return
    end

    local lines = mdview.render("![orange](" .. png .. ")", 40)
    local art = 0
    for _, line in ipairs(lines) do
        if line.text:find("▀", 1, true) then
            art = art + 1
        end
    end
    eq(art, 2, "decoded PNG cell rows")
    truthy(contains(lines, "orange"), "PNG caption")
    os.remove(ppm)
    os.remove(png)
end)

-- =========================================================================
-- CLI behavior
-- =========================================================================
test("CLI renders plain output without escape codes", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("# Heading\n\nSome **bold** text and a [link](https://example.com).\n")
    file:close()

    local output_path = os.tmpname()
    local status = os.execute(string.format(
        "%s mdview.lua --no-pager --width 40 %s > %s 2>&1",
        luajit_bin, path, output_path))
    local file_out = assert(io.open(output_path, "rb"))
    local output = file_out:read("*a")
    file_out:close()
    os.remove(output_path)
    os.remove(path)

    eq(status, 0, "exit status")
    truthy(output:find("Heading", 1, true), "heading in output")
    truthy(output:find("Some bold text", 1, true), "inline text preserved")
    truthy(output:find("\27[", 1, true) == nil, "no ANSI escapes when piped")
    for line in (output .. "\n"):gmatch("([^\n]*)\n") do
        truthy(mdview.display_width(line) <= 40, "plain output width: " .. line)
    end
end)

test("CLI snapshot prints exactly the requested number of rows", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("# Snapshot\n\nhello\n")
    file:close()

    local command = string.format("%s mdview.lua --snapshot 60x12 %s 2>&1", luajit_bin, path)
    local handle = assert(io.popen(command))
    local output = handle:read("*a")
    local status = handle:close()
    os.remove(path)

    truthy(status == 0 or status == true, "snapshot exit status")
    local rows = 0
    for line in (output:gsub("\n$", "") .. "\n"):gmatch("([^\n]*)\n") do
        rows = rows + 1
        eq(mdview.display_width(mdview.strip_ansi(line)), 60,
            "snapshot row " .. rows .. " width")
    end
    eq(rows, 12, "snapshot row count")
    truthy(output:find("Snapshot", 1, true), "snapshot content")
end)

test("CLI search option highlights and reports matches in snapshots", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("# Doc\n\nalpha beta\n\nalpha gamma\n")
    file:close()

    local command = string.format(
        "%s mdview.lua --color --snapshot 70x10 --search alpha %s 2>&1", luajit_bin, path)
    local handle = assert(io.popen(command))
    local output = handle:read("*a")
    handle:close()
    os.remove(path)

    truthy(output:find("match 1/2", 1, true), "match status line")
    truthy(output:find("43m", 1, true), "highlight escape in output")
end)

test("CLI honors --no-color, --theme and NO_COLOR", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("# Heading\n\nBody\n")
    file:close()

    local function run(command)
        local handle = assert(io.popen(command .. " 2>&1", "r"))
        local output = handle:read("*a")
        handle:close()
        return output
    end

    local plain = run(string.format(
        "%s mdview.lua --snapshot 50x8 --no-color %s", luajit_bin, path))
    truthy(plain:find("\27", 1, true) == nil, "--no-color removes escapes")

    local light = run(string.format(
        "%s mdview.lua --color --snapshot 50x8 --theme light %s", luajit_bin, path))
    truthy(light:find("38;2;24;74;158", 1, true), "light theme heading color")

    local env_prefix = IS_WINDOWS and "set NO_COLOR=1&& " or "NO_COLOR=1 "
    local env_plain = run(env_prefix .. string.format(
        "%s mdview.lua --snapshot 50x8 %s", luajit_bin, path))
    truthy(env_plain:find("\27", 1, true) == nil, "NO_COLOR is honored")

    local forced = run(env_prefix .. string.format(
        "%s mdview.lua --snapshot 50x8 --color %s", luajit_bin, path))
    truthy(forced:find("\27", 1, true) ~= nil, "--color overrides NO_COLOR")

    os.remove(path)
end)

test("CLI --case-sensitive narrows snapshot matches", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("# Case\n\nAlpha alpha\n")
    file:close()

    local function run(extra)
        local handle = assert(io.popen(string.format(
            "%s mdview.lua --snapshot 70x10 --search alpha %s %s 2>&1",
            luajit_bin, extra, path), "r"))
        local output = handle:read("*a")
        handle:close()
        return mdview.strip_ansi(output)
    end

    truthy(string.find(run(""), "match 1/2", 1, true), "insensitive finds both")
    truthy(string.find(run("--case-sensitive"), "match 1/1", 1, true),
        "case-sensitive finds one")
    os.remove(path)
end)

test("CLI can disable inline images", function()
    local directory = os.tmpname()
    os.remove(directory)
    eq(ensure_directory(directory), 0, "temp directory")
    write_ppm(directory .. "/dot.ppm", 2, 2, function()
        return 255, 0, 0
    end)
    local file = assert(io.open(directory .. "/doc.md", "wb"))
    file:write("![dot](dot.ppm)\n")
    file:close()

    local handle = assert(io.popen(string.format(
        "%s mdview.lua --snapshot 60x10 --no-images %s/doc.md 2>&1",
        luajit_bin, directory)))
    local output = handle:read("*a")
    handle:close()
    os.remove(directory .. "/dot.ppm")
    os.remove(directory .. "/doc.md")
    os.remove(directory)

    truthy(output:find("[image] dot", 1, true), "placeholder shown")
    truthy(output:find("disabled", 1, true), "disabled reason shown")
end)

test("CLI snapshot renders images relative to the document", function()
    local directory = os.tmpname()
    os.remove(directory)
    eq(ensure_directory(directory), 0, "temp directory")
    write_ppm(directory .. "/dot.ppm", 2, 2, function()
        return 255, 0, 0
    end)
    local file = assert(io.open(directory .. "/doc.md", "wb"))
    file:write("![dot](dot.ppm)\n")
    file:close()

    local handle = assert(io.popen(string.format(
        "%s mdview.lua --snapshot 60x10 %s/doc.md 2>&1", luajit_bin, directory)))
    local output = handle:read("*a")
    handle:close()
    os.remove(directory .. "/dot.ppm")
    os.remove(directory .. "/doc.md")
    os.remove(directory)

    truthy(output:find("▀", 1, true), "half-block art in snapshot")
    truthy(output:find("dot", 1, true), "caption in snapshot")
end)

test("CLI numbers flag adds and removes the gutter", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("# Heading\n\nbody\n")
    file:close()

    local function run(command)
        local handle = assert(io.popen(command, "r"))
        local output = handle:read("*a")
        handle:close()
        return mdview.strip_ansi(output)
    end

    local snapshot = run(string.format(
        "%s mdview.lua --snapshot 60x10 %s 2>&1", luajit_bin, path))
    truthy(snapshot:find("1 Heading", 1, true), "pager numbers on by default")

    local bare = run(string.format(
        "%s mdview.lua --snapshot 60x10 --no-numbers %s 2>&1", luajit_bin, path))
    truthy(bare:find("1 Heading", 1, true) == nil, "--no-numbers hides the gutter")
    truthy(bare:find("Heading", 1, true), "content still rendered")

    local plain = run(string.format(
        "%s mdview.lua --no-pager --width 40 %s 2>&1", luajit_bin, path))
    truthy(plain:find("^Heading") ~= nil, "plain output has no gutter by default")

    local numbered = run(string.format(
        "%s mdview.lua --no-pager -n --width 40 %s 2>&1", luajit_bin, path))
    truthy(numbered:find("^1 Heading") ~= nil, "-n enables the gutter in plain output")
    os.remove(path)
end)

test("CLI reports missing files and bad options on stderr", function()
    local missing = os.tmpname()
    os.remove(missing)
    local error_path = os.tmpname()
    local status = os.execute(string.format(
        "%s mdview.lua --no-pager %s > %s 2> %s",
        luajit_bin, missing, NULL_DEVICE, error_path))
    truthy(status ~= 0, "missing file fails")
    local file = assert(io.open(error_path, "rb"))
    local message = file:read("*a")
    file:close()
    os.remove(error_path)
    truthy(message:find("cannot open", 1, true), "missing file message")
    truthy(message:find(missing, 1, true), "path in message")

    local bad_status = os.execute(string.format(
        "%s mdview.lua --bogus > %s 2>&1", luajit_bin, NULL_DEVICE))
    truthy(bad_status ~= 0, "unknown option fails")
    local no_input = os.execute(string.format(
        "%s mdview.lua > %s 2>&1", luajit_bin, NULL_DEVICE))
    truthy(no_input ~= 0, "directory browser requires a terminal or --snapshot")
end)

test("CLI renders stdin with '-'", function()
    local path = os.tmpname()
    local status = os.execute(string.format(
        "%s -e \"io.write('# From stdin\\n\\nbody\\n')\" | %s mdview.lua --no-pager - > %s 2>&1",
        luajit_bin, luajit_bin, path))
    local file = assert(io.open(path, "rb"))
    local output = file:read("*a")
    file:close()
    os.remove(path)
    eq(status, 0, "stdin exit status")
    truthy(output:find("From stdin", 1, true), "stdin heading")
end)

test("rendering never exceeds width across a real document", function()
    local file = assert(io.open("README.md", "rb"))
    local data = file:read("*a")
    file:close()
    for _, width in ipairs({ 20, 33, 48, 80, 120 }) do
        assert_widths(mdview.render(data, width), width, "README width " .. width)
    end
    truthy(#mdview.render(data, 80) > 50, "README renders many lines")
end)

-- =========================================================================
-- Scoping and terminal safety
-- =========================================================================
test("bytecode analysis finds no undeclared globals", function()
    local handle = assert(io.popen(luajit_bin .. " -bl mdview.lua 2>&1"))
    local output = handle:read("*a")
    handle:close()
    local allowed = {
        require = true, ffi = true, bit = true, math = true, string = true,
        table = true, io = true, os = true, debug = true, arg = true,
        pcall = true, xpcall = true, setmetatable = true, tonumber = true,
        tostring = true, type = true, ipairs = true, pairs = true,
        assert = true, error = true, print = true, next = true, select = true,
    }
    local leaked = {}
    for name in output:gmatch('GGET%s+.-;%s*"([%w_]+)"') do
        if not allowed[name] then
            leaked[#leaked + 1] = name
        end
    end
    truthy(#leaked == 0, "undeclared globals: " .. table.concat(leaked, ", "))
    truthy(output:find("GSET") == nil, "no global assignments")
end)

test("module can be required without running the CLI", function()
    eq(type(mdview.main), "function", "main exported")
    eq(type(mdview.render), "function", "render exported")
    eq(mdview.VERSION, "1.0.0", "version")
    eq(mdview.Terminal.in_raw_mode, false, "no raw mode after load")
end)

test("terminal layer exposes a platform key reader", function()
    eq(type(mdview.Terminal.read_key), "function", "read_key wired")
    eq(type(mdview.Terminal.enable_raw_mode), "function", "raw mode enable")
    eq(type(mdview.Terminal.disable_raw_mode), "function", "raw mode disable")
    eq(type(mdview.Terminal.get_size), "function", "terminal size")
    eq(mdview.Terminal.in_raw_mode, false, "not in raw mode during tests")
    local ffi = require("ffi")
    if ffi.os == "Windows" then
        eq(type(mdview.Terminal.is_tty(1)), "boolean", "Windows tty probe")
    else
        eq(type(mdview.Terminal.is_tty(0)), "boolean", "Linux tty probe")
        eq(mdview.Terminal.is_tty(-1), false, "invalid fd is not a tty")
    end
end)

test("document controls are inert in plain, styled and frame output", function()
    local payload = "before\27[2Jafter\7\r\194\15531m\155"
    local plain = render_plain(payload, 100)
    truthy(not plain:find("[\1-\31\127]"), "no ASCII controls")
    truthy(not plain:find("\194\155", 1, true), "no Unicode C1 controls")
    truthy(plain:find("before^[", 1, true), "escape is visible text")
    local malformed = render_plain("a\194\155\12831mb\224\128\155", 100)
    truthy(not malformed:find("\194\155", 1, true), "C1 cannot hide before a stray continuation")
    truthy(not malformed:find("[\128-\255]"), "malformed UTF-8 becomes inert ASCII")
    local unicode = "你好 café"
    eq(render_plain(unicode, 100), unicode, "Unicode remains intact")
    for _, color in ipairs({ false, true }) do
        mdview.set_color(color)
        local output = mdview.spans_to_ansi({
            { text = payload, style = { href = "https://example.test/\7\27[2J" } },
        }, 100, false)
        truthy(not output:find("\27[2J", 1, true), "no injected screen clear")
        truthy(not output:find("\27]8;", 1, true), "unsafe hyperlink omitted")
        local view = mdview.new_view(payload, render_lines(payload, 60))
        local frame = mdview.render_frame(view, 60, 8)
        for _, row in ipairs(frame.rows) do
            truthy(not row:find("\27[2J", 1, true), "safe title and body")
        end
    end
    mdview.set_color(true)
end)

test("reflow retains words, source position and search through width changes", function()
    local paragraph = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
    local source = "# Title\n\n" .. paragraph .. "\n\n" .. string.rep("tail\n\n", 20)
    local view = mdview.new_view("resize.md", mdview.render(source, 80, { numbers = true }))
    mdview.search(view, "epsilon", 8)
    view.top = 4
    for _, width in ipairs({ 24, 50, 80 }) do
        mdview.reflow(view, width, 8)
        eq(view.lines[view.top].number, 3, "source paragraph stays at top")
        eq(view.search.query, "epsilon", "query retained")
        eq(#view.search.matches, 1, "match rebuilt")
        local match = view.search.matches[view.search.index]
        truthy(view.match_map[match.line], "match map uses new row indices")
        assert_widths(view.lines, width - view.gutter_width, "reflow")
        local words = {}
        for _, line in ipairs(view.lines) do
            for word in line.text:gmatch("%a+") do
                words[#words + 1] = word
            end
        end
        truthy(table.concat(words, " "):find(paragraph, 1, true), "all paragraph words retained")
        local frame = mdview.render_frame(view, width, 8)
        eq(#frame.rows, 8, "resized frame renders")
    end
    mdview.handle_key(view, "/", 8)
    for _, key in ipairs({ "t", "a", "i", "l" }) do
        mdview.handle_key(view, key, 8)
    end
    mdview.reflow(view, 30, 8)
    mdview.handle_key(view, "ESC", 8)
    eq(view.search.query, "epsilon", "cancel after resize restores search")
    eq(view.lines[view.top].number, 3, "cancel restores reflowed source anchor")
    local empty = mdview.new_view("empty", render_lines("", 80))
    mdview.reflow(empty, 24, 4)
    eq(empty.top, 1, "empty reflow remains clamped")
    mdview.render_frame(empty, 24, 4)
end)

test("snapshot wraps at requested width without losing paragraph words", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\n")
    file:close()
    local pipe = assert(io.popen(string.format(
        "%s mdview.lua --snapshot 24x12 --no-color --no-numbers %s", luajit_bin, path)))
    local output = pipe:read("*a")
    pipe:close()
    os.remove(path)
    for _, word in ipairs({ "alpha", "epsilon", "theta", "lambda", "mu" }) do
        truthy(output:find(word, 1, true), "snapshot retains " .. word)
    end
end)

test("help scrolls independently when opened from the document bottom", function()
    local source = string.rep("paragraph\n\n", 100)
    for _, width in ipairs({ 24, 60, 100 }) do
        local view = mdview.new_view("help.md", render_lines(source, width))
        mdview.handle_key(view, "G", 12, width)
        local top = view.top
        mdview.search(view, "paragraph", 12)
        local search = view.search
        mdview.handle_key(view, "h", 12, width)
        local frame = mdview.render_frame(view, width, 12)
        truthy(frame.plain[2]:find("mdview keys", 1, true), "help starts at its heading")
        mdview.handle_key(view, "G", 12, width)
        mdview.render_frame(view, width, 12)
        truthy(view.help_top > 1, "help scrolls to bottom")
        eq(view.top, top, "document position unchanged while scrolling help")
        mdview.handle_key(view, "ESC", 12, width)
        mdview.render_frame(view, width, 12)
        eq(view.top, top, "document position restored")
        eq(view.search, search, "search state preserved")
        mdview.handle_key(view, "h", 12, width)
        mdview.handle_key(view, "q", 12, width)
        eq(view.quit, true, "q quits as help footer advertises")
    end
    local empty = mdview.new_view("empty", render_lines("", 24))
    mdview.handle_key(empty, "h", 4, 24)
    mdview.render_frame(empty, 24, 4)
    mdview.handle_key(empty, "h", 4, 24)
    eq(empty.top, 1, "empty document survives help round trip")
end)

test("outline indexes real headings and filters using key-reader tokens", function()
    local source = "# Intro\n\n## **Install** Linux\n\nbody\n\n"
        .. "## Install Windows\n\n### 中文\n\n"
        .. "```md\n# not a heading\n```\n\nSetext\n======\n\n"
        .. string.rep("tail\n\n", 10)
    local view = mdview.new_view("outline.md", render_lines(source, 60))
    eq(#view.lines.headings, 5, "fenced headings excluded, setext included")
    eq(view.lines.headings[2].text, "Install Linux", "heading inline styles removed")
    mdview.handle_key(view, "G", 10)
    local original_top = view.top
    local search = view.search
    mdview.handle_key(view, "t", 10)
    eq(view.outline.selected, 1, "first heading selected")
    local frame = mdview.render_frame(view, 60, 10)
    truthy(frame.plain[1]:find("Outline", 1, true), "outline heading")
    for _, key in ipairs({ "/", "I", "n", "s", "t", "a", "l", "l", "SPACE", "W", "BACKSPACE" }) do
        mdview.handle_key(view, key, 10)
        mdview.render_frame(view, 60, 10)
    end
    eq(view.outline.query, "Install ", "symbolic space and backspace")
    eq(#view.outline.items, 2, "matching headings only")
    mdview.handle_key(view, "DOWN", 10)
    mdview.reflow(view, 24, 10)
    mdview.render_frame(view, 24, 10)
    mdview.handle_key(view, "ENTER", 10)
    eq(view.mode, "normal", "jump returns to document")
    eq(view.lines[view.top].number, 7, "jump uses source line after resize")
    mdview.handle_key(view, "t", 10)
    for _, key in ipairs({ "/", "中", "文", "BACKSPACE" }) do
        mdview.handle_key(view, key, 10)
    end
    eq(view.outline.query, "中", "Unicode backspace removes one code point")
    eq(#view.outline.items, 1, "Unicode filter")
    local top = view.top
    local active_search = view.search
    mdview.handle_key(view, "ESC", 10)
    eq(view.top, top, "cancel preserves document position")
    eq(view.search, active_search, "cancel preserves search object")
    truthy(original_top > 1 and search ~= nil, "started from populated view")
end)

test("outline renders empty, long and special headings across viewport boundaries", function()
    local source = ""
    for index = 1, 30 do
        source = source .. string.format("## Heading %d %% 中文 %s\n\n", index, string.rep("long ", 20))
    end
    for _, size in ipairs({ { 1, 1 }, { 23, 3 }, { 24, 4 }, { 40, 8 }, { 100, 30 } }) do
        local width, height = size[1], size[2]
        local view = mdview.new_view("special % name", render_lines(source, width))
        mdview.handle_key(view, "t", height)
        for _, key in ipairs({ "G", "j", "UP", "PAGE_UP", "PAGE_DOWN", "HOME", "k", "END" }) do
            mdview.handle_key(view, key, height)
            local frame = mdview.render_frame(view, width, height)
            eq(#frame.rows, height, "outline frame height")
            for _, row in ipairs(frame.plain) do
                eq(mdview.display_width(row), width, "outline row width")
            end
            truthy(view.outline.selected >= view.outline.top, "selection above lower bound")
            truthy(view.outline.selected < view.outline.top + math.max(1, height - 2),
                "selection below upper bound")
        end
        mdview.handle_key(view, "/", height)
        mdview.handle_key(view, "z", height)
        local frame = mdview.render_frame(view, width, height)
        eq(view.outline.selected, 0, "no match has no selection")
        if width >= 24 and height >= 4 then
            truthy(frame.plain[2]:find("No headings", 1, true), "visible no-match state")
            for row = 3, height - 1 do
                eq(frame.plain[row], string.rep(" ", width), "stale headings cleared")
            end
        end
        mdview.handle_key(view, "ENTER", height)
        eq(view.mode, "outline", "Enter without a match stays in outline")
        mdview.handle_key(view, "ESC", height)
        mdview.render_frame(view, width, height)
    end
    local view = mdview.new_view("empty", render_lines("", 60))
    mdview.handle_key(view, "t", 10)
    local frame = mdview.render_frame(view, 60, 10)
    truthy(frame.plain[2]:find("No headings in this document", 1, true), "empty document message")
    mdview.handle_key(view, "t", 10)
    eq(view.mode, "normal", "toggle restores empty document")
    mdview.handle_key(view, "t", 10)
    mdview.handle_key(view, "q", 10)
    eq(view.quit, true, "q quits from outline")
    local long_prompt = mdview.new_view("long prompt", render_lines("# Heading", 24))
    mdview.handle_key(long_prompt, "t", 4)
    mdview.handle_key(long_prompt, "/", 4)
    for _ = 1, 40 do
        mdview.handle_key(long_prompt, "中", 4)
    end
    mdview.handle_key(long_prompt, "X", 4)
    local prompt_frame = mdview.render_frame(long_prompt, 24, 4)
    truthy(prompt_frame.plain[4]:find("X▏", 1, true), "long filter keeps typed tail and cursor visible")
end)

local function browser_fixture()
    local scans = {}
    local files = {
        ["/docs/alpha.md"] = "# Alpha\n\n" .. string.rep("alpha text\n\n", 40),
        ["/docs/beta.markdown"] = "# Beta\n\nshort\n",
        ["/docs/nested/中文.md"] = "# Unicode\n\n![image](image.ppm)\n",
    }
    local directories = {
        ["/docs"] = {
            { name = "beta.markdown", kind = "file" },
            { name = "nested", kind = "directory" },
            { name = "alpha.md", kind = "file" },
            { name = ".hidden.md", kind = "file" },
            { name = "secret.md", kind = "file", hidden = true },
            { name = "loop", kind = "link" },
            { name = "image.png", kind = "file" },
        },
        ["/docs/nested"] = { { name = "中文.md", kind = "file" } },
    }
    local fs = {
        resolve = function(path)
            return path:gsub("/$", "")
        end,
        kind = function(path)
            if files[path] then
                return "file"
            elseif directories[path] then
                return "directory"
            end
            return nil, "file disappeared"
        end,
        list = function(path)
            scans[path] = (scans[path] or 0) + 1
            return directories[path], "permission denied"
        end,
        read_document = function(path)
            return files[path], "read failed"
        end,
    }
    local view = mdview.new_view("Select a file", render_lines("Choose a file", 80))
    local browser = mdview.new_browser(view, "/docs", true, { images = false }, fs)
    return browser, files, directories, scans
end

local function browser_key(browser, key, width, height)
    width, height = width or 80, height or 10
    mdview.handle_browser_key(browser, key, width, height)
    -- Exercise loading-state rendering before each external operation.
    mdview.render_browser(browser, width, height)
    if browser.pending then
        mdview.process_browser_pending(browser, width, height)
    end
    mdview.resize_browser(browser, width, height)
    return mdview.render_browser(browser, width, height)
end

test("file tree is lazy, sorted, icon-labelled and navigable with Vim tokens", function()
    local browser, _, _, scans = browser_fixture()
    truthy(mdview.process_browser_pending(browser, 80, 10), "root loaded")
    eq(#browser.entries, 4, "only directory and visible Markdown files")
    eq(browser.entries[2].name, "nested", "directories first")
    eq(browser.entries[3].name, "alpha.md", "files alphabetical")
    eq(scans["/docs/nested"], nil, "collapsed folder not scanned")
    local frame = browser_key(browser, "j")
    truthy(frame.plain[2]:find("📂", 1, true), "expanded folder icon")
    truthy(frame.plain[3]:find("📁", 1, true), "closed folder icon")
    truthy(frame.plain[4]:find("📄", 1, true), "Markdown file icon")
    truthy(frame.rows[2]:find("38;2;240;190;90", 1, true), "expanded folder icon colored")
    truthy(frame.rows[3]:find("38;2;240;190;90", 1, true), "closed folder icon colored")
    truthy(frame.rows[4]:find("38;2;120;200;230", 1, true), "file icon colored")
    browser_key(browser, "l")
    eq(scans["/docs/nested"], 1, "expanding scans once")
    eq(#browser.entries, 5, "child exposed")
    browser_key(browser, "l")
    eq(browser.entries[browser.selected].name, "中文.md", "l enters expanded directory")
    browser_key(browser, "h")
    eq(browser.selected, 2, "h selects parent")
    browser_key(browser, "h")
    eq(#browser.entries, 4, "h collapses directory")
    browser_key(browser, "RIGHT")
    eq(scans["/docs/nested"], 1, "reopening cached directory avoids scan")
    browser_key(browser, "G")
    eq(browser.selected, #browser.entries, "G selects last")
    browser_key(browser, "g")
    eq(browser.selected, #browser.entries, "single g waits for second g")
    browser_key(browser, "g")
    eq(browser.selected, 1, "gg selects first")
    browser_key(browser, "UP")
    eq(browser.selected, 1, "upper bound clamped")
    browser_key(browser, "?")
    eq(browser.view.mode, "help", "tree question mark opens help")
    browser_key(browser, "ESC")
    eq(browser.focus, "tree", "closing help restores tree focus")
end)

test("file switching preserves document search and position and resolves relative images", function()
    local browser = browser_fixture()
    mdview.process_browser_pending(browser, 80, 10)
    browser_key(browser, "j")
    browser_key(browser, "j")
    browser_key(browser, "ENTER")
    eq(browser.focus, "document", "opening focuses document")
    eq(browser.path, "/docs/alpha.md", "selected file opened")
    for _, key in ipairs({ "/", "t", "e", "x", "t", "ENTER", "G" }) do
        browser_key(browser, key)
    end
    local alpha = browser.view
    local top = alpha.top
    local search = alpha.search
    browser_key(browser, "TAB")
    browser_key(browser, "j")
    browser_key(browser, "ENTER")
    eq(browser.path, "/docs/beta.markdown", "second file opened")
    browser_key(browser, "TAB")
    browser_key(browser, "k")
    browser_key(browser, "ENTER")
    eq(browser.view, alpha, "same document view restored")
    eq(browser.view.top, top, "scroll restored")
    eq(browser.view.search, search, "search restored")
    browser_key(browser, "TAB")
    browser_key(browser, "k")
    browser_key(browser, "l")
    browser_key(browser, "j")
    browser_key(browser, "ENTER")
    eq(browser.path, "/docs/nested/中文.md", "Unicode file opened")
    eq(browser.view.lines.render_options.base_dir, "/docs/nested/", "image base is opened file directory")
end)

test("tree failures preserve the document and can be repaired with refresh", function()
    local browser, files, directories = browser_fixture()
    mdview.process_browser_pending(browser, 80, 10)
    local original = browser.view
    browser_key(browser, "G")
    files["/docs/beta.markdown"] = nil
    local frame = browser_key(browser, "ENTER")
    eq(browser.view, original, "disappeared file does not replace document")
    truthy(frame.plain[10]:find("Cannot open", 1, true), "visible file error")
    browser_key(browser, "g")
    browser_key(browser, "g")
    browser_key(browser, "j")
    directories["/docs/nested"] = nil
    frame = browser_key(browser, "l")
    truthy(frame.plain[10]:find("permission denied", 1, true), "visible folder failure")
    eq(browser.view, original, "directory failure preserves document")
    directories["/docs/nested"] = {}
    browser_key(browser, "r")
    eq(browser.message, "", "refresh clears repaired error")
    eq(browser.entries[2].expanded, true, "empty folder opens")
    directories["/docs"] = {}
    browser_key(browser, "g")
    browser_key(browser, "g")
    frame = browser_key(browser, "r")
    eq(#browser.entries, 1, "refresh removes stale entries")
    for row = 4, 9 do
        eq(frame.plain[row]:sub(1, 26), string.rep(" ", 26), "stale tree rows cleared")
    end
end)

test("browser frames cover tiny, narrow and wide terminals and long unsafe names", function()
    local browser, _, directories = browser_fixture()
    for index = 1, 40 do
        directories["/docs"][#directories["/docs"] + 1] = {
            name = string.rep("中", 20) .. "%\27[2J" .. index .. ".md",
            kind = "file",
        }
    end
    mdview.process_browser_pending(browser, 80, 10)
    for _, size in ipairs({ { 1, 1 }, { 23, 3 }, { 24, 4 }, { 63, 10 }, { 64, 10 }, { 120, 30 } }) do
        local width, height = size[1], size[2]
        for _, key in ipairs({ "G", "j", "CTRL_U", "CTRL_D", "PAGE_UP", "PAGE_DOWN", "HOME" }) do
            local frame = browser_key(browser, key, width, height)
            eq(#frame.rows, height, "browser frame height")
            for _, row in ipairs(frame.plain) do
                eq(mdview.display_width(row), width, "browser frame width")
                truthy(not row:find("\27[2J", 1, true), "filename cannot clear terminal")
            end
            truthy(browser.selected >= browser.top, "selection above scroll offset")
            truthy(browser.selected < browser.top + math.max(1, height - 2), "selection visible")
        end
        browser_key(browser, "TAB", width, height)
        eq(browser.focus, "document", "Tab focuses document")
        browser_key(browser, "f", width, height)
        eq(browser.tree_visible, false, "f hides tree")
        browser_key(browser, "f", width, height)
        eq(browser.focus, "tree", "f reveals and focuses tree")
    end
end)

test("direct-file browser loads its tree only when requested", function()
    local fixture = browser_fixture()
    local view = mdview.new_view("alpha.md", render_lines("# Alpha", 80))
    local browser = mdview.new_browser(view, "/docs/alpha.md", false, {}, fixture.fs)
    eq(browser.tree_visible, false, "file starts full width")
    eq(browser.pending, nil, "file startup does not scan directories")
    local frame = mdview.render_browser(browser, 80, 10)
    truthy(frame.plain[1]:find("alpha.md", 1, true), "direct document header")
    browser_key(browser, "f")
    eq(browser.tree_visible, true, "tree opens on demand")
    eq(browser.root.path, "/docs", "tree root is document parent")
    eq(browser.entries[browser.selected].name, "alpha.md", "direct file selected when tree opens")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
os.exit(0)
