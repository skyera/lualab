-- Lua todo
local function load_tasks()
    local tasks = {}
    local file = io.open("tasks.txt", "r")
    if file then
        for line in file:lines() do
            table.insert(tasks, line)
        end
        file:close()
    end
    return tasks
end


local function save_tasks(tasks)
    local file = io.open("tasks.txt", "w")
    for _, task in ipairs(tasks) do
        file:write(task .. "\n")
    end
    file:close()
end

local function display_tasks(tasks)
    if #tasks == 0 then
        print("No tasks to display")
    else
        for i, task in ipairs(tasks) do
            print(i .. "." .. task)
        end
    end
end

local function main()
    print("My todo list")
    local tasks = load_tasks()

    while true do
        print("1. Add Task")
        print("2. View Tasks")
        print("3. Quit")
        local choice = tonumber(io.read())
        if choice == 1 then
            print("Enter task description:")
            local task = io.read()
            table.insert(tasks, task)
            save_tasks(tasks)
            print("Task added!")
        elseif choice == 2 then
            display_tasks(tasks)
        elseif choice == 3 then
            break
        else
            print("Invalid choice!")
        end
    end
end

main()
