-- Linux filesystem operations confined to a notebook, with atomic file writes.
local ffi = require('ffi')
if ffi.os == 'Windows' then return require('fs_windows') end
local bit = require('bit')
ffi.cdef[[
typedef struct leaf_directory leaf_directory;
struct leaf_dirent { unsigned long inode; long offset; unsigned short length;
    unsigned char kind; char name[256]; };
struct leaf_stat { unsigned long dev, inode, links; unsigned int mode, uid, gid, pad;
    unsigned long rdev; long size, blocksize, blocks, atime; unsigned long atime_ns;
    long mtime; unsigned long mtime_ns; long ctime; unsigned long ctime_ns; long unused[3]; };
int open(const char *, int, ...);
int openat(int, const char *, int, ...);
int mkdir(const char *, unsigned int);
int mkdirat(int, const char *, unsigned int);
int renameat(int, const char *, int, const char *);
int unlinkat(int, const char *, int);
int close(int);
int fsync(int);
int flock(int, int);
int getpid(void);
long read(int, void *, size_t);
long write(int, const void *, size_t);
int fstat(int, struct leaf_stat *);
leaf_directory *fdopendir(int);
struct leaf_dirent *readdir(leaf_directory *);
int closedir(leaf_directory *);
char *realpath(const char *, char *);
]]
local C = ffi.C
local stat_fd = ffi.cast('int (*)(int, struct leaf_stat *)', C.fstat)
local read_dir = ffi.cast('struct leaf_dirent *(*)(leaf_directory *)', C.readdir)
local fd_open_dir = ffi.cast('leaf_directory *(*)(int)', C.fdopendir)
local close_dir = ffi.cast('int (*)(leaf_directory *)', C.closedir)
local DIRECTORY = 65536 + 131072 + 524288 -- O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
local NOFOLLOW = 131072 + 524288 + 2048 -- O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
local serial = 0
local Fs = {}
Fs.__index = Fs

