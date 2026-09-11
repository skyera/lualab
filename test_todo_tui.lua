#!/usr/bin/env luajit
--[[
    test_todo_tui.lua
    Unit and integration tests for todo_tui.lua (todo_lite.lua).
]]

print("=== Running Unit Tests for todo_tui.lua (Todo TUI) ===")

-- Backup existing tasks file for idempotence
local db_backup = nil
local f_in = io.open("todo_tasks.json", "r")
if f_in then
    db_backup = f_in:read("*a")
    f_in:close()
end

local tests = {
    {
        name = "Help flag (--help)",
        cmd = "luajit todo_tui.lua --help",
        expect = "Terminal Task Manager (LuaJIT FFI Engine)"
    },
    {
        name = "Task listing (--list)",
        cmd = "luajit todo_tui.lua --list",
        expect = "TODO TASKS"
    },
    {
        name = "Add new task via CLI (--add)",
        cmd = "luajit todo_tui.lua --add \"Automated Test Task\" high Dev",
        expect = "Added task"
    },
    {
        name = "Verify added task in list",
        cmd = "luajit todo_tui.lua --list",
        expect = "Automated Test Task"
    },
    {
        name = "Snapshot non-interactive render (--snapshot)",
        cmd = "luajit todo_tui.lua --snapshot",
        expect = "TODO TUI"
    },
    {
        name = "Symlink todo_lite.lua check",
        cmd = "luajit todo_lite.lua --list",
        expect = "TODO TASKS"
    }
}

local passed = 0
for i, t in ipairs(tests) do
    local p = io.popen(t.cmd .. " 2>&1")
    local out = p:read("*a")
    p:close()

    if out:find(t.expect, 1, true) then
        print(string.format("  \27[32m✔ PASS [%d/%d]\27[0m: %s", i, #tests, t.name))
        passed = passed + 1
    else
        print(string.format("  \27[31m✘ FAIL [%d/%d]\27[0m: %s", i, #tests, t.name))
        print("    Expected substring: " .. t.expect)
        print("    Output preview: " .. out:sub(1, 200))
    end
end

-- Restore original tasks database if it existed
if db_backup then
    local f_out = io.open("todo_tasks.json", "w")
    if f_out then
        f_out:write(db_backup)
        f_out:close()
    end
end

print(string.format("\nTest Summary: %d / %d tests passed.", passed, #tests))
if passed == #tests then
    print("\27[1;32mALL TODO TUI TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
else
    os.exit(1)
end

