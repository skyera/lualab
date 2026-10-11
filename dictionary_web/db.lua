-- SQLite persistence through LuaJIT FFI; all values use prepared statements.
local ffi = require('ffi')
local json = require('json')
ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open(const char *, sqlite3 **);
int sqlite3_close(sqlite3 *);
const char *sqlite3_errmsg(sqlite3 *);
int sqlite3_busy_timeout(sqlite3 *, int);
int sqlite3_prepare_v2(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
int sqlite3_step(sqlite3_stmt *);
int sqlite3_finalize(sqlite3_stmt *);
int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int, void (*)(void *));
int sqlite3_bind_double(sqlite3_stmt *, int, double);
int sqlite3_bind_null(sqlite3_stmt *, int);
int sqlite3_column_count(sqlite3_stmt *);
int sqlite3_column_type(sqlite3_stmt *, int);
const char *sqlite3_column_name(sqlite3_stmt *, int);
const unsigned char *sqlite3_column_text(sqlite3_stmt *, int);
double sqlite3_column_double(sqlite3_stmt *, int);
int sqlite3_exec(sqlite3 *, const char *, void *, void *, char **);
void sqlite3_free(void *);
]]
local sqlite = ffi.load('sqlite3')
local transient = ffi.cast('void (*)(void *)', -1)

local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_ROW     = 100
local SQLITE_DONE    = 101

local DB = {}
DB.__index = DB

function DB.open(path, schema)
    local ptr = ffi.new('sqlite3 *[1]')
    if sqlite.sqlite3_open(path, ptr) ~= 0 then
        local message = ptr[0] ~= nil and ffi.string(sqlite.sqlite3_errmsg(ptr[0])) or 'SQLite open failed'
        if ptr[0] ~= nil then
            sqlite.sqlite3_close(ptr[0])
        end
        error(message)
    end
    local self = setmetatable({handle = ffi.gc(ptr[0], sqlite.sqlite3_close)}, DB)
    sqlite.sqlite3_busy_timeout(self.handle, 5000)
    if schema then
        local err_msg = ffi.new('char *[1]')
        local rc = sqlite.sqlite3_exec(self.handle, schema, nil, nil, err_msg)
        if rc ~= 0 then
            local err = err_msg[0] ~= nil and ffi.string(err_msg[0]) or 'Schema execution failed'
            if err_msg[0] ~= nil then sqlite.sqlite3_free(err_msg[0]) end
            self:close()
            error(err)
        end
    end
    return self
end

function DB:close()
    if self.handle then
        sqlite.sqlite3_close(ffi.gc(self.handle, nil))
        self.handle = nil
    end
end

