#!/usr/bin/env luajit
--[[
    enigma.lua
    Top-level launcher for LuaJIT FFI Enigma Cipher Machine Simulator.
    Delegates directly to ffi_enigma.lua.
]]

local script_dir = "."
if arg and arg[0] then
    local dir = arg[0]:match("^(.*)/[^/]+$")
    if dir and #dir > 0 then
        script_dir = dir
    end
end

dofile(script_dir .. "/ffi_enigma.lua")
