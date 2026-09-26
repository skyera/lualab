#!/usr/bin/env luajit
--[[
    ffi_verlet_cloth.lua
    Interactive Verlet cloth and rope simulator using LuaJIT FFI.

    Controls: mouse drag to pull nodes, click a constraint to cut it,
    Space pause, R reset, +/- solver iterations, Q quit.
    Modes: --help, --test, --snapshot [--ascii].
]]

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
    typedef struct {
        double x, y, old_x, old_y;
        int anchored;
        int active;
    } VerletParticle;
    typedef struct {
        int a, b;
        double rest_length;
        int kind;
        int active;
    } VerletConstraint;
    typedef unsigned int verlet_tcflag_t;
    typedef unsigned char verlet_cc_t;
    typedef unsigned int verlet_speed_t;
    struct VerletTermios {
        verlet_tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
        verlet_cc_t c_line, c_cc[32];
        verlet_speed_t c_ispeed, c_ospeed;
    };
    struct VerletPollfd { int fd; short events; short revents; };
    struct VerletTimespec { long tv_sec; long tv_nsec; };
    int tcgetattr(int fd, struct VerletTermios *termios_p);
    int tcsetattr(int fd, int actions, const struct VerletTermios *termios_p);
    int poll(struct VerletPollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, unsigned long count);
    int clock_gettime(int clock_id, struct VerletTimespec *tp);
    struct VerletWinsize { unsigned short rows, cols, xpixel, ypixel; };
    int ioctl(int fd, unsigned long request, struct VerletWinsize *argp);
    typedef void (*verlet_sighandler_t)(int);
    verlet_sighandler_t signal(int signum, verlet_sighandler_t handler);
]]

local WIDTH, HEIGHT = 74, 18
local MAX_PARTICLES, MAX_CONSTRAINTS = 256, 1200
local GRAVITY, DAMPING = 26, 0.992
local KIND_HORIZONTAL, KIND_VERTICAL, KIND_DIAGONAL, KIND_BEND, KIND_ROPE = 1, 2, 3, 4, 5
local CSI_ESC = string.char(27)
local Scene = {}
Scene.__index = Scene
local signal_callbacks = {}

