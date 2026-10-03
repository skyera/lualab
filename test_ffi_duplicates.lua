#!/usr/bin/env luajit
local ffi = require('ffi')
if ffi.os == 'Windows' then
 dofile('test_ffi_duplicates_windows.lua')
 return
end
local finder = require('ffi_duplicates')
local json = require('json')
ffi.cdef[[
char *mkdtemp(char *template);
int mkdir(const char *path, unsigned int mode);
int symlink(const char *target, const char *path);
int link(const char *oldpath, const char *newpath);
int unlink(const char *path);
int rmdir(const char *path);
int chmod(const char *path, unsigned int mode);
unsigned int geteuid(void);
int mkfifo(const char *path, unsigned int mode);
]]
local template=ffi.new('char[?]',64,'/tmp/lualab-duplicates-XXXXXX')
assert(ffi.C.mkdtemp(template) ~= nil)
local root=ffi.string(template)
local paths, directories={}, {}
local count=0
local function check(condition, message)
 assert(condition,message); count=count+1
end
local function write(name,data)
 local path=root..'/'..name
 local f=assert(io.open(path,'wb')); assert(f:write(data)); assert(f:close())
 paths[#paths+1]=path; return path
end
local function directory(name)
 local path=root..'/'..name; assert(ffi.C.mkdir(path,448)==0)
 directories[#directories+1]=path; return path
end
local function quote(s) return "'"..s:gsub("'", "'\\''").."'" end
local function cli(arguments)
 local command=quote(arg[-1] or 'luajit')..' ffi_duplicates.lua '..arguments..' 2>&1'
 local p=assert(io.popen(command..'; printf "\\nSTATUS:%s" "$?"'))
 local output=p:read('*a'); p:close()
 local status=assert(tonumber(output:match('STATUS:(%d+)$')))
 return output:gsub('\nSTATUS:%d+$',''),status
end
local ok,e=xpcall(function()
 check(ffi.sizeof('dup_stat')==256,'statx ABI size')
 directory('nested')
 local bytes=string.rep('\0\255hello\n',20000)
 local a=write('a.bin',bytes)
 write('nested/b.bin',bytes)
 write('same-size.bin',bytes:sub(1,-2)..'X')
 write('empty-a',''); write('empty-b','')
 write('unique','unique')
 write('quote\' newline\n\27.bin','special')
 write('nested/special.bin','special')
 local hard=root..'/hard'; assert(ffi.C.link(a,hard)==0); paths[#paths+1]=hard
 local loop=root..'/nested/loop'; assert(ffi.C.symlink(root,loop)==0); paths[#paths+1]=loop
 local broken=root..'/broken'; assert(ffi.C.symlink(root..'/absent',broken)==0); paths[#paths+1]=broken
 local r=finder.scan({root,root..'/nested',a})
 check(#r.errors==0,'scan errors')
 check(r.files==8,'hard links and overlapping roots counted once')
 check(#r.groups==3,'binary, empty and special groups')
 check(r.groups[1].size==#bytes and #r.groups[1].paths==2,'large binary group')
 check(r.redundant_bytes==#bytes+7,'redundant content size')
 check(r.skipped_links==2,'symlink loop and dangling link skipped')
 local filtered=finder.scan({root},{min_size=1})
 check(#filtered.groups==2,'minimum size excludes empty files')
 local collided=finder.scan({root},{hash=function() return 'collision' end})
 check(#collided.groups==3 and #collided.groups[1].paths==2,'exact verification rejects hash collisions')
 check(#finder.scan({root..'/unique'}).groups==0,'single file')
 check(#finder.scan({root..'/absent'}).errors==1,'missing root reported')
 local empty=directory('empty-dir')
 check(#finder.scan({empty}).groups==0,'empty directory')
 local rendered=finder.render(r)
 check(not rendered:find('\27',1,true),'terminal escapes quoted')
 check(rendered:find('\\n',1,true)~=nil,'newline names escaped')
 check(finder.render({groups={},files=0,redundant_bytes=0}):find('0 duplicate',1,true)~=nil,'empty renderer')
 local long=finder.render({groups={{size=1,paths={string.rep('x',4096),'percent%'}}},files=2,redundant_bytes=1})
 check(long:find('percent%',1,true)~=nil,'long and percent paths render safely')
 local out,status=cli('--json '..quote(root))
 check(status==0,'JSON CLI success')
 local parsed=json.decode(out)
 check(#parsed.groups==3 and parsed.redundant_bytes==#bytes+7,'JSON CLI roundtrip')
 local controls = '\\"'
 for i=0,31 do controls=controls..string.char(i) end
 local encoded=finder.to_json({groups={},errors={{path=controls,message=controls}},files=0,redundant_bytes=0,skipped_links=0})
 local escaped=json.decode(encoded)
 check(escaped.errors[1].path==controls and escaped.errors[1].message==controls,'standalone JSON escapes every control character')
 out,status=cli(quote(root))
 check(status==0 and out:find('3 duplicate group',1,true)~=nil,'text CLI output')
 out,status=cli('--help'); check(status==0 and out:find('Usage:',1,true)~=nil,'help')
 out,status=cli('--wat'); check(status==2 and out:find('Unknown option',1,true)~=nil,'unknown flag')
 out,status=cli('--min-size=-1'); check(status==2,'negative size')
 out,status=cli('--min-size=9007199254740992'); check(status==2,'inexact size')
 out,status=cli(quote(root..'/absent')); check(status==1 and out:find('No such file',1,true)~=nil,'error visible and nonzero status')
 out,status=cli('-- '..quote(root)); check(status==0,'literal arguments')
 directory('mutating'); local ma=write('mutating/a','abc'); write('mutating/b','abc')
 local changed=false
 local mutation=finder.scan({root..'/mutating'},{hash=function(file)
  local h,err=finder.hash(file)
  if not changed then
   changed=true; local f=assert(io.open(file.path,'wb')); f:write('changed'); f:close()
  end
  return h,err
 end})
 check(#mutation.groups==0 and #mutation.errors>0,'changed file cannot be reported as duplicate')
 directory('vanishing'); write('vanishing/a','abc'); write('vanishing/b','abc')
 local removed=false
 local vanished=finder.scan({root..'/vanishing'},{hash=function(file)
  if not removed then removed=true; ffi.C.unlink(file.path) end
  return finder.hash(file)
 end})
 check(#vanished.groups==0 and #vanished.errors==1,'removed file error')
 directory('replaced'); write('replaced/a','abc'); write('replaced/b','abc')
 local replaced=false
 local replacement=finder.scan({root..'/replaced'},{hash=function(file)
  if not replaced then
   replaced=true; assert(ffi.C.unlink(file.path)==0)
   assert(ffi.C.mkfifo(file.path,384)==0)
  end
  return finder.hash(file)
 end})
 check(#replacement.groups==0 and #replacement.errors==1,'replacement FIFO rejected without blocking')
 -- Regression: representative failures must preserve surviving duplicates.
 for _, kind in ipairs({'removed', 'changed', 'candidate', 'multiple'}) do
  local dir=directory('recovery-'..kind)
  write('recovery-'..kind..'/a','same'); write('recovery-'..kind..'/b','same')
  write('recovery-'..kind..'/c','same'); write('recovery-'..kind..'/d','same')
  local result=finder.scan({dir},{hash=function(file)
   local h,err=finder.hash(file)
   if file.path==dir..'/d' then
    if kind=='changed' then
     local f=assert(io.open(dir..'/a','wb'));f:write('xxxx');f:close()
    elseif kind=='candidate' then assert(os.remove(dir..'/c'))
    else
     assert(os.remove(dir..'/a'))
     if kind=='multiple' then assert(os.remove(dir..'/b')) end
    end
   end
   return h,err
  end})
  local expected=kind=='multiple' and 2 or 3
  check(#result.groups==1 and #result.groups[1].paths==expected,'recover after '..kind..' failure')
  check(#result.errors==(kind=='multiple' and 2 or 1),'report failed files once: '..kind)
  check(result.errors[1].path==dir..(kind=='candidate' and '/c' or '/a'),'identify failed path: '..kind)
 end
 -- End representative regressions.
 if ffi.C.geteuid() ~= 0 then
  directory('unreadable'); local denied=write('unreadable/a','abc'); write('unreadable/b','abc')
  assert(ffi.C.chmod(denied,0)==0)
  local unreadable=finder.scan({root..'/unreadable'})
  check(#unreadable.groups==0 and #unreadable.errors==1,'permission denied reported')
  assert(ffi.C.chmod(denied,384)==0)
 end
end,debug.traceback)
for i=#paths,1,-1 do ffi.C.unlink(paths[i]) end
for i=#directories,1,-1 do ffi.C.rmdir(directories[i]) end
ffi.C.rmdir(root)
if not ok then io.stderr:write(e,'\n'); os.exit(1) end
print(string.format('PASS: %d duplicate finder checks',count))

-- Also exercise the embedded Windows backend through its Win32 API double.
dofile('test_ffi_duplicates_windows.lua')
