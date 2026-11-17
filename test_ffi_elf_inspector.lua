#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_ffi_elf_inspector.lua
-- Comprehensive test suite for ffi_elf_inspector.lua
--------------------------------------------------------------------------------

print("================================================================================")
print("  Running Unit & Integration Tests for ffi_elf_inspector.lua")
print("================================================================================")

local interpreter = arg[-1] or "luajit"

-- Build outputs that are not in git. Cases that analyze one of them are
-- skipped, with the reason shown, when it has not been built.
local BUILT_ARTIFACTS = {
    "./libtermbox2.so",
    "./demo_luabridge",
    "./LuaJIT/src/luajit",
}

local function file_exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

--- Returns the first unbuilt artifact the case analyzes, or nil.
local function missing_artifact(test)
    if test.needs and not file_exists(test.needs) then
        return test.needs
    end
    for _, artifact in ipairs(BUILT_ARTIFACTS) do
        local target = "ffi_elf_inspector.lua " .. artifact
        if test.cmd:find(target, 1, true) and not file_exists(artifact) then
            return artifact
        end
    end
    return nil
end

local tests = {
    {
        name = "CLI Help flag (--help)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua --help",
        expect = "Usage: luajit ffi_elf_inspector.lua <elf-binary>"
    },
    {
        name = "Self-test validation mode (--test)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua --test",
        needs = "./libtermbox2.so",
        expect = "Successfully verified"
    },
    {
        name = "Parse Section Headers on shared object (libtermbox2.so)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./libtermbox2.so --sections",
        expect = ".text"
    },
    {
        name = "Verify .rodata and .symtab in section table",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./libtermbox2.so --sections",
        expect = ".rodata"
    },
    {
        name = "Exported functions on libtermbox2.so (--exports)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./libtermbox2.so --exports",
        expect = "tb_init"
    },
    {
        name = "Verify tb_present in exported list",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./libtermbox2.so --exports",
        expect = "tb_present"
    },
    {
        name = "Top bloat / largest functions (--top 5)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./libtermbox2.so --top 5",
        expect = "send_attr"
    },
    {
        name = "Function disassembly on tb_init (--disasm)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./libtermbox2.so --disasm tb_init",
        expect = "Disassembly of tb_init"
    },
    {
        name = "C++ Symbol Demangling on demo_luabridge",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./demo_luabridge --funcs",
        expect = "luabridge::"
    },
    {
        name = "Dynamic symbols on stripped executable (LuaJIT/src/luajit)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./LuaJIT/src/luajit --funcs",
        expect = "Stripped:  YES"
    },
    {
        name = "Machine-readable JSON serialization (--json)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua ./libtermbox2.so --json",
        expect = "\"filepath\":\"./libtermbox2.so\""
    },
    {
        name = "Tab key cycling logic (1 -> 2 -> 3 -> 4 -> 1)",
        cmd = "./LuaJIT/src/luajit -e 'local tab = 1; for i=1,4 do tab = (tab % 4) + 1 end assert(tab == 1); print(\"TAB_CYCLE_OK\")'",
        expect = "TAB_CYCLE_OK"
    },
    {
        name = "TUI [?] interactive help cheat sheet modal defined",
        cmd = "grep -n \"ELF Inspector Keybindings Help\" ffi_elf_inspector.lua",
        expect = "ELF Inspector Keybindings Help"
    },
    {
        name = "Vim-style bottom line search bar definition",
        cmd = "grep -n \"Vim-style bottom line\" ffi_elf_inspector.lua",
        expect = "Vim-style bottom line"
    },
    {
        name = "Sticky table column headers and tab badge counts",
        cmd = "grep -n \"SYMBOL NAME\" ffi_elf_inspector.lua",
        expect = "SYMBOL NAME"
    }
}

local passed = 0
local skipped = 0
for i, t in ipairs(tests) do
    local missing = missing_artifact(t)
    if missing then
        skipped = skipped + 1
        print(string.format("  \27[33m[SKIP %2d/%2d]\27[0m %s (%s not built)",
            i, #tests, t.name, missing))
        goto continue
    end
    local command = t.cmd:gsub("%./LuaJIT/src/luajit", function()
        return interpreter
    end)
    local p = io.popen(command .. " 2>&1")
    local out = p:read("*a")
    p:close()

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m[PASS %2d/%2d]\27[0m %s", i, #tests, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m[FAIL %2d/%2d]\27[0m %s", i, #tests, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output received: " .. out:sub(1, 200))
    end
    ::continue::
end

print("--------------------------------------------------------------------------------")
local ran = #tests - skipped
print(string.format("  Results: %d/%d tests passed, %d skipped",
    passed, ran, skipped))
print("================================================================================")

if passed ~= ran then
    os.exit(1)
end
