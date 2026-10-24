#!/usr/bin/env luajit
--[[
================================================================================
test_ffi_imagej.lua
Automated Verification & Test Suite for ffi_imagej.lua
Validates mathematical correctness, ImageJ algorithms, and headless TUI rendering.
================================================================================
]]

local ffi = require("ffi")
local imagej = require("ffi_imagej")

local function assert_near(actual, expected, tol, name)
    tol = tol or 0.01
    if math.abs(actual - expected) > tol then
        error(string.format("ASSERT FAILED [%s]: expected ~%.4f, got %.4f (diff: %.4f, tol: %.4f)",
            name or "value", expected, actual, math.abs(actual - expected), tol))
    end
end

local function assert_eq(actual, expected, name)
    if actual ~= expected then
        error(string.format("ASSERT FAILED [%s]: expected %s, got %s",
            name or "value", tostring(expected), tostring(actual)))
    end
end

local function run_test(name, fn)
    io.write(string.format("Running %-55s ... ", name))
    io.flush()
    local ok, err = pcall(fn)
    if ok then
        io.write("\27[32m[PASS]\27[0m\n")
    else
        io.write("\27[31m[FAIL]\27[0m\n")
        io.stderr:write(string.format("  Error: %s\n", tostring(err)))
        os.exit(1)
    end
end

print("================================================================================")
print("              ffi_imagej.lua - Scientific Verification Test Suite               ")
print("================================================================================")

-- Test 1: ImageBuffer Creation, Set/Get, and Procedural Targets
run_test("Test 1: ImageBuffer & Procedural Generation", function()
    local buf = imagej.ImageBuffer.new(32, 32, false)
    assert_eq(buf.width, 32, "buf.width")
    assert_eq(buf.height, 32, "buf.height")
    assert_eq(buf.channels, 1, "buf.channels")

    buf:set_pixel(10, 15, 200)
    assert_eq(buf:get_gray(10, 15), 200, "get_gray")
    local r, g, b = buf:get_pixel(10, 15)
    assert_eq(r, 200, "r")
    assert_eq(g, 200, "g")
    assert_eq(b, 200, "b")

    -- Out of bounds safety
    assert_eq(buf:get_gray(-1, -1), 0, "oob left")
    assert_eq(buf:get_gray(100, 100), 0, "oob right")

    -- Procedural cells
    local cells = imagej.ImageBuffer.generate_cells(64, 64)
    assert_eq(cells.width, 64, "cells.width")
    assert_eq(cells.height, 64, "cells.height")

    -- Procedural target
    local target = imagej.ImageBuffer.generate_target(64, 64)
    assert_eq(target.width, 64, "target.width")
    assert_eq(target.height, 64, "target.height")
end)

-- Test 2: Statistical Analysis & ROI Measure (Ground Truth Math)
run_test("Test 2: Statistical Analysis & ROI Measure Math", function()
    local img = imagej.ImageBuffer.new(10, 10, false)
    -- Fill with 1 to 100
    for y = 0, 9 do
        for x = 0, 9 do
            img:set_pixel(x, y, y * 10 + x + 1)
        end
    end

    local roi = { x1 = 0, y1 = 0, x2 = 9, y2 = 9 }
    local stats = imagej.compute_roi_stats(img, roi)

    assert_eq(stats.area, 100, "area")
    assert_eq(stats.min, 1, "min")
    assert_eq(stats.max, 100, "max")
    assert_eq(stats.int_den, 5050, "int_den") -- sum 1..100 = 5050
    assert_near(stats.mean, 50.5, 0.001, "mean")

    -- Variance of 1..100: (100^2 - 1)/12 = 9999/12 = 833.25; StdDev = sqrt(833.25) = ~28.866
    assert_near(stats.std_dev, 28.866, 0.01, "std_dev")
    -- In 1..100, discrete median point is 50 or 51
    assert(stats.median == 50 or stats.median == 51, "median 50 or 51")
end)

