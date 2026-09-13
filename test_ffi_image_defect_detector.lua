#!/usr/bin/env luajit
--[[
    test_ffi_image_defect_detector.lua
    Unit, regression, and integration test suite for ffi_image_defect_detector.lua.
]]

local ffi = require("ffi")

print("=== Running Unit Tests for ffi_image_defect_detector.lua ===")

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --help",
        expect = "Optical Defect Inspector & Image Diff Engine • LuaJIT FFI"
    },
    {
        name = "CLI self-tests flag (--test)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --test",
        expect = "ALL DEFECT DETECTOR TESTS PASSED SUCCESSFULLY!"
    },
    {
        name = "Synthetic demo mode (--demo --ascii)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --demo --ascii",
        expect = "OPTICAL DEFECT INSPECTOR"
    },
    {
        name = "JSON report export (--demo --json)",
        cmd = "./LuaJIT/src/luajit ffi_image_defect_detector.lua --demo --json",
        expect = '"verdict": "FAIL"'
    },
    {
        name = "Pass verdict on identical images",
        cmd = "./LuaJIT/src/luajit -e 'local mod = require(\"ffi_image_defect_detector\"); local g = mod.PCBGenerator.generate_golden_pcb(60, 40); local d = mod.DefectDetector.new(); local res = d:compute_diff(g, g); local b = d:extract_blobs(res); print(\"IDENTICAL_BLOBS_COUNT=\" .. #b)'",
        expect = "IDENTICAL_BLOBS_COUNT=0"
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

-- In-Depth Module Tests
print("\n--- In-Depth FFI Struct & Detection Logic Tests ---")
local mod = require("ffi_image_defect_detector")
local Image = mod.Image
local PCBGenerator = mod.PCBGenerator
local DefectDetector = mod.DefectDetector

local function assert_test(name, cond)
    if cond then
        passed = passed + 1
        print(string.format("  \27[32m✔ PASS\27[0m: %s", name))
    else
        print(string.format("  \27[31m✘ FAIL\27[0m: %s", name))
    end
    total_cli = total_cli + 1
end

-- 1. Struct Layout
assert_test("PixelRGB size is 3 bytes", ffi.sizeof("PixelRGB") == 3)
assert_test("DefectBlob size is valid", ffi.sizeof("DefectBlob") > 0)

-- 2. Clean Image Diff produces 0 blobs
local ref = Image.new(50, 50, 100, 150, 200)
local smp = ref:clone()
local det = DefectDetector.new({ tolerance = 20, min_blob_area = 3 })
local res0 = det:compute_diff(ref, smp)
local blobs0 = det:extract_blobs(res0)
assert_test("Zero difference returns 0 blobs", #blobs0 == 0)

-- 3. Synthetic Defect Injections
smp:fill_rect(10, 10, 8, 8, 255, 0, 0) -- square defect of 64 pixels
local res1 = det:compute_diff(ref, smp)
local blobs1 = det:extract_blobs(res1)
assert_test("Single injected defect detected", #blobs1 == 1)
assert_test("Injected defect area is 64 pixels", blobs1[1].area == 64)
assert_test("Injected defect bbox x_min == 10", blobs1[1].x_min == 10)
assert_test("Injected defect bbox y_min == 10", blobs1[1].y_min == 10)

print(string.format("\nTest Summary: %d / %d tests passed.", passed, total_cli))
if passed == total_cli then
    print("\27[1;32mALL DEFECT DETECTOR TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
    os.exit(1)
end
