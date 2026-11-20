#!/usr/bin/env luajit
-- ============================================================================
-- OOP Todo List Manager (Task & Todo Classes)
-- ============================================================================

local string_format = string.format
local table_insert = table.insert
local table_remove = table.remove
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local type = type
local setmetatable = setmetatable

-- ===========================================================================
-- Class 1: Task (Represents a single to do item)

local Task = {}
Task.__index = Task

setmetatable(Task, {
    __call = function(cls, ...)
        return cls:new(...)
    end
})

function Task:new(text, done)
    if type(text) ~= "string" or text:match("^%s*$") then
        return nil, "Task text cannot be empty"
    end

    local instance = setmetatable({}, self)
    instance.text = text:match("^%s*(.-)%s*$")
    instance.done = (done == true)
    return instance
end

function Task:complete()
    self.done = true
    return self
end

function Task:toggle()
    self.done = not self.done
    return self
end

function Task:__tostring()
    local status = self.done and "[x]" or "[ ]"
    return string_format("%s %s", status, self.text)
end

-- ============================================================================
-- Class 2: Todo (Manages a collection of Task objects & persistence)
local Todo = {}
Todo.__index = Todo

setmetatable(Todo, {
    __call = function(cls, ...)
        return cls:new(...)
    end
})

function Todo:new(filename)
    local instance = setmetatable({}, self)
    instance.tasks = {}
    instance.filename = filename or "tasks.txt"
    instance:load()
    return instance
end

--- Convert index (a number or numeric string) to a valid task position.
--- Returns the position, or nil and an error message when no task exists
--- at that index.
local function find_task_position(todo, index)
    local position = tonumber(index)
    if not position or not todo.tasks[position] then
        return nil, string_format(
            "No such task at index: %s",
            tostring(index)
        )
    end
    return position
end

function Todo:count()
    return #self.tasks
end

function Todo:add(text)
    local task, err = Task(text, false)
    if not task then
        return false, err
    end
    table_insert(self.tasks, task)
    local ok, save_err = self:save()
    if not ok then
        return false, save_err
    end
    return true, task
end

function Todo:done(index)
    local position, err = find_task_position(self, index)
    if not position then
        return false, err
    end
    self.tasks[position]:complete()
    return self:save()
end

function Todo:toggle(index)
    local position, err = find_task_position(self, index)
    if not position then
        return false, err
    end
    self.tasks[position]:toggle()
    return self:save()
end

function Todo:remove(index)
    local position, find_err = find_task_position(self, index)
    if not position then
        return false, find_err
    end
    local removed = table_remove(self.tasks, position)
    local ok, err = self:save()
    if not ok then
        return false, err
    end
    return true, removed
end

function Todo:save()
    local f, err = io.open(self.filename, "w")
    if not f then
        return false, string_format(
            "Failed to open '%s' for writing: %s",
            self.filename,
            tostring(err)
        )
    end
    for _, task in ipairs(self.tasks) do
        f:write(string_format("%s; %s\n", task.done and "1" or "0", task.text))
    end
    f:close()
    return true
end

function Todo:load()
    self.tasks = {}
    local f = io.open(self.filename, "r")
    if not f then
        return false
    end

    for line in f:lines() do
        local done_flag, text = line:match("^(%d);%s*(.+)$")
        if done_flag and text then
            local task = Task(text, done_flag == "1")
            if task then
                table_insert(self.tasks, task)
            end
        end
    end
    f:close()
    return true
end

function Todo:list()
    if #self.tasks == 0 then
        print("No tasks in list")
        return
    end

    for i, task in ipairs(self.tasks) do
        print(string_format("%d. %s", i, tostring(task)))
    end
end

-- ============================================================================
-- Step 3: Standalone Interactive CLI & Module Export
-- Run the CLI only when this file is the script being run. When it is
-- loaded with require, arg[0] names the requiring script instead. The
-- file name is compared exactly, so test_oop_todo.lua does not match, and
-- no stack-depth check is needed (it breaks under debugger wrappers).
local script_name = arg and arg[0] and arg[0]:match("[^/\\]+$")
local is_standalone = script_name == "oop_todo.lua"
    or script_name == "oop_todo"

if is_standalone then
    local filename = (arg and arg[1]) or "tasks.txt"
    local todo = Todo(filename)
    print(string_format("Loaded %d task(s) from %s", todo:count(), filename))

    while true do
        io.write("\nCommands: add <task>, done <num>, toggle <num>, rm <num>, ",
            "list, quit\n> ")
        io.flush()
        local input = io.read()
        if not input then
            break
        end
        local cmd, param = input:match("^(%S+)%s*(.*)$")

        if cmd == "add" then
            local ok, res = todo:add(param)
            if ok then
                print("Added:", tostring(res))
            else
                print("Error:", res)
            end
        elseif cmd == "done" then
            local ok, err = todo:done(param)
            if not ok then
                print("Error:", err)
            end
        elseif cmd == "toggle" then
            local ok, err = todo:toggle(param)
            if not ok then
                print("Error:", err)
            end
        elseif cmd == "rm" or cmd == "remove" then
            local ok, res = todo:remove(param)
            if ok then
                print("Removed:", tostring(res))
            else
                print("Error:", res)
            end
        elseif cmd == "list" or cmd == "ls" then
            todo:list()
        elseif cmd == "quit" or cmd == "q" then
            break
        elseif cmd then
            print("Unknown command:", cmd)
        end
    end
end

return {
    Task = Task,
    Todo = Todo
}
