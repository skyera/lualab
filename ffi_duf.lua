#!/usr/bin/env luajit
-- ffi_duf.lua  ─  disk usage viewer (duf clone) using LuaJIT FFI
-- Auto-detects the OS and loads the appropriate backend module.
--
-- Architecture (Option C — abstraction layer):
--
--   ffi_duf.lua          ← this file: entry point + OS detection
--   ffi_duf_shared.lua   ← shared: formatting, classification, table rendering
--   ffi_duf_linux.lua    ← Linux:   /proc/mounts + statvfs()
--   ffi_duf_macos.lua    ← macOS:   getmntinfo() + struct statfs
--   ffi_duf_windows.lua  ← Windows: GetLogicalDriveStringsW + GetDiskFreeSpaceExW
--
-- Backend contract:
--   get_mounts() → { mountpoint, device, fstype, total, used, avail }[]
--                  (total / used / avail are byte counts)
--
-- Usage: luajit ffi_duf.lua

-- ─── Make sibling modules discoverable regardless of CWD ─────────────────
local _src = debug.getinfo(1, "S").source
local _dir = _src:match("^@(.+[/\\])")
if _dir then package.path = _dir.."?.lua;"..package.path end

-- ─── Load shared layer ────────────────────────────────────────────────────
local ffi    = require("ffi")
local shared = require("ffi_duf_shared")

-- ─── OS → backend mapping ─────────────────────────────────────────────────
local BACKENDS = {
  Windows = "ffi_duf_windows",
  OSX     = "ffi_duf_macos",
  -- Linux, FreeBSD, and other POSIX systems fall through to the Linux backend
}
local mod = BACKENDS[ffi.os] or "ffi_duf_linux"

local ok, backend = pcall(require, mod)
if not ok then
  io.stderr:write("ffi_duf: could not load backend '"..mod.."'\n"..tostring(backend).."\n")
  os.exit(1)
end

shared.run(backend)
