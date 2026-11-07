#!/usr/bin/env luajit
-- Terminal Asteroids. Linux and Windows console backends; mechanics/rendering are headless.
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
-- ============================================================================
-- Terminal backends: POSIX (Linux) and Win32 console
-- ============================================================================
-- Each backend provides:
--   is_interactive() -> bool   stdin and stdout are both a real terminal
--   open()                     enter raw input mode (errors if impossible)
--   close()                    restore terminal state; safe after a failed open()
--   read() -> string|nil|false input bytes, nil on timeout, false on end of input
--   interrupted() -> bool      an external stop request (SIGINT/SIGTERM) arrived
--   size() -> cols, rows
--   now() -> seconds from a monotonic clock

local READ_TIMEOUT_MS = 16
local CONSOLE_READ_BATCH = 32
local VK_BYTES = {
    [0x25] = '\27[D',
    [0x26] = '\27[A',
    [0x27] = '\27[C',
    [0x28] = '\27[B',
}

--- Translate a Win32 key-down event into the VT bytes the shared decoder expects.
--- vk is the virtual key code, ch the ASCII character (0 for non-character keys).
function M.console_key_bytes(vk, ch)
    local bytes = VK_BYTES[vk]
    if bytes then
        return bytes
    end
    if ch and ch ~= 0 then
        return string.char(ch)
    end
    return ''
end

local function posix_backend()
    ffi.cdef[[
        struct AstTermios {
            unsigned int c_iflag, c_oflag, c_cflag, c_lflag;
            unsigned char c_line, c_cc[32];
            unsigned int c_ispeed, c_ospeed;
        };
        struct AstPoll { int fd; short events, revents; };
        struct AstSize { unsigned short rows, cols, xpixel, ypixel; };
        struct AstTime { long sec, nsec; };
        int isatty(int fd);
        int tcgetattr(int fd, struct AstTermios *p);
        int tcsetattr(int fd, int actions, const struct AstTermios *p);
        int poll(struct AstPoll *fds, unsigned long n, int timeout);
        long read(int fd, void *buf, size_t count);
        int ioctl(int fd, unsigned long request, ...);
        int clock_gettime(int id, struct AstTime *p);
        typedef void (*ast_signal_handler)(int);
        ast_signal_handler signal(int sig, ast_signal_handler handler);
    ]]
    local backend = {}
    local original = ffi.new('struct AstTermios')
    local poll_fd = ffi.new('struct AstPoll', { 0, 1, 0 })
    local buf = ffi.new('uint8_t[256]')
    local winsize = ffi.new('struct AstSize')
    local clock = ffi.new('struct AstTime')
    local stopped = false
    local callback, previous2, previous15
    local raw_enabled = false

    function backend.is_interactive()
        return ffi.C.isatty(0) ~= 0 and ffi.C.isatty(1) ~= 0
    end

    function backend.open()
        assert(ffi.C.tcgetattr(0, original) == 0, 'Cannot read terminal settings')
        local raw = ffi.new('struct AstTermios')
        ffi.copy(raw, original, ffi.sizeof(raw))
        raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(11))
        raw.c_iflag = bit.band(raw.c_iflag, bit.bnot(1280))
        raw.c_cc[5], raw.c_cc[6] = 0, 0
        callback = ffi.cast('ast_signal_handler', function()
            stopped = true
        end)
        previous2 = ffi.C.signal(2, callback)
        previous15 = ffi.C.signal(15, callback)
        assert(ffi.C.tcsetattr(0, 0, raw) == 0, 'Cannot enable raw input')
        raw_enabled = true
    end

    function backend.close()
        if raw_enabled then
            ffi.C.tcsetattr(0, 0, original)
            raw_enabled = false
        end
        if callback then
            ffi.C.signal(2, previous2)
            ffi.C.signal(15, previous15)
            callback:free()
            callback = nil
        end
    end

    function backend.read()
        poll_fd.revents = 0
        if ffi.C.poll(poll_fd, 1, READ_TIMEOUT_MS) <= 0 then
            return nil
        end
        local n = ffi.C.read(0, buf, 256)
        if n <= 0 then
            return false
        end
        return ffi.string(buf, n)
    end

    function backend.interrupted()
        return stopped
    end

    function backend.size()
        if ffi.C.ioctl(1, 0x5413, winsize) == 0 and winsize.cols > 0 then
            return tonumber(winsize.cols), tonumber(winsize.rows)
        end
        return 80, 24
    end

    function backend.now()
        assert(ffi.C.clock_gettime(1, clock) == 0, 'Clock failed')
        return tonumber(clock.sec) + tonumber(clock.nsec) / 1e9
    end

    return backend
