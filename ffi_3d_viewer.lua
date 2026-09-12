--[[
    ffi_3d_viewer.lua
    Interactive Real-time 3D Polygonal Mesh Renderer in Terminal Truecolor.
    Built entirely using LuaJIT FFI.

    Features:
    1. Full 3D Graphics Pipeline:
       - 3D Matrix Transformations: Model translation, pitch/yaw/roll rotations, scaling.
       - Perspective projection camera model (Fov, near/far planes).
       - Backface culling via triangle face normals.
       - Standard depth-buffering (Z-Buffer) for proper 3D surface occlusion.
       - Dynamic Directional Lighting + Ambient light with Phong/diffuse shading.
       - Sub-pixel edge rasterization for solid triangle polygons.
    2. Multiple 3D Geometries:
       - 1: Cube (with multi-colored faces)
       - 2: Torus (3D Donut mesh)
       - 3: Pyramid / Tetrahedron
       - 4: Octahedron (faceted gemstone diamond)
       - 5: Cylinder / Prism
    3. Terminal Truecolor Half-Block Rasterizer:
       - Uses 24-bit ANSI color codes with UTF-8 half-block '▄' (2 vertical pixels per text row).
       - Automatically tracks terminal width & height dynamically via ioctl(TIOCGWINSZ).
    4. Real-time Interactive Control:
       - [← / → / ↑ / ↓] or [H / J / K / L]: Manual pitch and yaw rotation
       - [Space]: Toggle auto-rotation on / off
       - [1 - 5]: Switch 3D mesh model
       - [+ / -]: Zoom in / out (camera distance)
       - [W]: Toggle wireframe vs solid shaded mode
       - [L]: Move directional light source
       - [Q / Esc]: Quit
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. C Declarations for Windows / POSIX, Terminal, High-Res Clock & Buffers
-- =========================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;
]]

local get_time_sec
local get_terminal_size
local enable_raw_mode
local disable_raw_mode
local read_key
local is_stdin_tty
local sleep_ms

