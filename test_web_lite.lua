#!/usr/bin/env luajit
--[[
    test_web_lite.lua
    Comprehensive unit and integration test suite for web_lite.lua.
]]

local web = require("web_lite")

local TestRunner = {
    passed = 0,
    failed = 0
}

function TestRunner.describe(suite_name, fn)
    print(string.format("\n\27[1;36m▶ Suite: %s\27[0m", suite_name))
    fn()
end

function TestRunner.it(test_name, fn)
    local ok, err = pcall(fn)
    if ok then
        TestRunner.passed = TestRunner.passed + 1
        print(string.format("  \27[32m✔\27[0m %s", test_name))
    else
        TestRunner.failed = TestRunner.failed + 1
        print(string.format("  \27[31m✘\27[0m %s", test_name))
        print(string.format("    \27[31mError: %s\27[0m", tostring(err)))
    end
end

local function assert_true(val, msg)
    if not val then
        error(msg or "Assertion failed: expected true", 2)
    end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

print("=== Running web_lite Terminal Browser Test Suite ===")

-- 1. HTML Entity Decoding & Tag Cleaning
TestRunner.describe("1. HTML Entity Decoding & Tag Cleaning", function()
    TestRunner.it("should decode standard named entities", function()
        local input = "Tom &amp; Jerry &lt;rocks&gt; &quot;quote&quot; &#39;apostrophe&#39;"
        local decoded = web.decode_entities(input)
        assert_eq(decoded, "Tom & Jerry <rocks> \"quote\" 'apostrophe'", "named entities must decode correctly")
    end)

    TestRunner.it("should decode numeric decimal and hex entities", function()
        local input = "Price: &#36;100 &#x26; tax &#169; 2026"
        local decoded = web.decode_entities(input)
        assert_true(decoded:find("%$100"), "dollar sign &#36; should decode to $")
        assert_true(decoded:find("&"), "ampersand &#x26; should decode to &")
        assert_true(decoded:find("©"), "copyright &#169; should decode to ©")
    end)

    TestRunner.it("should strip script, style, svg, and comment blocks", function()
        local dirty_html = "<!-- Comment --><h1>Title</h1><script>alert(1);</script><style>body{color:red;}</style><div class=\"[&>:first-child]:h-full\"><p>Content</p></div>"
        local cleaned = web.strip_scripts_and_styles(dirty_html)
        assert_true(not cleaned:find("alert"), "script content must be removed")
        assert_true(not cleaned:find("color:red"), "style content must be removed")
        assert_true(not cleaned:find("Comment"), "comments must be removed")
        assert_true(not cleaned:find("&>:first%-child"), "tailwind CSS selector classes must be stripped")
        assert_true(cleaned:find("Title"), "HTML tags and content must be preserved")
    end)
end)

-- 2. URL Resolution & Smart Omnibox Input
TestRunner.describe("2. URL Resolution & Smart Omnibox Input", function()
    TestRunner.it("should resolve relative URLs correctly", function()
        local base = "https://luajit.org/ext_ffi.html"
        assert_eq(web.resolve_relative_url(base, "/index.html"), "https://luajit.org/index.html")
        assert_eq(web.resolve_relative_url(base, "changes.html"), "https://luajit.org/changes.html")
        assert_eq(web.resolve_relative_url(base, "https://www.lua.org"), "https://www.lua.org")
    end)

    TestRunner.it("should smartly detect direct URLs vs search queries", function()
        local u1, mode1 = web.smart_resolve_input("news.ycombinator.com")
        assert_eq(u1, "https://news.ycombinator.com")
        assert_eq(mode1, "url")

        local u2, mode2 = web.smart_resolve_input("https://github.com/skyera")
        assert_eq(u2, "https://github.com/skyera")
        assert_eq(mode2, "url")

        local u3, mode3 = web.smart_resolve_input("luajit ffi tutorial windows")
        assert_true(u3:find("duckduckgo%.com"), "search query must route to DuckDuckGo")
        assert_eq(mode3, "search")

        local u4, mode4 = web.smart_resolve_input("about:home")
        assert_eq(u4, "about:home")
        assert_eq(mode4, "about")

        local u5, mode5 = web.smart_resolve_input("r/programming")
        assert_eq(u5, "https://www.reddit.com/r/programming", "r/<subname> must resolve to reddit")
        assert_eq(mode5, "url")
    end)
end)

