--[[
    ffi_nebula_generator.lua
    A procedural cosmic nebula generator written in LuaJIT FFI.
    
    Demonstrates:
    1. Zero-allocation C pixel buffers (ffi.new("PixelRGB[?]", W * H)).
    2. Multi-octave Fractional Brownian Motion (fBm) with Domain Warping (simulating fluid gas dynamics).
    3. Volumetric emission and dark dust absorption physics.
    4. Starfield generation with optical diffraction spikes and bloom.
    5. Direct binary PPM export + Terminal true-color preview.
--]]

local ffi = require("ffi")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;

    typedef struct { long tv_sec; long tv_nsec; } ffi_timespec;
    int clock_gettime(int clk_id, ffi_timespec *tp);
]]

local function get_time_ms()
    local ts = ffi.new("ffi_timespec")
    ffi.C.clock_gettime(1, ts)
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

-- =========================================================================
-- 1. High-Performance Procedural Noise (Permutation-based 2D Gradient Noise)
-- =========================================================================
local P = ffi.new("int[512]")
local GRAD2 = ffi.new("double[8][2]", {
    {1, 0}, {-1, 0}, {0, 1}, {0, -1},
    {0.7071, 0.7071}, {-0.7071, 0.7071}, {0.7071, -0.7071}, {-0.7071, -0.7071}
})

-- Seed random permutation
local function init_noise(seed)
    math.randomseed(seed or 1337)
    local p256 = {}
    for i = 0, 255 do p256[i] = i end
    for i = 255, 1, -1 do
        local j = math.random(0, i)
        p256[i], p256[j] = p256[j], p256[i]
    end
    for i = 0, 511 do
        P[i] = p256[bit.band(i, 255)]
    end
end
init_noise(42)

