#!/usr/bin/env luajit
--[[
    test_weblite.lua
    Comprehensive unit and integration test suite for weblite.lua.
]]

local web = require("weblite")

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

print("=== Running weblite Terminal Browser Test Suite ===")

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

        local u2b, mode2b = web.smart_resolve_input("https:/://bbs.wenxuecity.com")
        assert_eq(u2b, "https://bbs.wenxuecity.com")
        assert_eq(mode2b, "url")

        local u3, mode3 = web.smart_resolve_input("luajit ffi tutorial windows")
        assert_true(u3:find("duckduckgo%.com"), "search query must route to DuckDuckGo")
        assert_eq(mode3, "search")

        local u4, mode4 = web.smart_resolve_input("about:home")
        assert_eq(u4, "about:home")
        assert_eq(mode4, "about")

        local u5, mode5 = web.smart_resolve_input("r/programming")
        assert_eq(u5, "https://www.reddit.com/r/programming", "r/<subname> must resolve to reddit")
        assert_eq(mode5, "url")

        local u6, mode6 = web.smart_resolve_input("links")
        assert_eq(u6, "about:links")
        assert_eq(mode6, "about")
    end)

    TestRunner.it("should safely shell-quote arbitrary URLs", function()
        local malicious_url = "https://example.com/search?q=$(calc)&param=`id`&x='\""
        local quoted = web.shell_quote(malicious_url)
        assert_true(quoted ~= nil and #quoted > 0, "shell_quote must return a quoted string")
        assert_true(quoted:sub(1, 1) == "'" or quoted:sub(1, 1) == '"', "quoted string must start with quote")
    end)
end)

