#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_workers.lua
-- Real fork/pipe coverage for bounded concurrency, cancellation and worker failure.
--------------------------------------------------------------------------------

local directory = (arg[0]:match('^(.*)/') or '.') .. '/..'
package.path = directory .. '/?.lua;' .. package.path

local ffi = require('ffi')
local Pool = require('workers')

ffi.cdef[[int usleep(unsigned int);]]

--------------------------------------------------------------------------------
-- Test Harness & Concurrency Fixtures
--------------------------------------------------------------------------------

local count = 0

local function test(name, run)
    local pool = Pool.new(nil, { max_workers = 2, capacity = 3, timeout = 5 })
    local ok, err = pcall(run, pool)
    pool:close()
    assert(ok, name .. ': ' .. tostring(err))
    count = count + 1
    print('ok ' .. count .. ' - ' .. name)
end

local function start(pool, owner, run, timeout)
    local output = {}
    local thread = coroutine.create(function()
        output.value, output.error = pool:run(owner, run, timeout)
    end)
    assert(coroutine.resume(thread))
    return { thread = thread, output = output }
end

local function finish(pool, tasks)
    local deadline = os.time() + 10
    while true do
        pool:tick()
        local active = false
        for _, task in ipairs(tasks) do
            if coroutine.status(task.thread) ~= 'dead' then
                active = true
                assert(coroutine.resume(task.thread))
            end
        end
        if not active then
            return
        end
        assert(os.time() < deadline, 'worker test timed out')
        ffi.C.usleep(10000)
    end
end

--------------------------------------------------------------------------------
-- Worker Concurrency & IPC Tests
--------------------------------------------------------------------------------

test('bounded running workers, queue overflow and complete large IPC results', function(pool)
    local function slow()
        ffi.C.usleep(200000)
        return string.rep('字', 100000)
    end
    local tasks = {}
    for index = 1, 4 do
        tasks[index] = start(pool, index, slow)
    end
    assert(#pool.jobs == 3 and pool.jobs[1].pid and pool.jobs[2].pid and not pool.jobs[3].pid)
    assert(tasks[4].output.error:find('queue is full', 1, true))
    finish(pool, tasks)
    for index = 1, 3 do
        assert(tasks[index].output.value == string.rep('字', 100000))
    end
    assert(#pool.jobs == 0)
end)

test('exceptions, abnormal child exits and oversized results become readable errors', function(pool)
    for _, run in ipairs({
        function()
            error('private implementation error')
        end,
        function()
            ffi.C._exit(7)
        end,
        function()
            return string.rep('x', 3 * 1024 * 1024)
        end,
    }) do
        local task = start(pool, {}, run)
        finish(pool, { task })
        assert(not task.output.value and task.output.error)
        assert(not task.output.error:find('private implementation error', 1, true))
    end
end)

--------------------------------------------------------------------------------
-- Timeouts & Worker Lifecycle Tests
--------------------------------------------------------------------------------

test('deadlines and owner cancellation terminate and reap children', function(pool)
    local task = start(pool, 'timeout', function()
        ffi.C.usleep(5000000)
        return 'late'
    end, 1)
    local pid = pool.jobs[1].pid
    finish(pool, { task })
    assert(task.output.error:find('timed out', 1, true))
    assert(ffi.C.waitpid(pid, ffi.new('int[1]'), 1) == -1 and ffi.errno() == 10)
    task = start(pool, 'cancel', function()
        ffi.C.usleep(5000000)
        return 'late'
    end)
    pid = pool.jobs[1].pid
    pool:cancel('cancel')
    finish(pool, { task })
    while #pool.jobs > 0 do
        pool:tick()
        ffi.C.usleep(1000)
    end
    assert(task.output.error == 'Lookup cancelled.')
    assert(ffi.C.waitpid(pid, ffi.new('int[1]'), 1) == -1 and ffi.errno() == 10)
end)

test('shutdown reaps all active workers and clears queued jobs', function(pool)
    for index = 1, 3 do
        start(pool, index, function()
            ffi.C.usleep(5000000)
        end)
    end
    local pids = { pool.jobs[1].pid, pool.jobs[2].pid }
    pool:close()
    assert(#pool.jobs == 0)
    for _, pid in ipairs(pids) do
        assert(ffi.C.waitpid(pid, ffi.new('int[1]'), 1) == -1 and ffi.errno() == 10)
    end
end)

print('1..' .. count)