-- Test 3: 1D Line Profile & FWHM Peak Calculation
run_test("Test 3: 1D Line Profile & FWHM Calculation", function()
    local img = imagej.ImageBuffer.new(64, 64, false)
    -- Create a Gaussian peak centered at X=32 on Y=10
    -- Baseline = 10, Peak = 210, Sigma = 5
    for x = 0, 63 do
        local dx = x - 32
        local val = 10 + 200 * math.exp(-(dx * dx) / (2 * 5 * 5))
        img:set_pixel(x, 10, math.floor(val))
    end

    local prof = imagej.compute_line_profile(img, true, 10)
    assert_eq(prof.length, 64, "profile length")
    assert_eq(prof.peak_pos, 32, "peak position")
    assert_near(prof.peak_val, 210, 2.0, "peak value")
    assert_near(prof.baseline, 10, 2.0, "baseline")
    assert_near(prof.half_max, 110, 2.0, "half_max")

    -- Theoretical FWHM for Gaussian with sigma=5 is 2 * sqrt(2*ln(2)) * 5 = 2.355 * 5 = ~11.77 px
    assert_near(prof.fwhm, 12, 1.5, "fwhm")
end)

-- Test 4: Otsu Auto-Thresholding on Bimodal Distribution
run_test("Test 4: Otsu Auto-Thresholding on Bimodal Image", function()
    local img = imagej.ImageBuffer.new(100, 100, false)
    -- Half background at 40, half foreground at 200
    for y = 0, 99 do
        for x = 0, 99 do
            if x < 50 then
                img:set_pixel(x, y, 40)
            else
                img:set_pixel(x, y, 200)
            end
        end
    end

    local otsu_t = imagej.compute_otsu_threshold(img)
    -- Optimal threshold between 40 and 200 is midpoint ~120
    if otsu_t < 40 or otsu_t > 200 then
        error("Otsu threshold outside bimodal range: " .. tostring(otsu_t))
    end
    assert_near(otsu_t, 120, 10, "otsu threshold")
end)

-- Test 5: Connected Component Particle Analysis
run_test("Test 5: Connected Component Particle / Blob Counter", function()
    local img = imagej.ImageBuffer.new(50, 50, false)
    -- Draw 2 distinct separate square blobs
    -- Blob 1: 5x5 at (5, 5), area = 25
    for y = 5, 9 do
        for x = 5, 9 do
            img:set_pixel(x, y, 255)
        end
    end
    -- Blob 2: 4x4 at (30, 30), area = 16
    for y = 30, 33 do
        for x = 30, 33 do
            img:set_pixel(x, y, 255)
        end
    end

    local parts = imagej.analyze_particles(img, 128)
    assert_eq(parts.count, 2, "particle count")
    assert_eq(parts.total_area, 25 + 16, "total area")
    assert_eq(parts.blobs[1].area, 25, "largest blob area")
    assert_eq(parts.blobs[2].area, 16, "second blob area")
    assert_eq(parts.blobs[1].cx, 7, "blob 1 center x")
    assert_eq(parts.blobs[1].cy, 7, "blob 1 center y")
end)

