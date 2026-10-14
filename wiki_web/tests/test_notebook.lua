#!/usr/bin/env luajit
-- Temporary-notebook verification of files, links, conflicts and maintenance recovery.
local root = (arg[0]:gsub('\\', '/'):match('^(.*)/') or '.') .. '/../..'
package.path = root .. '/wiki_web/?.lua;' .. root .. '/dictionary_web/?.lua;' .. root .. '/?.lua;' .. package.path
local Notebook = require('notebook')
local links = require('links')
local json = require('json')
local ffi = require('ffi')
if ffi.os ~= 'Windows' then ffi.cdef[[int symlink(const char *, const char *);]] end
local managed = arg[1] and arg[1]:gsub('\\', '/')
assert(ffi.os ~= 'Windows' or managed, 'On Windows run node --test wiki_web/tests/test_http.js')
local serial = 0
local count = 0
local function fixture(run)
    serial = serial + 1
    local directory = managed and managed .. '/notebook-' .. serial or os.tmpname()
    local cache = managed and managed .. '/cache-' .. serial or os.tmpname()
    if not managed then os.remove(directory); os.remove(cache) end
    local notebook = Notebook.open(directory, cache)
    local ok, err = pcall(run, notebook, directory, cache)
    notebook:close()
    if not managed then os.execute("rm -rf -- '" .. directory .. "' '" .. cache .. "'") end
    assert(ok, err)
end
local function test(name, run)
    local ok, err = pcall(run)
    assert(ok, name .. ': ' .. tostring(err))
    count = count + 1; print('ok ' .. count .. ' - ' .. name)
end

