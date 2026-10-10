-- A scan worker isolates blocking network lookups from the HTTP server.
local ffi = require("ffi")
local json = require("json")
local windows = ffi.os == "Windows"
local kernel
if windows then
    ffi.cdef[[
        typedef struct {
            uint32_t cb; char *reserved; char *desktop; char *title;
            uint32_t x, y, x_size, y_size, x_chars, y_chars, fill, flags;
            uint16_t show, reserved_size; uint8_t *reserved_data;
            void *stdin_handle; void *stdout_handle; void *stderr_handle;
        } LAN_STARTUPINFOA;
        typedef struct { void *process; void *thread; uint32_t pid, tid; } LAN_PROCESS_INFORMATION;
        int CreateProcessA(const char *, char *, void *, void *, int, uint32_t,
            void *, const char *, LAN_STARTUPINFOA *, LAN_PROCESS_INFORMATION *);
        uint32_t WaitForSingleObject(void *, uint32_t);
        int GetExitCodeProcess(void *, uint32_t *);
        int TerminateProcess(void *, unsigned int);
        int CloseHandle(void *);
        int MoveFileExA(const char *, const char *, unsigned long);
    ]]
    kernel = ffi.load("kernel32")
else
    ffi.cdef[[
        int fork(void);
        int execvp(const char *, char *const []);
        void _exit(int);
        int waitpid(int, int *, int);
        int kill(int, int);
        int getpid(void);
        int getppid(void);
    ]]
    if ffi.os == "Linux" then
        ffi.cdef[[int prctl(int, unsigned long, unsigned long, unsigned long, unsigned long);]]
    end
end

local function write_update(path, data)
    local ok, content = pcall(json.encode, data)
    if not ok then return nil, content end
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "w")
    if not file then return nil, err end
    local written, write_error = file:write(content)
    local closed, close_error = file:close()
    if not written or not closed then
        os.remove(temporary)
        return nil, write_error or close_error
    end
    local replaced, replace_error
    if windows then
        replaced = kernel.MoveFileExA(temporary, path, 9) ~= 0
        replace_error = "Could not replace worker snapshot"
    else
        replaced, replace_error = os.rename(temporary, path)
    end
    if not replaced then os.remove(temporary); return nil, replace_error end
    return true
end

