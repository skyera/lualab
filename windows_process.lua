#!/usr/bin/env luajit
-- Windows child processes: Unicode arguments, inherited output, no command shell.
local ffi = require('ffi')
ffi.cdef[[
typedef struct {
    unsigned long size; uint16_t *reserved, *desktop, *title;
    unsigned long x, y, x_size, y_size, x_chars, y_chars, fill, flags;
    unsigned short show, reserved_size; unsigned char *reserved_bytes;
    void *input, *output, *error;
} dict_startup_info;
typedef struct { void *process, *thread; unsigned long process_id, thread_id; } dict_process_info;
int __stdcall CreateProcessW(const uint16_t *, uint16_t *, void *, void *, int,
    unsigned long, void *, const uint16_t *, dict_startup_info *, dict_process_info *);
int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, uint16_t *, int);
void * __stdcall GetStdHandle(unsigned long);
unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
int __stdcall GetExitCodeProcess(void *, unsigned long *);
int __stdcall CloseHandle(void *);
unsigned long __stdcall GetLastError(void);
unsigned long __stdcall GetFileAttributesW(const uint16_t *);
]]
local kernel = ffi.load('kernel32')
local M = {}

function M.quote(value)
    value = tostring(value)
    assert(not value:find('%z'), 'Command argument contains NUL')
    return '"' .. value:gsub('(\\*)"', '%1%1\\"'):gsub('(\\+)$', '%1%1') .. '"'
end

function M.file_exists(path)
    local count = kernel.MultiByteToWideChar(65001, 8, path, #path, nil, 0)
    assert(count > 0, 'Invalid UTF-8 file path')
    local wide = ffi.new('uint16_t[?]', count + 1)
    assert(kernel.MultiByteToWideChar(65001, 8, path, #path, wide, count) == count, 'Cannot encode file path')
    local attributes = tonumber(kernel.GetFileAttributesW(wide))
    if attributes == 0xffffffff then
        local code = tonumber(kernel.GetLastError())
        assert(code == 2 or code == 3, 'Cannot inspect file: ' .. path .. ' (Windows error ' .. code .. ')')
        return false
    end
    return attributes % 32 < 16 -- exclude directories without reading database contents
end

function M.run(argv)
    assert(type(argv[1]) == 'string' and argv[1] ~= '', 'Missing executable')
    local parts = {}
    for _, value in ipairs(argv) do parts[#parts + 1] = M.quote(value) end
    local text = table.concat(parts, ' ')
    local count = kernel.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
    assert(count > 0, 'Invalid UTF-8 command arguments')
    local command = ffi.new('uint16_t[?]', count + 1)
    assert(kernel.MultiByteToWideChar(65001, 8, text, #text, command, count) == count,
        'Cannot encode command arguments')
    local startup, process = ffi.new('dict_startup_info'), ffi.new('dict_process_info')
    startup.size, startup.flags = ffi.sizeof(startup), 0x100 -- STARTF_USESTDHANDLES
    startup.input = kernel.GetStdHandle(0xfffffff6)
    startup.output = kernel.GetStdHandle(0xfffffff5)
    startup.error = kernel.GetStdHandle(0xfffffff4)
    io.stdout:flush(); io.stderr:flush()
    local created = kernel.CreateProcessW(nil, command, nil, nil, 1, 0x08000000, nil, nil, startup, process)
    assert(created ~= 0, 'Cannot start ' .. argv[1] .. ' (Windows error ' .. kernel.GetLastError()
        .. '). Install the executable and check PATH.')
    kernel.CloseHandle(process.thread)
    local waited = kernel.WaitForSingleObject(process.process, 0xffffffff)
    local code = ffi.new('unsigned long[1]')
    local read = kernel.GetExitCodeProcess(process.process, code)
    kernel.CloseHandle(process.process)
    assert(waited == 0 and read ~= 0, 'Cannot read exit status for ' .. argv[1])
    assert(code[0] == 0, argv[1] .. ' failed (status ' .. tonumber(code[0]) .. ').')
end

return M
