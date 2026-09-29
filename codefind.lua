#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- codefind.lua
-- High-Performance Local Code & Document Search Engine
-- Built with pure LuaJIT FFI and SQLite FTS5 (Zero external dependencies)
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

local CODEFIND_VERSION = "0.1.0"

local is_windows = (ffi.os == "Windows")
local kernel32, msvcrt
local STD_INPUT_HANDLE  = 0xFFFFFFF6 -- ((uint32_t)-10)
local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- ((uint32_t)-11)
if is_windows then
    pcall(function() kernel32 = ffi.load("kernel32") end)
    pcall(function() msvcrt = ffi.load("msvcrt") end)
    if not kernel32 then kernel32 = ffi.C end
    if not msvcrt then msvcrt = ffi.C end
end

--------------------------------------------------------------------------------
-- 1. C Declarations: SQLite3 & POSIX / Win32 OS APIs
--------------------------------------------------------------------------------
ffi.cdef[[
    // --- SQLite3 Bindings ---
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3 *db);
    const char *sqlite3_errmsg(sqlite3 *db);
    const char *sqlite3_libversion(void);

    int sqlite3_exec(sqlite3 *db, const char *sql,
                     int (*callback)(void*, int, char**, char**),
                     void *arg, char **errmsg);
    void sqlite3_free(void *ptr);

    int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                           sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt *pStmt);
    int sqlite3_finalize(sqlite3_stmt *pStmt);
    int sqlite3_reset(sqlite3_stmt *pStmt);

    int sqlite3_bind_int(sqlite3_stmt *pStmt, int idx, int val);
    int sqlite3_bind_int64(sqlite3_stmt *pStmt, int idx, int64_t val);
    int sqlite3_bind_double(sqlite3_stmt *pStmt, int idx, double val);
    int sqlite3_bind_text(sqlite3_stmt *pStmt, int idx, const char *val, int len, void(*destructor)(void*));

    int sqlite3_column_count(sqlite3_stmt *pStmt);
    int sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
    const char *sqlite3_column_name(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
    double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
    const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_bytes(sqlite3_stmt *pStmt, int iCol);
]]

if is_windows then
    ffi.cdef[[
        typedef void *HANDLE;
        typedef struct _COORD { short X; short Y; } COORD;
        typedef struct _SMALL_RECT { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
        typedef struct _CONSOLE_SCREEN_BUFFER_INFO {
            COORD      dwSize;
            COORD      dwCursorPosition;
            uint16_t   wAttributes;
            SMALL_RECT srWindow;
            COORD      dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        HANDLE GetStdHandle(uint32_t nStdHandle);
        int GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO *lpConsoleScreenBufferInfo);
        int GetConsoleMode(HANDLE hConsoleHandle, uint32_t *lpMode);
        int SetConsoleMode(HANDLE hConsoleHandle, uint32_t dwMode);
        int SetConsoleOutputCP(uint32_t wCodePageID);
        void Sleep(uint32_t dwMilliseconds);
        int _kbhit(void);
        int _getch(void);

        typedef struct _FILETIME { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } FILETIME;
        typedef struct _WIN32_FIND_DATAA {
            uint32_t dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            uint32_t nFileSizeHigh;
            uint32_t nFileSizeLow;
            uint32_t dwReserved0;
            uint32_t dwReserved1;
            char     cFileName[260];
            char     cAlternateFileName[14];
        } WIN32_FIND_DATAA;

        void* FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA* lpFindFileData);
        int   FindNextFileA(void* hFindFile, WIN32_FIND_DATAA* lpFindFileData);
        int   FindClose(void* hFindFile);
        char* _fullpath(char *absPath, const char *relPath, size_t maxLength);
        unsigned long long GetTickCount64(void);
    ]]
else
    -- macOS/BSD declare tcflag_t/speed_t as 64-bit and set NCCS to 20, while Linux
-- uses 32-bit and NCCS=32.  Picking the wrong layout shifts every field offset
-- and makes tcgetattr overrun the LuaJIT buffer, so select it at cdef time.
-- On Linux the definition below passes through byte-for-byte unchanged.
local function posix_termios_cdef(def)
    if ffi.os == "OSX" or ffi.os == "BSD" then
        def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
        def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
        def = def:gsub("c_cc%[32%]", "c_cc[20]")
    end
    return def
end

ffi.cdef(posix_termios_cdef[[
        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, void *argp);
        int isatty(int fd);

        typedef unsigned char cc_t;
        typedef unsigned int  speed_t;
        typedef unsigned int  tcflag_t;

        struct termios {
            tcflag_t c_iflag;
            tcflag_t c_oflag;
            tcflag_t c_cflag;
            tcflag_t c_lflag;
            cc_t     c_line;
            cc_t     c_cc[32];
            speed_t  c_ispeed;
            speed_t  c_ospeed;
        };

        int tcgetattr(int fd, struct termios *termios_p);
        int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);

        struct pollfd {
            int   fd;
            short events;
            short revents;
        };
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
        long read(int fd, void *buf, size_t count);

        typedef struct DIR DIR;
        struct dirent {
            unsigned long  d_ino;
            long           d_off;
            unsigned short d_reclen;
            unsigned char  d_type;
            char           d_name[256];
        };
        DIR *opendir(const char *name);
        struct dirent *readdir(DIR *dirp);
        int closedir(DIR *dirp);

        typedef long time_t;
        char *realpath(const char *path, char *resolved_path);
]])


    if ffi.arch == "arm64" or ffi.arch == "aarch64" then
        ffi.cdef[[
            struct stat {
                unsigned long  st_dev;
                unsigned long  st_ino;
                unsigned int   st_mode;
                unsigned int   st_nlink;
                unsigned int   st_uid;
                unsigned int   st_gid;
                unsigned long  st_rdev;
                unsigned long  __pad1;
                long           st_size;
                int            st_blksize;
                int            __pad2;
                long           st_blocks;
                time_t         st_atime;
                unsigned long  st_atime_nsec;
                time_t         st_mtime;
                unsigned long  st_mtime_nsec;
                time_t         st_ctime;
                unsigned long  st_ctime_nsec;
                int            __glibc_reserved[2];
            };
            int stat(const char *pathname, struct stat *statbuf);
            int __xstat(int ver, const char *pathname, struct stat *statbuf);
        ]]
    else
        ffi.cdef[[
            struct stat {
                unsigned long  st_dev;
                unsigned long  st_ino;
                unsigned long  st_nlink;
                unsigned int   st_mode;
                unsigned int   st_uid;
                unsigned int   st_gid;
                unsigned int   __pad0;
                unsigned long  st_rdev;
                long           st_size;
                long           st_blksize;
                long           st_blocks;
                time_t         st_atime;
                unsigned long  st_atime_nsec;
                time_t         st_mtime;
                unsigned long  st_mtime_nsec;
                time_t         st_ctime;
                unsigned long  st_ctime_nsec;
                long           __unused[3];
            };
            int stat(const char *pathname, struct stat *statbuf);
            int __xstat(int ver, const char *pathname, struct stat *statbuf);
        ]]
    end
end

--------------------------------------------------------------------------------
-- 2. Library Loaders & OS Primitives
--------------------------------------------------------------------------------
-- SQLite3 discovery & validation
--------------------------------------------------------------------------------
-- Windows commonly has SEVERAL sqlite3 DLLs installed at once (conda, chocolatey,
-- MSYS2, hand-dropped copies). ffi.load("sqlite3") silently takes whichever the
-- Windows loader reaches first, so the version you actually get is invisible and
-- can differ from the one you think you have. So we enumerate real files,
-- validate each one, and let the user choose.

local SQLITE_CANDIDATES  = { "sqlite3", "sqlite3.dll", "libsqlite3.so.0", "libsqlite3.so", "libsqlite3.dylib" }
local SQLITE_FILE_NAMES  = { "sqlite3.dll", "sqlite3-3.dll", "libsqlite3.dll" }
local SQLITE_ENV_OVERRIDE = "CODEFIND_SQLITE3"

-- Symbols codefind actually calls. These are ALREADY declared in the cdef
-- above, which is load-bearing: lib[sym] raises "undefined symbol" for any name
-- that is not declared, so probing an undeclared symbol yields a false negative.
local SQLITE_REQUIRED_SYMBOLS = {
    "sqlite3_open", "sqlite3_close", "sqlite3_errmsg", "sqlite3_exec",
    "sqlite3_prepare_v2", "sqlite3_step", "sqlite3_finalize", "sqlite3_reset",
    "sqlite3_bind_text", "sqlite3_bind_int64", "sqlite3_column_text",
    "sqlite3_column_count", "sqlite3_libversion", "sqlite3_free",
}

-- Everything the loader learned, so `doctor` can show it without re-scanning.
local SQLITE_SCAN = { candidates = {}, chosen = nil }

local function is_tty_fd(fd)
    if is_windows then
        if not kernel32 then return false end
        local h = (fd == 0) and STD_INPUT_HANDLE or STD_OUTPUT_HANDLE
        local ok, handle = pcall(function() return kernel32.GetStdHandle(h) end)
        if not ok or handle == nil or handle == ffi.NULL then return false end
        local mode = ffi.new("uint32_t[1]")
        local ok2, r = pcall(function() return kernel32.GetConsoleMode(handle, mode) end)
        return ok2 and r ~= 0
    end
    local ok, r = pcall(function() return ffi.C.isatty(fd) ~= 0 end)
    return ok and r
end

-- Windows PATH is ';'-separated even under Git Bash, where $PATH looks ':'-separated.
local function split_path_list(p)
    local out = {}
    for d in tostring(p or ""):gmatch("[^;]+") do
        d = d:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]+$", "")
        if #d > 0 then out[#out + 1] = d end
    end
    return out
end

