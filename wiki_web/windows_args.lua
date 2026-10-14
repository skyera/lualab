--------------------------------------------------------------------------------
-- windows_args.lua
-- LuaJIT's Windows CRT argv is ANSI. Recover UTF-8 notebook/config arguments from
-- the original Unicode command line before parsing options.
--------------------------------------------------------------------------------

local ffi = require('ffi')

local M = {}

--------------------------------------------------------------------------------
-- Unicode Environment Variable Retrieval
--------------------------------------------------------------------------------
function M.getenv(name)
    if ffi.os ~= 'Windows' then return os.getenv(name) end
    ffi.cdef[[
    unsigned long __stdcall GetEnvironmentVariableW(const uint16_t *, uint16_t *, unsigned long);
    int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const uint16_t *, int,
        char *, int, const char *, int *);
    ]]
    assert(name:match('^[%w_]+$'), 'Invalid environment variable name')
    local kernel = ffi.load('kernel32')
    local key = ffi.new('uint16_t[?]', #name + 1)
    for index = 1, #name do
        key[index - 1] = name:byte(index)
    end
    local count = kernel.GetEnvironmentVariableW(key, nil, 0)
    if count == 0 then return nil end
    local value = ffi.new('uint16_t[?]', count)
    assert(kernel.GetEnvironmentVariableW(key, value, count) < count, 'Environment variable changed')
    local size = kernel.WideCharToMultiByte(65001, 0, value, -1, nil, 0, nil, nil)
    local buffer = ffi.new('char[?]', size)
    kernel.WideCharToMultiByte(65001, 0, value, -1, buffer, size, nil, nil)
    return ffi.string(buffer)
end

--------------------------------------------------------------------------------
-- Unicode Command Line Argument Normalization
--------------------------------------------------------------------------------
function M.normalize()
    if ffi.os ~= 'Windows' then return end
    ffi.cdef[[
    const uint16_t * __stdcall GetCommandLineW(void);
    uint16_t ** __stdcall CommandLineToArgvW(const uint16_t *, int *);
    void * __stdcall LocalFree(void *);
    int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const uint16_t *, int,
        char *, int, const char *, int *);
    ]]
    local kernel, shell = ffi.load('kernel32'), ffi.load('shell32')
    local count = ffi.new('int[1]')
    local values = shell.CommandLineToArgvW(kernel.GetCommandLineW(), count)
    assert(values ~= nil, 'Cannot read Windows command line')
    local arguments = {}
    for index = 0, count[0] - 1 do
        local size = kernel.WideCharToMultiByte(65001, 0, values[index], -1, nil, 0, nil, nil)
        local buffer = ffi.new('char[?]', size)
        kernel.WideCharToMultiByte(65001, 0, values[index], -1, buffer, size, nil, nil)
        arguments[index] = ffi.string(buffer)
    end
    kernel.LocalFree(values)
    local name = arg[0]:gsub('\\', '/'):match('([^/]+)$')
    for index = 1, count[0] - 1 do
        if arguments[index]:gsub('\\', '/'):match('([^/]+)$') == name then
            arg[0] = arguments[index]
            for offset = 1, #arg do
                arg[offset] = nil
            end
            for offset = index + 1, count[0] - 1 do
                arg[offset - index] = arguments[offset]
            end
            return
        end
    end
end

return M
