#!/usr/bin/env luajit
--[[
    run_all_tests.lua
    Unified test suite runner for the repository.
    Discovers and executes all test suites, aggregating results and exit codes.
]]

local test_suites = {
    { file = "test_ffi_suite.lua", description = "LuaJIT FFI Structs & C Binding Suite" },
    { file = "test_gallery_portrait.lua", description = "Procedural Portrait Gallery & HTML Exporter" },
    { file = "test_pix.lua", description = "pix — Terminal Gallery Image Viewer" },
    { file = "test_ffi_3d_viewer.lua", description = "FFI 3D Wireframe/Lambertian Software Renderer" },
    { file = "test_ffi_fractal_explorer.lua", description = "FFI Multi-Fractal Interactive Renderer" },
    { file = "test_ffi_image_filter_studio.lua", description = "FFI Image Filter & Convolution Studio" },
    { file = "test_todo_tui.lua", description = "LuaJIT FFI Todo TUI Application Suite" },
    { file = "test_ffi_system_info.lua", description = "FFI System Diagnostics & Hardware Suite" },
    { file = "test_ffi_russian_block.lua", description = "LuaJIT FFI Russian Block (Tetris) Suite" },
    { file = "test_ffi_chinese_chess.lua", description = "LuaJIT FFI Chinese Chess (Xiangqi) Engine & Rules Suite" },
    { file = "test_ffi_chip8.lua", description = "LuaJIT FFI Retro Chip-8 CPU Emulator & VM Suite" },
    { file = "test_ffi_falling_sand.lua", description = "LuaJIT FFI Falling Sand & Cellular Physics Suite" },
    { file = "test_ffi_demoscene_studio.lua", description = "LuaJIT FFI 1990s Demoscene Effects Studio Suite" },
    { file = "test_ffi_wolf3d_raycaster.lua", description = "LuaJIT FFI 1990s Wolfenstein 3D Raycasting Engine Suite" },
    { file = "test_ffi_game_2048.lua", description = "LuaJIT FFI 2048 Sliding Puzzle & Expectimax AI Suite" },
    { file = "test_ffi_image_defect_detector.lua", description = "LuaJIT FFI Optical Defect Inspection & Image Diff Suite" },
    { file = "test_ffi_wafer_d2d_inspector.lua", description = "Semiconductor 300mm Wafer Die-to-Die (D2D) Inspector Suite" },
    { file = "test_luatop.lua", description = "luatop — LuaJIT FFI Real-Time System & Hardware Monitor Suite" },
    { file = "test_weblite.lua", description = "weblite — Vim-Driven Terminal Web Browser Suite" },
    { file = "test_lumina.lua", description = "lumina — Miller Columns File Manager Suite" },
}

local luajit_bin = "luajit"
if arg and arg[-1] and #arg[-1] > 0 then
    luajit_bin = arg[-1]
else
    local f_check = io.open("./LuaJIT/src/luajit", "rb")
    if f_check then
        f_check:close()
        luajit_bin = "./LuaJIT/src/luajit"
    end
end

print("=================================================================")
print("             LUALAB UNIFIED TEST SUITE RUNNER                    ")
print("=================================================================")
print(string.format("Using interpreter: %s\n", luajit_bin))

local total_suites = #test_suites
local passed_suites = 0
local failed_suites = {}
local t_start_total = os.clock()

for idx, suite in ipairs(test_suites) do
    io.write(string.format("[%d/%d] Running %-32s (%s)...\n", idx, total_suites, suite.file, suite.description))
    local t_start = os.clock()
    local tmpfile = "_test_suite_" .. idx .. ".tmp"
    local cmd = string.format('"%s" %s > %s 2>&1', luajit_bin, suite.file, tmpfile)
    local ret = os.execute(cmd)

    local f = io.open(tmpfile, "r")
    local output = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(tmpfile)

    local elapsed = os.clock() - t_start
    local is_ok = (ret == 0 or ret == true)

    if is_ok then
        passed_suites = passed_suites + 1
        print(string.format("      \27[32m✔ SUITE PASSED\27[0m (%.2fs)\n", elapsed))
    else
        local exit_code = (type(ret) == "number") and ret or 1
        table.insert(failed_suites, { file = suite.file, output = output })
        print(string.format("      \27[31m✘ SUITE FAILED\27[0m (exit code: %s, %.2fs)\n", tostring(exit_code), elapsed))
        print("      --- Failure Output ---")
        for line in output:gmatch("[^\r\n]+") do
            print("      " .. line)
        end
        print("      ----------------------\n")
    end
end

local total_time = os.clock() - t_start_total
print("=================================================================")
print(string.format("SUMMARY: %d / %d suites passed (Total time: %.2fs)", passed_suites, total_suites, total_time))
if #failed_suites == 0 then
    print("\27[1;32mALL TEST SUITES PASSED SUCCESSFULLY!\27[0m")
    print("=================================================================")
    os.exit(0)
else
    print(string.format("\27[1;31mFAILED SUITES (%d):\27[0m", #failed_suites))
    for _, f in ipairs(failed_suites) do
        print("  - " .. f.file)
    end
    print("=================================================================")
    os.exit(1)
end
