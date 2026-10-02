#!/usr/bin/env luajit
-- Windows/Linux log explorer. Native file identity and terminal APIs via FFI.
local ffi,bit=require('ffi'),require('bit')
local M,Model={},{}; Model.__index=Model
local windows=ffi.os=='Windows'
local native
if windows then
 ffi.cdef[[
 typedef struct {uint32_t low,high;} LogFileTime;
 typedef struct {uint32_t attributes; LogFileTime creation,access,write; uint32_t volume,size_high,size_low,links,index_high,index_low;} LogFileInfo;
 typedef struct {uint32_t attributes; LogFileTime creation,access,write;
  uint32_t size_high,size_low,reserved0,reserved1; uint16_t name[260],alternate[14];} LogFindData;
 void* __stdcall FindFirstFileW(const uint16_t *pattern,LogFindData *data);
 int __stdcall FindNextFileW(void *h,LogFindData *data);
 int __stdcall FindClose(void *h);
 uint32_t __stdcall GetFileAttributesW(const uint16_t *path);
 uint32_t __stdcall GetFullPathNameW(const uint16_t *path,uint32_t size,uint16_t *out,uint16_t **part);
 typedef struct {short x,y;} LogCoord;
 typedef struct {short left,top,right,bottom;} LogRect;
 typedef struct {LogCoord size,cursor; uint16_t attributes; LogRect window; LogCoord maximum;} LogConsoleInfo;
 int __stdcall MultiByteToWideChar(unsigned int cp,uint32_t flags,const char *s,int n,uint16_t *out,int cap);
 void* __stdcall CreateFileW(const uint16_t *name,uint32_t access,uint32_t share,void *security,uint32_t creation,uint32_t flags,void *template_file);
 int __stdcall GetFileInformationByHandle(void *h,LogFileInfo *info);
 int __stdcall SetFilePointerEx(void *h,int64_t offset,int64_t *result,uint32_t method);
 int __stdcall ReadFile(void *h,void *buf,uint32_t size,uint32_t *count,void *overlapped);
 int __stdcall CloseHandle(void *h);
 uint32_t __stdcall GetLastError(void);
 void* __stdcall GetStdHandle(uint32_t n);
 int __stdcall GetConsoleMode(void *h,uint32_t *mode);
 int __stdcall SetConsoleMode(void *h,uint32_t mode);
 int __stdcall GetConsoleScreenBufferInfo(void *h,LogConsoleInfo *info);
 uint32_t __stdcall GetConsoleOutputCP(void);
 int __stdcall SetConsoleOutputCP(uint32_t cp);
 void __stdcall Sleep(uint32_t ms);
 const uint16_t* __stdcall GetCommandLineW(void);
 uint16_t** __stdcall CommandLineToArgvW(const uint16_t *command,int *count);
 int __stdcall WideCharToMultiByte(unsigned int cp,uint32_t flags,const uint16_t *s,int n,char *out,int cap,const char *fallback,int *used);
 void* __stdcall LocalFree(void *memory);
 typedef struct {int down; uint16_t repeats,virtual_key,scan_code,unicode; uint32_t control;} LogKeyEvent;
 typedef struct {uint16_t type,padding; union {LogKeyEvent key; uint8_t other[16];} event;} LogInputRecord;
 int __stdcall GetNumberOfConsoleInputEvents(void *h,uint32_t *count);
 int __stdcall ReadConsoleInputW(void *h,LogInputRecord *records,uint32_t count,uint32_t *read_count);
 typedef int (__stdcall *log_ctrl_handler)(uint32_t);
 int __stdcall SetConsoleCtrlHandler(log_ctrl_handler handler,int add);
 ]]
 native=ffi.load('kernel32')
else
 assert(ffi.os=='Linux','Log Explorer supports Windows and Linux')
 assert(ffi.arch=='x64' or ffi.arch=='arm64','Linux backend requires x86-64 or ARM64 LuaJIT')
 local stat_fields=ffi.arch=='arm64' and [[
 unsigned long dev,ino; unsigned int mode,nlink,uid,gid; unsigned long rdev,pad;
 long size; int blksize,pad2; long blocks; long atime,ansec,mtime,mnsec,ctime,cnsec; int reserved[2];
 ]] or [[
 unsigned long dev,ino,nlink; unsigned int mode,uid,gid,pad;
 unsigned long rdev; long size,blksize,blocks,atime,ansec,mtime,mnsec,ctime,cnsec,unused[3];
 ]]
 ffi.cdef('struct LogStat {'..stat_fields..'}; int stat(const char *path,struct LogStat *out);')
 ffi.cdef[[
 typedef struct LogDir LogDir;
 struct LogDirent {unsigned long ino; long offset; unsigned short reclen; unsigned char type; char name[256];};
 LogDir *opendir(const char *path); struct LogDirent *readdir(LogDir *dir); int closedir(LogDir *dir);
 char *realpath(const char *path,char *resolved); void free(void *memory);
 struct LogTermios {unsigned int iflag,oflag,cflag,lflag; unsigned char line,cc[32]; unsigned int ispeed,ospeed;};
 struct LogPoll {int fd; short events,revents;};
 struct LogSize {unsigned short rows,cols,xpixel,ypixel;};
 int isatty(int fd); int tcgetattr(int fd,struct LogTermios *t);
 int tcsetattr(int fd,int action,const struct LogTermios *t);
 int ioctl(int fd,unsigned long request,...);
 int poll(struct LogPoll *fds,unsigned long n,int timeout);
 long read(int fd,void *buf,size_t n);
 typedef void (*log_signal_handler)(int);
 log_signal_handler signal(int sig,log_signal_handler handler);
 ]]
