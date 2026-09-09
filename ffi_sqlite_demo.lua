--[[
    ffi_sqlite_demo.lua
    A complete, practical demonstration of LuaJIT FFI interacting with libsqlite3.

    Features demonstrated:
    1. C structure and function bindings (ffi.cdef)
    2. Dynamic library loading (ffi.load)
    3. Pointer passing, error strings, and memory handling
    4. Safe parameterized queries (prepared statements) to prevent injection
    5. Clean Lua OOP wrapper around raw C handles
    6. Performance benchmarking: raw insertions inside a transaction
]]

local ffi = require("ffi")

-- 1. C Declarations for SQLite3
ffi.cdef[[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    // Database lifecycle
    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3 *db);
    const char *sqlite3_errmsg(sqlite3 *db);

    // Direct execution
    int sqlite3_exec(sqlite3 *db, const char *sql,
                     int (*callback)(void*, int, char**, char**),
                     void *arg, char **errmsg);
    void sqlite3_free(void *ptr);

    // Prepared statements
    int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                           sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt *pStmt);
    int sqlite3_finalize(sqlite3_stmt *pStmt);
    int sqlite3_reset(sqlite3_stmt *pStmt);

    // Parameter binding
    int sqlite3_bind_int(sqlite3_stmt *pStmt, int idx, int val);
    int sqlite3_bind_double(sqlite3_stmt *pStmt, int idx, double val);
    int sqlite3_bind_text(sqlite3_stmt *pStmt, int idx, const char *val, int len, void(*destructor)(void*));

    // Column extraction
    int sqlite3_column_count(sqlite3_stmt *pStmt);
    int sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
    const char *sqlite3_column_name(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
    const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);

    // High-resolution clock for benchmarking
    typedef struct { long tv_sec; long tv_nsec; } ffi_timespec;
    int clock_gettime(int clk_id, ffi_timespec *tp);
]]

-- 2. Load SQLite3 Library
local sqlite = ffi.load("sqlite3")

-- SQLite constants
local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

-- Helper: nanosecond timing
local function get_time_ms()
    local ts = ffi.new("ffi_timespec")
    ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC = 1
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

-- 3. Lua OOP Wrapper around SQLite3
local Database = {}
Database.__index = Database

function Database.open(filename)
    local db_ptr = ffi.new("sqlite3*[1]")
    local rc = sqlite.sqlite3_open(filename or ":memory:", db_ptr)
    if rc ~= SQLITE_OK then
        local err = ffi.string(sqlite.sqlite3_errmsg(db_ptr[0]))
        sqlite.sqlite3_close(db_ptr[0])
        error("Failed to open database: " .. err)
    end
    return setmetatable({ _db = db_ptr[0] }, Database)
end

function Database:close()
    if self._db then
        sqlite.sqlite3_close(self._db)
        self._db = nil
    end
end