-- Test 6: Spatial Convolutions (Median, Blur, Sobel)
run_test("Test 6: Spatial Convolutions (Median & Sobel Edge)", function()
    local img = imagej.ImageBuffer.new(20, 20, false)
    -- Fill with 100, add a single impulse salt noise at (10, 10) = 255
    for y = 0, 19 do
        for x = 0, 19 do
            img:set_pixel(x, y, 100)
        end
    end
    img:set_pixel(10, 10, 255)

    -- Median filter must completely remove isolated salt-and-pepper noise
    local filtered = imagej.apply_filter(img, "median")
    assert_eq(filtered:get_gray(10, 10), 100, "median removed salt noise")

    -- Sobel edge on a sharp vertical step: left 0, right 200
    local step_img = imagej.ImageBuffer.new(20, 20, false)
    for y = 0, 19 do
        for x = 10, 19 do
            step_img:set_pixel(x, y, 200)
        end
    end
    local sobel = imagej.apply_filter(step_img, "sobel")
    -- Strong edge response at column 9 and 10
    local edge_val = sobel:get_gray(10, 10)
    if edge_val < 150 then
        error("Expected strong Sobel edge at boundary, got " .. tostring(edge_val))
    end

    -- Sharpen filter preserves uniform region and enhances contrast at step
    local sharp = imagej.apply_filter(step_img, "sharpen")
    assert_eq(sharp:get_gray(2, 2), 0, "sharpen flat dark")
    assert_eq(sharp:get_gray(15, 15), 200, "sharpen flat bright")
    assert(sharp:get_gray(10, 10) >= 200, "sharpen boosts bright edge")

    -- Invert filter
    local inv = imagej.apply_filter(step_img, "invert")
    assert_eq(inv:get_gray(2, 2), 255, "invert 0 -> 255")
    assert_eq(inv:get_gray(15, 15), 55, "invert 200 -> 55")
end)

-- Test 7: Lookup Tables (LUTs) Mapping
run_test("Test 7: Scientific Lookup Tables (LUTs)", function()
    for _, lut_name in ipairs(imagej.LUT_NAMES) do
        local fn = imagej.LUTS[lut_name]
        assert(fn ~= nil, "LUT function exists: " .. tostring(lut_name))
        -- Test boundaries 0, 128, 255
        for _, v in ipairs({ 0, 128, 255 }) do
            local r, g, b = fn(v)
            assert(r >= 0 and r <= 255, "r in bounds for " .. lut_name)
            assert(g >= 0 and g <= 255, "g in bounds for " .. lut_name)
            assert(b >= 0 and b <= 255, "b in bounds for " .. lut_name)
        end
    end
end)

