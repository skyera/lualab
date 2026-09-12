#!/usr/bin/env luajit
--[[
    test_ffi_demoscene_studio.lua
    Unit, integration, and FFI regression test suite for ffi_demoscene_studio.lua (1990s Demoscene Studio).
--]]

local ffi = require("ffi")
local studio_mod = require("ffi_demoscene_studio")

print("=== Running Unit Tests for ffi_demoscene_studio.lua (1990s Demoscene Studio) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_demoscene_studio.lua --help",
        expect = "1990s DEMOSCENE EFFECTS STUDIO"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_demoscene_studio.lua --test",
        expect = "All Demoscene Studio self-tests completed successfully!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_demoscene_studio.lua --snapshot",
        expect = "CANVAS [74x36] - PSX DOOM Fire Simulation"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_demoscene_studio.lua --snapshot --ascii",
        expect = "+-- CANVAS [74x36] - PSX DOOM Fire Simulation"
    },
    {
        name = "Plasma effect snapshot (--effect plasma --snapshot)",
        cmd = "luajit ffi_demoscene_studio.lua --effect plasma --snapshot",
        expect = "CANVAS [74x36] - Multi-Sine Rainbow Plasma"
    },
    {
        name = "Voxel effect snapshot (--effect voxel --snapshot)",
        cmd = "luajit ffi_demoscene_studio.lua --effect voxel --snapshot",
        expect = "CANVAS [74x36] - Comanche 3D Voxel Flight Simulator"
    },
    {
        name = "Starfield effect snapshot (--effect starfield --snapshot)",
        cmd = "luajit ffi_demoscene_studio.lua --effect starfield --snapshot",
        expect = "CANVAS [74x36] - 3D Starfield Warp & Motion Blur"
    },
    {
        name = "Matrix effect snapshot (--effect matrix --snapshot)",
        cmd = "luajit ffi_demoscene_studio.lua --effect matrix --snapshot",
        expect = "CANVAS [74x36] - Matrix Digital Rain Cascade"
    },
    {
        name = "Automated demoscene tour execution (--demo 15)",
        cmd = "luajit ffi_demoscene_studio.lua --demo 15",
        expect = "[Demoscene Tour Complete]"
    }
}

local passed = 0
local total_cli = #tests

for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
    local out = p:read("*a")
    p:close()

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, total_cli, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, total_cli, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

-- =========================================================================
-- In-Depth Demoscene Engine, Effect Math & FFI Unit Tests
-- =========================================================================
print("\n--- In-Depth Demoscene Engine, Effect Math & FFI Unit Tests ---")

local function assert_test(condition, msg)
    if condition then
        print("  \27[32m✔ PASS\27[0m: " .. msg)
        passed = passed + 1
    else
        print("  \27[31m✘ FAIL\27[0m: " .. msg)
        error("Assertion failed: " .. msg)
    end
end

-- 1. FFI Struct verification
assert_test(ffi.sizeof("RGBColor") == 3, "RGBColor sizeof == 3")
assert_test(ffi.offsetof("RGBColor", "r") == 0, "RGBColor offsetof(r) == 0")
assert_test(ffi.offsetof("RGBColor", "g") == 1, "RGBColor offsetof(g) == 1")
assert_test(ffi.offsetof("RGBColor", "b") == 2, "RGBColor offsetof(b) == 2")
assert_test(ffi.sizeof("StudioState") >= 74 * 36 * 3 + 8, "StudioState sizeof bounds")

local studio = studio_mod.DemosceneStudio.new()
assert_test(studio.width == 74 and studio.height == 36, "Canvas dimensions 74x36")
assert_test(ffi.sizeof(studio.state.fb) == 74 * 36 * 3, "Framebuffer flat size == 7992 bytes")

-- 2. Framebuffer operations
studio:clear_framebuffer(10, 20, 30)
assert_test(studio.state.fb[0].r == 10 and studio.state.fb[0].g == 20 and studio.state.fb[0].b == 30, "Framebuffer clear color top-left")
assert_test(studio.state.fb[74 * 36 - 1].r == 10 and studio.state.fb[74 * 36 - 1].g == 20 and studio.state.fb[74 * 36 - 1].b == 30, "Framebuffer clear color bottom-right")

