#!/usr/bin/env luajit
local m=require('ffi_asteroids')
local Game=m.Game
local passed=0
local function test(name,fn) fn(); passed=passed+1; print('PASS '..name) end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function near(a,b) assert(math.abs(a-b)<0.00001) end
local function rock(x,y,size) return {x=x,y=y,vx=0,vy=0,size=size or 1,phase=0} end

test('deterministic initial wave',function()
 local a,b=Game.new(),Game.new(); eq(a.lives,3); eq(#a.asteroids,4)
 for i,r in ipairs(a.asteroids) do eq(r.x,b.asteroids[i].x); eq(r.y,b.asteroids[i].y) end
end)
test('actual key decoding, including fragmented arrows and Space',function()
 local decode=m.decoder(); eq(#decode('\27['),0)
 local keys=decode('Aw p\27[Cq'); eq(table.concat(keys,','),'UP,w,SPACE,p,RIGHT,q')
 local g=Game.new(); for _,k in ipairs(keys) do g:key(k) end
 eq(#g.bullets,1); assert(g.paused); assert(g.thrust>0)
 eq(decode('\27',true)[1],'ESC'); eq(decode('\3')[1],'CTRL_C')
end)
test('rotation and thrust',function()
 local g=Game.new(); local a=g.angle; g:key('LEFT'); assert(g.angle<a)
 g:key('RIGHT'); near(g.angle,a); g:key('UP'); g:update(0.1); assert(g.ship.vy<0)
end)
test('ship wraps and frame hitch is bounded',function()
 local g=Game.new(); g.ship.x=95.9; g.ship.vx=10; g:update(5); near(g.ship.x,0.9)
end)
test('bullet cooldown and expiry',function()
 local g=Game.new(); g:fire(); g:fire(); eq(#g.bullets,1)
 g.bullets[1].life=0.001; g:update(0.01); eq(#g.bullets,0)
end)
test('large asteroid splits and awards points',function()
 local g=Game.new(); g.asteroids={rock(10,10,3),rock(70,30)}
 g.bullets={{x=10,y=10,vx=0,vy=0,life=1}}; g:update(0.005)
 eq(g.score,20); eq(#g.asteroids,3); eq(g.asteroids[2].size,2); eq(#g.bullets,0)
end)
test('collision wraps across screen seam',function()
 local g=Game.new(); g.asteroids={rock(0.1,10),rock(70,30)}
 g.bullets={{x=95.9,y=10,vx=0,vy=0,life=1}}; g:update(0.005)
 eq(g.score,100); eq(#g.asteroids,1)
end)
test('clearing wave advances',function()
 local g=Game.new(); g.asteroids={rock(10,10)}
 g.bullets={{x=10,y=10,vx=0,vy=0,life=1}}; g:update(0.005)
 eq(g.wave,2); eq(#g.asteroids,5)
end)
test('protection, respawn, last life and restart',function()
 local g=Game.new(); g.asteroids={rock(g.ship.x,g.ship.y)}
 g:update(0.005); eq(g.lives,3); g.shield=0; g:update(0.005)
 eq(g.lives,2); assert(g.shield>0)
 g.lives=1; g.shield=0; g:update(0.005); assert(g.game_over); eq(g.lives,0)
 local frame=table.concat(m.render_frame(g),'\n'); assert(frame:find('GAME OVER',1,true))
 g:key('r'); eq(g.lives,3); eq(g.score,0); assert(not g.game_over)
end)
test('pause freezes all simulation and ignores fire',function()
 local g=Game.new(); g:key('p'); g:key('SPACE'); g:update(0.1)
 eq(g.shield,2.5); eq(#g.bullets,0)
 assert(table.concat(m.render_frame(g),'\n'):find('PAUSED',1,true))
end)
test('all render states fit terminal boundary sizes',function()
 local g=Game.new(); g.score=999999; g:fire(); g:explode(g.ship)
 for _,dims in ipairs({{2,1},{10,3},{40,11},{41,12},{80,24},{160,50}}) do
  for _,state in ipairs({'play','pause','over'}) do
   g.paused=state=='pause'; g.game_over=state=='over'
   local lines=m.render_frame(g,dims[1],dims[2]); eq(#lines,dims[2])
   for _,line in ipairs(lines) do eq(#line,dims[1]-1); assert(not line:find('[\r\n\27]')) end
  end
 end
end)
test('differential emission only updates changed rows',function()
 local a={'abc','def'}; local b={'abc','xyz'}
 local delta=m.frame_diff(b,a); assert(delta:find('\27[2;1H',1,true)); assert(not delta:find('\27[1;1H',1,true))
 assert(not delta:find('\27[2J',1,true)); eq(m.frame_diff(a,a),'\27[?2026h\27[?2026l')
end)
test('long deterministic simulation keeps finite bounded coordinates',function()
 local g=Game.new()
 for i=1,3000 do
  if g.game_over then g:key('r') end
  g:key('a'); g:key('w'); g:key('SPACE'); g:update(0.016)
  assert(g.ship.x>=0 and g.ship.x<m.WIDTH and g.ship.y>=0 and g.ship.y<m.HEIGHT)
  assert(#g.particles<200)
 end
end)
test('headless CLI and pipeline',function()
 for _,args in ipairs({'--help','--snapshot',''}) do
  local p=assert(io.popen('printf "w q" | luajit ffi_asteroids.lua '..args..' 2>&1'))
  local out=p:read('*a'); assert(p:close()); assert(#out>0)
  if args=='' then assert(out:find('interactive terminal',1,true)) end
 end
end)
print(string.format('Asteroids: %d tests passed',passed))
