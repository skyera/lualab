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
end

function Todo:done(index)
    if self.tasks[index] then
        self.tasks[index].done = true
        self:save()
    else
        print("No such task:", index)
    end
end

function Todo:save()
    local f = io.open(self.filename, "w")
    for _, task in ipairs(self.tasks) do
        f:write((task.done and "1" or "0") .. "; " .. task.text .. "\n")
    end
    f:close()
end

function Todo:list()
    for i, task in ipairs(self.tasks) do
        local status = task.done and "[x]" or "[ ]"
        print(i .. ". " .. status .. " " .. task.text)
    end
end

function Todo:load()
    local f = io.open(self.filename, "r")
    if not f then return end
    for line in f:lines() do
        local done, text = line:match("^(%d);%s*(.+)$")
        table.insert(self.tasks, {text=text, done=="1"})
    end
    f:close()
end

-- main
local todo = Todo:new()
while true do
    io.write("\nCommands: add <task>, done <num>, list, quit\n> ")
    local input = io.read()
    if not input then break end
    local cmd, arg = input:match("^(%S+)%s*(.*)$")

    if cmd == "add" then
        todo:add(arg)
    elseif cmd == "done" then
        todo:done(tonumber(arg))
    elseif cmd == "list" then
        todo:list()
    elseif cmd == "quit" then
        break
    else
        print("Unknown command:", cmd)
    end
end
