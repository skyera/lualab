#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_zim.lua
-- Unit tests for Zim Desktop Wiki to Leaf Wiki Markdown converter & importer
--------------------------------------------------------------------------------

local root = (arg[0]:gsub('\\', '/'):match('^(.*)/') or '.') .. '/../..'
package.path = root .. '/wiki_web/?.lua;' .. root .. '/dictionary_web/?.lua;' .. root .. '/?.lua;' .. package.path

local zim = require('zim')
local ffi = require('ffi')

local tests_run = 0
local tests_passed = 0

local function test(name, fn)
    tests_run = tests_run + 1
    io.write('Testing: ' .. name .. ' ... ')
    local ok, err = pcall(fn)
    if ok then
        tests_passed = tests_passed + 1
        print('PASS')
    else
        print('FAIL')
        print('  Error: ' .. tostring(err))
        error(err)
    end
end

--------------------------------------------------------------------------------
-- 1. Header Stripping Tests
--------------------------------------------------------------------------------
test('strips Zim RFC822 headers and preserves plain text without headers', function()
    local zim_header = [[Content-Type: text/x-zim-wiki
Wiki-Format: zim 0.4
Creation-Date: 2026-10-15T09:00:00+00:00

====== Home Page ======
This is the content.
]]
    local converted = zim.convert_text(zim_header, 'Home')
    assert(not converted:find('Content-Type'), 'Header must be stripped')
    assert(not converted:find('Wiki-Format'), 'Wiki-Format must be stripped')
    assert(converted:find('# Home Page'), 'Title heading should remain')
    assert(converted:find('This is the content%.'), 'Content should remain')

    local plain = 'Just some plain text without headers.'
    local plain_converted = zim.convert_text(plain, 'Home')
    assert(plain_converted:find('Just some plain text'), 'Plain text without header should be preserved')
end)

--------------------------------------------------------------------------------
-- 2. Headings Inversion Tests
--------------------------------------------------------------------------------
test('inverts Zim symmetric equals headings to standard Markdown levels', function()
    local input = [[
====== Heading 1 ======
===== Heading 2 =====
==== Heading 3 ====
=== Heading 4 ===
== Heading 5 ==
]]
    local output = zim.convert_text(input, 'Test')
    assert(output:find('# Heading 1\n'), 'H1 should have 1 hash')
    assert(output:find('## Heading 2\n'), 'H2 should have 2 hashes')
    assert(output:find('### Heading 3\n'), 'H3 should have 3 hashes')
    assert(output:find('#### Heading 4\n'), 'H4 should have 4 hashes')
    assert(output:find('##### Heading 5\n'), 'H5 should have 5 hashes')
end)

--------------------------------------------------------------------------------
-- 3. Verbatim & Code Block Protection Tests
--------------------------------------------------------------------------------
test('preserves verbatim code blocks and prevents internal syntax conversion', function()
    local input = [[
Here is a code block:
'''python
def test():
    # //not italic//
    url = "https://example.com"
    return [ ]
'''
And inline ''code with //slash//''.
]]
    local output = zim.convert_text(input, 'CodePage')
    assert(output:find('```python\ndef test%(%):'), 'Code block should use markdown backticks')
    assert(output:find('//not italic//'), 'Verbatim content must preserve raw text without converting italic')
    assert(output:find('`code with //slash//`'), 'Inline verbatim should convert to backticks')
end)

--------------------------------------------------------------------------------
-- 4. Inline Styles Tests
--------------------------------------------------------------------------------
test('converts inline italic, bold, strikethrough, sub and super', function()
    local input = 'Text with **bold**, //italic//, ~~strikethrough~~, ^{sup}, and _{sub}. Also https://github.com link.'
    local output = zim.convert_text(input, 'Styles')
    assert(output:find('%*%*bold%*%*'), 'Bold should be preserved')
    assert(output:find('%*italic%*'), 'Italic // should convert to *')
    assert(output:find('~~strikethrough~~'), 'Strikethrough should be preserved')
    assert(output:find('<sup>sup</sup>'), 'Superscript conversion')
    assert(output:find('<sub>sub</sub>'), 'Subscript conversion')
    assert(output:find('https://github%.com'), 'URLs should not have their slashes converted to italic')
end)

--------------------------------------------------------------------------------
-- 5. Tasks and Lists Tests
--------------------------------------------------------------------------------
test('converts Zim checkboxes, bullets, and numbered items to Markdown checklist', function()
    local input = [[
[ ] Open task
[*] In-progress task
[x] Finished task
[X] Another finished task
[-] Cancelled task
[>] Delegated task
* Bullet one
	* Indented bullet
1. Numbered item
]]
    local output = zim.convert_text(input, 'Tasks')
    assert(output:find('%- %[ %] Open task'), 'Open task [ ]')
    assert(output:find('%- %[ %] In%-progress task'), 'In-progress task [*]')
    assert(output:find('%- %[x%] Finished task'), 'Finished task [x]')
    assert(output:find('%- %[x%] Another finished task'), 'Finished task [X]')
    assert(output:find('%- %[x%] Cancelled task'), 'Cancelled task [-]')
    assert(output:find('%- %[ %] Delegated task'), 'Delegated task [>]')
    assert(output:find('%- Bullet one'), 'Bullet conversion')
    assert(output:find('  %- Indented bullet'), 'Indented bullet conversion')
    assert(output:find('1%. Numbered item'), 'Numbered item preservation')
end)

