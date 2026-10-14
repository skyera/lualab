-- Windows notebook filesystem: UTF-8 paths, pinned directories, no reparse traversal,
-- flushed temporary writes and atomic replacement. Handles prohibit directory swaps.
local ffi = require('ffi')
local bit = require('bit')
ffi.cdef[[
typedef struct { unsigned long low, high; } leaf_filetime;
typedef struct { unsigned long attributes; leaf_filetime created, accessed, written;
    unsigned long volume, size_high, size_low, links, index_high, index_low; } leaf_file_info;
typedef struct { unsigned long attributes; leaf_filetime created, accessed, written;
    unsigned long size_high, size_low, reserved0, reserved1;
    uint16_t name[260], alternate[14]; } leaf_find_data;
int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, uint16_t *, int);
int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const uint16_t *, int,
    char *, int, const char *, int *);
unsigned long __stdcall GetFullPathNameW(const uint16_t *, unsigned long, uint16_t *, uint16_t **);
unsigned long __stdcall GetFinalPathNameByHandleW(void *, uint16_t *, unsigned long, unsigned long);
void * __stdcall CreateFileW(const uint16_t *, unsigned long, unsigned long, void *,
    unsigned long, unsigned long, void *);
int __stdcall CreateDirectoryW(const uint16_t *, void *);
int __stdcall CloseHandle(void *);
int __stdcall GetFileInformationByHandle(void *, leaf_file_info *);
unsigned long __stdcall GetFileType(void *);
unsigned long __stdcall GetLastError(void);
int __stdcall ReadFile(void *, void *, unsigned long, unsigned long *, void *);
int __stdcall WriteFile(void *, const void *, unsigned long, unsigned long *, void *);
int __stdcall FlushFileBuffers(void *);
int __stdcall MoveFileExW(const uint16_t *, const uint16_t *, unsigned long);
int __stdcall DeleteFileW(const uint16_t *);
void * __stdcall FindFirstFileW(const uint16_t *, leaf_find_data *);
int __stdcall FindNextFileW(void *, leaf_find_data *);
int __stdcall FindClose(void *);
unsigned long __stdcall GetCurrentProcessId(void);
]]
local C = ffi.load('kernel32')
local INVALID = ffi.cast('void *', -1)
local DIRECTORY, REPARSE = 0x10, 0x400
local OPEN_FLAGS = 0x02000000 + 0x00200000 -- backup semantics, open reparse point
local Fs = {}
Fs.__index = Fs
local serial = 0

