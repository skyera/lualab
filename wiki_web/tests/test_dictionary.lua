#!/usr/bin/env luajit
-- Read-only local dictionary tests; the Node runner owns and removes the fixture folder.
local root = arg[0]:gsub('\\', '/'):match('^(.*)/') .. '/../..'
package.path = root .. '/wiki_web/?.lua;' .. root .. '/dictionary_web/?.lua;' .. root .. '/?.lua;' .. package.path
require('windows_args').normalize()
local DB = require('db')
local dictionary = require('dictionary')
local directory = assert(arg[1], 'Pass a managed temporary directory'):gsub('\\', '/')
local path = directory .. '/词典.db'
local db = DB.open(path, [[CREATE TABLE dict(id INTEGER PRIMARY KEY, word TEXT, pos TEXT,
    definition TEXT, example TEXT, syn TEXT, ant TEXT);]])
for _, sense in ipairs({
    { 'ephemeral', 'adj.', 'Lasting a short time.', 'An ephemeral bloom.', 'temporary', 'lasting' },
    { 'ephemeral', 'n.', 'A short-lived thing.', '', '', '' },
    { '学习', 'v.', 'Study and learn.', '', '', '' },
    { "don't", '', 'Do not.', '', '', '' },
    { '<script>', '', '<img src=x onerror=alert(1)>', '', '', '' },
}) do
    db:query('INSERT INTO dict(word,pos,definition,example,syn,ant) VALUES(?,?,?,?,?,?)', sense)
end
db:close()
local result, status = dictionary.lookup(path, '  EPHEMERAL  ')
assert(status == 200 and #result.senses == 2 and result.senses[1].example == 'An ephemeral bloom.')
assert(dictionary.lookup(path, '学习').senses[1].definition == 'Study and learn.')
assert(dictionary.lookup(path, "don't").senses[1].definition == 'Do not.')
assert(#dictionary.lookup(path, "' OR 1=1 --").senses == 0)
assert(#dictionary.lookup(path, 'missing').senses == 0)
for _, value in ipairs({ '', ' ', '\0', '\255', string.rep('x', 241) }) do
    local _, code = dictionary.lookup(path, value)
    assert(code == 400)
end
local _, code = dictionary.lookup(path, nil)
assert(code == 400)
_, code = dictionary.lookup('none', 'word')
assert(code == 503)
local missing = directory .. '/missing.db'
_, code = dictionary.lookup(missing, 'word')
assert(code == 503 and io.open(missing, 'rb') == nil, 'Lookup created a missing database')
local empty = directory .. '/empty.db'
db = DB.open(empty); db:close()
_, code = dictionary.lookup(empty, 'word')
assert(code == 503)
db = DB.open(path, nil, true)
assert(not pcall(db.query, db, 'DELETE FROM dict'), 'Dictionary connection was writable')
assert(#db:query('SELECT * FROM dict') == 5)
db:close()
print('Passed local dictionary validation and read-only tests.')
