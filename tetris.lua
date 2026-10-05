#!/usr/bin/env luajit
--[[
    tetris.lua
    Top-level launcher for LuaJIT FFI Tetris.
    Delegates directly to ffi_tetris.lua.
]]

local script_dir = "."
if arg and arg[0] then
    local dir = arg[0]:match("^(.*)/[^/]+$")
    if dir and #dir > 0 then
        script_dir = dir
    end
end

dofile(script_dir .. "/ffi_tetris.lua")