local function quintic(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function grad_noise(x, y)
    local xi = bit.band(math.floor(x), 255)
    local yi = bit.band(math.floor(y), 255)
    local xf = x - math.floor(x)
    local yf = y - math.floor(y)

    local u = quintic(xf)
    local v = quintic(yf)

    local aa = bit.band(P[P[xi] + yi], 7)
    local ab = bit.band(P[P[xi] + yi + 1], 7)
    local ba = bit.band(P[P[xi + 1] + yi], 7)
    local bb = bit.band(P[P[xi + 1] + yi + 1], 7)

    local g_aa = GRAD2[aa][0] * xf + GRAD2[aa][1] * yf
    local g_ba = GRAD2[ba][0] * (xf - 1) + GRAD2[ba][1] * yf
    local g_ab = GRAD2[ab][0] * xf + GRAD2[ab][1] * (yf - 1)
    local g_bb = GRAD2[bb][0] * (xf - 1) + GRAD2[bb][1] * (yf - 1)

    local x1 = g_aa + u * (g_ba - g_aa)
    local x2 = g_ab + u * (g_bb - g_ab)
    return (x1 + v * (x2 - x1)) * 0.7071 -- normalize roughly to [-1, 1]
end

local function fbm(x, y, octaves, persistence, lacunarity)
    persistence = persistence or 0.5
    lacunarity = lacunarity or 2.0
    local total = 0
    local frequency = 1.0
    local amplitude = 1.0
    local max_val = 0

    for _ = 1, octaves do
        total = total + grad_noise(x * frequency, y * frequency) * amplitude
        max_val = max_val + amplitude
        frequency = frequency * lacunarity
        amplitude = amplitude * persistence
    end
    return total / max_val
end

-- =========================================================================
-- 2. Domain Warping (Simulating cosmic turbulence & fluid tendrils)
-- =========================================================================
local function domain_warp_nebula(nx, ny)
    -- Multi-stage recursive warping
    local qx = fbm(nx, ny, 4, 0.5, 2.0)
    local qy = fbm(nx + 5.2, ny + 1.3, 4, 0.5, 2.0)

    local rx = fbm(nx + 4.0 * qx + 1.7, ny + 4.0 * qy + 9.2, 4, 0.5, 2.0)
    local ry = fbm(nx + 4.0 * qx + 8.3, ny + 4.0 * qy + 2.8, 4, 0.5, 2.0)

    -- Primary gas density
    local density = fbm(nx + 4.0 * rx, ny + 4.0 * ry, 6, 0.55, 2.1)
    density = (density + 0.8) * 0.55
    density = math.max(0.0, math.min(1.0, density))

    -- Secondary fine filament detail
    local detail = fbm(nx * 2.5 + rx, ny * 2.5 + ry, 4, 0.5, 2.2)
    detail = math.max(0.0, (detail + 0.7) * 0.6)

    return density, detail, qx, qy, rx, ry
end

-- =========================================================================
-- 3. Nebula Color Transfer Function & Lighting (Orion M42 Astrophysics)
-- =========================================================================
local function clamp(val, low, high)
    if val < low then return low end
    if val > high then return high end
    return val
end

local function sample_nebula(x, y, w, h)
    local aspect = w / h
    local u = (x / w - 0.5) * 2.0 * aspect
    local v = (y / h - 0.5) * 2.0

    -- Asymmetric Orion cloud envelope:
    -- M42 has two grand sweeping "wings" spreading horizontally, with a concave bay at the top
    local wing_u = u * 0.9
    local wing_v = v + 0.25 * (wing_u * wing_u) -- parabolic sweep of the wings
    local r_cloud = math.sqrt(wing_u * wing_u * 0.7 + wing_v * wing_v * 1.5)
    
    -- Cloud envelope with soft, feathering edge
    local envelope = math.exp(- (r_cloud * r_cloud) / 0.55)
    if envelope < 0.002 then
        -- Deep space cosmic background
        return 0.003, 0.002, 0.008
    end

    -- Sample warped gas turbulence
    local scale = 1.6
    local density, detail, qx, qy, rx, ry = domain_warp_nebula(u * scale + 5.0, v * scale + 5.0)

    -- The iconic "Fish's Mouth" dark dust bay:
    -- A thick, dark interstellar absorption dust lane cutting diagonally into the core from above
    local dust_u = u * 0.85 + v * 0.75 - 0.06
    local dust_v = -u * 0.75 + v * 0.85 + 0.22
    local dust_shape = math.exp(-(dust_u * dust_u * 8.0 + dust_v * dust_v * 3.5))
    -- Heavy fractal turbulence on dust boundaries
    local dust_turb = fbm(u * 4.0 + rx * 2.5, v * 4.0 + ry * 2.5, 4, 0.55, 2.2)
    local dust_mask = clamp(dust_shape * (0.65 + 0.65 * dust_turb) * 1.8, 0.0, 0.96)

    -- Finer dark dust filaments across outer wings
    local fine_dust = fbm(u * 5.5 + 1.2, v * 5.5 + 3.4, 3)
    if fine_dust > 0.35 then
        dust_mask = clamp(dust_mask + (fine_dust - 0.35) * 0.4 * envelope, 0.0, 0.96)
    end

    -- Core position (Trapezium cluster stellar nursery)
    local core_du = u - 0.02
    local core_dv = v + 0.08
    local core_dist = math.sqrt(core_du * core_du + core_dv * core_dv * 1.3)

    -- Core emission profile: intense central star cluster + localized ambient ionization glow
    local core_sharp = math.exp(-core_dist * 22.0) * 4.0
    local core_ambient = math.exp(-core_dist * 6.0) * 1.5

    -- Gas illumination modulated by dust absorption
    local trans = 1.0 - dust_mask

    -- Color Synthesis based on Hubble Space Telescope false-color / emission astrophotography:
    -- 1. Deep Space Void (pitch-black cosmic void with subtle navy tint)
    local r = 0.002
    local g = 0.002
    local b = 0.008

    -- 2. Outer Reflection & Low-density Fringes (Deep Indigo / Violet Wisps)
    local outer_gas = envelope * (density ^ 2.2) * trans
    r = r + outer_gas * 0.20
    g = g + outer_gas * 0.03
    b = b + outer_gas * 0.85

    -- Inner cavity vs outer shell:
    -- In the core cavity, high radiation ionizes Oxygen into brilliant electric cyan [O III].
    -- In the outer cloud, Hydrogen-alpha crimson dominates.
    local inner_zone = math.exp(-(core_dist * core_dist) / 0.22)
    local outer_zone = clamp(1.0 - inner_zone * 1.1, 0.0, 1.0)

    -- 3. Hydrogen-Alpha Emission (H-α: 656 nm - Deep Crimson / Vivid Magenta)
    local h_alpha = clamp((density - 0.15) * 2.0, 0.0, 1.0) ^ 1.3 * envelope * trans * outer_zone
    r = r + h_alpha * 1.30
    g = g + h_alpha * 0.04
    b = b + h_alpha * 0.45

    -- 4. Doubly Ionized Oxygen ([O III]: 500 nm - Brilliant Electric Cyan / Turquoise)
    local o_iii = clamp((density + 0.10) * 1.5, 0.0, 1.0) * inner_zone * envelope * trans
    r = r + o_iii * 0.05
    g = g + o_iii * 0.95
    b = b + o_iii * 1.15

    -- 5. Warm Golden-Amber Backlit Dust Edge
    local dust_rim = clamp(dust_mask * (1.0 - dust_mask) * 4.5 * (density + 0.2) * envelope, 0.0, 1.0)
    r = r + dust_rim * 0.70
    g = g + dust_rim * 0.38
    b = b + dust_rim * 0.05

    -- 6. Trapezium Core Cluster Luminous Cavity
    r = r + core_ambient * 0.15 * trans + core_sharp * 1.5
    g = g + core_ambient * 0.60 * trans + core_sharp * 1.5
    b = b + core_ambient * 0.95 * trans + core_sharp * 1.8

    return r, g, b
end

-- =========================================================================
-- 4. Starfield & Diffraction Spikes
-- =========================================================================
local function hash21(px, py)
    local n = math.sin(px * 127.1 + py * 311.7) * 43758.5453123
    return n - math.floor(n)
end

local function add_stars(r, g, b, x, y, w, h)
    -- Background micro-stars
    local cell_size = 16
    local cx = math.floor(x / cell_size)
    local cy = math.floor(y / cell_size)
    local h1 = hash21(cx, cy)

    if h1 > 0.80 then
        local sx = (cx + hash21(cx + 1.1, cy + 2.3)) * cell_size
        local sy = (cy + hash21(cx + 3.7, cy + 4.1)) * cell_size
        local dx = x - sx
        local dy = y - sy
        local dist2 = dx * dx + dy * dy
        local star_bright = (h1 - 0.80) / 0.20
        
        local star_lum = math.exp(-dist2 * 0.75) * star_bright * 1.4
        local star_temp = hash21(cx + 5.0, cy + 7.0)
        local sr = 1.0 + (star_temp - 0.5) * 0.45
        local sg = 1.0
        local sb = 1.0 - (star_temp - 0.5) * 0.45

        r = r + star_lum * sr
        g = g + star_lum * sg
        b = b + star_lum * sb
    end

    -- Trapezium Cluster + Hero Field Stars
    local core_px = w * (0.5 + 0.02 / (2.0 * (w / h)))
    local core_py = h * (0.5 - 0.08 / 2.0)

    local hero_stars = {
        -- Authentic Trapezium Asterism (Theta-1 Orionis A, B, C, D in the core)
        { x = core_px - 5, y = core_py - 4, brightness = 3.8, size = 2.0, sr = 0.85, sg = 0.95, sb = 1.3, spikes = true },
        { x = core_px + 7, y = core_py - 2, brightness = 2.4, size = 1.7, sr = 0.90, sg = 0.95, sb = 1.2, spikes = false },
        { x = core_px - 4, y = core_py + 6, brightness = 2.0, size = 1.5, sr = 0.90, sg = 0.95, sb = 1.2, spikes = false },
        { x = core_px + 6, y = core_py + 7, brightness = 1.8, size = 1.4, sr = 0.95, sg = 0.95, sb = 1.1, spikes = false },
        -- Prominent foreground field stars
        { x = w * 0.20, y = h * 0.26, brightness = 3.2, size = 2.8, sr = 1.25, sg = 0.85, sb = 0.65, spikes = true }, -- warm orange star
        { x = w * 0.78, y = h * 0.70, brightness = 3.0, size = 2.6, sr = 0.80, sg = 0.95, sb = 1.30, spikes = true }, -- luminous blue star
        { x = w * 0.84, y = h * 0.20, brightness = 2.4, size = 2.2, sr = 1.00, sg = 1.00, sb = 1.00, spikes = true },
        { x = w * 0.35, y = h * 0.78, brightness = 2.2, size = 2.0, sr = 0.90, sg = 0.90, sb = 1.15, spikes = false },
    }

    for _, s in ipairs(hero_stars) do
        local dx = x - s.x
        local dy = y - s.y
        local d = math.sqrt(dx * dx + dy * dy)

        local glare = math.exp(- (d * d) / (s.size * s.size)) * s.brightness
        local halo = math.exp(- d / (s.size * 4.5)) * (s.brightness * 0.22)
        
        local star_total = glare + halo

        if s.spikes then
            local spike_x = math.exp(-math.abs(dy) * 0.85) * math.exp(-math.abs(dx) * 0.035)
            local spike_y = math.exp(-math.abs(dx) * 0.85) * math.exp(-math.abs(dy) * 0.035)
            star_total = star_total + (spike_x + spike_y) * (s.brightness * 0.40)
        end

        r = r + star_total * s.sr
        g = g + star_total * s.sg
        b = b + star_total * s.sb
    end

    return r, g, b
end

-- =========================================================================
-- 5. Render Canvas & Save
-- =========================================================================
local function render_nebula(w, h)
    local num_pixels = w * h
    local buffer = ffi.new("PixelRGB[?]", num_pixels)

    local t0 = get_time_ms()

    -- ACES-like filmic tone mapping to handle dynamic range gracefully
    local function tonemap(c)
        local a = 2.51
        local b_const = 0.03
        local c_const = 2.43
        local d = 0.59
        local e = 0.14
        return clamp((c * (a * c + b_const)) / (c * (c_const * c + d) + e), 0.0, 1.0)
    end

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local r, g, b = sample_nebula(x, y, w, h)
            r, g, b = add_stars(r, g, b, x, y, w, h)

            -- Tone map and gamma correct (sRGB gamma ~ 2.2)
            r = tonemap(r) ^ (1.0 / 2.2)
            g = tonemap(g) ^ (1.0 / 2.2)
            b = tonemap(b) ^ (1.0 / 2.2)

            local idx = y * w + x
            buffer[idx].r = math.floor(r * 255 + 0.5)
            buffer[idx].g = math.floor(g * 255 + 0.5)
            buffer[idx].b = math.floor(b * 255 + 0.5)
        end
    end

    local elapsed = get_time_ms() - t0
    return buffer, elapsed
end

-- Export to standard binary Netpbm PPM (P6 format)
local function save_ppm(filename, buffer, w, h)
    local f = io.open(filename, "wb")
    if not f then error("Cannot open " .. filename .. " for writing") end
    f:write(string.format("P6\n%d %d\n255\n", w, h))
    f:write(ffi.string(buffer, w * h * 3))
    f:close()
end

-- Render to Terminal using 24-bit Truecolor ANSI Half-Blocks (▄)
local function print_terminal(buffer, w, h, term_w, term_h)
    local out = {}
    local function emit(str) table.insert(out, str) end

    -- 2 vertical image pixels per character cell
    local step_x = w / term_w
    local step_y = h / (term_h * 2)

    for ty = 0, term_h - 1 do
        local y_top = math.floor(ty * 2 * step_y)
        local y_bot = math.min(h - 1, math.floor((ty * 2 + 1) * step_y))

        for tx = 0, term_w - 1 do
            local x = math.min(w - 1, math.floor(tx * step_x))

            local top_p = buffer[y_top * w + x]
            local bot_p = buffer[y_bot * w + x]

            -- \27[48;2;R;G;Bm (background = top) \27[38;2;R;G;Bm (foreground = bottom) ▄
            emit(string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                top_p.r, top_p.g, top_p.b,
                bot_p.r, bot_p.g, bot_p.b
            ))
        end
        emit("\27[0m\n")
    end
    io.write(table.concat(out))
end

-- =========================================================================
-- Main Execution
-- =========================================================================
local WIDTH = 800
local HEIGHT = 600
print(string.format("Generating Orion Nebula (Messier 42) [%dx%d] via LuaJIT FFI...", WIDTH, HEIGHT))

local buffer, ms = render_nebula(WIDTH, HEIGHT)
print(string.format("[+] Render completed in %.2f ms (%.1f Mpixels/sec)", ms, (WIDTH * HEIGHT / 1e6) / (ms / 1000)))

local ppm_file = "nebula_orion.ppm"
save_ppm(ppm_file, buffer, WIDTH, HEIGHT)
print(string.format("[+] Saved high-resolution image to '%s'", ppm_file))

-- Terminal Preview
local term_w = 90
local term_h = 32
print(string.format("\n--- Cosmic Preview (%dx%d characters) ---", term_w, term_h))
print_terminal(buffer, WIDTH, HEIGHT, term_w, term_h)

return {
    render = render_nebula,
    save_ppm = save_ppm,
    print_terminal = print_terminal
}
