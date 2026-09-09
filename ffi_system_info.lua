local ffi = require("ffi")

-- 1. Define C structures and functions
-- We use ffi.cdef to map the C signatures.
ffi.cdef[[
    // Standard Unix/Linux syscalls
    int getpid(void);
    int gethostname(char *name, size_t len);
    
    // Standard libc file handling (portable across OS and architecture)
    typedef void FILE;
    FILE *fopen(const char *path, const char *mode);
    int fseek(FILE *stream, long offset, int whence);
    long ftell(FILE *stream);
    int fclose(FILE *stream);
]]

print("--- System Information using FFI ---")

-- 2. Get Process ID
local pid = ffi.C.getpid()
assert(type(pid) == "number" and pid > 0, "PID should be a positive number")
print("Current Process ID: " .. pid)

-- 3. Get Hostname
local buffer = ffi.new("char[256]")
assert(ffi.C.gethostname(buffer, 256) == 0, "gethostname failed")
local hostname = ffi.string(buffer)
assert(#hostname > 0, "Hostname should not be empty")
print("Hostname: " .. hostname)

-- 4. Get File Info (Portable libc file sizing)
local function get_file_size(filename)
    local f = ffi.C.fopen(filename, "rb")
    if f == nil then return nil, "Could not open file" end
    ffi.C.fseek(f, 0, 2) -- SEEK_END = 2
    local size = ffi.C.ftell(f)
    ffi.C.fclose(f)
    return tonumber(size)
end

local size, err = get_file_size("Makefile")
assert(size and size > 0, "Makefile size should be greater than 0")
print("Size of 'Makefile': " .. size .. " bytes")

-- 5. Using FFI for Performance: Fast Memory Clearing
ffi.cdef[[
    void *memset(void *s, int c, size_t n);
]]

local large_array = ffi.new("uint8_t[1000000]")
ffi.C.memset(large_array, 0, 1000000)
assert(large_array[0] == 0 and large_array[999999] == 0, "Memset failed to clear array")
print("Cleared 1MB array using C memset.")

print("\nAll FFI tests passed successfully!")
