-- Linux worker pool: blocking provider calls run in children with bounded IPC.
local ffi = require('ffi')
local json = require('json')
local jit = require('jit')
ffi.cdef[[
int fork(void);
int pipe(int [2]);
int fcntl(int, int, ...);
int close(int);
long read(int, void *, size_t);
long write(int, const void *, size_t);
int kill(int, int);
int waitpid(int, int *, int);
int getpid(void);
int getppid(void);
int prctl(int, unsigned long, unsigned long, unsigned long, unsigned long);
void _exit(int);
]]
local C = ffi.C
local MAX_RESULT = 2 * 1024 * 1024
local Pool = {}
Pool.__index = Pool

function Pool.new(close_inherited, options)
    options = options or {}
    return setmetatable({ jobs = {}, close_inherited = close_inherited,
        max_workers = options.max_workers or 4, capacity = options.capacity or 20,
        timeout = options.timeout or 45 }, Pool)
end

local function close_pipe(job)
    if job.fd then C.close(job.fd); job.fd = nil end
end

local function fail(job, message)
    job.done, job.result = true, { error = message }
    close_pipe(job)
    if job.pid then C.kill(job.pid, 9) end
end

function Pool:launch(job)
    local descriptors = ffi.new('int[2]')
    if C.pipe(descriptors) ~= 0 then fail(job, 'Could not start dictionary worker.'); return end
    local parent = C.getpid()
    local pid = C.fork()
    if pid == 0 then
        C.close(descriptors[0])
        for _, other in ipairs(self.jobs) do if other.fd then C.close(other.fd) end end
        if self.close_inherited then self.close_inherited() end
        C.prctl(1, 9, 0, 0, 0)
        if C.getppid() ~= parent then C._exit(1) end
        local ok, value, message = pcall(job.run)
        local encoded, data = pcall(json.encode, ok and { value = value, error = message }
            or { error = 'Dictionary lookup failed. Please try again.' })
        if not encoded or #data > MAX_RESULT then data = '{"error":"Dictionary response is too large."}' end
        local offset, pointer = 0, ffi.cast('const char *', data)
        while offset < #data do
            local bytes = tonumber(C.write(descriptors[1], pointer + offset, #data - offset))
            if bytes <= 0 then C._exit(1) end
            offset = offset + bytes
        end
        C.close(descriptors[1])
        C._exit(0)
    end
    C.close(descriptors[1])
    if pid < 0 then C.close(descriptors[0]); fail(job, 'Could not start dictionary worker.'); return end
    job.pid, job.fd, job.started = tonumber(pid), tonumber(descriptors[0]), os.time()
    job.run, job.chunks, job.size = nil, {}, 0
    if C.fcntl(job.fd, 4, ffi.new('int', 2048)) ~= 0 then fail(job, 'Could not configure dictionary worker.') end
end
jit.off(Pool.launch, true)

local function drain(job, buffer)
    if job.fd and not job.done then
        while true do
            local bytes = tonumber(C.read(job.fd, buffer, 65536))
            if bytes > 0 then
                job.size = job.size + bytes
                if job.size > MAX_RESULT then fail(job, 'Dictionary response is too large.'); break end
                job.chunks[#job.chunks + 1] = ffi.string(buffer, bytes)
            elseif bytes == 0 then
                close_pipe(job)
                break
            elseif ffi.errno() == 11 then break
            elseif ffi.errno() ~= 4 then fail(job, 'Dictionary worker failed.'); break end
        end
    end
end

function Pool:tick()
    local buffer = ffi.new('char[65536]')
    local running = 0
    for index = #self.jobs, 1, -1 do
        local job = self.jobs[index]
        if job.pid then
            if not job.done and os.time() - job.started >= job.timeout then
                fail(job, 'Dictionary lookup timed out. Please try again.')
            end
            drain(job, buffer)
            local status = ffi.new('int[1]')
            local reaped = C.waitpid(job.pid, status, 1)
            if reaped > 0 or (reaped < 0 and ffi.errno() ~= 4) then
                drain(job, buffer)
                if not job.done then
                    local ok, result = pcall(json.decode, table.concat(job.chunks))
                    job.done = true
                    job.result = ok and type(result) == 'table' and result
                        or { error = 'Dictionary worker failed. Please try again.' }
                end
                close_pipe(job)
                job.pid = nil
                table.remove(self.jobs, index)
            else running = running + 1 end
        elseif job.done then table.remove(self.jobs, index) end
    end
    for _, job in ipairs(self.jobs) do
        if not job.pid and not job.done and running < self.max_workers then
            self:launch(job)
            if job.pid then running = running + 1 end
        end
    end
end

function Pool:run(owner, run, timeout)
    self:tick()
    if #self.jobs >= self.capacity then return nil, 'Dictionary queue is full. Please try again.' end
    local job = { owner = owner, run = run, timeout = timeout or self.timeout }
    self.jobs[#self.jobs + 1] = job
    self:tick()
    while not job.done do coroutine.yield(job) end
    return job.result.value, job.result.error
end

function Pool:cancel(owner)
    for _, job in ipairs(self.jobs) do
        if job.owner == owner and not job.done then fail(job, 'Lookup cancelled.') end
    end
end

function Pool:close()
    for _, job in ipairs(self.jobs) do
        if job.pid then
            C.kill(job.pid, 9)
            local status = ffi.new('int[1]')
            while C.waitpid(job.pid, status, 0) < 0 and ffi.errno() == 4 do end
        end
        close_pipe(job)
    end
    self.jobs = {}
end
return Pool
