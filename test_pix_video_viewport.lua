-- Isolate the real renderers without initializing decoders or launching players.
local file=assert(io.open('pix.lua','rb'));local source=file:read('*a');file:close()
local body=assert(source:match('(local function render_video_viewport_background.-)\n%-%- Video play engines'))
local captured={}
local env=setmetatable({io={write=function(text) captured[#captured+1]=text end,flush=function() end}},{__index=_G})
local chunk=assert(loadstring(body..'\nreturn render_video_viewport_background,render_video_frame_halfblock'))
setfenv(chunk,env);local background,frame=chunk()
for _,height in ipairs({1,5,10,24,50}) do
 local output=background(height);local rows={}
 for row in output:gmatch('\27%[(%d+);1H\27%[2K') do rows[tonumber(row)]=true end
 for row=1,height do assert(rows[row],'stale list row '..row) end
 assert(not rows[height+1]);assert(not output:find('\27[2J',1,true))
 assert(not output:find('1049',1,true))
 assert(output:sub(1,8)=='\27[?2026h' and output:sub(-8)=='\27[?2026l')
end
for _,size in ipairs({{76,20},{20,38},{1,2}}) do
 captured={};frame(string.rep('\0',size[1]*size[2]*3),size[1],size[2],' ',6)
 local output=table.concat(captured)
 assert(output:find('\27[6;1H',1,true));assert(not output:find('\27[2J',1,true))
 assert(output:sub(1,8)=='\27[?2026h' and output:sub(-8)=='\27[?2026l')
end
assert(source:find('io.write(render_video_viewport_background(term_h))',1,true))
print('PASS Pix video viewport: all rows erased atomically; wide/portrait/tiny frames preserve differential rendering')
