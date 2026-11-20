#!/usr/bin/env luajit
-- test_oop_todo.lua: index lookup tests for Todo:done, :toggle, :remove

local Todo = require("oop_todo").Todo

local FIXTURE = "0; a\n1; b\n0; c\n"
local INVALID_INDEXES = { 0, -1, 4, "abc", "", "1.5" }
local INDEX_METHODS = { "done", "toggle", "remove" }

local tests_run = 0
local tests_passed = 0

local function check(condition, description)
    tests_run = tests_run + 1
    if condition then
        tests_passed = tests_passed + 1
        print("  [PASS] " .. description)
    else
        print("  [FAIL] " .. description)
    end
end

local function read_file(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

--- Write FIXTURE to path and return a Todo loaded from it.
local function make_todo(path)
    local file = assert(io.open(path, "w"))
    file:write(FIXTURE)
    file:close()
    return Todo(path)
end

--- Check that method(index) fails with the standard error message
--- and leaves the saved file unchanged.
local function check_rejected(path, method, index)
    local todo = make_todo(path)
    local ok, err = todo[method](todo, index)
    local expected = "No such task at index: " .. tostring(index)
    local label = string.format("%s(%q)", method, tostring(index))
    check(ok == false and err == expected, label .. " returns the error")
    check(read_file(path) == FIXTURE, label .. " leaves the file unchanged")
end

local path = os.tmpname()

print("Test 1: a valid index updates the task and the file")
do
    local todo = make_todo(path)
    check(todo:done(1) == true, "done(1) returns true")
    check(read_file(path) == "1; a\n1; b\n0; c\n", "done(1) is saved")

    todo = make_todo(path)
    check(todo:toggle("2") == true, "toggle(\"2\") accepts a numeric string")
    check(read_file(path) == "0; a\n0; b\n0; c\n", "toggle(\"2\") is saved")

    todo = make_todo(path)
    local ok, removed = todo:remove(3)
    check(ok and removed.text == "c", "remove(3) returns the removed task")
    check(read_file(path) == "0; a\n1; b\n", "remove(3) is saved")
end

print("Test 2: an invalid index is rejected and changes nothing")
for _, method in ipairs(INDEX_METHODS) do
    for _, index in ipairs(INVALID_INDEXES) do
        check_rejected(path, method, index)
    end
    -- nil cannot be stored in INVALID_INDEXES, so it is checked here.
    check_rejected(path, method, nil)
end

os.remove(path)
print(string.format("%d / %d passed", tests_passed, tests_run))
if tests_passed ~= tests_run then
    os.exit(1)
end