--------------------------------------------------------------------------------
-- 6. Wiki Links & External Links Tests
--------------------------------------------------------------------------------
test('converts Zim wiki links, namespaces, subpages and web links', function()
    local input = [=[
Link to [[Page]] and [[Page|Custom Label]].
Subpage link to [[+SubPage]] or [[+SubPage|Sub Label]].
Absolute link to [[:RootPage]].
Namespace link to [[Projects:Wiki:Design]].
Web link to [[https://github.com/skyera/lualab|LuaLab]].
Bare web link to [[https://www.lua.org]].
]=]
    local output = zim.convert_text(input, 'Links')
    assert(output:find('%[%[Page%]%]'), 'Simple wiki link')
    assert(output:find('%[%[Page|Custom Label%]%]'), 'Wiki link with label')
    assert(output:find('%[%[%./SubPage%]%]'), 'Subpage link [[+SubPage]] -> [[./SubPage]]')
    assert(output:find('%[%[%./SubPage|Sub Label%]%]'), 'Subpage link with label')
    assert(output:find('%[%[RootPage%]%]'), 'Absolute link [[:RootPage]] -> [[RootPage]]')
    assert(output:find('%[%[Projects/Wiki/Design%]%]'), 'Namespace colons to slashes')
    assert(output:find('%[LuaLab%]%(https://github%.com/skyera/lualab%)'), 'External link with label')
    assert(output:find('https://www%.lua%.org'), 'Bare external link')
end)

--------------------------------------------------------------------------------
-- 7. Images & Attachments Tests
--------------------------------------------------------------------------------
test('converts Zim image syntax to Leaf Wiki attachment format with width tags', function()
    local input = [[
{{sketch.png}}
{{./architecture.png?width=280}}
{{diagram.png?width=500&height=300}}
{{banner.jpg?width=1200}}
]]
    local output = zim.convert_text(input, 'Projects/Roadmap')
    assert(output:find('!%[sketch%.png%]%(Roadmap%.attachments/sketch%.png%)'), 'Basic image')
    assert(output:find('!%[architecture%.png%]%(Roadmap%.attachments/architecture%.png%){width=small}'), 'Small image')
    assert(output:find('!%[diagram%.png%]%(Roadmap%.attachments/diagram%.png%){width=medium}'), 'Medium image')
    assert(output:find('!%[banner%.jpg%]%(Roadmap%.attachments/banner%.jpg%){width=full}'), 'Full width image')
end)

--------------------------------------------------------------------------------
-- 8. End-to-End Zim Notebook Migration Test
--------------------------------------------------------------------------------
test('imports entire Zim notebook directory tree with attachments into Leaf Wiki', function()
    local tmp_base = os.getenv('TEMP') or os.getenv('TMP') or '/tmp'
    tmp_base = tmp_base:gsub('\\', '/')
    local zim_dir = tmp_base .. '/zim_test_src_' .. os.time()
    local leaf_dir = tmp_base .. '/zim_test_dst_' .. os.time()

    local function write_raw(path, content)
        local dir = path:match('^(.*)/[^/]+$')
        if dir then os.execute('mkdir "' .. dir:gsub('/', '\\') .. '" 2>nul') end
        local f = assert(io.open(path, 'wb'))
        f:write(content)
        f:close()
    end

    -- Create Zim structure
    write_raw(zim_dir .. '/notebook.zim', '[Notebook]\nname=Sample Zim Wiki\nhome=Home\n')
    write_raw(zim_dir .. '/Home.txt', 'Content-Type: text/x-zim-wiki\n\n====== Home ======\nWelcome to [[Projects:Roadmap]].\n')
    write_raw(zim_dir .. '/Projects/Roadmap.txt', 'Content-Type: text/x-zim-wiki\n\n====== Roadmap ======\n[ ] Ship importer\n{{./flow.png}}\n')
    write_raw(zim_dir .. '/Projects/flow.png', '\137PNG\r\n\26\nfake_png_data')

    local progress_msgs = {}
    local result = zim.import_notebook(zim_dir, leaf_dir, {
        progress = function(m) progress_msgs[#progress_msgs + 1] = m end
    })

    assert(result.pages_converted == 2, 'Should convert 2 pages, got: ' .. result.pages_converted)
    assert(result.images_copied == 1, 'Should copy 1 image, got: ' .. result.images_copied)
    assert(#result.errors == 0, 'Should have 0 errors')
    assert(result.metadata.name == 'Sample Zim Wiki', 'Metadata name should match')

    -- Verify generated files
    local home_f = io.open(leaf_dir .. '/Home.md', 'r')
    assert(home_f, 'Home.md must exist')
    local home_content = home_f:read('*all')
    home_f:close()
    assert(home_content:find('# Home'), 'Home.md should have converted title')
    assert(home_content:find('%[%[Projects/Roadmap%]%]'), 'Wiki link in Home.md')

    local roadmap_f = io.open(leaf_dir .. '/Projects/Roadmap.md', 'r')
    assert(roadmap_f, 'Projects/Roadmap.md must exist')
    local roadmap_content = roadmap_f:read('*all')
    roadmap_f:close()
    assert(roadmap_content:find('%- %[ %] Ship importer'), 'Task in Roadmap.md')
    assert(roadmap_content:find('!%[flow%.png%]%(Roadmap%.attachments/flow%.png%)'), 'Image link in Roadmap.md')

    local img_f = io.open(leaf_dir .. '/Projects/Roadmap.attachments/flow.png', 'rb')
    assert(img_f, 'Attachment image must exist in Roadmap.attachments')
    local img_bytes = img_f:read('*all')
    img_f:close()
    assert(img_bytes == '\137PNG\r\n\26\nfake_png_data', 'Image content must match')

    -- Cleanup test directories
    os.execute('rmdir /s /q "' .. zim_dir:gsub('/', '\\') .. '" 2>nul')
    os.execute('rmdir /s /q "' .. leaf_dir:gsub('/', '\\') .. '" 2>nul')
end)

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------
print('')
print(string.format('All %d Zim importer tests PASSED!', tests_passed))