end

local function windows_backend()
    ffi.cdef[[
        typedef void *AstHandle;
        typedef unsigned long AstDword;
        typedef struct { short x, y; } AstCoord;
        typedef struct { short left, top, right, bottom; } AstRect;
        typedef struct {
            AstCoord size;
            AstCoord cursor;
            unsigned short attributes;
            AstRect window;
            AstCoord max_size;
        } AstScreenInfo;
        typedef struct {
            unsigned short event_type;
            int key_down;
            unsigned short repeat_count, vk, scan, unicode_char;
            AstDword control_keys;
        } AstInputRecord;
        AstHandle GetStdHandle(AstDword which);
        int GetConsoleMode(AstHandle h, AstDword *mode);
        int SetConsoleMode(AstHandle h, AstDword mode);
        AstDword WaitForSingleObject(AstHandle h, AstDword ms);
        int GetNumberOfConsoleInputEvents(AstHandle h, AstDword *count);
        int ReadConsoleInputA(AstHandle h, AstInputRecord *records, AstDword n, AstDword *read);
        int GetConsoleScreenBufferInfo(AstHandle h, AstScreenInfo *info);
        int QueryPerformanceCounter(int64_t *count);
        int QueryPerformanceFrequency(int64_t *freq);
    ]]
    local STD_INPUT, STD_OUTPUT = 0xFFFFFFF6, 0xFFFFFFF5 -- (DWORD)-10, (DWORD)-11
    local ENABLE_EXTENDED_FLAGS = 0x0080 -- also drops QuickEdit, which freezes output on click
    local ENABLE_PROCESSED_OUTPUT, ENABLE_VT_PROCESSING = 0x0001, 0x0004
    local EVENT_KEY = 0x0001

    local backend = {}
    local h_in = ffi.C.GetStdHandle(STD_INPUT)
    local h_out = ffi.C.GetStdHandle(STD_OUTPUT)
    local records = ffi.new('AstInputRecord[?]', CONSOLE_READ_BATCH)
    local count = ffi.new('AstDword[1]')
    local nread = ffi.new('AstDword[1]')
    local info = ffi.new('AstScreenInfo')
    local counter = ffi.new('int64_t[1]')
    local frequency = ffi.new('int64_t[1]')
    local orig_in, orig_out

    function backend.is_interactive()
        return ffi.C.GetConsoleMode(h_in, count) ~= 0 and ffi.C.GetConsoleMode(h_out, count) ~= 0
    end

    function backend.open()
        local mode = ffi.new('AstDword[1]')
        assert(ffi.C.GetConsoleMode(h_in, mode) ~= 0, 'Cannot read console input mode')
        local saved_in = mode[0]
        assert(ffi.C.GetConsoleMode(h_out, mode) ~= 0, 'Cannot read console output mode')
        local saved_out = mode[0]
        local out_mode = bit.bor(saved_out, ENABLE_PROCESSED_OUTPUT, ENABLE_VT_PROCESSING)
        assert(ffi.C.SetConsoleMode(h_out, out_mode) ~= 0,
            'Console does not support ANSI escapes; use Windows Terminal')
        orig_out = saved_out
        assert(ffi.C.SetConsoleMode(h_in, ENABLE_EXTENDED_FLAGS) ~= 0, 'Cannot enable raw console input')
        orig_in = saved_in
        assert(ffi.C.QueryPerformanceFrequency(frequency) ~= 0, 'Clock failed')
    end

    function backend.close()
        if orig_in then
            ffi.C.SetConsoleMode(h_in, orig_in)
            orig_in = nil
        end
        if orig_out then
            ffi.C.SetConsoleMode(h_out, orig_out)
            orig_out = nil
        end
    end

    function backend.read()
        if ffi.C.WaitForSingleObject(h_in, READ_TIMEOUT_MS) ~= 0 then
            return nil
        end
        assert(ffi.C.GetNumberOfConsoleInputEvents(h_in, count) ~= 0, 'Cannot query console input')
        local want = math.min(tonumber(count[0]), CONSOLE_READ_BATCH)
        if want == 0 then
            return nil
        end
        assert(ffi.C.ReadConsoleInputA(h_in, records, want, nread) ~= 0, 'Cannot read console input')
        local parts = {}
        for i = 0, tonumber(nread[0]) - 1 do
            local rec = records[i]
            if rec.event_type == EVENT_KEY and rec.key_down ~= 0 then
                parts[#parts + 1] = M.console_key_bytes(rec.vk, bit.band(rec.unicode_char, 0xFF))
            end
        end
        local bytes = table.concat(parts)
        if bytes == '' then
            return nil
        end
        return bytes
    end

    -- Raw mode disables Ctrl-C processing, so it arrives as the key '\3' instead.
    function backend.interrupted()
        return false
    end

    function backend.size()
        if ffi.C.GetConsoleScreenBufferInfo(h_out, info) ~= 0 then
            local cols = info.window.right - info.window.left + 1
            local rows = info.window.bottom - info.window.top + 1
            if cols > 0 and rows > 0 then
                return tonumber(cols), tonumber(rows)
            end
        end
        return 80, 24
    end

    function backend.now()
        assert(ffi.C.QueryPerformanceCounter(counter) ~= 0, 'Clock failed')
        return tonumber(counter[0]) / tonumber(frequency[0])
    end

    return backend
end

local function create_backend()
    if ffi.os == 'Linux' then
        return posix_backend()
    elseif ffi.os == 'Windows' then
        return windows_backend()
    end
    error('Interactive Asteroids supports Linux and Windows; --snapshot works headlessly on ' .. ffi.os)
end

-- ============================================================================
-- Interactive loop
-- ============================================================================
local function launch()
    local backend = create_backend()
    if not backend.is_interactive() then
        io.write('Asteroids needs an interactive terminal. Try --snapshot or --test.\n')
        return
    end
    local entered = false
    local ok, err = xpcall(function()
        backend.open()
        entered = true
        io.write('\27[?1049h\27[?25l\27[?7l\27[2J')
        io.flush()
        local g = Game.new(os.time())
        local decode = M.decoder()
        local stopped = false
        local old, oldcols, oldrows
        local last = backend.now()

        local function feed(keys)
            for _, key in ipairs(keys) do
                if not g:key(key) then
                    stopped = true
                end
            end
        end

        while not stopped and not backend.interrupted() do
            local bytes = backend.read()
            if bytes == false then
                break
            end
            feed(decode(bytes or '', bytes == nil))
            local t = backend.now()
            g:update(t - last)
            last = t
            local cols, rows = backend.size()
            if oldcols and (oldcols ~= cols or oldrows ~= rows) then
                io.write('\27[2J')
                old = nil
            end
            local lines = M.render_frame(g, cols, rows)
            io.write(M.frame_diff(lines, old))
            io.flush()
            old, oldcols, oldrows = lines, cols, rows
        end
    end, debug.traceback)
    if entered then
        io.write('\27[?7h\27[?1049l\27[?25h\27[0m')
        io.flush()
    end
    backend.close()
    if not ok then
        error(err, 0)
    end
end
-- Signal callbacks must not re-enter a JIT-compiled call into C.
require('jit').off(launch,true)
M.Game,M.WIDTH,M.HEIGHT=Game,W,H
if ...=='ffi_asteroids' then return M end
local mode=arg[1]
if mode=='--help' or mode=='-h' then
    print('Usage: luajit ffi_asteroids.lua [--help|--snapshot|--test]\nTerminal Asteroids (Linux, Windows): A/D or arrows rotate, W/Up thrust, Space fire.\nP pause, R restart, Q/Ctrl-C quit. Hold movement keys for keyboard repeat.')
elseif mode=='--snapshot' then print(table.concat(M.render_frame(Game.new(),80,24),'\n'))
elseif mode=='--test' then dofile('test_ffi_asteroids.lua')
elseif mode then io.stderr:write('Unknown option: '..mode..'\n'); os.exit(1)
else launch() end
