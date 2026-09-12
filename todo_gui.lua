#!/usr/bin/env luajit
local dir = (arg and arg[0] and arg[0]:match("(.*[/\\])")) or ""
dofile(dir .. "todo_tui.lua")