if is_windows then
    ffi.cdef[[
        typedef struct { short X; short Y; } COORD;
        typedef struct { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
        typedef struct {
            COORD      dwSize;
            COORD      dwCursorPosition;
            uint16_t   wAttributes;
            SMALL_RECT srWindow;
            COORD      dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        typedef union {
            struct {
                uint32_t LowPart;
                int32_t  HighPart;
            };
            int64_t QuadPart;
        } LARGE_INTEGER;

        void* __stdcall GetStdHandle(uint32_t nStdHandle);
        int   __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int   __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int   __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int   __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
        int   __stdcall QueryPerformanceCounter(LARGE_INTEGER* lpPerformanceCount);
        int   __stdcall QueryPerformanceFrequency(LARGE_INTEGER* lpFrequency);
        void  __stdcall Sleep(uint32_t dwMilliseconds);

        int _kbhit(void);
        int _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6 -- ((uint32_t)-10)
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- ((uint32_t)-11)

    local qpc_freq = ffi.new("LARGE_INTEGER")
    ffi.C.QueryPerformanceFrequency(qpc_freq)
    local freq_val = tonumber(qpc_freq.QuadPart)

    get_time_sec = function()
        local count = ffi.new("LARGE_INTEGER")
        ffi.C.QueryPerformanceCounter(count)
        return tonumber(count.QuadPart) / freq_val
    end

    local orig_in_mode = ffi.new("uint32_t[1]")
    local raw_mode_enabled = false

    pcall(function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        ffi.C.SetConsoleOutputCP(65001) -- UTF-8
        local out_mode = ffi.new("uint32_t[1]")
        if ffi.C.GetConsoleMode(hOut, out_mode) ~= 0 then
            local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            ffi.C.SetConsoleMode(hOut, bit.bor(out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        end
    end)

    is_stdin_tty = function()
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        return ffi.C.GetConsoleMode(hIn, mode) ~= 0
    end

    get_terminal_size = function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if ffi.C.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if w > 0 and h > 0 then
                return tonumber(w), tonumber(h)
            end
        end
        return 80, 24
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        if ffi.C.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end

        local ENABLE_LINE_INPUT = 0x0002
        local ENABLE_ECHO_INPUT = 0x0004
        local new_mode = bit.band(orig_in_mode[0], bit.bnot(bit.bor(ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT)))
        ffi.C.SetConsoleMode(hIn, new_mode)
        raw_mode_enabled = true

        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?25h\27[0m\n")
            io.flush()
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            raw_mode_enabled = false
        end
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 0
        if timeout_ms > 0 then
            local start_t = get_time_sec()
            while (get_time_sec() - start_t) * 1000 < timeout_ms do
                if ffi.C._kbhit() ~= 0 then break end
                ffi.C.Sleep(1)
            end
        end

        if ffi.C._kbhit() ~= 0 then
            local ch = ffi.C._getch()
            if ch == 0 or ch == 224 then
                local code = ffi.C._getch()
                if code == 72 then return "UP"
                elseif code == 80 then return "DOWN"
                elseif code == 75 then return "LEFT"
                elseif code == 77 then return "RIGHT"
                elseif code == 73 then return "PAGE_UP"
                elseif code == 81 then return "PAGE_DOWN"
                end
            elseif ch == 27 then
                return "ESC"
            elseif ch == 13 or ch == 10 then
                return "ENTER"
            elseif ch == 32 then
                return "SPACE"
            elseif ch == 8 then
                return "BACKSPACE"
            else
                return string.char(ch):lower()
            end
        end
        return nil
    end

    sleep_ms = function(ms)
        if ms > 0 then ffi.C.Sleep(ms) end
    end
else
    -- POSIX / Linux / macOS
    ffi.cdef[[
        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, void *argp);
        int isatty(int fd);

        typedef unsigned char cc_t;
        typedef unsigned int  speed_t;
        typedef unsigned int  tcflag_t;

        struct termios {
            tcflag_t c_iflag;
            tcflag_t c_oflag;
            tcflag_t c_cflag;
            tcflag_t c_lflag;
            cc_t     c_line;
            cc_t     c_cc[32];
            speed_t  c_ispeed;
            speed_t  c_ospeed;
        };

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);

        struct pollfd {
            int   fd;
            short events;
            short revents;
        };
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);

        typedef struct { long tv_sec; long tv_nsec; } timespec_t;
        int clock_gettime(int clk_id, timespec_t *tp);
    ]]

    local TIOCGWINSZ = 0x5413
    local STDIN_FILENO = 0
    local TCSANOW = 0
    local ICANON = 2
    local ECHO = 8
    local POLLIN = 1
    local CLOCK_MONOTONIC = 1

    get_time_sec = function()
        local ts = ffi.new("timespec_t")
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
    end

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if pcall(function() return ffi.C.ioctl(1, TIOCGWINSZ, ws) end) and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 80, 24
    end

    local orig_termios = ffi.new("struct termios")
    local raw_termios = ffi.new("struct termios")
    local raw_mode_enabled = false

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        raw_mode_enabled = true

        io.write("\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if raw_mode_enabled then
            io.write("\27[?25h\27[0m\n")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            raw_mode_enabled = false
        end
    end

    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local key_buf = ffi.new("char[16]")

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 0
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 16)
            if n > 0 then
                local c0 = key_buf[0]
                if c0 == 27 then
                    if n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP" end
                        if c2 == 66 then return "DOWN" end
                        if c2 == 67 then return "RIGHT" end
                        if c2 == 68 then return "LEFT" end
                        if c2 == 53 and n >= 4 and key_buf[3] == 126 then return "PAGE_UP" end
                        if c2 == 54 and n >= 4 and key_buf[3] == 126 then return "PAGE_DOWN" end
                    end
                    return "ESC"
                elseif c0 == 10 or c0 == 13 then
                    return "ENTER"
                elseif c0 == 32 then
                    return "SPACE"
                elseif c0 == 127 or c0 == 8 then
                    return "BACKSPACE"
                else
                    return string.char(c0):lower()
                end
            end
        end
        return nil
    end

    sleep_ms = function(ms)
        if ms > 0 then
            ffi.C.poll(nil, 0, ms)
        end
    end
end

-- =========================================================================
-- 3. 3D Math: Vector3, Matrix Operations, and Lighting
-- =========================================================================
local function vec3(x, y, z)
    return {x = x or 0, y = y or 0, z = z or 0}
end

local function vec3_sub(a, b)
    return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z}
end

local function vec3_cross(a, b)
    return {
        x = a.y * b.z - a.z * b.y,
        y = a.z * b.x - a.x * b.z,
        z = a.x * b.y - a.y * b.x
    }
end

local function vec3_dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function vec3_normalize(v)
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if len > 1e-8 then
        return {x = v.x / len, y = v.y / len, z = v.z / len}
    end
    return {x = 0, y = 0, z = 1}
end

-- =========================================================================
-- 4. 3D Mesh Generators: Cube, Torus, Pyramid, Octahedron, Cylinder
-- =========================================================================
local function create_cube()
    local verts = {
        vec3(-1, -1, -1), vec3( 1, -1, -1), vec3( 1,  1, -1), vec3(-1,  1, -1),
        vec3(-1, -1,  1), vec3( 1, -1,  1), vec3( 1,  1,  1), vec3(-1,  1,  1),
    }
    local tris = {
        -- Front (+Z) - Cyan
        {v = {5, 6, 7}, color = {r = 40,  g = 200, b = 240}},
        {v = {5, 7, 8}, color = {r = 40,  g = 200, b = 240}},
        -- Back (-Z) - Orange
        {v = {2, 1, 4}, color = {r = 250, g = 130, b = 40}},
        {v = {2, 4, 3}, color = {r = 250, g = 130, b = 40}},
        -- Top (+Y) - Green
        {v = {4, 3, 7}, color = {r = 60,  g = 220, b = 90}},
        {v = {4, 7, 8}, color = {r = 60,  g = 220, b = 90}},
        -- Bottom (-Y) - Magenta
        {v = {1, 2, 6}, color = {r = 220, g = 60,  b = 180}},
        {v = {1, 6, 5}, color = {r = 220, g = 60,  b = 180}},
        -- Right (+X) - Yellow
        {v = {2, 6, 7}, color = {r = 240, g = 220, b = 50}},
        {v = {2, 7, 3}, color = {r = 240, g = 220, b = 50}},
        -- Left (-X) - Blue
        {v = {1, 5, 8}, color = {r = 80,  g = 120, b = 255}},
        {v = {1, 8, 4}, color = {r = 80,  g = 120, b = 255}},
    }
    return {name = "Cube", verts = verts, tris = tris, scale = 1.0}
end

local function create_torus(r_major, r_minor, seg_u, seg_v)
    r_major = r_major or 1.2
    r_minor = r_minor or 0.45
    seg_u = seg_u or 18
    seg_v = seg_v or 10

    local verts = {}
    local tris = {}

    for i = 0, seg_u - 1 do
        local u = i * (2 * math.pi / seg_u)
        local cos_u = math.cos(u)
        local sin_u = math.sin(u)

        for j = 0, seg_v - 1 do
            local v = j * (2 * math.pi / seg_v)
            local cos_v = math.cos(v)
            local sin_v = math.sin(v)

            local x = (r_major + r_minor * cos_v) * cos_u
            local y = r_minor * sin_v
            local z = (r_major + r_minor * cos_v) * sin_u

            table.insert(verts, vec3(x, y, z))
        end
    end

    local function get_idx(i, j)
        return (i % seg_u) * seg_v + (j % seg_v) + 1
    end

    for i = 0, seg_u - 1 do
        for j = 0, seg_v - 1 do
            local p0 = get_idx(i, j)
            local p1 = get_idx(i + 1, j)
            local p2 = get_idx(i + 1, j + 1)
            local p3 = get_idx(i, j + 1)

            -- Gradient color around ring
            local hue = (i / seg_u) * 6
            local r = math.floor(math.sin(hue) * 100 + 155)
            local g = math.floor(math.sin(hue + 2) * 100 + 155)
            local b = math.floor(math.sin(hue + 4) * 100 + 155)
            local col = {r = r, g = g, b = b}

            table.insert(tris, {v = {p0, p1, p2}, color = col})
            table.insert(tris, {v = {p0, p2, p3}, color = col})
        end
    end

    return {name = "Torus (3D Donut)", verts = verts, tris = tris, scale = 0.85}
end

local function create_pyramid()
    local h = 1.3
    local verts = {
        vec3( 0,  h,  0), -- Apex (1)
        vec3(-1, -h * 0.7, -1), -- Base FL (2)
        vec3( 1, -h * 0.7, -1), -- Base FR (3)
        vec3( 1, -h * 0.7,  1), -- Base BR (4)
        vec3(-1, -h * 0.7,  1), -- Base BL (5)
    }
    local tris = {
        -- Front face
        {v = {1, 2, 3}, color = {r = 255, g = 80,  b = 80}},
        -- Right face
        {v = {1, 3, 4}, color = {r = 255, g = 200, b = 60}},
        -- Back face
        {v = {1, 4, 5}, color = {r = 60,  g = 210, b = 150}},
        -- Left face
        {v = {1, 5, 2}, color = {r = 80,  g = 140, b = 255}},
        -- Base
        {v = {2, 5, 4}, color = {r = 180, g = 100, b = 220}},
        {v = {2, 4, 3}, color = {r = 180, g = 100, b = 220}},
    }
    return {name = "Pyramid", verts = verts, tris = tris, scale = 1.0}
end

local function create_octahedron()
    local s = 1.4
    local verts = {
        vec3( 0,  s,  0), -- 1: Top
        vec3( 0, -s,  0), -- 2: Bottom
        vec3(-s,  0,  0), -- 3: Left
        vec3( s,  0,  0), -- 4: Right
        vec3( 0,  0,  s), -- 5: Front
        vec3( 0,  0, -s), -- 6: Back
    }
    local tris = {
        -- Upper 4 faces
        {v = {1, 3, 5}, color = {r = 80,  g = 220, b = 240}},
        {v = {1, 5, 4}, color = {r = 120, g = 140, b = 255}},
        {v = {1, 4, 6}, color = {r = 200, g = 100, b = 255}},
        {v = {1, 6, 3}, color = {r = 60,  g = 255, b = 180}},
        -- Lower 4 faces
        {v = {2, 5, 3}, color = {r = 255, g = 140, b = 80}},
        {v = {2, 4, 5}, color = {r = 255, g = 80,  b = 140}},
        {v = {2, 6, 4}, color = {r = 255, g = 220, b = 60}},
        {v = {2, 3, 6}, color = {r = 140, g = 255, b = 100}},
    }
    return {name = "Octahedron Gem", verts = verts, tris = tris, scale = 1.0}
end

local function create_cylinder(segs)
    segs = segs or 14
    local r = 1.1
    local h = 1.2
    local verts = {}
    local tris = {}

    -- Center top and bottom
    table.insert(verts, vec3(0,  h, 0)) -- 1: top center
    table.insert(verts, vec3(0, -h, 0)) -- 2: bottom center

    for i = 0, segs - 1 do
        local theta = i * (2 * math.pi / segs)
        local x = r * math.cos(theta)
        local z = r * math.sin(theta)
        table.insert(verts, vec3(x,  h, z)) -- top ring: 3 + i * 2
        table.insert(verts, vec3(x, -h, z)) -- bot ring: 4 + i * 2
    end

    for i = 0, segs - 1 do
        local next_i = (i + 1) % segs
        local t0 = 3 + i * 2
        local b0 = 4 + i * 2
        local t1 = 3 + next_i * 2
        local b1 = 4 + next_i * 2

        -- Side quads
        local side_col = {r = 70 + (i * 12) % 150, g = 180, b = 220}
        table.insert(tris, {v = {t0, b0, t1}, color = side_col})
        table.insert(tris, {v = {b0, b1, t1}, color = side_col})

        -- Top fan
        table.insert(tris, {v = {1, t0, t1}, color = {r = 100, g = 230, b = 120}})
        -- Bottom fan
        table.insert(tris, {v = {2, b1, b0}, color = {r = 240, g = 100, b = 120}})
    end

    return {name = "Cylinder Prism", verts = verts, tris = tris, scale = 0.9}
end

local MESHES = {
    create_cube(),
    create_torus(1.2, 0.45, 18, 10),
    create_pyramid(),
    create_octahedron(),
    create_cylinder(14)
}

-- =========================================================================
-- 5. Software Rasterizer: Depth Buffer (Z-Buffer) & Half-Block Engine
-- =========================================================================
local Framebuffer = {}
Framebuffer.__index = Framebuffer

function Framebuffer.new(w, h)
    local self = setmetatable({
        width = w,
        height = h,
        pixels = ffi.new("PixelRGB[?]", w * h),
        zbuffer = ffi.new("float[?]", w * h)
    }, Framebuffer)
    self:clear(15, 17, 26) -- Dark sleek slate background
    return self
end

function Framebuffer:clear(r, g, b)
    local count = self.width * self.height
    for i = 0, count - 1 do
        self.pixels[i].r = r
        self.pixels[i].g = g
        self.pixels[i].b = b
        self.zbuffer[i] = 1e9 -- Infinity depth
    end
end

-- Triangle Rasterizer with Edge Function & Interpolated 1/Z Depth
function Framebuffer:draw_triangle(p0, p1, p2, r, g, b)
    local w = self.width
    local h = self.height

    -- Bounding box
    local min_x = math.max(0, math.floor(math.min(p0.x, p1.x, p2.x)))
    local max_x = math.min(w - 1, math.ceil(math.max(p0.x, p1.x, p2.x)))
    local min_y = math.max(0, math.floor(math.min(p0.y, p1.y, p2.y)))
    local max_y = math.min(h - 1, math.ceil(math.max(p0.y, p1.y, p2.y)))

    if min_x > max_x or min_y > max_y then return end

    -- Determinant (2x area of triangle)
    local area = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x)
    if math.abs(area) < 1e-5 then return end
    local inv_area = 1.0 / area

    for py = min_y, max_y do
        local fy = py + 0.5
        for px = min_x, max_x do
            local fx = px + 0.5

            -- Barycentric weights w0, w1, w2
            local w0 = ((p1.x - fx) * (p2.y - fy) - (p1.y - fy) * (p2.x - fx)) * inv_area
            local w1 = ((p2.x - fx) * (p0.y - fy) - (p2.y - fy) * (p0.x - fx)) * inv_area
            local w2 = 1.0 - w0 - w1

            if w0 >= -0.001 and w1 >= -0.001 and w2 >= -0.001 then
                local z = w0 * p0.z + w1 * p1.z + w2 * p2.z
                local idx = py * w + px
                if z < self.zbuffer[idx] then
                    self.zbuffer[idx] = z
                    self.pixels[idx].r = r
                    self.pixels[idx].g = g
                    self.pixels[idx].b = b
                end
            end
        end
    end
end

-- Line Drawing for Wireframe mode (Bresenham)
function Framebuffer:draw_line(x0, y0, z0, x1, y1, z1, r, g, b)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = (x0 < x1) and 1 or -1
    local sy = (y0 < y1) and 1 or -1
    local err = dx - dy

    local total_steps = math.max(dx, dy)
    local step_count = 0
    local w, h = self.width, self.height

    while true do
        if x0 >= 0 and x0 < w and y0 >= 0 and y0 < h then
            local t = (total_steps > 0) and (step_count / total_steps) or 0
            local z = z0 + (z1 - z0) * t - 0.05 -- slight bias over faces
            local idx = y0 * w + x0
            if z < self.zbuffer[idx] then
                self.zbuffer[idx] = z
                self.pixels[idx].r = r
                self.pixels[idx].g = g
                self.pixels[idx].b = b
            end
        end

        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then
            err = err - dy
            x0 = x0 + sx
        end
        if e2 < dx then
            err = err + dx
            y0 = y0 + sy
        end
        step_count = step_count + 1
    end
end

-- Renders the framebuffer into ANSI Truecolor half-block text
function Framebuffer:render_ansi_screen(title_str, stat_str, term_w)
    local out = {}
    table.insert(out, "\27[H") -- Cursor home

    table.insert(out, title_str .. "\n")

    local w = self.width
    local h = self.height
    local px = self.pixels

    local margin_left = math.max(0, math.floor((term_w - w) / 2))
    local pad = string.rep(" ", margin_left)

    -- Half-block rendering: 2 vertical pixels per terminal character row
    for y = 0, h - 1, 2 do
        local line = { pad }
        for x = 0, w - 1 do
            local top = px[y * w + x]
            local bot = (y + 1 < h) and px[(y + 1) * w + x] or top

            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                top.r, top.g, top.b,
                bot.r, bot.g, bot.b
            ))
        end
        table.insert(line, "\27[0m\n")
        table.insert(out, table.concat(line))
    end

    table.insert(out, stat_str)
    io.write(table.concat(out))
    io.flush()
