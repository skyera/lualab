#!/usr/bin/env luajit
local m=require('ffi_log_explorer')
local passed,total=0,0
local function test(name,fn)
 total=total+1;local ok,err=pcall(fn)
 if ok then passed=passed+1;print('PASS '..name) else io.stderr:write('FAIL '..name..': '..tostring(err)..'\n') end
end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local a,b=os.tmpname(),os.tmpname()
local function write(path,text,mode) local f=assert(io.open(path,mode or 'wb'));f:write(text);f:close() end
local function drain(model) repeat local _,busy=model:refresh() until not busy end
write(a,'INFO Ready\r\nERROR connection refused\npartial')
write(b,'WARN Retry\nDEBUG Trace\n')
test('multiple sources and severity detection',function()
 local model=m.Model.new({a,b});drain(model);eq(#model.entries,4)
 eq(model.entries[2].level,'ERROR');eq(model.entries[3].level,'WARN');eq(model.entries[4].level,'DEBUG')
 eq(model.entries[1].text,'INFO Ready');eq(model.sources[1].pending,'partial')
end)
test('append completes partial line without duplicates',function()
 local model=m.Model.new({a});drain(model)
 write(a,' completed\nINFO next\n','ab');drain(model)
 eq(#model.entries,4);eq(model.entries[3].text,'partial completed');eq(model.entries[3].line,3)
 drain(model);eq(#model.entries,4)
end)
test('truncate resets offset and line numbering',function()
 local model=m.Model.new({a});drain(model);write(a,'WARN new\n');drain(model)
 eq(model.entries[#model.entries].text,'WARN new');eq(model.entries[#model.entries].line,1);eq(model.sources[1].generation,1)
end)
test('overwrite that regrows beyond offset is detected',function()
 write(a,'INFO before\n')
 local model=m.Model.new({a});drain(model)
 write(a,'ERROR replacement now larger than original\n');drain(model)
 eq(model.sources[1].generation,1);eq(model.entries[#model.entries].line,1)
 eq(model.entries[#model.entries].text,'ERROR replacement now larger than original')
end)
test('rotation with larger replacement detects new identity',function()
 local model=m.Model.new({a});drain(model)
 local old=a..'.rotated';assert(os.rename(a,old));write(a,'ERROR replacement is longer\n');drain(model)
 eq(model.entries[#model.entries].text,'ERROR replacement is longer');eq(model.sources[1].generation,1)
 os.remove(old)
end)
test('missing file is reported and later recovered',function()
 local path=a..'.missing';os.remove(path)
 local model=m.Model.new({path});drain(model);assert(model.sources[1].error)
 write(path,'INFO recovered\n');drain(model);eq(#model.entries,1);assert(not model.sources[1].error);os.remove(path)
end)
test('line retention and bookmark eviction are bounded',function()
 write(a,'INFO 1\nINFO 2\nINFO 3\n')
 local model=m.Model.new({a},2);drain(model);eq(#model.entries,2);eq(model.entries[1].line,2)
 model.bookmarks[model.entries[1].id]=true
 write(a,'INFO 4\nINFO 5\n','ab');drain(model);eq(#model.entries,2);assert(next(model.bookmarks)==nil)
end)
test('long lines and unfinished data are bounded',function()
 write(a,string.rep('x',100000))
 local model=m.Model.new({a});drain(model);assert(#model.sources[1].pending<=4096);eq(#model.entries,0)
 write(a,'\n','ab');drain(model);assert(#model.entries[1].text<=4110);assert(model.entries[1].text:find('[truncated]',1,true))
end)
test('actual token sequences edit spaces, UTF-8, backspace, cancel',function()
 local model=m.Model.new({a});local decode=m.decoder()
 for _,key in ipairs(decode('/connection refused')) do model:key(key,10) end
 eq(model.query,'connection refused');assert(model.editing)
 model:key('LEFT',10);eq(model.query,'connection refused')
 for _,key in ipairs(decode('界')) do model:key(key,10) end
 model:key('BACKSPACE',10);eq(model.query,'connection refused')
 model:key('ENTER',10);assert(not model.editing)
 model:key('/',10);model:key('x',10);model:key('ESC',10);eq(model.query,'connection refused')
end)
test('fragmented arrows and UTF-8 survive across reads',function()
 local decode=m.decoder();eq(#decode('\27['),0);eq(decode('A')[1],'UP')
 local text='界';eq(#decode(text:sub(1,1)),0);eq(decode(text:sub(2))[1],text)
 eq(decode('\27',true)[1],'ESC')
 eq(table.concat(decode(' q\t\3'),','),'SPACE,q,TAB,CTRL_C')
end)
test('filter, file switching, severity, bookmarks and navigation',function()
 write(a,'INFO Alpha\nERROR Connection refused\nWARN Retrying\n')
 local model=m.Model.new({a,b});drain(model);model.follow=false
 model.query='CONNECTION';eq(#model:visible(),1);model.query=''
 model:key('TAB',10);eq(model.source,1);eq(#model:visible(),3)
 model:key('g',10);model:key('b',10);model:key('B',10);eq(#model:visible(),1)
 model:key('B',10);model:key('DOWN',10);eq(model.selected,2)
 model:key('G',10);assert(model.follow);eq(model.selected,3)
 model.severity='WARN';eq(#model:visible(),1)
 assert(model:key('Q',10)==false)
end)
test('all viewport boundaries and data states render safely',function()
 write(a,'ERROR bad\27[2J\t%界\n')
 local model=m.Model.new({a});drain(model)
 for _,dims in ipairs({{2,1},{10,4},{41,10},{60,16},{80,24},{160,50}}) do
  for _,ascii in ipairs({true,false}) do
   for _,query in ipairs({'','absent',string.rep('long query',40)}) do
    model.query=query;model.editing=true
    local frame=m.render(model,dims[1],dims[2],ascii);eq(#frame,dims[2])
    for _,line in ipairs(frame) do
     local plain=line:gsub('\27%[[0-9;]*m','')
     assert(not plain:find('[\r\n\27]'))
     assert(not plain:find('\t',1,true))
     eq(m.fit(plain,dims[1]-1),plain)
    end
   end
  end
 end
end)
test('changed row frames never clear on key input',function()
 local delta=m.diff({'abc','new'},{'abc','old'})
 assert(delta:find('\27[2;1H',1,true));assert(not delta:find('\27[1;1H',1,true));assert(not delta:find('\27[2J',1,true))
 eq(m.diff({'abc'},{'abc'}),'\27[?2026h\27[?2026l')
end)
test('bare UI open dialog accepts paths with spaces and adds files',function()
 local model=m.Model.new({})
 local decode=m.decoder()
 model:key('o',10);model:key('p',10)
 for _,key in ipairs(decode('folder/log file.log\r')) do model:key(key,10) end
 eq(#model.sources,1);eq(model.sources[1].path,'folder/log file.log');assert(not model.opening)
 model:key('O',10);model:key('p',10)
 for _,key in ipairs(decode('worker.log\r')) do model:key(key,10) end
 eq(#model.sources,2);eq(model.source,2)
 model:key('O',10);model:key('ESC',10);assert(not model.browser)
 model:key('O',10);model:key('p',10);model:key('ENTER',10);assert(model.opening);eq(#model.sources,2)
end)
test('rendering is pure and open dialog fits boundaries',function()
 local model=m.Model.new({});model.opening=true;model.path_query=string.rep('path界',50)
 for _,dims in ipairs({{2,1},{41,10},{80,24}}) do
  local before=model.selected;local frame=m.render(model,dims[1],dims[2],true)
  eq(model.selected,before);eq(#frame,dims[2])
  for _,line in ipairs(frame) do eq(m.fit(line,dims[1]-1),line) end
 end
end)
test('browsing preserves selected line during bounded eviction',function()
 write(a,'INFO one\nINFO two\nINFO three\n')
 local model=m.Model.new({a},3);drain(model);model.follow=false;model.selected=2
 local id=model:visible()[2].id
 write(a,'INFO four\n','ab');drain(model);eq(model:visible()[model.selected].id,id)
end)
test('long prompts retain visible insertion point',function()
 local model=m.Model.new({});model.opening=true;model.path_query=string.rep('界',100)
 local frame=m.render(model,41,10,true)
 assert(frame[3]:find('_',1,true));eq(m.tail('abc界',3),'c界')
end)
local ffi=require('ffi')
local fixture=a..'-browser'
local win=ffi.os=='Windows'
local kernel
local function wide_path(path)
 local n=kernel.MultiByteToWideChar(65001,0,path,#path,nil,0)
 local out=ffi.new('uint16_t[?]',n+1);kernel.MultiByteToWideChar(65001,0,path,#path,out,n);return out
end
if win then
 kernel=ffi.load('kernel32')
 ffi.cdef[[int __stdcall CreateDirectoryW(const uint16_t *path,void *security);
 int __stdcall RemoveDirectoryW(const uint16_t *path);
 int __stdcall DeleteFileW(const uint16_t *path);
 int __stdcall WriteFile(void *h,const void *bytes,uint32_t length,uint32_t *count,void *overlapped);]]
else ffi.cdef('int mkdir(const char *path,unsigned int mode);') end
local function mkdir(path)
 if win then assert(kernel.CreateDirectoryW(wide_path(path),nil)~=0)
 else assert(ffi.C.mkdir(path,493)==0) end
end
local function fixture_write(path,text)
 if not win then write(path,text);return end
 local h=kernel.CreateFileW(wide_path(path),0x40000000,7,nil,2,128,nil)
 assert(h~=ffi.cast('void*',-1));local count=ffi.new('uint32_t[1]')
 assert(kernel.WriteFile(h,text,#text,count,nil)~=0);kernel.CloseHandle(h)
end
local function remove(path,dir)
 if win then if dir then kernel.RemoveDirectoryW(wide_path(path)) else kernel.DeleteFileW(wide_path(path)) end
 else os.remove(path) end
end
mkdir(fixture);mkdir(fixture..'/sub folder');mkdir(fixture..'/empty')
fixture_write(fixture..'/server log.log','INFO Browser opened\n')
fixture_write(fixture..'/界.log','WARN Unicode name\n')
fixture_write(fixture..'/sub folder/child.log','ERROR Nested file\n')
test('native directory scan sorts folders first and preserves Unicode names',function()
 local entries,err,absolute=m.scan_directory(fixture);assert(entries,err)
 eq(#entries,4);assert(entries[1].directory and entries[2].directory)
 local names={};for _,entry in ipairs(entries) do names[entry.name]=true end
 assert(names['server log.log'] and names['界.log'])
 eq(m.path_kind(absolute),'directory');eq(m.path_kind(fixture..'/server log.log'),'file')
 eq(m.parent_directory('/'),'/');eq(m.parent_directory('C:/'),'C:/')
end)
test('browser uses real navigation and filter tokens to open a nested file',function()
 local model=m.Model.new({});assert(model:browse(fixture))
 local decode=m.decoder()
 for _,key in ipairs(decode('/sub folder\r\r')) do model:key(key,8) end
 assert(model.browser.directory:find('sub folder',1,true))
 model:key('BACKSPACE',8);eq(model.browser.directory,m.absolute_path(fixture))
 for _,key in ipairs(decode('/server log\r\r')) do model:key(key,8) end
 assert(not model.browser);eq(#model.sources,1);drain(model)
 eq(model.entries[1].text,'INFO Browser opened')
end)
test('browser renders every boundary including empty and filtered results',function()
 local model=m.Model.new({});assert(model:browse(fixture))
 for _,dir in ipairs({fixture,fixture..'/empty'}) do
  assert(model:browse(dir))
  for _,query in ipairs({'','no match',string.rep('界',100)}) do
   model.browser.query=query;model.browser.filtering=true
   for _,dims in ipairs({{2,1},{41,10},{80,24},{160,50}}) do
    for _,ascii in ipairs({true,false}) do
     local frame=m.render(model,dims[1],dims[2],ascii);eq(#frame,dims[2])
     for _,line in ipairs(frame) do
      local plain=line:gsub('\27%[[0-9;]*m','')
      eq(m.fit(plain,dims[1]-1),plain);assert(not plain:find('[\r\n\27]'))
     end
    end
   end
  end
 end
 assert(table.concat(m.render(model,80,24,true),'\n'):find('Directory is empty',1,true))
end)
test('failed scan preserves current directory and Escape cancels browser',function()
 local model=m.Model.new({});assert(model:browse(fixture))
 local before=model.browser
 assert(not model:browse(fixture..'/missing'));eq(model.browser,before)
 model:key('ESC',8);assert(not model.browser)
end)
remove(fixture..'/sub folder/child.log');remove(fixture..'/server log.log');remove(fixture..'/界.log')
remove(fixture..'/sub folder',true);remove(fixture..'/empty',true);remove(fixture,true)
test('CLI snapshot/help run headlessly',function()
 local interpreter=arg[-1] or 'luajit'
 for _,option in ipairs({'','--help','--snapshot --ascii '..string.format('%q',a)}) do
  local pipe=assert(io.popen(interpreter..' ffi_log_explorer.lua '..option..' 2>&1'))
  local text=pipe:read('*a');assert(pipe:close());assert(#text>0);assert(not text:find('\27',1,true))
 end
end)
os.remove(a);os.remove(b)
print(string.format('Log Explorer: %d/%d tests passed',passed,total))
assert(passed==total,'Log Explorer tests failed')
