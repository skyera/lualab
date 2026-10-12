#!/usr/bin/env luajit
-- Real Windows console input verifies Ctrl-C cleanup and notebook lock release.
local root = arg[0]:gsub('\\', '/'):match('^(.*)/') .. '/../..'
package.path = root .. '/wiki_web/?.lua;' .. root .. '/dictionary_web/?.lua;' .. root .. '/?.lua;' .. package.path
local ffi = require('ffi')
assert(ffi.os == 'Windows')
local http = require('http')
ffi.cdef[[
int __stdcall AllocConsole(void);
int __stdcall FreeConsole(void);
void * __stdcall CreateFileW(const uint16_t *, unsigned long, unsigned long, void *,
    unsigned long, unsigned long, void *);
int __stdcall SetStdHandle(unsigned long, void *);
int __stdcall CloseHandle(void *);
int __stdcall WriteConsoleInputW(void *, const struct leaf_key_event *, unsigned long, unsigned long *);
]]
local C = ffi.load('kernel32')
-- Detach inherited consoles before allocating an isolated, hidden test console.
C.FreeConsole()
assert(C.AllocConsole() ~= 0, 'Cannot allocate test console')
local input = C.CreateFileW(ffi.new('uint16_t[7]', { 67, 79, 78, 73, 78, 36, 0 }),
    0x80000000 + 0x40000000, 3, nil, 3, 0, nil)
assert(input ~= ffi.cast('void *', -1), 'Cannot open console input')
assert(C.SetStdHandle(0xfffffff6, input) ~= 0)
local before = ffi.new('unsigned long[1]')
assert(C.GetConsoleMode(input, before) ~= 0)
local serve = http.serve
http.serve = function(port, handler, ready, host, workers, options)
    return serve(port, handler, function(actual_port)
        ready(actual_port)
        local event = ffi.new('struct leaf_key_event[1]')
        event[0].kind, event[0].down, event[0].key = 1, 1, 67
        event[0].character, event[0].control = 3, 8
        local written = ffi.new('unsigned long[1]')
        assert(C.WriteConsoleInputW(input, event, 1, written) ~= 0 and written[0] == 1)
    end, host, workers, options)
end
local directory = arg[1]:gsub('\\', '/')
local options = { '--port', '0', '--data-dir', directory .. '/notebook', '--cache-dir', directory .. '/cache',
    '--config', directory .. '/config.json', [0] = root .. '/wiki_web.lua' }
for key in pairs(arg) do arg[key] = nil end
for key, value in pairs(options) do arg[key] = value end
require('app').run(root)
local after = ffi.new('unsigned long[1]')
assert(C.GetConsoleMode(input, after) ~= 0 and after[0] == before[0], 'Console mode was not restored')
local notebook = require('notebook').open(directory .. '/notebook', directory .. '/cache')
notebook:close()
C.CloseHandle(input)
C.FreeConsole()
print('Console Ctrl-C restored input mode and released notebook lock')