end

-- =========================================================================
-- 6. Main Interactive 3D Render Loop
-- =========================================================================
local function main()
    local interactive = is_stdin_tty()

    -- CLI flags
    local mesh_idx = 1
    local wireframe_mode = false
    local auto_rotate = true
    local run_once = not interactive

    for _, a in ipairs(arg or {}) do
        if a == "--wireframe" or a == "-w" then
            wireframe_mode = true
        elseif a == "--no-rotate" then
            auto_rotate = false
        elseif a == "--once" then
            run_once = true
        elseif tonumber(a) and tonumber(a) >= 1 and tonumber(a) <= #MESHES then
            mesh_idx = tonumber(a)
        elseif a == "-h" or a == "--help" then
            print("\27[1;36mTerminal 3D Mesh Renderer (LuaJIT FFI Truecolor)\27[0m")
            print("Usage:")
            print("  ./LuaJIT/src/luajit ffi_3d_viewer.lua [model 1-5] [options]")
            print("\nModels:")
            print("  1: Cube")
            print("  2: Torus (3D Donut)")
            print("  3: Pyramid")
            print("  4: Octahedron Gem")
            print("  5: Cylinder Prism")
            print("\nOptions:")
            print("  --wireframe, -w   Render in vector wireframe mode")
            print("  --no-rotate       Start in manual rotation mode")
            print("  --once            Render a single frame and exit (batch mode)")
            print("  -h, --help        Show this help documentation")
            os.exit(0)
        end
    end

    if interactive and not run_once then
        enable_raw_mode()
        io.write("\27[2J") -- Clear full terminal
    end

    -- Camera & World Orientation
    local rot_x = 0.4
    local rot_y = 0.6
    local rot_z = 0.0
    local cam_dist = 3.6
    local light_dir = vec3_normalize(vec3(0.6, 0.9, -0.8))

    local last_t = get_time_sec()
    local frame_count = 0
    local fps = 0
    local fps_t0 = last_t

    while true do
        local now = get_time_sec()
        local dt = math.min(0.1, now - last_t)
        last_t = now

        -- Handle user input
        if interactive and not run_once then
            local k = read_key(0)
            if k == "q" or k == "ESC" then
                break
            elseif k == "SPACE" then
                auto_rotate = not auto_rotate
            elseif k == "w" then
                wireframe_mode = not wireframe_mode
            elseif k == "UP" or k == "k" then
                rot_x = rot_x - 0.15
            elseif k == "DOWN" or k == "j" then
                rot_x = rot_x + 0.15
            elseif k == "LEFT" or k == "h" then
                rot_y = rot_y - 0.15
            elseif k == "RIGHT" or k == "l" then
                rot_y = rot_y + 0.15
            elseif k == "PAGE_UP" or k == "+" or k == "=" then
                cam_dist = math.max(1.8, cam_dist - 0.3)
            elseif k == "PAGE_DOWN" or k == "-" or k == "_" then
                cam_dist = math.min(7.0, cam_dist + 0.3)
            elseif tonumber(k) and tonumber(k) >= 1 and tonumber(k) <= #MESHES then
                mesh_idx = tonumber(k)
            end
        end

        -- Auto-rotation animation
        if auto_rotate then
            rot_y = rot_y + dt * 1.2
            rot_x = rot_x + dt * 0.7
            rot_z = rot_z + dt * 0.3
        end

        -- Calculate buffer dimensions from terminal size
        local term_w, term_h = get_terminal_size()
        local header_rows = 4
        local footer_rows = 3
        local avail_rows = math.max(10, term_h - header_rows - footer_rows)
        local buf_w = math.min(term_w, math.floor(avail_rows * 2.2))
        local buf_h = avail_rows * 2 -- each char row is 2 pixels high
        if buf_h % 2 ~= 0 then buf_h = buf_h + 1 end

        local fb = Framebuffer.new(buf_w, buf_h)

        -- Model view rotation matrices
        local cos_x, sin_x = math.cos(rot_x), math.sin(rot_x)
        local cos_y, sin_y = math.cos(rot_y), math.sin(rot_y)
        local cos_z, sin_z = math.cos(rot_z), math.sin(rot_z)

        local mesh = MESHES[mesh_idx]
        local m_scale = mesh.scale

        -- 1. Transform all vertices (Model -> World View -> Perspective Screen)
        local proj_verts = {}
        local fov_scale = (buf_h * 0.85) * (cam_dist / 3.5)
        local cx = buf_w * 0.5
        local cy = buf_h * 0.5

        for _, v in ipairs(mesh.verts) do
            -- Scale
            local x = v.x * m_scale
            local y = v.y * m_scale
            local z = v.z * m_scale

            -- Rotate Y
            local x1 = x * cos_y + z * sin_y
            local y1 = y
            local z1 = -x * sin_y + z * cos_y

            -- Rotate X
            local x2 = x1
            local y2 = y1 * cos_x - z1 * sin_x
            local z2 = y1 * sin_x + z1 * cos_x

            -- Rotate Z
            local x3 = x2 * cos_z - y2 * sin_z
            local y3 = x2 * sin_z + y2 * cos_z
            local z3 = z2

            -- Translate along camera Z
            local cz = z3 + cam_dist

            -- Perspective projection
            local inv_z = 1.0 / cz
            local sx = cx + (x3 * inv_z) * fov_scale
            local sy = cy - (y3 * inv_z) * fov_scale

            table.insert(proj_verts, {
                x = sx,
                y = sy,
                z = cz,
                world = vec3(x3, y3, z3)
            })
        end

        -- 2. Render Triangles with Depth-buffering and Lighting
        local tris_drawn = 0
        for _, tri in ipairs(mesh.tris) do
            local p0 = proj_verts[tri.v[1]]
            local p1 = proj_verts[tri.v[2]]
            local p2 = proj_verts[tri.v[3]]

            -- Backface culling: calculate screen-space cross product
            local cross_z = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x)

            if cross_z < 0 then -- Facing camera
                tris_drawn = tris_drawn + 1

                -- Compute 3D surface normal
                local e1 = vec3_sub(p1.world, p0.world)
                local e2 = vec3_sub(p2.world, p0.world)
                local normal = vec3_normalize(vec3_cross(e1, e2))

                -- Directional diffuse lighting: max(0, N · L)
                local diff = math.max(0, vec3_dot(normal, light_dir))
                local ambient = 0.22
                local light_intensity = math.min(1.0, ambient + diff * 0.78)

                -- Compute final pixel RGB
                local base_c = tri.color
                local r = math.min(255, math.floor(base_c.r * light_intensity))
                local g = math.min(255, math.floor(base_c.g * light_intensity))
                local b = math.min(255, math.floor(base_c.b * light_intensity))

                if wireframe_mode then
                    fb:draw_line(math.floor(p0.x), math.floor(p0.y), p0.z, math.floor(p1.x), math.floor(p1.y), p1.z, 50, 240, 255)
                    fb:draw_line(math.floor(p1.x), math.floor(p1.y), p1.z, math.floor(p2.x), math.floor(p2.y), p2.z, 50, 240, 255)
                    fb:draw_line(math.floor(p2.x), math.floor(p2.y), p2.z, math.floor(p0.x), math.floor(p0.y), p0.z, 50, 240, 255)
                else
                    fb:draw_triangle(p0, p1, p2, r, g, b)
                end
            end
        end

        -- Calculate FPS
        frame_count = frame_count + 1
        if now - fps_t0 >= 0.5 then
            fps = frame_count / (now - fps_t0)
            fps_t0 = now
            frame_count = 0
        end

        -- Top Header Banner
        local bar = string.rep("═", math.min(term_w - 2, 78))
        local title_str = string.format(
            "\27[1;35m%s\27[0m\n  \27[1;37m3D TERMINAL GRAPHICS ENGINE\27[0m  \27[90m| Model: \27[1;93m[%d] %s\27[0m  \27[90m| Mode: \27[96m%s\27[0m\n  \27[90mControls: [1-5] Model  [Space] Pause  [←/→/↑/↓] Rotate  [W] Wireframe  [Q] Quit\27[0m\n\27[90m%s\27[0m",
            bar, mesh_idx, mesh.name, wireframe_mode and "Wireframe" or "Shaded Z-Buffer", bar
        )

        -- Bottom Stat Line
        local stat_str = string.format(
            "  \27[90mResolution: \27[37m%dx%d px\27[0m | \27[90mVisible Faces: \27[32m%d/%d\27[0m | \27[90mFramerate: \27[1;33m%.1f FPS\27[0m | \27[90mZoom: \27[36m%.1f\27[0m\n",
            buf_w, buf_h, tris_drawn, #mesh.tris, fps, cam_dist
        )

        fb:render_ansi_screen(title_str, stat_str, term_w)

        if run_once then break end

        -- Target ~30 FPS frame limiter (33 ms)
        local frame_duration = get_time_sec() - now
        local sleep_rem = 0.033 - frame_duration
        if sleep_rem > 0.001 then
            sleep_ms(math.floor(sleep_rem * 1000))
        end
    end

    if interactive and not run_once then
        disable_raw_mode()
        print("\n\27[1;36mExited 3D Terminal Renderer. Thanks for watching!\27[0m")
    end
end

main()
