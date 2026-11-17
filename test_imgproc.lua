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

local function write_file(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    assert(file:close())
end

--- Runs imgproc.lua with the given argument text. Returns whether it exited
--- 0, and everything it printed (stdout and stderr together).
local function run_command(arguments)
    local log_path = os.tmpname()
    local command = string.format(
        '"%s" %s %s > "%s" 2>&1',
        INTERPRETER,
        SCRIPT_PATH,
        arguments,
        log_path
    )
    local status = os.execute(command)
    local printed = read_file(log_path)
    os.remove(log_path)
    return status == 0, printed
end

local function run_imgproc(output_path)
    return run_command('"' .. output_path .. '"')
end

local function run_info(image_path)
    return run_command('info "' .. image_path .. '"')
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

local function test_info_round_trip()
    local image_path = os.tmpname()
    assert(run_imgproc(image_path))
    local succeeded, printed = run_info(image_path)
    os.remove(image_path)
    assert(succeeded, "expected exit 0, printed: " .. printed)
    local expected = image_path
        .. ": 256x256, average color 127.5 127.5 128.0\n"
    assert(printed == expected, "unexpected message: " .. printed)
end

local BAD_FILES = {
    { content = "not an image", expected = "no binary PPM (P6) header found" },
    { content = "P6\n2 2\n65535\nxxxxxxxxxxxx", expected = "max value 65535" },
    { content = "P6\n0 5\n255\n", expected = "invalid size 0x5" },
    { content = "P6\n2 3\n255\n0123456789", expected = "10 of 18 bytes" },
}

local function test_info_rejects_bad_files()
    for _, bad_file in ipairs(BAD_FILES) do
        local image_path = os.tmpname()
        write_file(image_path, bad_file.content)
        local succeeded, printed = run_info(image_path)
        os.remove(image_path)
        assert(not succeeded, "expected a nonzero exit: " .. printed)
        assert_contains(printed, "error: " .. image_path .. ": ")
        assert_contains(printed, bad_file.expected)
        assert_contains(printed, "hint: expected an 8-bit binary PPM")
    end
end

local function test_info_missing_file()
    local image_path = "/nonexistent-imgproc-test/in.ppm"
    local succeeded, printed = run_info(image_path)
    assert(not succeeded, "expected a nonzero exit: " .. printed)
    assert_contains(printed, "error: cannot open for reading: " .. image_path)
    assert_contains(printed, "hint: check that the file exists")
end

test_success_run()
test_missing_directory()
test_info_round_trip()
test_info_rejects_bad_files()
test_info_missing_file()
print("test_imgproc: all tests passed")
