#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- wiki_web.lua
-- Leaf Wiki: Local Markdown Notebook with In-Browser Editing & Image Attachments
-- High-performance, zero-dependency personal wiki powered by LuaJIT & SQLite
--------------------------------------------------------------------------------

-- Resolve the application root directory across relative and absolute launches
local script_source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = script_source:match("^(.*)[/\\][^/\\]*$")
local root = script_dir or (arg and arg[0] and (arg[0]:gsub("\\", "/"):match("^(.*)/") or ".")) or "."

package.path = root .. "/wiki_web/?.lua;"
    .. root .. "/dictionary_web/?.lua;"
    .. root .. "/?.lua;"
    .. package.path

local startup = require("startup")

local success = startup.launch(function()
    require("app").run(root)
end)

if not success then
    os.exit(1)
end
