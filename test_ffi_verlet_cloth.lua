#!/usr/bin/env luajit
-- Tests for Verlet cloth/rope physics and headless CLI modes.

local verlet = require("ffi_verlet_cloth")
local ffi = require("ffi")
local passed, total = 0, 0

local function check(name, condition)
    total = total + 1
    if condition then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        io.stderr:write("  FAIL: " .. name .. "\n")
    end
end

local function run_cli(command)
    local pipe = assert(io.popen(command .. " 2>&1; printf '\\n__EXIT__%d' $?", "r"))
    local output = pipe:read("*a")
    pipe:close()
    local code = tonumber(output:match("__EXIT__(%d+)$"))
    output = output:gsub("\\n__EXIT__%d+$", "")
    return output, code == 0, code
end

print("=== Verlet cloth and rope tests ===")
local scene = verlet.Scene.new()
check("uses FFI-backed particle and constraint arrays", ffi.istype("VerletParticle[?]", scene.particles) and ffi.istype("VerletConstraint[?]", scene.constraints))
check("builds a cloth sheet and rope", scene.particle_count == 91 and scene.constraint_count > 250)
check("pins cloth edge and rope endpoint", scene.particles[0].anchored == 1 and scene.particles[80].anchored == 1)

local gravity_particle = scene.particles[10]
local initial_y = gravity_particle.y
scene.constraint_count = 0
scene:step(1 / 60)
check("gravity moves free particles downward", gravity_particle.y > initial_y)

scene = verlet.Scene.new()
scene.particle_count, scene.constraint_count = 0, 0
local first_index = scene:add_particle(10, 5, true)
local second_index = scene:add_particle(15, 5, false)
local structural_index = scene:add_constraint(first_index, second_index, 1)
local first, second = scene.particles[first_index], scene.particles[second_index]
second.x = second.x + 3
scene:step(1 / 60)
local dx, dy = second.x - first.x, second.y - first.y
check("distance solver restores stretched constraint", math.abs(math.sqrt(dx * dx + dy * dy) - scene.constraints[structural_index].rest_length) < 0.01)
check("constraint solve preserves pinned coordinates", first.x == 10 and first.y == 5)

scene = verlet.Scene.new()
check("drag selects a nearby particle", scene:begin_drag(7, 3) == 0)
scene:move_drag(12, 5)
check("drag sets position and previous position", scene.particles[0].x == 12 and scene.particles[0].old_x == 12)
scene:end_drag()
check("release retains original pinned state", scene.drag_index == -1 and scene.particles[0].anchored == 1)

scene = verlet.Scene.new()
local cut = scene:cut_nearest(9.15, 3)
check("link cutting deactivates nearest constraint", cut >= 0 and scene.constraints[cut].active == 0)
scene.paused = true
local y_before = scene.particles[10].y
scene:step(1 / 60)
check("pause freezes simulation", scene.particles[10].y == y_before)
local snapshot = verlet.render_frame(scene)
check("snapshot contains cloth, rope, and controls", snapshot:find("VERLET CLOTH + ROPE", 1, true) ~= nil and snapshot:find("Drag: pull nodes", 1, true) ~= nil and snapshot:find(".", 1, true) ~= nil)

local help, help_ok = run_cli("luajit ffi_verlet_cloth.lua --help")
check("--help prints usage", help_ok and help:find("Usage:", 1, true) ~= nil)
local test_output, test_ok = run_cli("luajit ffi_verlet_cloth.lua --test")
check("--test runs internal physics checks", test_ok and test_output:find("ALL VERLET CLOTH TESTS PASSED", 1, true) ~= nil)
local frame, frame_ok = run_cli("luajit ffi_verlet_cloth.lua --snapshot --ascii")
check("--snapshot --ascii renders headlessly", frame_ok and frame:find("VERLET CLOTH + ROPE", 1, true) ~= nil)
local invalid, _, invalid_code = run_cli("luajit ffi_verlet_cloth.lua --not-a-flag")
check("unknown option exits with code 2 and prints help", invalid_code == 2 and invalid:find("Unknown option", 1, true) ~= nil)

print(string.format("Test summary: %d/%d passed", passed, total))
os.exit(passed == total and 0 or 1)