-- Config stores forward slashes for portability; directory scans yield native
-- backslashes. Compare on a normalised form so a pin still matches its entry.
local function same_path(a, b)
    if not a or not b then return false end
    local function norm(p)
        return tostring(p):lower():gsub("/", "\\"):gsub("\\+", "\\")
    end
    return norm(a) == norm(b)
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- Numeric version key so 3.53.4 sorts above 3.47.2.
local function version_key(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not a then return 0 end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

-- Validate a single candidate. Returns a record; ok==true means genuinely usable.
-- Shared by file validation and the bare-soname fallback. Probing lib[sym] is
-- safe only because every name here is already declared in the cdef above;
-- an undeclared name raises "undefined symbol" regardless of what is exported.
local function missing_symbols(lib)
    local missing = {}
    for _, sym in ipairs(SQLITE_REQUIRED_SYMBOLS) do
        if not pcall(function() return lib[sym] end) then missing[#missing + 1] = sym end
    end
    return missing
end

local function validate_sqlite_lib(path)
    local res = { path = path, ok = false }

    local f = io.open(path, "rb")
    if not f then res.reason = "not readable"; return res end
    res.size = f:seek("end")
    f:seek("set")
    local magic = f:read(2)
    f:close()
    if not magic or #magic < 2 or magic:byte(1) ~= 77 or magic:byte(2) ~= 90 then
        res.reason = "not a PE image"
        return res
    end

    local ok, lib = pcall(ffi.load, path)
    if not ok or not lib then
        res.reason = "LoadLibrary failed (" .. tostring(lib) .. ")"
        return res
    end

    local missing = missing_symbols(lib)
    if #missing > 0 then
        res.reason = "missing symbols: " .. table.concat(missing, ", ")
        return res
    end

    local vok, v = pcall(function() return ffi.string(lib.sqlite3_libversion()) end)
    if not vok or not v or #v == 0 then
        res.reason = "sqlite3_libversion() not callable"
        return res
    end
    res.version = v

    -- Final gate: a library can load, export everything, and still be built
    -- without FTS5 -- which codefind needs for indexing. Probe the real feature.
    local db = ffi.new("sqlite3*[1]")
    if lib.sqlite3_open(":memory:", db) ~= 0 then
        res.reason = "sqlite3_open(':memory:') failed"
        return res
    end
    local err = ffi.new("char*[1]")
    local rc = lib.sqlite3_exec(db[0], "CREATE VIRTUAL TABLE t USING fts5(body)", nil, nil, err)
    if rc ~= 0 then
        local msg = (err[0] ~= nil) and ffi.string(err[0]) or ("code " .. rc)
        pcall(function() lib.sqlite3_free(err[0]) end)
        lib.sqlite3_close(db[0])
        res.reason = "FTS5 unavailable (" .. msg .. ")"
        return res
    end
    lib.sqlite3_close(db[0])

    res.ok = true
    res.lib = lib
    return res
end

local function current_script_dir()
    local a0 = rawget(_G, "arg")
    local s = a0 and a0[0]
    if not s or s == "" then return nil end
    return s:match("^(.*)[/\\][^/\\]*$")
end

-- Deliberately narrow: PATH, the script's own folder, and the cwd. These are
-- the only places a DLL would be picked up from anyway, and it stays fast.
-- Enumeration only: read directory entries and file headers, never ffi.load.
-- Loading a candidate just to describe it runs that DLL's entry point, which is
-- a side effect we neither need nor want before the user has picked one.
local function scan_sqlite_candidates()
    local found, seen = {}, {}
    local function consider(dir, source)
        if not dir or #dir == 0 then return end
        for _, name in ipairs(SQLITE_FILE_NAMES) do
            local p = dir .. "\\" .. name
            local key = p:lower():gsub("/", "\\")
            if not seen[key] then
                local f = io.open(p, "rb")
                if f then
                    local sz = f:seek("end")
                    f:seek("set")
                    local magic = f:read(2)
                    f:close()
                    seen[key] = true
                    found[#found + 1] = {
                        path = p, source = source, size = sz,
                        is_pe = (magic and #magic == 2
                                 and magic:byte(1) == 77 and magic:byte(2) == 90) or false,
                    }
                end
            end
        end
    end
    for _, dir in ipairs(split_path_list(os.getenv("PATH"))) do consider(dir, "PATH") end
    consider(current_script_dir(), "script dir")
    consider(os.getenv("CD") or os.getenv("PWD"), "cwd")
    return found
end
--------------------------------------------------------------------------------
-- Preference tiers and the persisted pin
--------------------------------------------------------------------------------
-- With several sqlite3 DLLs installed, the right one is usually decided by
-- which toolchain shipped it. A conda build is a deliberate, fully-featured
-- build (FTS5 included), whereas a stray copy on PATH or in the cwd is often
-- incidental. Ranking by origin gets the common case right with no config.
--
-- A pin covers the rest: `codefind pin` records an exact path that always wins,
-- for when the heuristic is not what you want.

-- Higher wins. Ties fall back to discovery order.
local SQLITE_TIERS = {
    { tier = 40, label = "conda",      match = "miniforge" },
    { tier = 40, label = "conda",      match = "anaconda" },
    { tier = 40, label = "conda",      match = "[/\\]conda" },
    { tier = 30, label = "local",      match = nil },        -- filled in per-source below
    { tier = 20, label = "msys2",      match = "msys64" },
    { tier = 20, label = "mingw",      match = "mingw" },
    { tier = 10, label = "chocolatey", match = "chocolatey" },
    { tier = 10, label = "scoop",      match = "scoop" },
}

local function classify_source(path, source)
    local lower = tostring(path):lower()
    for _, t in ipairs(SQLITE_TIERS) do
        if t.match then
            if lower:find(t.match, 1, true) or lower:find(t.match) then
                return t.tier, t.label
            end
        end
    end
    -- A DLL dropped beside the script or into the cwd is a deliberate local
    -- placement, so it outranks an anonymous PATH hit.
    if source == "script dir" or source == "cwd" then return 30, "local" end
    return 5, "PATH"
end

local function annotate_candidates(cands)
    for _, c in ipairs(cands) do
        c.tier, c.origin = classify_source(c.path, c.source)
    end
    return cands
end

local function best_candidate(cands)
    local best
    for _, c in ipairs(cands) do
        if not best or (c.tier or 0) > (best.tier or 0) then best = c end
    end
    return best
end

-- Per-user config, so it survives redeploys and applies from any directory.
local function config_path()
    if is_windows then
        local base = os.getenv("LOCALAPPDATA") or os.getenv("APPDATA")
        if base then return base .. "\\codefind\\config" end
        return "codefind.config"
    end
    local base = os.getenv("XDG_CONFIG_HOME")
    if not base or #base == 0 then base = os.getenv("HOME") .. "/.config" end
    return base .. "/codefind/config"
end

-- Deliberately a trivial key = "value" format: hand-editable, no parser needed.
local function read_config()
    local cfg = {}
    local f = io.open(config_path(), "r")
    if not f then return cfg end
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if #line > 0 and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^(%w+)%s*=%s*(.*)$")
            if k then
                v = v:gsub('^"', ""):gsub('"$', "")
                cfg[k:lower()] = v
            end
        end
    end
    f:close()
    return cfg
end

local function ensure_config_dir()
    local dir = config_path():match("^(.*)[/\\][^/\\]*$")
    if not dir or #dir == 0 then return end
    -- Best effort only, and deliberately not checked: `md` exits non-zero when
    -- the directory ALREADY exists, so its status code says nothing about
    -- whether the directory is usable. The real test is whether the config file
    -- can be opened for writing, which write_pin does next.
    if is_windows then
        os.execute('mkdir "' .. dir .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '"')
    end
end

local function write_config_key(key, val)
    ensure_config_dir()
    local cfg = read_config()
    cfg[key:lower()] = val
    local f = io.open(config_path(), "w")
    if not f then
        return false, "could not write " .. config_path() .. " (is that location writable?)"
    end
    f:write("# codefind configuration\n")
    for k, v in pairs(cfg) do
        f:write(string.format('%s = "%s"\n', k, tostring(v):gsub("\\", "/")))
    end
    f:close()
    return true
end

local function clear_config_key(key)
    local cfg = read_config()
    if not cfg[key:lower()] then return false, "no setting for " .. key end
    local f = io.open(config_path(), "r")
    if not f then return false, "could not read " .. config_path() end
    local kept = {}
    for line in f:lines() do
        local k = line:match("^%s*(%w+)%s*=")
        if k and k:lower() == key:lower() then
            -- drop it
        else
            kept[#kept + 1] = line
        end
    end
    f:close()
    local out = io.open(config_path(), "w")
    if not out then return false, "could not write " .. config_path() end
    out:write(table.concat(kept, "\n"))
    if #kept > 0 then out:write("\n") end
    out:close()
    return true
end

local function write_pin(path)
    return write_config_key("sqlite3", path)
end

local function clear_pin()
    return clear_config_key("sqlite3")
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

local function human_size(n)
    if not n then return "?" end
    if n < 1024 then return string.format("%d B", n) end
    if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
    return string.format("%.1f MB", n / (1024 * 1024))
end

-- Monotonic wall clock, in seconds. os.clock() reports CPU time, so it badly
-- understates an index dominated by file reads and SQLite writes -- timings and
-- the files/sec rate derived from it were effectively meaningless.
local wall_now
do
    local resolved = false
    if is_windows and kernel32 then
        local ok, fn = pcall(function() return kernel32.GetTickCount64 end)
        if ok and fn then
            wall_now = function() return tonumber(fn()) / 1000.0 end
            resolved = true
        end
    end
    if not resolved then
        local ok = pcall(function()
            ffi.cdef[[
                struct codefind_timespec { long tv_sec; long tv_nsec; };
                int clock_gettime(int clk_id, struct codefind_timespec *tp);
            ]]
        end)
        if ok then
            local ts = ffi.new("struct codefind_timespec[1]")
            local CLOCK_MONOTONIC = 1
            if pcall(function() return ffi.C.clock_gettime(CLOCK_MONOTONIC, ts) end) then
                wall_now = function()
                    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
                    return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) / 1e9
                end
                resolved = true
            end
        end
    end
    if not resolved then wall_now = os.clock end   -- last resort
end

local function format_duration(sec)
    if sec < 60 then return string.format("%.2fs", sec) end
    if sec < 3600 then return string.format("%dm%02ds", math.floor(sec / 60), math.floor(sec % 60)) end
    return string.format("%dh%02dm%02ds", math.floor(sec / 3600),
                         math.floor((sec % 3600) / 60), math.floor(sec % 60))
end

-- Every library we looked at, whether validated or rejected by the soname probe.
local function all_scan_entries()
    local out = {}
    for _, c in ipairs(SQLITE_SCAN.candidates) do out[#out + 1] = c end
    for _, c in ipairs(SQLITE_SCAN.rejected or {}) do out[#out + 1] = c end
    return out
end

-- Keep rejection reasons readable: a DLL missing all 14 symbols would otherwise
-- wrap a very long line across the terminal.
local function shorten_reason(reason, max_syms)
    local syms = tostring(reason):match("missing symbols: (.*)$")
    if not syms then return reason end
    local list = {}
    for s in syms:gmatch("[^,%s]+") do list[#list + 1] = s end
    if #list <= max_syms then return reason end
    return ("missing %d symbols: %s, ... (+%d more)"):format(
        #list, table.concat(list, ", ", 1, max_syms), #list - max_syms)
end

local function describe_candidate(c, i)
    local r = c.result
    local tag = ("  [%d] %s"):format(i, c.path)
    if r and r.ok then
        return ("%s\n         v%s  %s  usable (FTS5 yes)  [%s]"):format(
            tag, r.version, human_size(r.size or c.size), c.source)
    end
    if r then   -- loaded and rejected
        return ("%s\n         %s  UNUSABLE: %s"):format(
            tag, human_size(r.size or c.size), shorten_reason(r.reason, 4))
    end
    -- Enumerated but deliberately not loaded.
    return ("%s\n         %s  %s  %s  [not loaded]"):format(
        tag, human_size(c.size), c.is_pe and "PE image" or "NOT a PE image",
        c.origin or "?")
end

local function prompt_sqlite_choice(cands, read_fn, write_fn)
    write_fn = write_fn or function(s) io.write(s); io.flush() end
    write_fn(string.format("\n  %d sqlite3 libraries found:\n\n", #cands))
    for i, c in ipairs(cands) do write_fn(describe_candidate(c, i) .. "\n") end
    write_fn(string.format("\n  Select [1-%d] (default 1): ", #cands))
    local line = (read_fn or io.read)("*l")
    if not line then write_fn("\n"); return 1 end
    local n = tonumber((tostring(line):gsub("%s+", "")))
    if not n or n < 1 or n > #cands then return 1 end
    return math.floor(n)
end


-- Returns lib, label  (label is a human description used by `doctor`)
-- Pick from the enumerated candidates WITHOUT loading any of them.
-- Order of preference: an explicit pin, then an interactive choice, then the
-- highest toolchain tier, and finally plain discovery order.
local function choose_candidate(cands, interactive, read_fn, write_fn)
    if #cands == 0 then return nil end
    if #cands == 1 then return cands[1] end

    if interactive then
        return cands[prompt_sqlite_choice(cands, read_fn, write_fn)]
    end

    local best = best_candidate(cands)
    if best and (best.tier or 0) > (cands[1].tier or 0) then
        SQLITE_SCAN.tier_picked = best.origin
        return best
    end
    SQLITE_SCAN.auto_picked = true
    return cands[1]
end

local function select_sqlite_lib()
    -- 1. An explicit request must be honoured or reported, never silently ignored.
    local forced = os.getenv(SQLITE_ENV_OVERRIDE)
    if forced and #forced > 0 then
        local r = validate_sqlite_lib(forced)
        if r.ok then
            SQLITE_SCAN.chosen = r
            SQLITE_SCAN.forced = forced
            SQLITE_SCAN.candidates = { { path = forced, source = "env", size = r.size,
                                          is_pe = true, result = r } }
            return r.lib, forced
        end
        io.write("\n  " .. SQLITE_ENV_OVERRIDE .. "=" .. forced .. " is not usable:\n")
        io.write("    " .. tostring(r.reason) .. "\n")
        io.write("  Fix the variable or unset it to auto-select.\n\n")
        io.flush()
        error("CODEFIND_SQLITE3 points at an unusable library")
    end

    if is_windows then
        SQLITE_SCAN.candidates = annotate_candidates(scan_sqlite_candidates())

        -- A pin is an explicit decision and outranks both the heuristic and the
        -- prompt, so normal runs stay non-interactive once one is set.
        local pinned = read_config().sqlite3
        if pinned and #pinned > 0 then
            local pr = validate_sqlite_lib(pinned)
            if pr.ok then
                SQLITE_SCAN.chosen = pr
                SQLITE_SCAN.pinned = pinned
                local hit
                for _, c in ipairs(SQLITE_SCAN.candidates) do
                    if same_path(c.path, pinned) then hit = c end
                end
                if hit then hit.result = pr end
                return pr.lib, pinned
            end
            -- Stale pin: say so plainly, then carry on with the normal rules
            -- rather than failing over a setting the user can trivially re-set.
            io.write(string.format("\n  \27[33m!\27[0m Pinned sqlite3 is unusable: %s\n", pinned))
            io.write(string.format("      %s\n", tostring(pr.reason)))
            io.write(string.format("      Re-pin with: codefind pin     (config: %s)\n\n",
                                   config_path()))
            io.flush()
            SQLITE_SCAN.pin_broken = pinned
        end

        local picked = choose_candidate(SQLITE_SCAN.candidates, is_tty_fd(0), io.read,
                                        function(s) io.write(s); io.flush() end)
        if picked then
            -- Only the selected library is ever loaded.
            local r = validate_sqlite_lib(picked.path)
            picked.result = r
            if r.ok then
                SQLITE_SCAN.chosen = r
                return r.lib, picked.path
            end
            SQLITE_SCAN.selected_failed = r
            return nil, nil      -- banner explains, and points at doctor
        end
    end

    -- POSIX, or a Windows layout the scan could not see: fall back to plain
    -- soname probing. This MUST still validate -- on Windows ffi.load("sqlite3")
    -- happily resolves to a broken ./sqlite3.dll sitting in the cwd, and
    -- returning that unchecked crashes later at the first real API call.
    for _, name in ipairs(SQLITE_CANDIDATES) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            local missing = missing_symbols(lib)
            if #missing == 0 then
                local v = "unknown"
                pcall(function() v = ffi.string(lib.sqlite3_libversion()) end)
                SQLITE_SCAN.chosen = { ok = true, path = name, version = v, size = nil }
                return lib, name
            end
            SQLITE_SCAN.rejected = SQLITE_SCAN.rejected or {}
            SQLITE_SCAN.rejected[#SQLITE_SCAN.rejected + 1] = {
                path = name, source = "soname",
                result = { path = name, size = nil,
                           reason = "missing symbols: " .. table.concat(missing, ", ") },
            }
        end
    end
    return nil, nil
end

local function load_sqlite_lib()
    local lib, label = select_sqlite_lib()
    if lib then return lib, label end

    -- Nothing usable anywhere: fail loudly. This runs at module load, before any
    -- command dispatch, so a bare error() leaves an empty terminal and no clue.
    local L = {}
    local function say(s) L[#L + 1] = s end

    local title = "codefind FATAL: no usable SQLite3 library found"
    say("")
    say("  ╔" .. string.rep("═", 62) .. "╗")
    say("  ║  " .. title .. string.rep(" ", 62 - 2 - #title) .. "║")
    say("  ╚" .. string.rep("═", 62) .. "╝")
    say("")
    say("  codefind indexes into SQLite FTS5 and cannot run without it.")
    local entries = all_scan_entries()
    if SQLITE_SCAN.selected_failed then
        say("  The library you selected could not be used:")
        say("")
        say("      " .. SQLITE_SCAN.selected_failed.path)
        say("      " .. tostring(SQLITE_SCAN.selected_failed.reason))
        say("")
    end
    if #entries > 0 then
        say("  Libraries available (only the selected one is ever loaded):")
        say("")
        for i, c in ipairs(entries) do
            say("  " .. describe_candidate(c, i))
        end
        say("")
    else
        say("  No sqlite3 DLL was found in PATH, the script folder, or the cwd.")
        say("")
    end
    if is_windows then
        say("  Fix on Windows (pick one):")
        say("      choco install sqlite")
        say("      winget install SQLite.SQLite")
        say("      conda install sqlite            (if you use miniforge/anaconda)")
        say("      .. or drop a sqlite3.dll beside codefind.lua")
        say("  .. or pin a specific one you already have:")
        say(string.format("      set %s=C:\\path\\to\\sqlite3.dll", SQLITE_ENV_OVERRIDE))
    elseif ffi.os == "OSX" then
        say("  Fix on macOS:   brew install sqlite")
    else
        say("  Fix on Linux:   sudo apt install libsqlite3-0")
        say("                  (or: sudo yum install sqlite-libs)")
    end
    say("")
    say("  Inspect every library found and see why one is rejected:")
    say("      luajit codefind.lua doctor")
    say("")

    local message = table.concat(L, "\n")
    -- stdout AND stderr, both flushed, so this survives pipes, redirects,
    -- .cmd shims and IDE consoles.
    io.stdout:write(message, "\n"); io.stdout:flush()
    io.stderr:write(message, "\n"); io.stderr:flush()
    error("No usable SQLite3 library. See the instructions above.")
end

local sqlite, sqlite_lib_name = load_sqlite_lib()

local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

--------------------------------------------------------------------------------
-- 2b. Runtime Diagnostics
--------------------------------------------------------------------------------
-- Windows failures are easy to misread: a missing sqlite3.dll, a stale deployed
-- copy, and a console that swallows output all look alike ("nothing happened").
-- These helpers report what the running process actually sees -- especially
-- WHICH copy of the script is executing -- so the cases are distinguishable.

local function sqlite_version()
    local ok, v = pcall(function() return ffi.string(sqlite.sqlite3_libversion()) end)
    if ok and v and #v > 0 then return v end
    return "unknown"
end

local function is_stdout_tty()
    return is_tty_fd(1)
end

-- Resolve to an absolute path when the platform bindings allow it; fall back to
-- the shell's idea of the cwd so we still print something useful.
local function resolve_path(p)
    if type(p) ~= "string" or #p == 0 then return "?" end
    if p:match("^/") or p:match("^%a:[/\\]") or p:match("^\\\\") then return p end
    local buf = ffi.new("char[4096]")
    if is_windows then
        local ok, res = pcall(function() return ffi.string(ffi.C._fullpath(buf, p, 4096)) end)
        if ok and res then return res end
    else
        local ok, res = pcall(function() return ffi.string(ffi.C.realpath(p, buf)) end)
        if ok and res then return res end
    end
    local cwd = os.getenv("CD") or os.getenv("PWD") or "?"
    return (cwd:gsub("[/\\]+$", "")) .. "/" .. p
end


-- The single most useful line when a Windows install misbehaves: it proves
-- whether you are running the repo copy or a stale deployed one.
local function running_script_path()
    local a0 = rawget(_G, "arg")
    local s = a0 and a0[0]
    if not s or s == "" then return "?" end
    return resolve_path(s)
end

local resolve_finder, detect_available_finders

local function diagnostics_lines(db_path, target_dir, allow_all, finder_mode)
    local jit = rawget(_G, "jit")
    local interp = jit and string.format("%s (%s)", jit.version, jit.arch)
                        or "plain Lua -- NO JIT/FFI, cannot run this tool"

    local size = file_size(db_path)
    local db_desc = resolve_path(db_path)
    db_desc = db_desc .. string.format("  (%s%s)", size and "exists, " .. human_size(size) or "new",
                                       (db_path:match("%.db$")) and "" or "  [UNEXPECTED EXT]")

    local active_f = resolve_finder(finder_mode)
    local f_label
    if active_f == "fd" then
        f_label = "fd (fast multi-threaded)"
    elseif active_f == "builtin" then
        f_label = "builtin (native LuaJIT FFI)"
    elseif active_f == "find" then
        f_label = "find (POSIX find)"
    else
        f_label = active_f
    end

    local L = {}
    local function add(k, v) L[#L + 1] = string.format("  %-11s %s", k, v) end
    add("codefind", "v" .. CODEFIND_VERSION)
    add("interpreter", interp)
    add("platform", string.format("%s / %s   ffi.os=%s", is_windows and "Windows" or ffi.os, ffi.arch, ffi.os))
    add("sqlite3", string.format("v%s  %s", sqlite_version(), tostring(sqlite_lib_name)))
    add("crawler", f_label)
    add("tty", is_stdout_tty() and "yes" or "no  (output redirected or buffered)")
    add("script", running_script_path())
    add("db", db_desc)
    add("target", string.format("%s  ->  %s", target_dir, resolve_path(target_dir)))
    add("mode", allow_all and "ALL files" or "SOURCE ONLY (use --all to include everything)")
    return L
end

-- Always shown, even when there is only one candidate: seeing the number and
-- the resolved path is what makes "which sqlite3 am I actually using?" answerable
-- at a glance instead of by guesswork.
-- `validate` is used by `doctor` only. Normal runs never load a library the
-- user did not pick; doctor is an explicit request to inspect them all, so it
-- is the one place where loading every candidate is the point.
local function print_sqlite_candidates(validate)
    local entries = all_scan_entries()
    io.write("\n  \27[1m-- sqlite3 libraries \27[0m" .. string.rep("-", 40) .. "\n")
    if #entries == 0 then
        io.write(string.format("      (no sqlite3 file found by path; loaded %s)\n",
                               tostring(sqlite_lib_name)))
        return
    end
    if validate then
        for _, c in ipairs(entries) do
            if not c.result then c.result = validate_sqlite_lib(c.path) end
        end
    end
    for i, c in ipairs(entries) do
        local inuse = (SQLITE_SCAN.chosen and c.result and same_path(c.result.path, SQLITE_SCAN.chosen.path))
        io.write(describe_candidate(c, i))
        if inuse then
            io.write("   \27[1m<- IN USE\27[0m")
            if SQLITE_SCAN.pinned then io.write(" \27[2m(pinned)\27[0m") end
        end
        io.write("\n")
    end
    if #entries > 1 then
        if SQLITE_SCAN.tier_picked then
            io.write(string.format("      (chose the %s build: highest preference tier)\n",
                                   SQLITE_SCAN.tier_picked))
        elseif SQLITE_SCAN.auto_picked then
            io.write("      (stdin is not a terminal, so the first on PATH was used)\n")
        end
        io.write(string.format("\n  Choose a different one:\n"))
        io.write(string.format("      codefind pin                (remember the choice)\n"))
        io.write(string.format("      set %s=C:\\path\\to\\sqlite3.dll   (this session)\n",
                               SQLITE_ENV_OVERRIDE))
    end
end

local function print_diagnostics(db_path, target_dir, allow_all, finder_mode)
    -- The library list comes first: which sqlite3 is in play is the fact that
    -- most often explains a missing, wrong or shadowed library, so it should not
    -- sit buried underneath the environment block.
    print_sqlite_candidates()
    io.write("\n  \27[1m-- environment \27[0m" .. string.rep("-", 46) .. "\n")
    io.write(table.concat(diagnostics_lines(db_path, target_dir, allow_all, finder_mode), "\n"), "\n")
    io.flush()
end

-- Terminal & File Stat helpers
local posix_stat = nil
if not is_windows then
    if pcall(function() return ffi.C.stat end) then
        posix_stat = function(p, st) return ffi.C.stat(p, st) end
    elseif pcall(function() return ffi.C.__xstat end) then
        local stat_ver = 1
        local dummy_st = ffi.new("struct stat")
        if ffi.C.__xstat(0, ".", dummy_st) == 0 then
            stat_ver = 0
        elseif ffi.C.__xstat(1, ".", dummy_st) == 0 then
            stat_ver = 1
        elseif ffi.C.__xstat(3, ".", dummy_st) == 0 then
            stat_ver = 3
        end
        posix_stat = function(p, st)
            return ffi.C.__xstat(stat_ver, p, st)
        end
    else
        posix_stat = function(p, st) return -1 end
    end
end

local function get_file_metadata(path)
    if is_windows then
        local f = io.open(path, "rb")
        if not f then return nil end
        local sz = f:seek("end")
        f:close()
        return { size = sz or 0, mtime = 0, is_dir = false, is_reg = true }
    else
        local st = ffi.new("struct stat")
        if posix_stat and posix_stat(path, st) == 0 then
            local is_dir = bit.band(st.st_mode, 0xF000) == 0x4000
            local is_reg = bit.band(st.st_mode, 0xF000) == 0x8000
            return {
                size = tonumber(st.st_size),
                mtime = tonumber(st.st_mtime),
                is_dir = is_dir,
                is_reg = is_reg
            }
        else
            -- Robust fallback to Lua standard io if POSIX stat fails
            local f = io.open(path, "rb")
            if f then
                local sz = f:seek("end") or 0
                f:close()
                return { size = sz, mtime = 0, is_dir = false, is_reg = true }
            end
        end
    end
    return nil
end

local function is_binary_buffer(data)
    local sample_len = math.min(#data, 4096)
    local null_count = 0
    for i = 1, sample_len do
        local b = data:byte(i)
        if b == 0 then
            null_count = null_count + 1
            if null_count > 1 then return true end
        end
    end
    return false
end

local function get_filename(path)
    return path:match("([^/\\]+)$") or path
end

local function normalize_path(path)
    if not path or path == "" then return "." end
    local p = path:gsub("\\", "/")
    while p:find("^%./") do
        p = p:sub(3)
    end
    p = p:gsub("/+", "/")
    if #p > 1 and p:sub(-1) == "/" then
        p = p:sub(1, -2)
    end
    return (p == "" or p == ".") and "." or p
end

--------------------------------------------------------------------------------
-- 3. Database Engine & SQLite Wrapper
--------------------------------------------------------------------------------
local Database = {}
Database.__index = Database

function Database.open(db_path)
    local self = setmetatable({}, Database)
    self.path = db_path or ".codefind.db"
    local db_p = ffi.new("sqlite3*[1]")
    local rc = sqlite.sqlite3_open(self.path, db_p)
    if rc ~= SQLITE_OK then
        local err = db_p[0] ~= nil and ffi.string(sqlite.sqlite3_errmsg(db_p[0])) or "Unknown error"
        error("Failed to open database: " .. err)
    end
    self.db = db_p[0]
    self:init_schema()
    return self
end

function Database:close()
    if self.db then
        if self._stmt_get_file_info then
            sqlite.sqlite3_finalize(self._stmt_get_file_info)
            self._stmt_get_file_info = nil
        end
        if self._stmt_del_fts then
            sqlite.sqlite3_finalize(self._stmt_del_fts)
            self._stmt_del_fts = nil
        end
        if self._stmt_del_files then
            sqlite.sqlite3_finalize(self._stmt_del_files)
            self._stmt_del_files = nil
        end
        if self._stmt_ins_f then
            sqlite.sqlite3_finalize(self._stmt_ins_f)
            self._stmt_ins_f = nil
        end
        if self._stmt_ins_fts then
            sqlite.sqlite3_finalize(self._stmt_ins_fts)
            self._stmt_ins_fts = nil
        end
        sqlite.sqlite3_close(self.db)
        self.db = nil
    end
end

function Database:exec(sql)
    local err_p = ffi.new("char*[1]")
    local rc = sqlite.sqlite3_exec(self.db, sql, nil, nil, err_p)
    if rc ~= SQLITE_OK then
        -- Copy error string to Lua BEFORE freeing the C pointer (prevents use-after-free)
        local err
        if err_p[0] ~= nil then
            err = ffi.string(err_p[0])
            sqlite.sqlite3_free(err_p[0])
        else
            err = ffi.string(sqlite.sqlite3_errmsg(self.db))
        end
        return false, err
    end
    return true
end

function Database:init_schema()
    -- Fast journaling & caching
    self:exec("PRAGMA synchronous = NORMAL;")
    self:exec("PRAGMA journal_mode = WAL;")

    -- Metadata table
    local sql_files = [[
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            filepath TEXT UNIQUE NOT NULL,
            filename TEXT NOT NULL,
            extension TEXT,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_files_path ON files(filepath);
    ]]
    local ok, err = self:exec(sql_files)
    if not ok then error("Error creating files table: " .. err) end

    -- Key-Value meta table (stores last_index timestamp, etc.)
    local ok_meta = self:exec([[
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
    ]])
    -- non-fatal if it already exists or fails

    -- Full-Text Search 5 virtual table (unicode61 tokenchars to match symbols like _, .)
    local sql_fts = [[
        CREATE VIRTUAL TABLE IF NOT EXISTS code_idx USING fts5(
            filepath UNINDEXED,
            filename,
            content,
            tokenize = "unicode61 tokenchars '._'"
        );
    ]]
    local ok_fts, err_fts = self:exec(sql_fts)
    if not ok_fts then
        -- Fallback to default tokenizer if custom tokenchars syntax not supported by older sqlite
        local sql_fts_fallback = "CREATE VIRTUAL TABLE IF NOT EXISTS code_idx USING fts5(filepath UNINDEXED, filename, content);"
        local ok_fb, err_fb = self:exec(sql_fts_fallback)
        if not ok_fb then error("Failed to create FTS5 index: " .. err_fb) end
    end
end


function Database:begin()
    return self:exec("BEGIN TRANSACTION;")
end

function Database:commit()
    return self:exec("COMMIT;")
end

function Database:rollback()
    return self:exec("ROLLBACK;")
end

function Database:get_file_info(filepath)
    local canon = normalize_path(filepath)
    local dot_variant = "./" .. canon

    local stmt = self._stmt_get_file_info
    if not stmt then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "SELECT id, size, mtime, filepath FROM files WHERE filepath = ? OR filepath = ? LIMIT 1;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then
            return nil
        end
        stmt = stmt_p[0]
        self._stmt_get_file_info = stmt
    else
        sqlite.sqlite3_reset(stmt)
    end

    sqlite.sqlite3_bind_text(stmt, 1, canon, #canon, SQLITE_TRANSIENT)
    sqlite.sqlite3_bind_text(stmt, 2, dot_variant, #dot_variant, SQLITE_TRANSIENT)
    local res = nil
    if sqlite.sqlite3_step(stmt) == SQLITE_ROW then
        res = {
            id = tonumber(sqlite.sqlite3_column_int64(stmt, 0)),
            size = tonumber(sqlite.sqlite3_column_int64(stmt, 1)),
            mtime = tonumber(sqlite.sqlite3_column_int64(stmt, 2)),
            filepath = ffi.string(sqlite.sqlite3_column_text(stmt, 3)),
        }
    end
    return res
end

function Database:remove_file(filepath)
    local canon = normalize_path(filepath)
    local dot_variant = "./" .. canon

    local stmt_del_fts = self._stmt_del_fts
    if not stmt_del_fts then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "DELETE FROM code_idx WHERE filepath = ? OR filepath = ?;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_del_fts = stmt_p[0]
            self._stmt_del_fts = stmt_del_fts
        end
    else
        sqlite.sqlite3_reset(stmt_del_fts)
    end
    if stmt_del_fts then
        sqlite.sqlite3_bind_text(stmt_del_fts, 1, canon, #canon, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_del_fts, 2, dot_variant, #dot_variant, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_del_fts)
    end

    local stmt_del_files = self._stmt_del_files
    if not stmt_del_files then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "DELETE FROM files WHERE filepath = ? OR filepath = ?;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_del_files = stmt_p[0]
            self._stmt_del_files = stmt_del_files
        end
    else
        sqlite.sqlite3_reset(stmt_del_files)
    end
    if stmt_del_files then
        sqlite.sqlite3_bind_text(stmt_del_files, 1, canon, #canon, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_del_files, 2, dot_variant, #dot_variant, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_del_files)
    end
end

function Database:index_file(filepath, filename, ext, size, mtime, content)
    filepath = normalize_path(filepath)
    filename = filename or get_filename(filepath)

    -- 1. Remove previous FTS and file entry if updating (cleans both canon and ./ variants)
    self:remove_file(filepath)

    -- 2. Insert into files table
    local stmt_ins_f = self._stmt_ins_f
    if not stmt_ins_f then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "INSERT INTO files (filepath, filename, extension, size, mtime) VALUES (?, ?, ?, ?, ?);"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_ins_f = stmt_p[0]
            self._stmt_ins_f = stmt_ins_f
        end
    else
        sqlite.sqlite3_reset(stmt_ins_f)
    end
    if stmt_ins_f then
        sqlite.sqlite3_bind_text(stmt_ins_f, 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_ins_f, 2, filename, #filename, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_ins_f, 3, ext or "", #(ext or ""), SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_int64(stmt_ins_f, 4, size)
        sqlite.sqlite3_bind_int64(stmt_ins_f, 5, mtime)
        sqlite.sqlite3_step(stmt_ins_f)
    end

    -- 3. Insert into FTS5 index
    local stmt_ins_fts = self._stmt_ins_fts
    if not stmt_ins_fts then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "INSERT INTO code_idx (filepath, filename, content) VALUES (?, ?, ?);"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_ins_fts = stmt_p[0]
            self._stmt_ins_fts = stmt_ins_fts
        end
    else
        sqlite.sqlite3_reset(stmt_ins_fts)
    end
    if stmt_ins_fts then
        sqlite.sqlite3_bind_text(stmt_ins_fts, 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_ins_fts, 2, filename, #filename, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_ins_fts, 3, content, #content, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_ins_fts)
    end
end

function Database:get_all_filepaths()
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    local sql = "SELECT filepath FROM files;"
    if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then
        return {}
    end
    local stmt = stmt_p[0]
    local list = {}
    while sqlite.sqlite3_step(stmt) == SQLITE_ROW do
        local fpath = ffi.string(sqlite.sqlite3_column_text(stmt, 0))
        table.insert(list, fpath)
    end
    sqlite.sqlite3_finalize(stmt)
    return list
end

function Database:search(query_str, options)
    options = options or {}
    local limit = options.limit
    local limit_clause = (limit and limit > 0) and string.format(" LIMIT %d", limit * 3) or ""
    local ext_filter = options.extension

    -- Handle "files:<pattern>" prefix — searches by filename, not content
    local files_prefix = query_str:match("^[Ff]iles?:(.*)$")
    if files_prefix then
        local pattern = files_prefix:gsub("%*", "%%"):gsub("^%%", ""):gsub("%%$", "")
        if #pattern == 0 then pattern = "%" end
        local like_pat = "%" .. pattern .. "%"
        local sql = "SELECT filepath, filename, '' AS snip, 0.0 AS rank FROM files WHERE filename LIKE ?" ..
                    (ext_filter and (" AND extension = '" .. ext_filter:gsub("'","''") .. "'") or "") ..
                    " ORDER BY filename" ..
                    ((limit and limit > 0) and (" LIMIT " .. limit) or "") .. ";"
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then
            return {}, "files: search query failed"
        end
        sqlite.sqlite3_bind_text(stmt_p[0], 1, like_pat, #like_pat, SQLITE_TRANSIENT)
        local results = {}
        local seen = {}
        while sqlite.sqlite3_step(stmt_p[0]) == SQLITE_ROW do
            local fpath = ffi.string(sqlite.sqlite3_column_text(stmt_p[0], 0))
            local fname = ffi.string(sqlite.sqlite3_column_text(stmt_p[0], 1))
            local canon_path = normalize_path(fpath)
            if not seen[canon_path] then
                seen[canon_path] = true
                table.insert(results, { filepath = canon_path, filename = fname, snippet = "", rank = 0.0 })
                if limit and limit > 0 and #results >= limit then break end
            end
        end
        sqlite.sqlite3_finalize(stmt_p[0])
        return results
    end

    -- Handle empty / wildcard search when extension filter is set (e.g. typing @lua in TUI)
    if (#query_str == 0 or query_str == "*" or query_str:match("^%s*$")) and ext_filter and #ext_filter > 0 then
        local sql = string.format("SELECT filepath, filename, '' AS snip, 0.0 AS rank FROM files WHERE extension = '%s' ORDER BY filename%s;",
            ext_filter:gsub("'", "''"),
            (limit and limit > 0) and (" LIMIT " .. (limit * 3)) or "")
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then
            return {}
        end
        local results = {}
        local seen = {}
        while sqlite.sqlite3_step(stmt_p[0]) == SQLITE_ROW do
            local fpath = ffi.string(sqlite.sqlite3_column_text(stmt_p[0], 0))
            local fname = ffi.string(sqlite.sqlite3_column_text(stmt_p[0], 1))
            local canon_path = normalize_path(fpath)
            if not seen[canon_path] then
                seen[canon_path] = true
                table.insert(results, { filepath = canon_path, filename = fname, snippet = "", rank = 0.0 })
                if limit and limit > 0 and #results >= limit then break end
            end
        end
        sqlite.sqlite3_finalize(stmt_p[0])
        return results
    end

    -- Sanitize/escape query string for FTS5
    -- If user did not wrap in quotes and has no special syntax, wrap tokens or support prefix.
    -- #5: Preserve boolean operators (AND, OR, NOT) so users can use multi-token OR/NOT queries.
    local fts_query = query_str
    if not query_str:find('"') and not query_str:find("%*") then
        local words = {}
        for w in query_str:gmatch("%S+") do
            if w == "OR" or w == "AND" or w == "NOT" then
                table.insert(words, w)
            else
                local escaped = w:gsub('"', '""')
                table.insert(words, string.format('"%s"*', escaped))
            end
        end
        local join_sep = (options.op == "OR" or options["or"]) and " OR " or " "
        fts_query = table.concat(words, join_sep)
    end

    if #fts_query == 0 then return {} end

    local sql
    if ext_filter and #ext_filter > 0 then
        sql = string.format([=[
            SELECT 
                c.filepath,
                c.filename,
                snippet(code_idx, 2, '[[HL]]', '[[/HL]]', '...', 16) AS snip,
                bm25(code_idx) AS rank
            FROM code_idx c
            JOIN files f ON c.filepath = f.filepath
            WHERE code_idx MATCH ? AND f.extension = '%s'
            ORDER BY rank ASC%s;
        ]=], ext_filter:gsub("'", "''"), limit_clause)
    else
        sql = string.format([=[
            SELECT 
                filepath,
                filename,
                snippet(code_idx, 2, '[[HL]]', '[[/HL]]', '...', 16) AS snip,
                bm25(code_idx) AS rank
            FROM code_idx
            WHERE code_idx MATCH ?
            ORDER BY rank ASC%s;
        ]=], limit_clause)
    end

    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil)
    if rc ~= SQLITE_OK then
        -- Try direct match without prefix wildcard if syntax error
        local fallback_sql = string.format([=[
            SELECT filepath, filename, snippet(code_idx, 2, '[[HL]]', '[[/HL]]', '...', 16), bm25(code_idx)
            FROM code_idx WHERE code_idx MATCH ? ORDER BY bm25(code_idx) ASC%s;
        ]=], limit_clause)
        if sqlite.sqlite3_prepare_v2(self.db, fallback_sql, #fallback_sql, stmt_p, nil) ~= SQLITE_OK then
            return {}, "Invalid search query syntax: " .. query_str
        end
        fts_query = string.format('"%s"', query_str:gsub('"', '""'))
    end

    local stmt = stmt_p[0]
    sqlite.sqlite3_bind_text(stmt, 1, fts_query, #fts_query, SQLITE_TRANSIENT)

    local results = {}
    local seen = {}
    while sqlite.sqlite3_step(stmt) == SQLITE_ROW do
        local fpath = ffi.string(sqlite.sqlite3_column_text(stmt, 0))
        local fname = ffi.string(sqlite.sqlite3_column_text(stmt, 1))
        local snip  = ffi.string(sqlite.sqlite3_column_text(stmt, 2))
        local rank  = sqlite.sqlite3_column_double(stmt, 3)

        local canon_path = normalize_path(fpath)
        if not seen[canon_path] then
            seen[canon_path] = true
            table.insert(results, {
                filepath = canon_path,
                filename = fname,
                snippet  = snip,
                rank     = rank
            })
            if limit and limit > 0 and #results >= limit then
                break
            end
        end
    end
    sqlite.sqlite3_finalize(stmt)
    return results
end

function Database:set_meta(key, value)
    local sql = "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);"
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then return false end
    sqlite.sqlite3_bind_text(stmt_p[0], 1, key, #key, SQLITE_TRANSIENT)
    local vs = tostring(value)
    sqlite.sqlite3_bind_text(stmt_p[0], 2, vs, #vs, SQLITE_TRANSIENT)
    sqlite.sqlite3_step(stmt_p[0])
    sqlite.sqlite3_finalize(stmt_p[0])
    return true
end

function Database:get_meta(key)
    local sql = "SELECT value FROM meta WHERE key = ?;"
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then return nil end
    sqlite.sqlite3_bind_text(stmt_p[0], 1, key, #key, SQLITE_TRANSIENT)
    local val = nil
    if sqlite.sqlite3_step(stmt_p[0]) == SQLITE_ROW then
        local t = sqlite.sqlite3_column_text(stmt_p[0], 0)
        if t ~= nil then val = ffi.string(t) end
    end
    sqlite.sqlite3_finalize(stmt_p[0])
    return val
end

function Database:get_stats()
    local stats = { total_files = 0, total_size = 0, extensions = {}, last_index = nil }
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    local sql = "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files;"
    if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
        if sqlite.sqlite3_step(stmt_p[0]) == SQLITE_ROW then
            stats.total_files = tonumber(sqlite.sqlite3_column_int64(stmt_p[0], 0))
            stats.total_size  = tonumber(sqlite.sqlite3_column_int64(stmt_p[0], 1))
        end
        sqlite.sqlite3_finalize(stmt_p[0])
    end

    local sql_ext = "SELECT extension, COUNT(*) FROM files GROUP BY extension ORDER BY COUNT(*) DESC;"
    if sqlite.sqlite3_prepare_v2(self.db, sql_ext, #sql_ext, stmt_p, nil) == SQLITE_OK then
        while sqlite.sqlite3_step(stmt_p[0]) == SQLITE_ROW do
            local ext = ffi.string(sqlite.sqlite3_column_text(stmt_p[0], 0))
            local cnt = tonumber(sqlite.sqlite3_column_int(stmt_p[0], 1))
            table.insert(stats.extensions, { ext = (ext == "" and "[none]" or ext), count = cnt })
        end
        sqlite.sqlite3_finalize(stmt_p[0])
    end

    -- Read last index timestamp from meta table (may not exist on older DBs)
    stats.last_index = self:get_meta("last_index")

    return stats
end


--------------------------------------------------------------------------------
-- 4. Fast Directory Walker & File Classifier
--------------------------------------------------------------------------------
local IGNORED_DIRS = {
    -- VCS & IDE metadata
    [".git"] = true,
    [".svn"] = true,
    [".hg"] = true,
    [".vscode"] = true,
    [".idea"] = true,
    [".settings"] = true,

    -- Cache directories
    ["__pycache__"] = true,
    [".pytest_cache"] = true,
    [".mypy_cache"] = true,
    [".cache"] = true,

    -- Build & Output directories
    ["build"] = true,
    ["_output"] = true,
    ["dist"] = true,
    ["out"] = true,
    ["target"] = true,
    ["Debug"] = true,
    ["debug"] = true,
    ["Release"] = true,
    ["release"] = true,
    ["cudafe1"] = true,

    -- Package managers & virtual environments
    ["node_modules"] = true,
    ["webapp"] = true,
    ["virtualenv"] = true,
    ["venv"] = true,
    [".venv"] = true,
    ["env"] = true,
    ["Anaconda"] = true,
    ["anaconda"] = true,

    -- Third-party & vendor libraries (as in dotag.py)
    ["3rdParty"] = true,
    ["ThirdParty"] = true,
    ["third_party"] = true,
    ["3rdparty"] = true,
    ["boost"] = true,
    ["Omni"] = true,
    ["Generated"] = true,
    ["jazz"] = true,
    ["PythonStandardLibrary"] = true,
    ["OpenThreads"] = true,
    ["OpenCV"] = true
}

local BINARY_EXTENSIONS = {
    ["so"] = true, ["dll"] = true, ["dylib"] = true, ["a"] = true, ["o"] = true,
    ["exe"] = true, ["bin"] = true, ["png"] = true, ["jpg"] = true, ["jpeg"] = true,
    ["gif"] = true, ["bmp"] = true, ["webp"] = true, ["mp3"] = true, ["mp4"] = true,
    ["zip"] = true, ["tar"] = true, ["gz"] = true, ["bz2"] = true, ["xz"] = true,
    ["pdf"] = true, ["db"] = true, ["sqlite"] = true, ["sqlite3"] = true, ["iso"] = true
}

-- Comprehensive allowlist of source code and configuration extensions
local SOURCE_EXTENSIONS = {
    -- C / C++ / CUDA / Assembly
    ["c"] = true, ["h"] = true, ["cpp"] = true, ["hpp"] = true, ["cc"] = true, ["hh"] = true,
    ["cxx"] = true, ["hxx"] = true, ["inl"] = true, ["inc"] = true, ["asm"] = true, ["s"] = true,
    ["cu"] = true, ["cuh"] = true, ["idl"] = true, ["rc"] = true, ["mc"] = true, ["sdl"] = true,
    -- Scripting & Dynamic languages
    ["lua"] = true, ["luau"] = true, ["py"] = true, ["pyw"] = true, ["rb"] = true, ["php"] = true,
    ["pl"] = true, ["pm"] = true, ["tcl"] = true, ["awk"] = true, ["sed"] = true,
    ["bat"] = true, ["cmd"] = true,
    -- Systems & Compiled languages
    ["rs"] = true, ["go"] = true, ["zig"] = true, ["d"] = true, ["nim"] = true, ["v"] = true,
    ["odin"] = true, ["f"] = true, ["f90"] = true, ["f95"] = true, ["ada"] = true,
    -- JVM & Mobile languages
    ["java"] = true, ["kt"] = true, ["kts"] = true, ["scala"] = true, ["groovy"] = true,
    ["swift"] = true, ["m"] = true, ["mm"] = true, ["dart"] = true, ["cs"] = true,
    -- Web & Frontend
    ["js"] = true, ["jsx"] = true, ["ts"] = true, ["tsx"] = true, ["mjs"] = true, ["cjs"] = true,
    ["vue"] = true, ["svelte"] = true, ["html"] = true, ["htm"] = true, ["css"] = true,
    ["scss"] = true, ["sass"] = true, ["less"] = true,
    -- Functional & Scientific languages
    ["hs"] = true, ["lhs"] = true, ["ml"] = true, ["mli"] = true, ["fs"] = true, ["fsi"] = true,
    ["clj"] = true, ["cljs"] = true, ["lisp"] = true, ["el"] = true, ["r"] = true, ["jl"] = true,
    ["erl"] = true, ["hrl"] = true, ["ex"] = true, ["exs"] = true,
    -- Shell, Build, Config & Specs
    ["sh"] = true, ["bash"] = true, ["zsh"] = true, ["fish"] = true,
    ["cmake"] = true, ["make"] = true, ["mk"] = true, ["dockerfile"] = true,
    ["yaml"] = true, ["yml"] = true, ["toml"] = true, ["json"] = true,
    ["md"] = true, ["markdown"] = true, ["rst"] = true, ["sql"] = true,
    ["proto"] = true, ["graphql"] = true, ["gql"] = true, ["ini"] = true, ["conf"] = true
}

local SPECIAL_SOURCE_FILES = {
    ["makefile"] = true,
    ["cmakelists.txt"] = true,
    ["dockerfile"] = true,
    ["rakefile"] = true,
    ["gemfile"] = true,
    ["vagrantfile"] = true,
    ["build.gradle"] = true
}

local function is_source_file(filename, ext)
    if SOURCE_EXTENSIONS[ext] then return true end
    if SPECIAL_SOURCE_FILES[filename:lower()] then return true end
    return false
end

local function get_file_extension(path)
    local ext = path:match("%.([%w_%-]+)$")
    return ext and ext:lower() or ""
end

local function has_ignored_dir(path)
    if not path then return false end
    for segment in path:gmatch("[^/\\]+") do
        if IGNORED_DIRS[segment] then return true end
    end
    return false
end

detect_available_finders = function()
    local finders = {
        builtin = {
            name = "builtin",
            label = "Native LuaJIT FFI (FindFirstFile / opendir, zero dependencies)",
            available = true,
            path = "builtin"
        }
    }

    -- Check fd / fdfind
    local fd_cmd = is_windows and "where fd.exe 2>nul" or "which fd 2>/dev/null || which fdfind 2>/dev/null"
    local p = io.popen(fd_cmd, "r")
    if p then
        local line = p:read("*l")
        p:close()
        if line and #line > 0 then
            local vp_cmd = is_windows and "fd --version 2>nul" or "fd --version 2>/dev/null"
            local vp = io.popen(vp_cmd, "r")
            if vp then
                local vl = vp:read("*l")
                vp:close()
                if vl and #vl > 0 then vstr = vl end
            end
            finders.fd = {
                name = "fd",
                label = string.format("fd (%s, fast multi-threaded)", vstr),
                available = true,
                path = line
            }
        end
    end

    -- Check POSIX find
    if not is_windows then
        local p = io.popen("which find 2>/dev/null", "r")
        if p then
            local line = p:read("*l")
            p:close()
            if line and #line > 0 then
                finders.find = {
                    name = "find",
                    label = "GNU/POSIX find (Standard Unix utility)",
                    available = true,
                    path = line
                }
            end
        end
    else
        local p = io.popen("find . -maxdepth 0 -type d 2>nul", "r")
        if p then
            local out = p:read("*a")
            p:close()
            if out and (out:find("%./") or out:find("%.")) then
                finders.find = {
                    name = "find",
                    label = "GNU/POSIX find (Git/Cygwin find)",
                    available = true,
                    path = "find"
                }
            end
        end
    end

    return finders
end

resolve_finder = function(requested_mode)
    local mode = requested_mode
    if not mode or #mode == 0 then
        mode = os.getenv("CODEFIND_FINDER")
    end
    if not mode or #mode == 0 then
        local cfg = read_config()
        mode = cfg.finder
    end
    mode = (mode or "auto"):lower()

    local available = detect_available_finders()

    if mode == "auto" then
        if available.fd and available.fd.available then
            return "fd"
        end
        return "builtin"
    elseif mode == "fd" then
        if available.fd and available.fd.available then
            return "fd"
        else
            return "builtin"
        end
    elseif mode == "find" then
        if available.find and available.find.available then
            return "find"
        else
            return "builtin"
        end
    elseif mode == "builtin" or mode == "native" then
        return "builtin"
    else
        return "builtin"
    end
end

local function scan_directory_builtin(root_dir, callback)
    root_dir = root_dir or "."
    root_dir = root_dir:gsub("\\", "/"):gsub("/+$", "")
    if root_dir == "" or root_dir == "./" then root_dir = "." end

    local function walk(current_dir)
        if is_windows then
            local find_pattern = current_dir .. "/*"
            local find_data = ffi.new("WIN32_FIND_DATAA")
            local hFind = kernel32.FindFirstFileA(find_pattern, find_data)
            if hFind == ffi.cast("void*", -1) or hFind == nil then return end

            repeat
                local name = ffi.string(find_data.cFileName)
                if name ~= "." and name ~= ".." then
                    local is_dir = bit.band(find_data.dwFileAttributes, 0x10) ~= 0
                    local full_path = (current_dir == ".") and name or (current_dir .. "/" .. name)
                    if is_dir then
                        if not IGNORED_DIRS[name] then walk(full_path) end
                    else
                        if not has_ignored_dir(full_path) then
                            callback(normalize_path(full_path), name)
                        end
                    end
                end
            until kernel32.FindNextFileA(hFind, find_data) == 0
            kernel32.FindClose(hFind)
        else
            local dir_p = ffi.C.opendir(current_dir)
            if dir_p == nil then return end

            while true do
                local entry = ffi.C.readdir(dir_p)
                if entry == nil then break end
                local name = ffi.string(entry.d_name)
                if name ~= "." and name ~= ".." then
                    local full_path = (current_dir == ".") and name or (current_dir .. "/" .. name)
                    local is_dir = (entry.d_type == 4)
                    local is_reg = (entry.d_type == 8)

                    -- Fallback stat if d_type is DT_UNKNOWN (0)
                    if entry.d_type == 0 then
                        local meta = get_file_metadata(full_path)
                        if meta then
                            is_dir = meta.is_dir
                            is_reg = meta.is_reg
                        end
                    end

                    if is_dir then
                        if not IGNORED_DIRS[name] then walk(full_path) end
                    elseif is_reg then
                        if not has_ignored_dir(full_path) then
                            callback(normalize_path(full_path), name)
                        end
                    end
                end
            end
            ffi.C.closedir(dir_p)
        end
    end

    walk(root_dir)
end

local function scan_directory_fd(root_dir, callback)
    root_dir = root_dir or "."
    root_dir = root_dir:gsub("\\", "/"):gsub("/+$", "")
    if root_dir == "" or root_dir == "./" then root_dir = "." end

    local null_dev = is_windows and "2>nul" or "2>/dev/null"
    local exclude_parts = {}
    for dir in pairs(IGNORED_DIRS) do
        table.insert(exclude_parts, string.format('--exclude "%s"', dir))
    end
    local exclude_str = table.concat(exclude_parts, " ")
    local search_path = (root_dir == ".") and "." or root_dir
    local cmd = string.format('fd --type f --hidden %s . "%s" %s', exclude_str, search_path, null_dev)
    local p = io.popen(cmd, "r")
    if not p then return false end
    for line in p:lines() do
        local raw = normalize_path(line:gsub("\r$", ""))
        if not has_ignored_dir(raw) then
            local fname = get_filename(raw)
            callback(raw, fname)
        end
    end
    p:close()
    return true
end

local function scan_directory_find(root_dir, callback)
    root_dir = root_dir or "."
    root_dir = root_dir:gsub("\\", "/"):gsub("/+$", "")
    if root_dir == "" or root_dir == "./" then root_dir = "." end

    local null_dev = is_windows and "2>nul" or "2>/dev/null"
    local search_path = (root_dir == ".") and "." or root_dir
    local cmd = string.format('find "%s" -type f %s', search_path, null_dev)
    local p = io.popen(cmd, "r")
    if not p then return false end
    for line in p:lines() do
        local raw = normalize_path(line:gsub("\r$", ""))
        if not has_ignored_dir(raw) then
            local fname = get_filename(raw)
            callback(raw, fname)
        end
    end
    p:close()
    return true
end

local function scan_directory(root_dir, callback, finder_mode)
    local active = resolve_finder(finder_mode)
    if active == "fd" then
        local ok = scan_directory_fd(root_dir, callback)
        if ok then return "fd" end
    elseif active == "find" then
        local ok = scan_directory_find(root_dir, callback)
        if ok then return "find" end
    end
    scan_directory_builtin(root_dir, callback)
    return "builtin"
end

--------------------------------------------------------------------------------
-- 5. Indexing Pipeline
--------------------------------------------------------------------------------
local Indexer = {}

function Indexer.run(db, root_dir, verbose, allow_all, finder_mode)
    root_dir = root_dir or "."
    -- strip trailing slash
    root_dir = root_dir:gsub("[/\\]+$", "")
    if #root_dir == 0 then root_dir = "." end

    local t_start = wall_now()

    local active_crawler = resolve_finder(finder_mode)

    -- Phase 1: Fast discovery and candidate filtering
    if verbose then
        io.write(string.format("\27[90m⚡ Discovering files (crawler: %s)...\27[0m", active_crawler))
        io.flush()
    end

    local candidate_files = {}
    local visited_paths = {}

    scan_directory(root_dir, function(full_path, fname)
        -- Ignore internal DB file itself
        if fname:find("%.db$") or fname:find("%.db%-wal$") or fname:find("%.db%-shm$") then return end

        local ext = get_file_extension(fname)

        -- Filter: Limit indexing to source code & config unless allow_all is set
        if not allow_all and not is_source_file(fname, ext) then
            return
        end

        if BINARY_EXTENSIONS[ext] then
            return
        end

        local canon = normalize_path(full_path)
        if visited_paths[canon] then
            return
        end
        visited_paths[canon] = true
        visited_paths[full_path] = true
        visited_paths[full_path:gsub("^%./", "")] = true
        visited_paths["./" .. full_path:gsub("^%./", "")] = true
        table.insert(candidate_files, { path = canon, name = fname, ext = ext })
    end, active_crawler)

    local total_files = #candidate_files
    if verbose then
        io.write(string.format("\r\27[2K🔍 Found %d candidate source files to index (crawler: %s)\n", total_files, active_crawler))
        io.flush()
    end

    local t_discovered = wall_now()

    -- Phase 2: Indexing pipeline with progress and ETA
    local files_indexed = 0
    local files_skipped = 0
    local large_skipped = 0    -- #10: track files skipped due to >5MB separately
    local total_bytes = 0
    local batch_count = 0
    local last_progress_time = 0

    local function render_progress(current_idx, force)
        if not verbose or total_files == 0 then return end
        local now = wall_now()
        if not force and (now - last_progress_time < 0.08) and (current_idx < total_files) then
            return
        end
        last_progress_time = now

        local elapsed = math.max(0.001, now - t_start)
        local progress_ratio = current_idx / total_files
        local pct = math.floor(progress_ratio * 100)
        local rate = current_idx / elapsed

        local elap_m, elap_s = math.floor(elapsed / 60), math.floor(elapsed % 60)
        local elapsed_str = string.format("%02d:%02d", elap_m, elap_s)

        -- Estimate time remaining (ETA)
        local remaining_files = total_files - current_idx
        local eta_seconds = (rate > 0) and math.max(0, math.floor(remaining_files / rate)) or 0
        local time_str
        if current_idx >= total_files then
            time_str = string.format("Elapsed: %s │ Done", elapsed_str)
        elseif eta_seconds >= 60 then
            time_str = string.format("Elapsed: %s │ ETA: %02dm%02ds", elapsed_str, math.floor(eta_seconds / 60), eta_seconds % 60)
        else
            time_str = string.format("Elapsed: %s │ ETA: %02ds", elapsed_str, eta_seconds)
        end

        -- Progress bar with 24 blocks
        local bar_w = 24
        local filled = math.min(bar_w, math.floor(progress_ratio * bar_w))
        local bar = "\27[32m" .. string.rep("█", filled) .. "\27[90m" .. string.rep("░", bar_w - filled) .. "\27[0m"

        local status_line = string.format("\r\27[2K[%s] %3d%% │ %d/%d files │ %.1f MB │ %d f/s │ %s",
            bar, pct, current_idx, total_files, total_bytes / (1024 * 1024), math.floor(rate), time_str)
        io.write(status_line)
        io.flush()
    end

    db:begin()

    for idx, item in ipairs(candidate_files) do
        local full_path = item.path
        local fname = item.name
        local ext = item.ext

        local meta = get_file_metadata(full_path)
        if not meta or meta.size > (5 * 1024 * 1024) then -- skip > 5MB single files
            if meta and meta.size > (5 * 1024 * 1024) then
                large_skipped = large_skipped + 1  -- #10: count large files separately
            end
            files_skipped = files_skipped + 1
        else
            -- Check if file already indexed and unchanged (must match size, mtime, and canonical path)
            local existing = db:get_file_info(full_path)
            if existing and existing.size == meta.size and existing.mtime == meta.mtime and existing.filepath == full_path then
                files_skipped = files_skipped + 1
            else
                local f = io.open(full_path, "rb")
                if not f then
                    files_skipped = files_skipped + 1
                else
                    local content = f:read("*a")
                    f:close()

                    if not content or is_binary_buffer(content) then
                        files_skipped = files_skipped + 1
                    else
                        db:index_file(full_path, fname, ext, meta.size, meta.mtime, content)
                        files_indexed = files_indexed + 1
                        total_bytes = total_bytes + meta.size
                        batch_count = batch_count + 1

                        if batch_count >= 500 then
                            db:commit()
                            db:begin()
                            batch_count = 0
                        end
                    end
                end
            end
        end

        render_progress(idx, false)
    end

    render_progress(total_files, true)
    if verbose and total_files > 0 then
        io.write("\n")
        io.flush()
    end

    -- Prune deleted / stale / duplicate files from database
    local files_pruned = 0
    local all_db_paths = db:get_all_filepaths()
    local norm_root = normalize_path(root_dir)
    local seen_db_canon = {}
    for _, db_path in ipairs(all_db_paths) do
        local canon_db = normalize_path(db_path)
        -- Only prune files that belong under root_dir
        local belongs = (norm_root == "" or norm_root == ".") or (canon_db == norm_root) or (canon_db:sub(1, #norm_root + 1) == (norm_root .. "/"))
        if belongs then
            if not visited_paths[canon_db] or seen_db_canon[canon_db] or db_path ~= canon_db then
                db:remove_file(db_path)
                files_pruned = files_pruned + 1
            else
                seen_db_canon[canon_db] = true
            end
        end
    end

    db:commit()

    -- #4: Write last_index timestamp to meta table
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    pcall(function() db:set_meta("last_index", ts) end)

    local elapsed = wall_now() - t_start
    local t_indexed = wall_now() - t_discovered

    if verbose then
        print(string.format("\27[32m✔ Indexing completed in %s\27[0m (%d files/sec)",
                            format_duration(elapsed),
                            math.floor(total_files / math.max(0.001, elapsed))))
        print(string.format("  - Scanned: %d files", total_files))
        print(string.format("  - Indexed/Updated: %d files (%.2f MB)", files_indexed, total_bytes / (1024*1024)))
        print(string.format("  - Unchanged/Skipped: %d files", files_skipped - large_skipped))
        if large_skipped > 0 then
            print(string.format("  - Too large (>5 MB): %d files  (skipped)", large_skipped))
        end
        if files_pruned > 0 then
            print(string.format("  - Pruned (deleted): %d files", files_pruned))
        end
        print(string.format("  \27[90m- Elapsed: %s total  |  crawler: %s (discover %s)  |  index+write %s\27[0m",
                            format_duration(elapsed), active_crawler, format_duration(t_discovered - t_start),
                            format_duration(t_indexed)))
    end

    return {
        scanned = total_files,
        indexed = files_indexed,
        skipped = files_skipped,
        large_skipped = large_skipped,
        pruned  = files_pruned,
        bytes   = total_bytes,
        time    = elapsed,
        crawler = active_crawler,
        discover_time = t_discovered - t_start,

        index_time    = t_indexed
    }
end

--------------------------------------------------------------------------------
-- 6. Highlighting & Terminal Formatting
--------------------------------------------------------------------------------

local function extract_file_matches(filepath, query_tokens, max_matches_per_file)
    max_matches_per_file = max_matches_per_file or 3
    local f = io.open(filepath, "r")
    if not f then return nil end

    local lines = {}
    for l in f:lines() do
        table.insert(lines, l)
    end
    f:close()

    local matching_line_indices = {}
    local lower_tokens = {}
    for _, tok in ipairs(query_tokens) do
        if #tok > 0 then table.insert(lower_tokens, tok:lower()) end
    end

    for idx, line in ipairs(lines) do
        local l_lower = line:lower()
        local matched = false
        for _, tok in ipairs(lower_tokens) do
            if l_lower:find(tok, 1, true) then
                matched = true
                break
            end
        end
        if matched then
            table.insert(matching_line_indices, idx)
            if #matching_line_indices >= max_matches_per_file then
                break
            end
        end
    end

    if #matching_line_indices == 0 then
        return nil
    end

    -- Build formatted match blocks with 1 line of context before and after
    local blocks = {}
    local covered = {}

    for _, match_ln in ipairs(matching_line_indices) do
        local start_ln = math.max(1, match_ln - 1)
        local end_ln = math.min(#lines, match_ln + 1)

        local block_lines = {}
        for ln = start_ln, end_ln do
            if not covered[ln] then
                covered[ln] = true
                local is_hit = (ln == match_ln)
                local content = lines[ln]
                
                -- Highlight query tokens on the hit line
                if is_hit then
                    for _, tok in ipairs(lower_tokens) do
                        local pat = tok:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
                        -- Case-insensitive replacement in pure Lua
                        content = content:gsub("(" .. pat .. ")", "\27[1;33m%1\27[0m")
                    end
                end

                local marker = is_hit and "\27[1;33m>\27[0m" or " "
                local line_str = string.format("   %s \27[90m%4d │\27[0m %s", marker, ln, content)
                table.insert(block_lines, line_str)
            end
        end
        if #block_lines > 0 then
            table.insert(blocks, table.concat(block_lines, "\n"))
        end
    end

    return {
        first_line = matching_line_indices[1],
        total_hits = #matching_line_indices,
        formatted = table.concat(blocks, "\n   \27[90m     ···\27[0m\n")
    }
end

local function colorize_snippet(snip)
    -- Format: replace [[HL]] with ANSI yellow bold, [[/HL]] with reset
    local res = snip:gsub("%[%[HL%]%]", "\27[1;33m"):gsub("%[%[/HL%]%]", "\27[0m")
    -- Format newlines with clean indentation
    res = res:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in res:gmatch("[^\n]+") do
        table.insert(lines, "      \27[90m│\27[0m " .. line)
    end
    return table.concat(lines, "\n")
end

local function sanitize_terminal_text(text)
    local sanitized = tostring(text)
        :gsub("\t", "    ")
        :gsub("[%z\1-\31\127]", " ")
    return sanitized
end

local function format_bytes(bytes)
    if bytes < 1024 then return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024)
    else return string.format("%.2f MB", bytes / (1024 * 1024))
    end
end

--------------------------------------------------------------------------------
-- 7. Interactive Terminal UI (TUI) Mode
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Preview highlighting patterns
--------------------------------------------------------------------------------
-- One case-insensitive Lua pattern per term in the query, used to highlight
-- matches in the TUI preview pane.
--
-- gsub returns (string, substitutions). As the final argument to table.insert
-- that second value expands into insert's optional `pos` parameter, so
-- table.insert(parts, ch:gsub(...)) is really insert(parts, str, count) and
-- raises "bad argument #2 (number expected, got string)" for every non-letter
-- character in the query -- which is why searching "job_", "log2024" or
-- "user.name" crashed the preview. Parentheses truncate it to one value.
local function build_preview_patterns(query_str)
    local terms, patterns = {}, {}
    for term in tostring(query_str or ""):gmatch("[%w_%-]+") do
        terms[#terms + 1] = term:lower()
        local ci_parts = {}
        for ch in term:gmatch(".") do
            local lo, up = ch:lower(), ch:upper()
            if lo ~= up then
                ci_parts[#ci_parts + 1] = "[" .. lo .. up .. "]"
            else
                ci_parts[#ci_parts + 1] = (lo:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
            end
        end
        patterns[#patterns + 1] = table.concat(ci_parts)
    end
    return terms, patterns
end

--------------------------------------------------------------------------------
-- Stream / Windowed Preview Reader
--------------------------------------------------------------------------------
-- Caches a sliding window of lines around the active cursor/match offset on
-- demand, allowing files of arbitrary size (10k, 50k, 100k+ lines) to be previewed
-- and searched with minimal memory footprint and zero disk I/O on nearby navigation.
local function make_preview_reader(window_size, max_cached_files)
    local win_size = window_size or 1000
    local max_files = max_cached_files or 16
    local file_cache = {}
    local file_order = {}
    local line_count_cache = {}

    local function get_total_lines(filepath)
        if not filepath then return 0 end
        if line_count_cache[filepath] then return line_count_cache[filepath] end
        local cnt = 0
        local f = io.open(filepath, "rb")
        if f then
            local has_any = false
            local last_byte = 0
            while true do
                local chunk = f:read(65536)
                if not chunk or #chunk == 0 then break end
                has_any = true
                local _, n = chunk:gsub("\n", "")
                cnt = cnt + n
                last_byte = chunk:byte(#chunk)
            end
            f:close()
            if has_any and last_byte ~= 10 then cnt = cnt + 1 end
        end
        line_count_cache[filepath] = cnt
        return cnt
    end


    local function touch_lru(filepath)
        for i, path in ipairs(file_order) do
            if path == filepath then
                table.remove(file_order, i)
                break
            end
        end
        table.insert(file_order, filepath)
        if #file_order > max_files then
            local oldest = table.remove(file_order, 1)
            file_cache[oldest] = nil
        end
    end

    local function load_window(filepath, target_start)
        local f = io.open(filepath, "r")
        local loaded = {}
        if f then
            local curr = 0
            for l in f:lines() do
                curr = curr + 1
                if curr >= target_start then
                    table.insert(loaded, l)
                    if #loaded >= win_size then break end
                end
            end
            f:close()
        end
        return loaded
    end

    local function get_line(filepath, line_num)
        if not filepath or not line_num or line_num < 1 then return "" end
        local total = get_total_lines(filepath)
        if line_num > total then return "" end

        local entry = file_cache[filepath]
        if not entry then
            local start_ln = math.max(1, line_num - math.floor(win_size / 2))
            local lines = load_window(filepath, start_ln)
            entry = {
                window_start = start_ln,
                lines = lines
            }
            file_cache[filepath] = entry
            touch_lru(filepath)
        else
            touch_lru(filepath)
            local offset = line_num - entry.window_start + 1
            if offset < 1 or offset > #entry.lines then
                local start_ln = math.max(1, line_num - math.floor(win_size / 2))
                entry.window_start = start_ln
                entry.lines = load_window(filepath, start_ln)
            end
        end

        local offset = line_num - entry.window_start + 1
        if offset >= 1 and offset <= #entry.lines then
            return entry.lines[offset] or ""
        end
        return ""
    end

    local function find_matches(filepath, terms)
        local match_lines = {}
        local match_list = {}
        local total_lines = 0

        if not filepath then return match_lines, match_list, 0 end
        local has_terms = terms and #terms > 0
        if not has_terms then
            total_lines = get_total_lines(filepath)
            return match_lines, match_list, total_lines
        end

        local f = io.open(filepath, "r")
        if f then
            for line in f:lines() do
                total_lines = total_lines + 1
                local l_lower = line:lower()
                for _, term in ipairs(terms) do
                    if l_lower:find(term, 1, true) then
                        match_lines[total_lines] = true
                        table.insert(match_list, total_lines)
                        break
                    end
                end
            end
            f:close()
            line_count_cache[filepath] = total_lines
        else
            total_lines = get_total_lines(filepath)
        end

        return match_lines, match_list, total_lines
    end

    return {
        get_line = get_line,
        get_total_lines = get_total_lines,
        find_matches = find_matches,
        file_cache = file_cache,
    }
end

local function visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local w = 0
    for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #c == 1 then
            w = w + 1
        elseif (c >= "─" and c <= "╿") or (c >= "┌" and c <= "▟") or c == "▶" then
            w = w + 1
        else
            w = w + 2
        end
    end
    return w
end

local function truncate(str, max_w)
    local len = visual_len(str)
    if len <= max_w then return str end
    if max_w <= 3 then return string.rep(".", math.max(0, max_w)) end

    local out = {}
    local curr = 0
    local pos = 1
    local raw = tostring(str)
    while pos <= #raw and curr < max_w - 3 do
        local ansi = raw:match("^\27%[[%d;]*[mK]", pos)
        if ansi then
            table.insert(out, ansi)
            pos = pos + #ansi
        else
            local c = raw:match("^[%z\1-\127\194-\244][\128-\191]*", pos)
            if c then
                local cw = 1
                if #c > 1 and not ((c >= "─" and c <= "╿") or (c >= "┌" and c <= "▟") or c == "▶") then
                    cw = 2
                end
                if curr + cw > max_w - 3 then break end
                table.insert(out, c)
                curr = curr + cw
                pos = pos + #c
            else
                break
            end
        end
    end
    local has_ansi = (raw:find("\27[", 1, true) ~= nil)
    return table.concat(out) .. "..." .. (has_ansi and "\27[0m" or "")
end

local function pad_to(str, target_width)
    local s = truncate(str, target_width)
    local vlen = visual_len(s)
    if vlen < target_width then
        return s .. string.rep(" ", target_width - vlen)
    else
        return s
    end
end

local function format_footer_pill(key, desc)
    return string.format("\27[1;30;46m %s \27[0;37;40m %s \27[0m", key, desc)
end

local function footer_pill_width(key, desc)
    return visual_len(key) + visual_len(desc) + 4
end

local function format_query_prompt(query, cursor_pos, avail_w, is_focused)
    query = query or ""
    cursor_pos = math.max(1, math.min(#query + 1, cursor_pos or (#query + 1)))
    local prefix = " > "
    local prefix_w = 3
    local text_w = math.max(4, avail_w - prefix_w)

    if #query == 0 then
        if is_focused then
            local hint = " (F1: help)"
            if text_w >= 1 + #hint then
                return prefix .. "|\27[90m" .. hint .. "\27[0m"
            else
                return prefix .. "|"
            end
        else
            return prefix .. "\27[90m(search)\27[0m"
        end
    end

    if not is_focused then
        if #query <= text_w then
            return prefix .. query
        else
            return prefix .. query:sub(1, text_w - 1) .. "\27[90m>\27[0m"
        end
    end

    local cursor = "\27[1;36m|\27[0m"
    if #query + 1 <= text_w then
        local before = query:sub(1, cursor_pos - 1)
        local after = query:sub(cursor_pos)
        return prefix .. before .. cursor .. after
    end

    -- Windowing when query + cursor exceeds text_w
    local lead = ""
    local trail = ""
    local start_idx, end_idx
    if cursor_pos <= text_w - 1 then
        trail = "\27[90m>\27[0m"
        local q_cap = text_w - 2
        start_idx = 1
        end_idx = math.min(#query, start_idx + q_cap - 1)
    elseif cursor_pos > #query - (text_w - 3) then
        lead = "\27[90m<\27[0m"
        local q_cap = text_w - 2
        end_idx = #query
        start_idx = math.max(1, end_idx - q_cap + 1)
    else
        lead = "\27[90m<\27[0m"
        trail = "\27[90m>\27[0m"
        local q_cap = math.max(1, text_w - 3)
        local half = math.floor(q_cap / 2)
        start_idx = math.max(1, cursor_pos - half)
        end_idx = math.min(#query, start_idx + q_cap - 1)
        if end_idx - start_idx + 1 < q_cap then
            start_idx = math.max(1, end_idx - q_cap + 1)
        end
    end

    local before = ""
    local after = ""
    if cursor_pos > start_idx then
        before = query:sub(start_idx, cursor_pos - 1)
    end
    if cursor_pos <= end_idx then
        after = query:sub(cursor_pos, end_idx)
    end
    return prefix .. lead .. before .. cursor .. after .. trail
end

local function get_empty_state_left_lines(query, text_w)
    query = query or ""
    text_w = text_w or 40
    local lines = {}
    if #query == 0 then
        lines[1] = ""
        if text_w >= 36 then
            lines[2] = "  \27[1;36m🔍 CodeFind — Local Code Search\27[0m"
        else
            lines[2] = "  \27[1;36m🔍 CodeFind\27[0m"
        end
        lines[3] = "  \27[90mType keywords to search code or files.\27[0m"
        lines[4] = ""
        lines[5] = "  \27[1;37mSearch Syntax:\27[0m"
        if text_w >= 36 then
            lines[6] = "    \27[1m•\27[0m Wildcard  : \27[33mterm*\27[0m"
            lines[7] = "    \27[1m•\27[0m Boolean   : \27[33ma AND b\27[0m, \27[33ma OR b\27[0m"
            lines[8] = "    \27[1m•\27[0m Phrase    : \27[33m\"exact match\"\27[0m"
            lines[9] = "    \27[1m•\27[0m File path : \27[33mfiles:*.lua\27[0m"
            lines[10] = "   \27[1m•\27[0m Extension : \27[33m@lua\27[0m, \27[33m@c\27[0m, \27[33m@py\27[0m"
        else
            lines[6] = "  \27[1m•\27[0m Wildcard : \27[33mterm*\27[0m"
            lines[7] = "  \27[1m•\27[0m Boolean  : \27[33ma OR b\27[0m"
            lines[8] = "  \27[1m•\27[0m Phrase   : \27[33m\"match\"\27[0m"
            lines[9] = "  \27[1m•\27[0m Files    : \27[33mfiles:pat\27[0m"
            lines[10] = "  \27[1m•\27[0m Filter   : \27[33m@lua\27[0m"
        end
        lines[11] = ""
        lines[12] = "  \27[90m(Press F1 or ? for help)\27[0m"
    else
        lines[1] = ""
        if text_w >= 34 then
            local q_disp = truncate(query, math.max(4, text_w - 24))
            lines[2] = string.format("  \27[1;33m⚠ No matches found\27[0m for '%s'", q_disp)
        else
            lines[2] = "  \27[1;33m⚠ No matches found\27[0m"
        end
        lines[3] = ""
        lines[4] = "  \27[1;36mSearch Suggestions:\27[0m"
        if text_w >= 36 then
            lines[5] = "    \27[1m•\27[0m Wildcard search : \27[33mterm*\27[0m"
            lines[6] = "    \27[1m•\27[0m Boolean OR      : \27[33mterm1 OR term2\27[0m"
            lines[7] = "    \27[1m•\27[0m Exact phrase    : \27[33m\"exact words\"\27[0m"
            lines[8] = "    \27[1m•\27[0m Filename search : \27[33mfiles:*.ext\27[0m"
            lines[9] = "    \27[1m•\27[0m Filter by ext   : \27[33m@lua\27[0m or \27[33m@c\27[0m"
        else
            lines[5] = "  \27[1m•\27[0m Wildcard : \27[33mterm*\27[0m"
            lines[6] = "  \27[1m•\27[0m Boolean  : \27[33ma OR b\27[0m"
            lines[7] = "  \27[1m•\27[0m Phrase   : \27[33m\"words\"\27[0m"
            lines[8] = "  \27[1m•\27[0m Files    : \27[33mfiles:pat\27[0m"
            lines[9] = "  \27[1m•\27[0m Filter   : \27[33m@ext\27[0m"
        end
        lines[10] = ""
        lines[11] = "  \27[90m(Press F1 or ? for full help)\27[0m"
    end
    return lines
end

local function get_empty_state_right_lines(query, avail_w)
    avail_w = avail_w or 40
    local lines = {}
    lines[1] = ""
    lines[2] = "  \27[1;36mCodeFind & FTS5 Search Reference\27[0m"
    local div_len = math.max(10, math.min(avail_w - 4, 54))
    lines[3] = "  \27[90m" .. string.rep("─", div_len) .. "\27[0m"
    lines[4] = "  \27[1;37mWildcard / Prefix\27[0m   \27[33mterm*\27[0m           Match identifiers starting with 'term'"
    lines[5] = "  \27[1;37mImplicit AND\27[0m        \27[33mopen sqlite\27[0m     Match documents containing all words"
    lines[6] = "  \27[1;37mBoolean OR\27[0m          \27[33mfoo OR bar\27[0m      Match either keyword"
    lines[7] = "  \27[1;37mNegation / NOT\27[0m      \27[33mauth NOT test\27[0m   Exclude matching terms"
    lines[8] = "  \27[1;37mExact Phrase\27[0m        \27[33m\"int main()\"\27[0m    Preserve exact spaces and punctuation"
    lines[9] = "  \27[1;37mFilename Search\27[0m     \27[33mfiles:*.lua\27[0m     Search file paths instead of content"
    lines[10] = "  \27[1;37mExtension Filter\27[0m    \27[35m@lua\27[0m, \27[35m@c\27[0m, \27[35m@py\27[0m   Quick filter results by extension"
    lines[11] = ""
    lines[12] = "  \27[1;36mKeyboard Controls\27[0m"
    lines[13] = "  \27[90m" .. string.rep("─", div_len) .. "\27[0m"
    lines[14] = "  \27[1mTab\27[0m                 Toggle focus: Search Box ⇄ Preview / Browse"
    lines[15] = "  \27[1mEnter\27[0m               Execute search, or open match in $EDITOR"
    lines[16] = "  \27[1mF2 / z\27[0m              Toggle full-width pane zoom"
    lines[17] = "  \27[1m← / → / Home / End\27[0m Move cursor in search query (Ctrl-B / Ctrl-F)"
    lines[18] = "  \27[1mCtrl-U / Esc\27[0m        Clear search box / reset search"
    lines[19] = "  \27[1mF1 / ?\27[0m              Open full keyboard shortcuts & help overlay"
    return lines
end

local function compute_layout_geometry(cur_cols, cur_rows, focus_pane, is_zoomed)
    local is_narrow = (cur_cols < 75)
    local is_single_pane = is_narrow or (is_zoomed == true)
    local content_w = cur_cols - 2
    local left_col_w, right_col_w
    if is_single_pane then
        if focus_pane == "preview" then
            left_col_w = 0
            right_col_w = content_w
        else
            left_col_w = content_w
            right_col_w = 0
        end
    else
        left_col_w = math.max(34, math.floor((cur_cols - 3) * 0.44))
        right_col_w = cur_cols - 3 - left_col_w
    end
    local list_height = math.max(5, (cur_rows or 24) - 6)
    return {
        is_narrow = is_narrow,
        is_single_pane = is_single_pane,
        left_col_w = left_col_w,
        right_col_w = right_col_w,
        list_height = list_height,
        content_w = content_w
    }
end

local function build_footer_content(cur_cols, status_bar_msg, is_status_active, focus_pane, query, is_zoomed, is_single_pane)
    local inner_w = cur_cols - 2
    query = query or ""
    if is_single_pane == nil then
        is_single_pane = (cur_cols < 75) or (is_zoomed == true)
    end

    local tab_desc = is_single_pane and ((focus_pane == "search") and "Preview" or "Search")
                                     or ((focus_pane == "search") and "Browse" or "Search")
    local zoom_desc = is_zoomed and "Unzoom" or "Zoom"

    if not is_status_active or not status_bar_msg or status_bar_msg == "" then
        local pills = {}
        if focus_pane == "search" then
            pills = {
                {"Tab", tab_desc},
                {"F1", "Help"},
                {"Enter", "Open"},
                {"Esc", #query > 0 and "Clear" or "Exit"},
                {"F2", zoom_desc},
                {"@ext", "Filter"},
                {"^Q", "Quit"},
                {"^W", "Del Word"}
            }
        else
            pills = {
                {"Tab", tab_desc},
                {"?", "Help"},
                {"Enter", "Open"},
                {"z", zoom_desc},
                {"n/N", "Match"},
                {"j/k", "Scroll"},
                {"q", "Quit"},
                {"y", "Copy Path"}
            }
        end

        local parts = {}
        local curr_w = 0
        for _, item in ipairs(pills) do
            local key, desc = item[1], item[2]
            local item_w = footer_pill_width(key, desc)
            local sep_w = (#parts > 0) and 1 or 0
            if curr_w + sep_w + item_w <= inner_w then
                table.insert(parts, format_footer_pill(key, desc))
                curr_w = curr_w + sep_w + item_w
            else
                break
            end
        end
        local combined = table.concat(parts, " ")
        local pad_w = math.max(0, inner_w - curr_w)
        return combined .. string.rep(" ", pad_w)
    else
        -- Status notification active: split footer into Left (Alert) and Right (Persistent Pills)
        local msg = tostring(status_bar_msg)
        local badge_text, badge_bg, clean_msg
        if msg:find("^✔%s*") then
            badge_text = " DONE "
            badge_bg = "42" -- green
            clean_msg = msg:gsub("^✔%s*", "")
        elseif msg:find("^⚡%s*") then
            badge_text = " SYNC "
            badge_bg = "43" -- yellow
            clean_msg = msg:gsub("^⚡%s*", "")
        else
            badge_text = " INFO "
            badge_bg = "46" -- cyan
            clean_msg = msg
        end

        local badge_w = visual_len(badge_text)
        local min_right_w = 23 -- Room for at least [F1] Help / [^Q] Quit or [?] Help / [q] Quit
        local max_msg_w = math.max(15, inner_w - min_right_w - badge_w - 3)
        if visual_len(clean_msg) > max_msg_w then
            clean_msg = truncate(clean_msg, max_msg_w)
        end

        local left_w = badge_w + visual_len(clean_msg) + 2
        local left_str = string.format("\27[1;30;%sm%s\27[0;37;40m %s \27[0m", badge_bg, badge_text, clean_msg)

        local right_avail_w = math.max(0, inner_w - left_w - 1)
        local candidate_pills = (focus_pane == "search") and {
            {"Tab", tab_desc},
            {"Enter", "Open"},
            {"F1", "Help"},
            {"^Q", "Quit"}
        } or {
            {"Tab", tab_desc},
            {"Enter", "Open"},
            {"?", "Help"},
            {"q", "Quit"}
        }

        local chosen_pills = {}
        for start_idx = 1, #candidate_pills do
            local test_pills = {}
            local total_w = 0
            for k = start_idx, #candidate_pills do
                local item = candidate_pills[k]
                local item_w = footer_pill_width(item[1], item[2])
                local sep_w = (#test_pills > 0) and 1 or 0
                total_w = total_w + sep_w + item_w
                table.insert(test_pills, item)
            end
            if total_w <= right_avail_w then
                chosen_pills = test_pills
                break
            end
        end

        local right_parts = {}
        local right_w = 0
        for _, item in ipairs(chosen_pills) do
            local item_w = footer_pill_width(item[1], item[2])
            local sep_w = (#right_parts > 0) and 1 or 0
            table.insert(right_parts, format_footer_pill(item[1], item[2]))
            right_w = right_w + sep_w + item_w
        end

        local right_str = table.concat(right_parts, " ")
        local pad_w = math.max(0, inner_w - left_w - right_w)
        return left_str .. string.rep(" ", pad_w) .. right_str
    end
end

local function format_preview_gutter(line_num, total_lines, is_hit)
    local gutter_digits = math.max(3, #tostring(total_lines or 1))
    local gutter_w = gutter_digits + 5
    local gutter_fmt = is_hit and string.format("\27[1;33m> \27[90m%%%dd │ \27[0m", gutter_digits)
                               or string.format("  \27[90m%%%dd │ \27[0m", gutter_digits)
    return string.format(gutter_fmt, line_num), gutter_w, gutter_digits
end

local TUI = {}

function TUI.run(db, initial_query, tui_limit)
    -- Check if running in an interactive terminal
    if not is_windows then
        if ffi.C.isatty(0) == 0 then
            print("Note: TUI mode requires an interactive terminal (stdin is not a TTY).")
            return false
        end
    end

    local orig_termios = nil
    local orig_in_mode = is_windows and ffi.new("uint32_t[1]") or nil
    local orig_out_mode = is_windows and ffi.new("uint32_t[1]") or nil
    local in_raw_mode = false

    local function enable_raw()
        if is_windows then
            if not kernel32 then return false end
            local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
            local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
            if kernel32.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end
            kernel32.GetConsoleMode(hOut, orig_out_mode)

            kernel32.SetConsoleOutputCP(65001)
            local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            kernel32.SetConsoleMode(hOut, bit.bor(orig_out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))

            local raw_mode = bit.band(orig_in_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
            kernel32.SetConsoleMode(hIn, raw_mode)

            in_raw_mode = true
            io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
            io.flush()
            return true
        end

        orig_termios = ffi.new("struct termios")
        if ffi.C.tcgetattr(0, orig_termios) ~= 0 then return false end

        local raw = ffi.new("struct termios")
        ffi.copy(raw, orig_termios, ffi.sizeof("struct termios"))
        -- Disable ICANON, ECHO, ISIG
        raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
        if ffi.C.tcsetattr(0, 0, raw) == 0 then
            in_raw_mode = true
            -- Switch to alternate screen buffer, hide cursor, disable auto-wrap, clear screen
            io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
            io.flush()
            return true
        end
        return false
    end

    local function disable_raw()
        if in_raw_mode then
            -- Leave alternate screen buffer, re-enable auto-wrap, show cursor, reset formatting
            io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
            io.flush()
            if is_windows then
                if kernel32 then
                    local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
                    local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
                    kernel32.SetConsoleMode(hIn, orig_in_mode[0])
                    kernel32.SetConsoleMode(hOut, orig_out_mode[0])
                end
            elseif orig_termios then
                ffi.C.tcsetattr(0, 0, orig_termios)
            end
            in_raw_mode = false
        end
    end

    if not enable_raw() then
        print("Error: Failed to initialize raw terminal mode.")
        return false
    end

    local function get_term_size()
        if is_windows then
            if kernel32 then
                local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
                local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
                if kernel32.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
                    local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
                    local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
                    if w > 0 and h > 0 then return tonumber(w), tonumber(h) end
                end
            end
        else
            local ws = ffi.new("struct winsize")
            if ffi.C.ioctl(1, (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
                return tonumber(ws.ws_col), tonumber(ws.ws_row)
            end
        end
        return 100, 30
    end

    local pfd = not is_windows and ffi.new("struct pollfd", { fd = 0, events = 1, revents = 0 }) or nil
    local key_buf = not is_windows and ffi.new("char[128]") or nil
    local key_queue = {}

    local function read_key(timeout_ms)
        if #key_queue > 0 then
            return table.remove(key_queue, 1)
        end
        timeout_ms = timeout_ms or 30

        if is_windows then
            local crt = msvcrt or ffi.C
            local elapsed = 0
            while elapsed < timeout_ms do
                if crt and crt._kbhit() ~= 0 then
                    local c0 = crt._getch()
                    if c0 == 0 or c0 == 224 then
                        local c1 = crt._getch()
                        if c1 == 72 then return "UP"
                        elseif c1 == 80 then return "DOWN"
                        elseif c1 == 75 then return "LEFT"
                        elseif c1 == 77 then return "RIGHT"
                        elseif c1 == 73 then return "PAGE_UP"
                        elseif c1 == 81 then return "PAGE_DOWN"
                        elseif c1 == 71 then return "HOME"
                        elseif c1 == 79 then return "END"
                        elseif c1 == 83 then return "DELETE"
                        elseif c1 == 59 or c1 == 84 or c1 == 94 or c1 == 104 then return "F1"
                        elseif c1 == 60 or c1 == 85 or c1 == 95 or c1 == 105 then return "F2"
                        end
                    elseif c0 == 27 then
                        local seq = ""
                        local t_wait = 0
                        while t_wait < 30 and crt._kbhit() == 0 do
                            if kernel32 then kernel32.Sleep(2) end
                            t_wait = t_wait + 2
                        end
                        while crt._kbhit() ~= 0 do
                            local c_next = crt._getch()
                            seq = seq .. string.char(c_next)
                        end
                        if #seq > 0 then
                            if seq == "OP" or seq == "[11~" or seq == "[[A" or seq:find("OP$") then
                                return "F1"
                            elseif seq == "OQ" or seq == "[12~" or seq == "[[B" or seq:find("OQ$") then
                                return "F2"
                            elseif seq == "[A" or seq == "OA" then return "UP"
                            elseif seq == "[B" or seq == "OB" then return "DOWN"
                            elseif seq == "[C" or seq == "OC" then return "RIGHT"
                            elseif seq == "[D" or seq == "OD" then return "LEFT"
                            elseif seq == "[5~" then return "PAGE_UP"
                            elseif seq == "[6~" then return "PAGE_DOWN"
                            elseif seq == "[3~" then return "DELETE"
                            elseif seq == "[H" or seq == "[1~" then return "HOME"
                            elseif seq == "[F" or seq == "[4~" then return "END"
                            elseif seq == "?" then return "?"
                            end
                        end
                        return "ESC"
                    elseif c0 == 9 then
                        return "TAB"
                    elseif c0 == 13 or c0 == 10 then
                        return "ENTER"
                    elseif c0 == 127 or c0 == 8 then
                        return "BACKSPACE"
                    elseif c0 == 21 then -- Ctrl-U
                        return "CTRL_U"
                    elseif c0 == 23 then -- Ctrl-W
                        return "CTRL_W"
                    elseif c0 == 1 then  -- Ctrl-A
                        return "CTRL_A"
                    elseif c0 == 5 then  -- Ctrl-E
                        return "CTRL_E"
                    elseif c0 == 2 then  -- Ctrl-B
                        return "CTRL_B"
                    elseif c0 == 6 then  -- Ctrl-F
                        return "CTRL_F"
                    elseif c0 == 14 then -- Ctrl-N
                        return "CTRL_N"
                    elseif c0 == 16 then -- Ctrl-P
                        return "CTRL_P"
                    elseif c0 == 11 then -- Ctrl-K
                        return "CTRL_K"
                    elseif c0 == 4 then -- Ctrl-D
                        return "CTRL_D"
                    elseif c0 == 18 then -- Ctrl-R
                        return "CTRL_R"
                    elseif c0 == 3 then -- Ctrl-C
                        return "CTRL_C"
                    elseif c0 == 17 then -- Ctrl-Q
                        return "CTRL_Q"
                    elseif c0 >= 32 and c0 <= 126 then
                        return string.char(c0)
                    end
                end
                if kernel32 then kernel32.Sleep(10) end
                elapsed = elapsed + 10
            end
            return nil
        end

        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, 1) ~= 0 then
            local n = ffi.C.read(0, key_buf, 128)
            if n > 0 then
                local idx = 0
                while idx < n do
                    local c0 = key_buf[idx]
                    if c0 == 27 then -- ESC sequence
                        if idx + 4 < n and key_buf[idx + 1] == 91 and key_buf[idx + 2] == 49 and key_buf[idx + 3] == 49 and key_buf[idx + 4] == 126 then -- ESC [ 1 1 ~ (F1)
                            table.insert(key_queue, "F1"); idx = idx + 5
                        elseif idx + 4 < n and key_buf[idx + 1] == 91 and key_buf[idx + 2] == 49 and key_buf[idx + 3] == 50 and key_buf[idx + 4] == 126 then -- ESC [ 1 2 ~ (F2)
                            table.insert(key_queue, "F2"); idx = idx + 5
                        elseif idx + 3 < n and key_buf[idx + 1] == 91 and key_buf[idx + 2] == 91 and key_buf[idx + 3] == 65 then -- ESC [ [ A (F1)
                            table.insert(key_queue, "F1"); idx = idx + 4
                        elseif idx + 3 < n and key_buf[idx + 1] == 91 and key_buf[idx + 2] == 91 and key_buf[idx + 3] == 66 then -- ESC [ [ B (F2)
                            table.insert(key_queue, "F2"); idx = idx + 4
                        elseif idx + 2 < n and key_buf[idx + 1] == 91 then -- '['
                            local c2 = key_buf[idx + 2]
                            if c2 == 65 then table.insert(key_queue, "UP"); idx = idx + 3
                            elseif c2 == 66 then table.insert(key_queue, "DOWN"); idx = idx + 3
                            elseif c2 == 67 then table.insert(key_queue, "RIGHT"); idx = idx + 3
                            elseif c2 == 68 then table.insert(key_queue, "LEFT"); idx = idx + 3
                            elseif c2 == 53 and idx + 3 < n and key_buf[idx + 3] == 126 then table.insert(key_queue, "PAGE_UP"); idx = idx + 4
                            elseif c2 == 54 and idx + 3 < n and key_buf[idx + 3] == 126 then table.insert(key_queue, "PAGE_DOWN"); idx = idx + 4
                            elseif c2 == 51 and idx + 3 < n and key_buf[idx + 3] == 126 then table.insert(key_queue, "DELETE"); idx = idx + 4
                            elseif c2 == 72 then table.insert(key_queue, "HOME"); idx = idx + 3
                            elseif c2 == 70 then table.insert(key_queue, "END"); idx = idx + 3
                            else table.insert(key_queue, "ESC"); idx = idx + 1 end
                        elseif idx + 2 < n and key_buf[idx + 1] == 79 and key_buf[idx + 2] == 80 then -- ESC O P (F1)
                            table.insert(key_queue, "F1"); idx = idx + 3
                        elseif idx + 2 < n and key_buf[idx + 1] == 79 and key_buf[idx + 2] == 81 then -- ESC O Q (F2)
                            table.insert(key_queue, "F2"); idx = idx + 3
                        elseif idx + 1 == n then
                            -- Only 1 byte ESC at end of buffer
                            local more = ffi.C.poll(pfd, 1, 15)
                            if more > 0 and bit.band(pfd.revents, 1) ~= 0 then
                                local got = ffi.C.read(0, key_buf + n, 128 - n)
                                if got > 0 then
                                    n = n + got
                                else
                                    table.insert(key_queue, "ESC")
                                    idx = idx + 1
                                end
                            else
                                table.insert(key_queue, "ESC")
                                idx = idx + 1
                            end
                        else
                            table.insert(key_queue, "ESC")
                            idx = idx + 1
                        end
                    elseif c0 == 10 or c0 == 13 then
                        table.insert(key_queue, "ENTER")
                        idx = idx + 1
                    elseif c0 == 9 then
                        table.insert(key_queue, "TAB")
                        idx = idx + 1
                    elseif c0 == 127 or c0 == 8 then
                        table.insert(key_queue, "BACKSPACE")
                        idx = idx + 1
                    elseif c0 == 21 then -- Ctrl-U
                        table.insert(key_queue, "CTRL_U")
                        idx = idx + 1
                    elseif c0 == 23 then -- Ctrl-W
                        table.insert(key_queue, "CTRL_W")
                        idx = idx + 1
                    elseif c0 == 1 then -- Ctrl-A
                        table.insert(key_queue, "CTRL_A")
                        idx = idx + 1
                    elseif c0 == 5 then -- Ctrl-E
                        table.insert(key_queue, "CTRL_E")
                        idx = idx + 1
                    elseif c0 == 2 then -- Ctrl-B
                        table.insert(key_queue, "CTRL_B")
                        idx = idx + 1
                    elseif c0 == 6 then -- Ctrl-F
                        table.insert(key_queue, "CTRL_F")
                        idx = idx + 1
                    elseif c0 == 14 then -- Ctrl-N
                        table.insert(key_queue, "CTRL_N")
                        idx = idx + 1
                    elseif c0 == 16 then -- Ctrl-P
                        table.insert(key_queue, "CTRL_P")
                        idx = idx + 1
                    elseif c0 == 11 then -- Ctrl-K
                        table.insert(key_queue, "CTRL_K")
                        idx = idx + 1
                    elseif c0 == 4 then -- Ctrl-D
                        table.insert(key_queue, "CTRL_D")
                        idx = idx + 1
                    elseif c0 == 18 then -- Ctrl-R
                        table.insert(key_queue, "CTRL_R")
                        idx = idx + 1
                    elseif c0 == 3 then -- Ctrl-C
                        table.insert(key_queue, "CTRL_C")
                        idx = idx + 1
                    elseif c0 == 17 then -- Ctrl-Q
                        table.insert(key_queue, "CTRL_Q")
                        idx = idx + 1
                    elseif c0 >= 32 and c0 <= 126 then
                        table.insert(key_queue, string.char(c0))
                        idx = idx + 1
                    else
                        idx = idx + 1
                    end
                end
            end
        end
        if #key_queue > 0 then
            return table.remove(key_queue, 1)
        end
        return nil
    end

    local query = initial_query or ""
    local cursor_pos = #query + 1
    local selected_idx = 1
    local list_scroll_offset = 0
    local preview_scroll_offset = 0
    local focus_pane = "search" -- "search" | "preview"
    local vim_mode = "INSERT" -- "INSERT" | "NORMAL"
    local results = {}
    local error_msg = nil
    local status_bar_msg = nil
    local status_bar_time = 0
    local show_help = false

    local current_preview_file = nil
    local current_preview_total_lines = 0
    local current_match_lines = {}
    local current_match_list = {}
    local current_match_pos = 1
    local current_preview_patterns = {}
    local needs_redraw = true
    local last_searched_query = nil

    local preview_reader = make_preview_reader(1000, 16)
    local preview_match_cache = {}

    local function get_file_line_count(filepath)
        return preview_reader.get_total_lines(filepath)
    end

    local function set_status(msg)
        status_bar_msg = msg
        status_bar_time = wall_now()
        needs_redraw = true
    end

    local function load_preview_for(filepath, query_str)
        if current_preview_file == filepath and current_preview_query == query_str then return end
        current_preview_file = filepath
        current_preview_query = query_str

        local cache_key = query_str or ""
        local cached_match = preview_match_cache[filepath] and preview_match_cache[filepath][cache_key]
        if cached_match then
            current_match_lines = cached_match.match_lines
            current_match_list = cached_match.match_list
            current_match_pos = 1
            preview_scroll_offset = cached_match.scroll_offset
            current_preview_patterns = cached_match.patterns or {}
            current_preview_total_lines = cached_match.total_lines or preview_reader.get_total_lines(filepath)
            -- #12: Show match count immediately on file load (from cache)
            if #current_match_list > 0 then
                set_status(string.format("📄 %s — %d match(es) [n/N to navigate]",
                    get_filename(filepath), #current_match_list))
            end
            return
        end

        current_match_lines = {}
        current_match_list = {}
        current_match_pos = 1
        preview_scroll_offset = 0

        local terms
        terms, current_preview_patterns = build_preview_patterns(query_str)

        local m_lines, m_list, tot_lines = preview_reader.find_matches(filepath, terms)
        current_match_lines = m_lines
        current_match_list = m_list
        current_preview_total_lines = tot_lines

        if #current_match_list > 0 then
            preview_scroll_offset = math.max(0, current_match_list[1] - 4)
            current_match_pos = 1
            -- #12: Show match count immediately on file load (fresh scan)
            set_status(string.format("📄 %s — %d match(es) [n/N to navigate]",
                get_filename(filepath), #current_match_list))
        end

        -- Warm up preview window around initial preview_scroll_offset
        preview_reader.get_line(filepath, preview_scroll_offset + 1)

        if not preview_match_cache[filepath] then
            preview_match_cache[filepath] = {}
        end
        preview_match_cache[filepath][cache_key] = {
            match_lines = current_match_lines,
            match_list = current_match_list,
            scroll_offset = preview_scroll_offset,
            patterns = current_preview_patterns,
            total_lines = current_preview_total_lines,
        }
    end


    local active_ext_filter = nil

    local function refresh_search()
        local raw_query = query or ""
        local ext_filt = nil
        local fts_q = raw_query
        fts_q = fts_q:gsub("@([%w_%-]+)", function(e)
            ext_filt = e:lower()
            return ""
        end)
        fts_q = fts_q:gsub("ext:([%w_%-]+)", function(e)
            ext_filt = e:lower()
            return ""
        end)
        fts_q = fts_q:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

        active_ext_filter = ext_filt

        if #raw_query == 0 then
            results = {}
            error_msg = nil
            current_preview_file = nil
            current_preview_query = nil
            current_preview_total_lines = 0
            current_match_lines = {}
            current_match_list = {}
            selected_idx = 1
            list_scroll_offset = 0
            needs_redraw = true
            return
        end

        local search_opts = { limit = (tui_limit and tui_limit > 0) and tui_limit or nil }
        if ext_filt then search_opts.extension = ext_filt end

        local res, err = db:search(#fts_q > 0 and fts_q or "*", search_opts)
        if err then
            error_msg = err
            results = {}
        else
            error_msg = nil
            results = res
            if selected_idx > #results then selected_idx = math.max(1, #results) end
            if #results > 0 and results[selected_idx] then
                load_preview_for(results[selected_idx].filepath, fts_q)
            end
        end
        last_searched_query = raw_query
        needs_redraw = true
    end

    refresh_search()

    local running = true

    local is_zoomed = false

    -- Cached layout dimensions (subtract 1 col to avoid hitting terminal auto-wrap edge)
    local raw_cols, raw_rows = get_term_size()
    local cur_cols = math.max(60, raw_cols - 1)
    local cur_rows = math.max(15, raw_rows)
    local init_geom = compute_layout_geometry(cur_cols, cur_rows, focus_pane, is_zoomed)
    local left_col_w = init_geom.left_col_w
    local right_col_w = init_geom.right_col_w
    local list_height = init_geom.list_height
    local is_single_pane = init_geom.is_single_pane
    local render_full_screen = nil
    local render_selection = nil

    local function clamp_scroll()
        local max_scroll = math.max(0, #results - list_height)
        if #results > 0 then
            selected_idx = math.max(1, math.min(#results, selected_idx))
        else
            selected_idx = 1
        end
        if selected_idx < list_scroll_offset + 1 then
            list_scroll_offset = selected_idx - 1
        elseif selected_idx > list_scroll_offset + list_height then
            list_scroll_offset = selected_idx - list_height
        end
        list_scroll_offset = math.max(0, math.min(list_scroll_offset, max_scroll))

        if current_preview_total_lines > 0 then
            preview_scroll_offset = math.max(0, math.min(current_preview_total_lines - 1, preview_scroll_offset))
        else
            preview_scroll_offset = 0
        end
    end

    local function update_layout(force_calc)
        local cols, rows = get_term_size()
        cols = math.max(60, cols - 1)
        rows = math.max(15, rows)
        local geom = compute_layout_geometry(cols, rows, focus_pane, is_zoomed)
        local size_changed = (cols ~= cur_cols or rows ~= cur_rows)
        local geom_changed = (geom.left_col_w ~= left_col_w or geom.right_col_w ~= right_col_w or geom.is_single_pane ~= is_single_pane)
        if size_changed or geom_changed or force_calc then
            cur_cols = cols
            cur_rows = rows
            left_col_w = geom.left_col_w
            right_col_w = geom.right_col_w
            list_height = geom.list_height
            is_single_pane = geom.is_single_pane
            clamp_scroll()
            if size_changed then
                io.write("\27[H\27[2J")
            end
            needs_redraw = true
        end
    end

    local function open_selected_in_editor()
        if #results > 0 and results[selected_idx] then
            disable_raw()
            local chosen = results[selected_idx].filepath
            local target_ln = (current_match_list and current_match_list[current_match_pos])
                           or (current_match_list and current_match_list[1])
                           or (preview_scroll_offset and preview_scroll_offset > 0 and (preview_scroll_offset + 1))
                           or 1
            local editor = os.getenv("EDITOR")
            if not editor or editor == "" then
                if not is_windows and os.execute("which nvim >/dev/null 2>&1") == 0 then
                    editor = "nvim"
                else
                    editor = "vim"
                end
            end
            local edit_cmd = string.format('%s +%d "%s"', editor, target_ln, chosen)
            os.execute(edit_cmd)

            -- Re-initialize raw terminal mode and alternate screen buffer
            enable_raw()
            io.write("\27[H\27[2J")
            io.flush()
            set_status(string.format("✔ Returned from %s (%s:%d)", editor, get_filename(chosen), target_ln))
            needs_redraw = true
        end
    end

    -- Lightweight fast syntax highlighter
    local SYNTAX_KEYWORDS = {
        ["local"] = true, ["function"] = true, ["return"] = true, ["end"] = true,
        ["if"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
        ["for"] = true, ["while"] = true, ["do"] = true, ["repeat"] = true, ["until"] = true,
        ["break"] = true, ["not"] = true, ["and"] = true, ["or"] = true,
        ["nil"] = true, ["true"] = true, ["false"] = true,
        ["int"] = true, ["char"] = true, ["void"] = true, ["const"] = true, ["static"] = true,
        ["struct"] = true, ["typedef"] = true, ["sizeof"] = true, ["uint8_t"] = true,
        ["uint16_t"] = true, ["uint32_t"] = true, ["uint64_t"] = true, ["int64_t"] = true,
        ["class"] = true, ["public"] = true, ["private"] = true, ["virtual"] = true,
        ["def"] = true, ["import"] = true, ["from"] = true, ["class"] = true,
        ["var"] = true, ["let"] = true, ["export"] = true, ["default"] = true
    }

    local function highlight_code_line(raw_line, ext, patterns, is_hit)
        local line = raw_line
        -- 1. Check for whole line or trailing comments
        local comment_pos = nil
        if ext == "c" or ext == "h" or ext == "cpp" or ext == "js" or ext == "ts" then
            comment_pos = line:find("//", 1, true)
        elseif ext == "lua" then
            comment_pos = line:find("%-%-")
        elseif ext == "py" or ext == "sh" or ext == "bash" or ext == "yaml" or ext == "toml" then
            comment_pos = line:find("#", 1, true)
        end

        local code_part = line
        local comment_part = ""
        if comment_pos then
            code_part = line:sub(1, comment_pos - 1)
            comment_part = "\27[90;3m" .. line:sub(comment_pos) .. "\27[0m"
        end

        -- 2. Numbers (highlighted before ANSI codes are added so ANSI digits aren't matched)
        code_part = code_part:gsub("(%f[%w_]%d+%f[^%w_])", "\27[36m%1\27[0m")

        -- 3. Strings ("..." or '...')
        code_part = code_part:gsub('(".-")', "\27[32m%1\27[0m")
        code_part = code_part:gsub("('.-')", "\27[32m%1\27[0m")

        -- 4. Preprocessor directives
        if ext == "c" or ext == "h" or ext == "cpp" then
            code_part = code_part:gsub("^(%s*#%w+)", "\27[1;35m%1\27[0m")
        end

        -- 5. Keywords
        code_part = code_part:gsub("([%a_][%w_]*)", function(word)
            if SYNTAX_KEYWORDS[word] then
                return "\27[1;34m" .. word .. "\27[0m"
            end
            return word
        end)

        local result = code_part .. comment_part

        -- 6. Highlight search hits only in visible text segments (never inside ANSI escapes)
        if is_hit and patterns and #patterns > 0 then
            local parts = {}
            local last_pos = 1
            local cur_color = "\27[0m"
            for esc_start, esc_match, esc_end in result:gmatch("()(\27%[[%d;]*%a)()") do
                if esc_start > last_pos then
                    local chunk = result:sub(last_pos, esc_start - 1)
                    for _, pat in ipairs(patterns) do
                        chunk = chunk:gsub("(" .. pat .. ")", "\27[1;30;43m%1\27[0m" .. cur_color)
                    end
                    table.insert(parts, chunk)
                end
                cur_color = esc_match
                table.insert(parts, esc_match)
                last_pos = esc_end
            end
            if last_pos <= #result then
                local chunk = result:sub(last_pos)
                for _, pat in ipairs(patterns) do
                    chunk = chunk:gsub("(" .. pat .. ")", "\27[1;30;43m%1\27[0m" .. cur_color)
                end
                table.insert(parts, chunk)
            end
            result = table.concat(parts)
        end
        return result
    end

    -- Filetype color icons
    -- #8: Single FILE_BADGES data table replaces three near-identical 25-line switch functions
    local FILE_BADGES = {
        -- Groups: keys = extensions that share a badge
        c   = { exts={"c","cpp","cc","cxx"},      label="[c]",   color="\27[1;34m" },
        h   = { exts={"h","hpp","hh"},            label="[h]",   color="\27[1;36m" },
        lua = { exts={"lua","luau"},              label="[lua]", color="\27[1;35m" },
        py  = { exts={"py","pyw"},                label="[py]",  color="\27[1;33m" },
        js  = { exts={"js","ts","jsx","tsx","mjs","cjs"}, label="[js]", color="\27[1;32m" },
        txt = { exts={"md","txt","rst","markdown"},label="[txt]",color="\27[37m"   },
        cfg = { exts={"json","yaml","yml","toml","ini","conf"}, label="[cfg]", color="\27[33m" },
        sh  = { exts={"sh","bash","zsh","fish"},  label="[sh]",  color="\27[1;32m" },
        rs  = { exts={"rs"},                      label="[rs]",  color="\27[1;31m" },
        go  = { exts={"go"},                      label="[go]",  color="\27[1;36m" },
        rb  = { exts={"rb"},                      label="[rb]",  color="\27[1;31m" },
        java= { exts={"java","kt","kts"},         label="[jv]",  color="\27[1;33m" },
    }
    -- Build fast ext→badge lookup table once
    local _ext_badge = {}
    for _, bd in pairs(FILE_BADGES) do
        for _, e in ipairs(bd.exts) do _ext_badge[e] = bd end
    end
    local function _badge_for(path)
        local ext = path:match("%.([%w_%-]+)$")
        if not ext then return nil, nil, nil end
        ext = ext:lower()
        local bd = _ext_badge[ext]
        if bd then return bd.label, bd.color, ext end
        return "[" .. ext:sub(1,3) .. "]", "\27[90m", ext
    end
    local function get_file_badge(path)
        local label, color = _badge_for(path)
        if not label then return "\27[90m·\27[0m " end
        return color .. label .. "\27[0m "
    end
    local function get_file_badge_plain(path)
        local label = _badge_for(path)
        if not label then return "· " end
        return label .. " "
    end
    local function get_file_badge_color(path)
        local _, color = _badge_for(path)
        return color or "\27[90m"
    end

    local function shorten_path(path, max_len)
        if visual_len(path) <= max_len then return path end
        local fname = get_filename(path)
        if visual_len(fname) >= max_len then
            return truncate(fname, max_len)
        end
        local segments = {}
        for seg in path:gmatch("[^/\\]+") do
            table.insert(segments, seg)
        end
        if #segments <= 1 then
            return truncate(path, max_len)
        end
        local candidate = fname
        for k = #segments - 1, 1, -1 do
            local sub = candidate:gsub("^%.%.%./", "")
            local test_p = ".../" .. segments[k] .. "/" .. sub
            if visual_len(test_p) <= max_len then
                candidate = test_p
            else
                break
            end
        end
        if candidate ~= fname then
            return candidate
        end
        if visual_len(".../" .. fname) <= max_len then
            return ".../" .. fname
        end
        return truncate(fname, max_len)
    end

    -- Format a single file item in the left list
    local function format_left_item(item_idx, is_sel, list_thumb_pos, i)
        local res_item = results[item_idx]
        local left_sb = " "
        if #results > list_height then
            left_sb = (i == list_thumb_pos) and "\27[1;36m█\27[0m" or "\27[90m│\27[0m"
        end

        local text_w = left_col_w - 1
        if res_item then
            local marker = is_sel and "▶ " or "  "
            local full_path = res_item.filepath
            local display_path = sanitize_terminal_text(full_path)
            local badge_plain = get_file_badge_plain(full_path)
            local badge_w = #badge_plain

            local num_w = math.max(2, #tostring(#results))
            local num_plain = string.format("%" .. num_w .. "d. ", item_idx)
            local num_w_total = #num_plain
            local num_col = is_sel and num_plain or ("\27[90m" .. num_plain .. "\27[0m")

            local line_cnt = get_file_line_count(full_path)
            local cnt_tag = ""
            if text_w >= 45 and line_cnt > 0 then
                if line_cnt >= 1000 then
                    cnt_tag = string.format(" %.1fkL", line_cnt / 1000)
                else
                    cnt_tag = string.format(" %dL", line_cnt)
                end
            end
            local cnt_w = #cnt_tag

            local max_p_len = math.max(4, text_w - 2 - num_w_total - badge_w - cnt_w)
            local clean_path = shorten_path(display_path, max_p_len)

            local avail_space = math.max(0, text_w - 2 - num_w_total - badge_w - visual_len(clean_path) - cnt_w)
            local pad_spaces = string.rep(" ", avail_space)

            if is_sel then
                local plain_line = marker .. num_plain .. badge_plain .. clean_path .. pad_spaces .. cnt_tag
                return "\27[1;30;43m" .. pad_to(plain_line, text_w) .. "\27[0m" .. left_sb
            else
                local badge_col = get_file_badge_color(full_path)
                local right_part = (cnt_w > 0) and ("\27[90m" .. cnt_tag .. "\27[0m") or ""
                local colored_line = marker .. num_col .. badge_col .. badge_plain .. "\27[0;37m" .. clean_path .. "\27[0m" .. pad_spaces .. right_part
                return pad_to(colored_line, text_w) .. left_sb
            end
        elseif #results == 0 then
            local empty_lines = get_empty_state_left_lines(query, text_w)
            local line_str = empty_lines[i] or ""
            return pad_to(line_str, text_w) .. left_sb
        else
            return string.rep(" ", text_w) .. left_sb
        end
    end

    -- Instant visual echo: update query prompt line in row 2 with zero flicker
    local function render_query_prompt_instant()
        local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
        local ext_tag = active_ext_filter and ("\27[1;35m[." .. active_ext_filter .. "]\27[0m ") or ""
        local matches_badge = ext_tag .. ((#results > 0) and string.format("[%d/%d]", selected_idx, #results) or "[0 Matches]")
        local badge_w = visual_len(matches_badge)
        local avail_prompt_w = (left_col_w > badge_w + 4) and (left_col_w - badge_w) or left_col_w
        local query_prompt = format_query_prompt(query, cursor_pos, avail_prompt_w, focus_pane == "search")
        local left_head = ""
        if left_col_w > badge_w + 4 then
            left_head = pad_to(query_prompt, avail_prompt_w) .. matches_badge
        else
            left_head = pad_to(query_prompt, left_col_w)
        end
        -- Write left half or full row 2 with synchronized updates up to the border
        if is_single_pane then
            io.write(string.format("\27[?2026h\27[2;1H%s│\27[0m%s%s│\27[0m\27[?2026l",
                left_col_border,
                pad_to(left_head, left_col_w),
                left_col_border))
        else
            io.write(string.format("\27[?2026h\27[2;1H%s│\27[0m%s\27[0m\27[90m│\27[0m\27[?2026l",
                left_col_border,
                pad_to(left_head, left_col_w)))
        end
        io.flush()
    end

    local function get_thumb_positions()
        local list_thumb_pos = 1
        if #results > list_height then
            local max_offset = math.max(1, #results - list_height)
            list_thumb_pos = 1 + math.floor((list_scroll_offset / max_offset) * (list_height - 1))
        end

        local prev_total = current_preview_total_lines
        local prev_thumb_pos = 1
        if prev_total > list_height then
            local max_prev_offset = math.max(1, prev_total - list_height)
            prev_thumb_pos = 1 + math.floor((preview_scroll_offset / max_prev_offset) * (list_height - 1))
        end

        local cur_file_ext = current_preview_file and current_preview_file:match("%.([%w_%-]+)$")
        cur_file_ext = cur_file_ext and cur_file_ext:lower() or ""

        return list_thumb_pos, prev_thumb_pos, prev_total, cur_file_ext
    end

    local function build_header_row()
        local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
        local right_col_border = (focus_pane == "preview") and "\27[1;32m" or "\27[90m"
        local neutral_border = "\27[90m"

        local ext_tag = active_ext_filter and ("\27[1;35m[." .. active_ext_filter .. "]\27[0m ") or ""
        local matches_badge = ext_tag .. ((#results > 0) and string.format("[%d/%d]", selected_idx, #results) or "[0 Matches]")
        local badge_w = visual_len(matches_badge)
        local avail_prompt_w = (left_col_w > badge_w + 4) and (left_col_w - badge_w) or left_col_w
        local query_prompt = format_query_prompt(query, cursor_pos, avail_prompt_w, focus_pane == "search")
        local left_head = ""
        if left_col_w > badge_w + 4 then
            left_head = pad_to(query_prompt, avail_prompt_w) .. matches_badge
        else
            left_head = pad_to(query_prompt, left_col_w)
        end

        local right_head_title = ""
        if current_preview_file then
            local first_ln = current_match_list[1] or 1
            local match_badge = ""
            if #current_match_list > 0 then
                match_badge = string.format(" \27[1;33m[Match %d/%d]\27[0m", current_match_pos, #current_match_list)
            end
            local line_badge = string.format(" \27[90m[Line %d/%d]\27[0m", preview_scroll_offset + 1, current_preview_total_lines)
            right_head_title = string.format(" 📄 %s:%d%s%s", sanitize_terminal_text(get_filename(current_preview_file)), first_ln, match_badge, line_badge)
        elseif #results == 0 and #query > 0 then
            right_head_title = " 📄 Syntax & Search Guidance"
        elseif #results == 0 and #query == 0 then
            right_head_title = " 📄 Quick Reference & Shortcuts"
        else
            right_head_title = " 📄 Preview: (No file selected)"
        end
        local pane_badge = (focus_pane == "preview") and "\27[1;32;40m [PREVIEW / BROWSE] \27[0m" or "\27[1;36;40m [SEARCH / TYPING] \27[0m"
        local fbadge_w = visual_len(pane_badge)
        local right_head = ""
        if right_col_w > fbadge_w + 4 then
            right_head = pad_to(right_head_title, right_col_w - fbadge_w) .. pane_badge
        else
            right_head = pad_to(right_head_title, right_col_w)
        end

        if is_single_pane then
            if focus_pane == "search" then
                return string.format("%s│\27[0m%s%s│\27[0m",
                    left_col_border,
                    pad_to(left_head, left_col_w),
                    left_col_border)
            else
                return string.format("%s│\27[0m%s%s│\27[0m",
                    right_col_border,
                    pad_to(right_head, right_col_w),
                    right_col_border)
            end
        end

        return string.format("%s│\27[0m%s%s│\27[0m%s%s│\27[0m",
            left_col_border,
            pad_to(left_head, left_col_w),
            neutral_border,
            pad_to(right_head, right_col_w),
            right_col_border)
    end

    local function build_right_cell(i, prev_thumb_pos, prev_total, cur_file_ext)
        local right_sb = " "
        if prev_total > list_height then
            right_sb = (i == prev_thumb_pos) and "\27[1;32m█\27[0m" or "\27[90m│\27[0m"
        end

        local right_cell = ""
        local r_text_w = right_col_w - 1
        if current_preview_file and current_preview_total_lines > 0 then
            local file_line_num = preview_scroll_offset + i
            if file_line_num <= current_preview_total_lines then
                local line_content = sanitize_terminal_text(preview_reader.get_line(current_preview_file, file_line_num) or "")
                local is_hit = current_match_lines[file_line_num]

                local gutter_str, gutter_w = format_preview_gutter(file_line_num, current_preview_total_lines, is_hit)
                local max_code_w = math.max(0, r_text_w - gutter_w)
                local code_str = truncate(line_content, max_code_w)
                local line_pad = string.rep(" ", math.max(0, max_code_w - visual_len(code_str)))

                local highlighted = highlight_code_line(code_str, cur_file_ext, current_preview_patterns, is_hit)
                right_cell = gutter_str .. highlighted .. line_pad .. right_sb
            else
                right_cell = string.rep(" ", r_text_w) .. right_sb
            end
        else
            local empty_lines = get_empty_state_right_lines(query, r_text_w)
            local line_str = empty_lines[i] or ""
            right_cell = pad_to(line_str, r_text_w) .. right_sb
        end
        return right_cell
    end

    local function build_content_row(i, list_thumb_pos, prev_thumb_pos, prev_total, cur_file_ext)
        local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
        local right_col_border = (focus_pane == "preview") and "\27[1;32m" or "\27[90m"
        local neutral_border = "\27[90m"

        if is_single_pane then
            if focus_pane == "search" then
                local item_idx = list_scroll_offset + i
                local left_cell = format_left_item(item_idx, (item_idx == selected_idx), list_thumb_pos, i)
                return string.format("%s│\27[0m%s%s│\27[0m", left_col_border, left_cell, left_col_border)
            else
                local right_cell = build_right_cell(i, prev_thumb_pos, prev_total, cur_file_ext)
                return string.format("%s│\27[0m%s%s│\27[0m", right_col_border, right_cell, right_col_border)
            end
        end

        local item_idx = list_scroll_offset + i
        local left_cell = format_left_item(item_idx, (item_idx == selected_idx), list_thumb_pos, i)
        local right_cell = build_right_cell(i, prev_thumb_pos, prev_total, cur_file_ext)

        return string.format("%s│\27[0m%s%s│\27[0m%s%s│\27[0m", left_col_border, left_cell, neutral_border, right_cell, right_col_border)
    end

    render_selection = function(_, new_idx)
        selected_idx = new_idx
        clamp_scroll()

        if #results > 0 and results[selected_idx] then
            load_preview_for(results[selected_idx].filepath, query)
        end

        -- Selection changes affect the preview, header, scrollbar, and list. Render them
        -- together as one frame instead of mixing partial updates with the main loop.
        render_full_screen()
    end

    local function render_help_view()
        local neutral_border = "\27[90m"
        local frame_buf = {}
        local function emit_row(y, row_str)
            table.insert(frame_buf, string.format("\27[%d;1H\27[2K%s", y, row_str))
        end

        local title = " CodeFind v" .. CODEFIND_VERSION .. " — Keyboard Shortcuts & Search Patterns "
        local top_bar = pad_to(" " .. title, cur_cols - 2)
        emit_row(1, neutral_border .. "┌" .. string.rep("─", cur_cols - 2) .. "┐\27[0m")
        emit_row(2, string.format("%s│\27[1;30;46m%s\27[0m%s│\27[0m", neutral_border, top_bar, neutral_border))
        emit_row(3, neutral_border .. "├" .. string.rep("─", cur_cols - 2) .. "┤\27[0m")

        local help_content = {
            "  \27[1;36mKeyboard Navigation & Shortcuts\27[0m",
            "    \27[1mTab\27[0m             Switch focus between Search Box and Preview / Browse pane",
            "    \27[1mF2 / z\27[0m          Toggle full-width pane zoom (Search list or Preview)",
            "    \27[1m← / →\27[0m           Move cursor inside search query (Ctrl-B / Ctrl-F)",
            "    \27[1mHome / End\27[0m      Jump to start / end of search query (Ctrl-A / Ctrl-E)",
            "    \27[1mDel\27[0m            Delete character under cursor (Ctrl-D)",
            "    \27[1m↑ / ↓\27[0m           Navigate file list (or scroll preview in preview pane)",
            "    \27[1mPgUp / PgDn\27[0m     Scroll 10 items / lines up or down",
            "    \27[1mj / k\27[0m           Vim-style scroll in Browse pane",
            "    \27[1mn / N\27[0m           Jump to next / previous search match in current file",
            "    \27[1mEnter\27[0m           Open selected file at current match line in $EDITOR",
            "    \27[1my\27[0m               Yank (copy) selected 'filepath:line' to clipboard",
            "    \27[1mCtrl-W\27[0m          Delete word backward in search box",
            "    \27[1mCtrl-U\27[0m          Clear entire search query",
            "    \27[1mCtrl-R\27[0m          Trigger immediate incremental re-index of repository",
            "    \27[1mEsc\27[0m             Clear search text / exit preview / return to search",
            "    \27[1mq / Ctrl-Q\27[0m      Quit CodeFind",
            "",
            "  \27[1;36mSearch Pattern Syntax\27[0m",
            "    \27[33mword1 word2\27[0m       Implicit AND — matches files containing BOTH terms",
            "    \27[33mword1 OR word2\27[0m    Boolean OR — matches files containing EITHER term",
            "    \27[33mword1 NOT word2\27[0m   Boolean NOT — matches 'word1' but excludes 'word2'",
            "    \27[33m\"exact phrase\"\27[0m    Exact phrase search (preserves contiguous token order)",
            "    \27[33mprefix*\27[0m           Prefix search — matches any word starting with prefix",
            "    \27[33mfiles:<pattern>\27[0m   Filename match (e.g. files:config, files:*.md, files:test_*)",
            "    \27[33m@<ext>\27[0m            Inline extension filter (e.g. 'handle @lua' or just '@md')",
            "",
            "  \27[90mPress ?, F1, Esc, q, or Enter to close this Help View and return to search\27[0m",
        }

        for i = 1, list_height do
            local line = help_content[i] or ""
            local padded = pad_to(line, cur_cols - 2)
            emit_row(3 + i, string.format("%s│\27[0m%s%s│\27[0m", neutral_border, padded, neutral_border))
        end

        local div_y = 3 + list_height + 1
        emit_row(div_y, neutral_border .. "├" .. string.rep("─", cur_cols - 2) .. "┤\27[0m")
        local status_y = div_y + 1
        local foot = pad_to("  [?, F1, Esc, q, or Enter] Close Help View", cur_cols - 2)
        emit_row(status_y, string.format("%s│\27[1;30;47m%s\27[0m%s│\27[0m", neutral_border, foot, neutral_border))
        local bot_y = status_y + 1
        emit_row(bot_y, neutral_border .. "└" .. string.rep("─", cur_cols - 2) .. "┘\27[0m")

        io.write("\27[?2026h" .. table.concat(frame_buf) .. "\27[?2026l")
        io.flush()
    end

    render_full_screen = function()
        if show_help then
            render_help_view()
            return
        end
        clamp_scroll()
        local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
        local right_col_border = (focus_pane == "preview") and "\27[1;32m" or "\27[90m"
        local neutral_border = "\27[90m"
        local active_border = (focus_pane == "preview") and right_col_border or left_col_border

        local frame_buf = {}
        local function emit_row(y, row_str)
            table.insert(frame_buf, string.format("\27[%d;1H\27[2K%s", y, row_str))
        end

        local list_thumb_pos, prev_thumb_pos, prev_total, cur_file_ext = get_thumb_positions()

        if is_single_pane then
            -- Single-pane mode (Narrow terminal or Zoomed)
            -- Row 1: Top Border
            emit_row(1, neutral_border .. "┌" .. active_border .. string.rep("─", cur_cols - 2) .. neutral_border .. "┐\27[0m")

            -- Row 2: Header Information Bar
            emit_row(2, build_header_row())

            -- Row 3: Split Divider
            emit_row(3, neutral_border .. "├" .. active_border .. string.rep("─", cur_cols - 2) .. neutral_border .. "┤\27[0m")

            -- Rows 4 .. (4 + list_height - 1): Content rows
            for i = 1, list_height do
                emit_row(3 + i, build_content_row(i, list_thumb_pos, prev_thumb_pos, prev_total, cur_file_ext))
            end

            -- Row Bottom Divider
            local div_y = 3 + list_height + 1
            emit_row(div_y, neutral_border .. "├" .. active_border .. string.rep("─", cur_cols - 2) .. neutral_border .. "┤\27[0m")

            -- Row Footer / Keybindings
            local status_y = div_y + 1
            local is_status_active = (status_bar_msg ~= nil) and (wall_now() - status_bar_time <= 3.0)
            local footer_content = build_footer_content(cur_cols, status_bar_msg, is_status_active, focus_pane, query, is_zoomed, is_single_pane)
            emit_row(status_y, string.format("%s│%s%s│\27[0m", neutral_border, footer_content, neutral_border))

            -- Final Bottom Border
            local bot_y = status_y + 1
            emit_row(bot_y, neutral_border .. "└" .. string.rep("─", cur_cols - 2) .. "┘\27[0m")
        else
            -- Two-pane mode (Default on wide terminals)
            -- Row 1: Top Border
            emit_row(1, neutral_border .. "┌" .. left_col_border .. string.rep("─", left_col_w) .. neutral_border .. "┬" .. right_col_border .. string.rep("─", right_col_w) .. neutral_border .. "┐\27[0m")

            -- Row 2: Header Information Bar
            emit_row(2, build_header_row())

            -- Row 3: Split Divider
            emit_row(3, neutral_border .. "├" .. left_col_border .. string.rep("─", left_col_w) .. neutral_border .. "┼" .. right_col_border .. string.rep("─", right_col_w) .. neutral_border .. "┤\27[0m")

            -- Rows 4 .. (4 + list_height - 1): Content rows
            for i = 1, list_height do
                emit_row(3 + i, build_content_row(i, list_thumb_pos, prev_thumb_pos, prev_total, cur_file_ext))
            end

            -- Row Bottom Divider
            local div_y = 3 + list_height + 1
            emit_row(div_y, neutral_border .. "├" .. left_col_border .. string.rep("─", left_col_w) .. neutral_border .. "┴" .. right_col_border .. string.rep("─", right_col_w) .. neutral_border .. "┤\27[0m")

            -- Row Footer / Keybindings
            local status_y = div_y + 1
            local is_status_active = (status_bar_msg ~= nil) and (wall_now() - status_bar_time <= 3.0)
            local footer_content = build_footer_content(cur_cols, status_bar_msg, is_status_active, focus_pane, query, is_zoomed, is_single_pane)
            emit_row(status_y, string.format("%s│%s%s│\27[0m", neutral_border, footer_content, neutral_border))

            -- Final Bottom Border
            local bot_y = status_y + 1
            emit_row(bot_y, neutral_border .. "└" .. string.rep("─", cur_cols - 2) .. "┘\27[0m")
        end

        -- Atomically write frame buffer with synchronized updates (Zero flicker)
        io.write("\27[?2026h" .. table.concat(frame_buf) .. "\27[?2026l")
        io.flush()
    end

    while running do
        update_layout()

        if needs_redraw then
            needs_redraw = false
            render_full_screen()
        end

        local poll_timeout = 40
        local key = read_key(poll_timeout)
        if key then
            if show_help then
                if key == "CTRL_C" or key == "CTRL_Q" then
                    running = false
                else
                    -- Any key (Esc, q, ?, F1, Enter, Tab, Space, etc.) dismisses Help View
                    show_help = false
                    needs_redraw = true
                end
            elseif key == "CTRL_C" or key == "CTRL_Q" then
                running = false
            elseif key == "F1" or key == "?" then
                show_help = true
                needs_redraw = true
            elseif key == "F2" then
                is_zoomed = not is_zoomed
                update_layout(true)
                set_status(is_zoomed and "🔍 Full-width pane zoom enabled (F2 / z to toggle)" or "🔍 Two-pane view restored")
                needs_redraw = true
            elseif key == "ESC" then
                if focus_pane == "preview" then
                    -- If in preview pane, ESC switches back to search box
                    focus_pane = "search"
                    vim_mode = "INSERT"
                    if is_single_pane then
                        update_layout(true)
                    end
                    needs_redraw = true
                elseif #query > 0 then
                    -- If search box has text, ESC clears it
                    query = ""
                    cursor_pos = 1
                    selected_idx = 1
                    vim_mode = "INSERT"
                    render_query_prompt_instant()
                    set_status("Query cleared")
                    needs_redraw = true
                else
                    -- Query is already empty: ESC quits
                    running = false
                end
            elseif key == "UP" or key == "CTRL_P" or (vim_mode == "INSERT" and key == "CTRL_K") then
                if focus_pane == "preview" then
                    if preview_scroll_offset > 0 then
                        preview_scroll_offset = preview_scroll_offset - 1
                        needs_redraw = true
                    end
                else
                    if selected_idx > 1 then
                        local old_idx = selected_idx
                        render_selection(old_idx, old_idx - 1)
                    end
                end
            elseif key == "DOWN" or key == "CTRL_N" then
                if focus_pane == "preview" then
                    if preview_scroll_offset + 1 < current_preview_total_lines then
                        preview_scroll_offset = preview_scroll_offset + 1
                        needs_redraw = true
                    end
                else
                    if selected_idx < #results then
                        local old_idx = selected_idx
                        render_selection(old_idx, old_idx + 1)
                    end
                end
            elseif key == "PAGE_UP" or (vim_mode == "NORMAL" and focus_pane == "preview" and key == "CTRL_U") then
                if focus_pane == "preview" then
                    preview_scroll_offset = math.max(0, preview_scroll_offset - 10)
                else
                    selected_idx = math.max(1, selected_idx - 10)
                    if #results > 0 and results[selected_idx] then
                        load_preview_for(results[selected_idx].filepath, query)
                    end
                end
                clamp_scroll()
                needs_redraw = true
            elseif key == "PAGE_DOWN" or (vim_mode == "NORMAL" and key == "CTRL_D") then
                if focus_pane == "preview" then
                    preview_scroll_offset = math.min(math.max(0, current_preview_total_lines - 1), preview_scroll_offset + 10)
                else
                    selected_idx = math.min(#results, selected_idx + 10)
                    if #results > 0 and results[selected_idx] then
                        load_preview_for(results[selected_idx].filepath, query)
                    end
                end
                clamp_scroll()
                needs_redraw = true
            elseif key == "TAB" then
                if focus_pane == "search" then
                    focus_pane = "preview"
                    vim_mode = "NORMAL"
                else
                    focus_pane = "search"
                    vim_mode = "INSERT"
                end
                if is_single_pane then
                    update_layout(true)
                end
                needs_redraw = true
            elseif key == "CTRL_U" then
                query = ""
                cursor_pos = 1
                selected_idx = 1
                vim_mode = "INSERT"
                focus_pane = "search"
                render_query_prompt_instant()
                set_status("Query cleared — type new search")
                needs_redraw = true
            elseif key == "CTRL_R" then
                set_status("⚡ Incremental re-indexing in progress...")
                local stat_res = Indexer.run(db, ".", false)
                set_status(string.format("✔ Re-indexed %d files (Total: %d)", stat_res.indexed, db:get_stats().total_files))
                refresh_search()
            elseif key == "LEFT" or (focus_pane == "search" and key == "CTRL_B") then
                if focus_pane == "search" then
                    if cursor_pos > 1 then
                        cursor_pos = cursor_pos - 1
                        render_query_prompt_instant()
                    end
                end
            elseif key == "RIGHT" or (focus_pane == "search" and key == "CTRL_F") then
                if focus_pane == "search" then
                    if cursor_pos <= #query then
                        cursor_pos = cursor_pos + 1
                        render_query_prompt_instant()
                    end
                end
            elseif key == "CTRL_A" or (focus_pane == "search" and key == "HOME") then
                if focus_pane == "search" then
                    cursor_pos = 1
                    render_query_prompt_instant()
                end
            elseif key == "CTRL_E" or (focus_pane == "search" and key == "END") then
                if focus_pane == "search" then
                    cursor_pos = #query + 1
                    render_query_prompt_instant()
                end
            elseif key == "BACKSPACE" then
                if focus_pane == "search" and cursor_pos > 1 then
                    query = query:sub(1, cursor_pos - 2) .. query:sub(cursor_pos)
                    cursor_pos = cursor_pos - 1
                    selected_idx = 1
                    render_query_prompt_instant()
                end
            elseif key == "DELETE" or (focus_pane == "search" and key == "CTRL_D") then
                if focus_pane == "search" and cursor_pos <= #query then
                    query = query:sub(1, cursor_pos - 1) .. query:sub(cursor_pos + 1)
                    selected_idx = 1
                    render_query_prompt_instant()
                end
            elseif key == "CTRL_W" then
                if focus_pane == "search" and cursor_pos > 1 then
                    local prefix = query:sub(1, cursor_pos - 1)
                    local suffix = query:sub(cursor_pos)
                    local trimmed = prefix:gsub("%s+$", "")
                    local new_prefix = trimmed:match("^(.-)[%w_%-]+$") or ""
                    query = new_prefix .. suffix
                    cursor_pos = #new_prefix + 1
                    selected_idx = 1
                    render_query_prompt_instant()
                end
            elseif key == "ENTER" then
                if vim_mode == "INSERT" and query ~= last_searched_query then
                    -- Execute search if query has been changed / typed
                    selected_idx = 1
                    refresh_search()
                    if #results > 0 then
                        set_status(string.format("Found %d matches for '%s'", #results, query))
                    else
                        set_status(string.format("No matches for '%s' — see search tips", query))
                    end
                else
                    -- Results are displayed and unchanged, or in NORMAL mode: open in editor
                    open_selected_in_editor()
                end
            elseif key == "o" and vim_mode == "NORMAL" then
                open_selected_in_editor()
            elseif vim_mode == "NORMAL" then
                if key == "i" or key == "/" then
                    vim_mode = "INSERT"
                    focus_pane = "search"
                    if is_single_pane then update_layout(true) end
                    set_status("INSERT mode")
                elseif key == "z" or key == "Z" then
                    is_zoomed = not is_zoomed
                    update_layout(true)
                    set_status(is_zoomed and "🔍 Full-width pane zoom enabled (F2 / z to toggle)" or "🔍 Two-pane view restored")
                    needs_redraw = true
                elseif key == "j" then
                    if focus_pane == "preview" then
                        if preview_scroll_offset + 1 < current_preview_total_lines then
                            preview_scroll_offset = preview_scroll_offset + 1
                            needs_redraw = true
                        end
                    else
                        if selected_idx < #results then
                            local old_idx = selected_idx
                            render_selection(old_idx, old_idx + 1)
                        end
                    end
                elseif key == "k" then
                    if focus_pane == "preview" then
                        if preview_scroll_offset > 0 then
                            preview_scroll_offset = preview_scroll_offset - 1
                            needs_redraw = true
                        end
                    else
                        if selected_idx > 1 then
                            local old_idx = selected_idx
                            render_selection(old_idx, old_idx - 1)
                        end
                    end
                elseif key == "h" then
                    focus_pane = "search"
                    if is_single_pane then update_layout(true) end
                    needs_redraw = true
                elseif key == "l" then
                    focus_pane = "preview"
                    if is_single_pane then update_layout(true) end
                    needs_redraw = true
                elseif key == "g" then
                    if focus_pane == "preview" then
                        preview_scroll_offset = 0
                    else
                        selected_idx = 1
                        if #results > 0 and results[selected_idx] then
                            load_preview_for(results[selected_idx].filepath, query)
                        end
                    end
                    clamp_scroll()
                    needs_redraw = true
                elseif key == "G" then
                    if focus_pane == "preview" then
                        preview_scroll_offset = math.max(0, current_preview_total_lines - list_height)
                    else
                        selected_idx = math.max(1, #results)
                        if #results > 0 and results[selected_idx] then
                            load_preview_for(results[selected_idx].filepath, query)
                        end
                    end
                    clamp_scroll()
                    needs_redraw = true
                elseif key == "n" then
                    -- Jump to next match in current file
                    if #current_match_list > 0 then
                        current_match_pos = (current_match_pos % #current_match_list) + 1
                        local target_ln = current_match_list[current_match_pos]
                        preview_scroll_offset = math.max(0, target_ln - 4)
                        needs_redraw = true
                    end
                elseif key == "N" then
                    -- Jump to previous match in current file
                    if #current_match_list > 0 then
                        current_match_pos = current_match_pos - 1
                        if current_match_pos < 1 then current_match_pos = #current_match_list end
                        local target_ln = current_match_list[current_match_pos]
                        preview_scroll_offset = math.max(0, target_ln - 4)
                        needs_redraw = true
                    end
                elseif key == "y" then
                    -- Yank (copy) filepath:line to clipboard
                    if #results > 0 and results[selected_idx] then
                        local chosen = results[selected_idx].filepath
                        local first_ln = current_match_list[1] or 1
                        local yank_text = string.format("%s:%d", chosen, first_ln)
                        if is_windows then
                            local p = io.popen("clip", "w")
                            if p then p:write(yank_text); p:close() end
                        else
                            local p = io.popen("xclip -selection clipboard 2>/dev/null || wl-copy 2>/dev/null || pbcopy 2>/dev/null", "w")
                            if p then p:write(yank_text); p:close() end
                        end
                        set_status(string.format("✔ Copied '%s' to clipboard", yank_text))
                        needs_redraw = true
                    end
                elseif key == "q" then
                    running = false
                elseif key == "c" then
                    query = ""
                    cursor_pos = 1
                    selected_idx = 1
                    vim_mode = "INSERT"
                    focus_pane = "search"
                    if is_single_pane then update_layout(true) end
                    render_query_prompt_instant()
                    set_status("Query cleared — type new search")
                    needs_redraw = true
                elseif key == "?" or key == "F1" then
                    show_help = true
                    needs_redraw = true
                end
            elseif #key == 1 and focus_pane == "search" then
                -- Search box is a text input: printable keys are literal, including 'q'.
                -- Quit via Esc (empty box), Ctrl-C, Ctrl-Q, or Tab then q in Browse.
                vim_mode = "INSERT"
                local chars = key
                -- Drain any additional pending single-character keys from the queue
                while #key_queue > 0 and #key_queue[1] == 1 do
                    chars = chars .. table.remove(key_queue, 1)
                end
                query = query:sub(1, cursor_pos - 1) .. chars .. query:sub(cursor_pos)
                cursor_pos = cursor_pos + #chars
                selected_idx = 1
                -- Instant 0ms visual echo to the prompt bar
                render_query_prompt_instant()
            end
        else
            -- Check if status bar message timed out
            if status_bar_msg and (wall_now() - status_bar_time > 3.0) then
                status_bar_msg = nil
                needs_redraw = true
            end
        end
    end

    disable_raw()
    return true
end

--------------------------------------------------------------------------------
-- 8. CLI Interface & Self-Tests
--------------------------------------------------------------------------------
local function print_help()
    print([[
CodeFind v]] .. CODEFIND_VERSION .. [[ — High-Performance Local Code & Document Search Engine
Powered by LuaJIT FFI & SQLite FTS5 (Zero dependencies)

Usage:
  codefind <command> [arguments]

Commands:
  index  [dir]           Index or update repository files (default: current directory)
  search <query>         Fast ranked full-text search with context snippets
  tui    [query]         Interactive search browser with live side-by-side preview
  stats                  Show index statistics (files, size, extensions, last-indexed time)
  clean                  Drop index database and vacuum
  doctor                 Print environment diagnostics (interpreter, sqlite3, script in use)
  pin [n|path]           Remember which sqlite3 library to use (--list, --clear)
  finder [name]          Configure default file crawler (fd, find, builtin, auto; --list, --clear)
  --test                 Run built-in unit & integration test suite

Options:
  -v, --version          Print version information and exit
  -h, --help             Show this help message and exit
  --tui                  Launch interactive full-screen TUI (supports live search, scroll, open)
  --json                 Output search results as JSON (for scripting/editor integration)
  --watch[=N]            After indexing, poll every N seconds (default 3) for changed files
  --finder <mode>        File crawler to use: fd, find, builtin, or auto (default: auto)
  --ext <extension>      Filter by file extension (e.g. --ext lua, --ext c)
  --all                  Index all text files (disables source code extension filter)
  --limit <n>            Maximum results (default: 20). Use 0, 'all', or --no-limit for unlimited
  --no-limit             Return all results (no cap)
  --db <path>            Custom database file path (default: .codefind.db)
  --quiet                Suppress the environment block printed before indexing

Search Pattern Syntax:
  • Full-Text (Content):
      sqlite3 prepare        Implicit AND — matches files containing BOTH terms
      sqlite3 OR prepare     Boolean OR — matches files containing EITHER term
      sqlite3 NOT prepare    Boolean NOT — matches 'sqlite3' but excludes 'prepare'
      "sqlite3_prepare_v2"   Exact phrase match (preserves contiguous order)
      sqlite*                Prefix wildcard — matches tokens starting with 'sqlite'
      Note: '.' and '_' are token characters; identifiers (e.g. mod.fn, foo_bar)
            are indexed as single cohesive tokens.

  • Filename / Path Search:
      files:config           Search file names containing 'config' (bypasses FTS5)
      files:*.md             Search all Markdown files by name
      files:test_*           Search files starting with 'test_'

  • Extension Filters:
      --ext <ext>            CLI option to restrict to extension (e.g. --ext lua)
      @<ext> or ext:<ext>    Inline filter in query or TUI (e.g. "prepare @c", "@lua")

Examples:
  luajit codefind.lua index . --watch
  luajit codefind.lua search "sqlite3_prepare"
  luajit codefind.lua search "sqlite3 OR prepare" --json
  luajit codefind.lua search "files:*.md"
  luajit codefind.lua search "open @lua"
  luajit codefind.lua tui "files:config"
]])
end

local function run_self_tests()
    print("================================================================================")
    print("  Running Unit & Integration Tests for codefind.lua")
    print("================================================================================")

    local test_db_path = "/tmp/_test_codefind_" .. os.time() .. ".db"
    os.remove(test_db_path)

    -- Test 1: Database creation & FTS5 initialization
    io.write("Test 1: Database & FTS5 Schema Initialization... ")
    local db = Database.open(test_db_path)
    assert(db ~= nil and db.db ~= nil, "Database handle should not be nil")
    print("\27[32m✔ PASSED\27[0m")

    -- Test 2: Indexing mock files
    io.write("Test 2: Direct file indexing & FTS5 storage... ")
    db:begin()
    db:index_file("test/alpha.lua", "alpha.lua", "lua", 120, 1000, "local function calculate_sum(a, b) return a + b end")
    db:index_file("test/beta.c", "beta.c", "c", 250, 1000, "int main() { printf(\"hello world\\n\"); return 0; }")
    db:index_file("docs/readme.md", "readme.md", "md", 500, 1000, "# CodeFind Engine\nFast search using SQLite FTS5 and trigrams.")
    db:commit()
    print("\27[32m✔ PASSED\27[0m")

    -- Test 3: Search queries & BM25 ranking
    io.write("Test 3: Search query with snippet and ranking... ")
    local res1 = db:search("calculate_sum")
    assert(#res1 == 1, "Expected 1 match for 'calculate_sum', got " .. #res1)
    assert(res1[1].filepath == "test/alpha.lua", "Matched file mismatch")
    assert(res1[1].snippet:find("%[%[HL%]%]calculate_sum%[%[/HL%]%]"), "Snippet highlight missing")
    print("\27[32m✔ PASSED\27[0m")

    -- Test 4: Extension filter
    io.write("Test 4: Search with extension filter... ")
    local res2 = db:search("FTS5", { extension = "md" })
    assert(#res2 == 1, "Expected 1 markdown match for 'FTS5'")
    assert(res2[1].filename == "readme.md")

    local res3 = db:search("FTS5", { extension = "lua" })
    assert(#res3 == 0, "Expected 0 lua matches for 'FTS5'")
    print("\27[32m✔ PASSED\27[0m")

    -- Test 5: Incremental file update
    io.write("Test 5: Incremental update & deletion... ")
    db:begin()
    db:index_file("test/alpha.lua", "alpha.lua", "lua", 150, 2000, "local function calculate_sum_v2(a, b, c) return a + b + c end")
    db:commit()
    local res4 = db:search("calculate_sum_v2")
    assert(#res4 == 1, "Expected updated content to match")
    local res5 = db:search("calculate_sum")
    assert(#res5 >= 1, "calculate_sum prefix match supported")

    db:remove_file("test/alpha.lua")
    local res6 = db:search("calculate_sum_v2")
    assert(#res6 == 0, "File should have been removed")
    print("\27[32m✔ PASSED\27[0m")

    -- Test 6: Database Statistics
    io.write("Test 6: Database stats query... ")
    local stats = db:get_stats()
    assert(stats.total_files == 2, "Expected 2 files remaining in stats")
    print("\27[32m✔ PASSED\27[0m")

    -- Test 7: Windowed preview reader with large file (> 2000 lines)
    io.write("Test 7: Windowed preview reader with files > 2000 lines... ")
    local reader = make_preview_reader(200, 4)
    local sample_path = "test_large_preview.tmp"
    local tf = io.open(sample_path, "w")
    for i = 1, 3500 do
        if i == 2500 then
            tf:write("local special_marker_at_2500 = true\n")
        else
            tf:write(string.format("line %d = %d\n", i, i * 2))
        end
    end
    tf:close()

    local tot = reader.get_total_lines(sample_path)
    assert(tot == 3500, "Expected total lines to be 3500, got " .. tostring(tot))
    local l1 = reader.get_line(sample_path, 1)
    assert(l1 == "line 1 = 2", "Expected line 1 content")
    local l2500 = reader.get_line(sample_path, 2500)
    assert(l2500 == "local special_marker_at_2500 = true", "Expected line 2500 content")
    local l3500 = reader.get_line(sample_path, 3500)
    assert(l3500 == "line 3500 = 7000", "Expected line 3500 content")
    local out_bound = reader.get_line(sample_path, 3501)
    assert(out_bound == "", "Expected empty string for out-of-bounds line")

    local m_lines, m_list, m_tot = reader.find_matches(sample_path, { "special_marker_at_2500" })
    assert(#m_list == 1 and m_list[1] == 2500, "Expected match at line 2500 beyond old 2000 limit")
    assert(m_lines[2500] == true, "Expected match_lines[2500] to be true")
    assert(m_tot == 3500, "Expected total lines to match 3500")

    os.remove(sample_path)
    print("\27[32m✔ PASSED\27[0m")

    -- Test 8: Unlimited search and limit support
    io.write("Test 8: Unlimited search vs capped limit... ")
    db:begin()
    db:index_file("test/lim1.lua", "lim1.lua", "lua", 100, 1000, "local common_word_here = 1")
    db:index_file("test/lim2.lua", "lim2.lua", "lua", 100, 1000, "local common_word_here = 2")
    db:index_file("test/lim3.lua", "lim3.lua", "lua", 100, 1000, "local common_word_here = 3")
    db:commit()
    local lim_all = db:search("common_word_here")
    assert(#lim_all == 3, "Expected 3 matches with unlimited search, got " .. #lim_all)
    local lim_one = db:search("common_word_here", { limit = 1 })
    assert(#lim_one == 1, "Expected 1 match with limit = 1, got " .. #lim_one)
    local lim_zero = db:search("common_word_here", { limit = 0 })
    assert(#lim_zero == 3, "Expected 3 matches with limit = 0 (unlimited), got " .. #lim_zero)
    print("\27[32m✔ PASSED\27[0m")

    db:close()
    os.remove(test_db_path)
    os.remove(test_db_path .. "-wal")
    os.remove(test_db_path .. "-shm")

    print("================================================================================")
    print("\27[1;32mALL CODEFIND TESTS PASSED SUCCESSFULLY! (8/8)\27[0m")
    print("================================================================================")
end

local function main(args)
    if #args == 0 or args[1] == "--help" or args[1] == "-h" then
        print_help()
        return
    end

    if args[1] == "--version" or args[1] == "-v" then
        print("codefind " .. CODEFIND_VERSION)
        return
    end

    if args[1] == "--test" then
        run_self_tests()
        return
    end

    -- Parse global flags
    local db_path = ".codefind.db"
    local command = nil
    local cmd_args = {}
    local use_tui = false
    local use_json = false    -- #1: --json output mode
    local watch_interval = nil -- #3: --watch mode interval in seconds
    local ext_filter = nil
    local limit = 20
    local limit_specified = false
    local allow_all = false
    local quiet = false
    local finder_mode = nil

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--version" or a == "-v" then
            print("codefind " .. CODEFIND_VERSION)
            return
        elseif a == "--help" or a == "-h" then
            print_help()
            return
        elseif a == "--tui" then
            use_tui = true
        elseif a == "--json" then
            use_json = true   -- #1: JSON output mode
        elseif a == "--watch" then
            watch_interval = 3   -- #3: default 3s poll interval
        elseif a:match("^%-%-watch=(%d+)$") then
            watch_interval = tonumber(a:match("^%-%-watch=(%d+)$")) or 3
        elseif a == "--all" then
            allow_all = true
        elseif a == "--quiet" or a == "-q" then
            quiet = true
        elseif a == "--finder" and i + 1 <= #args then
            finder_mode = args[i + 1]:lower()
            i = i + 1
        elseif a:match("^%-%-finder=(.+)$") then
            finder_mode = a:match("^%-%-finder=(.+)$"):lower()
        elseif a == "--db" and i + 1 <= #args then
            db_path = args[i + 1]
            i = i + 1
        elseif a == "--ext" and i + 1 <= #args then
            ext_filter = args[i + 1]:lower():gsub("^%.", "")
            i = i + 1
        elseif a == "--limit" and i + 1 <= #args then
            -- #13: Accept --limit 0, --limit all, --limit unlimited, --no-limit as "no limit"
            local raw_lim = args[i + 1]:lower()
            if raw_lim == "all" or raw_lim == "unlimited" or raw_lim == "none" then
                limit = 0  -- 0 means unlimited
            else
                limit = tonumber(raw_lim) or 0
            end
            limit_specified = true
            i = i + 1
        elseif a == "--no-limit" or a == "--unlimited" then
            limit = 0
            limit_specified = true
        elseif not command then
            command = a
        else
            table.insert(cmd_args, a)
        end
        i = i + 1
    end

    if not command and use_tui then
        command = "tui"
    elseif command == "--tui" then
        command = "tui"
    end

    if not command then
        print_help()
        return
    end

    if command == "clean" then
        os.remove(db_path)
        os.remove(db_path .. "-wal")
        os.remove(db_path .. "-shm")
        print("\27[32m✔ Dropped index database: " .. db_path .. "\27[0m")
        return
    end

    local db = Database.open(db_path)

    if command == "pin" then
        local cands = annotate_candidates(scan_sqlite_candidates())
        local arg1 = cmd_args[1]

        if arg1 == "--clear" then
            local ok, err = clear_pin()
            io.write(ok and "  \27[32m✔\27[0m Pin cleared.\n"
                           or string.format("  nothing to clear: %s\n", tostring(err)), "\n")
            io.flush(); db:close(); return
        end
        if arg1 == "--list" then
            SQLITE_SCAN.candidates = cands
            print_sqlite_candidates(true)
            io.write(string.format("\n  config: %s\n", config_path()), "\n")
            io.flush(); db:close(); return
        end

        local target
        if arg1 and tonumber(arg1) then
            target = cands[tonumber(arg1)]
            if not target then
                io.write(string.format("\n  No candidate [%s].\n", tostring(arg1)), "\n")
                io.flush(); db:close(); return
            end
        elseif arg1 then
            target = { path = arg1 }
        else
            if #cands == 0 then
                io.write("\n  No sqlite3 library found to pin.\n\n", "\n")
                io.flush(); db:close(); return
            end
            SQLITE_SCAN.candidates = cands
            io.write(string.format("\n  \27[1mPin a sqlite3 library\27[0m  (%d found)\n", #cands))
            for i, c in ipairs(cands) do io.write(describe_candidate(c, i) .. "\n") end
            io.write(string.format("\n  Pin which one? [1-%d]: ", #cands))
            io.flush()
            local line = io.read("*l")
            local n = line and tonumber((tostring(line):gsub("%s+", ""))) or nil
            if not n or n < 1 or n > #cands then
                io.write("  \27[33m!\27[0m Nothing pinned.\n\n", "\n")
                io.flush(); db:close(); return
            end
            target = cands[n]
        end

        local r = validate_sqlite_lib(target.path)
        if not r.ok then
            io.write(string.format("\n  \27[31mCannot pin\27[0m %s\n", target.path), "\n")
            io.write(string.format("      %s\n\n", tostring(r.reason)), "\n")
            io.flush(); db:close(); return
        end
        local ok, err = write_pin(target.path)
        if not ok then
            io.write(string.format("\n  \27[31mFailed\27[0m %s\n\n", tostring(err)), "\n")
            io.flush(); db:close(); return
        end
        io.write(string.format("\n  \27[32m✔\27[0m Pinned to %s  (v%s)\n", target.path, r.version), "\n")
        io.write(string.format("  \27[32m✔\27[0m Saved to %s\n\n", config_path()), "\n")
        io.flush(); db:close(); return
    end

    if command == "finder" then
        local cands = detect_available_finders()
        local cur = resolve_finder()
        local arg1 = cmd_args[1]

        if arg1 == "--clear" then
            local ok, err = clear_config_key("finder")
            io.write(ok and "  \27[32m✔\27[0m Finder setting cleared (reverted to auto).\n"
                           or string.format("  nothing to clear: %s\n", tostring(err)), "\n")
            io.flush(); db:close(); return
        end
        if arg1 == "--list" then
            io.write("\n  \27[1mAvailable File Crawlers\27[0m:\n")
            for _, k in ipairs({ "fd", "find", "builtin" }) do
                local f = cands[k]
                local mark = (k == cur) and " \27[32m[Active]\27[0m" or ""
                if f and f.available then
                    io.write(string.format("    - \27[1m%-8s\27[0m: %s%s\n", k, f.label, mark))
                else
                    io.write(string.format("    - \27[90m%-8s: not available%s\27[0m\n", k, mark))
                end
            end
            io.write(string.format("\n  Config path: %s\n\n", config_path()))
            io.flush(); db:close(); return
        end

        local target
        if arg1 then
            target = arg1:lower()
            if target ~= "fd" and target ~= "find" and target ~= "builtin" and target ~= "auto" then
                io.write(string.format("\n  Unknown finder [%s]. Choose: fd, find, builtin, or auto.\n\n", tostring(arg1)))
                io.flush(); db:close(); return
            end
            if target ~= "auto" and (not cands[target] or not cands[target].available) then
                io.write(string.format("\n  \27[33mWarning\27[0m: Finder '%s' is not currently available on this system.\n", target))
            end
        else
            local list = { "fd", "find", "builtin", "auto" }
            io.write(string.format("\n  \27[1mConfigure Default File Crawler\27[0m\n"))
            io.write("  --------------------------------------------------\n")
            for idx, k in ipairs(list) do
                local f = cands[k]
                local desc = (k == "auto") and "Auto-detect (uses fd if present, otherwise builtin) [Recommended]" or (f and f.label or "Not available")
                local mark = (k == cur) and " \27[32m[Active]\27[0m" or ""
                io.write(string.format("  [%d] %-8s %s%s\n", idx, k, desc, mark))
            end
            io.write("\n  Select default finder [1-4] (or Enter for [1]): ")
            io.flush()
            local line = io.read("*l")
            local n = line and tonumber((tostring(line):gsub("%s+", ""))) or 1
            if not n or n < 1 or n > #list then
                io.write("  \27[33m!\27[0m Nothing changed.\n\n")
                io.flush(); db:close(); return
            end
            target = list[n]
        end

        local ok, err = write_config_key("finder", target)
        if not ok then
            io.write(string.format("\n  \27[31mFailed\27[0m: %s\n\n", tostring(err)))
            io.flush(); db:close(); return
        end
        io.write(string.format("\n  \27[32m✔\27[0m Default file crawler set to: %s\n", target))
        io.write(string.format("  \27[32m✔\27[0m Saved to %s\n\n", config_path()))
        io.flush(); db:close(); return
    end

    if command == "doctor" then
        io.write("\n  \27[1mCodeFind diagnostics\27[0m\n")
        io.write(table.concat(diagnostics_lines(db_path, cmd_args[1] or ".", allow_all), "\n"), "\n")

        print_sqlite_candidates(true)

        local finders = detect_available_finders()
        local cur_f = resolve_finder()
        io.write("\n  \27[1m-- file crawlers \27[0m" .. string.rep("-", 40) .. "\n")
        for _, k in ipairs({ "fd", "find", "builtin" }) do
            local f = finders[k]
            local mark = (k == cur_f) and " \27[32m[Active]\27[0m" or ""
            if f and f.available then
                io.write(string.format("    - \27[1m%-8s\27[0m: %s%s\n", k, f.label, mark))
            else
                io.write(string.format("    - \27[90m%-8s: not available%s\27[0m\n", k, mark))
            end
        end

        io.write("\n  If 'script' points somewhere other than your checkout, you are\n")
        io.write("  running a stale deployed copy -- re-run: luajit deploy.lua --app codefind\n\n")
        io.flush()
        db:close()
        return
    end

    if command == "index" then
        local target_dir = cmd_args[1] or "."
        local active_f = resolve_finder(finder_mode)
        if not quiet then print_diagnostics(db_path, target_dir, allow_all, finder_mode) end
        print(string.format("⚡ Indexing directory '%s' into %s (Source mode: %s, Crawler: %s)...",
                            target_dir, db_path,
                            allow_all and "ALL" or "SOURCE ONLY",
                            active_f))
        Indexer.run(db, target_dir, true, allow_all, finder_mode)
        -- #3: --watch mode: poll at interval and re-index only changed files
        if watch_interval then
            print(string.format("\27[90m👁  Watch mode active (poll every %ds). Ctrl-C to stop.\27[0m", watch_interval))
            while true do
                -- Sleep using io.popen sleep (portable)
                if is_windows then
                    os.execute("timeout /t " .. tostring(watch_interval) .. " >nul 2>&1")
                else
                    os.execute("sleep " .. tostring(watch_interval))
                end
                local t0 = wall_now()
                local stat_res = Indexer.run(db, target_dir, false, allow_all, finder_mode)
                local dt = wall_now() - t0
                if stat_res.indexed > 0 or stat_res.pruned > 0 then
                    io.write(string.format("\r\27[2K\27[32m✔ [%s] Reindexed %d, pruned %d (%.1fs)\27[0m\n",
                        os.date("%H:%M:%S"), stat_res.indexed, stat_res.pruned, dt))
                    io.flush()
                end
            end
        end
    elseif command == "search" then
        local query = table.concat(cmd_args, " ")
        local tui_limit = limit_specified and ((limit and limit > 0) and limit or nil) or nil
        if use_tui then
            TUI.run(db, query, tui_limit)
        else
            if #query == 0 then
                print("Error: search query cannot be empty. Example: codefind search 'function'")
                db:close()
                os.exit(1)
            end

            local t0 = os.clock()
            local search_limit = (limit and limit > 0) and limit or nil
            local results, err = db:search(query, { extension = ext_filter, limit = search_limit })
            local elapsed = (os.clock() - t0) * 1000

            if err then
                print(string.format("\27[31mError: %s\27[0m", err))
                db:close()
                os.exit(1)
            end

            -- #1: --json output mode
            if use_json then
                io.write("[\n")
                for idx, res in ipairs(results) do
                    local comma = (idx < #results) and "," or ""
                    -- minimal JSON serializer (no deps)
                    local function jstr(s)
                        return '"' .. tostring(s or ""):gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t') .. '"'
                    end
                    io.write(string.format('  {"filepath":%s,"filename":%s,"rank":%.4f,"snippet":%s}%s\n',
                        jstr(res.filepath), jstr(res.filename), res.rank, jstr(res.snippet), comma))
                end
                io.write("]\n")
            else
                if #results == 0 then
                    -- #5: Hint FTS5 operators when nothing found
                    print(string.format("\27[90mNo matches found for '%s' (%.1fms)\27[0m", query, elapsed))
                    print("\27[90mTip: FTS5 supports AND/OR/NOT operators and \"exact phrase\" queries.\27[0m")
                else
                    print(string.format("\27[1;36m🔍 Results for '%s' (%d matching files in %.2fms):\27[0m\n", query, #results, elapsed))

                    -- Extract query search terms for token highlighting
                    local terms = {}
                    for t in query:gmatch("[%w_%-]+") do
                        table.insert(terms, t)
                    end

                    for idx, res in ipairs(results) do
                        local ctx = extract_file_matches(res.filepath, terms, 3)
                        if ctx then
                            local loc_str = string.format("%s:%d", res.filepath, ctx.first_line)
                            print(string.format("  \27[1;34m📄 %s\27[0m  \27[90m(score: %.2f)\27[0m", loc_str, res.rank))
                            print(ctx.formatted .. "\n")
                        else
                            -- Fallback to FTS5 snippet if file couldn't be read directly
                            local colored = colorize_snippet(res.snippet)
                            print(string.format("  \27[1;34m📄 %s\27[0m  \27[90m(score: %.2f)\27[0m", res.filepath, res.rank))
                            print(colored .. "\n")
                        end
                    end
                end
            end
        end
    elseif command == "tui" then
        local query = table.concat(cmd_args, " ")
        local tui_limit = limit_specified and ((limit and limit > 0) and limit or nil) or nil
        TUI.run(db, query, tui_limit)
    elseif command == "stats" then
        local stats = db:get_stats()
        -- #4: Show DB file size/age and last-index timestamp
        local db_size = file_size(db_path)
        local db_age_str = ""
        if db_size then
            local mtime_buf = ffi.new("struct stat")
            if not is_windows and posix_stat and posix_stat(db_path, mtime_buf) == 0 then
                local age_sec = os.difftime(os.time(), tonumber(mtime_buf.st_mtime))
                if age_sec < 60 then
                    db_age_str = string.format(", modified %ds ago", math.floor(age_sec))
                elseif age_sec < 3600 then
                    db_age_str = string.format(", modified %dm ago", math.floor(age_sec / 60))
                else
                    db_age_str = string.format(", modified %dh ago", math.floor(age_sec / 3600))
                end
            end
        end
        print("\n=== CodeFind Database Statistics ===")
        print(string.format("Database Path : %s%s", db_path,
            db_size and ("  (" .. human_size(db_size) .. db_age_str .. ")") or ""))
        print(string.format("Last Indexed  : %s", stats.last_index or "(not recorded — run 'index' first)"))
        print(string.format("Indexed Files : %d", stats.total_files))
        print(string.format("Total Size    : %s", format_bytes(stats.total_size)))
        print("\nTop File Extensions:")
        for _, e in ipairs(stats.extensions) do
            print(string.format("  .%-10s : %d files", e.ext, e.count))
        end
        print("=====================================\n")
    else
        print("Unknown command: " .. command)
        print_help()
    end


    db:close()
end

if pcall(debug.getlocal, 4, 1) then
    return {
        _VERSION = CODEFIND_VERSION,
        version  = CODEFIND_VERSION,
        Database = Database,
        Indexer  = Indexer,
        TUI      = TUI,
        make_preview_reader = make_preview_reader,
        sanitize_terminal_text = sanitize_terminal_text,
        build_footer_content = build_footer_content,
        compute_layout_geometry = compute_layout_geometry,
        format_preview_gutter = format_preview_gutter,
        format_query_prompt = format_query_prompt,
        get_empty_state_left_lines = get_empty_state_left_lines,
        get_empty_state_right_lines = get_empty_state_right_lines,
        visual_len = visual_len,
        truncate = truncate,
        -- exposed for tests: console-independent selection logic
        choose_candidate = choose_candidate,
        classify_source = classify_source,
        best_candidate = best_candidate,
        read_config = read_config,
        same_path = same_path,
        build_preview_patterns = build_preview_patterns,
        config_path = config_path,
        validate_sqlite_lib = validate_sqlite_lib,
        version_key = version_key,
        describe_candidate = describe_candidate,
        detect_available_finders = detect_available_finders,
        resolve_finder = resolve_finder,
        has_ignored_dir = has_ignored_dir,
        scan_directory = scan_directory,
        scan_directory_builtin = scan_directory_builtin,
        scan_directory_fd = scan_directory_fd,
        scan_directory_find = scan_directory_find,
        normalize_path = normalize_path,
        get_filename = get_filename,
        IGNORED_DIRS = IGNORED_DIRS,
    }
else
    main(arg)
end
