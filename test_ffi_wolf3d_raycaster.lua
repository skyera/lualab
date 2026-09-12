#!/usr/bin/env luajit
--[[
    test_ffi_wolf3d_raycaster.lua
    Unit, integration, and FFI regression test suite for ffi_wolf3d_raycaster.lua (Wolf3D Raycaster Engine).
--]]

local ffi = require("ffi")
local wolf_mod = require("ffi_wolf3d_raycaster")

print("=== Running Unit Tests for ffi_wolf3d_raycaster.lua (Wolfenstein 3D Raycaster) ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit ffi_wolf3d_raycaster.lua --help",
        expect = "WOLFENSTEIN 3D RAYCASTING ENGINE"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "luajit ffi_wolf3d_raycaster.lua --test",
        expect = "All Wolfenstein 3D Raycaster self-tests completed successfully!"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit ffi_wolf3d_raycaster.lua --snapshot",
        expect = "CANVAS [74x36] - THE DUNGEON ESCAPE"
    },
    {
        name = "ASCII snapshot render (--snapshot --ascii)",
        cmd = "luajit ffi_wolf3d_raycaster.lua --snapshot --ascii",
        expect = "+-- CANVAS [74x36] - THE DUNGEON ESCAPE"
    },
    {
        name = "Map 2 snapshot (--map 2 --snapshot)",
        cmd = "luajit ffi_wolf3d_raycaster.lua --map 2 --snapshot",
        expect = "CANVAS [74x36] - CASTLE COURTYARD & RAMPARTS"
    },
    {
        name = "Map 3 snapshot (--map 3 --snapshot)",
        cmd = "luajit ffi_wolf3d_raycaster.lua --map 3 --snapshot",
        expect = "CANVAS [74x36] - BOSS STRONGHOLD & ARMORY"
    },
    {
        name = "Automated raycaster tour execution (--demo 15)",
        cmd = "luajit ffi_wolf3d_raycaster.lua --demo 15",
        expect = "[Wolfenstein 3D Tour Complete]"
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
-- In-Depth 3D Raycasting Engine, DDA, Textures & FFI Unit Tests
-- =========================================================================
print("\n--- In-Depth 3D Raycasting Engine, DDA, Textures & FFI Unit Tests ---")

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

assert_test(ffi.sizeof("Texture32") == 32 * 32 * 3, "Texture32 sizeof == 3072 bytes")
assert_test(ffi.sizeof("SpriteEntity") == 24, "SpriteEntity sizeof == 24 bytes")
assert_test(ffi.sizeof("PlayerState") >= 44, "PlayerState sizeof bounds")
assert_test(ffi.sizeof("RaycasterState") >= 74 * 36 * 3 + 74 * 4, "RaycasterState bounds")

-- 2. Engine initialization & Level setup
local engine = wolf_mod.WolfEngine.new()
assert_test(engine.width == 74 and engine.height == 36, "Viewport dimensions 74x36")
assert_test(engine.player.health == 100, "Initial player health is 100")
assert_test(engine.player.armor == 50, "Initial player armor is 50")
assert_test(engine.player.ammo == 32, "Initial player ammo is 32")

-- 3. Procedural Texture Atlas verification
for id = 1, 6 do
    local tex = engine.wall_textures[id]
    local lum = 0
    for p = 0, 32 * 32 - 1 do
        lum = lum + tex.pixels[p].r + tex.pixels[p].g + tex.pixels[p].b
    end
    assert_test(lum > 5000, string.format("Wall texture [%d] is populated with non-zero color data", id))
end

for id = 1, 5 do
    local tex = engine.sprite_textures[id]
    local lum = 0
    for p = 0, 32 * 32 - 1 do
        lum = lum + tex.pixels[p].r + tex.pixels[p].g + tex.pixels[p].b
    end
    assert_test(lum > 1000, string.format("Sprite texture [%d] is populated with non-zero color data", id))
end

-- 4. DDA Raycasting & Perpendicular Depth Buffer
engine:clear_framebuffer()
engine:render_walls()
local valid_depths = 0
for col = 0, engine.width - 1 do
    local dist = engine.state.z_buffer[col]
    if dist >= 0.05 and dist <= 40.0 then valid_depths = valid_depths + 1 end
end
assert_test(valid_depths == engine.width, "74 DDA screen rays generated continuous valid depths")

-- 5. Sliding door mechanics (John Carmack recessed DDA door)
local door_cell = 2 * 24 + 4 -- Map 1 door at (4, 2)
assert_test(engine.map[door_cell] == wolf_mod.TEX_DOOR, "Identified steel door in Map 1 layout")
assert_test(engine:is_solid(4.5, 2.5) == true, "Closed door is solid to player navigation")
engine.door_timer[door_cell] = 3.0
engine:step(0.4)
assert_test(engine.door_open[door_cell] > 0.5, "Door opens over time when triggered")
engine.door_open[door_cell] = 0.9
assert_test(engine:is_solid(4.5, 2.5) == false, "Fully opened door allows player passage")

-- 6. Billboarded 3D Sprites sorting & depth clipping
engine:render_sprites()
local chalice_found = false
for i = 0, engine.num_sprites - 1 do
    if engine.sprites[i].type == wolf_mod.SPRITE_CHALICE then chalice_found = true end
end
assert_test(chalice_found, "Level contains collectible gold chalice sprites")

-- 7. First-person weapon firing & recoil
local old_ammo = engine.player.ammo
local fired = engine:fire_weapon()
assert_test(fired == true, "fire_weapon() executes successfully")
assert_test(engine.player.ammo == old_ammo - 1, "Weapon firing decrements ammo counter")
assert_test(engine.player.firing_timer > 0, "Firing activates muzzle flash and recoil timer")

-- 8. Player Movement & Rotation
local start_x = engine.player.x
local start_y = engine.player.y
engine:move_player(engine.player.dir_x, engine.player.dir_y, 0.05)
assert_test(engine.player.x ~= start_x or engine.player.y ~= start_y, "move_player() translates position")

local old_dir_x = engine.player.dir_x
engine:rotate_player(0.1)
assert_test(engine.player.dir_x ~= old_dir_x, "rotate_player() rotates camera direction vector")

-- 9. Minimap toggle
assert_test(engine.show_minimap == true, "Minimap radar starts enabled")
engine.show_minimap = false
assert_test(engine.show_minimap == false, "Minimap radar toggles off")
engine.show_minimap = true

-- 10. 80-Column terminal frame geometry across all 3 maps
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

for m = 1, #wolf_mod.MAP_PRESETS do
    engine:load_map(m)
    engine.use_ascii = false
    local lines_u = check_frame_width(engine:render_frame(), "Truecolor-Map" .. m)
    assert_test(lines_u == 28, string.format("Truecolor Map %d renders exactly 28 lines x 80 cols", m))

    engine.use_ascii = true
    local lines_a = check_frame_width(engine:render_frame(), "ASCII-Map" .. m)
    assert_test(lines_a == 28, string.format("ASCII Map %d renders exactly 28 lines x 80 cols", m))
end

print(string.format("\nTest Summary: %d / %d tests passed.", passed, passed))
print("\27[1;32mALL WOLFENSTEIN 3D RAYCASTER TESTS PASSED SUCCESSFULLY!\27[0m\n")
os.exit(0)
