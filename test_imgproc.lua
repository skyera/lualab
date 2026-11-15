#!/usr/bin/env luajit
-- test_imgproc.lua: black-box tests for imgproc.lua. Runs the script as a
-- subprocess, then checks its exit status, its message, and the file it wrote.

local SCRIPT_PATH = "imgproc.lua"
local INTERPRETER = arg[-1] or "luajit"

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

--- Runs imgproc.lua with one output path. Returns whether it exited 0, and
--- everything it printed (stdout and stderr together).
local function run_imgproc(output_path)
    local log_path = os.tmpname()
    local command = string.format(
        '"%s" %s "%s" > "%s" 2>&1',
        INTERPRETER,
        SCRIPT_PATH,
        output_path,
        log_path
    )
    local status = os.execute(command)
    local printed = read_file(log_path)
    os.remove(log_path)
    return status == 0, printed
end

local function assert_contains(text, expected)
    local found = text:find(expected, 1, true)
    assert(found, "expected '" .. expected .. "' in: " .. text)
end

local function test_missing_directory()
    local output_path = "/nonexistent-imgproc-test/out.ppm"
    local succeeded, printed = run_imgproc(output_path)
    assert(not succeeded, "expected a nonzero exit, printed: " .. printed)
    assert_contains(printed, "error: cannot open for writing: " .. output_path)
    assert_contains(printed, "hint: ")
    local claimed_success = printed:find("wrote ", 1, true)
    assert(not claimed_success, "printed success after failing: " .. printed)
end

local function test_success_run()
    local output_path = os.tmpname()
    local succeeded, printed = run_imgproc(output_path)
    os.remove(output_path)
    assert(succeeded, "expected exit 0, printed: " .. printed)
    local expected = "wrote " .. output_path .. " (256x256, 196623 bytes)\n"
    assert(printed == expected, "unexpected message: " .. printed)
end

test_success_run()
test_missing_directory()
print("test_imgproc: all tests passed")
