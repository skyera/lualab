local ffi = require("ffi")

-- 1. Define C structures and functions
-- We use ffi.cdef to map the C signatures.
ffi.cdef[[
    // Standard Unix/Linux syscalls
    int getpid(void);
    int gethostname(char *name, size_t len);
    
    // File status structure (simplified for Linux x64)
    typedef struct {
        unsigned long st_dev;
        unsigned long st_ino;
        unsigned long st_nlink;
        unsigned int  st_mode;
        unsigned int  st_uid;
        unsigned int  st_gid;
        unsigned int  __pad0;
        unsigned long st_rdev;
        long          st_size;
        long          st_blksize;
        long          st_blocks;
        long          st_atime;
        long          st_atime_nsec;
        long          st_mtime;
        long          st_mtime_nsec;
        long          st_ctime;
        long          st_ctime_nsec;
    } stat_t;

    int stat(const char *path, stat_t *buf);
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

-- 4. Get File Info (stat)
local function get_file_size(filename)
    local st = ffi.new("stat_t")
    if ffi.C.stat(filename, st) == 0 then
        return tonumber(st.st_size)
    else
        return nil, "Could not stat file"
    end
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