function Database:exec(sql)
    local errmsg = ffi.new("char*[1]")
    local rc = sqlite.sqlite3_exec(self._db, sql, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local err = ffi.string(errmsg[0])
        sqlite.sqlite3_free(errmsg[0])
        error("Execution error: " .. err .. " in SQL: " .. sql)
    end
end

function Database:prepare(sql)
    local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite.sqlite3_prepare_v2(self._db, sql, #sql, stmt_ptr, nil)
    if rc ~= SQLITE_OK then
        error("Prepare error: " .. ffi.string(sqlite.sqlite3_errmsg(self._db)))
    end

    local stmt = { _stmt = stmt_ptr[0], _db = self._db }

    function stmt:bind(params)
        for idx, val in ipairs(params) do
            local t = type(val)
            if t == "number" then
                if math.floor(val) == val then
                    sqlite.sqlite3_bind_int(self._stmt, idx, val)
                else
                    sqlite.sqlite3_bind_double(self._stmt, idx, val)
                end
            elseif t == "string" then
                sqlite.sqlite3_bind_text(self._stmt, idx, val, #val, SQLITE_TRANSIENT)
            else
                error("Unsupported bind parameter type: " .. t)
            end
        end
    end

    function stmt:step()
        local rc = sqlite.sqlite3_step(self._stmt)
        return rc == SQLITE_ROW
    end

    function stmt:columns()
        local num_cols = sqlite.sqlite3_column_count(self._stmt)
        local row = {}
        for i = 0, num_cols - 1 do
            local name = ffi.string(sqlite.sqlite3_column_name(self._stmt, i))
            local col_type = sqlite.sqlite3_column_type(self._stmt, i)
            if col_type == SQLITE_INTEGER then
                row[name] = sqlite.sqlite3_column_int(self._stmt, i)
            elseif col_type == SQLITE_FLOAT then
                row[name] = sqlite.sqlite3_column_double(self._stmt, i)
            elseif col_type == SQLITE_TEXT then
                row[name] = ffi.string(sqlite.sqlite3_column_text(self._stmt, i))
            elseif col_type == SQLITE_NULL then
                row[name] = nil
            end
        end
        return row
    end

    function stmt:reset()
        sqlite.sqlite3_reset(self._stmt)
    end

    function stmt:finalize()
        if self._stmt then
            sqlite.sqlite3_finalize(self._stmt)
            self._stmt = nil
        end
    end

    return stmt
end

function Database:query(sql, params)
    local stmt = self:prepare(sql)
    if params then
        stmt:bind(params)
    end
    local rows = {}
    while stmt:step() do
        table.insert(rows, stmt:columns())
    end
    stmt:finalize()
    return rows
end

-- =========================================================================
-- 4. Demo Walkthrough
-- =========================================================================

print("=== Practical LuaJIT FFI: SQLite Database Project Demo ===")

-- A. Create an in-memory database
local db = Database.open(":memory:")
print("[+] Created in-memory SQLite database via ffi.load('sqlite3')")

-- B. Create a schema
db:exec([[
    CREATE TABLE products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        price REAL NOT NULL,
        stock INTEGER NOT NULL
    );
]])
print("[+] Created table 'products'")

-- C. Prepared Statement & Parameter Binding
local insert_stmt = db:prepare("INSERT INTO products (name, category, price, stock) VALUES (?, ?, ?, ?);")

local seed_items = {
    {"Mechanical Keyboard", "Hardware", 89.99, 15},
    {"USB-C Hub", "Accessories", 29.50, 42},
    {"Noise-Cancelling Headphones", "Audio", 199.00, 8},
    {"4K Monitor 27-inch", "Hardware", 329.95, 5},
    {"Ergonomic Mouse", "Accessories", 49.99, 20}
}

for _, item in ipairs(seed_items) do
    insert_stmt:bind(item)
    insert_stmt:step()
    insert_stmt:reset()
end
insert_stmt:finalize()
print(string.format("[+] Seeded %d initial products using prepared statements", #seed_items))

-- D. Querying with filters
print("\n--- Query: Hardware products costing > $50 ---")
local results = db:query("SELECT id, name, price, stock FROM products WHERE category = ? AND price > ?;", {"Hardware", 50.0})

for _, row in ipairs(results) do
    print(string.format("  [%d] %-30s | Price: $%6.2f | Stock: %d", row.id, row.name, row.price, row.stock))
end

-- E. Performance Benchmark: Fast batch insert inside a transaction
local BATCH_SIZE = 10000
print(string.format("\n--- Benchmark: Inserting %d rows inside an FFI transaction ---", BATCH_SIZE))

local t_start = get_time_ms()
db:exec("BEGIN TRANSACTION;")
local batch_stmt = db:prepare("INSERT INTO products (name, category, price, stock) VALUES (?, ?, ?, ?);")

for i = 1, BATCH_SIZE do
    batch_stmt:bind({"Benchmark Item " .. i, "Benchmark", 9.99 + (i % 100), i})
    batch_stmt:step()
    batch_stmt:reset()
end
batch_stmt:finalize()
db:exec("COMMIT;")
local t_elapsed = get_time_ms() - t_start

print(string.format("  Total time: %.2f ms", t_elapsed))
print(string.format("  Throughput: %.0f inserts/sec", (BATCH_SIZE / t_elapsed) * 1000))

-- F. Aggregate query
local count_result = db:query("SELECT COUNT(*) AS total_count, AVG(price) AS avg_price FROM products;")
print(string.format("\n--- Summary ---"))
print(string.format("  Total Products in DB: %d", count_result[1].total_count))
print(string.format("  Average Price: $%.2f", count_result[1].avg_price))

-- Cleanup
db:close()
print("\n[+] Database closed cleanly. Demo finished successfully!")
