local jobs = require("lan_scan_job")
local ffi = require("ffi")
if ffi.os == "Windows" then ffi.cdef[[void Sleep(unsigned long);]]
else ffi.cdef[[int usleep(unsigned int);]] end
local function pause()
    if ffi.os == "Windows" then ffi.C.Sleep(5) else ffi.C.usleep(5000) end
end
local function wait(manager, predicate)
    for _ = 1, 400 do
        local status = manager:poll()
        if predicate(status) then return status end
        pause()
    end
    error("Timed out waiting for scan worker")
end

local fixture_base = os.tmpname()
os.remove(fixture_base)
local fixture = fixture_base .. " worker 'quoted'.lua"
local script = [=[
local jobs = require("lan_scan_job")
local ffi = require("ffi")
if ffi.os == "Windows" then ffi.cdef[[void Sleep(unsigned long);]]
else ffi.cdef[[int usleep(unsigned int);]] end
local path = (...)
local input = assert(jobs.read_update(path))
for i = 1, 10 do
    assert(jobs.write_update(path .. ".progress", {phase = "devices", completed = i, total = 10, current_ip = path}))
    if ffi.os == "Windows" then ffi.C.Sleep(30) else ffi.C.usleep(30000) end
end
if input.crash then
    io.stderr:write("Expected test worker failure visible on stderr\n")
    assert(jobs.write_update(path .. ".result", {error = "Test worker failed"}))
    os.exit(1)
end
assert(jobs.write_update(path .. ".result", {devices = input.devices, subnet = "192.168.1.0/24", finished_at = os.time()}))
]=]
local file = assert(io.open(fixture, "w"))
assert(file:write(script)); assert(file:close())
local completed = 0
local crash = false
local manager = jobs.new({command = {jobs.executable(), fixture},
    input = function() return {devices = {}, crash = crash} end,
    complete = function(result) assert(#result.devices == 0); completed = completed + 1 end})

assert(manager.status.state == "idle")
assert(manager:start())
local duplicate, same = manager:start()
assert(duplicate == false and same.id == 1)
wait(manager, function(s) return s.completed > 0 end)
local snapshot = manager.status
assert(snapshot.phase == "devices" and snapshot.total == 10)
local cancelled_path = snapshot.current_ip
assert(manager:cancel())
assert(manager:start() == false or manager.status.id == 2) -- A reaped cancellation permits a new job.
if manager.status.id == 2 then assert(manager:cancel()) end
wait(manager, function(s) return s.state == "cancelled" end)
assert(completed == 0)
for _, suffix in ipairs({"", ".tmp", ".progress", ".result"}) do
    local leftover = io.open(cancelled_path .. suffix, "r")
    if leftover then leftover:close(); error("Cancelled job leaked " .. suffix) end
end
assert(manager:cancel() == false)
assert(manager:start())
local done = wait(manager, function(s) return s.state == "completed" end)
assert(done.completed == done.total and completed == 1)
assert(not jobs.read_update(done.current_ip))
assert(not jobs.read_update(done.current_ip .. ".result"))

crash = true
assert(manager:start())
local failed = wait(manager, function(s) return s.state == "failed" end)
assert(failed.error == "Test worker failed" and completed == 1)
local bad = jobs.new({command = {"/nonexistent/lan-scan-worker"}, input = function() return {} end, complete = function() error("Must not publish") end})
local launched = bad:start()
if launched then wait(bad, function(s) return s.state == "failed" end) end
assert(bad.status.state == "failed")

local apply_failure = jobs.new({command = {jobs.executable(), fixture}, input = function() return {devices = {}} end,
    complete = function() error("Could not apply scan") end})
assert(apply_failure:start())
assert(wait(apply_failure, function(s) return s.state == "failed" end).error:find("Could not apply scan"))
assert(not jobs.write_update("/nonexistent/lan-scan-progress", {}))

assert(jobs.quote_windows('C:\\path with spaces\\') == '"C:\\path with spaces\\\\"')
assert(jobs.quote_windows('a"b') == '"a\\"b"')
os.remove(fixture)
print("Background scan jobs: progress, duplicate requests, cancellation, restart, failure, and argv quoting PASS")
