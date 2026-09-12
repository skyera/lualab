#!/usr/bin/env luajit
--[[
    run_all_tests.lua
    Unified test suite runner for the repository.
    Discovers and executes all test suites, aggregating results and exit codes.
]]

local test_suites = {
    { file = "test_ffi_suite.lua", description = "LuaJIT FFI Structs & C Binding Suite" },
    { file = "test_gallery_portrait.lua", description = "Procedural Portrait Gallery & HTML Exporter" },
    { file = "test_view_gallery_terminal.lua", description = "Terminal Gallery Image Viewer" },
    { file = "test_ffi_3d_viewer.lua", description = "FFI 3D Wireframe/Lambertian Software Renderer" },
    { file = "test_ffi_fractal_explorer.lua", description = "FFI Multi-Fractal Interactive Renderer" },
    { file = "test_ffi_image_filter_studio.lua", description = "FFI Image Filter & Convolution Studio" },
    { file = "test_todo_tui.lua", description = "LuaJIT FFI Todo TUI Application Suite" },
    { file = "test_ffi_system_info.lua", description = "FFI System Diagnostics & Hardware Suite" },
}

local luajit_bin = "./LuaJIT/src/luajit"
local f_check = io.open(luajit_bin, "rb")
if f_check then
    f_check:close()
else
    luajit_bin = "luajit"
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
    local cmd = string.format("%s %s", luajit_bin, suite.file)
    local p = io.popen(cmd .. " 2>&1", "r")
    local output = p and p:read("*a") or ""
    local success, exit_status, code = false, nil, 1
    if p then
        success, exit_status, code = p:close()
    end

    local elapsed = os.clock() - t_start
    local is_ok = (code == 0 or (code == nil and success == true))

    if is_ok then
        passed_suites = passed_suites + 1
        print(string.format("      \27[32m✔ SUITE PASSED\27[0m (%.2fs)\n", elapsed))
    else
        table.insert(failed_suites, { file = suite.file, output = output })
        print(string.format("      \27[31m✘ SUITE FAILED\27[0m (exit code: %s, %.2fs)\n", tostring(code), elapsed))
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
