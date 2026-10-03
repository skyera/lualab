#!/usr/bin/env luajit
-- Native Windows fixtures on Windows; injectable Win32 backend on Linux.
local ffi, bit = require('ffi'), require('bit')
local finder = require('ffi_duplicates')
local module = {new=finder.windows_backend}
local json = require('json')
local count = 0
local function check(ok, message) assert(ok, message); count=count+1 end
if ffi.os == 'Windows' then
 ffi.cdef[[
 uint32_t __stdcall GetTempPathW(uint32_t, uint16_t*);
 unsigned int __stdcall GetTempFileNameW(const uint16_t*, const uint16_t*, unsigned int, uint16_t*);
 int __stdcall CreateDirectoryW(const uint16_t*, void*);
 int __stdcall DeleteFileW(const uint16_t*);
 int __stdcall RemoveDirectoryW(const uint16_t*);
 int __stdcall CreateHardLinkW(const uint16_t*, const uint16_t*, void*);
 int __stdcall WriteFile(void*, const void*, uint32_t, uint32_t*, void*);
 ]]
 local native, fs = ffi.load('kernel32'), module.new()
 local temp, reserved = ffi.new('uint16_t[32768]'), ffi.new('uint16_t[260]')
 check(native.GetTempPathW(32768,temp)>0, 'temporary directory')
 check(native.GetTempFileNameW(temp,fs.wide('dup'),0,reserved)~=0, 'temporary name')
 local root=assert(fs.from_wide(reserved))
 check(native.DeleteFileW(reserved)~=0 and native.CreateDirectoryW(reserved,nil)~=0,'fixture directory')
 local paths, dirs={}, {}
 local function write(name,data)
  local path=fs.join(root,name); local w=assert(fs.path(path))
  local h=native.CreateFileW(w,0x40000000,7,nil,2,128,nil)
  assert(h~=ffi.cast('void*',-1)); local written=ffi.new('uint32_t[1]')
  local ok=native.WriteFile(h,data,#data,written,nil); native.CloseHandle(h)
  assert(ok~=0 and written[0]==#data);paths[#paths+1]=path; return path
 end
 local function directory(name)
  local path=fs.join(root,name); assert(native.CreateDirectoryW(fs.path(path),nil)~=0)
  dirs[#dirs+1]=path;return path
 end
 local ok,e=xpcall(function()
  directory('nested')
  local data=string.rep('\0\255hello',10000)
  local a=write('a.bin',data);write('nested\\b.bin',data)
  write('different.bin',data:sub(1,-2)..'X')
  write('empty-a','');write('empty-b','')
  write('中文-😀.txt','unicode');write('nested\\unicode-copy.txt','unicode')
  local hard=fs.join(root,'hard.bin')
  check(native.CreateHardLinkW(fs.path(hard),fs.path(a),nil)~=0,'native hard link')
  paths[#paths+1]=hard
  local result=finder.scan({root,fs.join(root,'nested'),a})
  check(#result.errors==0 and result.files==7,'native traversal and identity deduplication')
  check(#result.groups==3 and result.redundant_bytes==#data+7,'native binary/empty/Unicode duplicates')
  local collided=finder.scan({root},{hash=function() return 'collision' end})
  check(#collided.groups==3,'native collision confirmation')
  check(#finder.scan({root},{min_size=1}).groups==2,'native minimum size')
  check(#finder.scan({fs.join(root,'absent')}).errors==1,'native missing path')
  local decoded=json.decode(finder.to_json(result))
  check(#decoded.groups==3,'native JSON roundtrip')
  local long='long';directory(long)
  for i=1,5 do long=long..'\\'..string.rep('x',55);directory(long) end
  local l=write(long..'\\long.bin','long');write('long-copy.bin','long')
  check(#l>260 and #finder.scan({l,fs.join(root,'long-copy.bin')}).groups==1,'native extended-length paths')
  local p=io.popen('"'..(arg[-1] or 'luajit')..'" ffi_duplicates.lua --json "'..root..'" 2>&1')
  assert(p);local out=p:read('*a');p:close()
  check(#json.decode(out).groups==4,'native CLI JSON')
 end,debug.traceback)
 for i=#paths,1,-1 do native.DeleteFileW(fs.path(paths[i])) end
 for i=#dirs,1,-1 do native.RemoveDirectoryW(fs.path(dirs[i])) end
 native.RemoveDirectoryW(fs.path(root))
 if not ok then error(e) end
 print(string.format('PASS: %d native Windows duplicate finder checks',count))
 return
end

-- A Win32 API double exercises the actual Windows backend, not a replacement
-- filesystem backend. Struct writes, UTF conversion, flags and resource cleanup
-- all pass through the production functions.
local function units(text)
 local result, i={},1
 while i<=#text do
  local b=text:byte(i);local n,c
  if b<128 then n,c=1,b
  elseif b>=194 and b<224 then n,c=2,b-192
  elseif b>=224 and b<240 then n,c=3,b-224
  elseif b>=240 and b<245 then n,c=4,b-240
  else return nil end
  for j=1,n-1 do
   local v=text:byte(i+j);if not v or v<128 or v>=192 then return nil end
   c=c*64+v-128
  end
  if c<0x10000 then result[#result+1]=c else
   c=c-0x10000;result[#result+1]=0xd800+math.floor(c/1024);result[#result+1]=0xdc00+c%1024
  end
  i=i+n
 end
 return result
end
local function utf8(c)
 if c<128 then return string.char(c) end
 if c<2048 then return string.char(192+math.floor(c/64),128+c%64) end
 if c<65536 then return string.char(224+math.floor(c/4096),128+math.floor(c/64)%64,128+c%64) end
 return string.char(240+math.floor(c/262144),128+math.floor(c/4096)%64,128+math.floor(c/64)%64,128+c%64)
end
local function text(w)
 local out,i={},0
 while w[i]~=0 do
  local c=tonumber(w[i]);i=i+1
  if c>=0xd800 and c<=0xdbff then c=0x10000+(c-0xd800)*1024+tonumber(w[i])-0xdc00;i=i+1 end
  out[#out+1]=utf8(c)
 end
 return table.concat(out)
end
local function put(w,s)
 local u=assert(units(s));for i,v in ipairs(u) do w[i-1]=v end;w[#u]=0;return #u
end
local invalid=ffi.cast('void*',-1)
local state={error=0,handles={},finds={},files={},cp=437}
local native={}
function native.GetLastError() return state.error end
function native.MultiByteToWideChar(cp,flags,s,n,out,cap)
 check(cp==65001 and flags==8,'UTF-8 conversion flags')
 local u=units(s:sub(1,n));if not u then state.error=1113;return 0 end
 if out then for i,v in ipairs(u) do out[i-1]=v end end
 return #u
end
function native.WideCharToMultiByte(cp,flags,w,n,out,cap)
 assert(cp==65001 and n==-1)
 local s=text(w);if out then ffi.copy(out,s..'\0',#s+1) end;return #s+1
end
function native.GetFullPathNameW(w,n,out)
 local s=text(w)
 if not s:match('^%a:\\') and s:sub(1,2)~='\\\\' then s='C:\\cwd\\'..s end
 if out then return put(out,s) end
 return #assert(units(s))+1
end
function native.CreateFileW(w,access,share,security,creation,flags)
 check(share==7 and creation==3 and bit.band(flags,0x02200000)==0x02200000,'open flags and sharing')
 local path=text(w);local f=state.files[path]
 if not f then state.error=2;return invalid end
 if f.denied then state.error=5;return invalid end
 local h={file=f,offset=0};state.handles[h]=true;return h
end
function native.CloseHandle(h) assert(state.handles[h]);state.handles[h]=nil;return 1 end
function native.GetFileType(h) return h.file.type or 1 end
function native.GetFileInformationByHandle(h,out)
 if h.file.meta_error then state.error=5;return 0 end
 local f=h.file;out[0].attributes=f.attr or 0
 local size=f.size or #(f.data or '')
 out[0].size_high=math.floor(size/4294967296);out[0].size_low=size%4294967296
 return 1
end
function native.GetFileInformationByHandleEx(h,class,out,size)
 local f=h.file
 if f.ex_error then state.error=50;return 0 end
 if class==0 then
  assert(size==40);out[0].write=f.time or 1;out[0].change=f.change or 1
 elseif class==18 then
  assert(size==24);out[0].volume=f.volume or 123
  out[0].id[0]=f.id;out[0].id[15]=f.tail or 0
 else error('Unexpected information class') end
 return 1
end
function native.ReadFile(h,buf,size,out)
 local f=h.file
 if f.read_error then state.error=5;return 0 end
 local s=f.data:sub(h.offset+1,h.offset+math.min(size,10000))
 ffi.copy(buf,s,#s);h.offset=h.offset+#s;out[0]=#s;return 1
end
function native.FindFirstFileW(w,data)
 local path=text(w):gsub('\\%*$','');local dir=state.files[path]
 if not dir then state.error=3;return invalid end
 if dir.denied_list then state.error=5;return invalid end
 local entries=dir.names or {}
 if #entries==0 then state.error=2;return invalid end
 local h={dir=dir,index=1};state.finds[h]=true;put(data[0].name,entries[1]);return h
end
function native.FindNextFileW(h,data)
 if h.dir.enum_error then state.error=5;return 0 end
 h.index=h.index+1
 if h.index>#h.dir.names then state.error=18;return 0 end
 put(data[0].name,h.dir.names[h.index]);return 1
end
function native.FindClose(h) assert(state.finds[h]);state.finds[h]=nil;return 1 end
function native.GetConsoleOutputCP() return state.cp end
function native.SetConsoleOutputCP(cp) state.cp=cp;return 1 end
local command_buffers={}
local shell={}
function native.GetCommandLineW() return 'mock command line' end
function shell.CommandLineToArgvW(command,count_out)
 local args={'luajit.exe','ffi_duplicates.lua','--json','C:\\中文-😀'}
 local ptrs=ffi.new('uint16_t*[?]',#args)
 for i,s in ipairs(args) do local w=ffi.new('uint16_t[?]',#s+1);put(w,s);command_buffers[i]=w;ptrs[i-1]=w end
 command_buffers.ptrs=ptrs;count_out[0]=#args;return ptrs
end
function native.LocalFree(ptr) state.freed=true;return nil end
local fs=module.new(native,shell)
check(ffi.sizeof('DupFileInfo')==52 and ffi.sizeof('DupFindData')==592,'Win32 struct sizes')
check(fs.from_wide(assert(fs.wide('中文-😀')))== '中文-😀','Unicode and surrogate-pair conversion')
check(fs.wide('\255')==nil and fs.wide('a\0b')==nil,'invalid UTF-8 and embedded NUL rejected')
check(text(assert(fs.path('C:/photos')))== '\\\\?\\C:\\photos','drive path extended prefix')
check(text(assert(fs.path('\\\\server\\share\\folder')))== '\\\\?\\UNC\\server\\share\\folder','UNC extended prefix')
check(text(assert(fs.path('.')))== '\\\\?\\C:\\cwd\\.','relative path resolution')
check(text(assert(fs.path('\\\\?\\C:\\long')))== '\\\\?\\C:\\long','existing extended prefix')
check(fs.path('\\\\.\\pipe\\test')==nil and fs.path('\\\\?\\GLOBALROOT\\x')==nil,'device paths rejected')
check(fs.join('C:\\','a')=='C:\\a' and fs.join('C:','a')=='C:a','drive roots and drive-relative joins')
check(fs.join('\\\\server\\share\\','a')=='\\\\server\\share\\a','UNC join')
local decoded=assert(fs.arguments({'--json','ANSI-lossy-name'}))
check(decoded[2]=='C:\\中文-😀' and state.freed,'Unicode command arguments and allocation cleanup')
local restore=fs.console_utf8();check(state.cp==65001,'UTF-8 console output');restore();check(state.cp==437,'console code page restored')
local base='\\\\?\\C:\\fixture'
state.files[base]={id=1,attr=16,names={'.','..','a','b','other','empty-a','empty-b','中文-😀','hard','junction','broken'}}
local data=string.rep('\0\255abc',14000)
state.files[base..'\\a']={id=2,data=data}
state.files[base..'\\b']={id=3,data=data}
state.files[base..'\\other']={id=4,data=data:sub(1,-2)..'X'}
state.files[base..'\\empty-a']={id=5,data=''}
state.files[base..'\\empty-b']={id=6,data=''}
state.files[base..'\\中文-😀']={id=7,data='unique'}
state.files[base..'\\hard']=state.files[base..'\\a']
state.files[base..'\\junction']={id=8,attr=0x410}
state.files[base..'\\broken']={id=9,attr=0x400}
local winfinder=finder.new(fs)
local r=winfinder.scan({'C:\\fixture','C:\\fixture','C:\\fixture\\a'})
check(#r.errors==0 and #r.groups==2 and r.files==6,'shared scanner with Windows backend')
check(r.redundant_bytes==#data and r.skipped_links==2,'Windows hard links and reparse points')
local collisions=winfinder.scan({'C:\\fixture'},{hash=function() return 'collision' end})
check(#collisions.groups==2 and #collisions.groups[1].paths==2,'Windows byte comparison rejects collisions')
check(#winfinder.scan({'C:\\fixture'},{min_size=1}).groups==1,'Windows minimum size')
check(#winfinder.scan({'C:\\missing'}).errors==1,'missing Windows path')
local f=assert(fs.metadata('C:\\fixture\\a'));f.path='C:\\fixture\\a'
state.files[base..'\\a'].change=2
check(winfinder.hash(f)==nil,'change timestamp prevents stale read')
state.files[base..'\\a'].change=1
state.files[base..'\\a'].read_error=true
check(winfinder.hash(f)==nil,'ReadFile errors propagate')
state.files[base..'\\a'].read_error=nil
state.files[base..'\\a'].denied=true
check(fs.open('C:\\fixture\\a')==nil,'CreateFile access errors')
state.files[base..'\\a'].denied=nil
state.files[base..'\\a'].meta_error=true
check(fs.metadata('C:\\fixture\\a')==nil,'metadata errors close handles')
state.files[base..'\\a'].meta_error=nil
state.files[base..'\\a'].ex_error=true
check(fs.metadata('C:\\fixture\\a')==nil,'extended metadata errors close handles')
state.files[base..'\\a'].ex_error=nil
state.files[base..'\\a'].size=9007199254740992
check(fs.metadata('C:\\fixture\\a')==nil,'inexact Windows file sizes rejected')
state.files[base..'\\a'].size=nil
state.files[base].enum_error=true
check(fs.list('C:\\fixture',function() end)==nil,'enumeration error propagated')
state.files[base].enum_error=nil
state.files[base].names={}
check(fs.list('C:\\fixture',function() error('empty directory visited') end),'empty Windows directory')
check(next(state.handles)==nil and next(state.finds)==nil,'all native handles closed')
check(#json.decode(winfinder.to_json(r)).groups==2,'Windows result JSON roundtrip')
print(string.format('PASS: %d Windows backend checks (Win32 API double; native runtime unavailable)',count))