function DB:query(sql, params)
    assert(self.handle, 'Database is closed')
    local ptr = ffi.new('sqlite3_stmt *[1]')
    if sqlite.sqlite3_prepare_v2(self.handle, sql, #sql, ptr, nil) ~= 0 then
        error(ffi.string(sqlite.sqlite3_errmsg(self.handle)))
    end
    local stmt = ptr[0]
    local ok, result = pcall(function()
        for index, value in ipairs(params or {}) do
            local rc
            if type(value) == 'number' then
                rc = sqlite.sqlite3_bind_double(stmt, index, value)
            elseif value == false then
                rc = sqlite.sqlite3_bind_null(stmt, index)
            else
                local text = tostring(value)
                rc = sqlite.sqlite3_bind_text(stmt, index, text, #text, transient)
            end
            assert(rc == 0, 'SQLite parameter binding failed')
        end
        local rows = {}
        while true do
            local rc = sqlite.sqlite3_step(stmt)
            if rc == SQLITE_DONE then break end
            if rc ~= SQLITE_ROW then
                error(ffi.string(sqlite.sqlite3_errmsg(self.handle)))
            end
            local row = {}
            for index = 0, sqlite.sqlite3_column_count(stmt) - 1 do
                local kind = sqlite.sqlite3_column_type(stmt, index)
                local name = ffi.string(sqlite.sqlite3_column_name(stmt, index))
                if kind == SQLITE_INTEGER or kind == SQLITE_FLOAT then
                    row[name] = sqlite.sqlite3_column_double(stmt, index)
                elseif kind == SQLITE_TEXT then
                    row[name] = ffi.string(sqlite.sqlite3_column_text(stmt, index))
                end
            end
            rows[#rows + 1] = row
        end
        return rows
    end)
    sqlite.sqlite3_finalize(stmt)
    if not ok then error(result) end
    return result
end

function DB:get(word, source)
    return self:query('SELECT * FROM words WHERE word=? AND source=?', {word, source})[1]
end

function DB:get_proverb(date)
    local row = self:query('SELECT * FROM proverbs WHERE date=?', {date})[1]
    if not row then return nil end
    return {
        text = row.text,
        chinese = row.chinese,
        explanation = row.explanation,
        audio_url = row.audio_url,
    }
end

function DB:save_proverb(p, stamp)
    stamp = stamp or os.time()
    self:query([[INSERT INTO proverbs(date, text, chinese, explanation, audio_url, created_at)
        VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(date) DO UPDATE SET
        text=excluded.text, chinese=excluded.chinese,
        explanation=excluded.explanation, audio_url=excluded.audio_url]],
        {p.date, p.text, p.chinese, p.explanation or '', p.audio_url or false, stamp})
    return self:get_proverb(p.date)
end

function DB:save(word, source, entry, stamp)
    stamp = stamp or os.time()
    -- Youdao dictionary terms forbid caching provider responses.
    if source == 'youdao' then
        entry = nil
    end
    self:query([[INSERT INTO words(word,source,entry,first_seen,last_seen,fetched_at,due_at)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(word,source) DO UPDATE SET
        lookup_count=lookup_count+1,last_seen=excluded.last_seen,
        entry=COALESCE(excluded.entry,words.entry),
        fetched_at=COALESCE(excluded.fetched_at,words.fetched_at)]],
        {word, source, entry and json.encode(entry) or false, stamp, stamp, entry and stamp or false, stamp})
    return self:get(word, source)
end

function DB:words(query, due, stamp)
    local escaped = (query or ''):gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_')
    local sql = "SELECT * FROM words WHERE word LIKE ? ESCAPE '\\'"
    local params = {'%' .. escaped .. '%'}
    if due then
        sql = sql .. ' AND due_at<=?'
        params[2] = stamp or os.time()
    end
    local rows = self:query(sql .. ' ORDER BY last_seen DESC,id DESC', params)
    for _, row in ipairs(rows) do
        if row.entry then
            row.entry = json.decode(row.entry)
        end
    end
    return rows
end

function DB:suggest(prefix, limit)
    limit = limit or 6
    if not prefix or #prefix == 0 then return {} end
    local escaped = (prefix or ''):gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_')
    local sql = "SELECT DISTINCT word, note FROM words WHERE lower(word) LIKE ? ESCAPE '\\' ORDER BY lookup_count DESC, last_seen DESC LIMIT ?"
    local rows = self:query(sql, { escaped:lower() .. '%', limit })
    local suggestions = {}
    for _, row in ipairs(rows) do
        suggestions[#suggestions + 1] = { word = row.word, snippet = row.note }
    end
    return suggestions
end

function DB:review(id, remembered, stamp)
    stamp = stamp or os.time()
    local row = self:query('SELECT streak FROM words WHERE id=?', {id})[1]
    if not row then
        return nil, 'Word not found.'
    end
    local streak = remembered and row.streak + 1 or 0
    local delay = remembered and math.min(30, 2 ^ math.min(streak - 1, 5)) * 86400 or 600
    self:query('UPDATE words SET streak=?,review_count=review_count+1,due_at=? WHERE id=?',
        {streak, stamp + delay, id})
    return {due_at = stamp + delay}
end

function DB:note(id, note)
    if not self:query('SELECT id FROM words WHERE id=?', {id})[1] then
        return nil, 'Word not found.'
    end
    self:query('UPDATE words SET note=? WHERE id=?', {note, id})
    return {saved = true}
end

function DB:delete(id)
    self:query('BEGIN IMMEDIATE;')
    local ok, result = pcall(function()
        local row = self:query('SELECT word FROM words WHERE id=?', {id})[1]
        if not row then return nil end
        self:query('DELETE FROM words WHERE id=?', {id})
        self:query('COMMIT;')
        return {deleted = true, word = row.word}
    end)
    if not ok or not result then
        self:query('ROLLBACK;')
    end
    if not ok then error(result) end
    return result, not result and 'Word not found.' or nil
end

return DB
