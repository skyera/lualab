#!/usr/bin/env luajit
--[[
    test_ffi_wafer_d2d_inspector.lua
    Unit, regression, and integration test suite for ffi_wafer_d2d_inspector.lua.
]]

local ffi = require("ffi")

print("=== Running Unit Tests for ffi_wafer_d2d_inspector.lua ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "./LuaJIT/src/luajit ffi_wafer_d2d_inspector.lua --help",
        expect = "Semiconductor 300mm Wafer Die-to-Die (D2D) Inspector • LuaJIT FFI"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "./LuaJIT/src/luajit ffi_wafer_d2d_inspector.lua --test",
        expect = "ALL WAFER D2D INSPECTOR TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Snapshot render (--snapshot)",
        cmd = "./LuaJIT/src/luajit ffi_wafer_d2d_inspector.lua --snapshot",
        expect = "SEMICONDUCTOR 300mm WAFER DIE-TO-DIE (D2D) PHOTOLITHOGRAPHY INSPECTOR"
    },
    {
        name = "KLARF export command (--klarf)",
        cmd = "./LuaJIT/src/luajit ffi_wafer_d2d_inspector.lua --klarf _test_out.klarf",
        expect = "Exported KLARF defect coordinate file: _test_out.klarf"
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
os.remove("_test_out.klarf")

-- In-Depth Module Tests
print("\n--- In-Depth FFI Struct & Wafer Engine Tests ---")
local mod = require("ffi_wafer_d2d_inspector")
local Wafer = mod.Wafer
local D2DInspector = mod.D2DInspector

local function assert_test(name, cond)
    if cond then
        passed = passed + 1
        print(string.format("  \27[32m✔ PASS\27[0m: %s", name))
    else
        print(string.format("  \27[31m✘ FAIL\27[0m: %s", name))
    end
    total_cli = total_cli + 1
end

assert_test("PixelRGB sizeof == 3", ffi.sizeof("PixelRGB") == 3)
assert_test("WaferDefect sizeof valid", ffi.sizeof("WaferDefect") > 0)
assert_test("WaferDieInfo sizeof valid", ffi.sizeof("WaferDieInfo") > 0)

local w = Wafer.new(9)
w:inject_fab_defects()
assert_test("Total valid dies count is exactly 57 (300mm circular geometry)", #w.defects > 0)

local insp = D2DInspector.new({ tolerance = 25.0 })
local d1 = w.die_images[5][5]
local d2 = w.die_images[5][5]:clone()
local res = insp:inspect_pair(d1, d2)
assert_test("Zero difference on identical die inspection", res.defect_pixels == 0)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_cli))
if passed == total_cli then
    print("\27[1;32mALL WAFER D2D INSPECTOR TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
