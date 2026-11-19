#!/usr/bin/env luajit
-- Simple todo list manager
local Todo = {}
Todo.__index = Todo

function Todo:new(filename)
    local obj = {
        tasks = {},
        filename = filename or "tasks.txt"
    }
    setmetatable(obj, self)
    obj:load()
    return obj
end

function Todo:add(task)
    table.insert(self.tasks, {text=task, done=false})
    return self:save()
end

function Todo:done(index)
    if not self.tasks[index] then
        return nil, "no such task: " .. tostring(index)
    end
    self.tasks[index].done = true
    return self:save()
end

function Todo:save()
    local f, err = io.open(self.filename, "w")
    if not f then
        return nil, "save tasks: " .. err
    end
    for _, task in ipairs(self.tasks) do
        f:write((task.done and "1" or "0") .. "; " .. task.text .. "\n")
    end
    f:close()
    return true
end

function Todo:list()
    for i, task in ipairs(self.tasks) do
        local status = task.done and "[x]" or "[ ]"
        print(i .. ". " .. status .. " " .. task.text)
    end
end

function Todo:load()
    local f = io.open(self.filename, "r")
    if not f then
        return
    end
    for line in f:lines() do
        local done, text = line:match("^(%d);%s*(.+)$")
        if done and text then
            table.insert(self.tasks, {text=text, done=(done=="1")})
        end
    end
    f:close()
end

local function print_error_if_failed(ok, err)
    if not ok then
        io.stderr:write("error: ", err, "\n")
    end
end

-- main
local todo = Todo:new()
while true do
    io.write("\nCommands: add <task>, done <num>, list, quit\n> ")
    local input = io.read()
    if not input then
        break
    end
    local cmd, arg = input:match("^(%S+)%s*(.*)$")

    if cmd == "add" then
        print_error_if_failed(todo:add(arg))
    elseif cmd == "done" then
        print_error_if_failed(todo:done(tonumber(arg)))
    elseif cmd == "list" then
        todo:list()
    elseif cmd == "quit" then
        break
    else
        print("Unknown command:", cmd)
    end
end