-- Test 8: Headless TUI Rendering (All Modes & Sizes)
run_test("Test 8: Headless TUI Rendering (All Modes & Views)", function()
    local img = imagej.ImageBuffer.generate_cells(64, 64)
    local app = imagej.build_tui_app(img, "test_render.pgm")

    -- 1. Normal Viewport across resolutions
    for _, dim in ipairs({ {80, 24}, {100, 30}, {140, 45} }) do
        local frame = app:render(dim[1], dim[2])
        assert(type(frame) == "string", "frame is string")
        assert(#frame > 200, "frame contains data")
        assert(not frame:find("bad argument to 'format'"), "no format string crashes")
    end

    -- 2. Line Profile Modal
    app.mode = "profile"
    local prof_frame = app:render(100, 30)
    assert(#prof_frame > 200, "profile frame rendered")

    -- 3. Threshold Split-Pane & Full Table Modal
    app.mode = "threshold"
    local thresh_frame = app:render(100, 30)
    assert(#thresh_frame > 200, "threshold split-pane frame rendered")

    app.mode = "threshold_table"
    local table_frame = app:render(100, 30)
    assert(#table_frame > 200, "threshold full table modal rendered")

    -- 4. Help Modal
    app.show_help = true
    local help_frame = app:render(100, 30)
    assert(#help_frame > 200, "help frame rendered")
end)

-- Test 9: Scoping & Undeclared Global Check (LuaJIT Bytecode)
run_test("Test 9: Scoping & Undeclared Global Check (GGET)", function()
    local p = io.popen("luajit -bl ffi_imagej.lua 2>&1")
    if not p then error("Cannot invoke luajit for bytecode analysis") end
    local output = p:read("*a")
    p:close()

    local undeclared = {}
    for line in output:gmatch("[^\r\n]+") do
        -- Only check global access GGET
        local gname = line:match('GGET%s+.-;%s*"([%w_]+)"')
        if gname then
            -- Standard whitelisted globals in Lua/LuaJIT
            local allowed = {
                require = true, ffi = true, bit = true, math = true,
                string = true, table = true, io = true, os = true,
                debug = true, arg = true,
                pcall = true, setmetatable = true, tonumber = true,
                tostring = true, ipairs = true, type = true, assert = true
            }
            if not allowed[gname] then
                table.insert(undeclared, gname)
            end
        end
    end

    if #undeclared > 0 then
        error("Found undeclared global variable(s): " .. table.concat(undeclared, ", "))
    end
end)

-- Test 10: CLI Help & Argument Options (--help, -h, /?, --target)
run_test("Test 10: CLI Help & Argument Options", function()
    local ret_help = imagej.main({ "--help" })
    assert_eq(ret_help, 0, "--help return code")

    local ret_h = imagej.main({ "-h" })
    assert_eq(ret_h, 0, "-h return code")

    local ret_target = imagej.main({ "--target=usaf", "--test" })
    assert_eq(ret_target, 0, "--target=usaf return code")

    -- Test interactive 'l' and 'L' LUT cycling on Grayscale
    local buf = imagej.ImageBuffer.generate_cells(32, 32)
    local app = imagej.build_tui_app(buf, "test.pgm")
    assert_eq(app.lut_idx, 1, "initial lut is grayscale")
    assert_eq(app.rgb_passthrough, false, "grayscale not rgb passthrough")
    app:handle_key("l")
    assert_eq(app.lut_idx, 2, "l key cycles to Fire")
    app:handle_key("l")
    assert_eq(app.lut_idx, 3, "l key cycles to Viridis")
    app:handle_key("L")
    assert_eq(app.lut_idx, 2, "L key cycles backward to Fire")
end)

-- Test 11: RGB Passthrough, 2-Point ROI, Zoom, Window/Level & Verified Export
run_test("Test 11: RGB Passthrough, 2-Pt ROI, Zoom & Export", function()
    -- 1. RGB Truecolor Passthrough
    local rgb_buf = imagej.ImageBuffer.new(32, 32, true)
    rgb_buf:set_pixel(5, 5, 250, 120, 40)
    local rgb_app = imagej.build_tui_app(rgb_buf, "rgb_test.ppm")
    assert_eq(rgb_app.rgb_passthrough, true, "RGB image starts in Truecolor passthrough")
    rgb_app:handle_key("l")
    assert_eq(rgb_app.rgb_passthrough, false, "l key switches RGB image to LUT mode")
    assert_eq(rgb_app.lut_idx, 2, "switches to Fire LUT")
    rgb_app:handle_key("L")
    assert_eq(rgb_app.lut_idx, 1, "switches back to Grayscale")
    rgb_app:handle_key("L")
    assert_eq(rgb_app.rgb_passthrough, true, "cycles back to Original RGB")

    -- 2. 2-Point Interactive ROI State Machine
    assert_eq(rgb_app.roi_state, "none", "initial ROI state is none")
    rgb_app.probe_x = 4
    rgb_app.probe_y = 6
    rgb_app:handle_key("r")
    assert_eq(rgb_app.roi_state, "sizing", "first r starts sizing")
    assert_eq(rgb_app.roi.x1, 4, "roi x1 anchored at probe_x")
    assert_eq(rgb_app.roi.y1, 6, "roi y1 anchored at probe_y")

    -- Move cursor to resize ROI
    rgb_app:handle_key("RIGHT")
    rgb_app:handle_key("DOWN")
    assert_eq(rgb_app.roi.x2, 5, "roi x2 follows cursor")
    assert_eq(rgb_app.roi.y2, 7, "roi y2 follows cursor")

    rgb_app:handle_key("r")
    assert_eq(rgb_app.roi_state, "locked", "second r locks ROI")
    rgb_app:handle_key("RIGHT")
    assert_eq(rgb_app.roi.x2, 5, "locked ROI does not change when cursor moves")

    rgb_app:handle_key("r")
    assert_eq(rgb_app.roi_state, "none", "third r clears ROI")

    -- 3. Interactive Zoom & Pan
    assert_eq(rgb_app.zoom, 1.0, "initial zoom 1.0x")
    rgb_app:handle_key("+")
    assert_eq(rgb_app.zoom, 2.0, "zoom in to 2.0x")
    local vx0, vy0, vw, vh = rgb_app:get_viewport_bounds()
    assert_eq(vw, 16, "2.0x zoom halves viewport width")
    assert_eq(vh, 16, "2.0x zoom halves viewport height")
    rgb_app:handle_key("0")
    assert_eq(rgb_app.zoom, 1.0, "0 resets zoom to 1.0x")

    -- 4. Bidirectional Window/Level
    rgb_app.win_low = 40
    rgb_app.win_high = 200
    rgb_app:sync_wl()
    local w0 = rgb_app.win_width
    rgb_app:handle_key("w")
    assert(rgb_app.win_width < w0, "w narrows contrast window")
    rgb_app:handle_key("W")
    assert_eq(rgb_app.win_width, w0, "W widens contrast window back")

    local b0 = rgb_app.win_level
    rgb_app:handle_key("b")
    assert(rgb_app.win_level < b0, "b shifts window level down to brighten image")
    rgb_app:handle_key("B")
    assert_eq(rgb_app.win_level, b0, "B shifts window level back")

    -- 5. Verified CSV + PPM Export
    local tmp_csv = "test_tmp_measurements.csv"
    local tmp_ppm = "test_tmp_export.ppm"
    local ok, msg = rgb_app:export_data(tmp_csv, tmp_ppm)
    assert_eq(ok, true, "export_data succeeded: " .. tostring(msg))
    os.remove(tmp_csv)
    os.remove(tmp_ppm)
end)

-- Test 12: RGB Channel Splitting ([c] / extract_channel)
run_test("Test 12: RGB Channel Splitting (Red, Green, Blue, Gray)", function()
    local rgb_img = imagej.ImageBuffer.new(16, 16, true)
    for y = 0, 15 do
        for x = 0, 15 do
            rgb_img:set_pixel(x, y, 220, 110, 40)
        end
    end

    local app = imagej.build_tui_app(rgb_img, "channels.ppm")
    assert_eq(imagej.CHANNEL_MODES[app.channel_idx], "composite", "initial channel composite")

    -- Cycle to Red ('c')
    app:handle_key("c")
    assert_eq(imagej.CHANNEL_MODES[app.channel_idx], "red", "channel red")
    assert_eq(app.img:get_gray(8, 8), 220, "red channel value 220")

    -- Cycle to Green ('c')
    app:handle_key("c")
    assert_eq(imagej.CHANNEL_MODES[app.channel_idx], "green", "channel green")
    assert_eq(app.img:get_gray(8, 8), 110, "green channel value 110")

    -- Cycle to Blue ('c')
    app:handle_key("c")
    assert_eq(imagej.CHANNEL_MODES[app.channel_idx], "blue", "channel blue")
    assert_eq(app.img:get_gray(8, 8), 40, "blue channel value 40")
end)

-- Test 13: Point-to-Point Distance & Angle Ruler ([d] / compute_ruler)
run_test("Test 13: Point-to-Point Euclidean Ruler & Angle Math", function()
    local img = imagej.ImageBuffer.new(64, 64, false)
    img:set_pixel(10, 10, 50)
    img:set_pixel(40, 50, 200)

    -- 3-4-5 right triangle: dx=30, dy=40 -> D = 50.0 px
    local rm = imagej.compute_ruler(img, 10, 10, 40, 50)
    assert_near(rm.dist, 50.0, 0.001, "30-40-50 triangle distance")
    assert_eq(rm.dv, 150, "intensity delta 200 - 50")

    -- Interactive 'd' state machine
    local app = imagej.build_tui_app(img, "ruler.pgm")
    app.probe_x = 10
    app.probe_y = 10
    app:handle_key("d")
    assert_eq(app.ruler.state, "measuring", "first d starts measuring")
    app:move_probe(30, 40)
    assert_eq(app.ruler.x2, 40, "ruler x2 follows probe")
    assert_eq(app.ruler.y2, 50, "ruler y2 follows probe")
    app:handle_key("d")
    assert_eq(app.ruler.state, "locked", "second d locks ruler")
    local frame = app:render(100, 30)
    assert(frame:find("50.0 px"), "rendered frame shows ruler distance")
    app:handle_key("d")
    assert_eq(app.ruler.state, "none", "third d clears ruler")
end)

-- Test 14: Morphological Operations (Erode, Dilate, Open, Close) & Equalization
run_test("Test 14: Morphological Ops (Erode/Dilate/Open/Close) & EQ", function()
    local img = imagej.ImageBuffer.new(20, 20, false)
    -- Draw a 3x3 bright block at (9..11, 9..11) and 1x1 salt noise at (3, 3)
    for y = 9, 11 do
        for x = 9, 11 do
            img:set_pixel(x, y, 250)
        end
    end
    img:set_pixel(3, 3, 250)

    -- Erode shrinks 3x3 block to single center pixel (10, 10) and removes (3, 3)
    local eroded = imagej.apply_filter(img, "erode")
    assert_eq(eroded:get_gray(10, 10), 250, "erode center survives")
    assert_eq(eroded:get_gray(9, 9), 0, "erode corner removed")
    assert_eq(eroded:get_gray(3, 3), 0, "erode isolated pixel removed")

    -- Open (Erode -> Dilate) removes 1x1 noise at (3, 3) but restores 3x3 block at (9..11, 9..11)
    local opened = imagej.apply_filter(img, "open")
    assert_eq(opened:get_gray(3, 3), 0, "open removed 1x1 noise")
    assert_eq(opened:get_gray(10, 10), 250, "open preserved 3x3 center")
    assert_eq(opened:get_gray(9, 9), 250, "open restored 3x3 corner")

    -- Histogram Equalization spreads compressed range [100..110] across [0..255]
    local low_c = imagej.ImageBuffer.new(16, 16, false)
    for y = 0, 15 do
        for x = 0, 15 do
            low_c:set_pixel(x, y, 100 + (x % 10))
        end
    end
    local eq_img = imagej.apply_filter(low_c, "equalize")
    local stats = imagej.compute_roi_stats(eq_img, { x1 = 0, y1 = 0, x2 = 15, y2 = 15 })
    assert_eq(stats.min, 0, "equalized min stretched to 0")
    assert_eq(stats.max, 255, "equalized max stretched to 255")
end)

-- Test 15: Gamma Curve, Multi-ROI Results Log ([m]), and 3D Surface Plot ([3])
run_test("Test 15: Gamma Curve, Multi-ROI Log & 3D Surface Plot", function()
    local img = imagej.ImageBuffer.generate_cells(48, 48)
    local app = imagej.build_tui_app(img, "cells.pgm")

    -- Gamma adjustment ('g' and 'G')
    assert_near(app.gamma, 1.0, 0.001, "initial gamma 1.0")
    app:handle_key("g")
    assert_near(app.gamma, 0.9, 0.001, "g decreases gamma to 0.9")
    app:handle_key("G")
    assert_near(app.gamma, 1.0, 0.001, "G restores gamma to 1.0")

    -- Multi-ROI Measurement Log ('m')
    assert_eq(#app.measurement_log, 0, "initial log empty")
    app:handle_key("m")
    app:handle_key("m")
    assert_eq(#app.measurement_log, 2, "two measurements logged")

    -- 3D Isometric Surface Plot ('3')
    app:handle_key("3")
    assert_eq(app.mode, "surface3d", "switched to surface3d mode")
    local surf_frame = app:render(100, 30)
    assert(#surf_frame > 200, "3D surface plot rendered")
    assert(surf_frame:find("3D Isometric Surface Plot"), "3D surface plot title present")
    app:handle_key("3")
    assert_eq(app.mode, "normal", "3 returns to normal mode")
end)

print("================================================================================")
print("\27[32mALL 15 TEST SUITES PASSED! Mathematical & UI invariants verified.\27[0m")
print("================================================================================")