TestRunner.describe("2b. Response Metadata & Link Tools", function()
    TestRunner.it("should normalize content types", function()
        assert_eq(web.get_content_type("text/html; charset=UTF-8"), "text/html")
        assert_eq(web.get_content_type(" application/json "), "application/json")
    end)

    TestRunner.it("should detect Cloudflare browser challenges", function()
        local headers = "HTTP/2 403\r\ncf-mitigated: challenge\r\ncontent-type: text/html\r\n"
        local body = "<html><title>Just a moment...</title></html>"
        assert_true(web.is_cloudflare_challenge(headers, body), "Cloudflare challenge must be detected")
        assert_true(not web.is_cloudflare_challenge("HTTP/2 200\r\n", "<title>Normal page</title>"), "normal HTML must not be flagged")
    end)

    TestRunner.it("should detect Reddit block responses", function()
        local headers = "HTTP/2 403\r\ncontent-type: text/html\r\n"
        local body = "<html><title>Blocked</title><body>You have been blocked</body></html>"
        assert_true(web.is_reddit_block(headers, body, "https://www.reddit.com/r/programming"), "Reddit block must be detected")
        assert_true(not web.is_reddit_block("HTTP/2 200\r\n", "<title>Reddit</title>", "https://www.reddit.com"), "normal Reddit HTML must not be flagged")
    end)

    TestRunner.it("should parse JSON strings with escapes and unicode", function()
        local json = [[{"title":"How to use \"quotes\" & \u2605 star","body":"<p>Paragraph</p>"}]]
        local title = web.parse_json_value_after(json, "title")
        local body = web.parse_json_value_after(json, "body")
        assert_eq(title, "How to use \"quotes\" & ★ star")
        assert_eq(body, "<p>Paragraph</p>")
    end)

    TestRunner.it("should render a useful Cloudflare challenge page", function()
        local b = web.Browser.new("about:home")
        b.raw_html = "<html><title>Cloudflare verification required</title><body><h1>Cloudflare verification required</h1><p>weblite uses curl and cannot execute the JavaScript challenge.</p><p>--insecure will not bypass this protection.</p></body></html>"
        b.doc = web.render_html_to_document(b.raw_html, "https://stackoverflow.com", 80)
        assert_true(b.doc.title:find("Cloudflare"), "challenge page should have a clear title")
        local text = table.concat(b.doc.lines, "\n")
        assert_true(text:find("JavaScript challenge"), "challenge page should explain the limitation")
    end)

    TestRunner.it("should build a navigable links page", function()
        local b = web.Browser.new("about:home")
        b.doc = web.render_html_to_document("<h1>Test</h1><a href='https://example.com'>Example</a>", "about:home", 80)
        b.raw_html = "<h1>Test</h1><a href='https://example.com'>Example</a>"
        b:show_links()
        assert_eq(b.url, "about:links")
        assert_true(b.doc and #b.doc.links > 0, "links page should contain links")
        assert_true(b.raw_html:find("https://example.com"), "links page should include target URLs")
    end)

    TestRunner.it("should expose image preview support without loading images automatically", function()
        local doc = web.render_html_to_document("<img src='https://example.com/test.png' alt='Test image'>", "https://example.com", 80)
        assert_true(#doc.links == 1, "image should remain an interactive link")
        assert_true(doc.links[1].is_image, "image link should be marked as an image")
        local renderer = web.find_image_renderer()
        assert_true(renderer == nil or renderer == "chafa" or renderer == "viu", "renderer detection must be safe")
        assert_true(web.image_download_message(403, "https://images.example/test.png"):find("403 Forbidden"), "403 image errors must be explicit")
        assert_true(web.is_image_url("https://images.example/photo.jpg?size=large"), "image URL with query must be detected")
        assert_true(not web.is_image_url("https://example.com/page.html"), "HTML URL must not be detected as an image")
        assert_true(web.is_image_url("https://preview.redd.it/photo.jpeg?width=1080"), "Reddit preview image URL must be detected")
        assert_eq(web.reddit_original_image_url("https://preview.redd.it/photo.jpeg?width=1080&format=pjpg"), "https://i.redd.it/photo.jpeg", "Reddit preview URL must resolve to original media")
        assert_eq(web.reddit_original_image_url("https://i.redd.it/photo.jpeg"), nil, "original Reddit media URL must remain unchanged")
        local error_doc = web.render_html_to_document(web.image_error_html("https://images.example/photo.jpg", "HTTP 403 Forbidden (CDN error 54113)"), "https://images.example/photo.jpg", 80)
        assert_true(table.concat(error_doc.lines, "\n"):find("CDN error 54113"), "image errors must render as a readable page")
        assert_true(web.show_image_preview ~= nil, "image preview must download before rendering")
        local rows, top, left, width, height = web.build_image_overlay("line 1\nline 2", "https://example.com/a.png", 80, 24)
        assert_true(rows[1] == "Image Preview" and top > 1 and left > 1, "image preview must be centered in an overlay")
        assert_true(width <= 76 and height <= 22, "image overlay must fit the terminal")
        assert_true(web.show_image_preview ~= nil, "image preview must wait for an explicit close key")
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

    TestRunner.it("should format HTML5 details, summary, and definition lists", function()
        local html = [[
            <main>
                <details>
                    <summary>Advanced Configuration</summary>
                    <p>Options details here.</p>
                </details>
                <dl>
                    <dt>CPU</dt>
                    <dd>Central Processing Unit</dd>
                    <dt>RAM</dt>
                    <dd>Random Access Memory</dd>
                </dl>
            </main>
        ]]
        local doc = web.render_html_to_document(html, "https://example.com", 80)
        local text = table.concat(doc.lines, "\n")
        assert_true(text:find("▶ Advanced Configuration"), "summary must render with disclosure symbol")
        assert_true(text:find("Options details here"), "details content must be preserved")
        assert_true(text:find("• CPU:"), "dt must render with bullet and colon")
        assert_true(text:find("Central Processing Unit"), "dd text must be rendered")
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
        assert_eq(b.doc.title, "weblite: Help & Keybindings")

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
        local cjk_text = "欢迎使用weblite终端网页浏览器，这是一个纯LuaJIT编写的高性能极简浏览器，支持Vim全键盘导航。"
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

-- 6. Page Cache & Navigation History Memory
TestRunner.describe("6. Page Cache & Navigation History Memory", function()
    TestRunner.it("should restore previous page scroll position and doc from cache on history back", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")
        assert_eq(b.url, "about:home")

        -- Scroll down on home page
        b.scroll_y = 12
        b.selected_link_idx = 3

        -- Navigate to about:help
        b:navigate_to("about:help")
        assert_eq(b.url, "about:help")
        assert_eq(b.scroll_y, 1, "new page starts at top")

        -- Go back to about:home via 'H'
        b:handle_key("H")
        assert_eq(b.url, "about:home", "history back should return to about:home")
        assert_eq(b.scroll_y, 12, "cached page should restore exact scroll position")
        assert_eq(b.selected_link_idx, 3, "cached page should restore focused link index")

        -- Go forward to about:help via 'L'
        b:handle_key("L")
        assert_eq(b.url, "about:help", "history forward should return to about:help")
    end)

    TestRunner.it("should invalidate cache on reload (r)", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")
        assert_true(b.page_cache ~= nil)
        b.scroll_y = 15

        -- Trigger reload
        b:handle_key("r")
        assert_eq(b.scroll_y, 1, "reloading page resets scroll to line 1")
    end)
end)

-- 7. Local Bookmarks Management
TestRunner.describe("7. Local Bookmarks Management", function()
    local test_url = "https://example.com/test-bookmark-" .. os.time()
    local test_title = "Test Bookmark Title"

    TestRunner.it("should resolve 'b' and 'bookmarks' to about:bookmarks", function()
        local r1, m1 = web.smart_resolve_input("b")
        assert_eq(r1, "about:bookmarks")
        assert_eq(m1, "about")

        local r2, m2 = web.smart_resolve_input("bookmarks")
        assert_eq(r2, "about:bookmarks")
        assert_eq(m2, "about")
    end)

    TestRunner.it("should add, persist, and load bookmarks", function()
        local ok, action = web.add_bookmark(test_url, test_title)
        assert_true(ok, "bookmark should be added successfully")

        local bms = web.load_bookmarks()
        local found = false
        for _, b in ipairs(bms) do
            if b.url == test_url and b.title == test_title then
                found = true
                break
            end
        end
        assert_true(found, "added bookmark must be retrieved from saved file")
    end)

    TestRunner.it("should render bookmarks into about:bookmarks HTML page", function()
        local html = web.get_bookmarks_page_html()
        assert_true(html:find(test_url, 1, true) ~= nil, "bookmarks HTML should contain added URL")
        assert_true(html:find(test_title, 1, true) ~= nil, "bookmarks HTML should contain added title")
    end)

    TestRunner.it("should bookmark current page via 'm' key in Normal mode", function()
        local b = web.Browser.new("about:help")
        b:load_url("about:help")
        b:handle_key("m")
        assert_true(b.status_msg:find("Bookmarked:"), "status should confirm bookmark")

        local bms = web.load_bookmarks()
        local found = false
        for _, bm in ipairs(bms) do
            if bm.url == "about:help" then
                found = true
                break
            end
        end
        assert_true(found, "about:help should be saved in bookmarks")
    end)

    TestRunner.it("should navigate to bookmarks via 'gb'", function()
        local b = web.Browser.new("about:help")
        b:load_url("about:help")
        b:handle_key("g")
        b:handle_key("b")
        assert_eq(b.url, "about:bookmarks", "'gb' must navigate to about:bookmarks")
    end)

    TestRunner.it("should clean up test bookmark", function()
        local removed = web.remove_bookmark(test_url)
        assert_true(removed, "remove_bookmark should remove the test entry")
    end)

    TestRunner.it("should sanitize bookmark titles with newlines and tabs", function()
        local test_dirty_url = "https://example.com/dirty"
        local test_dirty_title = "Dirty\tTitle\nWith\rNewlines"
        web.add_bookmark(test_dirty_url, test_dirty_title)
        local bms = web.load_bookmarks()
        local matched = false
        for _, bm in ipairs(bms) do
            if bm.url == test_dirty_url then
                assert_true(not bm.title:find("[\t\r\n]"), "bookmark title must not contain newlines or tabs")
                matched = true
                break
            end
        end
        assert_true(matched, "sanitized bookmark must be found")
        web.remove_bookmark(test_dirty_url)
    end)
end)

-- 8. Document Export (:w)
TestRunner.describe("8. Document Export (:w)", function()
    local text_export_file = "test_export_dump.txt"
    local html_export_file = "test_export_dump.html"

    TestRunner.it("should export formatted document to plain text file via :w <file>", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        b:handle_key(":")
        local cmd = "w " .. text_export_file
        for c in cmd:gmatch(".") do b:handle_key(c) end
        b:handle_key("ENTER")

        local f = io.open(text_export_file, "r")
        assert_true(f ~= nil, "exported text file must exist")
        local content = f:read("*a")
        f:close()
        os.remove(text_export_file)

        assert_true(content:find("weblite"), "exported file should contain document text")
        assert_true(content:find("Hacker News"), "exported file should contain link names")
    end)

    TestRunner.it("should export raw HTML when filename ends with .html", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        b:handle_key(":")
        local cmd = "w " .. html_export_file
        for c in cmd:gmatch(".") do b:handle_key(c) end
        b:handle_key("ENTER")

        local f = io.open(html_export_file, "r")
        assert_true(f ~= nil, "exported html file must exist")
        local content = f:read("*a")
        f:close()
        os.remove(html_export_file)

        assert_true(content:find("<!DOCTYPE html>") or content:find("<html"), "exported html file should contain HTML tags")
    end)
end)

-- 9. Numeric Link Jump & View Centering
TestRunner.describe("9. Numeric Link Jump & View Centering", function()
    TestRunner.it("should follow link directly via <number> ENTER", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        -- Link [2] on home page is Hacker News
        local target_href = b.doc.links[2].href
        assert_true(target_href ~= nil)

        -- Type '2' then ENTER
        b:handle_key("2")
        assert_eq(b.count_prefix, 2)
        b:handle_key("ENTER")

        assert_eq(b.url, target_href, "typing 2+ENTER must follow link 2")
    end)

    TestRunner.it("should follow link directly via :<number> command", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        local target_href = b.doc.links[1].href
        b:handle_key(":")
        b:handle_key("1")
        b:handle_key("ENTER")

        assert_eq(b.url, target_href, "command :1 must navigate to link 1")
    end)

    TestRunner.it("should center view vertically via 'zz'", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")
        b.scroll_y = 20

        b:handle_key("z")
        b:handle_key("z")
        assert_true(b.status_msg:find("Centered"), "'zz' should set status message Centered")
    end)

    TestRunner.it("should center search results with vertical offset", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        b:handle_key("/")
        for c in string.gmatch("Hacker", ".") do b:handle_key(c) end
        b:handle_key("ENTER")

        assert_true(#b.search_matches > 0)
        local match_line = b.search_matches[1]
        assert_true(b.scroll_y <= match_line, "search centering scroll_y must be at or above match line")
    end)
end)

-- 10. Dynamic Terminal Resize Reflow
TestRunner.describe("10. Dynamic Terminal Resize Reflow", function()
    TestRunner.it("should reflow document when terminal width changes", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        local orig_line_count = #b.doc.lines
        -- Reflow to a narrow 40-column width
        b:reflow(40)
        local narrow_line_count = #b.doc.lines

        -- Narrower width should cause more wrapped lines
        assert_true(narrow_line_count > orig_line_count, "narrower width should increase total wrapped lines")

        -- Reflow back to 100 columns
        b:reflow(100)
        assert_true(#b.doc.lines < narrow_line_count, "wider width should decrease total wrapped lines")
    end)
end)

-- 11. Hyperlink Yanking & Yank Hint Mode (yl, yf, :yl)
TestRunner.describe("11. Hyperlink Yanking & Yank Hint Mode", function()
    TestRunner.it("should yank focused hyperlink URL via 'yl'", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")
        b.selected_link_idx = 2
        local target_href = b.doc.links[2].href
        assert_true(target_href ~= nil)

        b:handle_key("y")
        b:handle_key("l")
        assert_true(b.status_msg:find("Yanked link to clipboard"), "'yl' must report yanking link to clipboard")
        assert_true(b.status_msg:find(target_href:sub(1, 15), 1, true), "status msg must contain target URL prefix")
    end)

    TestRunner.it("should activate Yank Hint mode via 'yf' and copy chosen link", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        b:handle_key("y")
        b:handle_key("f")
        assert_eq(b.mode, "HINT", "'yf' must enter HINT mode")
        assert_eq(b.hint_action, "YANK", "hint_action must be set to YANK")

        b:build_hints(25)
        assert_true(b.hint_map["A"] ~= nil, "hint 'A' must be available")
        local chosen_link_idx = b.hint_map["A"]
        local chosen_href = b.doc.links[chosen_link_idx].href

        b:handle_key("A")
        assert_eq(b.mode, "NORMAL", "after selecting hint, mode returns to NORMAL")
        assert_true(b.status_msg:find("Yanked link to clipboard"))
        assert_true(b.status_msg:find(chosen_href:sub(1, 15), 1, true))
    end)

    TestRunner.it("should yank focused link via ':yl' command", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")
        b.selected_link_idx = 1

        b:handle_key(":")
        b:handle_key("y")
        b:handle_key("l")
        b:handle_key("ENTER")
        assert_true(b.status_msg:find("Yanked link to clipboard"), "':yl' must yank focused link")
    end)
end)

-- 12. Heading Jump Navigation & Table of Contents (}, {, ]], [[, :toc)
TestRunner.describe("12. Heading Jump Navigation & Table of Contents", function()
    TestRunner.it("should extract headings hierarchy and line positions into doc.headings", function()
        local html = "<h1>Main Heading</h1><p>Para 1</p><p>Para 2</p><h2>Section One</h2><p>Content</p><h3>Subsection</h3>"
        local doc = web.render_html_to_document(html, "https://example.com/test", 80)

        assert_eq(#doc.headings, 3, "should extract 3 headings")
        assert_eq(doc.headings[1].level, 1)
        assert_eq(doc.headings[1].text, "Main Heading")
        assert_eq(doc.headings[2].level, 2)
        assert_eq(doc.headings[2].text, "Section One")
        assert_eq(doc.headings[3].level, 3)
        assert_eq(doc.headings[3].text, "Subsection")
        assert_true(doc.headings[1].line_idx < doc.headings[2].line_idx, "h1 must appear before h2")
        assert_true(doc.headings[2].line_idx < doc.headings[3].line_idx, "h2 must appear before h3")
    end)

    TestRunner.it("should jump between headings using '}' and '{'", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")
        assert_true(#b.doc.headings >= 2, "about:home should have multiple headings")

        b.scroll_y = 1
        b:handle_key("}")
        assert_true(b.scroll_y > 1, "'}' should advance scroll_y to next heading")
        local first_heading_scroll = b.scroll_y

        b:handle_key("}")
        assert_true(b.scroll_y > first_heading_scroll, "subsequent '}' should advance to next heading")

        b:handle_key("{")
        assert_eq(b.scroll_y, first_heading_scroll, "'{' should jump backward to previous heading")
    end)

    TestRunner.it("should jump between headings using ']]' and '[['", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        b.scroll_y = 1
        b:handle_key("]]")
        assert_true(b.scroll_y > 1, "']]' should jump to next heading")
        b:handle_key("[[")
        assert_eq(b.scroll_y, 1, "'[[' should jump back to top heading")
    end)

    TestRunner.it("should display Table of Contents via ':toc' and return via 'H'", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        b:handle_key(":")
        b:handle_key("t")
        b:handle_key("o")
        b:handle_key("c")
        b:handle_key("ENTER")

        assert_eq(b.url, "about:toc", "':toc' must navigate to about:toc")
        assert_true(b.doc.title:find("Table of Contents"), "doc title must be Table of Contents")
        assert_true(#b.doc.links > 0, "TOC should contain return links")

        -- Press 'H' to return to previous page
        b:handle_key("H")
        assert_eq(b.url, "about:home", "'H' from TOC must restore original page")
    end)

    TestRunner.it("should match mixed-case heading tags", function()
        local html = "<H1>Upper Heading</h1><H2>Second Upper</h2>"
        local doc = web.render_html_to_document(html, "https://example.com/test", 80)
        assert_eq(#doc.headings, 2, "must extract mixed-case headings")
        assert_eq(doc.headings[1].text, "Upper Heading")
        assert_eq(doc.headings[2].text, "Second Upper")
    end)

    TestRunner.it("should extract hyperlinks embedded inside heading tags", function()
        local html = "<h2><a href=\"https://news.ycombinator.com/item?id=123\">Linked Heading Title</a></h2>"
        local doc = web.render_html_to_document(html, "https://news.ycombinator.com", 80)
        assert_eq(#doc.links, 1, "heading hyperlink must be extracted into doc.links")
        assert_eq(doc.links[1].href, "https://news.ycombinator.com/item?id=123")
        assert_eq(doc.links[1].text, "Linked Heading Title")
        assert_true(doc.headings[1].text:find("Linked Heading Title %[1%]"), "heading text should display link badge [1]")
    end)
end)

-- 13. Image Link Extraction & Media Inspection
TestRunner.describe("13. Image Link Extraction & Media Inspection", function()
    TestRunner.it("should parse <img> tags into hyperlinks with [IMG: alt] badges", function()
        local html = "<p>Architecture diagram:</p><img src=\"system_arch.png\" alt=\"System Architecture\"><p><img src=\"https://example.com/badge.svg\"></p>"
        local doc = web.render_html_to_document(html, "https://skyera.org/docs/index.html", 80)

        assert_true(#doc.links >= 2, "must extract image tags as hyperlinks")
        assert_eq(doc.links[1].text, "[IMG: System Architecture]")
        assert_eq(doc.links[1].href, "https://skyera.org/docs/system_arch.png", "relative image path must be resolved")
        assert_eq(doc.links[1].is_image, true, "is_image flag must be true")

        assert_eq(doc.links[2].text, "[IMG: Image 2]", "empty alt attribute should fallback to Image N")
        assert_eq(doc.links[2].href, "https://example.com/badge.svg")
        assert_eq(doc.links[2].is_image, true)
    end)

    TestRunner.it("should allow focusing image links with TAB and opening with gx", function()
        local b = web.Browser.new("https://skyera.org/demo")
        local html = "<h1>Title</h1><p><img src=\"https://example.com/diagram.png\" alt=\"Workflow\"></p>"
        b.raw_html = html
        b.doc = web.render_html_to_document(html, "https://skyera.org/demo", 80)
        assert_eq(#b.doc.links, 1)

        b:handle_key("TAB")
        assert_eq(b.selected_link_idx, 1)
        assert_eq(b.doc.links[1].text, "[IMG: Workflow]")
    end)
end)

-- 14. Persistent Browsing History (about:history, :history, gH)
TestRunner.describe("14. Persistent Browsing History", function()
    local test_hist_file = web.get_history_file_path() .. ".test_suite.txt"

    TestRunner.it("should persist and load browsing history records", function()
        os.remove(test_hist_file)
        web.add_history_entry("https://news.ycombinator.com", "Hacker News", test_hist_file)
        web.add_history_entry("https://luajit.org", "LuaJIT Site", test_hist_file)

        local items = web.load_history(10, test_hist_file)
        assert_true(#items >= 2, "must load at least 2 history records")
        assert_eq(items[1].url, "https://luajit.org", "most recent history item must be first")
        assert_eq(items[1].title, "LuaJIT Site")
        assert_eq(items[2].url, "https://news.ycombinator.com")
        os.remove(test_hist_file)
    end)

    TestRunner.it("should render about:history page with clickable hyperlinks", function()
        os.remove(test_hist_file)
        web.add_history_entry("https://example.com/article", "Example Article", test_hist_file)

        local html = web.get_history_page_html(test_hist_file)
        assert_true(html:find("Browsing History"), "HTML must contain history title")
        local doc = web.render_html_to_document(html, "about:history", 80)
        assert_true(doc.title:find("History"))
        assert_true(#doc.links > 0, "about:history must contain extracted links")
        os.remove(test_hist_file)
    end)

    TestRunner.it("should navigate to about:history via 'gH' and ':history'", function()
        local b = web.Browser.new("about:home")
        b:load_url("about:home")

        b:handle_key("g")
        b:handle_key("H")
        assert_eq(b.url, "about:history", "'gH' shortcut must navigate to about:history")

        b:navigate_to("about:home")
        b:handle_key(":")
        for c in string.gmatch("history", ".") do b:handle_key(c) end
        b:handle_key("ENTER")
        assert_eq(b.url, "about:history", "':history' command must navigate to about:history")
    end)
end)

-- 15. Distraction-Free Reader Mode (gr, :reader)
TestRunner.describe("15. Distraction-Free Reader Mode", function()
    local noisy_html = [[
<!DOCTYPE html>
<html>
<head><title>Clean News Article</title></head>
<body>
  <header><h1>Site Logo</h1><nav><a href="/home">Home</a> | <a href="/login">Login</a></nav></header>
  <aside><div class="ad">Buy our product now!</div></aside>
  <article>
    <h1>The Power of Minimalist Terminal Browsers</h1>
    <p>This is the core article content that readers truly care about without any distracting ads.</p>
  </article>
  <footer><p>Copyright 2026 Corporation. All rights reserved.</p></footer>
</body>
</html>
]]

    TestRunner.it("should filter out header, nav, aside, footer in reader mode", function()
        local doc_normal = web.render_html_to_document(noisy_html, "https://news.com/post/1", 80, false)
        local normal_str = table.concat(doc_normal.lines, " ")
        assert_true(normal_str:find("Buy our product"), "normal mode must contain ads and aside")
        assert_true(normal_str:find("Site Logo"), "normal mode must contain header")

        local doc_reader = web.render_html_to_document(noisy_html, "https://news.com/post/1", 80, true)
        local reader_str = table.concat(doc_reader.lines, " ")
        assert_true(reader_str:find("The Power of Minimalist Terminal Browsers"), "reader mode must preserve article title")
        assert_true(reader_str:find("core article content"), "reader mode must preserve article body")
        assert_true(not reader_str:find("Buy our product"), "reader mode must filter aside/ads")
        assert_true(not reader_str:find("Site Logo"), "reader mode must filter header")
    end)

    TestRunner.it("should toggle reader mode in Browser via 'gr' and ':reader'", function()
        local b = web.Browser.new("https://news.com/post/1")
        b.raw_html = noisy_html
        b.doc = web.render_html_to_document(noisy_html, "https://news.com/post/1", 80, false)
        assert_eq(b.reader_mode, false)

        -- Toggle ON with 'gr'
        b:handle_key("g")
        b:handle_key("r")
        assert_eq(b.reader_mode, true, "'gr' must toggle reader_mode to true")
        assert_true(b.status_msg:find("Reader mode: ON"))

        -- Toggle OFF with ':reader'
        b:handle_key(":")
        for c in string.gmatch("reader", ".") do b:handle_key(c) end
        b:handle_key("ENTER")
        assert_eq(b.reader_mode, false, "':reader' must toggle reader_mode back to false")
        assert_true(b.status_msg:find("Reader mode: OFF"))
    end)
end)

print(string.format("\n========================================="))
print(string.format("Test Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.format("=========================================\n"))

if TestRunner.failed > 0 then
    os.exit(1)
end
os.exit(0)
