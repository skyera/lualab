#!/usr/bin/env luajit
-- Terminal Asteroids. Linux terminal backend; mechanics/rendering are headless.
local ffi = require('ffi')
local bit = require('bit')
local M, Game = {}, {}
Game.__index = Game
local W, H, TAU = 96, 48, math.pi * 2
local function body(x,y,vx,vy) return {x=x,y=y,vx=vx or 0,vy=vy or 0} end
local function distance(a,b)
    local dx,dy=math.abs(a.x-b.x)%W,math.abs(a.y-b.y)%H
    dx,dy=math.min(dx,W-dx),math.min(dy,H-dy)
    return math.sqrt(dx*dx+dy*dy)
end
function Game:random()
    self.seed=(self.seed*16807)%2147483647
    return self.seed/2147483647
end
function Game:reset_ship()
    self.ship=body(W/2,H/2)
    self.angle=-math.pi/2
    self.shield=2.5
end
function Game:wave_start()
    self.asteroids={}
    for i=1,math.min(12,self.wave+3) do
        local a=body(self:random()*W,self:random()*H)
        if distance(a,self.ship)<18 then a.x=(self.ship.x+W/2)%W end
        local angle=self:random()*TAU
        local speed=3+self.wave+self:random()*3
        a.vx,a.vy=math.cos(angle)*speed,math.sin(angle)*speed
        a.size,a.phase=3,self:random()*TAU
        self.asteroids[#self.asteroids+1]=a
    end
end
function Game.new(seed)
    local g=setmetatable({seed=(seed or 42)%2147483646+1,score=0,lives=3,wave=1,
        bullets={},particles={},paused=false,game_over=false,cooldown=0,thrust=0},Game)
    g:reset_ship(); g:wave_start()
    return g
end
function Game:fire()
    if self.paused or self.game_over or self.cooldown>0 then return end
    local c,s=math.cos(self.angle),math.sin(self.angle)
    local b=body((self.ship.x+c*2)%W,(self.ship.y+s*2)%H,self.ship.vx+c*65,self.ship.vy+s*65)
    b.life=0.85
    self.bullets[#self.bullets+1]=b
    self.cooldown=0.15
end
function Game:key(key)
    if key=='q' or key=='Q' or key=='ESC' or key=='CTRL_C' then return false end
    if key=='r' or key=='R' then
        local fresh=Game.new(self.seed)
        for k in pairs(self) do self[k]=nil end
        for k,v in pairs(fresh) do self[k]=v end
    elseif key=='p' or key=='P' then self.paused=not self.paused
    elseif not self.paused and not self.game_over then
        if key=='a' or key=='A' or key=='LEFT' then self.angle=self.angle-0.18
        elseif key=='d' or key=='D' or key=='RIGHT' then self.angle=self.angle+0.18
        elseif key=='w' or key=='W' or key=='UP' then self.thrust=0.18
        elseif key=='SPACE' or key==' ' then self:fire() end
    end
    return true
end
function Game:explode(a)
    for _=1,10 do
        local angle=self:random()*TAU
        local p=body(a.x,a.y,math.cos(angle)*12,math.sin(angle)*12)
        p.life=0.4+self:random()*0.4
        self.particles[#self.particles+1]=p
    end
end
function Game:hit(index)
    local a=table.remove(self.asteroids,index)
    self.score=self.score+({100,50,20})[a.size]
    self:explode(a)
    if a.size>1 then
        for sign=-1,1,2 do
            local child=body(a.x,a.y,a.vx-sign*5,a.vy+sign*5)
            child.size,child.phase=a.size-1,a.phase+sign
            self.asteroids[#self.asteroids+1]=child
        end
    end
end
local function move(a,dt)
    a.x,a.y=(a.x+a.vx*dt)%W,(a.y+a.vy*dt)%H
end
function Game:update(dt)
    if self.paused or self.game_over or dt<=0 then return end
    dt=math.min(dt,0.1)
    -- Substeps keep fast projectiles from passing through small asteroids.
    local steps=math.ceil(dt/0.005)
    dt=dt/steps
    for _=1,steps do
        self.cooldown=math.max(0,self.cooldown-dt)
        self.shield=math.max(0,self.shield-dt)
        if self.thrust>0 then
            self.ship.vx=self.ship.vx+math.cos(self.angle)*40*dt
            self.ship.vy=self.ship.vy+math.sin(self.angle)*40*dt
            self.thrust=math.max(0,self.thrust-dt)
        end
        local speed=math.sqrt(self.ship.vx^2+self.ship.vy^2)
        if speed>30 then self.ship.vx,self.ship.vy=self.ship.vx*30/speed,self.ship.vy*30/speed end
        move(self.ship,dt)
        for _,a in ipairs(self.asteroids) do move(a,dt) end
        for i=#self.bullets,1,-1 do
            local b=self.bullets[i]; move(b,dt); b.life=b.life-dt
            if b.life<=0 then table.remove(self.bullets,i)
            else
                for j=#self.asteroids,1,-1 do
                    if distance(b,self.asteroids[j])<=self.asteroids[j].size*1.7 then
                        self:hit(j); table.remove(self.bullets,i); break
                    end
                end
            end
        end
        for i=#self.particles,1,-1 do
            local p=self.particles[i]; move(p,dt); p.life=p.life-dt
            if p.life<=0 then table.remove(self.particles,i) end
        end
        if self.shield<=0 then
            for _,a in ipairs(self.asteroids) do
                if distance(self.ship,a)<=a.size*1.7+0.7 then
                    self:explode(self.ship); self.lives=self.lives-1; self.bullets={}
                    if self.lives==0 then self.game_over=true; return end
                    self:reset_ship(); self.thrust=0; break
                end
            end
        end
        if #self.asteroids==0 then self.wave=self.wave+1; self:wave_start() end
    end
end

-- ASCII-only frame generator: every row fits cols-1, even at tiny sizes.
function M.render_frame(g,cols,rows)
    cols,rows=math.max(2,cols or 80),math.max(1,rows or 28)
    local width=cols-1
    local function fit(s) return s:sub(1,width)..string.rep(' ',math.max(0,width-#s)) end
    if width<40 or rows<12 then
        local out={fit('Resize terminal: minimum 41 x 12')}
        for i=2,rows do out[i]=fit(i==2 and 'Q quit' or '') end
        return out
    end
    local bw,bh=width-2,rows-4
    local grid={}
    for y=1,bh do grid[y]={}; for x=1,bw do grid[y][x]=' ' end end
    local function plot(x,y,ch)
        local cx,cy=math.floor((x%W)/W*bw)+1,math.floor((y%H)/H*bh)+1
        cx,cy=math.min(bw,cx),math.min(bh,cy)
        grid[cy][cx]=ch
    end
    for _,p in ipairs(g.particles) do plot(p.x,p.y,'.') end
    for _,a in ipairs(g.asteroids) do
        for i=0,15 do
            local angle=i/16*TAU
            local radius=a.size*1.7*(1+0.18*math.sin(i*2+a.phase))
            plot(a.x+math.cos(angle)*radius,a.y+math.sin(angle)*radius,'o')
        end
    end
    for _,b in ipairs(g.bullets) do plot(b.x,b.y,'*') end
    if not g.game_over and (g.shield==0 or math.floor(g.shield*8)%2==0) then
        local symbols={'>','\\','v','/','<','\\','^','/'}
        plot(g.ship.x,g.ship.y,symbols[math.floor((g.angle%TAU)/TAU*8+0.5)%8+1])
        if g.thrust>0 then plot(g.ship.x-math.cos(g.angle)*2,g.ship.y-math.sin(g.angle)*2,'+') end
    end
    local status=g.game_over and 'GAME OVER - R restart' or (g.paused and 'PAUSED' or '')
    local out={fit(string.format('ASTEROIDS  Score: %d  Lives: %d  Wave: %d  %s',g.score,g.lives,g.wave,status)),
        '+'..string.rep('-',bw)..'+'}
    for y=1,bh do out[#out+1]='|'..table.concat(grid[y])..'|' end
    out[#out+1]='+'..string.rep('-',bw)..'+'
    out[#out+1]=fit('A/D rotate  W thrust  SPACE fire  P pause  R restart  Q quit')
    return out
end
function M.frame_diff(lines,old)
    local out={'\27[?2026h'}
    for i,line in ipairs(lines) do
        if not old or old[i]~=line then out[#out+1]=string.format('\27[%d;1H%s\27[K',i,line) end
    end
    out[#out+1]='\27[?2026l'
    return table.concat(out)
end
-- Stateful decoder retains fragmented VT arrow sequences across reads.
function M.decoder()
    local pending=''
    return function(bytes,eof)
        pending=pending..(bytes or '')
        local keys={}
        while #pending>0 do
            if pending:sub(1,1)=='\27' then
                if (#pending==1 or pending=='\27[') and not eof then break end
                local seq=pending:match('^\27%[[0-9;]*[A-Za-z~]')
                if seq then
                    local key=({['\27[A']='UP',['\27[B']='DOWN',['\27[C']='RIGHT',['\27[D']='LEFT'})[seq]
                    if key then keys[#keys+1]=key end
                    pending=pending:sub(#seq+1)
                else keys[#keys+1]='ESC'; pending=pending:sub(2) end
            else
                local ch=pending:sub(1,1)
                keys[#keys+1]=ch==' ' and 'SPACE' or (ch=='\3' and 'CTRL_C' or ch)
                pending=pending:sub(2)
            end
        end
        return keys
    end
end
local function launch()
    assert(ffi.os=='Linux','Interactive Asteroids currently supports Linux; --snapshot works headlessly.')
    ffi.cdef[[
        struct AstTermios { unsigned int c_iflag,c_oflag,c_cflag,c_lflag; unsigned char c_line,c_cc[32]; unsigned int c_ispeed,c_ospeed; };
        struct AstPoll { int fd; short events,revents; };
        struct AstSize { unsigned short rows,cols,xpixel,ypixel; };
        struct AstTime { long sec,nsec; };
        int isatty(int fd);
        int tcgetattr(int fd, struct AstTermios *p);
        int tcsetattr(int fd,int actions,const struct AstTermios *p);
        int poll(struct AstPoll *fds,unsigned long n,int timeout);
        long read(int fd,void *buf,size_t count);
        int ioctl(int fd,unsigned long request,...);
        int clock_gettime(int id,struct AstTime *p);
        typedef void (*ast_signal_handler)(int);
        ast_signal_handler signal(int sig,ast_signal_handler handler);
    ]]
    if ffi.C.isatty(0)==0 or ffi.C.isatty(1)==0 then
        io.write('Asteroids needs an interactive terminal. Try --snapshot or --test.\n'); return
    end
    local original=ffi.new('struct AstTermios')
    assert(ffi.C.tcgetattr(0,original)==0,'Cannot read terminal settings')
    local raw=ffi.new('struct AstTermios'); ffi.copy(raw,original,ffi.sizeof(raw))
    raw.c_lflag=bit.band(raw.c_lflag,bit.bnot(11))
    raw.c_iflag=bit.band(raw.c_iflag,bit.bnot(1280))
    raw.c_cc[5],raw.c_cc[6]=0,0
    local stopped=false
    local callback=ffi.cast('ast_signal_handler',function() stopped=true end)
    local previous2=ffi.C.signal(2,callback)
    local previous15=ffi.C.signal(15,callback)
    local enabled=false
    local ok,err=xpcall(function()
        assert(ffi.C.tcsetattr(0,0,raw)==0,'Cannot enable raw input'); enabled=true
        io.write('\27[?1049h\27[?25l\27[?7l\27[2J'); io.flush()
        local g=Game.new(os.time())
        local size=ffi.new('struct AstSize')
        local clock=ffi.new('struct AstTime')
        local poll=ffi.new('struct AstPoll',{0,1,0})
        local buf=ffi.new('uint8_t[256]')
        local decode=M.decoder()
        local old,oldcols,oldrows,last
        local function now()
            assert(ffi.C.clock_gettime(1,clock)==0,'Clock failed')
            return tonumber(clock.sec)+tonumber(clock.nsec)/1e9
        end
        last=now()
        while not stopped do
            poll.revents=0
            if ffi.C.poll(poll,1,16)>0 then
                local n=ffi.C.read(0,buf,256)
                if n<=0 then break end
                for _,key in ipairs(decode(ffi.string(buf,n))) do if not g:key(key) then stopped=true end end
            else
                for _,key in ipairs(decode('',true)) do if not g:key(key) then stopped=true end end
            end
            local t=now(); g:update(t-last); last=t
            local cols,rows=80,24
            if ffi.C.ioctl(1,0x5413,size)==0 and size.cols>0 then cols,rows=tonumber(size.cols),tonumber(size.rows) end
            if oldcols and (oldcols~=cols or oldrows~=rows) then
                io.write('\27[2J'); old=nil
            end
            local lines=M.render_frame(g,cols,rows)
            io.write(M.frame_diff(lines,old)); io.flush()
            old,oldcols,oldrows=lines,cols,rows
        end
    end,debug.traceback)
    if enabled then
        ffi.C.tcsetattr(0,0,original)
        io.write('\27[?7h\27[?1049l\27[?25h\27[0m'); io.flush()
    end
    ffi.C.signal(2,previous2); ffi.C.signal(15,previous15); callback:free()
    if not ok then error(err,0) end
end
-- Signal callbacks must not re-enter a JIT-compiled call into C.
require('jit').off(launch,true)
M.Game,M.WIDTH,M.HEIGHT=Game,W,H
if ...=='ffi_asteroids' then return M end
local mode=arg[1]
if mode=='--help' or mode=='-h' then
    print('Usage: luajit ffi_asteroids.lua [--help|--snapshot|--test]\nLinux terminal Asteroids: A/D or arrows rotate, W/Up thrust, Space fire.\nP pause, R restart, Q/Ctrl-C quit. Hold movement keys for keyboard repeat.')
elseif mode=='--snapshot' then print(table.concat(M.render_frame(Game.new(),80,24),'\n'))
elseif mode=='--test' then dofile('test_ffi_asteroids.lua')
elseif mode then io.stderr:write('Unknown option: '..mode..'\n'); os.exit(1)
else launch() end
