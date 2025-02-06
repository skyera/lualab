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
end

main()