test('attachment listing excludes unsafe files and code-only references', function()
    fixture(function(n, directory)
        local page = assert(n:save('Notes/学习', '# Images', ''))
        local image = n:image(page.id, '\137PNG\r\n\26\nbytes')
        n.fs:write(page.id .. '.attachments/manual.jpg', '\255\216\255')
        n.fs:write(page.id .. '.attachments/ignored.svg', '<svg/>')
        local content = image.markdown .. '\n![missing](学习.attachments/missing.webp)\n'
            .. '`![code](学习.attachments/code.gif)`'
        assert(n:save(page.id, content, page.revision))
        local rows = n:attachments().attachments
        assert(#rows == 3)
        local found = {}
        for _, row in ipairs(rows) do found[row.file] = row end
        assert(found[image.file].referenced and found[image.file].bytes == 13)
        assert(not found['manual.jpg'].referenced and found['manual.jpg'].bytes == 3)
        assert(found['missing.webp'].missing)
        if ffi.os ~= 'Windows' then
            local target = directory .. '/' .. page.id .. '.attachments/unsafe.png'
            assert(ffi.C.symlink('/etc/passwd', target) == 0)
            rows = n:attachments().attachments
            assert(#rows == 3, 'Symlink attachments must not be listed')
        end
    end)
end)

test('nested Unicode pages, revision conflicts, external edits and rebuildable search', function()
    fixture(function(n)
        local page = assert(n:save('Projects/学习', '# Study\nSee [[Home]]. 100%_done', ''))
        assert(n:page(page.id).content == page.content)
        assert(n:backlinks('Home')[1].id == page.id)
        assert(#n:state('100%_').pages == 1 and #n:state('missing').pages == 0)
        n.fs:write(page.id .. '.md', '# External edit')
        local result, _, status = n:save(page.id, 'Stale text', page.revision)
        assert(not result and status == 409 and n:page(page.id).content == '# External edit')
        assert(#n:state('External').pages == 1 and #n:backlinks('Home') == 0)
        n.db:query('DELETE FROM pages'); n.db:query('DELETE FROM links')
        assert(#n:state().pages == 1)
        for _, id in ipairs({ '../escape', '/absolute', 'A//B', '.hidden', 'A/.leaf', 'A\\B', 'A#x', ' bad', 'bad ', '\255' }) do
            assert(not pcall(n.save, n, id, 'text', ''))
        end
        assert(not pcall(n.save, n, 'Bad', '\255', ''))
        assert(not pcall(n.save, n, 'Large', string.rep('x', 1024 * 1024 + 1), ''))
    end)
end)

test('wiki addresses and code boundaries agree with rename rewriting', function()
    local text = '[[./Tasks|Tasks]] [[../Other]] [[Home#section]]\n'
        .. '`[[Hidden]]` ``[[Hidden2]]``\n````lua\n[[Hidden3]]\n```\n[[Hidden4]]\n````\n'
        .. '    [[Hidden5]]\n[[Visible]]'
    local found = links.targets('Projects/Wiki/Design', text)
    assert(found['Projects/Wiki/Tasks'] and found['Projects/Other'] and found.Home and found.Visible)
    for index = 1, 5 do assert(not found[index == 1 and 'Hidden' or 'Hidden' .. index]) end
    assert(not links.resolve('Root', '../Outside'))
    local renamed = links.rename(text, 'Projects/Wiki/Design', 'Projects/Wiki/Tasks', 'New/Tasks')
    assert(renamed:find('[[New:Tasks|Tasks]]', 1, true))
    assert(renamed:find('`[[Hidden]]`', 1, true))
end)

test('notebook lock and symlink confinement protect external files', function()
    fixture(function(n, directory, cache)
        assert(not pcall(Notebook.open, directory, cache))
        assert(not pcall(Notebook.open, directory .. '/Other', directory .. '/Other/cache'))
        if ffi.os == 'Windows' then return end -- junction confinement is exercised by the Node integration test
        local outside = os.tmpname()
        local file = assert(io.open(outside, 'w')); file:write('outside'); file:close()
        assert(ffi.C.symlink(outside, directory .. '/Escape.md') == 0)
        assert(not pcall(n.page, n, 'Escape'))
        assert(not pcall(n.save, n, 'Escape', 'overwrite', ''))
        file = assert(io.open(outside)); assert(file:read('*a') == 'outside'); file:close()
        os.remove(outside)
        assert(ffi.C.symlink('/tmp', directory .. '/Linked') == 0)
        assert(not pcall(n.save, n, 'Linked/escape', 'overwrite', ''))
    end)
end)

test('image attachments survive renames, trash and restore with linked pages', function()
    fixture(function(n)
        local page = assert(n:save('Projects/Design', '[[./Tasks]]\n', ''))
        n:save('Refer', '[[Projects:Design|Design]] `[[Projects:Design]]`', '')
        local png = '\137PNG\r\n\26\nfixture'
        local image = n:image(page.id, png)
        page = assert(n:save(page.id, page.content .. image.markdown, page.revision))
        local again = n:image(page.id, png); assert(again.file == image.file)
        assert(n:attachment(page.id, image.file) == png)
        local renamed = assert(n:rename(page.id, 'New/Plan', page.revision))
        assert(renamed.content:find('[[Projects:Tasks]]', 1, true))
        assert(renamed.content:find('Plan.attachments/' .. image.file, 1, true))
        assert(n:attachment(renamed.id, image.file) == png and not n:page(page.id))
        assert(n:page('Refer').content == '[[New:Plan|Design]] `[[Projects:Design]]`')
        assert(n:trash(renamed.id, renamed.revision).deleted)
        assert(not n:page(renamed.id) and not n:attachment(renamed.id, image.file))
        local entries = n:trash_list(); assert(#entries == 1 and entries[1].attachments)
        local restored = assert(n:restore(entries[1].token))
        assert(restored.content == renamed.content and n:attachment(restored.id, image.file) == png)
        assert(#n:trash_list() == 0)
        assert(not pcall(n.image, n, restored.id, '<svg>unsafe</svg>'))
        assert(not pcall(n.attachment, n, restored.id, '../escape.png'))
        assert(not pcall(n.image, n, restored.id, string.rep('x', 5 * 1024 * 1024 + 1)))
    end)
end)

test('failed multi-file rename rolls back and interrupted transactions recover on startup', function()
    fixture(function(n, directory, cache)
        local page = assert(n:save('Old', 'Original', ''))
        n:save('Ref', '[[Old]]', '')
        local original, failed = n.fs.write, false
        n.fs.write = function(fs, path, text)
            if path == 'Ref.md' and not failed then failed = true; error('Injected disk failure') end
            return original(fs, path, text)
        end
        assert(not pcall(n.rename, n, 'Old', 'New', page.revision))
        n.fs.write = original
        assert(n:page('Old').content == 'Original' and not n:page('New') and n:page('Ref').content == '[[Old]]')
        n.fs:write('.leaf/transaction.json', json.encode({ files = {
            { id = 'Old', before = 'Original', after = 'Interrupted' },
        } }))
        n.fs:write('Old.md', 'Interrupted')
        n:close()
        local reopened = Notebook.open(directory, cache)
        assert(reopened:page('Old').content == 'Original')
        reopened:close()
    end)
end)

test('trash collision never overwrites a newly created page and restore failures roll back', function()
    fixture(function(n)
        local old = assert(n:save('Page', 'Original', ''))
        n:trash('Page', old.revision)
        n:save('Page', 'New page', '')
        local token = n:trash_list()[1].token
        local result, _, status = n:restore(token)
        assert(not result and status == 409 and n:page('Page').content == 'New page')
        n.fs:remove('Page.md')
        local original, failed = n.fs.write, false
        n.fs.write = function(fs, path, text)
            if path == 'Page.md' and not failed then failed = true; error('Injected write failure') end
            return original(fs, path, text)
        end
        assert(not pcall(n.restore, n, token))
        n.fs.write = original
        assert(not n:page('Page') and #n:trash_list() == 1)
        assert(n:restore(token).content == 'Original')
    end)
end)

test('known SHA-256 vectors and Windows aliases are rejected', function()
    local hash = require('hash')
    assert(hash.sha256('') == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    assert(hash.sha256('abc') == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    if ffi.os ~= 'Windows' then return end
    fixture(function(n, directory, cache)
        for _, id in ipairs({ 'CON', 'nul', 'Aux.txt', 'COM1', 'LPT9', 'bad.', 'bad*', 'bad?', 'bad<', 'A:stream' }) do
            assert(not pcall(n.save, n, id, 'text', ''))
        end
        n:save('Page', 'original', '')
        assert(not pcall(n.save, n, 'page', 'overwrite', ''))
        assert(n:page('Page').content == 'original')
        n:close()
        assert(not pcall(Notebook.open, directory:upper(), (directory .. '/CACHE'):upper()))
        local reopened = Notebook.open(directory, cache)
        assert(reopened:page('Page').content == 'original')
        reopened:close()
    end)
end)
test('history snapshots survive restore, restart, cache loss, rename and trash', function()
    fixture(function(n, directory, cache)
        local first = n:save('Projects/学习', 'First [[./Tasks]]', '')
        assert(#n:versions(first.id).versions == 0)
        local second = n:save(first.id, 'Second', first.revision)
        assert(#n:versions(first.id).versions == 1)
        assert(n:version(first.id, first.revision).content == first.content)
        n:save(first.id, second.content, second.revision)
        assert(#n:versions(first.id).versions == 1, 'No-op save added history')
        local result, _, status = n:restore_version(first.id, first.revision, 'stale')
        assert(not result and status == 409 and n:page(first.id).content == 'Second')
        local restored = n:restore_version(first.id, first.revision, second.revision)
        assert(restored.content == first.content and n:version(first.id, second.revision).content == 'Second')
        n.db:query('DELETE FROM pages')
        assert(#n:versions(first.id).versions == 2)
        local renamed = n:rename(first.id, 'New/Plan', restored.revision)
        assert(n:version(renamed.id, second.revision).content == 'Second')
        n:trash(renamed.id, renamed.revision)
        renamed = n:restore(n:trash_list()[1].token)
        n:close()
        local reopened = Notebook.open(directory, cache)
        assert(#reopened:versions(renamed.id).versions >= 2)
        local old = reopened:restore_version(renamed.id, first.revision, renamed.revision)
        assert(old.content == 'First [[Projects:Tasks]]')
        reopened:close()
    end)
end)

test('history failures never overwrite live text and damaged snapshots are rejected', function()
    fixture(function(n)
        local page = n:save('Page', 'Protected text', '')
        local original = n.fs.write
        n.fs.write = function(fs, path, text)
            if path:find('.leaf/history/', 1, true) then error('Injected history disk failure') end
            return original(fs, path, text)
        end
        assert(not pcall(n.save, n, page.id, 'New text', page.revision))
        assert(n:page(page.id).content == page.content)
        n.fs.write = original
        page = n:save(page.id, 'New text', page.revision)
        local old = n:versions(page.id).versions[1].revision
        for _, token in ipairs({ '../escape', string.rep('0', 64), 'wrong' }) do
            local ok, result = pcall(n.version, n, page.id, token)
            assert(not ok or not result)
        end
        n.fs:write('.leaf/history/blobs/' .. old .. '.md', 'damaged')
        assert(not pcall(n.restore_version, n, page.id, old, page.revision))
        assert(n:page(page.id).content == 'New text')
        n.fs.write = function(fs, path, text)
            if path == 'Page.md' then error('Injected live page disk failure') end
            return original(fs, path, text)
        end
        assert(not pcall(n.save, n, page.id, 'Failed text', page.revision))
        n.fs.write = original
        assert(n:page(page.id).content == 'New text')
        assert(n:version(page.id, page.revision).content == 'New text')
    end)
end)

test('restoring pre-rename history keeps page image references usable', function()
    fixture(function(n)
        local page = n:save('Old/Design', 'Original', '')
        local image = n:image(page.id, '\137PNG\r\n\26\nfixture')
        page = n:save(page.id, image.markdown, page.revision)
        local archived = page.revision
        page = n:save(page.id, 'Changed', page.revision)
        page = n:rename(page.id, 'New/Plan', page.revision)
        page = n:restore_version(page.id, archived, page.revision)
        assert(page.content:find('Plan.attachments/', 1, true))
        assert(n:attachment(page.id, image.file) == '\137PNG\r\n\26\nfixture')
    end)
end)
test('hashtags ignore code and follow saves, search, rename and external edits', function()
    local parsed = require('tags').parse('# Heading\n#Work #学习 #work #team-one\n`#hidden`\n```\n#code\n```\nhttps://site/#fragment')
    assert(#parsed == 3 and parsed[1] == 'team-one' and parsed[2] == 'work' and parsed[3] == '学习')
    fixture(function(n)
        local page = n:save('Projects/Note', '#Work #学习', '')
        assert(#n:state().pages[1].tags == 2)
        assert(#n:state('Note').pages[1].tags == 2)
        page = n:rename(page.id, 'Other/Note', page.revision)
        assert(#page.tags == 2)
        n.fs:write(page.id .. '.md', '#Changed')
        assert(n:state().pages[1].tags[1] == 'changed')
    end)
end)
test('path normalization is absolute and does not create missing folders', function()
    local fs = require('fs')
    local base = fs.resolve(managed or '/tmp')
    local path = base .. '/unused-parent/../normalization-only/file.db'
    assert(fs.resolve(path) == base .. '/normalization-only/file.db')
    assert(io.open(base .. '/normalization-only/file.db', 'rb') == nil)
    if ffi.os == 'Windows' then
        assert(fs.resolve(path:gsub('/', '\\')) == base .. '/normalization-only/file.db')
        assert(fs.resolve('c:\\') == 'C:/')
        assert(fs.resolve('\\\\server\\share\\folder\\..\\file.db') == '//server/share/file.db')
        assert(fs.resolve('\\\\server\\share\\') == '//server/share')
        assert(fs.resolve('~\\LeafWiki') == fs.resolve(require('windows_args').getenv('USERPROFILE') .. '/LeafWiki'))
        assert(fs.resolve('%TEMP%\\LeafWiki') == fs.resolve(require('windows_args').getenv('TEMP') .. '/LeafWiki'))
        assert(not pcall(fs.resolve, '%LEAF_WIKI_UNDEFINED_PATH_VARIABLE%/file'))
    end
end)
test('tasks exclude code, validate dates and preserve Unicode, CRLF, history and duplicate lines', function()
    local tasks = require('tasks')
    local content = '# 学习 #work\r\n- [ ] Same due:2028-02-29\r\n- [X] Same due:2027-02-29\r\n'
        .. '```md\r\n- [ ] Hidden\r\n```\r\n    - [ ] Code\r\n\t- [ ] Code\r\n'
        .. '`- [ ] Inline`\r\n~~~\r\n- [ ] Hidden too\r\n~~~\r\n  * [ ] 中文\r\n1. [ ] Ordered'
    local parsed = tasks.parse(content)
    assert(#parsed == 4 and parsed[1].due == '2028-02-29' and parsed[2].due == '')
    assert(parsed[2].done and parsed[3].text == '中文' and parsed[4].line == 14)
    assert(#tasks.parse('```\n- [ ] Unclosed fence') == 0)
    assert(#tasks.parse('') == 0)
    fixture(function(n)
        local page = assert(n:save('Projects/学习', content, ''))
        local all = n:tasks().tasks
        assert(#all == 4 and all[1].tags[1] == 'work' and all[1].revision == page.revision)
        local changed = assert(n:update_task(page.id, 2, true, page.revision))
        assert(changed.content == content:gsub('%[ %]', '[x]', 1))
        assert(#n:versions(page.id).versions >= 1)
        local value, _, status = n:update_task(page.id, 3, false, page.revision)
        assert(not value and status == 409 and n:page(page.id).content == changed.content)
        value, _, status = n:update_task(page.id, 5, true, changed.revision)
        assert(not value and status == 404)
        assert(not pcall(n.update_task, n, page.id, 2.5, true, changed.revision))
        assert(not pcall(n.update_task, n, page.id, 2, 'yes', changed.revision))
        n.fs:write(page.id .. '.md', '- [ ] External')
        assert(n:tasks().tasks[1].text == 'External')
        value, _, status = n:update_task('Missing', 1, true, '')
        assert(not value and status == 404 and not n:page('Missing'))
    end)
end)
test('quick capture creates journals and appends notes and tasks with revision checks and history', function()
    fixture(function(n)
        local page = assert(n:capture('2026-10-13', '想法\nSecond line', 'note', ''))
        assert(page.id == 'Journal/2026/10/2026-10-13')
        assert(page.content == '# 2026-10-13 Tuesday\n\n想法\nSecond line\n')
        local task = assert(n:capture('2026-10-13', 'Review backups\nCompare options', 'task', page.revision))
        assert(task.content == page.content .. '\n- [ ] Review backups\n  Compare options\n')
        assert(#n:tasks().tasks == 1 and n:tasks().tasks[1].text == 'Review backups')
        assert(#n:versions(page.id).versions == 1)
        local value, _, status = n:capture('2026-10-13', 'Stale', 'note', page.revision)
        assert(not value and status == 409 and n:page(page.id).content == task.content)
        value, _, status = n:capture('2026-10-13', 'Duplicate creation', 'note', '')
        assert(not value and status == 409)
        local crlf = assert(n:save('Journal/2024/02/2024-02-29', '# Existing\r\n', ''))
        local appended = assert(n:capture('2024-02-29', 'One\nTwo', 'note', crlf.revision))
        assert(appended.content == '# Existing\r\n\r\nOne\r\nTwo\r\n')
        local empty = assert(n:save('Journal/2026/10/2026-10-16', '', ''))
        local appended_empty = assert(n:capture('2026-10-16', 'First entry', 'note', empty.revision))
        assert(appended_empty.content == 'First entry\n')
        for _, date in ipairs({ '2025-02-29', '2026-04-31', '../Escape', '2026-00-01', '2026-10-00' }) do
            assert(not pcall(n.capture, n, date, 'Bad date', 'note', ''))
        end
        for _, text in ipairs({ '', ' \n\t', '\255', 'NUL\0byte', string.rep('x', 16001) }) do
            assert(not pcall(n.capture, n, '2026-10-14', text, 'note', ''))
        end
        assert(not pcall(n.capture, n, '2026-10-14', 'Text', 'invalid', ''))
        assert(not n:page('Journal/2026/10/2026-10-14'))
    end)
end)
test('capture write and history failures preserve source pages and report the failed operation', function()
    fixture(function(n)
        local page = assert(n:capture('2026-10-13', 'Original', 'note', ''))
        local write = n.fs.write
        n.fs.write = function(_, path) error('Permission denied writing ' .. path) end
        local ok, err = pcall(n.capture, n, '2026-10-13', 'New', 'note', page.revision)
        assert(not ok and tostring(err):find('Permission denied', 1, true))
        assert(n:page(page.id).content == page.content)
        ok, err = pcall(n.capture, n, '2026-10-14', 'First', 'note', '')
        assert(not ok and tostring(err):find('Journal/2026/10/2026-10-14.md', 1, true))
        assert(not n:page('Journal/2026/10/2026-10-14'))
        n.fs.write = write
        local large = assert(n:save('Journal/2026/10/2026-10-15', string.rep('x', 1024 * 1024), ''))
        assert(not pcall(n.capture, n, '2026-10-15', 'Too large', 'note', large.revision))
        assert(n:page(large.id).content == large.content)
    end)
end)
test('rich search filters by tag and path and extracts contextual snippets with term preservation', function()
    fixture(function(n)
        assert(n:save('Projects/Roadmap', '# 2026 Roadmap #work #planning\n\nOverview of goals.\nMany sections later we detail the quarterly budget and capital allocations.\nEnd.', ''))
        assert(n:save('Projects/Ideas', '# Ideas #work\n\nSome early notes without cost details.', ''))
        assert(n:save('Personal/Journal', '# Diary #personal\n\nDaily thoughts and family budget.', ''))
        assert(n:save('Personal/Empty', '', ''))

        local res = n:state('tag:work')
        assert(#res.pages == 2 and res.pages[1].id == 'Projects/Ideas' and res.pages[2].id == 'Projects/Roadmap')
        local hash_res = n:state('#planning')
        assert(#hash_res.pages == 1 and hash_res.pages[1].id == 'Projects/Roadmap')

        local path_res = n:state('path:Personal')
        assert(#path_res.pages == 2)
        local empty_res = n:state('path:Personal/Empty')
        assert(#empty_res.pages == 1 and empty_res.pages[1].snippet == '')

        local combined = n:state('tag:work path:Projects budget')
        assert(#combined.pages == 1 and combined.pages[1].id == 'Projects/Roadmap')
        assert(combined.pages[1].snippet:find('quarterly budget and capital', 1, true))
        assert(#combined.terms == 1 and combined.terms[1] == 'budget')

        local case_res = n:state('TAG:WORK path:projects')
        assert(#case_res.pages == 2)

        local quote_res = n:state('path:Projects "quarterly budget"')
        assert(#quote_res.pages == 1 and quote_res.pages[1].id == 'Projects/Roadmap')

        local title_match = n:state('Roadmap')
        assert(#title_match.pages == 1 and title_match.pages[1].snippet:find('Roadmap', 1, true))
    end)
end)
print('Passed ' .. count .. ' notebook tests.')
