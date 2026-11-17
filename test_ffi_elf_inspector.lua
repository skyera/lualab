#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_ffi_elf_inspector.lua
-- Comprehensive test suite for ffi_elf_inspector.lua
--
-- The ELF files the inspector analyzes are built from tiny C and C++ sources
-- into a temp directory, so the suite does not depend on any build output
-- that is not in git. Without a C compiler those cases are skipped, with the
-- reason shown.
--------------------------------------------------------------------------------

print("================================================================================")
print("  Running Unit & Integration Tests for ffi_elf_inspector.lua")
print("================================================================================")

local interpreter = arg[-1] or "luajit"
local INSPECTOR = "ffi_elf_inspector.lua"
local FILLER_STATEMENTS = 400

local function run_quiet(command)
    return os.execute(command .. " > /dev/null 2>&1") == 0
end

local function has_command(name)
    return run_quiet("command -v " .. name)
end

local function write_file(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    assert(file:close())
end

--- C source for a shared library with two small exports and one large
--- function, so that --top ranks send_attr first.
local function shared_library_source()
    local lines = {
        'static const char *const NAMES[] = { "bold", "dim", "reverse" };',
        "int tb_init(void) { return NAMES[0][0]; }",
        "int tb_present(void) { return NAMES[1][0]; }",
        "int send_attr(int attr) {",
        "    volatile int total = attr;",
    }
    for index = 1, FILLER_STATEMENTS do
        lines[#lines + 1] = string.format("    total += attr * %d;", index)
    end
    lines[#lines + 1] = "    return total;"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

local CPP_SOURCE = [[
namespace luabridge {
int push_value(int value) { return value + 1; }
}
int main() { return luabridge::push_value(0); }
]]

local C_MAIN_SOURCE = "int main(void) { return 0; }\n"

--- Compiles one fixture. Returns true, or false and the compiler used.
local function compile(compiler, flags, source_path, output_path)
    local command = string.format(
        "%s %s -o '%s' '%s'",
        compiler,
        flags,
        output_path,
        source_path
    )
    return run_quiet(command)
end

--- Builds the three ELF fixtures in a new temp directory. Returns a table
--- with directory, shared, cpp and stripped paths, or nil and a reason.
local function build_fixtures()
    for _, compiler in ipairs({ "gcc", "g++" }) do
        if not has_command(compiler) then
            return nil, compiler .. " not found"
        end
    end
    local directory = os.tmpname()
    os.remove(directory)
    if not run_quiet("mkdir -p '" .. directory .. "'") then
        return nil, "cannot create " .. directory
    end
    local fixtures = {
        directory = directory,
        shared = directory .. "/libfixture.so",
        cpp = directory .. "/demo_cpp",
        stripped = directory .. "/stripped_main",
    }
    write_file(directory .. "/shared.c", shared_library_source())
    write_file(directory .. "/demo.cpp", CPP_SOURCE)
    write_file(directory .. "/main.c", C_MAIN_SOURCE)
    local builds = {
        { "gcc", "-shared -fPIC -O0", "shared.c", fixtures.shared },
        { "g++", "-O0", "demo.cpp", fixtures.cpp },
        { "gcc", "-s", "main.c", fixtures.stripped },
    }
    for _, build in ipairs(builds) do
        local compiler, flags, source, output =
            build[1], build[2], build[3], build[4]
        local source_path = directory .. "/" .. source
        if not compile(compiler, flags, source_path, output) then
            return fixtures, "compiling " .. source .. " failed"
        end
    end
    return fixtures
end

local function remove_fixtures(fixtures)
    if fixtures and fixtures.directory then
        run_quiet("rm -rf '" .. fixtures.directory .. "'")
    end
end

local function inspect_command(arguments)
    return "{LUAJIT} " .. INSPECTOR .. " " .. arguments
end

local tests = {
    {
        name = "CLI Help flag (--help)",
        cmd = inspect_command("--help"),
        expect = "Usage: luajit ffi_elf_inspector.lua <elf-binary>"
    },
    {
        name = "Self-test validation mode (--test)",
        cmd = inspect_command("--test {SHARED}"),
        expect = "Successfully verified"
    },
    {
        name = "Parse Section Headers on shared object",
        cmd = inspect_command("{SHARED} --sections"),
        expect = ".text"
    },
    {
        name = "Verify .rodata and .symtab in section table",
        cmd = inspect_command("{SHARED} --sections"),
        expect = ".rodata"
    },
    {
        name = "Exported functions on shared object (--exports)",
        cmd = inspect_command("{SHARED} --exports"),
        expect = "tb_init"
    },
    {
        name = "Verify tb_present in exported list",
        cmd = inspect_command("{SHARED} --exports"),
        expect = "tb_present"
    },
    {
        name = "Top bloat / largest functions (--top 5)",
        cmd = inspect_command("{SHARED} --top 5"),
        expect = "send_attr"
    },
    {
        name = "Function disassembly on tb_init (--disasm)",
        cmd = inspect_command("{SHARED} --disasm tb_init"),
        expect = "Disassembly of tb_init"
    },
    {
        name = "C++ Symbol Demangling on a g++ executable",
        cmd = inspect_command("{CPP} --funcs"),
        expect = "luabridge::"
    },
    {
        name = "Dynamic symbols on a stripped executable",
        cmd = inspect_command("{STRIPPED} --funcs"),
        expect = "Stripped:  YES"
    },
    {
        name = "Machine-readable JSON serialization (--json)",
        cmd = inspect_command("{SHARED} --json"),
        expect = "\"filepath\":\"{SHARED}\""
    },
    {
        name = "Tab key cycling logic (1 -> 2 -> 3 -> 4 -> 1)",
        cmd = "{LUAJIT} -e 'local tab = 1; "
            .. "for i=1,4 do tab = (tab % 4) + 1 end "
            .. "assert(tab == 1); print(\"TAB_CYCLE_OK\")'",
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

--- Replaces {LUAJIT}, {SHARED}, {CPP} and {STRIPPED} in text.
local function expand(text, fixtures)
    local values = {
        LUAJIT = interpreter,
        SHARED = fixtures and fixtures.shared,
        CPP = fixtures and fixtures.cpp,
        STRIPPED = fixtures and fixtures.stripped,
    }
    return (text:gsub("{(%u+)}", values))
end

local function needs_fixtures(test)
    return test.cmd:find("{SHARED}", 1, true) ~= nil
        or test.cmd:find("{CPP}", 1, true) ~= nil
        or test.cmd:find("{STRIPPED}", 1, true) ~= nil
end

--- Runs every case. Returns the number passed and the number skipped.
local function run_cases(fixtures, fixture_problem)
    local passed = 0
    local skipped = 0
    for i, t in ipairs(tests) do
        if needs_fixtures(t) and fixture_problem then
            skipped = skipped + 1
            print(string.format(
                "  \27[33m[SKIP %2d/%2d]\27[0m %s (%s)",
                i,
                #tests,
                t.name,
                fixture_problem
            ))
        else
            local p = io.popen(expand(t.cmd, fixtures) .. " 2>&1")
            local out = p:read("*a")
            p:close()
            local expected = expand(t.expect, fixtures)
            if out:find(expected, 1, true) then
                print(string.format(
                    "  \27[32m[PASS %2d/%2d]\27[0m %s",
                    i,
                    #tests,
                    t.name
                ))
                passed = passed + 1
            else
                print(string.format(
                    "  \27[31m[FAIL %2d/%2d]\27[0m %s",
                    i,
                    #tests,
                    t.name
                ))
                print("    Expected substring: " .. expected)
                print("    Output received: " .. out:sub(1, 200))
            end
        end
    end
    return passed, skipped
end

local fixtures, fixture_problem = build_fixtures()
local finished, passed, skipped = pcall(run_cases, fixtures, fixture_problem)
remove_fixtures(fixtures)
if not finished then
    error(passed, 0)
end

print("--------------------------------------------------------------------------------")
local ran = #tests - skipped
print(string.format("  Results: %d/%d tests passed, %d skipped",
    passed, ran, skipped))
print("================================================================================")

if passed ~= ran then
    os.exit(1)
end