-- ============================================================================
-- UTF conversion and canonical folder paths
-- ============================================================================
local function wide(text)
    assert(type(text) == 'string' and not text:find('%z'), 'Invalid path')
    local count = C.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
    assert(count > 0, 'Path must be valid UTF-8')
    local buffer = ffi.new('uint16_t[?]', count + 1)
    assert(C.MultiByteToWideChar(65001, 8, text, #text, buffer, count) == count, 'Invalid path')
    return buffer
end

local function utf8(buffer, count)
    if not count then
        count = 0
        while buffer[count] ~= 0 do count = count + 1 end
    end
    if count == 0 then return '' end
    local size = C.WideCharToMultiByte(65001, 0, buffer, count, nil, 0, nil, nil)
    assert(size > 0, 'Cannot encode filename')
    local text = ffi.new('char[?]', size)
    assert(C.WideCharToMultiByte(65001, 0, buffer, count, text, size, nil, nil) == size,
        'Cannot encode filename')
    return ffi.string(text, size)
end

local function native(path)
    path = path:gsub('/', '\\')
    if path:sub(1, 2) == '\\\\' then return wide('\\\\?\\UNC\\' .. path:sub(3)) end
    return wide('\\\\?\\' .. path)
end

local function info(handle)
    local value = ffi.new('leaf_file_info[1]')
    assert(C.GetFileInformationByHandle(handle, value) ~= 0, 'Cannot inspect file')
    return value[0]
end

local function open_directory(path)
    local handle = C.CreateFileW(native(path), 0, 3, nil, 3, OPEN_FLAGS, nil)
    if handle == INVALID then return nil, tonumber(C.GetLastError()) end
    local stamp = info(handle)
    if bit.band(stamp.attributes, REPARSE) ~= 0 or bit.band(stamp.attributes, DIRECTORY) == 0 then
        C.CloseHandle(handle)
        error('Missing or unsafe page directory: ' .. path)
    end
    return handle
end

function Fs.resolve(path)
    assert(type(path) == 'string' and path ~= '' and not path:find('%z'), 'Invalid folder path')
    path = path:gsub('\\', '/')
    local getenv = require('windows_args').getenv
    path = path:gsub('%%([%w_]+)%%', function(name)
        return assert(getenv(name), 'Unknown path environment variable: ' .. name)
    end):gsub('\\', '/')
    if path == '~' or path:sub(1, 2) == '~/' then
        path = (getenv('USERPROFILE') or getenv('HOME') or '.') .. path:sub(2)
    end
    assert(not path:match('^//[?.]/'), 'Device paths are not supported')
    local buffer = ffi.new('uint16_t[32768]')
    local count = C.GetFullPathNameW(wide(path), 32768, buffer, nil)
    assert(count > 0 and count < 32768, 'Cannot resolve folder path')
    path = utf8(buffer, count):gsub('\\', '/')
    path = path:gsub('^%a:', function(drive) return drive:upper() end)
    return path:match('^%a:/$') and path or path:gsub('/+$', '')
end

function Fs.absolute(path)
    path = Fs.resolve(path)
    local buffer = ffi.new('uint16_t[32768]')
    local base, rest = path:match('^(%a:/)(.*)$')
    if not base then base, rest = path:match('^(//[^/]+/[^/]+)/?(.*)$') end
    assert(base, 'Folder must have a drive or UNC share')
    local current = base:gsub('/$', '')
    for part in rest:gmatch('[^/]+') do
        assert(not part:find('[<>:"|?*]') and not part:match('[ .]$'), 'Invalid folder component')
        current = current .. '/' .. part
        if C.CreateDirectoryW(native(current), nil) == 0 then
            assert(C.GetLastError() == 183, 'Cannot create folder: ' .. current)
        end
    end
    local handle = assert(open_directory(path), 'Cannot open folder: ' .. path)
    local count = C.GetFinalPathNameByHandleW(handle, buffer, 32768, 0)
    C.CloseHandle(handle)
    assert(count > 0 and count < 32768, 'Cannot resolve folder')
    path = utf8(buffer, count):gsub('\\', '/')
    if path:sub(1, 8) == '//?/UNC/' then path = '//' .. path:sub(9)
    else path = path:gsub('^//%?/', '') end
    return path:match('^%a:/$') and path or path:gsub('/$', '')
end

function Fs.open(path)
    local root = Fs.absolute(path)
    return setmetatable({ root = root, handle = assert(open_directory(root)) }, Fs)
end

-- ============================================================================
-- Pin each ancestor without delete sharing, and reject Windows path aliases.
-- ============================================================================
local function valid_component(part)
    local stem = part:match('^([^.]*)'):upper()
    return part ~= '' and part ~= '.' and part ~= '..' and not part:find('[%z\1-\31<>:"|?*\\]')
        and not part:match('[ .]$') and stem ~= 'CON' and stem ~= 'PRN' and stem ~= 'AUX'
        and stem ~= 'NUL' and not stem:match('^COM[1-9]$') and not stem:match('^LPT[1-9]$')
end

local function check_name(path, name)
    local data = ffi.new('leaf_find_data[1]')
    local search = C.FindFirstFileW(native(path), data)
    if search == INVALID then
        local err = tonumber(C.GetLastError())
        assert(err == 2 or err == 3, 'Cannot inspect path: ' .. path)
        return
    end
    C.FindClose(search)
    assert(utf8(data[0].name) == name, 'Filename spelling or case conflicts with an existing file')
    assert(bit.band(data[0].attributes, REPARSE) == 0, 'Unsafe reparse point: ' .. path)
end

function Fs:parent(path, create)
    assert(self.handle, 'Notebook is closed')
    assert(type(path) == 'string' and path:sub(1, 1) ~= '/' and path ~= ''
        and not path:find('//', 1, true) and path:sub(-1) ~= '/', 'Invalid file path')
    local parts, handles = {}, {}
    for part in path:gmatch('[^/]+') do
        assert(valid_component(part), 'Invalid Windows file path')
        parts[#parts + 1] = part
    end
    local function release()
        for _, handle in ipairs(handles) do C.CloseHandle(handle) end
    end
    local current = self.root:gsub('/$', '')
    local ok, err = pcall(function()
        for index = 1, #parts - 1 do
            current = current .. '/' .. parts[index]
            check_name(current, parts[index])
            if create and C.CreateDirectoryW(native(current), nil) == 0 then
                assert(C.GetLastError() == 183, 'Cannot create page directory')
            end
            handles[#handles + 1] = assert(open_directory(current), 'Missing page directory')
        end
        check_name(current .. '/' .. parts[#parts], parts[#parts])
    end)
    if not ok then release(); error(err) end
    return current .. '/' .. parts[#parts], release
end

local function read_full(full, maximum)
    local handle = C.CreateFileW(native(full), 0x80000000, 7, nil, 3, OPEN_FLAGS, nil)
    if handle == INVALID then
        local err = tonumber(C.GetLastError())
        if err == 2 or err == 3 then return nil end
        error('Cannot read file: ' .. full)
    end
    local success, result = pcall(function()
        local stamp = info(handle)
        assert(C.GetFileType(handle) == 1 and bit.band(stamp.attributes, DIRECTORY + REPARSE) == 0,
            'File is not a regular file: ' .. full)
        maximum = maximum or 1024 * 1024
        assert(stamp.size_high == 0 and stamp.size_low <= maximum, 'File exceeds size limit')
        local chunks, size = {}, 0
        local buffer, bytes = ffi.new('char[65536]'), ffi.new('unsigned long[1]')
        while true do
            assert(C.ReadFile(handle, buffer, 65536, bytes, nil) ~= 0, 'Cannot read file')
            if bytes[0] == 0 then break end
            size = size + tonumber(bytes[0])
            assert(size <= maximum, 'File exceeds size limit')
            chunks[#chunks + 1] = ffi.string(buffer, bytes[0])
        end
        return table.concat(chunks)
    end)
    C.CloseHandle(handle)
    assert(success, result)
    return result
end

function Fs:read(path, maximum)
    local ok, full, release = pcall(self.parent, self, path)
    if not ok then
        if tostring(full):find('Missing page directory', 1, true) then return nil end
        error(full)
    end
    local success, result = pcall(read_full, full, maximum)
    release()
    assert(success, result)
    return result
end

function Fs:file_exists(path)
    local full, release = self:parent(path)
    local handle = C.CreateFileW(native(full), 0, 7, nil, 3, OPEN_FLAGS, nil)
    if handle == INVALID then
        local err = tonumber(C.GetLastError())
        release()
        assert(err == 2 or err == 3, 'Cannot inspect file: ' .. path)
        return false
    end
    local inspected, stamp = pcall(info, handle)
    local regular = inspected and C.GetFileType(handle) == 1
        and bit.band(stamp.attributes, DIRECTORY + REPARSE) == 0
    C.CloseHandle(handle); release()
    assert(regular, 'Not a regular file: ' .. path)
    return true
end

-- Trusted launcher assets/configuration also need wide paths, without creating folders.
function Fs.read_file(path)
    return read_full(Fs.resolve(path), 32 * 1024 * 1024)
end

function Fs:write(path, text)
    local full, release = self:parent(path, true)
    serial = serial + 1
    local temporary = full:match('^(.*)/') .. '/.leaf-write-' .. tonumber(C.GetCurrentProcessId()) .. '-' .. serial
    local handle = C.CreateFileW(native(temporary), 0x40000000, 0, nil, 1, OPEN_FLAGS, nil)
    if handle == INVALID then release(); error('Cannot create temporary file') end
    local ok, err = pcall(function()
        local pointer, offset, bytes = ffi.cast('const char *', text), 0, ffi.new('unsigned long[1]')
        while offset < #text do
            assert(C.WriteFile(handle, pointer + offset, #text - offset, bytes, nil) ~= 0
                and bytes[0] > 0, 'Cannot write file')
            offset = offset + tonumber(bytes[0])
        end
        assert(C.FlushFileBuffers(handle) ~= 0, 'Cannot flush file')
        C.CloseHandle(handle); handle = nil
        assert(C.MoveFileExW(native(temporary), native(full), 1 + 8) ~= 0, 'Cannot replace file')
    end)
    if handle then C.CloseHandle(handle) end
    if not ok then C.DeleteFileW(native(temporary)) end
    release()
    assert(ok, err)
end

function Fs:remove(path)
    local full, release = self:parent(path)
    local ok = C.DeleteFileW(native(full)) ~= 0
    release()
    assert(ok, 'Cannot remove file')
end

function Fs:move(source, target)
    local full, release = self:parent(source)
    local ok, destination, release_target = pcall(self.parent, self, target, true)
    if not ok then release(); error(destination) end
    local moved = C.MoveFileExW(native(full), native(destination), 8) ~= 0
    release_target(); release()
    assert(moved, 'Cannot move file or attachment directory')
end

function Fs:directory_exists(path)
    local ok, full, release = pcall(self.parent, self, path)
    if not ok then
        if tostring(full):find('Missing page directory', 1, true) then return false end
        error(full)
    end
    local success, handle, err = pcall(open_directory, full)
    release()
    assert(success, handle)
    if handle then C.CloseHandle(handle); return true end
    assert(err == 2 or err == 3, 'Unsafe or unreadable directory')
    return false
end

function Fs:list(prefix, depth, attachments)
    prefix, depth = prefix or '', depth or 0
    assert(self.handle, 'Notebook is closed')
    assert(depth <= 16, 'Notebook nesting is limited to 16 levels')
    local full, release = self.root, function() end
    local directory
    if prefix ~= '' then
        full, release = self:parent(prefix)
        directory = open_directory(full)
        if not directory then
            local err = tonumber(C.GetLastError())
            release()
            if attachments and (err == 2 or err == 3) then return {} end
            error('Cannot list directory: ' .. full .. ' (Windows error ' .. err .. ')')
        end
    end
    local data, entries = ffi.new('leaf_find_data[1]'), {}
    local search = C.FindFirstFileW(native(full .. '/*'), data)
    if search == INVALID then
        if directory then C.CloseHandle(directory) end
        release()
        assert(C.GetLastError() == 2, 'Cannot list notebook')
        return {}
    end
    repeat
        local name, attributes = utf8(data[0].name), tonumber(data[0].attributes)
        if name:sub(1, 1) ~= '.' and bit.band(attributes, REPARSE) == 0 then
            entries[#entries + 1] = { name = name, directory = bit.band(attributes, DIRECTORY) ~= 0,
                bytes = tonumber(data[0].size_high) * 4294967296 + tonumber(data[0].size_low) }
        end
    until C.FindNextFileW(search, data) == 0
    local err = tonumber(C.GetLastError())
    C.FindClose(search)
    if directory then C.CloseHandle(directory) end
    release()
    assert(err == 18, 'Cannot finish listing notebook')
    local pages = {}
    for _, entry in ipairs(entries) do
        local path = prefix == '' and entry.name or prefix .. '/' .. entry.name
        if attachments and not entry.directory and entry.name:match('^[%w_-]+%.%a+$')
            and ({ png = true, jpg = true, gif = true, webp = true })[entry.name:match('%.(.*)$')] then
            pages[#pages + 1] = { file = entry.name, bytes = entry.bytes }
        elseif not attachments and entry.directory and not entry.name:match('%.attachments$') then
            for _, child in ipairs(self:list(path, depth + 1)) do pages[#pages + 1] = child end
        elseif not attachments and not entry.directory and entry.name:match('%.md$') then pages[#pages + 1] = path end
        assert(#pages <= 2000, attachments and 'Attachment directory is limited to 2,000 images: ' .. prefix
            or 'Notebook is limited to 2,000 pages')
    end
    table.sort(pages, attachments and function(a, b) return a.file < b.file end or nil)
    return pages
end

function Fs:lock()
    local full, release = self:parent('.leaf/lock', true)
    local handle = C.CreateFileW(native(full), 0x80000000 + 0x40000000, 0, nil, 4, OPEN_FLAGS, nil)
    release()
    assert(handle ~= INVALID, 'Notebook is already open or its lock cannot be acquired')
    return function() C.CloseHandle(handle) end
end

function Fs:close()
    if self.handle then C.CloseHandle(self.handle); self.handle = nil end
end
return Fs
