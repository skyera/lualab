-- Dependency-free startup guard: flushed phase messages, protected errors, and
-- cleanup of opened notebooks when initialization or serving fails.
local M = { running = false }
local phase, cleanups = 'Loading modules', {}

function M.report(message)
    phase = message
    if M.running then print('Leaf Wiki: ' .. message); io.stdout:flush() end
end

function M.warn(message)
    if M.running then
        io.stderr:write('Leaf Wiki warning: ' .. message .. '\n')
        io.stderr:flush()
    end
end

function M.track(notebook)
    if M.running then cleanups[#cleanups + 1] = function() notebook:close() end end
end

function M.launch(run)
    M.running = true
    phase, cleanups = 'Loading modules', {}
    local help = #arg == 1 and (arg[1] == '-h' or arg[1] == '--help')
    if not help then M.report(phase) end
    local ok, err = xpcall(run, debug.traceback)
    for index = #cleanups, 1, -1 do
        local closed, message = pcall(cleanups[index])
        if not closed and ok then ok, err = false, message end
    end
    cleanups, M.running = {}, false
    if not ok then
        io.stderr:write('\nLeaf Wiki failed during: ' .. phase .. '\n' .. tostring(err) .. '\n')
        io.stderr:flush()
    end
    return ok
end
return M
