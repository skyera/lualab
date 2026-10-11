#!/usr/bin/env luajit
-- Leaf Wiki: local Markdown notebook with browser editing and image attachments.
local root = (arg[0]:match('^(.*)/') or '.')
package.path = root .. '/wiki_web/?.lua;' .. root .. '/dictionary_web/?.lua;'
    .. root .. '/?.lua;' .. package.path
require('app').run(root)
