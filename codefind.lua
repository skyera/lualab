#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- codefind.lua
-- High-Performance Local Code & Document Search Engine
-- Built with pure LuaJIT FFI and SQLite FTS5 (Zero external dependencies)
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

local is_windows = (ffi.os == "Windows")

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
    ]]
else
    ffi.cdef[[
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
        char *realpath(const char *path, char *resolved_path);
    ]]
end

--------------------------------------------------------------------------------
-- 2. Library Loaders & OS Primitives
--------------------------------------------------------------------------------
local function load_sqlite_lib()
    local candidates = { "sqlite3", "libsqlite3.so.0", "libsqlite3.so", "sqlite3.dll", "libsqlite3.dylib" }
    for _, name in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then return lib end
    end
    error("Could not load SQLite3 shared library. Ensure libsqlite3 is installed.")
end

local sqlite = load_sqlite_lib()

local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

-- Terminal & File Stat helpers
local posix_stat = nil
if not is_windows then
    if pcall(function() return ffi.C.stat end) then
        posix_stat = function(p, st) return ffi.C.stat(p, st) end
    elseif pcall(function() return ffi.C.__xstat end) then
        posix_stat = function(p, st)
            local res = ffi.C.__xstat(3, p, st)
            if res ~= 0 then res = ffi.C.__xstat(1, p, st) end
            return res
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
        return { size = sz or 0, mtime = 0, is_dir = false }
    else
        local st = ffi.new("struct stat")
        if posix_stat(path, st) == 0 then
            local is_dir = bit.band(st.st_mode, 0xF000) == 0x4000
            local is_reg = bit.band(st.st_mode, 0xF000) == 0x8000
            return {
                size = tonumber(st.st_size),
                mtime = tonumber(st.st_mtime),
                is_dir = is_dir,
                is_reg = is_reg
            }
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
        local err = err_p[0] ~= nil and ffi.string(err_p[0]) or ffi.string(sqlite.sqlite3_errmsg(self.db))
        if err_p[0] ~= nil then sqlite.sqlite3_free(err_p[0]) end
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
    local stmt = self._stmt_get_file_info
    if not stmt then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "SELECT id, size, mtime FROM files WHERE filepath = ? LIMIT 1;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then
            return nil
        end
        stmt = stmt_p[0]
        self._stmt_get_file_info = stmt
    else
        sqlite.sqlite3_reset(stmt)
    end

    sqlite.sqlite3_bind_text(stmt, 1, filepath, #filepath, SQLITE_TRANSIENT)
    local res = nil
    if sqlite.sqlite3_step(stmt) == SQLITE_ROW then
        res = {
            id = tonumber(sqlite.sqlite3_column_int64(stmt, 0)),
            size = tonumber(sqlite.sqlite3_column_int64(stmt, 1)),
            mtime = tonumber(sqlite.sqlite3_column_int64(stmt, 2)),
        }
    end
    return res
end

function Database:index_file(filepath, filename, ext, size, mtime, content)
    -- 1. Remove previous FTS and file entry if updating
    local stmt_del_fts = self._stmt_del_fts
    if not stmt_del_fts then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "DELETE FROM code_idx WHERE filepath = ?;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_del_fts = stmt_p[0]
            self._stmt_del_fts = stmt_del_fts
        end
    else
        sqlite.sqlite3_reset(stmt_del_fts)
    end
    if stmt_del_fts then
        sqlite.sqlite3_bind_text(stmt_del_fts, 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_del_fts)
    end

    local stmt_del_files = self._stmt_del_files
    if not stmt_del_files then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "DELETE FROM files WHERE filepath = ?;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_del_files = stmt_p[0]
            self._stmt_del_files = stmt_del_files
        end
    else
        sqlite.sqlite3_reset(stmt_del_files)
    end
    if stmt_del_files then
        sqlite.sqlite3_bind_text(stmt_del_files, 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_del_files)
    end

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

function Database:remove_file(filepath)
    local stmt_del_fts = self._stmt_del_fts
    if not stmt_del_fts then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "DELETE FROM code_idx WHERE filepath = ?;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_del_fts = stmt_p[0]
            self._stmt_del_fts = stmt_del_fts
        end
    else
        sqlite.sqlite3_reset(stmt_del_fts)
    end
    if stmt_del_fts then
        sqlite.sqlite3_bind_text(stmt_del_fts, 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_del_fts)
    end

    local stmt_del_files = self._stmt_del_files
    if not stmt_del_files then
        local stmt_p = ffi.new("sqlite3_stmt*[1]")
        local sql = "DELETE FROM files WHERE filepath = ?;"
        if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
            stmt_del_files = stmt_p[0]
            self._stmt_del_files = stmt_del_files
        end
    else
        sqlite.sqlite3_reset(stmt_del_files)
    end
    if stmt_del_files then
        sqlite.sqlite3_bind_text(stmt_del_files, 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_del_files)
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
    local limit = options.limit or 50
    local ext_filter = options.extension

    -- Sanitize/escape query string for FTS5
    -- If user did not wrap in quotes and has no special syntax, wrap tokens or support prefix
    local fts_query = query_str
    if not query_str:find('"') and not query_str:find("%*") then
        local words = {}
        for w in query_str:gmatch("%S+") do
            -- escape double quotes
            local escaped = w:gsub('"', '""')
            table.insert(words, string.format('"%s"*', escaped))
        end
        fts_query = table.concat(words, " ")
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
            ORDER BY rank ASC
            LIMIT %d;
        ]=], ext_filter:gsub("'", "''"), limit)
    else
        sql = string.format([=[
            SELECT 
                filepath,
                filename,
                snippet(code_idx, 2, '[[HL]]', '[[/HL]]', '...', 16) AS snip,
                bm25(code_idx) AS rank
            FROM code_idx
            WHERE code_idx MATCH ?
            ORDER BY rank ASC
            LIMIT %d;
        ]=], limit)
    end

    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil)
    if rc ~= SQLITE_OK then
        -- Try direct match without prefix wildcard if syntax error
        local fallback_sql = string.format([=[
            SELECT filepath, filename, snippet(code_idx, 2, '[[HL]]', '[[/HL]]', '...', 16), bm25(code_idx)
            FROM code_idx WHERE code_idx MATCH ? ORDER BY bm25(code_idx) ASC LIMIT %d;
        ]=], limit)
        if sqlite.sqlite3_prepare_v2(self.db, fallback_sql, #fallback_sql, stmt_p, nil) ~= SQLITE_OK then
            return {}, "Invalid search query syntax: " .. query_str
        end
        fts_query = string.format('"%s"', query_str:gsub('"', '""'))
    end

    local stmt = stmt_p[0]
    sqlite.sqlite3_bind_text(stmt, 1, fts_query, #fts_query, SQLITE_TRANSIENT)

    local results = {}
    while sqlite.sqlite3_step(stmt) == SQLITE_ROW do
        local fpath = ffi.string(sqlite.sqlite3_column_text(stmt, 0))
        local fname = ffi.string(sqlite.sqlite3_column_text(stmt, 1))
        local snip  = ffi.string(sqlite.sqlite3_column_text(stmt, 2))
        local rank  = sqlite.sqlite3_column_double(stmt, 3)

        table.insert(results, {
            filepath = fpath,
            filename = fname,
            snippet  = snip,
            rank     = rank
        })
    end
    sqlite.sqlite3_finalize(stmt)
    return results
end

function Database:get_stats()
    local stats = { total_files = 0, total_size = 0, extensions = {} }
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    local sql = "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files;"
    if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) == SQLITE_OK then
        if sqlite.sqlite3_step(stmt_p[0]) == SQLITE_ROW then
            stats.total_files = tonumber(sqlite.sqlite3_column_int64(stmt_p[0], 0))
            stats.total_size  = tonumber(sqlite.sqlite3_column_int64(stmt_p[0], 1))
        end
        sqlite.sqlite3_finalize(stmt_p[0])
    end

    local sql_ext = "SELECT extension, COUNT(*) FROM files GROUP BY extension ORDER BY COUNT(*) DESC LIMIT 10;"
    if sqlite.sqlite3_prepare_v2(self.db, sql_ext, #sql_ext, stmt_p, nil) == SQLITE_OK then
        while sqlite.sqlite3_step(stmt_p[0]) == SQLITE_ROW do
            local ext = ffi.string(sqlite.sqlite3_column_text(stmt_p[0], 0))
            local cnt = tonumber(sqlite.sqlite3_column_int(stmt_p[0], 1))
            table.insert(stats.extensions, { ext = (ext == "" and "[none]" or ext), count = cnt })
        end
        sqlite.sqlite3_finalize(stmt_p[0])
    end

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

local function get_filename(path)
    return path:match("([^/\\]+)$") or path
end

local function scan_directory(root_dir, callback)
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
                    local full_path = current_dir .. "/" .. name
                    if is_dir then
                        if not IGNORED_DIRS[name] then walk(full_path) end
                    else
                        callback(full_path, name)
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
                    local full_path = current_dir .. "/" .. name
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
                        callback(full_path, name)
                    end
                end
            end
            ffi.C.closedir(dir_p)
        end
    end

    walk(root_dir)
end

--------------------------------------------------------------------------------
-- 5. Indexing Pipeline
--------------------------------------------------------------------------------
local Indexer = {}

function Indexer.run(db, root_dir, verbose, allow_all)
    root_dir = root_dir or "."
    -- strip trailing slash
    root_dir = root_dir:gsub("[/\\]+$", "")
    if #root_dir == 0 then root_dir = "." end

    local t_start = os.clock()

    -- Phase 1: Fast discovery and candidate filtering
    if verbose then
        io.write("\27[90m⚡ Discovering files...\27[0m")
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

        visited_paths[full_path] = true
        table.insert(candidate_files, { path = full_path, name = fname, ext = ext })
    end)

    local total_files = #candidate_files
    if verbose then
        io.write(string.format("\r\27[2K🔍 Found %d candidate source files to index\n", total_files))
        io.flush()
    end

    -- Phase 2: Indexing pipeline with progress and ETA
    local files_indexed = 0
    local files_skipped = 0
    local total_bytes = 0
    local batch_count = 0
    local last_progress_time = 0

    local function render_progress(current_idx, force)
        if not verbose or total_files == 0 then return end
        local now = os.clock()
        if not force and (now - last_progress_time < 0.08) and (current_idx < total_files) then
            return
        end
        last_progress_time = now

        local elapsed = math.max(0.001, now - t_start)
        local progress_ratio = current_idx / total_files
        local pct = math.floor(progress_ratio * 100)
        local rate = current_idx / elapsed

        -- Estimate time remaining (ETA)
        local remaining_files = total_files - current_idx
        local eta_seconds = (rate > 0) and math.max(0, math.floor(remaining_files / rate)) or 0
        local eta_str
        if current_idx >= total_files then
            eta_str = string.format("Elapsed: %02d:%02d", math.floor(elapsed / 60), math.floor(elapsed % 60))
        elseif eta_seconds >= 60 then
            eta_str = string.format("ETA: %02dm%02ds", math.floor(eta_seconds / 60), eta_seconds % 60)
        else
            eta_str = string.format("ETA: %02ds", eta_seconds)
        end

        -- Progress bar with 24 blocks
        local bar_w = 24
        local filled = math.min(bar_w, math.floor(progress_ratio * bar_w))
        local bar = "\27[32m" .. string.rep("█", filled) .. "\27[90m" .. string.rep("░", bar_w - filled) .. "\27[0m"

        local status_line = string.format("\r\27[2K[%s] %3d%% │ %d/%d files │ %.1f MB │ %d f/s │ %s",
            bar, pct, current_idx, total_files, total_bytes / (1024 * 1024), math.floor(rate), eta_str)
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
            files_skipped = files_skipped + 1
        else
            -- Check if file already indexed and unchanged
            local existing = db:get_file_info(full_path)
            if existing and existing.size == meta.size and existing.mtime == meta.mtime then
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

    -- Prune deleted / stale files from database
    local files_pruned = 0
    local all_db_paths = db:get_all_filepaths()
    for _, db_path in ipairs(all_db_paths) do
        -- Only prune files that belong under root_dir
        local belongs = (root_dir == ".") or (db_path == root_dir) or (db_path:sub(1, #root_dir + 1) == (root_dir .. "/"))
        if belongs and not visited_paths[db_path] then
            db:remove_file(db_path)
            files_pruned = files_pruned + 1
        end
    end

    db:commit()
    local elapsed = os.clock() - t_start

    if verbose then
        print(string.format("\27[32m✔ Indexing completed in %.3fs\27[0m (%d files/sec)", elapsed, math.floor(total_files / math.max(0.001, elapsed))))
        print(string.format("  - Scanned: %d files", total_files))
        print(string.format("  - Indexed/Updated: %d files (%.2f MB)", files_indexed, total_bytes / (1024*1024)))
        print(string.format("  - Unchanged/Skipped: %d files", files_skipped))
        if files_pruned > 0 then
            print(string.format("  - Pruned (deleted): %d files", files_pruned))
        end
    end

    return {
        scanned = total_files,
        indexed = files_indexed,
        skipped = files_skipped,
        pruned  = files_pruned,
        bytes   = total_bytes,
        time    = elapsed
    }
end

--------------------------------------------------------------------------------
-- 6. Highlighting & Terminal Formatting
--------------------------------------------------------------------------------
local function colorize_text_matches(line, query_tokens)
    -- Highlight matched tokens within the line
    local highlighted = line
    for _, token in ipairs(query_tokens) do
        if #token > 0 then
            -- Case-insensitive match replace
            local pat = token:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
            highlighted = highlighted:gsub("(?i)" .. pat, function(m)
                return "\27[1;33m" .. m .. "\27[0m"
            end)
        end
    end
    return highlighted
end

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

local function format_bytes(bytes)
    if bytes < 1024 then return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024)
    else return string.format("%.2f MB", bytes / (1024 * 1024))
    end
end

--------------------------------------------------------------------------------
-- 7. Interactive Terminal UI (TUI) Mode
--------------------------------------------------------------------------------
local TUI = {}

function TUI.run(db, initial_query)
    -- Check if running in an interactive terminal
    if not is_windows then
        if ffi.C.isatty(0) == 0 then
            print("Note: TUI mode requires an interactive terminal (stdin is not a TTY).")
            return false
        end
    end

    local orig_termios = nil
    local in_raw_mode = false

    local function enable_raw()
        if is_windows then return true end
        orig_termios = ffi.new("struct termios")
        if ffi.C.tcgetattr(0, orig_termios) ~= 0 then return false end

        local raw = ffi.new("struct termios")
        ffi.copy(raw, orig_termios, ffi.sizeof("struct termios"))
        -- Disable ICANON, ECHO, ISIG
        raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
        if ffi.C.tcsetattr(0, 0, raw) == 0 then
            in_raw_mode = true
            -- Switch to alternate screen buffer, hide cursor, clear screen
            io.write("\27[?1049h\27[?25l\27[2J\27[H")
            io.flush()
            return true
        end
        return false
    end

    local function disable_raw()
        if in_raw_mode then
            -- Leave alternate screen buffer, show cursor, reset formatting
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            if orig_termios then
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
        if not is_windows then
            local ws = ffi.new("struct winsize")
            if ffi.C.ioctl(1, 0x5413, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
                return tonumber(ws.ws_col), tonumber(ws.ws_row)
            end
        end
        return 100, 30
    end

    local pfd = ffi.new("struct pollfd", { fd = 0, events = 1, revents = 0 })
    local key_buf = ffi.new("char[128]")
    local key_queue = {}

    local function read_key(timeout_ms)
        if #key_queue > 0 then
            return table.remove(key_queue, 1)
        end
        timeout_ms = timeout_ms or 30
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, 1) ~= 0 then
            local n = ffi.C.read(0, key_buf, 128)
            if n > 0 then
                local idx = 0
                while idx < n do
                    local c0 = key_buf[idx]
                    if c0 == 27 then -- ESC sequence
                        if idx + 2 < n and key_buf[idx + 1] == 91 then -- '['
                            local c2 = key_buf[idx + 2]
                            if c2 == 65 then table.insert(key_queue, "UP"); idx = idx + 3
                            elseif c2 == 66 then table.insert(key_queue, "DOWN"); idx = idx + 3
                            elseif c2 == 67 then table.insert(key_queue, "RIGHT"); idx = idx + 3
                            elseif c2 == 68 then table.insert(key_queue, "LEFT"); idx = idx + 3
                            elseif c2 == 53 and idx + 3 < n and key_buf[idx + 3] == 126 then table.insert(key_queue, "PAGE_UP"); idx = idx + 4
                            elseif c2 == 54 and idx + 3 < n and key_buf[idx + 3] == 126 then table.insert(key_queue, "PAGE_DOWN"); idx = idx + 4
                            elseif c2 == 72 then table.insert(key_queue, "HOME"); idx = idx + 3
                            elseif c2 == 70 then table.insert(key_queue, "END"); idx = idx + 3
                            else table.insert(key_queue, "ESC"); idx = idx + 1 end
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
                    elseif c0 == 4 then -- Ctrl-D
                        table.insert(key_queue, "CTRL_D")
                        idx = idx + 1
                    elseif c0 == 18 then -- Ctrl-R
                        table.insert(key_queue, "CTRL_R")
                        idx = idx + 1
                    elseif c0 == 3 then -- Ctrl-C
                        table.insert(key_queue, "CTRL_C")
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
    local selected_idx = 1
    local list_scroll_offset = 0
    local preview_scroll_offset = 0
    local focus_pane = "search" -- "search" | "preview"
    local vim_mode = "INSERT" -- "INSERT" | "NORMAL"
    local results = {}
    local error_msg = nil
    local status_bar_msg = nil
    local status_bar_time = 0

    local current_preview_file = nil
    local current_preview_lines = {}
    local current_match_lines = {}
    local current_match_list = {}
    local current_match_pos = 1
    local needs_redraw = true
    local search_pending = false
    local search_pending_time = 0

    -- LRU File lines cache to avoid re-reading files on disk
    local preview_file_cache = {}
    local preview_file_order = {}

    local function get_cached_file_lines(filepath)
        if preview_file_cache[filepath] then
            return preview_file_cache[filepath]
        end
        local lines = {}
        local f = io.open(filepath, "r")
        if f then
            for line in f:lines() do
                table.insert(lines, line)
                if #lines > 2000 then break end
            end
            f:close()
        end
        -- Maintain at most 16 cached files
        if #preview_file_order >= 16 then
            local oldest = table.remove(preview_file_order, 1)
            preview_file_cache[oldest] = nil
        end
        table.insert(preview_file_order, filepath)
        preview_file_cache[filepath] = lines
        return lines
    end

    local function set_status(msg)
        status_bar_msg = msg
        status_bar_time = os.clock()
        needs_redraw = true
    end

    local function load_preview_for(filepath, query_str)
        if current_preview_file == filepath then return end
        current_preview_file = filepath
        current_preview_lines = get_cached_file_lines(filepath)
        current_match_lines = {}
        current_match_list = {}
        current_match_pos = 1
        preview_scroll_offset = 0

        local terms = {}
        for t in query_str:gmatch("[%w_%-]+") do
            table.insert(terms, t:lower())
        end

        for idx, line in ipairs(current_preview_lines) do
            local l_lower = line:lower()
            for _, term in ipairs(terms) do
                if l_lower:find(term, 1, true) then
                    current_match_lines[idx] = true
                    table.insert(current_match_list, idx)
                    break
                end
            end
        end

        if #current_match_list > 0 then
            preview_scroll_offset = math.max(0, current_match_list[1] - 4)
            current_match_pos = 1
        end
    end

    local function refresh_search()
        if #query == 0 then
            results = {}
            error_msg = nil
            current_preview_file = nil
            current_preview_lines = {}
            current_match_lines = {}
            selected_idx = 1
            list_scroll_offset = 0
            search_pending = false
            needs_redraw = true
            return
        end
        local res, err = db:search(query, { limit = 100 })
        if err then
            error_msg = err
            results = {}
        else
            error_msg = nil
            results = res
            if selected_idx > #results then selected_idx = math.max(1, #results) end
            if #results > 0 and results[selected_idx] then
                load_preview_for(results[selected_idx].filepath, query)
            end
        end
        search_pending = false
        needs_redraw = true
    end

    refresh_search()

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

    local running = true

    -- Cached layout dimensions
    local cur_cols, cur_rows = get_term_size()
    cur_cols = math.max(60, cur_cols)
    cur_rows = math.max(15, cur_rows)
    local left_col_w = math.max(34, math.floor((cur_cols - 3) * 0.44))
    local right_col_w = cur_cols - 3 - left_col_w
    local list_height = cur_rows - 6

    local function update_layout()
        local cols, rows = get_term_size()
        cols = math.max(60, cols)
        rows = math.max(15, rows)
        if cols ~= cur_cols or rows ~= cur_rows then
            cur_cols = cols
            cur_rows = rows
            left_col_w = math.max(34, math.floor((cols - 3) * 0.44))
            right_col_w = cols - 3 - left_col_w
            list_height = rows - 6
            needs_full_redraw = true
        end
    end

    local function clamp_scroll()
        local max_scroll = math.max(0, #results - list_height)
        if selected_idx < list_scroll_offset + 1 then
            list_scroll_offset = selected_idx - 1
        elseif selected_idx > list_scroll_offset + list_height then
            list_scroll_offset = selected_idx - list_height
        end
        list_scroll_offset = math.max(0, math.min(list_scroll_offset, max_scroll))
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
            local max_p_len = text_w - 4
            local clean_path = full_path
            if visual_len(clean_path) > max_p_len and max_p_len > 8 then
                -- Intelligent path shortening: keep filename and parent folder
                local fname = get_filename(full_path)
                local dir = full_path:sub(1, #full_path - #fname)
                if #fname + 4 <= max_p_len then
                    clean_path = "..." .. full_path:sub(#full_path - (max_p_len - 4))
                else
                    clean_path = truncate(full_path, max_p_len)
                end
            end
            local full_text = marker .. clean_path
            local padded = pad_to(full_text, text_w)
            if is_sel then
                return "\27[1;30;43m" .. padded .. "\27[0m" .. left_sb
            else
                return "\27[37m" .. padded .. "\27[0m" .. left_sb
            end
        elseif #results == 0 and i == 2 then
            local prompt_msg = (#query == 0) and "  Type to search code..." or "  No matches found"
            return "\27[90m" .. pad_to(prompt_msg, text_w) .. "\27[0m" .. left_sb
        else
            return string.rep(" ", text_w) .. left_sb
        end
    end

    -- Instant visual echo: update only the query prompt line in row 2
    local function render_query_prompt_instant()
        local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
        local query_prompt = " > " .. query .. "_"
        local matches_badge = string.format("[%d Matches]", #results)
        local badge_w = visual_len(matches_badge)
        local left_head = ""
        if left_col_w > badge_w + 4 then
            left_head = pad_to(query_prompt, left_col_w - badge_w) .. matches_badge
        else
            left_head = pad_to(query_prompt, left_col_w)
        end
        -- Write directly to row 2, column 2 (inside left pane)
        io.write(string.format("\27[2;1H%s│\27[0m%s", left_col_border, pad_to(left_head, left_col_w)))
        io.flush()
    end

    -- Fast selective row update when selection moves within visible window
    local function render_selection_move(old_idx, new_idx)
        local list_thumb_pos = 1
        if #results > list_height then
            local max_offset = math.max(1, #results - list_height)
            list_thumb_pos = 1 + math.floor((list_scroll_offset / max_offset) * (list_height - 1))
        end

        local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
        local neutral_border = "\27[90m"

        local function redraw_one_row(target_idx, is_sel)
            local row_num = target_idx - list_scroll_offset
            if row_num >= 1 and row_num <= list_height then
                local y = 3 + row_num
                local left_cell = format_left_item(target_idx, is_sel, list_thumb_pos, row_num)
                io.write(string.format("\27[%d;1H%s│\27[0m%s%s│\27[0m", y, left_col_border, left_cell, neutral_border))
            end
        end

        redraw_one_row(old_idx, false)
        redraw_one_row(new_idx, true)
        io.flush()
    end

    local function render_full_screen()
        clamp_scroll()
        local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
        local right_col_border = (focus_pane == "preview") and "\27[1;32m" or "\27[90m"
        local neutral_border = "\27[90m"

        local frame_buf = {}
        local function emit_row(y, row_str)
            table.insert(frame_buf, string.format("\27[%d;1H\27[2K%s", y, row_str))
        end

        -- Row 1: Top Border
        emit_row(1, neutral_border .. "┌" .. left_col_border .. string.rep("─", left_col_w) .. neutral_border .. "┬" .. right_col_border .. string.rep("─", right_col_w) .. neutral_border .. "┐\27[0m")

        -- Row 2: Header Information Bar
        local query_prompt = " > " .. query .. "_"
        local matches_badge = string.format("[%d Matches]", #results)
        local badge_w = visual_len(matches_badge)
        local left_head = ""
        if left_col_w > badge_w + 4 then
            left_head = pad_to(query_prompt, left_col_w - badge_w) .. matches_badge
        else
            left_head = pad_to(query_prompt, left_col_w)
        end

        local right_head_title = ""
        if current_preview_file then
            local first_ln = 1
            for ln = 1, #current_preview_lines do
                if current_match_lines[ln] then first_ln = ln; break end
            end
            right_head_title = string.format(" 📄 %s:%d (%d/%d)", get_filename(current_preview_file), first_ln, preview_scroll_offset + 1, #current_preview_lines)
        else
            right_head_title = " 📄 Preview: (No file selected)"
        end
        local mode_badge = (vim_mode == "INSERT") and "\27[1;36m[INSERT]\27[0m" or "\27[1;33m[NORMAL]\27[0m"
        local pane_badge = (focus_pane == "preview") and "\27[1;32m[PREVIEW]\27[0m" or "\27[1;34m[RESULTS]\27[0m"
        local badges = pane_badge .. " " .. mode_badge
        local fbadge_w = visual_len(badges)
        local right_head = ""
        if right_col_w > fbadge_w + 4 then
            right_head = pad_to(right_head_title, right_col_w - fbadge_w) .. badges
        else
            right_head = pad_to(right_head_title, right_col_w)
        end

        emit_row(2, string.format("%s│\27[0m%s%s│\27[0m%s%s│\27[0m",
            left_col_border,
            pad_to(left_head, left_col_w),
            neutral_border,
            pad_to(right_head, right_col_w),
            right_col_border))

        -- Row 3: Split Divider
        emit_row(3, neutral_border .. "├" .. left_col_border .. string.rep("─", left_col_w) .. neutral_border .. "┼" .. right_col_border .. string.rep("─", right_col_w) .. neutral_border .. "┤\27[0m")

        -- Calculate scrollbar thumb positions
        local list_thumb_pos = 1
        if #results > list_height then
            local max_offset = math.max(1, #results - list_height)
            list_thumb_pos = 1 + math.floor((list_scroll_offset / max_offset) * (list_height - 1))
        end

        local prev_total = #current_preview_lines
        local prev_thumb_pos = 1
        if prev_total > list_height then
            local max_prev_offset = math.max(1, prev_total - list_height)
            prev_thumb_pos = 1 + math.floor((preview_scroll_offset / max_prev_offset) * (list_height - 1))
        end

        -- Rows 4 .. (4 + list_height - 1): Content rows
        for i = 1, list_height do
            local item_idx = list_scroll_offset + i
            local left_cell = format_left_item(item_idx, (item_idx == selected_idx), list_thumb_pos, i)

            -- Right scrollbar indicator
            local right_sb = " "
            if prev_total > list_height then
                right_sb = (i == prev_thumb_pos) and "\27[1;32m█\27[0m" or "\27[90m│\27[0m"
            end

            -- Right Content (Source preview)
            local right_cell = ""
            local r_text_w = right_col_w - 1
            if current_preview_file and #current_preview_lines > 0 then
                local file_line_num = preview_scroll_offset + i
                if file_line_num <= #current_preview_lines then
                    local line_content = current_preview_lines[file_line_num] or ""
                    local is_hit = current_match_lines[file_line_num]

                    local max_code_w = math.max(0, r_text_w - 9)
                    local code_str = truncate(line_content, max_code_w)
                    local line_pad = string.rep(" ", math.max(0, max_code_w - visual_len(code_str)))

                    if is_hit then
                        for tok in query:gmatch("[%w_%-]+") do
                            local pat = tok:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
                            code_str = code_str:gsub("(" .. pat .. ")", "\27[1;33;4m%1\27[0;1;37m")
                        end
                        right_cell = string.format("\27[1;33m> \27[90m%4d │\27[1;37m %s%s\27[0m%s", file_line_num, code_str, line_pad, right_sb)
                    else
                        right_cell = string.format("  \27[90m%4d │\27[0;37m %s%s\27[0m%s", file_line_num, code_str, line_pad, right_sb)
                    end
                else
                    right_cell = string.rep(" ", r_text_w) .. right_sb
                end
            else
                right_cell = string.rep(" ", r_text_w) .. right_sb
            end

            emit_row(3 + i, string.format("%s│\27[0m%s%s│\27[0m%s%s│\27[0m", left_col_border, left_cell, neutral_border, right_cell, right_col_border))
        end

        -- Row Bottom Divider
        local div_y = 3 + list_height + 1
        emit_row(div_y, neutral_border .. "├" .. left_col_border .. string.rep("─", left_col_w) .. neutral_border .. "┴" .. right_col_border .. string.rep("─", right_col_w) .. neutral_border .. "┤\27[0m")

        -- Row Footer / Keybindings
        local status_text = status_bar_msg
        if not status_text or (os.clock() - status_bar_time > 3.0) then
            if vim_mode == "INSERT" then
                status_text = " [INSERT] Type: Search  [Esc] Normal Mode  [Enter/o] Open  [↑/↓] Results  [^U] Clear  [^R] Reindex"
            else
                status_text = " [NORMAL] j/k: Nav  n/N: Match  h/l: Pane  i or /: Search  ^D/^U: Page  y: Yank  Enter/o: Open  q: Quit"
            end
        else
            status_text = " " .. status_text
        end
        local padded_status = pad_to(status_text, cur_cols - 2)
        local status_y = div_y + 1
        emit_row(status_y, string.format("%s│\27[1;30;47m%s\27[0m%s│\27[0m", neutral_border, padded_status, neutral_border))

        -- Final Bottom Border
        local bot_y = status_y + 1
        emit_row(bot_y, neutral_border .. "└" .. string.rep("─", cur_cols - 2) .. "┘\27[0m")

        -- Atomically write frame buffer with synchronized updates (Zero flicker)
        io.write("\27[?2026h" .. table.concat(frame_buf) .. "\27[?2026l")
        io.flush()
    end

    while running do
        update_layout()

        -- Trigger debounced background search when idle or queue drained
        if search_pending and (os.clock() - search_pending_time >= 0.03 or #key_queue == 0) then
            refresh_search()
        end

        if needs_redraw then
            needs_redraw = false
            render_full_screen()
        end

        -- Read input via non-blocking poll (shorter timeout when a search debounce is pending)
        local poll_timeout = search_pending and 10 or 35
        local key = read_key(poll_timeout)
        if key then
            if key == "CTRL_C" then
                running = false
            elseif key == "ESC" then
                if vim_mode == "INSERT" then
                    vim_mode = "NORMAL"
                    set_status("NORMAL mode")
                else
                    running = false
                end
            elseif key == "UP" then
                if focus_pane == "preview" then
                    if preview_scroll_offset > 0 then
                        preview_scroll_offset = preview_scroll_offset - 1
                        needs_redraw = true
                    end
                else
                    if selected_idx > 1 then
                        local old_idx = selected_idx
                        selected_idx = selected_idx - 1
                        if selected_idx >= list_scroll_offset + 1 then
                            render_selection_move(old_idx, selected_idx)
                            if #results > 0 and results[selected_idx] then
                                load_preview_for(results[selected_idx].filepath, query)
                                needs_redraw = true
                            end
                        else
                            clamp_scroll()
                            needs_redraw = true
                        end
                    end
                end
            elseif key == "DOWN" then
                if focus_pane == "preview" then
                    if preview_scroll_offset + 1 < #current_preview_lines then
                        preview_scroll_offset = preview_scroll_offset + 1
                        needs_redraw = true
                    end
                else
                    if selected_idx < #results then
                        local old_idx = selected_idx
                        selected_idx = selected_idx + 1
                        if selected_idx <= list_scroll_offset + list_height then
                            render_selection_move(old_idx, selected_idx)
                            if #results > 0 and results[selected_idx] then
                                load_preview_for(results[selected_idx].filepath, query)
                                needs_redraw = true
                            end
                        else
                            clamp_scroll()
                            needs_redraw = true
                        end
                    end
                end
            elseif key == "PAGE_UP" or (vim_mode == "NORMAL" and key == "CTRL_U") then
                if focus_pane == "preview" then
                    preview_scroll_offset = math.max(0, preview_scroll_offset - 10)
                else
                    selected_idx = math.max(1, selected_idx - 10)
                end
                clamp_scroll()
                needs_redraw = true
            elseif key == "PAGE_DOWN" or (vim_mode == "NORMAL" and key == "CTRL_D") then
                if focus_pane == "preview" then
                    preview_scroll_offset = math.min(#current_preview_lines, preview_scroll_offset + 10)
                else
                    selected_idx = math.min(#results, selected_idx + 10)
                end
                clamp_scroll()
                needs_redraw = true
            elseif key == "TAB" then
                focus_pane = (focus_pane == "search") and "preview" or "search"
                set_status("Active Pane: " .. focus_pane:upper())
            elseif key == "CTRL_U" and vim_mode == "INSERT" then
                query = ""
                selected_idx = 1
                render_query_prompt_instant()
                search_pending = true
                search_pending_time = os.clock()
                set_status("Query cleared")
            elseif key == "CTRL_R" then
                set_status("⚡ Incremental re-indexing in progress...")
                local stat_res = Indexer.run(db, ".", false)
                set_status(string.format("✔ Re-indexed %d files (Total: %d)", stat_res.indexed, db:get_stats().total_files))
                refresh_search()
            elseif key == "BACKSPACE" then
                if vim_mode == "INSERT" and #query > 0 then
                    query = query:sub(1, -2)
                    selected_idx = 1
                    render_query_prompt_instant()
                    search_pending = true
                    search_pending_time = os.clock()
                end
            elseif key == "ENTER" or (vim_mode == "NORMAL" and key == "o") then
                if #results > 0 and results[selected_idx] then
                    disable_raw()
                    local chosen = results[selected_idx].filepath
                    local first_ln = 1
                    for ln = 1, #current_preview_lines do
                        if current_match_lines[ln] then first_ln = ln; break end
                    end
                    local editor = os.getenv("EDITOR") or "vim"
                    local edit_cmd = string.format('%s +%d "%s"', editor, first_ln, chosen)
                    print(string.format("\nOpening %s:%d with %s...\n", chosen, first_ln, editor))
                    os.execute(edit_cmd)
                    return true
                end
            elseif vim_mode == "NORMAL" then
                if key == "i" or key == "/" then
                    vim_mode = "INSERT"
                    focus_pane = "search"
                    set_status("INSERT mode")
                elseif key == "j" then
                    if focus_pane == "preview" then
                        if preview_scroll_offset + 1 < #current_preview_lines then
                            preview_scroll_offset = preview_scroll_offset + 1
                            needs_redraw = true
                        end
                    else
                        if selected_idx < #results then
                            local old_idx = selected_idx
                            selected_idx = selected_idx + 1
                            if selected_idx <= list_scroll_offset + list_height then
                                render_selection_move(old_idx, selected_idx)
                                if #results > 0 and results[selected_idx] then
                                    load_preview_for(results[selected_idx].filepath, query)
                                    needs_redraw = true
                                end
                            else
                                clamp_scroll()
                                needs_redraw = true
                            end
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
                            selected_idx = selected_idx - 1
                            if selected_idx >= list_scroll_offset + 1 then
                                render_selection_move(old_idx, selected_idx)
                                if #results > 0 and results[selected_idx] then
                                    load_preview_for(results[selected_idx].filepath, query)
                                    needs_redraw = true
                                end
                            else
                                clamp_scroll()
                                needs_redraw = true
                            end
                        end
                    end
                elseif key == "h" then
                    focus_pane = "search"
                    needs_redraw = true
                elseif key == "l" then
                    focus_pane = "preview"
                    needs_redraw = true
                elseif key == "g" then
                    if focus_pane == "preview" then
                        preview_scroll_offset = 0
                    else
                        selected_idx = 1
                    end
                    clamp_scroll()
                    needs_redraw = true
                elseif key == "G" then
                    if focus_pane == "preview" then
                        preview_scroll_offset = math.max(0, #current_preview_lines - 5)
                    else
                        selected_idx = math.max(1, #results)
                    end
                    clamp_scroll()
                    needs_redraw = true
                elseif key == "n" then
                    -- Jump to next match in current file
                    if #current_match_list > 0 then
                        current_match_pos = (current_match_pos % #current_match_list) + 1
                        local target_ln = current_match_list[current_match_pos]
                        preview_scroll_offset = math.max(0, target_ln - 4)
                        set_status(string.format("Match %d/%d (line %d)", current_match_pos, #current_match_list, target_ln))
                        needs_redraw = true
                    end
                elseif key == "N" then
                    -- Jump to previous match in current file
                    if #current_match_list > 0 then
                        current_match_pos = current_match_pos - 1
                        if current_match_pos < 1 then current_match_pos = #current_match_list end
                        local target_ln = current_match_list[current_match_pos]
                        preview_scroll_offset = math.max(0, target_ln - 4)
                        set_status(string.format("Match %d/%d (line %d)", current_match_pos, #current_match_list, target_ln))
                        needs_redraw = true
                    end
                elseif key == "y" then
                    -- Yank (copy) filepath:line to clipboard
                    if #results > 0 and results[selected_idx] then
                        local chosen = results[selected_idx].filepath
                        local first_ln = 1
                        for ln = 1, #current_preview_lines do
                            if current_match_lines[ln] then first_ln = ln; break end
                        end
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
                    selected_idx = 1
                    vim_mode = "INSERT"
                    focus_pane = "search"
                    render_query_prompt_instant()
                    search_pending = true
                    search_pending_time = os.clock()
                end
            elseif #key == 1 and vim_mode == "INSERT" then
                query = query .. key
                -- Drain any additional pending single-character keys from the queue
                while #key_queue > 0 and #key_queue[1] == 1 do
                    query = query .. table.remove(key_queue, 1)
                end
                selected_idx = 1
                -- Instant 0ms visual echo to the prompt bar
                render_query_prompt_instant()
                search_pending = true
                search_pending_time = os.clock()
            end
        else
            -- Check if status bar message timed out
            if status_bar_msg and (os.clock() - status_bar_time > 3.0) then
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
CodeFind — High-Performance Local Code & Document Search Engine
Powered by LuaJIT FFI & SQLite FTS5 (Zero dependencies)

Usage:
  codefind <command> [arguments]

Commands:
  index  [dir]           Index or update repository files (default: current directory)
  search <query>         Fast ranked full-text search with context snippets
  tui    [query]         Interactive search browser with live side-by-side preview
  stats                  Show index database statistics (file counts, size, extensions)
  clean                  Drop index database and vacuum
  --test                 Run built-in unit & integration test suite

Options:
  --tui                  Launch interactive full-screen TUI (supports live search, scroll, open)
  --ext <extension>      Filter by file extension (e.g. --ext lua, --ext c)
  --all                  Index all text files (disables source code extension filter)
  --limit <n>            Maximum results to return (default: 20)
  --db <path>            Custom database file path (default: .codefind.db)

Examples:
  luajit codefind.lua index .
  luajit codefind.lua index . --all
  luajit codefind.lua search "sqlite3_prepare"
  luajit codefind.lua search "strtok" --tui
  luajit codefind.lua --tui
  luajit codefind.lua tui "metatype"
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

    db:close()
    os.remove(test_db_path)
    os.remove(test_db_path .. "-wal")
    os.remove(test_db_path .. "-shm")

    print("================================================================================")
    print("\27[1;32mALL CODEFIND TESTS PASSED SUCCESSFULLY! (6/6)\27[0m")
    print("================================================================================")
end

local function main(args)
    if #args == 0 or args[1] == "--help" or args[1] == "-h" then
        print_help()
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
    local ext_filter = nil
    local limit = 20
    local allow_all = false

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--tui" then
            use_tui = true
        elseif a == "--all" then
            allow_all = true
        elseif a == "--db" and i + 1 <= #args then
            db_path = args[i + 1]
            i = i + 1
        elseif a == "--ext" and i + 1 <= #args then
            ext_filter = args[i + 1]:lower():gsub("^%.", "")
            i = i + 1
        elseif a == "--limit" and i + 1 <= #args then
            limit = tonumber(args[i + 1]) or 20
            i = i + 1
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

    if command == "index" then
        local target_dir = cmd_args[1] or "."
        print(string.format("⚡ Indexing directory '%s' into %s (Source mode: %s)...", target_dir, db_path, allow_all and "ALL" or "SOURCE ONLY"))
        Indexer.run(db, target_dir, true, allow_all)
    elseif command == "search" then
        local query = table.concat(cmd_args, " ")
        if use_tui then
            TUI.run(db, query)
        else
            if #query == 0 then
                print("Error: search query cannot be empty. Example: codefind search 'function'")
                db:close()
                os.exit(1)
            end

            local t0 = os.clock()
            local results, err = db:search(query, { extension = ext_filter, limit = limit })
        local elapsed = (os.clock() - t0) * 1000

        if err then
            print(string.format("\27[31mError: %s\27[0m", err))
            db:close()
            os.exit(1)
        end

        if #results == 0 then
            print(string.format("\27[90mNo matches found for '%s' (%.1fms)\27[0m", query, elapsed))
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
    elseif command == "tui" then
        local query = table.concat(cmd_args, " ")
        TUI.run(db, query)
    elseif command == "stats" then
        local stats = db:get_stats()
        print("\n=== CodeFind Database Statistics ===")
        print(string.format("Database Path : %s", db_path))
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
        Database = Database,
        Indexer  = Indexer,
        TUI      = TUI
    }
else
    main(arg)
end