local function read_update(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return nil
end

-- Windows argv quoting: backslashes are doubled only before quotes or the final quote.
local function quote_windows(argument)
    return '"' .. argument:gsub('(\\*)"', '%1%1\\"'):gsub('(\\+)$', '%1%1') .. '"'
end

local function launch(arguments)
    if windows then
        local parts = {}
        for _, argument in ipairs(arguments) do parts[#parts + 1] = quote_windows(argument) end
        local command = table.concat(parts, " ")
        local buffer = ffi.new("char[?]", #command + 1, command)
        local startup = ffi.new("LAN_STARTUPINFOA")
        startup.cb = ffi.sizeof(startup)
        local process = ffi.new("LAN_PROCESS_INFORMATION")
        if kernel.CreateProcessA(nil, buffer, nil, nil, 0, 0, nil, nil, startup, process) == 0 then
            return nil, "Could not launch scan worker"
        end
        kernel.CloseHandle(process.thread)
        return {handle = process.process}
    end
    local argv = ffi.new("char *[?]", #arguments + 1)
    for i, argument in ipairs(arguments) do argv[i - 1] = ffi.cast("char *", argument) end
    local parent = ffi.C.getpid()
    local pid = ffi.C.fork()
    if pid < 0 then return nil, "Could not fork scan worker" end
    if pid == 0 then
        if ffi.os == "Linux" then
            ffi.C.prctl(1, 9, 0, 0, 0) -- Kill the worker if its server disappears.
            if ffi.C.getppid() ~= parent then ffi.C._exit(1) end
        end
        ffi.C.execvp(arguments[1], argv)
        ffi.C._exit(127)
    end
    return {pid = tonumber(pid)}
end

local function poll_process(process)
    if windows then
        local wait = kernel.WaitForSingleObject(process.handle, 0)
        if wait == 258 then return false end -- WAIT_TIMEOUT
        local code = ffi.new("uint32_t[1]")
        local ok = kernel.GetExitCodeProcess(process.handle, code)
        kernel.CloseHandle(process.handle)
        return true, ok ~= 0 and tonumber(code[0]) or -1
    end
    local status = ffi.new("int[1]")
    local pid = ffi.C.waitpid(process.pid, status, 1) -- WNOHANG
    if pid == 0 then return false end
    if pid < 0 and ffi.errno() == 4 then return false end -- EINTR: retry without losing the worker.
    if pid < 0 then return true, -1 end
    local raw = tonumber(status[0])
    return true, raw % 128 == 0 and math.floor(raw / 256) or -1
end

local function terminate(process)
    if windows then
        if kernel.TerminateProcess(process.handle, 1) == 0 then return nil, "Could not stop scan worker" end
    elseif ffi.C.kill(process.pid, 9) ~= 0 then
        return nil, "Could not stop scan worker"
    end
    return true
end

local function new(options)
    local manager = {status = {id = 0, state = "idle", phase = "idle", completed = 0, total = 0}}
    local active

    local function cleanup()
        for _, suffix in ipairs({"", ".tmp", ".progress", ".progress.tmp", ".result", ".result.tmp"}) do
            os.remove(active.path .. suffix)
        end
        active = nil
    end

    function manager:start()
        self:poll()
        if active then return false, self.status end
        local path = os.tmpname()
        local ok, err = write_update(path, options.input())
        self.status = {id = self.status.id + 1, state = "running", phase = "starting", completed = 0,
            total = 0, started_at = os.time()}
        if not ok then
            os.remove(path)
            self.status.state, self.status.error = "failed", tostring(err)
            return nil, self.status
        end
        local arguments = {}
        for _, argument in ipairs(options.command) do arguments[#arguments + 1] = argument end
        arguments[#arguments + 1] = path
        local process, launch_error = launch(arguments)
        if not process then
            os.remove(path)
            self.status.state, self.status.error = "failed", tostring(launch_error)
            return nil, self.status
        end
        active = {process = process, path = path}
        return true, self.status
    end

    function manager:poll()
        if not active then return self.status end
        local progress = read_update(active.path .. ".progress")
        if progress and self.status.state == "running" then
            self.status.phase = progress.phase
            self.status.completed, self.status.total = progress.completed, progress.total
            self.status.current_ip = progress.current_ip
        end
        local done, exit_code = poll_process(active.process)
        if not done then return self.status end
        self.status.finished_at = os.time()
        if self.status.state ~= "cancelling" then
            local result = read_update(active.path .. ".result")
            if exit_code == 0 and result and type(result.devices) == "table" and
               type(result.subnet) == "string" and type(result.finished_at) == "number" then
                local ok, err = pcall(options.complete, result)
                self.status.state = ok and "completed" or "failed"
                self.status.error = not ok and tostring(err) or result.error
                self.status.completed = self.status.total
            else
                self.status.state = "failed"
                self.status.error = result and result.error or ("Scan worker exited without results (code " .. exit_code .. ")")
            end
        else
            self.status.state = "cancelled"
        end
        cleanup()
        return self.status
    end

    function manager:cancel()
        self:poll()
        if not active then return false, self.status end
        if self.status.state == "cancelling" then return true, self.status end
        local ok, err = terminate(active.process)
        if not ok then
            -- The worker may have exited between poll and termination.
            self:poll()
            if active then return nil, err end
            return false, self.status
        end
        self.status.state = "cancelling"
        self:poll()
        return true, self.status
    end

    return manager
end

local function executable()
    -- LuaJIT keeps its executable at the lowest negative argv index, even with flags.
    local index = -1
    for key in pairs(arg or {}) do
        if type(key) == "number" and key < index then index = key end
    end
    return arg and arg[index] or "luajit"
end

return {new = new, write_update = write_update, read_update = read_update,
    quote_windows = quote_windows, executable = executable}
