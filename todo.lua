-- Lua todo
function load_tasks()
    local tasks = {}
    local file = io.open("tasks.txt", "r")
    if file then
        for line in file:lines() do
        end
    end
    return tasks
end


function save_tasks(tasks)
end

function display_tasks(tasks)
end

function main()
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
