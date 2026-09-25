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
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    local sql = "SELECT id, size, mtime FROM files WHERE filepath = ? LIMIT 1;"
    if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then
        return nil
    end
    local stmt = stmt_p[0]
    sqlite.sqlite3_bind_text(stmt, 1, filepath, #filepath, SQLITE_TRANSIENT)
    local res = nil
    if sqlite.sqlite3_step(stmt) == SQLITE_ROW then
        res = {
            id = tonumber(sqlite.sqlite3_column_int64(stmt, 0)),
            size = tonumber(sqlite.sqlite3_column_int64(stmt, 1)),
            mtime = tonumber(sqlite.sqlite3_column_int64(stmt, 2)),
        }
    end
    sqlite.sqlite3_finalize(stmt)
    return res
end

function Database:index_file(filepath, filename, ext, size, mtime, content)
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    
    -- 1. Remove previous FTS and file entry if updating
    local sql_del_fts = "DELETE FROM code_idx WHERE filepath = ?;"
    if sqlite.sqlite3_prepare_v2(self.db, sql_del_fts, #sql_del_fts, stmt_p, nil) == SQLITE_OK then
        sqlite.sqlite3_bind_text(stmt_p[0], 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_p[0])
        sqlite.sqlite3_finalize(stmt_p[0])
    end

    local sql_del_files = "DELETE FROM files WHERE filepath = ?;"
    if sqlite.sqlite3_prepare_v2(self.db, sql_del_files, #sql_del_files, stmt_p, nil) == SQLITE_OK then
        sqlite.sqlite3_bind_text(stmt_p[0], 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_p[0])
        sqlite.sqlite3_finalize(stmt_p[0])
    end

    -- 2. Insert into files table
    local sql_ins_f = "INSERT INTO files (filepath, filename, extension, size, mtime) VALUES (?, ?, ?, ?, ?);"
    if sqlite.sqlite3_prepare_v2(self.db, sql_ins_f, #sql_ins_f, stmt_p, nil) == SQLITE_OK then
        sqlite.sqlite3_bind_text(stmt_p[0], 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_p[0], 2, filename, #filename, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_p[0], 3, ext or "", #(ext or ""), SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_int64(stmt_p[0], 4, size)
        sqlite.sqlite3_bind_int64(stmt_p[0], 5, mtime)
        sqlite.sqlite3_step(stmt_p[0])
        sqlite.sqlite3_finalize(stmt_p[0])
    end

    -- 3. Insert into FTS5 index
    local sql_ins_fts = "INSERT INTO code_idx (filepath, filename, content) VALUES (?, ?, ?);"
    if sqlite.sqlite3_prepare_v2(self.db, sql_ins_fts, #sql_ins_fts, stmt_p, nil) == SQLITE_OK then
        sqlite.sqlite3_bind_text(stmt_p[0], 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_p[0], 2, filename, #filename, SQLITE_TRANSIENT)
        sqlite.sqlite3_bind_text(stmt_p[0], 3, content, #content, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_p[0])
        sqlite.sqlite3_finalize(stmt_p[0])
    end
end

function Database:remove_file(filepath)
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    local sql1 = "DELETE FROM code_idx WHERE filepath = ?;"
    if sqlite.sqlite3_prepare_v2(self.db, sql1, #sql1, stmt_p, nil) == SQLITE_OK then
        sqlite.sqlite3_bind_text(stmt_p[0], 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_p[0])
        sqlite.sqlite3_finalize(stmt_p[0])
    end

    local sql2 = "DELETE FROM files WHERE filepath = ?;"
    if sqlite.sqlite3_prepare_v2(self.db, sql2, #sql2, stmt_p, nil) == SQLITE_OK then
        sqlite.sqlite3_bind_text(stmt_p[0], 1, filepath, #filepath, SQLITE_TRANSIENT)
        sqlite.sqlite3_step(stmt_p[0])
        sqlite.sqlite3_finalize(stmt_p[0])
    end
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
    [".git"] = true,
    ["node_modules"] = true,
    [".svn"] = true,
    [".hg"] = true,
    ["build"] = true,
    ["dist"] = true,
    ["target"] = true,
    ["__pycache__"] = true,
    [".idea"] = true,
    [".vscode"] = true
}

local BINARY_EXTENSIONS = {
    ["so"] = true, ["dll"] = true, ["dylib"] = true, ["a"] = true, ["o"] = true,
    ["exe"] = true, ["bin"] = true, ["png"] = true, ["jpg"] = true, ["jpeg"] = true,
    ["gif"] = true, ["bmp"] = true, ["webp"] = true, ["mp3"] = true, ["mp4"] = true,
    ["zip"] = true, ["tar"] = true, ["gz"] = true, ["bz2"] = true, ["xz"] = true,
    ["pdf"] = true, ["db"] = true, ["sqlite"] = true, ["sqlite3"] = true, ["iso"] = true
}

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

function Indexer.run(db, root_dir, verbose)
    root_dir = root_dir or "."
    -- strip trailing slash
    root_dir = root_dir:gsub("[/\\]+$", "")
    if #root_dir == 0 then root_dir = "." end

    local files_found = 0
    local files_indexed = 0
    local files_skipped = 0
    local total_bytes = 0

    local t_start = os.clock()
    db:begin()

    local batch_count = 0

    scan_directory(root_dir, function(full_path, fname)
        -- Ignore internal DB file itself
        if fname:find("%.db$") or fname:find("%.db%-wal$") or fname:find("%.db%-shm$") then return end

        files_found = files_found + 1
        local ext = get_file_extension(fname)

        if BINARY_EXTENSIONS[ext] then
            files_skipped = files_skipped + 1
            return
        end

        local meta = get_file_metadata(full_path)
        if not meta or meta.size > (5 * 1024 * 1024) then -- skip > 5MB single files
            files_skipped = files_skipped + 1
            return
        end

        -- Check if file already indexed and unchanged
        local existing = db:get_file_info(full_path)
        if existing and existing.size == meta.size and existing.mtime == meta.mtime then
            files_skipped = files_skipped + 1
            return
        end

        -- Read content
        local f = io.open(full_path, "rb")
        if not f then
            files_skipped = files_skipped + 1
            return
        end
        local content = f:read("*a")
        f:close()

        if not content or is_binary_buffer(content) then
            files_skipped = files_skipped + 1
            return
        end

        db:index_file(full_path, fname, ext, meta.size, meta.mtime, content)
        files_indexed = files_indexed + 1
        total_bytes = total_bytes + meta.size
        batch_count = batch_count + 1

        if batch_count >= 500 then
            db:commit()
            db:begin()
            batch_count = 0
            if verbose then
                io.write(string.format("\rIndexed %d files (%.1f MB)...", files_indexed, total_bytes / (1024*1024)))
                io.flush()
            end
        end
    end)

    db:commit()
    local elapsed = os.clock() - t_start

    if verbose then
        if files_indexed > 0 then io.write("\r" .. string.rep(" ", 40) .. "\r") end
        print(string.format("\27[32m✔ Indexing completed in %.3fs\27[0m", elapsed))
        print(string.format("  - Scanned: %d files", files_found))
        print(string.format("  - Indexed/Updated: %d files (%.2f MB)", files_indexed, total_bytes / (1024*1024)))
        print(string.format("  - Unchanged/Skipped: %d files", files_skipped))
    end

    return {
        scanned = files_found,
        indexed = files_indexed,
        skipped = files_skipped,
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
    local key_buf = ffi.new("char[32]")

    local function read_key(timeout_ms)
        timeout_ms = timeout_ms or 30
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, 1) ~= 0 then
            local n = ffi.C.read(0, key_buf, 32)
            if n > 0 then
                local c0 = key_buf[0]
                if c0 == 27 then -- ESC sequence
                    if n == 1 then
                        -- Check if more bytes are coming rapidly (within 20ms)
                        local more = ffi.C.poll(pfd, 1, 20)
                        if more > 0 and bit.band(pfd.revents, 1) ~= 0 then
                            local got = ffi.C.read(0, key_buf + 1, 31)
                            if got > 0 then n = n + got end
                        else
                            return "ESC"
                        end
                    end

                    if n >= 3 and key_buf[1] == 91 then -- '['
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP"
                        elseif c2 == 66 then return "DOWN"
                        elseif c2 == 67 then return "RIGHT"
                        elseif c2 == 68 then return "LEFT"
                        elseif c2 == 53 and n >= 4 and key_buf[3] == 126 then return "PAGE_UP"
                        elseif c2 == 54 and n >= 4 and key_buf[3] == 126 then return "PAGE_DOWN"
                        elseif c2 == 72 then return "HOME"
                        elseif c2 == 70 then return "END"
                        end
                    end
                    return "ESC"
                elseif c0 == 10 or c0 == 13 then
                    return "ENTER"
                elseif c0 == 9 then
                    return "TAB"
                elseif c0 == 127 or c0 == 8 then
                    return "BACKSPACE"
                elseif c0 == 21 then -- Ctrl-U
                    return "CTRL_U"
                elseif c0 == 18 then -- Ctrl-R
                    return "CTRL_R"
                elseif c0 == 3 then -- Ctrl-C
                    return "CTRL_C"
                elseif c0 >= 32 and c0 <= 126 then
                    return string.char(c0)
                end
            end
        end
        return nil
    end

    local query = initial_query or ""
    local selected_idx = 1
    local list_scroll_offset = 0
    local preview_scroll_offset = 0
    local focus_pane = "search" -- "search" | "preview"
    local results = {}
    local error_msg = nil
    local status_bar_msg = nil
    local status_bar_time = 0

    local current_preview_file = nil
    local current_preview_lines = {}
    local current_match_lines = {}
    local needs_redraw = true

    local function set_status(msg)
        status_bar_msg = msg
        status_bar_time = os.clock()
        needs_redraw = true
    end

    local function load_preview_for(filepath, query_str)
        if current_preview_file == filepath then return end
        current_preview_file = filepath
        current_preview_lines = {}
        current_match_lines = {}
        preview_scroll_offset = 0

        local f = io.open(filepath, "r")
        if f then
            for line in f:lines() do
                table.insert(current_preview_lines, line)
                if #current_preview_lines > 2000 then break end
            end
            f:close()
        end

        local terms = {}
        for t in query_str:gmatch("[%w_%-]+") do
            table.insert(terms, t:lower())
        end

        for idx, line in ipairs(current_preview_lines) do
            local l_lower = line:lower()
            for _, term in ipairs(terms) do
                if l_lower:find(term, 1, true) then
                    current_match_lines[idx] = true
                    break
                end
            end
        end

        for idx = 1, #current_preview_lines do
            if current_match_lines[idx] then
                preview_scroll_offset = math.max(0, idx - 4)
                break
            end
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

    while running do
        if needs_redraw then
            needs_redraw = false
            local cols, rows = get_term_size()
            cols = math.max(60, cols)
            rows = math.max(15, rows)

            local left_col_w = math.max(24, math.floor((cols - 3) * 0.38))
            local right_col_w = cols - 3 - left_col_w
            local list_height = rows - 6

            if selected_idx < list_scroll_offset + 1 then
                list_scroll_offset = selected_idx - 1
            elseif selected_idx > list_scroll_offset + list_height then
                list_scroll_offset = selected_idx - list_height
            end
            list_scroll_offset = math.max(0, list_scroll_offset)

            if #results > 0 and results[selected_idx] then
                load_preview_for(results[selected_idx].filepath, query)
            end

            local frame_buf = {}
            local function emit_row(y, row_str)
                table.insert(frame_buf, string.format("\27[%d;1H\27[2K%s", y, row_str))
            end

            local left_col_border = (focus_pane == "search") and "\27[1;36m" or "\27[90m"
            local right_col_border = (focus_pane == "preview") and "\27[1;32m" or "\27[90m"
            local neutral_border = "\27[90m"

            -- Row 1: Top Border (Exact visual width: 1 + left_col_w + 1 + right_col_w + 1 = cols)
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
            local focus_badge = (focus_pane == "preview") and "\27[1;32m[PREVIEW ACTIVE]\27[0m" or "\27[1;36m[SEARCH ACTIVE]\27[0m"
            local fbadge_w = visual_len(focus_badge)
            local right_head = ""
            if right_col_w > fbadge_w + 4 then
                right_head = pad_to(right_head_title, right_col_w - fbadge_w) .. focus_badge
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

            -- Rows 4 .. (4 + list_height - 1): Content rows
            for i = 1, list_height do
                local item_idx = list_scroll_offset + i
                local res_item = results[item_idx]

                -- Left Content (File list)
                local left_cell = ""
                if res_item then
                    local is_sel = (item_idx == selected_idx)
                    local marker = is_sel and "▶ " or "  "
                    local clean_path = res_item.filepath
                    local max_p_len = left_col_w - 4
                    if #clean_path > max_p_len and max_p_len > 6 then
                        clean_path = "..." .. clean_path:sub(#clean_path - (max_p_len - 4))
                    end

                    local full_text = marker .. clean_path
                    local padded = pad_to(full_text, left_col_w)
                    if is_sel then
                        left_cell = "\27[1;30;43m" .. padded .. "\27[0m"
                    else
                        left_cell = "\27[37m" .. padded .. "\27[0m"
                    end
                elseif #results == 0 and i == 2 then
                    local prompt_msg = (#query == 0) and "  Type to search code..." or "  No matches found"
                    left_cell = "\27[90m" .. pad_to(prompt_msg, left_col_w) .. "\27[0m"
                else
                    left_cell = string.rep(" ", left_col_w)
                end

                -- Right Content (Source preview)
                local right_cell = ""
                if current_preview_file and #current_preview_lines > 0 then
                    local file_line_num = preview_scroll_offset + i
                    if file_line_num <= #current_preview_lines then
                        local line_content = current_preview_lines[file_line_num] or ""
                        local is_hit = current_match_lines[file_line_num]

                        local max_code_w = math.max(0, right_col_w - 9)
                        local code_str = truncate(line_content, max_code_w)
                        local line_pad = string.rep(" ", math.max(0, max_code_w - visual_len(code_str)))

                        if is_hit then
                            for tok in query:gmatch("[%w_%-]+") do
                                local pat = tok:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
                                code_str = code_str:gsub("(" .. pat .. ")", "\27[1;33;4m%1\27[0;1;37m")
                            end
                            right_cell = string.format("\27[1;33m> \27[90m%4d │\27[1;37m %s%s\27[0m", file_line_num, code_str, line_pad)
                        else
                            right_cell = string.format("  \27[90m%4d │\27[0;37m %s%s\27[0m", file_line_num, code_str, line_pad)
                        end
                    else
                        right_cell = string.rep(" ", right_col_w)
                    end
                else
                    right_cell = string.rep(" ", right_col_w)
                end

                emit_row(3 + i, string.format("%s│\27[0m%s%s│\27[0m%s%s│\27[0m", left_col_border, left_cell, neutral_border, right_cell, right_col_border))
            end

            -- Row Bottom Divider
            local div_y = 3 + list_height + 1
            emit_row(div_y, neutral_border .. "├" .. left_col_border .. string.rep("─", left_col_w) .. neutral_border .. "┴" .. right_col_border .. string.rep("─", right_col_w) .. neutral_border .. "┤\27[0m")

            -- Row Footer / Keybindings
            local status_text = status_bar_msg
            if not status_text or (os.clock() - status_bar_time > 3.0) then
                status_text = " [Type] Search  [↑/↓] Results  [Tab] Focus  [PgUp/Dn] Scroll  [^U] Clear  [^R] Reindex  [Enter] Open  [Esc] Quit"
            else
                status_text = " " .. status_text
            end
            local padded_status = pad_to(status_text, cols - 2)
            local status_y = div_y + 1
            emit_row(status_y, string.format("%s│\27[1;30;47m%s\27[0m%s│\27[0m", neutral_border, padded_status, neutral_border))

            -- Final Bottom Border
            local bot_y = status_y + 1
            emit_row(bot_y, neutral_border .. "└" .. string.rep("─", cols - 2) .. "┘\27[0m")

            -- Atomically write frame buffer with synchronized updates (Zero flicker)
            io.write("\27[?2026h" .. table.concat(frame_buf) .. "\27[?2026l")
            io.flush()
        end

        -- Read input via non-blocking poll
        local key = read_key(40)
        if key then
            if key == "ESC" or key == "CTRL_C" then
                running = false
            elseif key == "UP" then
                if focus_pane == "preview" then
                    if preview_scroll_offset > 0 then
                        preview_scroll_offset = preview_scroll_offset - 1
                        needs_redraw = true
                    end
                else
                    if selected_idx > 1 then
                        selected_idx = selected_idx - 1
                        needs_redraw = true
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
                        selected_idx = selected_idx + 1
                        needs_redraw = true
                    end
                end
            elseif key == "PAGE_UP" then
                if focus_pane == "preview" then
                    preview_scroll_offset = math.max(0, preview_scroll_offset - 10)
                else
                    selected_idx = math.max(1, selected_idx - 10)
                end
                needs_redraw = true
            elseif key == "PAGE_DOWN" then
                if focus_pane == "preview" then
                    preview_scroll_offset = math.min(#current_preview_lines, preview_scroll_offset + 10)
                else
                    selected_idx = math.min(#results, selected_idx + 10)
                end
                needs_redraw = true
            elseif key == "TAB" then
                focus_pane = (focus_pane == "search") and "preview" or "search"
                set_status("Active Pane: " .. focus_pane:upper())
            elseif key == "CTRL_U" then
                query = ""
                selected_idx = 1
                refresh_search()
                set_status("Query cleared")
            elseif key == "CTRL_R" then
                set_status("⚡ Incremental re-indexing in progress...")
                local stat_res = Indexer.run(db, ".", false)
                set_status(string.format("✔ Re-indexed %d files (Total: %d)", stat_res.indexed, db:get_stats().total_files))
                refresh_search()
            elseif key == "BACKSPACE" then
                if focus_pane == "search" and #query > 0 then
                    query = query:sub(1, -2)
                    selected_idx = 1
                    refresh_search()
                end
            elseif key == "ENTER" then
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
            elseif #key == 1 then
                if focus_pane == "preview" then
                    if key == "j" then
                        if preview_scroll_offset + 1 < #current_preview_lines then
                            preview_scroll_offset = preview_scroll_offset + 1
                            needs_redraw = true
                        end
                    elseif key == "k" then
                        if preview_scroll_offset > 0 then
                            preview_scroll_offset = preview_scroll_offset - 1
                            needs_redraw = true
                        end
                    end
                else
                    query = query .. key
                    selected_idx = 1
                    refresh_search()
                end
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
  --limit <n>            Maximum results to return (default: 20)
  --db <path>            Custom database file path (default: .codefind.db)

Examples:
  luajit codefind.lua index .
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

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--tui" then
            use_tui = true
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
        print(string.format("⚡ Indexing directory '%s' into %s...", target_dir, db_path))
        Indexer.run(db, target_dir, true)
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