end
local function wide(s)
 local n=native.MultiByteToWideChar(65001,8,s,#s,nil,0)
 if n==0 then return nil end
 local out=ffi.new('uint16_t[?]',n+1)
 native.MultiByteToWideChar(65001,8,s,#s,out,n);return out
end
local function from_wide(s)
 local n=native.WideCharToMultiByte(65001,0,s,-1,nil,0,nil,nil)
 if n==0 then return nil end
 local bytes=ffi.new('char[?]',n)
 native.WideCharToMultiByte(65001,0,s,-1,bytes,n,nil,nil)
 return ffi.string(bytes)
end
function M.path_kind(path)
 if windows then
  local name=wide(path);if not name then return nil end
  local attributes=native.GetFileAttributesW(name)
  if attributes==0xffffffff then return nil end
  return bit.band(attributes,16)~=0 and 'directory' or 'file'
 end
 local meta=ffi.new('struct LogStat')
 if ffi.C.stat(path,meta)~=0 then return nil end
 local kind=bit.band(meta.mode,0xf000)
 return kind==0x4000 and 'directory' or (kind==0x8000 and 'file' or nil)
end
function M.absolute_path(path)
 if windows then
  local name=wide(path);if not name then return nil,'Invalid UTF-8 path' end
  local count=native.GetFullPathNameW(name,0,nil,nil)
  if count==0 then return nil,'Cannot resolve directory' end
  local buffer=ffi.new('uint16_t[?]',count+1)
  if native.GetFullPathNameW(name,count+1,buffer,nil)==0 then return nil,'Cannot resolve directory' end
  return from_wide(buffer):gsub('\\','/')
 end
 local resolved=ffi.C.realpath(path,nil)
 if resolved==nil then return nil,'Cannot resolve directory: '..path end
 local result=ffi.string(resolved);ffi.C.free(resolved);return result
end
function M.parent_directory(path)
 path=path:gsub('\\','/')
 if path=='/' or path:match('^%a:/$') then return path end
 local clean=path:gsub('/+$','')
 local parent=clean:match('^(.*)/[^/]+$')
 if not parent or parent=='' then return '/' end
 if parent:match('^%a:$') then parent=parent..'/' end
 return parent
end
local function join_path(dir,name) return dir:gsub('/+$','')..'/'..name end
function M.scan_directory(path)
 local directory,err=M.absolute_path(path)
 if not directory then return nil,err end
 if M.path_kind(directory)~='directory' then return nil,'Not a directory: '..path end
 local entries={}
 if windows then
  local data=ffi.new('LogFindData')
  local handle=native.FindFirstFileW(wide(join_path(directory,'*')),data)
  if handle==ffi.cast('void*',-1) then
   local code=tonumber(native.GetLastError())
   if code==2 then return entries,nil,directory end
   return nil,'Cannot read directory ('..code..')'
  end
  repeat
   local name=from_wide(data.name)
   if name and name~='.' and name~='..' then
    entries[#entries+1]={name=name,path=join_path(directory,name),directory=bit.band(data.attributes,16)~=0}
   end
  until native.FindNextFileW(handle,data)==0
  local last_error=tonumber(native.GetLastError());native.FindClose(handle)
  if last_error~=18 then return nil,'Directory scan failed ('..last_error..')' end
 else
  local handle=ffi.C.opendir(directory)
  if handle==nil then return nil,'Cannot read directory: '..directory end
  while true do
   local record=ffi.C.readdir(handle);if record==nil then break end
   local name=ffi.string(record.name)
   if name~='.' and name~='..' then
    local full=join_path(directory,name);local kind=M.path_kind(full)
    if kind then entries[#entries+1]={name=name,path=full,directory=kind=='directory'} end
   end
  end
  ffi.C.closedir(handle)
 end
 table.sort(entries,function(a,b)
  if a.directory~=b.directory then return a.directory end
  if a.name:lower()==b.name:lower() then return a.name<b.name end
  return a.name:lower()<b.name:lower()
 end)
 return entries,nil,directory
end

-- Reopen each poll, allowing replacement/rotation; identity is compared before seeking.
local function read_chunk(path,offset,previous,anchor)
 if windows then
  local name=wide(path);if not name then return nil,'Invalid UTF-8 path' end
  local h=native.CreateFileW(name,0x80000000,7,nil,3,0x80,nil)
  if h==ffi.cast('void*',-1) then return nil,'Open failed ('..tonumber(native.GetLastError())..')' end
  local info=ffi.new('LogFileInfo')
  if native.GetFileInformationByHandle(h,info)==0 then native.CloseHandle(h);return nil,'Cannot read file metadata' end
  local id=string.format('%u:%u:%u',info.volume,info.index_high,info.index_low)
  local size=tonumber(info.size_high)*4294967296+tonumber(info.size_low)
  local reset=(previous and previous~=id) or size<offset
  if reset then offset=0 end
  local buffer,count=ffi.new('uint8_t[65536]'),ffi.new('uint32_t[1]')
  if not reset and anchor and #anchor>0 then
   if native.SetFilePointerEx(h,offset-#anchor,nil,0)==0 or native.ReadFile(h,buffer,#anchor,count,nil)==0 then
    native.CloseHandle(h);return nil,'Cannot verify file position'
   end
   if ffi.string(buffer,count[0])~=anchor then reset=true;offset=0 end
  end
  if native.SetFilePointerEx(h,offset,nil,0)==0 or native.ReadFile(h,buffer,65536,count,nil)==0 then
   native.CloseHandle(h);return nil,'Cannot read file'
  end
  native.CloseHandle(h);return ffi.string(buffer,count[0]),id,offset,reset
 else
  local meta=ffi.new('struct LogStat')
  if ffi.C.stat(path,meta)~=0 then return nil,'Cannot stat file' end
  if bit.band(meta.mode,0xf000)~=0x8000 then return nil,'Not a regular log file' end
  local f,err=io.open(path,'rb');if not f then return nil,err end
  local id=tostring(meta.dev)..':'..tostring(meta.ino)
  local reset=(previous and previous~=id) or tonumber(meta.size)<offset
  if reset then offset=0 end
  if not reset and anchor and #anchor>0 then
   if not f:seek('set',offset-#anchor) then f:close();return nil,'Cannot verify file position' end
   if f:read(#anchor)~=anchor then reset=true;offset=0 end
  end
  if not f:seek('set',offset) then f:close();return nil,'Cannot seek file' end
  local data=f:read(65536) or '';f:close();return data,id,offset,reset
 end
end
local function severity(text)
 local upper=text:upper()
 for _,level in ipairs({'FATAL','ERROR','WARN','WARNING','DEBUG','TRACE','INFO'}) do
  if upper:find('%f[%a]'..level..'%f[%A]') then
   return (level=='FATAL' and 'ERROR') or (level=='WARNING' and 'WARN') or (level=='TRACE' and 'DEBUG') or level
  end
 end
 return 'INFO'
end
function Model.new(paths,max_lines)
 local self=setmetatable({sources={},entries={},next_id=1,max_lines=max_lines or 10000,
  query='',severity='ALL',source=0,bookmarks_only=false,follow=true,selected=1,scroll=0,
  bookmarks={},editing=false,status='Ready'},Model)
 for _,path in ipairs(paths) do self.sources[#self.sources+1]={path=path,name=path:match('[^/\\]+$') or path,offset=0,pending='',line=0,generation=0} end
 return self
end
function Model:add(source,text)
 self.entries[#self.entries+1]={id=self.next_id,source=source,line=self.sources[source].line,generation=self.sources[source].generation,text=text,level=severity(text)}
 self.next_id=self.next_id+1
end
function Model:refresh()
 local current=not self.follow and self:visible()[self.selected]
 local changed,busy=false,false
 for index,source in ipairs(self.sources) do
  local data,id,offset,reset=read_chunk(source.path,source.offset,source.identity,source.anchor)
  if data==nil then
   if source.error~=id then changed=true end;source.error=id
  else
   if source.error then changed=true end;source.error=nil
   if reset then source.pending='';source.line=0;source.generation=source.generation+1;source.overflow=false;self.status='Rotated/truncated: '..source.name;changed=true end
   source.identity,source.offset=id,offset+#data
   source.anchor=((reset and '' or source.anchor or '')..data):sub(-32)
   if #data>0 then
    busy=true;changed=true
    local text=source.pending..data;local start=1
    while true do
     local finish=text:find('\n',start,true);if not finish then break end
     source.line=source.line+1
     local line=text:sub(start,finish-1):gsub('\r$','')
     local truncated=source.overflow or #line>4096
     self:add(index,line:sub(1,4096)..(truncated and ' [truncated]' or ''));source.overflow=false
     start=finish+1
    end
    source.pending=text:sub(start)
    -- Limit an unfinished or maliciously long line while continuing to consume it.
    if #source.pending>4096 then source.pending=source.pending:sub(1,4096);source.overflow=true end
   end
  end
 end
 local extra=#self.entries-self.max_lines
 if extra>0 then
  local retained={}
  for i,entry in ipairs(self.entries) do
   if i>extra then retained[#retained+1]=entry else self.bookmarks[entry.id]=nil end
  end
  self.entries=retained
 end
 if current then
  local visible=self:visible()
  for i,entry in ipairs(visible) do if entry.id==current.id then self.selected=i;break end end
 end
 return changed,busy
end
function Model:visible()
 local out={};local query=self.query:lower()
 for _,entry in ipairs(self.entries) do
  if (self.source==0 or entry.source==self.source) and
   (self.severity=='ALL' or entry.level==self.severity) and
   (not self.bookmarks_only or self.bookmarks[entry.id]) and entry.text:lower():find(query,1,true) then out[#out+1]=entry end
 end
 return out
end
function Model:clamp(count,height)
 self.selected=count==0 and 1 or math.max(1,math.min(count,self.selected))
 if self.follow and count>0 then self.selected=count end
 self.scroll=math.max(0,math.min(self.scroll,math.max(0,count-height)))
 if self.selected>self.scroll+height then self.scroll=self.selected-height end
 if self.selected<=self.scroll then self.scroll=self.selected-1 end
 self.scroll=math.max(0,self.scroll)
end
local function pop_utf8(s)
 local i=#s;while i>0 and s:byte(i)>=128 and s:byte(i)<192 do i=i-1 end
 return s:sub(1,i-1)
end
local function printable(key)
 return key=='SPACE' or (#key<=4 and key~='ESC' and not key:find('[%z\1-\31\127]') and
  (#key==1 or key:byte(1)>=194))
end
function Model:open_file(path)
 local absolute=M.absolute_path(path)
 path=absolute or path
 local found
 for i,source in ipairs(self.sources) do if source.path==path then found=i end end
 if not found then
  self.sources[#self.sources+1]={path=path,name=path:match('[^/\\]+$') or path,offset=0,pending='',line=0,generation=0}
  found=#self.sources
 end
 self.source=found;self.follow=true;self.opening=false;self.browser=nil;self.status='Opened: '..path
end
function Model:browse(path)
 local entries,err,directory=M.scan_directory(path)
 if not entries then self.status=err;return false end
 self.browse_root=directory
 self.browser={directory=directory,entries=entries,query='',selected=1,scroll=0,filtering=false}
 self.opening=false;self.status='Choose a file; P enters a path'
 return true
end
function Model:browser_entries()
 local out={};local browser=self.browser
 for _,entry in ipairs(browser.entries) do
  if entry.name:lower():find(browser.query:lower(),1,true) then out[#out+1]=entry end
 end
 return out
end
function Model:browser_key(key,height)
 local browser=self.browser
 if browser.filtering then
  if key=='ENTER' then browser.filtering=false
  elseif key=='ESC' then browser.query=browser.before_query;browser.filtering=false
  elseif key=='BACKSPACE' then browser.query=pop_utf8(browser.query)
  elseif printable(key) then browser.query=browser.query..(key=='SPACE' and ' ' or key) end
  browser.selected,browser.scroll=1,0;return true
 end
 if key=='q' or key=='Q' then return false end
 if key=='ESC' then self.browser=nil;return true end
 if key=='p' or key=='P' then
  self.browser=nil;self.opening=true;self.path_query='';return true
 elseif key=='/' then browser.before_query=browser.query;browser.filtering=true
 elseif key=='BACKSPACE' or key=='LEFT' or key=='h' then self:browse(M.parent_directory(browser.directory))
 elseif key=='r' or key=='R' then self:browse(browser.directory)
 else
  local entries=self:browser_entries()
  if key=='ENTER' or key=='RIGHT' then
   local entry=entries[browser.selected]
   if entry then
    if entry.directory then self:browse(entry.path) else self:open_file(entry.path) end
   end
  elseif key=='UP' or key=='k' then browser.selected=browser.selected-1
  elseif key=='DOWN' or key=='j' then browser.selected=browser.selected+1
  elseif key=='PAGE_UP' then browser.selected=browser.selected-height
  elseif key=='PAGE_DOWN' then browser.selected=browser.selected+height
  elseif key=='HOME' or key=='g' then browser.selected=1
  elseif key=='END' or key=='G' then browser.selected=#entries end
  browser.selected=math.max(1,math.min(#entries,browser.selected))
  browser.scroll=math.max(0,math.min(browser.scroll,math.max(0,#entries-height)))
  if browser.selected>browser.scroll+height then browser.scroll=browser.selected-height end
  if browser.selected<=browser.scroll then browser.scroll=browser.selected-1 end
 end
 return true
end
function Model:key(key,height)
 if key=='CTRL_C' or key=='EOF' then return false end
 if self.browser then return self:browser_key(key,height) end
 if self.opening then
  if key=='ESC' then self.opening=false
  elseif key=='BACKSPACE' then self.path_query=pop_utf8(self.path_query)
  elseif key=='ENTER' then
   local path=self.path_query
   if path:sub(1,1)=='"' and path:sub(-1)=='"' then path=path:sub(2,-2) end
   if #path==0 then self.status='Enter a log file path'
   else
    if M.path_kind(path)=='directory' then self:browse(path) else self:open_file(path) end
   end
  elseif printable(key) then self.path_query=self.path_query..(key=='SPACE' and ' ' or key) end
  return true
 end
 if self.editing then
  if key=='ENTER'  then self.editing=false
  elseif key=='ESC' then self.query=self.before_query;self.editing=false
  elseif key=='BACKSPACE' then self.query=pop_utf8(self.query)
  elseif printable(key) then self.query=self.query..(key=='SPACE' and ' ' or key) end
  self.selected,self.scroll=1,0;return true
 end
 if key=='q' or key=='Q' or key=='ESC' then return false end
 local entries=self:visible();self:clamp(#entries,height)
 if key=='o' or key=='O' then self:browse(self.browse_root or '.')
 elseif key=='/' then self.before_query=self.query;self.editing=true;self.follow=false
 elseif key=='TAB' then self.source=(self.source+1)%(#self.sources+1);self.selected,self.scroll=1,0
 elseif key=='s' or key=='S' then
  local levels={'ALL','DEBUG','INFO','WARN','ERROR'}
  for i,level in ipairs(levels) do if self.severity==level then self.severity=levels[i%#levels+1];break end end
  self.selected,self.scroll=1,0
 elseif key=='f' or key=='F' then self.follow=not self.follow
 elseif key=='b' then local e=entries[self.selected];if e then self.bookmarks[e.id]=not self.bookmarks[e.id] end
 elseif key=='B' then self.bookmarks_only=not self.bookmarks_only;self.selected,self.scroll=1,0
 elseif key=='g' or key=='HOME' then self.follow=false;self.selected=1
 elseif key=='G' or key=='END' then self.follow=true;self.selected=math.max(1,#entries)
 elseif key=='UP' or key=='k' then self.follow=false;self.selected=self.selected-1
 elseif key=='DOWN' or key=='j' then self.follow=false;self.selected=self.selected+1
 elseif key=='PAGE_UP' then self.follow=false;self.selected=self.selected-height
 elseif key=='PAGE_DOWN' then self.follow=false;self.selected=self.selected+height
 elseif key=='c' then self.query='';self.selected,self.scroll=1,0 end
 self:clamp(#self:visible(),height);return true
end
-- Decode complete UTF-8 scalars; never split pasted text or VT sequences.
local function char_at(text,index)
 local first=text:byte(index);if not first then return nil end
 local length=first<128 and 1 or (first>=194 and first<=223 and 2 or (first<=239 and first>=224 and 3 or (first<=244 and first>=240 and 4 or 1)))
 if index+length-1>#text then return nil end
 local cp=length==1 and first or first%(2^(7-length))
 for j=1,length-1 do local b=text:byte(index+j);if b<128 or b>191 then return '?',1,63 end;cp=cp*64+b-128 end
 if length>1 and (cp<({[2]=128,[3]=2048,[4]=65536})[length] or cp>1114111 or (cp>=55296 and cp<=57343)) then return '?',1,63 end
 if length==1 and first>=128 then return '?',1,63 end
 return text:sub(index,index+length-1),length,cp
end
function M.decoder()
 local pending=''
 return function(bytes,flush)
  pending=pending..(bytes or '');local keys={}
  while #pending>0 do
   local ch=pending:sub(1,1)
   if ch=='\27' then
    if (pending=='\27' or pending=='\27[') and not flush then break end
    local seq=pending:match('^\27%[[0-9;]*[A-Za-z~]')
    if seq then
     local k=({['\27[A']='UP',['\27[B']='DOWN',['\27[C']='RIGHT',['\27[D']='LEFT',['\27[5~']='PAGE_UP',['\27[6~']='PAGE_DOWN',['\27[H']='HOME',['\27[F']='END'})[seq]
     if k then keys[#keys+1]=k end;pending=pending:sub(#seq+1)
    else keys[#keys+1]='ESC';pending=pending:sub(2) end
   else
    local text,n=char_at(pending,1);if not text then if not flush then break end;text,n='?',1 end
    keys[#keys+1]=({[' ']='SPACE',['\t']='TAB',['\127']='BACKSPACE',['\8']='BACKSPACE',['\r']='ENTER',['\n']='ENTER',['\3']='CTRL_C'})[text] or text
    pending=pending:sub(n+1)
   end
  end
  return keys
 end
end
local function cell_width(cp)
 if (cp>=768 and cp<=879) or (cp>=65024 and cp<=65039) then return 0 end
 if cp>=4352 and (cp<=4447 or (cp>=11904 and cp<=42191) or (cp>=44032 and cp<=55203) or
  (cp>=63744 and cp<=64255) or (cp>=65040 and cp<=65376) or (cp>=65504 and cp<=65510) or cp>=127744) then return 2 end
 return 1
end
function M.fit(text,width)
 local out,used,index={},0,1
 while index<=#text do
  local ch,n,cp=char_at(text,index)
  if not ch then ch,n,cp='?',1,63 end
  if cp<32 or (cp>=127 and cp<160) then ch,cp=' ',32 end
  local size=cell_width(cp)
  if used+size>width then break end
  out[#out+1]=ch;used=used+size;index=index+n
 end
 return table.concat(out)..string.rep(' ',math.max(0,width-used))
end
-- Keep the insertion point visible for long path/filter prompts.
function M.tail(text,width)
 local chars,columns,index={},0,1
 while index<=#text do
  local ch,n,cp=char_at(text,index)
  if not ch then ch,n,cp='?',1,63 end
  chars[#chars+1]={text=ch,width=cell_width(cp)};columns=columns+cell_width(cp);index=index+n
 end
 local first=1
 while columns>width and first<=#chars do columns=columns-chars[first].width;first=first+1 end
 local out={};for j=first,#chars do out[#out+1]=chars[j].text end
 return table.concat(out)
end
function M.render_browser(model,cols,rows,ascii)
 local width=math.max(1,cols-1);rows=math.max(1,rows)
 local lines={};local function add(s) if #lines<rows then lines[#lines+1]=M.fit(s,width) end end
 if width<40 or rows<10 then add('Resize terminal: minimum 41 x 10');add('Q quit')
 else
  local content=width-4;local reset=ascii and '' or '\27[0m'
  local function row(text,color)
   lines[#lines+1]='| '..(ascii and '' or (color or '\27[37m'))..M.fit(text,content)..reset..' |'
  end
  local browser=model.browser
  add('+- LOG EXPLORER - OPEN FILE '..string.rep('-',width-28)..'+')
  row('Directory: '..browser.directory,'\27[36m')
  row((browser.filtering and 'FIND> ' or 'Filter: ')..M.tail(browser.query..(browser.filtering and '_' or ''),content-8))
  row('    Name','\27[90m')
  local entries=model:browser_entries();local height=rows-8
  local selected=math.max(1,math.min(#entries,browser.selected))
  local scroll=math.max(0,math.min(browser.scroll,math.max(0,#entries-height)))
  if selected>scroll+height then scroll=selected-height end
  if selected<=scroll then scroll=selected-1 end
  scroll=math.max(0,scroll)
  for row_index=1,height do
   local index=scroll+row_index;local entry=entries[index]
   if entry then
    local color=entry.directory and '\27[36m' or '\27[37m'
    if index==selected then color=color..'\27[48;2;22;43;58m' end
    row((index==selected and '> ' or '  ')..(entry.directory and '[DIR] ' or '      ')..entry.name..(entry.directory and '/' or ''),color)
   else row(row_index==1 and (#browser.entries==0 and 'Directory is empty' or 'No matching files') or '') end
  end
  row(entries[selected] and entries[selected].path or 'No file selected','\27[90m')
  row(model.status,'\27[90m')
  row(content<50 and 'Enter Open Backsp Up / Find Q Quit' or
   content<70 and 'Enter Open Backsp Parent / Find P Path Esc Cancel Q Quit' or
   'Enter Open  Backspace Parent  / Filter  P Path  R Reload  Esc Cancel  Q Quit')
  add('+'..string.rep('-',width-2)..'+')
 end
 while #lines<rows do add('') end
 return lines
end
function M.render(model,cols,rows,ascii)
 if model.browser then return M.render_browser(model,cols,rows,ascii) end
 local width=math.max(1,cols-1);rows=math.max(1,rows)
 local frame={};local function add(s) if #frame<rows then frame[#frame+1]=M.fit(s,width) end end
 if width<40 or rows<10 then add('Resize terminal: minimum 41 x 10');add('Q quit')
 else
  local content=width-4
  local reset=ascii and '' or '\27[0m'
  local function row(text,color)
   local start=ascii and '' or (color or '\27[37m')
   frame[#frame+1]='| '..start..M.fit(text,content)..reset..' |'
  end
  add('+- LOG EXPLORER '..string.rep('-',width-16)..'+')
  local source=model.source==0 and 'All files' or model.sources[model.source].name
  row(string.format('%d sources | %s | Follow %s | %s%s',#model.sources,source,model.follow and 'ON' or 'OFF',model.severity,model.bookmarks_only and ' | Bookmarks' or ''),'\27[36m')
  row(model.opening and ('OPEN> '..M.tail(model.path_query..'_',content-6)) or
   (model.editing and ('SEARCH> '..M.tail(model.query..'_',content-8)) or ('Filter: '..model.query)))
  row('   Source           Line Level Message','\27[90m')
  local entries=model:visible();local height=rows-8
  local selected=#entries==0 and 1 or math.max(1,math.min(#entries,model.selected))
  if model.follow and #entries>0 then selected=#entries end
  local scroll=math.max(0,math.min(model.scroll,math.max(0,#entries-height)))
  if selected>scroll+height then scroll=selected-height end
  if selected<=scroll then scroll=selected-1 end
  scroll=math.max(0,scroll)
  for i=1,height do
   local e=entries[scroll+i]
   if e then
    local text=string.format('%s%s %s %6d %-5s %s',scroll+i==selected and '>' or ' ',model.bookmarks[e.id] and '*' or ' ',M.fit(model.sources[e.source].name,14),e.line,e.level,e.text)
    local color=e.level=='ERROR' and '\27[31m' or (e.level=='WARN' and '\27[33m' or (e.level=='DEBUG' and '\27[90m' or '\27[37m'))
    if scroll+i==selected then color=color..'\27[48;2;22;43;58m' end
    row(text,color)
   else row(i==1 and (#model.sources==0 and 'No logs loaded. Press O to open a file.' or 'No matching log lines') or '') end
  end
  local entry=entries[selected]
  row(entry and (model.sources[entry.source].path..':'..entry.line..' | '..entry.text) or 'Waiting for complete lines','\27[36m')
  local errors={};for _,s in ipairs(model.sources) do if s.error then errors[#errors+1]=s.name..': '..s.error end end
  row(#errors>0 and table.concat(errors,' | ') or model.status,'\27[90m')
  row(model.opening and 'Enter Open | Esc Cancel' or
   (content<50 and 'O Open / Find F Follow b Mark Q Quit' or
    content<65 and 'O Open / Find Tab File F Follow b Mark B Marks Q Quit' or
    'O Open / Find Tab File S Level F Follow b Mark B Marks Q Quit'))
  add('+'..string.rep('-',width-2)..'+')
 end
 while #frame<rows do add('') end
 return frame
end
function M.diff(frame,previous,clear)
 local out={'\27[?2026h'};if clear then out[#out+1]='\27[2J' end
 for row,line in ipairs(frame) do if not previous or line~=previous[row] then out[#out+1]=string.format('\27[%d;1H%s\27[0m\27[K',row,line) end end
 out[#out+1]='\27[?2026l';return table.concat(out)
end
local function terminal()
 local t={active=false,queue={},decode=M.decoder()}
 if windows then
  t.input,t.output=native.GetStdHandle(0xFFFFFFF6),native.GetStdHandle(0xFFFFFFF5)
  t.inmode,t.outmode=ffi.new('uint32_t[1]'),ffi.new('uint32_t[1]')
  function t:is_tty() return native.GetConsoleMode(self.input,self.inmode)~=0 and native.GetConsoleMode(self.output,self.outmode)~=0 end
  function t:size()
   local info=ffi.new('LogConsoleInfo')
   if native.GetConsoleScreenBufferInfo(self.output,info)~=0 then return tonumber(info.window.right-info.window.left+1),tonumber(info.window.bottom-info.window.top+1) end
   return 80,24
  end
  function t:enter()
   assert(self:is_tty(),'Console unavailable');self.codepage=native.GetConsoleOutputCP()
   assert(native.SetConsoleMode(self.output,bit.bor(self.outmode[0],4))~=0,'ANSI console output unavailable')
   self.active=true
   assert(native.SetConsoleMode(self.input,bit.band(self.inmode[0],bit.bnot(7)))~=0,'Cannot enable input')
   native.SetConsoleOutputCP(65001)
   io.write('\27[?1049h\27[?25l\27[?7l\27[2J');io.flush()
  end
  function t:restore()
   if self.active then
    io.write('\27[?7h\27[?1049l\27[?25h\27[0m');io.flush()
    native.SetConsoleMode(self.input,self.inmode[0]);native.SetConsoleMode(self.output,self.outmode[0]);native.SetConsoleOutputCP(self.codepage)
    self.active=false
   end
  end
  local function utf8(cp)
   if cp<128 then return string.char(cp)
   elseif cp<2048 then return string.char(192+math.floor(cp/64),128+cp%64)
   elseif cp<65536 then return string.char(224+math.floor(cp/4096),128+math.floor(cp/64)%64,128+cp%64)
   else return string.char(240+math.floor(cp/262144),128+math.floor(cp/4096)%64,128+math.floor(cp/64)%64,128+cp%64) end
  end
  function t:keys()
   local bytes=''
   local count,read_count=ffi.new('uint32_t[1]'),ffi.new('uint32_t[1]')
   local record=ffi.new('LogInputRecord[1]')
   while native.GetNumberOfConsoleInputEvents(self.input,count)~=0 and count[0]>0 do
    if native.ReadConsoleInputW(self.input,record,1,read_count)==0 then break end
    if record[0].type==1 and record[0].event.key.down~=0 then
     local event=record[0].event.key
     local key=({[38]='UP',[40]='DOWN',[37]='LEFT',[39]='RIGHT',[33]='PAGE_UP',[34]='PAGE_DOWN',[36]='HOME',[35]='END'})[event.virtual_key]
     for _=1,math.max(1,tonumber(event.repeats)) do
      local code=tonumber(event.unicode)
      if key then
       for _,k in ipairs(self.decode(bytes)) do self.queue[#self.queue+1]=k end
       bytes='';self.queue[#self.queue+1]=key
      elseif code>=55296 and code<=56319 then self.surrogate=code
      elseif code>=56320 and code<=57343 and self.surrogate then
       bytes=bytes..utf8(65536+(self.surrogate-55296)*1024+code-56320);self.surrogate=nil
      elseif code~=0 then self.surrogate=nil;bytes=bytes..utf8(code) end
     end
    end
   end
   for _,k in ipairs(self.decode(bytes,true)) do self.queue[#self.queue+1]=k end
   local keys=self.queue;self.queue={};native.Sleep(15);return keys
  end
 else
  t.original=ffi.new('struct LogTermios');t.poll=ffi.new('struct LogPoll',{0,1,0});t.buffer=ffi.new('uint8_t[1024]')
  function t:is_tty() return ffi.C.isatty(0)~=0 and ffi.C.isatty(1)~=0 end
  function t:size()
   local size=ffi.new('struct LogSize')
   if ffi.C.ioctl(1,0x5413,size)==0 and size.cols>0 and size.rows>0 then return tonumber(size.cols),tonumber(size.rows) end
   return 80,24
  end
  function t:enter()
   assert(ffi.C.tcgetattr(0,self.original)==0,'Cannot read terminal settings')
   local raw=ffi.new('struct LogTermios');ffi.copy(raw,self.original,ffi.sizeof(raw))
   raw.lflag=bit.band(raw.lflag,bit.bnot(11));raw.iflag=bit.band(raw.iflag,bit.bnot(1280));raw.cc[5],raw.cc[6]=0,0
   assert(ffi.C.tcsetattr(0,0,raw)==0,'Cannot enable raw input');self.active=true
   self.signal_cb=ffi.cast('log_signal_handler',function() self.stopped=true end)
   self.old_int=ffi.C.signal(2,self.signal_cb);self.old_term=ffi.C.signal(15,self.signal_cb)
   io.write('\27[?1049h\27[?25l\27[?7l\27[2J');io.flush()
  end
  function t:restore()
   if self.active then
    ffi.C.tcsetattr(0,0,self.original)
    io.write('\27[?7h\27[?1049l\27[?25h\27[0m');io.flush();self.active=false
   end
   if self.signal_cb then
    ffi.C.signal(2,self.old_int);ffi.C.signal(15,self.old_term);self.signal_cb:free();self.signal_cb=nil
   end
  end
  function t:keys()
   self.poll.revents=0
   if ffi.C.poll(self.poll,1,15)>0 then
    if bit.band(self.poll.revents,1)~=0 then
     local n=ffi.C.read(0,self.buffer,1024)
     if n<=0 then return {'EOF'} end
     self.escape_ticks=0;return self.decode(ffi.string(self.buffer,n))
    elseif bit.band(self.poll.revents,24)~=0 then return {'EOF'} end
   end
   self.escape_ticks=(self.escape_ticks or 0)+1
   return self.decode('',self.escape_ticks>=3)
  end
 end
 return t
end
local function run(model,ascii)
 -- Lua signal callbacks cannot re-enter compiled FFI calls. Restore the caller's JIT state on exit.
 local jit=require('jit');local jit_enabled=jit.status();jit.off()
 local term=terminal();local previous,oldcols,oldrows
 local ok,err=xpcall(function()
  term:enter()
  while not term.stopped do
   model:refresh()
   local cols,rows=term:size();local resized=oldcols and (oldcols~=cols or oldrows~=rows)
   if resized then previous=nil end
   model:clamp(#model:visible(),math.max(1,rows-8))
   local frame=M.render(model,cols,rows,ascii)
   io.write(M.diff(frame,previous,resized));io.flush()
   previous,oldcols,oldrows=frame,cols,rows
   local keys=term:keys();local running=true
   for _,key in ipairs(keys) do if not model:key(key,math.max(1,rows-8)) then running=false;break end end
   if not running then break end
  end
 end,debug.traceback)
 term:restore();if jit_enabled then jit.on() end
 if not ok then error(err,0) end
end
require('jit').off(run,true)
M.Model=Model
local function main(args)
 if windows and args==arg then
  local count=ffi.new('int[1]')
  local shell=ffi.load('shell32')
  local argv=shell.CommandLineToArgvW(native.GetCommandLineW(),count)
  if argv~=nil then
   local offset=tonumber(count[0])-#args
   for i=1,#args do
    local pointer=argv[offset+i-1]
    local n=native.WideCharToMultiByte(65001,0,pointer,-1,nil,0,nil,nil)
    if n>0 then
     local bytes=ffi.new('char[?]',n)
     native.WideCharToMultiByte(65001,0,pointer,-1,bytes,n,nil,nil)
     args[i]=ffi.string(bytes)
    end
   end
   native.LocalFree(argv)
  end
 end
 local paths,ascii,snapshot,max_lines={},false,false,10000
 local i=1
 while i<=#args do
  local a=args[i]
  if a=='--help' or a=='-h' then
   print([[Log Explorer - LuaJIT FFI for Windows/Linux
Usage: luajit ffi_log_explorer.lua [--snapshot] [--ascii] [--max-lines N] [FILE...]
Without files, browses the current directory. A directory argument opens its browser.
O opens the browser; Enter opens files/folders; Backspace goes to parent; / filters; P types a path.
Live file following; keeps the most recent 10000 complete lines by default.
Long lines are limited to 4096 bytes. Multiple files appear in arrival order.
/ edit substring filter; Enter accept; Esc cancel; c clear filter
Tab cycle files; S cycle severity; F toggle follow; b bookmark; B bookmarks only
Up/Down or j/k navigate; PgUp/PgDn page; g start; G end/follow; Q quit
--snapshot prints current logs without requiring a terminal. --test runs tests.]])
   return
  elseif a=='--test' then dofile('test_ffi_log_explorer.lua');return
  elseif a=='--ascii' then ascii=true
  elseif a=='--snapshot' then snapshot=true
  elseif a=='--max-lines' then
   i=i+1;max_lines=tonumber(args[i]);assert(max_lines and max_lines>=1 and max_lines<=1000000 and max_lines%1==0,'--max-lines must be an integer from 1 to 1000000')
  elseif a=='--' then for j=i+1,#args do paths[#paths+1]=args[j] end;break
  elseif a:sub(1,1)=='-' then error('Unknown option: '..a)
  else paths[#paths+1]=a end
  i=i+1
 end
 local directory
 if #paths==1 and M.path_kind(paths[1])=='directory' then directory=paths[1];paths={} end
 local model=Model.new(paths,max_lines)
 local term=terminal()
 if #paths==0 then
  if snapshot or not term:is_tty() then
   local files,err,current=M.scan_directory(directory or '.')
   if not files then io.stderr:write(err..'\n');return false end
   print('Log Explorer | Directory: '..M.fit(current,#current*2):gsub('%s+$',''))
   for _,entry in ipairs(files) do print(M.fit(entry.name,#entry.name*2):gsub('%s+$','')..(entry.directory and '/' or '')) end
   return
  end
  model.browse_root=directory or '.'
  if not model:browse(model.browse_root) then error(model.status) end
 end
 if snapshot or not term:is_tty() then
  repeat local _,busy=model:refresh() until not busy
  local failed=false
  for _,source in ipairs(model.sources) do if source.error then failed=true;io.stderr:write(source.path..': '..source.error..'\n') end end
  for _,entry in ipairs(model.entries) do io.write(M.fit(model.sources[entry.source].name,20)..':'..entry.line..' '..entry.level..' '..M.fit(entry.text,#entry.text*2):gsub('%s+$','')..'\n') end
  return not failed
 else run(model,ascii) end
end
M.main=main
if ...=='ffi_log_explorer' then return M end
package.loaded.ffi_log_explorer=M
local ok,result=pcall(main,arg)
if not ok then io.stderr:write('Log Explorer: '..tostring(result)..'\n');os.exit(1) end
if result==false then os.exit(1) end
