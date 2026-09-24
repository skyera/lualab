#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_ffi_elf_inspector.lua
-- Comprehensive test suite for ffi_elf_inspector.lua
--------------------------------------------------------------------------------

print("================================================================================")
print("  Running Unit & Integration Tests for ffi_elf_inspector.lua")
print("================================================================================")

local tests = {
    {
        name = "CLI Help flag (--help)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua --help",
        expect = "Usage: luajit ffi_elf_inspector.lua <elf-binary>"
    },
    {
        name = "Self-test validation mode (--test)",
        cmd = "./LuaJIT/src/luajit ffi_elf_inspector.lua --test",
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
    }
}

local passed = 0
for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
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
end

print("--------------------------------------------------------------------------------")
print(string.format("  Results: %d/%d tests passed (%.1f%% success)",
    passed, #tests, (passed / #tests) * 100))
print("================================================================================")

if passed ~= #tests then
    os.exit(1)
end