local function distance(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

function Scene.new()
    local self = setmetatable({}, Scene)
    self.particles = ffi.new("VerletParticle[?]", MAX_PARTICLES)
    self.constraints = ffi.new("VerletConstraint[?]", MAX_CONSTRAINTS)
    self.particle_count, self.constraint_count = 0, 0
    self.iterations, self.frame, self.paused = 5, 0, false
    self.drag_index, self.drag_was_anchor = -1, false
    self:reset()
    return self
end

function Scene:add_particle(x, y, anchored)
    assert(self.particle_count < MAX_PARTICLES, "particle capacity exceeded")
    local index = self.particle_count
    local p = self.particles[index]
    p.x, p.y, p.old_x, p.old_y = x, y, x, y
    p.anchored, p.active = anchored and 1 or 0, 1
    self.particle_count = index + 1
    return index
end

function Scene:add_constraint(a, b, kind)
    assert(self.constraint_count < MAX_CONSTRAINTS, "constraint capacity exceeded")
    local index = self.constraint_count
    local p1, p2 = self.particles[a], self.particles[b]
    local c = self.constraints[index]
    c.a, c.b = a, b
    c.rest_length = distance(p1.x, p1.y, p2.x, p2.y)
    c.kind, c.active = kind, 1
    self.constraint_count = index + 1
    return index
end

function Scene:reset()
    self.particle_count, self.constraint_count = 0, 0
    self.frame, self.paused = 0, false
    self.drag_index, self.drag_was_anchor = -1, false

    -- A 10x8 pinned fabric sheet with structural, shear, and bend links.
    local columns, rows = 10, 8
    local start_x, start_y, gap_x, gap_y = 7, 3, 4.3, 2.0
    local grid = {}
    for row = 0, rows - 1 do
        grid[row] = {}
        for col = 0, columns - 1 do
            local index = self:add_particle(start_x + col * gap_x, start_y + row * gap_y, row == 0)
            grid[row][col] = index
        end
    end
    for row = 0, rows - 1 do
        for col = 0, columns - 1 do
            local here = grid[row][col]
            if col + 1 < columns then self:add_constraint(here, grid[row][col + 1], KIND_HORIZONTAL) end
            if row + 1 < rows then self:add_constraint(here, grid[row + 1][col], KIND_VERTICAL) end
            if row + 1 < rows and col + 1 < columns then
                self:add_constraint(here, grid[row + 1][col + 1], KIND_DIAGONAL)
                self:add_constraint(grid[row][col + 1], grid[row + 1][col], KIND_DIAGONAL)
            end
            if col + 2 < columns then self:add_constraint(here, grid[row][col + 2], KIND_BEND) end
            if row + 2 < rows then self:add_constraint(here, grid[row + 2][col], KIND_BEND) end
        end
    end

    -- A separate long, anchored rope to demonstrate a chain without shear links.
    local previous = self:add_particle(64, 2, true)
    for i = 1, 10 do
        local next_particle = self:add_particle(64 + math.sin(i * 0.22) * 1.5, 2 + i * 1.35, false)
        self:add_constraint(previous, next_particle, KIND_ROPE)
        previous = next_particle
    end
end

function Scene:step(dt)
    if self.paused then return end
    dt = math.min(math.max(dt or 1 / 60, 0), 1 / 30)
    local dt2 = dt * dt
    for i = 0, self.particle_count - 1 do
        local p = self.particles[i]
        if p.active ~= 0 and p.anchored == 0 and i ~= self.drag_index then
            local x, y = p.x, p.y
            p.x = p.x + (p.x - p.old_x) * DAMPING
            p.y = p.y + (p.y - p.old_y) * DAMPING + GRAVITY * dt2
            p.old_x, p.old_y = x, y
            if p.x < 1 then p.x, p.old_x = 1, 1 end
            if p.x > WIDTH - 2 then p.x, p.old_x = WIDTH - 2, WIDTH - 2 end
            if p.y > HEIGHT - 2 then
                p.y, p.old_y = HEIGHT - 2, HEIGHT - 2
                p.old_x = p.x - (p.x - p.old_x) * 0.65
            end
        end
    end

    for _ = 1, self.iterations do
        for i = 0, self.constraint_count - 1 do
            local c = self.constraints[i]
            if c.active ~= 0 then
                local a, b = self.particles[c.a], self.particles[c.b]
                if a.active ~= 0 and b.active ~= 0 then
                    local dx, dy = b.x - a.x, b.y - a.y
                    local length = math.sqrt(dx * dx + dy * dy)
                    if length > 1e-9 then
                        local correction = (length - c.rest_length) / length
                        local a_free = a.anchored == 0 and c.a ~= self.drag_index
                        local b_free = b.anchored == 0 and c.b ~= self.drag_index
                        if a_free and b_free then
                            local half = correction * 0.5
                            a.x, a.y = a.x + dx * half, a.y + dy * half
                            b.x, b.y = b.x - dx * half, b.y - dy * half
                        elseif a_free then
                            a.x, a.y = a.x + dx * correction, a.y + dy * correction
                        elseif b_free then
                            b.x, b.y = b.x - dx * correction, b.y - dy * correction
                        end
                    end
                end
            end
        end
    end
    self.frame = self.frame + 1
end

function Scene:begin_drag(x, y)
    local best, best_dist = -1, 2.5
    for i = 0, self.particle_count - 1 do
        local p = self.particles[i]
        local d = distance(x, y, p.x, p.y)
        if p.active ~= 0 and d < best_dist then best, best_dist = i, d end
    end
    if best >= 0 then
        self.drag_index = best
        self.drag_was_anchor = self.particles[best].anchored ~= 0
        self.particles[best].anchored = 1
        self:move_drag(x, y)
    end
    return best
end

function Scene:move_drag(x, y)
    if self.drag_index < 0 then return end
    local p = self.particles[self.drag_index]
    p.x, p.y, p.old_x, p.old_y = x, y, x, y
end

function Scene:end_drag()
    if self.drag_index >= 0 then
        self.particles[self.drag_index].anchored = self.drag_was_anchor and 1 or 0
        self.drag_index = -1
    end
end

local function point_segment_distance(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local denom = dx * dx + dy * dy
    local t = denom > 1e-9 and ((px - ax) * dx + (py - ay) * dy) / denom or 0
    t = math.max(0, math.min(1, t))
    return distance(px, py, ax + t * dx, ay + t * dy)
end

function Scene:cut_nearest(x, y, radius)
    radius = radius or 1.35
    local best, best_dist = -1, radius
    for i = 0, self.constraint_count - 1 do
        local c = self.constraints[i]
        if c.active ~= 0 then
            local a, b = self.particles[c.a], self.particles[c.b]
            local d = point_segment_distance(x, y, a.x, a.y, b.x, b.y)
            if d < best_dist then best, best_dist = i, d end
        end
    end
    if best >= 0 then self.constraints[best].active = 0 end
    return best
end

local function make_frame(scene)
    local canvas = {}
    for y = 0, HEIGHT - 1 do
        canvas[y] = {}
        for x = 0, WIDTH - 1 do canvas[y][x + 1] = " " end
    end
    for i = 0, scene.constraint_count - 1 do
        local c = scene.constraints[i]
        if c.active ~= 0 and c.kind ~= KIND_BEND then
            local a, b = scene.particles[c.a], scene.particles[c.b]
            local x0, y0 = math.floor(a.x + 0.5), math.floor(a.y + 0.5)
            local x1, y1 = math.floor(b.x + 0.5), math.floor(b.y + 0.5)
            local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
            local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
            local err = dx - dy
            local symbol = c.kind == KIND_ROPE and "." or (c.kind == KIND_HORIZONTAL and "-" or (c.kind == KIND_VERTICAL and "|" or ((x1 - x0) * (y1 - y0) >= 0 and "\\" or "/")))
            while true do
                if x0 >= 0 and x0 < WIDTH and y0 >= 0 and y0 < HEIGHT and canvas[y0][x0 + 1] == " " then canvas[y0][x0 + 1] = symbol end
                if x0 == x1 and y0 == y1 then break end
                local e2 = 2 * err
                if e2 > -dy then err, x0 = err - dy, x0 + sx end
                if e2 < dx then err, y0 = err + dx, y0 + sy end
            end
        end
    end
    for i = 0, scene.particle_count - 1 do
        local p = scene.particles[i]
        if p.active ~= 0 then
            local x, y = math.floor(p.x + 0.5), math.floor(p.y + 0.5)
            if x >= 0 and x < WIDTH and y >= 0 and y < HEIGHT then
                canvas[y][x + 1] = i == scene.drag_index and "@" or (p.anchored ~= 0 and "O" or "o")
            end
        end
    end
    local lines = {}
    for y = 0, HEIGHT - 1 do lines[#lines + 1] = "|" .. table.concat(canvas[y]) .. "|" end
    return lines
end

local function render_frame(scene, use_color)
    local active = 0
    for i = 0, scene.constraint_count - 1 do if scene.constraints[i].active ~= 0 then active = active + 1 end end
    local state = scene.paused and "PAUSED" or "LIVE"
    local title = string.format(" VERLET CLOTH + ROPE | %-6s | %d particles | %d links | %d passes", state, scene.particle_count, active, scene.iterations)
    local lines = { title, string.rep("-", WIDTH + 2) }
    local canvas = make_frame(scene)
    for i = 1, #canvas do
        local line = canvas[i]
        if use_color then
            local colored = {}
            for j = 1, #line do
                local ch = line:sub(j, j)
                local color
                if ch == "O" then color = "32"
                elseif ch == "@" then color = "1;33"
                elseif ch == "." then color = "33"
                elseif ch == "o" then color = "1;37"
                elseif ch == "-" or ch == "|" or ch == "/" or ch == "\\" then color = "36" end
                colored[#colored + 1] = color and ("\27[" .. color .. "m" .. ch .. "\27[0m") or ch
            end
            line = table.concat(colored)
        end
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = string.rep("-", WIDTH + 2)
    lines[#lines + 1] = " Drag: pull nodes | Right-click/X: cut | Space: pause | R: reset"
    lines[#lines + 1] = " +/-: solver passes | Q: quit | FFI arrays + Verlet distance constraints"
    return table.concat(lines, "\n")
end

local function run_self_tests()
    local function check(name, condition)
        assert(condition, "FAIL: " .. name)
        print("  PASS: " .. name)
    end
    local scene = Scene.new()
    check("scene uses FFI-backed particle and constraint arrays", ffi.istype("VerletParticle[?]", scene.particles) and scene.particle_count > 0 and scene.constraint_count > 0)
    check("cloth edge and rope anchor stay pinned", scene.particles[0].anchored == 1 and scene.particles[scene.particle_count - 11].anchored == 1)

    local free = scene.particles[10]
    local initial_y = free.y
    scene.constraint_count = 0
    scene:step(1 / 60)
    check("gravity advances a free particle downward", free.y > initial_y)

    scene = Scene.new()
    scene.particle_count, scene.constraint_count = 0, 0
    local pa = scene:add_particle(10, 5, true)
    local pb = scene:add_particle(15, 5, false)
    local c = scene:add_constraint(pa, pb, KIND_HORIZONTAL)
    local pinned = scene.particles[pa]
    local moving = scene.particles[pb]
    moving.x = moving.x + 2
    local stretched = distance(pinned.x, pinned.y, moving.x, moving.y)
    scene:step(1 / 60)
    check("solver restores stretched link to its rest length", math.abs(distance(pinned.x, pinned.y, moving.x, moving.y) - scene.constraints[c].rest_length) < 0.01)
    check("anchored endpoint remains fixed during solve", pinned.x == 10 and pinned.y == 5)

    scene = Scene.new()
    local selected = scene:begin_drag(7, 3)
    check("drag selects a nearby particle", selected == 0 and scene.drag_index == 0)
    scene:move_drag(12, 5)
    check("drag moves node without injecting velocity", scene.particles[0].x == 12 and scene.particles[0].old_x == 12)
    scene:end_drag()
    check("releasing drag restores anchor state", scene.drag_index == -1 and scene.particles[0].anchored == 1)

    scene = Scene.new()
    local cut_index = scene:cut_nearest(9.15, 3)
    check("cut removes the closest cloth link", cut_index >= 0 and scene.constraints[cut_index].active == 0)
    scene = Scene.new()
    scene.iterations = 10
    local output = render_frame(scene)
    check("ASCII snapshot renders cloth and controls", output:find("VERLET CLOTH + ROPE", 1, true) ~= nil and output:find("Drag: pull nodes", 1, true) ~= nil and output:find("O", 1, true) ~= nil)
    print("ALL VERLET CLOTH TESTS PASSED")
end

local function print_help()
    print([[Verlet Cloth & Rope — LuaJIT FFI

Usage: luajit ffi_verlet_cloth.lua [--help|--test|--snapshot] [--ascii]

Controls: Drag to pull nodes; right-click or X toggles cut mode; Space pauses;
          R resets; +/- changes solver passes; Q quits.

Run --snapshot --ascii for a headless static preview.]])
end

local function run_interactive(use_color)
    local winsize = ffi.new("struct VerletWinsize")
    if ffi.C.ioctl(0, 0x5413, winsize) == 0 and (winsize.cols < WIDTH + 3 or winsize.rows < 23) then
        error(string.format("terminal needs at least %d columns by 23 rows", WIDTH + 3))
    end
    local original = ffi.new("struct VerletTermios")
    assert(ffi.C.tcgetattr(0, original) == 0, "interactive mode requires a POSIX terminal")
    local raw = ffi.new("struct VerletTermios")
    ffi.copy(raw, original, ffi.sizeof("struct VerletTermios"))
    raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
    raw.c_cc[5], raw.c_cc[6] = 0, 0
    assert(ffi.C.tcsetattr(0, 0, raw) == 0, "could not enable raw terminal mode")

    local pollfd = ffi.new("struct VerletPollfd[1]")
    pollfd[0].fd, pollfd[0].events = 0, 1
    local input = ffi.new("char[256]")
    local running, interrupted, cutting = true, false, false
    local scene = Scene.new()
    local function restore()
        ffi.C.tcsetattr(0, 0, original)
        io.write("\27[?1006l\27[?1002l\27[?1000l\27[?7h\27[?25h\27[0m\27[?1049l")
        io.flush()
    end
    local function on_signal() interrupted = true end
    local callback = ffi.cast("verlet_sighandler_t", on_signal)
    signal_callbacks[#signal_callbacks + 1] = callback
    local previous_sigint = ffi.C.signal(2, callback)
    local previous_sigterm = ffi.C.signal(15, callback)
    local function now()
        local ts = ffi.new("struct VerletTimespec")
        ffi.C.clock_gettime(1, ts)
        return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
    end
    local function handle_key(key)
        if key == "q" or key == "\3" then running = false
        elseif key == " " then scene.paused = not scene.paused
        elseif key == "r" then scene:reset()
        elseif key == "+" or key == "=" then scene.iterations = math.min(20, scene.iterations + 1)
        elseif key == "-" then scene.iterations = math.max(1, scene.iterations - 1)
        elseif key == "x" or key == "X" then cutting = not cutting end
    end
    local function handle_input(data)
        local i = 1
        while i <= #data do
            local b, x, y, action = data:match(CSI_ESC .. "%[<(%d+);(%d+);(%d+)([Mm])", i)
            if b then
                b, x, y = tonumber(b), tonumber(x) - 2, tonumber(y) - 3
                local down = action == "M" and (b == 0 or b == 2 or b == 32 or b == 34)
                if x >= 0 and x < WIDTH and y >= 0 and y < HEIGHT then
                    if down and (b == 2 or cutting) then
                        scene:cut_nearest(x, y)
                    elseif b == 0 and action == "M" then
                        if cutting then scene:cut_nearest(x, y) else scene:begin_drag(x, y) end
                    elseif down and mouse_down and scene.drag_index >= 0 then
                        scene:move_drag(x, y)
                    end
                end
                if action == "m" or (b == 3 and action == "M") then scene:end_drag() end
                local _, finish = data:find(CSI_ESC .. "%[<%d+;%d+;%d+[Mm]", i)
                i = (finish or i) + 1
            elseif data:sub(i, i + 1) == CSI_ESC .. "[" then
                -- Ignore terminal navigation/function key CSI sequences.
                i = math.min(#data + 1, i + 3)
            elseif data:byte(i) == 27 and i == #data then
                handle_key("q")
                i = i + 1
            else
                handle_key(data:sub(i, i))
                i = i + 1
            end
        end
    end

    io.write("\27[?1049h\27[?25l\27[?7l\27[?1000h\27[?1002h\27[?1006h\27[H")
    io.flush()
    local ok, err = pcall(function()
        local last, accumulator = now(), 0
        while running and not interrupted do
            pollfd[0].revents = 0
            local ready = ffi.C.poll(pollfd, 1, 8)
            if ready > 0 and bit.band(pollfd[0].revents, 1) ~= 0 then
                local n = ffi.C.read(0, input, 255)
                if n > 0 then handle_input(ffi.string(input, n)) end
            end
            local time = now()
            accumulator = math.min(accumulator + time - last, 0.05)
            last = time
            while accumulator >= 1 / 60 do scene:step(1 / 60); accumulator = accumulator - 1 / 60 end
            io.write("\27[?2026h\27[H" .. render_frame(scene, use_color) .. "\27[?2026l")
            io.flush()
        end
    end)
    restore()
    ffi.C.signal(2, previous_sigint)
    ffi.C.signal(15, previous_sigterm)
    if not ok then error(err) end
    print("\nVerlet cloth session ended.")
end

local function main(args)
    local snapshot, ascii = false, false
    local i = 1
    while i <= #args do
        local option = args[i]
        if option == "--help" or option == "-h" then print_help(); return 0
        elseif option == "--test" then run_self_tests(); return 0
        elseif option == "--snapshot" then snapshot = true
        elseif option == "--ascii" then ascii = true
        else io.stderr:write("Unknown option: " .. tostring(option) .. "\n"); print_help(); return 2 end
        i = i + 1
    end
    if snapshot then print(render_frame(Scene.new(), not ascii)); return 0 end
    run_interactive(not ascii)
    return 0
end

local M = { Scene = Scene, render_frame = render_frame, WIDTH = WIDTH, HEIGHT = HEIGHT }
if ... == "ffi_verlet_cloth" then return M end
os.exit(main(arg or {}))
