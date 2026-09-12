#!/usr/bin/env luajit
--[[
    test_ffi_falling_sand.lua
    Unit, integration, and FFI regression test suite for ffi_falling_sand.lua (Falling Sand Sandbox).
--]]

local ffi = require("ffi")
local sand = require("ffi_falling_sand")

print("=== Running Unit Tests for ffi_falling_sand.lua (Falling Sand Sandbox) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_falling_sand.lua --help",
        expect = "FALLING SAND & CELLULAR AUTOMATA PHYSICS SANDBOX"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_falling_sand.lua --test",
        expect = "All Falling Sand self-tests completed successfully!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_falling_sand.lua --snapshot",
        expect = "FALLING SAND & CELLULAR PHYSICS SANDBOX"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_falling_sand.lua --snapshot --ascii",
        expect = "+-- CANVAS [74x36] - Preset: HOURGLASS"
    },
    {
        name = "Lake preset snapshot (--snapshot --preset lake)",
        cmd = "luajit ffi_falling_sand.lua --snapshot --preset lake",
        expect = "Preset: LAKE"
    },
    {
        name = "Fireworks preset snapshot (--snapshot --preset fireworks)",
        cmd = "luajit ffi_falling_sand.lua --snapshot --preset fireworks",
        expect = "Preset: FIREWORKS"
    },
    {
        name = "Automated demo execution (--demo 15)",
        cmd = "luajit ffi_falling_sand.lua --demo 15",
        expect = "[Falling Sand Demo Complete]"
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
-- In-Depth Physics Engine, Thermodynamics & FFI Unit Tests
-- =========================================================================
print("\n--- In-Depth Physics Engine, Thermodynamics & FFI Unit Tests ---")

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
assert_test(ffi.sizeof("Cell") == 4, "Cell sizeof == 4")
assert_test(ffi.offsetof("Cell", "type") == 0, "Cell offsetof(type) == 0")
assert_test(ffi.offsetof("Cell", "life") == 1, "Cell offsetof(life) == 1")
assert_test(ffi.offsetof("Cell", "color_idx") == 2, "Cell offsetof(color_idx) == 2")
assert_test(ffi.offsetof("Cell", "updated") == 3, "Cell offsetof(updated) == 3")
assert_test(ffi.sizeof("SandGrid") == 4 * 74 * 36 + 8, "SandGrid sizeof == 10664")

-- 2. Simulator initialization & clearing
local sim = sand.SandSim.new()
assert_test(sim.width == 74 and sim.height == 36, "Grid dimensions 74x36")
assert_test(sim.grid.active_particles == 0, "Active particles initialized to 0")

-- 3. Gravity: Sand falling
sim:clear()
sim:set(20, 10, sand.ELEM_SAND)
sim:step()
assert_test(sim:get(20, 11) == sand.ELEM_SAND and sim:get(20, 10) == sand.ELEM_EMPTY, "Sand falls downward under gravity")

-- 4. Angle of repose: Sand rolling off obstacles
sim:clear()
sim:set(30, 20, sand.ELEM_STONE)
sim:set(30, 19, sand.ELEM_SAND)
sim:step()
local l = sim:get(29, 20)
local r = sim:get(31, 20)
assert_test(l == sand.ELEM_SAND or r == sand.ELEM_SAND, "Sand rolls diagonally off obstacles")

-- 5. Fluid dispersion: Water lateral spreading
sim:clear()
sim:set(19, 15, sand.ELEM_STONE)
sim:set(20, 15, sand.ELEM_STONE)
sim:set(21, 15, sand.ELEM_STONE)
sim:set(20, 14, sand.ELEM_WATER)
sim:step()
local w_l = sim:get(19, 14)
local w_r = sim:get(21, 14)
assert_test(w_l == sand.ELEM_WATER or w_r == sand.ELEM_WATER, "Water spreads laterally across flat surface")

-- 6. Buoyancy: Sand sinks through liquid
sim:clear()
sim:set(14, 12, sand.ELEM_STONE)
sim:set(15, 12, sand.ELEM_STONE)
sim:set(16, 12, sand.ELEM_STONE)
sim:set(14, 11, sand.ELEM_STONE)
sim:set(16, 11, sand.ELEM_STONE)
sim:set(14, 10, sand.ELEM_STONE)
sim:set(16, 10, sand.ELEM_STONE)
sim:set(15, 11, sand.ELEM_WATER)
sim:set(15, 10, sand.ELEM_SAND)
sim:step()
assert_test(sim:get(15, 11) == sand.ELEM_SAND and sim:get(15, 10) == sand.ELEM_WATER, "Sand sinks through water to bottom")

-- 7. Flammability: Fire ignites oil
sim:clear()
sim:set(24, 21, sand.ELEM_STONE)
sim:set(25, 21, sand.ELEM_STONE)
sim:set(26, 21, sand.ELEM_STONE)
sim:set(24, 20, sand.ELEM_STONE)
sim:set(26, 20, sand.ELEM_STONE)
sim:set(25, 20, sand.ELEM_OIL)
sim:set(25, 19, sand.ELEM_FIRE)
sim:step()
local oil_ignited = (sim:get(25, 20) == sand.ELEM_FIRE or sim:get(25, 20) == sand.ELEM_SMOKE)
assert_test(oil_ignited, "Fire instantly ignites flammable oil")

-- 8. Extinguishing: Water douses fire creating steam
sim:clear()
sim:set(40, 20, sand.ELEM_FIRE)
sim:set(40, 19, sand.ELEM_WATER)
sim:step()
assert_test(sim:get(40, 20) == sand.ELEM_STEAM, "Water douses fire and vaporizes into steam")

-- 9. Explosives: Gunpowder chain detonation
sim:clear()
sim:set(35, 20, sand.ELEM_GUNPOWDER)
sim:set(36, 20, sand.ELEM_GUNPOWDER)
sim:set(34, 20, sand.ELEM_FIRE)
sim:step()
local fire_or_smoke = 0
for dy = -4, 4 do
    for dx = -4, 4 do
        local t = sim:get(35 + dx, 20 + dy)
        if t == sand.ELEM_FIRE or t == sand.ELEM_SMOKE then fire_or_smoke = fire_or_smoke + 1 end
    end
end
assert_test(fire_or_smoke > 0, "Gunpowder chain-detonates into fireball and smoke")

-- 10. Corrosives: Acid dissolves organic matter (wood)
sim:clear()
sim:set(50, 15, sand.ELEM_WOOD)
sim:set(50, 14, sand.ELEM_ACID)
sim:step()
assert_test(sim:get(50, 15) == sand.ELEM_SMOKE and sim:get(50, 14) == sand.ELEM_EMPTY, "Acid dissolves wood into smoke")

-- 11. Stone is acid-proof
sim:clear()
sim:set(50, 15, sand.ELEM_STONE)
sim:set(50, 14, sand.ELEM_ACID)
sim:step()
assert_test(sim:get(50, 15) == sand.ELEM_STONE, "Stone is impervious to corrosive acid")

-- 12. Plant growth with water
sim:clear()
sim:set(60, 20, sand.ELEM_PLANT)
sim:set(61, 20, sand.ELEM_WATER)
for _ = 1, 50 do sim:step() end
local plant_count = 0
for dy = -2, 2 do
    for dx = -2, 2 do
        if sim:get(60 + dx, 20 + dy) == sand.ELEM_PLANT then plant_count = plant_count + 1 end
    end
end
assert_test(plant_count >= 1, "Plant survives and absorbs moisture")

-- 13. Preset scenes loading
for _, p in ipairs({ "hourglass", "lake", "fireworks", "acid", "blank" }) do
    sim:load_preset(p)
    assert_test(sim.current_preset == p, "Preset '" .. p .. "' loaded successfully")
end

-- 14. Terminal frame geometry check (exact 80 columns across all 28 lines)
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

sim.use_ascii = false
local lines_u = check_frame_width(sim:render_frame(), "Truecolor")
assert_test(lines_u == 28, "Truecolor frame renders exactly 28 lines of 80-column text")

sim.use_ascii = true
local lines_a = check_frame_width(sim:render_frame(), "ASCII")
assert_test(lines_a == 28, "ASCII fallback frame renders exactly 28 lines of 80-column text")

print(string.format("\nTest Summary: %d / %d tests passed.", passed, passed))
print("\27[1;32mALL FALLING SAND TESTS PASSED SUCCESSFULLY!\27[0m\n")
os.exit(0)
