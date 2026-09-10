--[[
    test_ffi_image_filter_studio.lua
    Automated Unit & Integration Tests for ffi_image_filter_studio.lua
]]

local function strip_ansi(s)
    return s:gsub("\27%[[0-9;]*[a-zA-Z]", ""):gsub("\27%[[0-9;]*m", "")
end

local function run_cmd(cmd)
    local p = io.popen(cmd, "r")
    if not p then return false, "" end
    local out = p:read("*a")
    local success, status, code = p:close()
    return (code == 0 or code == nil or success == true), out
end

local luajit = "./LuaJIT/src/luajit"
local total_tests = 0
local passed_tests = 0

local function test(desc, fn)
    total_tests = total_tests + 1
    io.write(string.format("  ▶ TEST [%d]: %s... ", total_tests, desc))
    local ok, err = pcall(fn)
    if ok then
        passed_tests = passed_tests + 1
        print("✔ PASS")
    else
        print("✘ FAIL\n    " .. tostring(err))
    end
end

print("=== Running Unit Tests for ffi_image_filter_studio.lua ===")

-- 1. Help Banner
test("Help banner displays correctly", function()
    local ok, out = run_cmd(string.format("%s ffi_image_filter_studio.lua --help", luajit))
    assert(ok, "Command failed")
    assert(out:find("Interactive Image Processing & Filter Studio"), "Missing banner text")
    assert(out:find("Convolution Filters"), "Missing filter documentation")
end)

-- 2. Procedural test rendering with Sobel filter
test("Single frame procedural render with Sobel filter", function()
    local ok, out = run_cmd(string.format("%s ffi_image_filter_studio.lua --once --filter 7", luajit))
    assert(ok, "Command failed")
    local plain = strip_ansi(out)
    assert(plain:find("FILTER STUDIO"), "Missing header bar")
    assert(plain:find("Sobel Edge Detection"), "Sobel filter title missing")
    assert(plain:find("Histogram:"), "Histogram bar missing")
end)

-- 3. Gaussian Blur on real portrait image
test("Single frame render on real image with Gaussian Blur", function()
    local ok, out = run_cmd(string.format("%s ffi_image_filter_studio.lua --once --filter 4 portraits/portrait_1_lady.png", luajit))
    assert(ok, "Command failed")
    local plain = strip_ansi(out)
    assert(plain:find("Gaussian Blur (5x5)", 1, true), "Gaussian blur title missing")
end)

-- 4. Cartoon / Cel-Shading filter test
test("Cartoon / Comic Cel-shading filter renders properly", function()
    local ok, out = run_cmd(string.format("%s ffi_image_filter_studio.lua --once --filter 2 portraits/portrait_1_lady.png", luajit))
    assert(ok, "Cartoon command failed")
    local plain = strip_ansi(out)
    assert(plain:find("Cartoon / Comic Cel-Shading", 1, true), "Cartoon title missing")
end)

-- 4. Color adjustments: Invert, Brightness, Contrast, Saturation
test("Color adjustments pipeline (Invert, Contrast, Gamma)", function()
    local ok, out = run_cmd(string.format("%s ffi_image_filter_studio.lua --once -b 15 -c 1.5 -g 0.8 -i", luajit))
    assert(ok, "Command failed")
    local plain = strip_ansi(out)
    assert(plain:find("%[INV%]"), "Invert tag missing")
    assert(plain:find("B:%+15"), "Brightness status missing")
    assert(plain:find("C:1.5"), "Contrast status missing")
end)

-- 5. Export processed image to PPM
test("Process and export image to PPM file", function()
    local tmp_file = "/tmp/test_studio_export.ppm"
    os.remove(tmp_file)
    local ok, out = run_cmd(string.format("%s ffi_image_filter_studio.lua --once --filter 4 --save %s portraits/portrait_1_lady.png", luajit, tmp_file))
    assert(ok, "Export command failed")
    local f = io.open(tmp_file, "rb")
    assert(f ~= nil, "Saved PPM file does not exist")
    local head = f:read(2)
    f:close()
    os.remove(tmp_file)
    assert(head == "P6", "Exported PPM file has invalid magic header: " .. tostring(head))
end)

-- 6. Export processed image to PNG
test("Process and export image to PNG file", function()
    local tmp_file = "/tmp/test_studio_export.png"
    os.remove(tmp_file)
    local ok, out = run_cmd(string.format("%s ffi_image_filter_studio.lua --once --filter 7 --sepia --save %s", luajit, tmp_file))
    assert(ok, "Export PNG command failed")
    local f = io.open(tmp_file, "rb")
    assert(f ~= nil, "Saved PNG file does not exist")
    f:close()
    os.remove(tmp_file)
end)

print(string.format("\nTest Summary: %d / %d tests passed.", passed_tests, total_tests))
if passed_tests == total_tests then
    print("ALL IMAGE FILTER STUDIO TESTS PASSED!\n")
    os.exit(0)
else
    print("SOME TESTS FAILED!\n")
    os.exit(1)
end