-- 3. Document Reflow, Formatting & Tables
TestRunner.describe("3. Document Reflow, Formatting & Tables", function()
    TestRunner.it("should wrap long lines properly to max width", function()
        local long_text = "The quick brown fox jumps over the lazy dog repeatedly to test word wrapping in our terminal engine."
        local wrapped = web.word_wrap(long_text, 30)
        assert_true(#wrapped >= 3, "must wrap into at least 3 lines")
        for _, l in ipairs(wrapped) do
            assert_true(web.visual_len(l) <= 30, "line must not exceed 30 visual columns")
        end
    end)

    TestRunner.it("should format HTML tables with Unicode box borders", function()
        local html_tbl = [[
            <table>
                <tr><th>Key</th><th>Description</th></tr>
                <tr><td>j</td><td>Move Down</td></tr>
                <tr><td>k</td><td>Move Up</td></tr>
            </table>
        ]]
        local lines = web.format_html_table(html_tbl, 60)
        assert_true(#lines >= 5, "table should have borders, headers, and rows")
        assert_true(lines[1]:find("┌"), "top border should start with ┌")
        assert_true(lines[#lines]:find("└"), "bottom border should end with └")
        assert_true(lines[2]:find("Key"), "header should contain 'Key'")
        assert_true(lines[4]:find("Move Down"), "data row should contain 'Move Down'")
    end)

    TestRunner.it("should parse full HTML and extract hyperlinks with IDs", function()
        local html = [[
            <html>
            <head><title>Test Page</title></head>
            <body>
                <h1>Main Heading</h1>
                <p>Visit <a href="https://luajit.org">LuaJIT</a> or read the <a href="/docs">Docs</a>.</p>
                <ul>
                    <li>Feature 1</li>
                    <li>Feature 2</li>
                </ul>
            </body>
            </html>
        ]]
        local doc = web.render_html_to_document(html, "https://example.com/index.html", 80)
        assert_eq(doc.title, "Test Page")
        assert_true(#doc.lines >= 5, "document should have rendered lines")
        assert_eq(#doc.links, 2, "document should have extracted 2 hyperlinks")
        assert_eq(doc.links[1].href, "https://luajit.org")
        assert_eq(doc.links[2].href, "https://example.com/docs")
    end)

    TestRunner.it("should preserve all hyperlinks in layout tables (e.g. Hacker News)", function()
        local hn_sample = [[
            <html><body>
            <table border="0" id="hnmain">
                <tr><td>
                    <table class="itemlist">
                        <tr class="athing">
                            <td>1.</td>
                            <td><a href="vote?id=101"><div class="votearrow" title="upvote"></div></a></td>
                            <td><a href="https://example.com/story1">First Story Title</a></td>
                        </tr>
                        <tr>
                            <td></td>
                            <td>100 points by user | <a href="item?id=101">42 comments</a></td>
                        </tr>
                        <tr class="athing">
                            <td>2.</td>
                            <td><a href="https://example.com/story2">Second Story Title</a></td>
                        </tr>
                    </table>
                </td></tr>
            </table>
            </body></html>
        ]]
        local doc = web.render_html_to_document(hn_sample, "https://news.ycombinator.com", 80)
        assert_true(#doc.links >= 3, "must extract story, vote, and comments links from layout table")
        assert_eq(doc.links[1].text, "▲", "vote link should render clean arrow symbol")
        assert_eq(doc.links[2].text, "First Story Title")
        assert_eq(doc.links[2].href, "https://example.com/story1")
        assert_eq(doc.links[3].text, "42 comments")
        assert_eq(doc.links[3].href, "https://news.ycombinator.com/item?id=101")
        assert_eq(doc.links[4].text, "Second Story Title")
    end)
end)

-- 4. Browser State Machine & Vim Navigation
TestRunner.describe("4. Browser State Machine & Vim Navigation", function()
    local b = web.Browser.new("about:home")
    b:load_url("about:home")

    TestRunner.it("should initialize at line 1 in NORMAL mode", function()
        assert_eq(b.scroll_y, 1)
        assert_eq(b.mode, "NORMAL")
        assert_true(b.doc ~= nil, "document must be loaded")
        assert_true(#b.doc.lines > 10, "home page must have content")
        assert_true(#b.doc.links >= 5, "home page must have quick bookmarks")
    end)

    TestRunner.it("should handle Vim scrolling (j, k, G, gg, d, u)", function()
        b:handle_key("j")
        assert_eq(b.scroll_y, 2, "'j' should scroll down 1 line")

        b:handle_key("5")
        b:handle_key("j")
        assert_eq(b.scroll_y, 7, "'5j' should scroll down 5 lines")

        b:handle_key("k")
        assert_eq(b.scroll_y, 6, "'k' should scroll up 1 line")

        b:handle_key("G")
        assert_true(b.scroll_y > 10, "'G' should jump to bottom")

        b:handle_key("g")
        b:handle_key("g")
        assert_eq(b.scroll_y, 1, "'gg' should jump back to top")
    end)

    TestRunner.it("should handle Vimium Hint mode (f)", function()
        b:handle_key("f")
        assert_eq(b.mode, "HINT", "'f' should enter HINT mode")
        b:build_hints(25)
        assert_true(b.hint_map["A"] ~= nil, "hint 'A' must be assigned to first visible link")

        b:handle_key("ESC")
        assert_eq(b.mode, "NORMAL", "ESC should exit hint mode")
    end)

    TestRunner.it("should handle in-page search (/)", function()
        b:handle_key("/")
        assert_eq(b.mode, "SEARCH", "'/' should enter search mode")

        -- Type "vim" and Enter
        for char in string.gmatch("Vim", ".") do
            b:handle_key(char)
        end
        b:handle_key("ENTER")
        assert_eq(b.mode, "NORMAL", "Enter should return to NORMAL mode")
        assert_true(#b.search_matches > 0, "should find matches for 'Vim'")

        local first_match = b.scroll_y
        b:handle_key("n")
        assert_true(b.scroll_y >= first_match, "'n' should jump through matches")

        b:handle_key("ESC")
        assert_eq(b.search_query, "", "ESC should clear search")
    end)

    TestRunner.it("should handle Omnibox URL input (o)", function()
        b:handle_key("o")
        assert_eq(b.mode, "INPUT", "'o' should enter Omnibox input mode")
        assert_eq(b.input_buf, "")

        for char in string.gmatch("about:help", ".") do
            b:handle_key(char)
        end
        assert_eq(b.input_buf, "about:help")

        b:handle_key("ENTER")
        assert_eq(b.mode, "NORMAL")
        assert_eq(b.url, "about:help", "Enter should navigate to typed URL")
        assert_eq(b.doc.title, "web_lite: Help & Keybindings")

        -- Test history Back (H) and Forward (L)
        b:handle_key("H")
        assert_eq(b.url, "about:home", "'H' should go back to home")
        b:handle_key("L")
        assert_eq(b.url, "about:help", "'L' should go forward to help")
    end)

    TestRunner.it("should return to HOME via 'gh' key shortcut", function()
        -- Ensure we are currently away from home
        b:navigate_to("about:help")
        assert_eq(b.url, "about:help")

        -- Press 'g' then 'h'
        b:handle_key("g")
        b:handle_key("h")
        assert_eq(b.url, "about:home", "'gh' must navigate directly to about:home")
        assert_eq(b.scroll_y, 1, "viewport must reset to top")
    end)

    TestRunner.it("should return to HOME via ':home' command", function()
        b:navigate_to("about:help")
        assert_eq(b.url, "about:help")

        b:handle_key(":")
        assert_eq(b.mode, "COMMAND")
        for char in string.gmatch("home", ".") do
            b:handle_key(char)
        end
        b:handle_key("ENTER")
        assert_eq(b.mode, "NORMAL")
        assert_eq(b.url, "about:home", "':home' command must navigate to about:home")
    end)

    TestRunner.it("should navigate and focus links via TAB, ], SHIFT_TAB, and [", function()
        b:navigate_to("about:home")
        assert_true(#b.doc.links >= 4, "home page has multiple links")

        b.selected_link_idx = 1
        -- Test TAB moving forward
        b:handle_key("TAB")
        assert_eq(b.selected_link_idx, 2, "TAB should advance to link 2")

        -- Test ']' alias moving forward
        b:handle_key("]")
        assert_eq(b.selected_link_idx, 3, "']' should advance to link 3")

        -- Test SHIFT_TAB moving backward
        b:handle_key("SHIFT_TAB")
        assert_eq(b.selected_link_idx, 2, "SHIFT_TAB should return to link 2")

        -- Test '[' alias moving backward
        b:handle_key("[")
        assert_eq(b.selected_link_idx, 1, "'[' should return to link 1")

        -- Test wrapping around backwards
        b:handle_key("[")
        assert_eq(b.selected_link_idx, #b.doc.links, "'[' at link 1 should wrap to last link")

        -- Test ENTER opening focused link
        local target_href = b.doc.links[b.selected_link_idx].href
        b:handle_key("ENTER")
        assert_eq(b.url, target_href, "ENTER should open the focused link")
    end)
end)

-- 5. Chinese (CJK) Text Processing, Word Wrapping & Input
TestRunner.describe("5. Chinese (CJK) Text Processing, Word Wrapping & Input", function()
    TestRunner.it("should accurately calculate visual width for Chinese characters", function()
        assert_eq(web.visual_len("你好世界"), 8, "4 Chinese characters should have visual width of 8")
        assert_eq(web.visual_len("LuaJIT中文"), 10, "6 ASCII + 2 Chinese characters should have visual width of 10")
        assert_eq(web.visual_len("提示：按'o'键输入网址"), 21, "Chinese text with punctuation should have correct visual width")
    end)

    TestRunner.it("should wrap spaceless Chinese paragraphs cleanly to max_width", function()
        local cjk_text = "欢迎使用web_lite终端网页浏览器，这是一个纯LuaJIT编写的高性能极简浏览器，支持Vim全键盘导航。"
        local lines = web.word_wrap(cjk_text, 30, "  • ", "    ")
        assert_true(#lines >= 3, "Chinese text must wrap into multiple lines even without spaces")
        for idx, l in ipairs(lines) do
            assert_true(web.visual_len(l) <= 30, string.format("Line %d visual width %d must not exceed 30", idx, web.visual_len(l)))
        end
    end)

    TestRunner.it("should keep Chinese closing punctuation attached to preceding characters", function()
        local text = "这是一个测试，标点符号不能单独出现在行首。换行测试！"
        local lines = web.word_wrap(text, 14)
        for idx, l in ipairs(lines) do
            -- First character of line should not be a lone closing comma or period
            local first_char = l:match("^%s*(.-)%s*$"):sub(1, 3)
            assert_true(first_char ~= "，" and first_char ~= "。" and first_char ~= "！", "line must not begin with closing punctuation")
        end
    end)

    TestRunner.it("should properly URL-encode Chinese search queries for DuckDuckGo Lite", function()
        local url, mode = web.smart_resolve_input("LuaJIT 中文教程")
        assert_eq(mode, "search")
        assert_true(url:find("duckduckgo%.com"), "should route to DuckDuckGo")
        -- Should be percent-encoded: %E4%B8%AD%E6%96%87
        assert_true(url:find("%%E4%%B8%%AD%%E6%%96%%87"), "Chinese characters must be percent-encoded in query")
    end)

    TestRunner.it("should safely pop entire UTF-8 Chinese character on Backspace", function()
        local s1 = "hello世界"
        local s2 = web.utf8_pop_char(s1)
        assert_eq(s2, "hello世", "should pop exactly one 3-byte Chinese character")
        local s3 = web.utf8_pop_char(s2)
        assert_eq(s3, "hello", "should pop second Chinese character")
        local s4 = web.utf8_pop_char(s3)
        assert_eq(s4, "hell", "should pop ASCII character normally")
    end)

    TestRunner.it("should render Chinese HTML documents and extract Chinese links", function()
        local html = [[
            <html>
            <head><title>中文测试页面</title></head>
            <body>
                <h1>LuaJIT 终端浏览器</h1>
                <p>这是一个<b>纯LuaJIT FFI</b>编写的终端浏览器，支持<a href="https://zh.wikipedia.org">中文维基百科</a>与技术文档浏览。</p>
                <ul>
                  <li>极速启动与零内存GC停顿</li>
                  <li>支持Vim全键盘模式操作</li>
                </ul>
            </body>
            </html>
        ]]
        local doc = web.render_html_to_document(html, "https://example.com/zh.html", 60)
        assert_eq(doc.title, "中文测试页面")
        assert_eq(#doc.links, 1)
        assert_eq(doc.links[1].text, "中文维基百科")
        assert_eq(doc.links[1].href, "https://zh.wikipedia.org")

        local found_bullet = false
        for _, l in ipairs(doc.lines) do
            if l:find("极速启动") then found_bullet = true end
        end
        assert_true(found_bullet, "Chinese bullet text must be present in document lines")
    end)

    TestRunner.it("should support Chinese search in page with '/'", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")
        b:handle_key("/")
        assert_eq(b.mode, "SEARCH")

        -- Enter Chinese search term "书签"
        b:handle_key("书")
        b:handle_key("签")
        b:handle_key("ENTER")
        assert_eq(b.mode, "NORMAL")
        assert_true(#b.search_matches > 0, "should find matches for Chinese search query '书签'")
    end)
end)

print(string.format("\n========================================="))
print(string.format("Test Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.format("=========================================\n"))

if TestRunner.failed > 0 then
    os.exit(1)
end
os.exit(0)