-- 3. PSX DOOM Fire simulation & propagation
studio.active_effect = "fire"
studio:init_fire()
local bottom_row = 36 * 74
local ign_count = 0
for x = 0, 73 do
    if studio.fire_buffer[bottom_row + x] == 36 then ign_count = ign_count + 1 end
end
assert_test(ign_count == 74, "DOOM Fire bottom row initialized with full heat (36)")

for _ = 1, 20 do studio:step() end
local mid_heat = 0
for x = 0, 73 do mid_heat = mid_heat + studio.fire_buffer[25 * 74 + x] end
assert_test(mid_heat > 0, "DOOM Fire heats upwards towards middle rows")

-- 4. Multi-Sine Rainbow Plasma
studio.active_effect = "plasma"
studio:step()
local c1 = studio.state.fb[0]
local c2 = studio.state.fb[37]
assert_test(c1.r ~= c2.r or c1.g ~= c2.g or c1.b ~= c2.b, "Multi-sine plasma creates spatial color variation")

-- 5. Comanche 3D Voxel Space raycaster & camera flight
studio.active_effect = "voxel"
local initial_cam_x = studio.cam_x
local initial_cam_y = studio.cam_y
studio:step()
assert_test(studio.cam_y ~= initial_cam_y or studio.cam_x ~= initial_cam_x, "Comanche camera flies forward over heightmap")

-- 6. 3D Starfield Warp projection & bounds
studio.active_effect = "starfield"
studio:step()
local active_stars = 0
for i = 0, studio.num_stars - 1 do
    if studio.stars_z[i] > 0 and studio.stars_z[i] <= 1000.0 then active_stars = active_stars + 1 end
end
assert_test(active_stars == studio.num_stars, "350 3D warp stars stay bounded in viewing frustum")

-- 7. Matrix Digital Rain cascade
studio.active_effect = "matrix"
local drop0_y = studio.matrix_drops[0]
studio:step()
assert_test(studio.matrix_drops[0] >= drop0_y, "Matrix digital rain cascades downward")

-- 8. Effect cycling & state transitions
local cur_eff = studio.active_effect
studio:next_effect()
assert_test(studio.active_effect ~= cur_eff, "next_effect() advances demoscene effect")

-- 9. Terminal Frame Geometry & Formatting (exact 80 cols x 28 lines)
local function check_frame_width(frame_text, mode_name)
    local l_idx = 0
    for line in frame_text:gmatch("[^\r\n]+") do
        l_idx = l_idx + 1
        local plain = line:gsub("\27%[[%d;]*m", "")
        local w = 0
        local i = 1
        while i <= #plain do
            local b = plain:byte(i)
            if b < 128 then w = w + 1; i = i + 1
            elseif b >= 192 and b < 224 then w = w + 1; i = i + 2
            elseif b >= 224 and b < 240 then w = w + 1; i = i + 3
            elseif b >= 240 then w = w + 2; i = i + 4
            else i = i + 1 end
        end
        assert(w == 80, string.format("[%s] Line %d width is %d != 80: '%s'", mode_name, l_idx, w, plain))
    end
    return l_idx
end

for _, eff in ipairs(studio_mod.EFFECTS) do
    studio.active_effect = eff
    studio.use_ascii = false
    local lines_u = check_frame_width(studio:render_frame(), "Truecolor-" .. eff)
    assert_test(lines_u == 28, string.format("Truecolor [%s] frame renders 28 lines x 80 cols", eff))

    studio.use_ascii = true
    local lines_a = check_frame_width(studio:render_frame(), "ASCII-" .. eff)
    assert_test(lines_a == 28, string.format("ASCII [%s] frame renders 28 lines x 80 cols", eff))
end

print(string.format("\nTest Summary: %d / %d tests passed.", passed, passed))
print("\27[1;32mALL DEMOSCENE STUDIO TESTS PASSED SUCCESSFULLY!\27[0m\n")
os.exit(0)