function Fs.resolve(path)
    assert(type(path) == 'string' and path ~= '' and not path:find('%z'), 'Invalid folder path')
    if path == '~' or path:sub(1, 2) == '~/' then path = (os.getenv('HOME') or '.') .. path:sub(2) end
    if path:sub(1, 1) ~= '/' then
        local cwd = ffi.new('char[4096]')
        assert(C.realpath('.', cwd) ~= nil, 'Cannot resolve current directory')
        path = ffi.string(cwd) .. '/' .. path
    end
    local parts = {}
    for part in path:gmatch('[^/]+') do
        if part == '..' then table.remove(parts)
        elseif part ~= '.' then parts[#parts + 1] = part end
    end
    return '/' .. table.concat(parts, '/')
end

function Fs.absolute(path)
    path = Fs.resolve(path)
    local current = ''
    for part in path:gmatch('[^/]+') do
        current = current .. '/' .. part
        if C.mkdir(current, 448) ~= 0 then assert(ffi.errno() == 17, 'Cannot create folder: ' .. current) end
    end
    local resolved = ffi.new('char[4096]')
    assert(C.realpath(path, resolved) ~= nil, 'Cannot resolve folder: ' .. path)
    return ffi.string(resolved)
end

function Fs.open(path)
    assert(ffi.os == 'Linux' and ffi.arch == 'x64', 'Leaf Wiki currently supports Linux x86-64')
    local root = Fs.absolute(path)
    local fd = C.open(root, DIRECTORY)
    assert(fd >= 0, 'Cannot open notebook folder')
    return setmetatable({ root = root, fd = tonumber(fd) }, Fs)
end

function Fs:parent(path, create)
    assert(type(path) == 'string' and path ~= '' and path:sub(1, 1) ~= '/'
        and not path:find('[%z\1-\31]'), 'Invalid file path')
    local parts = {}
    for part in path:gmatch('[^/]+') do
        assert(part ~= '.' and part ~= '..', 'Invalid file path')
        parts[#parts + 1] = part
    end
    local fd = C.openat(self.fd, '.', DIRECTORY)
    assert(fd >= 0, 'Notebook is closed')
    for index = 1, #parts - 1 do
        if create and C.mkdirat(fd, parts[index], 448) ~= 0 and ffi.errno() ~= 17 then
            C.close(fd); error('Cannot create page directory')
        end
        local next_fd = C.openat(fd, parts[index], DIRECTORY)
        C.close(fd)
        if next_fd < 0 then error('Missing or unsafe page directory') end
        fd = next_fd
    end
    return tonumber(fd), parts[#parts]
end

function Fs:read(path, maximum)
    local ok, parent, name = pcall(self.parent, self, path, false)
    if not ok then return nil end
    local fd = C.openat(parent, name, NOFOLLOW)
    C.close(parent)
    if fd < 0 then
        if ffi.errno() == 2 then return nil end
        error('Cannot read file safely: ' .. path)
    end
    local stamp = ffi.new('struct leaf_stat[1]')
    if stat_fd(fd, stamp) ~= 0 or bit.band(stamp[0].mode, 61440) ~= 32768
        or stamp[0].size > (maximum or 1024 * 1024) then
        C.close(fd); error('File is not a regular file or exceeds the size limit: ' .. path)
    end
    local chunks, size, buffer = {}, 0, ffi.new('char[65536]')
    while true do
        local bytes = tonumber(C.read(fd, buffer, 65536))
        if bytes > 0 then
            size = size + bytes
            if size > (maximum or 1024 * 1024) then C.close(fd); error('File exceeds size limit') end
            chunks[#chunks + 1] = ffi.string(buffer, bytes)
        elseif bytes == 0 then break
        elseif ffi.errno() ~= 4 then C.close(fd); error('Cannot read file') end
    end
    C.close(fd)
    return table.concat(chunks)
end

function Fs:file_exists(path)
    local parent, name = self:parent(path)
    local fd = C.openat(parent, name, NOFOLLOW)
    local err = ffi.errno()
    C.close(parent)
    if fd < 0 then assert(err == 2, 'Cannot inspect file: ' .. path); return false end
    local stamp = ffi.new('struct leaf_stat[1]')
    local regular = stat_fd(fd, stamp) == 0 and bit.band(stamp[0].mode, 61440) == 32768
    C.close(fd)
    assert(regular, 'Not a regular file: ' .. path)
    return true
end

function Fs:write(path, text)
    local parent, name = self:parent(path, true)
    serial = serial + 1
    local temporary = '.leaf-write-' .. tonumber(C.getpid()) .. '-' .. serial
    local fd = C.openat(parent, temporary, 1 + 64 + 128 + 524288, ffi.new('int', 384))
    if fd < 0 then C.close(parent); error('Cannot create temporary file') end
    local ok, err = pcall(function()
        local pointer, offset = ffi.cast('const char *', text), 0
        while offset < #text do
            local bytes = tonumber(C.write(fd, pointer + offset, #text - offset))
            if bytes > 0 then offset = offset + bytes
            elseif ffi.errno() ~= 4 then error('Cannot write file') end
        end
        assert(C.fsync(fd) == 0, 'Cannot flush file')
        assert(C.renameat(parent, temporary, parent, name) == 0, 'Cannot replace file')
        assert(C.fsync(parent) == 0, 'Cannot flush directory')
    end)
    C.close(fd)
    if not ok then C.unlinkat(parent, temporary, 0) end
    C.close(parent)
    assert(ok, err)
end

function Fs:remove(path)
    local parent, name = self:parent(path)
    local ok = C.unlinkat(parent, name, 0) == 0
    C.close(parent)
    assert(ok, 'Cannot remove file')
end

function Fs:move(source, target)
    local first, name = self:parent(source)
    local ok, second, destination = pcall(self.parent, self, target, true)
    if not ok then C.close(first); error(second) end
    local moved = C.renameat(first, name, second, destination) == 0
    C.close(first); C.close(second)
    assert(moved, 'Cannot move file or attachment directory')
end

function Fs:directory_exists(path)
    local ok, parent, name = pcall(self.parent, self, path)
    if not ok then return false end
    local fd = C.openat(parent, name, DIRECTORY)
    local err = ffi.errno()
    C.close(parent)
    if fd >= 0 then C.close(fd); return true end
    assert(err == 2, 'Unsafe or unreadable attachment directory')
    return false
end

function Fs:list(prefix, depth, attachments)
    prefix, depth = prefix or '', depth or 0
    assert(depth <= 16, 'Notebook nesting is limited to 16 levels')
    local fd
    if prefix == '' then fd = C.openat(self.fd, '.', DIRECTORY)
    else
        local parent, name = self:parent(prefix)
        fd = C.openat(parent, name, DIRECTORY); C.close(parent)
    end
    if fd < 0 then
        assert(not attachments or ffi.errno() == 2, 'Cannot list attachment directory: ' .. prefix)
        return {}
    end
    local stream = fd_open_dir(fd)
    if stream == nil then C.close(fd); error('Cannot list notebook') end
    local entries = {}
    while true do
        local item = read_dir(stream)
        if item == nil then break end
        local name = ffi.string(item.name)
        if name:sub(1, 1) ~= '.' then entries[#entries + 1] = { name = name, kind = tonumber(item.kind) } end
    end
    close_dir(stream)
    local pages = {}
    for _, entry in ipairs(entries) do
        local path = prefix == '' and entry.name or prefix .. '/' .. entry.name
        if entry.kind == 0 then
            local parent, name = self:parent(path)
            local probe = C.openat(parent, name, NOFOLLOW); C.close(parent)
            if probe >= 0 then
                local stamp = ffi.new('struct leaf_stat[1]')
                if stat_fd(probe, stamp) == 0 then
                    local mode = bit.band(stamp[0].mode, 61440)
                    entry.kind = mode == 16384 and 4 or mode == 32768 and 8 or 0
                end
                C.close(probe)
            end
        end
        if attachments and entry.kind == 8 and entry.name:match('^[%w_-]+%.%a+$')
            and ({ png = true, jpg = true, gif = true, webp = true })[entry.name:match('%.(.*)$')] then
            -- Image metadata is read through a confined, no-follow file handle.
            local parent, name = self:parent(path)
            local probe = C.openat(parent, name, NOFOLLOW)
            C.close(parent)
            assert(probe >= 0, 'Cannot inspect attachment: ' .. path)
            local stamp = ffi.new('struct leaf_stat[1]')
            local ok = stat_fd(probe, stamp) == 0 and bit.band(stamp[0].mode, 61440) == 32768
            local bytes = tonumber(stamp[0].size)
            C.close(probe)
            assert(ok, 'Cannot inspect regular attachment: ' .. path)
            pages[#pages + 1] = { file = entry.name, bytes = bytes }
        elseif not attachments and entry.kind == 4 and not entry.name:match('%.attachments$') then
            for _, child in ipairs(self:list(path, depth + 1)) do pages[#pages + 1] = child end
        elseif not attachments and entry.kind == 8 and entry.name:match('%.md$') then pages[#pages + 1] = path end
        assert(#pages <= 2000, attachments and 'Attachment directory is limited to 2,000 images: ' .. prefix
            or 'Notebook is limited to 2,000 pages')
    end
    table.sort(pages, attachments and function(a, b) return a.file < b.file end or nil)
    return pages
end

function Fs:close()
    if self.fd then C.close(self.fd); self.fd = nil end
end

function Fs:lock()
    local parent, name = self:parent('.leaf/lock', true)
    local fd = C.openat(parent, name, 2 + 64 + 131072 + 524288, ffi.new('int', 384))
    C.close(parent)
    if fd < 0 or C.flock(fd, 2 + 4) ~= 0 then
        if fd >= 0 then C.close(fd) end
        error('Notebook is already open or its lock cannot be acquired')
    end
    return function() C.close(fd) end
end
return Fs
