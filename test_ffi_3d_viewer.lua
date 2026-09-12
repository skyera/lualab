--[[
    test_ffi_3d_viewer.lua
    Unit tests for 3D terminal graphics pipeline in ffi_3d_viewer.lua.
]]

print("=== Running Unit Tests for ffi_3d_viewer.lua ===")

local luajit = "luajit"
local f_check = io.open("./LuaJIT/src/luajit", "rb") or io.open("./LuaJIT/src/luajit.exe", "rb")
if f_check then
    f_check:close()
    luajit = (package.config:sub(1,1) == '\\') and ".\\LuaJIT\\src\\luajit.exe" or "./LuaJIT/src/luajit"
end

local tests = {
    {
        name = "CLI Help output",
        cmd = luajit .. " ffi_3d_viewer.lua --help",
        expect = "Terminal 3D Mesh Renderer"
    },
    {
        name = "Cube shaded single frame render",
        cmd = luajit .. " ffi_3d_viewer.lua 1 --once",
        expect = "Model: [1] Cube"
    },
    {
        name = "Torus 3D Donut shaded single frame render",
        cmd = luajit .. " ffi_3d_viewer.lua 2 --once",
        expect = "Model: [2] Torus"
    },
    {
        name = "Pyramid wireframe single frame render",
        cmd = luajit .. " ffi_3d_viewer.lua 3 --wireframe --once",
        expect = "Mode: Wireframe"
    },
    {
        name = "Octahedron Gem single frame render",
        cmd = luajit .. " ffi_3d_viewer.lua 4 --once",
        expect = "Model: [4] Octahedron Gem"
    },
    {
        name = "Cylinder Prism single frame render",
        cmd = luajit .. " ffi_3d_viewer.lua 5 --once",
        expect = "Model: [5] Cylinder Prism"
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
    print("\27[1;32mALL 3D ENGINE TESTS PASSED!\27[0m")
else
    os.exit(1)
end
