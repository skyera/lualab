#!/usr/bin/env luajit
-- Read-only duplicate finder. Windows / Linux 64-bit; bounded read buffers.
local ffi, bit = require('ffi'), require('bit')
assert(ffi.os == 'Windows' or (ffi.os == 'Linux' and ffi.abi('64bit')),
 'ffi_duplicates requires Windows or 64-bit Linux')
ffi.cdef[[int memcmp(const void *a, const void *b, size_t n);]]
local function windows_backend(native, shell)
ffi.cdef[[
typedef struct { uint32_t low, high; } DupFileTime;
typedef struct {
 uint32_t attributes; DupFileTime creation, access, write;
 uint32_t volume, size_high, size_low, links, index_high, index_low;
} DupFileInfo;
typedef struct {
 int64_t creation, access, write, change; uint32_t attributes;
} DupBasicInfo;
typedef struct { uint64_t volume; uint8_t id[16]; } DupIdInfo;
typedef struct {
 uint32_t attributes; DupFileTime creation, access, write;
 uint32_t size_high, size_low, reserved0, reserved1;
 uint16_t name[260], alternate[14];
} DupFindData;
void* __stdcall CreateFileW(const uint16_t*, uint32_t, uint32_t, void*, uint32_t, uint32_t, void*);
int __stdcall GetFileInformationByHandle(void*, DupFileInfo*);
int __stdcall GetFileInformationByHandleEx(void*, int, void*, uint32_t);
uint32_t __stdcall GetFileType(void*);
int __stdcall ReadFile(void*, void*, uint32_t, uint32_t*, void*);
int __stdcall CloseHandle(void*);
void* __stdcall FindFirstFileW(const uint16_t*, DupFindData*);
int __stdcall FindNextFileW(void*, DupFindData*);
int __stdcall FindClose(void*);
uint32_t __stdcall GetLastError(void);
uint32_t __stdcall GetFullPathNameW(const uint16_t*, uint32_t, uint16_t*, uint16_t**);
int __stdcall MultiByteToWideChar(unsigned int, uint32_t, const char*, int, uint16_t*, int);
int __stdcall WideCharToMultiByte(unsigned int, uint32_t, const uint16_t*, int, char*, int, const char*, int*);
const uint16_t* __stdcall GetCommandLineW(void);
uint16_t** __stdcall CommandLineToArgvW(const uint16_t*, int*);
void* __stdcall LocalFree(void*);
uint32_t __stdcall GetConsoleOutputCP(void);
int __stdcall SetConsoleOutputCP(uint32_t);
]]
local invalid = ffi.cast('void*', -1)
 native = native or ffi.load('kernel32')
 local M = {}
 local function err() return 'Windows error ' .. tonumber(native.GetLastError()) end
 function M.wide(s)
  if s == '' or s:find('\0', 1, true) then return nil, 'Empty path or embedded NUL' end
  local n = native.MultiByteToWideChar(65001, 8, s, #s, nil, 0)
  if n == 0 then return nil, 'Invalid UTF-8 path' end
  local out = ffi.new('uint16_t[?]', n + 1)
  if native.MultiByteToWideChar(65001, 8, s, #s, out, n) ~= n then return nil, err() end
  return out
 end
 function M.from_wide(s)
  local n = native.WideCharToMultiByte(65001, 0, s, -1, nil, 0, nil, nil)
  if n == 0 then return nil, err() end
  local out = ffi.new('char[?]', n)
  if native.WideCharToMultiByte(65001, 0, s, -1, out, n, nil, nil) ~= n then return nil, err() end
  return ffi.string(out, n - 1)
 end
 function M.path(path)
  path = path:gsub('/', '\\')
  -- Only filesystem paths: reject device namespaces (including named pipes).
  if path:sub(1,4) == '\\\\?\\' then
   if not path:match('^\\\\%?\\%a:\\') and path:sub(1,8):upper() ~= '\\\\?\\UNC\\' then
    return nil, 'Unsupported Windows device path'
   end
   return M.wide(path)
  end
  if path:sub(1,4) == '\\\\.\\' then return nil, 'Unsupported Windows device path' end
  local input, e = M.wide(path); if not input then return nil, e end
  local n = native.GetFullPathNameW(input, 0, nil, nil)
  if n == 0 then return nil, err() end
  local out = ffi.new('uint16_t[?]', n + 1)
  local written = native.GetFullPathNameW(input, n + 1, out, nil)
  if written == 0 or written > n then return nil, 'Cannot resolve Windows path' end
  local full; full, e = M.from_wide(out); if not full then return nil, e end
  if full:sub(1,2) == '\\\\' then full = '\\\\?\\UNC\\' .. full:sub(3)
  else full = '\\\\?\\' .. full end
  return M.wide(full)
 end
 local function open_path(path, access)
  local name, e = M.path(path); if not name then return nil, e end
  -- OPEN_EXISTING, shared read/write/delete; inspect reparse points themselves.
  local h = native.CreateFileW(name, access, 7, nil, 3, 0x02200000, nil)
  if h == invalid or h == nil then return nil, err() end
  return h
 end
 function M.close(h) native.CloseHandle(h) end
 function M.open(path) return open_path(path, 0x80000000) end
 function M.metadata(path, handle)
  local h, e = handle
  if not h then h, e = open_path(path, 0x80); if not h then return nil, e end end
  local function finish(value, message)
   if not handle then M.close(h) end
   return value, message
  end
  if native.GetFileType(h) ~= 1 then return finish(nil, 'Not a disk file') end
  local info = ffi.new('DupFileInfo[1]')
  if native.GetFileInformationByHandle(h, info) == 0 then return finish(nil, err()) end
  local attr = info[0].attributes
  if bit.band(attr, 0x400) ~= 0 then return finish({kind=0xa000}) end
  if info[0].size_high > 0x1fffff then return finish(nil, 'file size exceeds exact numeric range') end
  local basic, identity = ffi.new('DupBasicInfo[1]'), ffi.new('DupIdInfo[1]')
  if native.GetFileInformationByHandleEx(h, 0, basic, ffi.sizeof(basic)) == 0 or
     native.GetFileInformationByHandleEx(h, 18, identity, ffi.sizeof(identity)) == 0 then
   return finish(nil, err())
  end
  local hex = {}
  for i=0,15 do hex[#hex+1] = string.format('%02x', identity[0].id[i]) end
  local id = tostring(identity[0].volume) .. ':' .. table.concat(hex)
  local size = tonumber(info[0].size_high) * 4294967296 + tonumber(info[0].size_low)
  local signature = id .. ':' .. string.format('%.0f', size) .. ':' ..
   tostring(basic[0].write) .. ':' .. tostring(basic[0].change)
  return finish({id=id, signature=signature, size=size,
   kind=bit.band(attr, 16) ~= 0 and 0x4000 or 0x8000})
 end
 function M.read(h, buffer, size)
  local count = ffi.new('uint32_t[1]')
  if native.ReadFile(h, buffer, size, count, nil) == 0 then return nil, err() end
  return tonumber(count[0])
 end
 function M.join(path, name)
  -- Preserve drive-relative C:foo semantics, and drive/UNC roots.
  if path:match('^%a:$') then return path .. name end
  return path:gsub('[/\\]+$', '') .. '\\' .. name
 end
 function M.list(path, visit)
  local pattern, e = M.path(M.join(path, '*')); if not pattern then return nil, e end
  local data = ffi.new('DupFindData[1]')
  local h = native.FindFirstFileW(pattern, data)
  if h == invalid or h == nil then
   if native.GetLastError() == 2 then return true end
   return nil, err()
  end
  local message
  while true do
   local name; name, e = M.from_wide(data[0].name)
   if not name then message = e; break end
   if name ~= '.' and name ~= '..' then visit(name) end
   if native.FindNextFileW(h, data) == 0 then
    if native.GetLastError() ~= 18 then message = err() end
    break
   end
  end
  native.FindClose(h)
  if message then return nil, message end
  return true
 end
 function M.arguments(args)
  shell = shell or ffi.load('shell32')
  local count = ffi.new('int[1]')
  local argv = shell.CommandLineToArgvW(native.GetCommandLineW(), count)
  if argv == nil then return nil, err() end
  local result, message = {}, nil
  -- LuaJIT has already parsed interpreter/script arguments; replace only its
  -- trailing script arguments, avoiding the CRT's lossy ANSI conversion.
  if count[0] < #args then message = 'Cannot decode Windows arguments' else
   for i=tonumber(count[0]) - #args,tonumber(count[0])-1 do
    local text, e = M.from_wide(argv[i])
    if not text then message = e; break end
    result[#result+1] = text
   end
  end
  native.LocalFree(argv)
  if message then return nil, message end
  return result
 end
 function M.console_utf8()
  local previous = native.GetConsoleOutputCP()
  if previous ~= 0 and native.SetConsoleOutputCP(65001) ~= 0 then
   return function() native.SetConsoleOutputCP(previous) end
  end
 end
 return M
end

local function linux_backend()
assert(ffi.os == 'Linux' and ffi.abi('64bit'), 'ffi_duplicates requires 64-bit Linux')
ffi.cdef[[
typedef struct { int64_t sec; uint32_t nsec; int32_t reserved; } dup_timestamp;
typedef struct {
 uint32_t mask, blksize; uint64_t attributes; uint32_t nlink, uid, gid;
 uint16_t mode, spare0; uint64_t ino, size, blocks, attributes_mask;
 dup_timestamp atime, btime, ctime, mtime;
 uint32_t rdev_major, rdev_minor, dev_major, dev_minor; uint64_t spare[14];
} dup_stat;
typedef struct { uint64_t ino; int64_t off; unsigned short reclen;
 unsigned char type; char name[256]; } dup_dirent;
void *opendir(const char *name);
dup_dirent *readdir(void *dir);
int closedir(void *dir);
int statx(int fd, const char *path, int flags, unsigned int mask, dup_stat *out);
int open(const char *path, int flags, ...);
long read(int fd, void *buf, unsigned long count);
int close(int fd);
char *strerror(int err);
]]
local C, M = ffi.C, {}
local function err() return ffi.string(C.strerror(ffi.errno())) end
function M.metadata(path, fd)
 local s = ffi.new('dup_stat[1]')
 if C.statx(fd or -100, fd and '' or path, fd and 4096 or 256, 0x7ff, s) ~= 0 then return nil, err() end
 s = s[0]
 if bit.band(s.mask, 0x3c3) ~= 0x3c3 then return nil, 'incomplete filesystem metadata' end
 if s.size > 9007199254740991ULL then return nil, 'file size exceeds exact numeric range' end
 local id = s.dev_major .. ':' .. s.dev_minor .. ':' .. tostring(s.ino)
 local signature = id .. ':' .. tostring(s.size) .. ':' .. tostring(s.mtime.sec) .. ':' .. s.mtime.nsec .. ':' .. tostring(s.ctime.sec) .. ':' .. s.ctime.nsec
 return {id=id, signature=signature, size=tonumber(s.size), kind=bit.band(s.mode, 0xf000)}
end

function M.open(path)
 local fd = C.open(path, 0x20000 + 0x800 + 0x80000)
 if fd < 0 then return nil, err() end
 return fd
end
function M.read(fd, buf, size)
 while true do
  local n = tonumber(C.read(fd, buf, size))
  if n >= 0 then return n end
  if ffi.errno() ~= 4 then return nil, err() end
 end
end
function M.close(fd) C.close(fd) end
function M.join(path, name) return path:gsub('/+$', '') .. '/' .. name end
function M.list(path, visit)
 local d = C.opendir(path)
 if d == nil then return nil, err() end
 local message
 while true do
  ffi.errno(0)
  local entry = C.readdir(d)
  if entry == nil then
   if ffi.errno() ~= 0 then message = err() end
   break
  end
  local name = ffi.string(entry.name)
  if name ~= '.' and name ~= '..' then visit(name) end
 end
 C.closedir(d)
 if message then return nil, message end
 return true
end
return M
end

local backend = ffi.os == 'Windows' and windows_backend() or linux_backend()
local function new(backend)
local M = {}
local metadata = backend.metadata
local function open_checked(file)
 local fd, e = backend.open(file.path)
 if not fd then return nil, e end
 local s, e = metadata(file.path, fd)
 if not s or s.kind ~= 0x8000 or s.signature ~= file.signature then
  backend.close(fd); return nil, e or 'file changed during scan'
 end
 return fd
end
local function read_chunk(fd, buf)
 local used = 0
 while used < 65536 do
  local n, e = backend.read(fd, buf + used, 65536 - used)
  if not n then return nil, e end
  if n == 0 then break end
  used = used + n
 end
 return used
end
local function stable(file, fd)
 local s = metadata(file.path, fd)
 return s and s.signature == file.signature
end
function M.hash(file)
 local fd, e = open_checked(file)
 if not fd then return nil, e end
 local buf, h, total = ffi.new('uint8_t[65536]'), 5381, 0
 while true do
  local n; n, e = read_chunk(fd, buf)
  if not n then break end
  if n == 0 then break end
  total = total + n
  for i=0,n-1 do h = bit.bxor(bit.tobit(h * 33), buf[i]) end
 end
 local ok = stable(file, fd) and total == file.size
 backend.close(fd)
 if e or not ok then return nil, e or 'file changed during hashing' end
 return tostring(h)
end
function M.equal(a, b)
 local fa, e = open_checked(a); if not fa then return nil, e, a end
 local fb; fb, e = open_checked(b); if not fb then backend.close(fa); return nil, e, b end
 local ba, bb = ffi.new('uint8_t[65536]'), ffi.new('uint8_t[65536]')
 local same, total, failed_file = true, 0, nil
 while true do
  local na, ea = read_chunk(fa, ba); local nb, eb = read_chunk(fb, bb)
  if not na or not nb then same=nil; e=ea or eb; failed_file=not na and a or b; break end
  total = total + na
  if na ~= nb or ffi.C.memcmp(ba, bb, na) ~= 0 then same=false; break end
  if na == 0 then break end
 end
 if not stable(a, fa) then same=nil; e='file changed during comparison'; failed_file=a
 elseif not stable(b, fb) then same=nil; e='file changed during comparison'; failed_file=b
 elseif same and total ~= a.size then same=nil; e='file changed during comparison'; failed_file=a end
 backend.close(fa); backend.close(fb)
 return same, e, failed_file
end
function M.scan(roots, options)
 options = options or {}
 local result = {groups={}, errors={}, files=0, redundant_bytes=0, skipped_links=0}
 local seen, dirs, sizes, pending = {}, {}, {}, {}
 local function warning(path, message) result.errors[#result.errors+1]={path=path, message=message} end
 for _, root in ipairs(roots) do pending[#pending+1]=root end
 while #pending > 0 do
  local path=table.remove(pending)
  local s, e=metadata(path)
  if not s then warning(path,e)
  elseif s.kind == 0xa000 then result.skipped_links=result.skipped_links+1
  elseif s.kind == 0x4000 and not dirs[s.id] then
   dirs[s.id]=true
   local ok, message = backend.list(path, function(name)
    pending[#pending+1] = backend.join(path, name)
   end)
   if not ok then warning(path, message) end
  elseif s.kind == 0x8000 and not seen[s.id] then
   seen[s.id]=true; s.path=path; result.files=result.files+1
   if s.size >= (options.min_size or 0) then
    sizes[s.size]=sizes[s.size] or {}; table.insert(sizes[s.size],s)
   end
  end
 end
 for _, files in pairs(sizes) do
  if #files > 1 then
   table.sort(files,function(a,b) return a.path < b.path end)
   local buckets={}
   for _, file in ipairs(files) do
    local hash,e=(options.hash or M.hash)(file)
    if not hash then warning(file.path,e) else
     buckets[hash]=buckets[hash] or {}; table.insert(buckets[hash],file)
    end
   end
   for _, bucket in pairs(buckets) do
    local groups={}
    for _, file in ipairs(bucket) do
     local found, failed=false,false
     for _, group in ipairs(groups) do
      while #group > 0 do
       local same,e,bad=M.equal(group[1],file)
       if same == nil then
        warning(bad.path,e)
        if bad == file then failed=true; break end
        table.remove(group,1)
       else
        if same then table.insert(group,file); found=true end
        break
       end
      end
      if found or failed then break end
     end
     if not found and not failed then groups[#groups+1]={file} end
    end
    for _, group in ipairs(groups) do
     if #group > 1 then
      local paths={}; for _, file in ipairs(group) do paths[#paths+1]=file.path end
      result.groups[#result.groups+1]={size=group[1].size, paths=paths}
      result.redundant_bytes=result.redundant_bytes+group[1].size*(#group-1)
     end
    end
   end
  end
 end
 table.sort(result.groups,function(a,b) if a.size ~= b.size then return a.size>b.size end return a.paths[1]<b.paths[1] end)
 table.sort(result.errors,function(a,b) return a.path<b.path end)
 return result
end
function M.render(r)
 local lines={}
 for i,g in ipairs(r.groups) do
  lines[#lines+1]=string.format('Group %d: %d files, %.0f bytes each',i,#g.paths,g.size)
  for _,path in ipairs(g.paths) do lines[#lines+1]='  '..string.format('%q',path):gsub('\\\n','\\n') end
 end
 lines[#lines+1]=string.format('%d duplicate group(s); %.0f redundant content bytes; %d files scanned',#r.groups,r.redundant_bytes,r.files)
 return table.concat(lines,'\n')..'\n'
end
local function json_string(value)
 return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
  if c == '"' then return '\\"' end
  if c == '\\' then return '\\\\' end
  return string.format('\\u%04x', c:byte())
 end) .. '"'
end
function M.to_json(r)
 local groups, errors = {}, {}
 for _, group in ipairs(r.groups) do
  local paths = {}
  for _, path in ipairs(group.paths) do paths[#paths+1] = json_string(path) end
  groups[#groups+1] = '{"size":' .. string.format('%.0f', group.size) ..
   ',"paths":[' .. table.concat(paths, ',') .. ']}'
 end
 for _, error in ipairs(r.errors) do
  errors[#errors+1] = '{"path":' .. json_string(error.path) ..
   ',"message":' .. json_string(error.message) .. '}'
 end
 return '{"groups":[' .. table.concat(groups, ',') .. '],"errors":[' ..
  table.concat(errors, ',') .. '],"files":' .. string.format('%.0f', r.files) ..
  ',"redundant_bytes":' .. string.format('%.0f', r.redundant_bytes) ..
  ',"skipped_links":' .. string.format('%.0f', r.skipped_links) .. '}'
end
function M.main(args)
 local roots, opts, json_output={}, {}, false
 local literal=false
 for _,a in ipairs(args) do
  if not literal and a=='--' then literal=true
  elseif not literal and (a=='--help' or a=='-h') then
   io.write('Usage: luajit ffi_duplicates.lua [--json] [--min-size=BYTES] [--] [PATH ...]\nDefault PATH: .; recursive, read-only; skips symlinks/reparse points and repeated hard links.\nExit: 0 complete, 1 scan errors, 2 invalid arguments. Windows / Linux 64-bit.\n'); return 0
  elseif not literal and a=='--json' then json_output=true
  elseif not literal and a:match('^%-%-min%-size=') then
   local value=a:match('^%-%-min%-size=(%d+)$'); local n=tonumber(value)
   if not n or n>9007199254740991 then io.stderr:write('Invalid minimum size\n'); return 2 end
   opts.min_size=n
  elseif not literal and a:sub(1,1)=='-' then io.stderr:write('Unknown option: ',string.format('%q',a),'\n'); return 2
  else roots[#roots+1]=a end
 end
 if #roots==0 then roots={'.'} end
 local r=M.scan(roots,opts)
 if json_output then io.write(M.to_json(r),'\n') else io.write(M.render(r)) end
 for _,e in ipairs(r.errors) do io.stderr:write(string.format('%q: %q\n',e.path,e.message)) end
 return #r.errors>0 and 1 or 0
end
return M
end
local M = new(backend)
M.new = new
M.windows_backend = windows_backend
if ... == 'ffi_duplicates' then return M end
local args, message = arg
if backend.arguments then args, message = backend.arguments(arg) end
if not args then io.stderr:write(message, '\n'); os.exit(2) end
local restore = backend.console_utf8 and backend.console_utf8()
local code = M.main(args)
if restore then restore() end
os.exit(code)
