--[[
    test_ffi_fractal_explorer.lua
    Unit tests for ffi_fractal_explorer.lua.
]]

print("=== Running Unit Tests for ffi_fractal_explorer.lua ===")

local tests = {
    {
        name = "Help display (--help)",
        cmd = "./LuaJIT/src/luajit ffi_fractal_explorer.lua --help",
        expect = "Terminal Fractal Explorer"
    },
    {
        name = "Mandelbrot Set frame render",
        cmd = "./LuaJIT/src/luajit ffi_fractal_explorer.lua 1 --once",
        expect = "Fractal: [1] Mandelbrot Set"
    },
    {
        name = "Julia Set with Fire palette",
        cmd = "./LuaJIT/src/luajit ffi_fractal_explorer.lua 2 -p 2 --once",
        expect = "Fractal: [2] Julia Set"
    },
    {
        name = "Burning Ship fractal render",
        cmd = "./LuaJIT/src/luajit ffi_fractal_explorer.lua 3 --once",
        expect = "Fractal: [3] Burning Ship"
    },
    {
        name = "Tricorn fractal render",
        cmd = "./LuaJIT/src/luajit ffi_fractal_explorer.lua 4 --once",
        expect = "Fractal: [4] Tricorn (Mandelbar)"
    },
    {
        name = "Newton-Raphson basins render",
        cmd = "./LuaJIT/src/luajit ffi_fractal_explorer.lua 5 --once",
        expect = "Fractal: [5] Newton-Raphson"
    }
}

local passed = 0
for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
    local raw = p:read("*a")
    p:close()

    local out = raw:gsub("\27%[[0-9;]*m", ""):gsub("\27%[[0-9;]*[A-Za-z]", "")

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, #tests, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, #tests, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

print(string.format("\nTest Summary: %d / %d tests passed.", passed, #tests))
if passed == #tests then
    print("\27[1;32mALL FRACTAL EXPLORER TESTS PASSED!\27[0m")
else
    os.exit(1)
end
