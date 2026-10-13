#!/usr/bin/env luajit
-- Leaf Wiki: local Markdown notebook with browser editing and image attachments.
local root = (arg[0]:gsub('\\', '/'):match('^(.*)/') or '.')
package.path = root .. '/wiki_web/?.lua;' .. root .. '/dictionary_web/?.lua;'
    .. root .. '/?.lua;' .. package.path
local startup = require('startup')
if not startup.launch(function() require('app').run(root) end) then os.exit(1) end
