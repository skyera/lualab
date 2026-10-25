#!/usr/bin/env luajit
-- Git subprocess capture with separate arguments, visible diagnostics, and exit status.
local ffi = require("ffi")
local M = {}

-- =========================================================================
-- Platform process execution
-- =========================================================================
if ffi.os == "Windows" then
    ffi.cdef[[
        typedef struct {
            unsigned long size;
            void *descriptor;
            int inherit;
        } lg_security_attributes;
        typedef struct {
            unsigned long size;
            uint16_t *reserved, *desktop, *title;
            unsigned long x, y, x_size, y_size, x_chars, y_chars, fill, flags;
            unsigned short show, reserved_size;
            unsigned char *reserved_bytes;
            void *input, *output, *error;
        } lg_startup_info;
        typedef struct { void *process, *thread; unsigned long process_id, thread_id; } lg_process_info;
        int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, uint16_t *, int);
        int __stdcall CreatePipe(void **, void **, lg_security_attributes *, unsigned long);
        int __stdcall SetHandleInformation(void *, unsigned long, unsigned long);
        int __stdcall CreateProcessW(const uint16_t *, uint16_t *, void *, void *, int,
            unsigned long, void *, const uint16_t *, lg_startup_info *, lg_process_info *);
        void * __stdcall GetStdHandle(unsigned long);
        int __stdcall ReadFile(void *, void *, unsigned long, unsigned long *, void *);
        unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
        int __stdcall GetExitCodeProcess(void *, unsigned long *);
        int __stdcall CloseHandle(void *);
        unsigned long __stdcall GetLastError(void);
    ]]
    local kernel = ffi.load("kernel32")

    function M.run(argv, allowed_exit)
        local parts = {}
        for _, value in ipairs(argv) do
            assert(not value:find("%z"), "Command argument contains NUL")
            parts[#parts + 1] = '"' .. value:gsub('(\\*)"', '%1%1\\"'):gsub('(\\+)$', '%1%1') .. '"'
        end
        local text = table.concat(parts, " ")
        local count = kernel.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
        if count == 0 then
            return nil, "Invalid UTF-8 command arguments"
        end
        local command = ffi.new("uint16_t[?]", count + 1)
        if kernel.MultiByteToWideChar(65001, 8, text, #text, command, count) ~= count then
            return nil, "Cannot encode command arguments"
        end
        local handles = ffi.new("void *[2]")
        local security = ffi.new("lg_security_attributes")
        security.size = ffi.sizeof(security)
        security.inherit = 1
        if kernel.CreatePipe(handles, handles + 1, security, 0) == 0 then
            return nil, "Cannot create Git output pipe: Windows error " .. kernel.GetLastError()
        end
        if kernel.SetHandleInformation(handles[0], 1, 0) == 0 then
            local code = kernel.GetLastError()
            kernel.CloseHandle(handles[0])
            kernel.CloseHandle(handles[1])
            return nil, "Cannot configure Git output pipe: Windows error " .. code
        end
        local startup = ffi.new("lg_startup_info")
        local process = ffi.new("lg_process_info")
        startup.size = ffi.sizeof(startup)
        startup.flags = 0x100
        startup.input = kernel.GetStdHandle(0xfffffff6)
        startup.output = handles[1]
        startup.error = handles[1]
        local created = kernel.CreateProcessW(nil, command, nil, nil, 1, 0x08000000,
            nil, nil, startup, process)
        local create_error = kernel.GetLastError()
        kernel.CloseHandle(handles[1])
        if created == 0 then
            kernel.CloseHandle(handles[0])
            return nil, "Cannot start " .. argv[1] .. ": Windows error " .. create_error .. ". Check PATH."
        end
        kernel.CloseHandle(process.thread)
        local chunks = {}
        local buffer = ffi.new("char[8192]")
        local bytes = ffi.new("unsigned long[1]")
        local read_error
        while true do
            local read = kernel.ReadFile(handles[0], buffer, 8192, bytes, nil)
            if read == 0 then
                local code = tonumber(kernel.GetLastError())
                if code ~= 109 then -- ERROR_BROKEN_PIPE is normal EOF.
                    read_error = "Cannot read Git output: Windows error " .. code
                end
                break
            end
            if bytes[0] == 0 then
                break
            end
            chunks[#chunks + 1] = ffi.string(buffer, bytes[0])
        end
        kernel.CloseHandle(handles[0])
        local waited = kernel.WaitForSingleObject(process.process, 0xffffffff)
        local code = ffi.new("unsigned long[1]")
        local got_code = kernel.GetExitCodeProcess(process.process, code)
        kernel.CloseHandle(process.process)
        local output = table.concat(chunks)
        if read_error then
            return nil, read_error
        end
        if waited ~= 0 or got_code == 0 then
            return nil, "Cannot read Git exit status"
        end
        if code[0] ~= 0 and code[0] ~= allowed_exit then
            return nil, "Git failed (exit " .. tonumber(code[0]) .. "): " .. output
        end
        return output
    end
else
    function M.run(argv, allowed_exit)
        local parts = {}
        for _, value in ipairs(argv) do
            assert(not value:find("%z"), "Command argument contains NUL")
            parts[#parts + 1] = "'" .. value:gsub("'", "'\\''") .. "'"
        end
        -- Capture the exit status explicitly: LuaJIT's popen close varies by platform.
        local pipe, err = io.popen(table.concat(parts, " ") .. " 2>&1; printf '\\nLG_EXIT:%d' $?", "r")
        if not pipe then
            return nil, "Cannot launch Git: " .. tostring(err)
        end
        local result = pipe:read("*a")
        pipe:close()
        local output, code = (result or ""):match("^(.*)\nLG_EXIT:(%d+)$")
        if not code then
            return nil, "Cannot read Git exit status: " .. tostring(result)
        end
        if tonumber(code) ~= 0 and tonumber(code) ~= allowed_exit then
            return nil, "Git failed (exit " .. code .. "): " .. output
        end
        return output
    end
end

return M
