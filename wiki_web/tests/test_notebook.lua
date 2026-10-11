#!/usr/bin/env luajit
-- Temporary-notebook verification of files, links, conflicts and maintenance recovery.
local root = (arg[0]:match('^(.*)/') or '.') .. '/../..'
package.path = root .. '/wiki_web/?.lua;' .. root .. '/dictionary_web/?.lua;' .. root .. '/?.lua;' .. package.path
local Notebook = require('notebook')
local links = require('links')
local json = require('json')
local ffi = require('ffi')
ffi.cdef[[int symlink(const char *, const char *);]]
local count = 0
local function fixture(run)
    local directory, cache = os.tmpname(), os.tmpname()
    os.remove(directory); os.remove(cache)
    local notebook = Notebook.open(directory, cache)
    local ok, err = pcall(run, notebook, directory, cache)
    notebook:close()
    os.execute("rm -rf -- '" .. directory .. "' '" .. cache .. "'")
    assert(ok, err)
end
local function test(name, run)
    local ok, err = pcall(run)
    assert(ok, name .. ': ' .. tostring(err))
    count = count + 1; print('ok ' .. count .. ' - ' .. name)
end

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
print('Passed ' .. count .. ' notebook tests.')
