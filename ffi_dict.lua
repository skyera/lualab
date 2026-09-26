#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- ffi_dict.lua
-- Offline Vocabulary Trainer & Dictionary (Anki-style SM-2 spaced repetition)
-- Built with pure LuaJIT FFI and SQLite FTS5 (Zero external dependencies)
--
-- Commands:
--   add <word>      Add a word to your deck (auto-fills from imported dictionary)
--   review          Interactive flashcard review with SM-2 grading
--   quiz            Multiple-choice quiz (cloze from example sentences)
--   lookup <query>  Search the dictionary and your deck
--   stats           Learning statistics, streak and review sparkline
--   wotd            Word of the day (deterministic by date)
--   import          Import dictionary data (Wordset / Webster 1913 / CSV)
--------------------------------------------------------------------------------

local ffi = require("ffi")
local bit = require("bit")

local is_windows = (ffi.os == "Windows")

--------------------------------------------------------------------------------
-- 1. C Declarations: SQLite3 & POSIX Terminal APIs
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
    int sqlite3_bind_null(sqlite3_stmt *pStmt, int idx);
    int sqlite3_bind_text(sqlite3_stmt *pStmt, int idx, const char *val, int len, void(*destructor)(void*));

    int sqlite3_column_count(sqlite3_stmt *pStmt);
    int sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
    const char *sqlite3_column_name(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
    double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
    const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);

    int64_t sqlite3_last_insert_rowid(sqlite3 *db);
]]

if not is_windows then
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

        typedef void (*sighandler_t)(int);
        sighandler_t signal(int signum, sighandler_t handler);
        int atexit(void (*func)(void));
    ]]
end

--------------------------------------------------------------------------------
-- 2. Library Loading & Constants
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
local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_NULL    = 5
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

local SECONDS_PER_DAY = 86400

-- Ordered seed lists for guided study plans. Definitions are filled from the
-- user's imported dictionary, so plans work offline after dictionary setup.
local STUDY_TRACKS = {
    { id = "common", name = "Common English", words = {
        "ability", "accept", "achieve", "active", "actual", "advice", "affect", "allow",
        "almost", "amount", "appear", "approach", "area", "avoid", "balance", "behavior",
        "benefit", "certain", "change", "choice", "common", "community", "compare", "complete",
        "consider", "continue", "create", "decide", "develop", "difference", "discover", "effect",
        "effort", "encourage", "enough", "environment", "especially", "experience", "familiar", "famous",
        "feature", "follow", "government", "happen", "improve", "include", "interest", "knowledge",
        "language", "likely", "meaning", "necessary", "opportunity", "perhaps", "possible", "problem",
        "provide", "reason", "result", "support", "though", "understand",
    } },
    { id = "academic", name = "Academic", words = {
        "abstract", "accurate", "adapt", "adequate", "analyze", "approach", "assess", "assume",
        "authority", "available", "benefit", "concept", "consistent", "constitutional", "context", "data",
        "define", "derive", "distribute", "economy", "establish", "estimate", "evidence", "export",
        "factor", "finance", "formula", "function", "identify", "indicate", "individual", "interpret",
        "involve", "issue", "method", "occur", "percent", "period", "policy", "principle", "proceed",
        "process", "require", "research", "respond", "role", "section", "significant", "similar",
        "source", "specific", "structure", "theory", "vary",
    } },
    { id = "exam", name = "Exam Prep", words = {
        "abate", "aberrant", "abjure", "abscond", "abstain", "acumen", "admonish", "adulterate",
        "aesthetic", "aggregate", "alacrity", "alleviate", "ambiguous", "ameliorate", "amenable", "anachronism",
        "analogous", "anomaly", "antipathy", "appease", "arbitrary", "arduous", "articulate", "ascetic",
        "assiduous", "astute", "auspicious", "belligerent", "bolster", "brevity", "candid", "censure",
        "circumspect", "coherent", "complacent", "concise", "conundrum", "corroborate", "decorum", "delineate",
        "deride", "didactic", "diffident", "discern", "eclectic", "eloquent", "enigma", "ephemeral",
        "equivocal", "erudite", "exacerbate", "fastidious", "gregarious", "immutable", "lucid", "mitigate",
        "obsolete", "pragmatic", "scrutinize", "tenuous", "ubiquitous", "venerate",
    } },
}

local STUDY_TRACK_BY_ID = {}
for _, track in ipairs(STUDY_TRACKS) do STUDY_TRACK_BY_ID[track.id] = track end

--------------------------------------------------------------------------------
-- 3. Minimal JSON Decoder (for dictionary imports)
--------------------------------------------------------------------------------
local JSON = {}

do
    local utf8_char = function(cp)
        if cp < 0x80 then
            return string.char(cp)
        elseif cp < 0x800 then
            return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
        elseif cp < 0x10000 then
            return string.char(0xE0 + math.floor(cp / 0x1000),
                               0x80 + math.floor(cp / 0x40) % 0x40,
                               0x80 + cp % 0x40)
        else
            return string.char(0xF0 + math.floor(cp / 0x40000),
                               0x80 + math.floor(cp / 0x1000) % 0x40,
                               0x80 + math.floor(cp / 0x40) % 0x40,
                               0x80 + cp % 0x40)
        end
    end

    local ws = function(s, i)
        local _, j = s:find("^[ \t\r\n]*", i)
        return j + 1
    end

    local parse_string, parse_value

    parse_string = function(s, i)
        local buf = {}
        i = i + 1
        while true do
            local c = s:sub(i, i)
            if c == "" then error("JSON: unterminated string") end
            if c == '"' then
                return table.concat(buf), i + 1
            elseif c == "\\" then
                local e = s:sub(i + 1, i + 1)
                local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                              b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if map[e] then
                    buf[#buf + 1] = map[e]
                    i = i + 2
                elseif e == "u" then
                    local hex = s:sub(i + 2, i + 5)
                    if not hex:match("^%x%x%x%x$") then error("JSON: bad \\u escape") end
                    local code = tonumber(hex, 16)
                    i = i + 6
                    if code >= 0xD800 and code <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
                        local lo = tonumber(s:sub(i + 2, i + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
                            i = i + 6
                        end
                    end
                    buf[#buf + 1] = utf8_char(code)
                else
                    error("JSON: bad escape \\" .. e)
                end
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
    end

    parse_value = function(s, i)
        i = ws(s, i)
        local c = s:sub(i, i)
        if c == "{" then
            local obj = {}
            i = ws(s, i + 1)
            if s:sub(i, i) == "}" then return obj, i + 1 end
            while true do
                if s:sub(i, i) ~= '"' then error("JSON: expected string key at " .. i) end
                local k
                k, i = parse_string(s, i)
                i = ws(s, i)
                if s:sub(i, i) ~= ":" then error("JSON: expected ':' at " .. i) end
                local v
                v, i = parse_value(s, i + 1)
                obj[k] = v
                i = ws(s, i)
                local d = s:sub(i, i)
                if d == "," then
                    i = ws(s, i + 1)
                elseif d == "}" then
                    return obj, i + 1
                else
                    error("JSON: expected ',' or '}' at " .. i)
                end
            end
        elseif c == "[" then
            local arr = {}
            i = ws(s, i + 1)
            if s:sub(i, i) == "]" then return arr, i + 1 end
            while true do
                local v
                v, i = parse_value(s, i)
                arr[#arr + 1] = v
                i = ws(s, i)
                local d = s:sub(i, i)
                if d == "," then
                    i = i + 1
                elseif d == "]" then
                    return arr, i + 1
                else
                    error("JSON: expected ',' or ']' at " .. i)
                end
            end
        elseif c == '"' then
            return parse_string(s, i)
        elseif c == "t" and s:sub(i, i + 3) == "true" then
            return true, i + 4
        elseif c == "f" and s:sub(i, i + 4) == "false" then
            return false, i + 5
        elseif c == "n" and s:sub(i, i + 3) == "null" then
            return nil, i + 4
        else
            local numstr = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
            local n = tonumber(numstr)
            if not n then error("JSON: bad number at " .. i) end
            return n, i + #numstr
        end
    end

    function JSON.decode(text)
        local v = parse_value(text, 1)
        return v
    end
end

--------------------------------------------------------------------------------
-- 4. SM-2 Spaced Repetition Scheduler (pure functions)
--------------------------------------------------------------------------------
local SM2 = {}
SM2.GRADE_AGAIN = 0
SM2.GRADE_HARD  = 1
SM2.GRADE_GOOD  = 2
SM2.GRADE_EASY  = 3
SM2.MIN_EASE = 1.3
SM2.AGAIN_DELAY = 600 -- relearn after 10 minutes

function SM2.grade_name(g)
    if g == 0 then return "Again" elseif g == 1 then return "Hard"
    elseif g == 2 then return "Good" elseif g == 3 then return "Easy" end
    return "?"
end

function SM2.new_state()
    return { ease = 2.5, interval_days = 0, due_at = 0, reps = 0, lapses = 0 }
end

-- state: { ease, interval_days, due_at, reps, lapses }, grade: 0..3, now: unix seconds
function SM2.schedule(state, grade, now)
    if type(grade) ~= "number" or grade < 0 or grade > 3 or math.floor(grade) ~= grade then
        return nil, "invalid grade: " .. tostring(grade)
    end
    local s = {
        ease = state.ease,
        interval_days = state.interval_days,
        due_at = state.due_at,
        reps = state.reps,
        lapses = state.lapses,
    }
    if grade == SM2.GRADE_AGAIN then
        s.reps = 0
        s.lapses = state.lapses + 1
        s.ease = math.max(SM2.MIN_EASE, state.ease - 0.2)
        s.interval_days = 0
        s.due_at = now + SM2.AGAIN_DELAY
    elseif grade == SM2.GRADE_HARD then
        s.reps = state.reps + 1
        s.ease = math.max(SM2.MIN_EASE, state.ease - 0.15)
        s.interval_days = math.max(0.5, state.interval_days * 1.2)
        s.due_at = now + math.floor(s.interval_days * SECONDS_PER_DAY)
    elseif grade == SM2.GRADE_GOOD then
        s.reps = state.reps + 1
        if state.reps == 0 then
            s.interval_days = 1
        elseif state.reps == 1 then
            s.interval_days = 3
        else
            s.interval_days = state.interval_days * state.ease
        end
        s.due_at = now + math.floor(s.interval_days * SECONDS_PER_DAY)
    elseif grade == SM2.GRADE_EASY then
        s.reps = state.reps + 1
        s.ease = state.ease + 0.15
        if state.reps == 0 then
            s.interval_days = 2
        elseif state.reps == 1 then
            s.interval_days = 4
        else
            s.interval_days = state.interval_days * state.ease * 1.3
        end
        s.due_at = now + math.floor(s.interval_days * SECONDS_PER_DAY)
    end
    return s
end

--------------------------------------------------------------------------------
-- 5. Database Layer (SQLite FTS5)
--------------------------------------------------------------------------------
local Database = {}
Database.__index = Database

local function col_text(stmt, i)
    local p = sqlite.sqlite3_column_text(stmt, i)
    if p == nil then return nil end
    return ffi.string(p)
end

function Database.open(path)
    local self = setmetatable({}, Database)
    local db_p = ffi.new("sqlite3*[1]")
    if sqlite.sqlite3_open(path, db_p) ~= SQLITE_OK then
        return nil, "failed to open database: " .. tostring(path)
    end
    self.db = db_p[0]
    self.path = path
    self._stmts = {}
    local ok, err = self:init_schema()
    if not ok then
        sqlite.sqlite3_close(self.db)
        return nil, err
    end
    return self
end

function Database:close()
    for _, stmt in pairs(self._stmts) do
        sqlite.sqlite3_finalize(stmt)
    end
    self._stmts = {}
    if self.db then
        sqlite.sqlite3_close(self.db)
        self.db = nil
    end
end

function Database:errmsg()
    return ffi.string(sqlite.sqlite3_errmsg(self.db))
end

function Database:exec(sql)
    local err_p = ffi.new("char*[1]")
    local rc = sqlite.sqlite3_exec(self.db, sql, nil, nil, err_p)
    if rc ~= SQLITE_OK then
        local err = err_p[0] ~= nil and ffi.string(err_p[0]) or self:errmsg()
        if err_p[0] ~= nil then sqlite.sqlite3_free(err_p[0]) end
        return false, err
    end
    return true
end

function Database:_prep(sql)
    local stmt = self._stmts[sql]
    if stmt then return stmt end
    local stmt_p = ffi.new("sqlite3_stmt*[1]")
    if sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_p, nil) ~= SQLITE_OK then
        return nil
    end
    self._stmts[sql] = stmt_p[0]
    return stmt_p[0]
end

-- params is a positional array; use "" instead of nil (ipairs stops at holes)
function Database:_bind(stmt, params)
    if not params then return end
    for i, v in ipairs(params) do
        local tv = type(v)
        if tv == "number" then
            if math.floor(v) == v then
                sqlite.sqlite3_bind_int64(stmt, i, v)
            else
                sqlite.sqlite3_bind_double(stmt, i, v)
            end
        elseif tv == "boolean" then
            sqlite.sqlite3_bind_int(stmt, i, v and 1 or 0)
        else
            local sv = tostring(v)
            sqlite.sqlite3_bind_text(stmt, i, sv, #sv, SQLITE_TRANSIENT)
        end
    end
end

function Database:run(sql, params)
    local stmt = self:_prep(sql)
    if not stmt then return false, self:errmsg() end
    self:_bind(stmt, params)
    local rc = sqlite.sqlite3_step(stmt)
    sqlite.sqlite3_reset(stmt)
    if rc ~= SQLITE_DONE and rc ~= SQLITE_ROW then
        return false, self:errmsg()
    end
    return true
end

function Database:query(sql, params)
    local stmt = self:_prep(sql)
    if not stmt then return nil, self:errmsg() end
    self:_bind(stmt, params)
    local rows = {}
    while sqlite.sqlite3_step(stmt) == SQLITE_ROW do
        local row = {}
        for i = 0, sqlite.sqlite3_column_count(stmt) - 1 do
            local name = ffi.string(sqlite.sqlite3_column_name(stmt, i))
            local t = sqlite.sqlite3_column_type(stmt, i)
            if t == SQLITE_NULL then
                row[name] = nil
            elseif t == SQLITE_INTEGER then
                row[name] = tonumber(sqlite.sqlite3_column_int64(stmt, i))
            elseif t == SQLITE_FLOAT then
                row[name] = sqlite.sqlite3_column_double(stmt, i)
            else
                row[name] = col_text(stmt, i)
            end
        end
        rows[#rows + 1] = row
    end
    sqlite.sqlite3_reset(stmt)
    return rows
end

function Database:scalar(sql, params)
    local rows, err = self:query(sql, params)
    if not rows then return nil, err end
    if #rows == 0 then return nil end
    for _, v in pairs(rows[1]) do return v end
    return nil
end

function Database:init_schema()
    self:exec("PRAGMA synchronous = NORMAL;")
    self:exec("PRAGMA journal_mode = WAL;")

    local ok, err = self:exec([[
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        CREATE TABLE IF NOT EXISTS dict (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            word TEXT NOT NULL,
            pos TEXT,
            definition TEXT,
            example TEXT,
            syn TEXT,
            ant TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_dict_word ON dict(word);
        CREATE INDEX IF NOT EXISTS idx_dict_word_lower ON dict(lower(word));
        CREATE TABLE IF NOT EXISTS words (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            word TEXT UNIQUE NOT NULL,
            pos TEXT,
            definition TEXT,
            example TEXT,
            mnem TEXT,
            syn TEXT,
            ant TEXT,
            tags TEXT,
            added_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS srs (
            word_id INTEGER PRIMARY KEY,
            ease REAL NOT NULL DEFAULT 2.5,
            interval_days REAL NOT NULL DEFAULT 0,
            due_at INTEGER NOT NULL DEFAULT 0,
            reps INTEGER NOT NULL DEFAULT 0,
            lapses INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            word_id INTEGER NOT NULL,
            rated_at INTEGER NOT NULL,
            grade INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS study_plan (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            track TEXT NOT NULL,
            daily_new INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS study_plan_words (
            word_id INTEGER PRIMARY KEY,
            source_track TEXT NOT NULL,
            plan_date TEXT NOT NULL,
            FOREIGN KEY (word_id) REFERENCES words(id)
        );
        CREATE INDEX IF NOT EXISTS idx_study_plan_words_date ON study_plan_words(plan_date);
        CREATE INDEX IF NOT EXISTS idx_reviews_time ON reviews(rated_at);
    ]])
    if not ok then return false, "schema error: " .. tostring(err) end

    local ok_fts, err_fts = self:exec([[
        CREATE VIRTUAL TABLE IF NOT EXISTS dict_fts USING fts5(
            word, definition, example, syn,
            tokenize = "unicode61"
        );
    ]])
    if not ok_fts then
        local ok_fb, err_fb = self:exec([[
            CREATE VIRTUAL TABLE IF NOT EXISTS dict_fts USING fts5(word, definition, example, syn);
        ]])
        if not ok_fb then return false, "fts5 error: " .. tostring(err_fb) end
    end
    return true
end

function Database:begin() return self:exec("BEGIN TRANSACTION;") end
function Database:commit() return self:exec("COMMIT;") end
function Database:rollback() return self:exec("ROLLBACK;") end

--------------------------------------------------------------------------------
-- 5a. Dictionary (imported reference) operations
--------------------------------------------------------------------------------

-- Remove any existing senses for this word, then insert the given senses.
-- senses: array of { pos=, definition=, example=, syn=, ant= }
function Database:dict_replace_word(word, senses, defer_fts)
    self:run([[
        DELETE FROM dict_fts
        WHERE rowid IN (SELECT id FROM dict WHERE lower(word) = lower(?));]], { word })
    self:run("DELETE FROM dict WHERE lower(word) = lower(?);", { word })
    local inserted = 0
    for _, s in ipairs(senses) do
        local ok = self:run(
            "INSERT INTO dict (word, pos, definition, example, syn, ant) VALUES (?, ?, ?, ?, ?, ?);",
            { word, s.pos or "", s.definition or "", s.example or "", s.syn or "", s.ant or "" })
        if ok then
            if not defer_fts then
                local id = self:scalar("SELECT last_insert_rowid();")
                self:run("INSERT INTO dict_fts (rowid, word, definition, example, syn) VALUES (?, ?, ?, ?, ?);",
                    { id, word, s.definition or "", s.example or "", s.syn or "" })
            end
            inserted = inserted + 1
        end
    end
    return inserted
end

function Database:dict_lookup(word)
    local rows, err = self:query(
        "SELECT word, pos, definition, example, syn, ant FROM dict WHERE lower(word) = lower(?) ORDER BY id;",
        { word })
    return rows or {}, err
end

local function fts_match_string(q)
    local tokens = {}
    for t in q:gmatch("[%w_]+") do
        tokens[#tokens + 1] = '"' .. t .. '"*'
    end
    if #tokens == 0 then return nil end
    return table.concat(tokens, " ")
end

function Database:dict_search(q, limit)
    limit = limit or 10
    local match = fts_match_string(q)
    if match then
        local rows = self:query([[
            SELECT d.id, d.word, d.pos, d.definition, d.example, d.syn, d.ant
            FROM dict_fts JOIN dict d ON d.id = dict_fts.rowid
            WHERE dict_fts MATCH ?
            ORDER BY rank LIMIT ?;]], { match, limit })
        if rows and #rows > 0 then return rows end
    end
    return self:query([[
        SELECT id, word, pos, definition, example, syn, ant FROM dict
        WHERE lower(word) LIKE lower(?) LIMIT ?;]], { "%" .. q .. "%", limit }) or {}
end

--------------------------------------------------------------------------------
-- 5b. Deck (learning words) operations
--------------------------------------------------------------------------------

-- f: { word=, pos=, definition=, example=, mnem=, syn=, ant=, tags= }
-- Missing fields are auto-filled from the imported dictionary.
function Database:deck_add(f, now)
    now = now or os.time()
    local word = f.word and f.word:match("^%s*(.-)%s*$") or ""
    if #word == 0 then return nil, "word required" end

    local dup = self:query("SELECT word FROM words WHERE lower(word) = lower(?)", { word })
    if dup and #dup > 0 then
        return nil, string.format("'%s' is already in your deck", word)
    end

    if not f.definition or #f.definition == 0 then
        local senses = self:dict_lookup(word)
        if #senses == 0 then
            return nil, string.format("'%s' not found in the imported dictionary — provide --def", word)
        end
        local defs, syns, ants = {}, {}, {}
        for i, s in ipairs(senses) do
            defs[#defs + 1] = string.format("%d. %s", i, s.definition or "")
            if not f.pos and s.pos and #s.pos > 0 then f.pos = s.pos end
            if not f.example and s.example and #s.example > 0 then f.example = s.example end
            if s.syn and #s.syn > 0 then syns[#syns + 1] = s.syn end
            if s.ant and #s.ant > 0 then ants[#ants + 1] = s.ant end
        end
        f.definition = table.concat(defs, "  ")
        if not f.syn and #syns > 0 then f.syn = table.concat(syns, ", ") end
        if not f.ant and #ants > 0 then f.ant = table.concat(ants, ", ") end
    end

    local ok, err = self:run([[
        INSERT INTO words (word, pos, definition, example, mnem, syn, ant, tags, added_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);]],
        { word, f.pos or "", f.definition or "", f.example or "", f.mnem or "",
          f.syn or "", f.ant or "", f.tags or "", now })
    if not ok then return nil, err end

    local id = self:scalar("SELECT last_insert_rowid();")
    local st = SM2.new_state()
    st.due_at = now
    self:run([[
        INSERT INTO srs (word_id, ease, interval_days, due_at, reps, lapses)
        VALUES (?, ?, ?, ?, ?, ?);]],
        { id, st.ease, st.interval_days, st.due_at, st.reps, st.lapses })
    return id
end

function Database:deck_get(word)
    local rows = self:query([[
        SELECT w.id, w.word, w.pos, w.definition, w.example, w.mnem, w.syn, w.ant, w.tags,
               s.ease, s.interval_days, s.due_at, s.reps, s.lapses
        FROM words w JOIN srs s ON s.word_id = w.id
        WHERE lower(w.word) = lower(?);]], { word })
    return rows and rows[1] or nil
end

function Database:get_due(now, limit)
    limit = limit or 20
    return self:query([[
        SELECT w.id, w.word, w.pos, w.definition, w.example, w.mnem, w.syn, w.ant, w.tags,
               s.ease, s.interval_days, s.due_at, s.reps, s.lapses
        FROM words w JOIN srs s ON s.word_id = w.id
        WHERE s.due_at <= ?
        ORDER BY s.due_at ASC, w.id ASC LIMIT ?;]], { now, limit }) or {}
end

function Database:deck_sample(limit)
    limit = limit or 20
    return self:query([[
        SELECT w.id, w.word, w.pos, w.definition, w.example, w.mnem, w.syn, w.ant, w.tags,
               s.ease, s.interval_days, s.due_at, s.reps, s.lapses
        FROM words w JOIN srs s ON s.word_id = w.id
        ORDER BY w.id ASC LIMIT ?;]], { limit }) or {}
end

function Database:study_plan_get()
    local rows = self:query("SELECT track, daily_new AS batch_size, updated_at FROM study_plan WHERE id = 1;")
    return rows and rows[1] or nil
end

function Database:study_plan_set(track, batch_size, now)
    if track ~= "mixed" and not STUDY_TRACK_BY_ID[track] then
        return false, "unknown study track: " .. tostring(track)
    end
    if type(batch_size) ~= "number" or batch_size < 1 or batch_size > 50 or math.floor(batch_size) ~= batch_size then
        return false, "new-word batch size must be an integer from 1 to 50"
    end
    -- Keep the existing column name so existing user databases need no migration.
    return self:run([[
        INSERT OR REPLACE INTO study_plan (id, track, daily_new, updated_at)
        VALUES (1, ?, ?, ?);]], { track, batch_size, now or os.time() })
end

function Database:study_plan_today_count(date)
    return self:scalar("SELECT COUNT(*) FROM study_plan_words WHERE plan_date = ?;",
        { date or os.date("%Y-%m-%d") }) or 0
end

local function study_track_performance(db, track_id)
    local rows = db:query([[
        SELECT COUNT(*) AS n, AVG(CASE WHEN r.grade > 0 THEN 1.0 ELSE 0.0 END) AS success
        FROM study_plan_words p JOIN reviews r ON r.word_id = p.word_id
        WHERE p.source_track = ?;]], { track_id }) or {}
    local row = rows[1] or {}
    return row.n and row.n > 0 and row.success or 0.75
end

function Database:study_plan_candidates(track_id, limit)
    limit = limit or 10
    if limit <= 0 then return {} end
    local tracks = {}
    if track_id == "mixed" then
        for _, track in ipairs(STUDY_TRACKS) do
            local performance = study_track_performance(self, track.id)
            tracks[#tracks + 1] = {
                track = track, words = {}, cursor = 1,
                performance = performance,
                weight = 0.5 + (1 - performance) * 2,
                current_weight = 0,
            }
        end
    else
        local track = STUDY_TRACK_BY_ID[track_id]
        if not track then return nil, "unknown study track: " .. tostring(track_id) end
        tracks[1] = { track = track, words = {}, cursor = 1, weight = 1, current_weight = 0 }
    end

    local deck_rows = self:query("SELECT lower(word) AS word FROM words;") or {}
    local in_deck, track_word_set, track_words = {}, {}, {}
    for _, row in ipairs(deck_rows) do in_deck[row.word] = true end
    for _, track in ipairs(STUDY_TRACKS) do
        for _, word in ipairs(track.words) do
            local key = word:lower()
            if not track_word_set[key] then
                track_word_set[key] = true
                track_words[#track_words + 1] = key
            end
        end
    end

    for _, state in ipairs(tracks) do
        for _, word in ipairs(state.track.words) do
            local key = word:lower()
            if not in_deck[key] then
                local senses = self:dict_lookup(word)
                if #senses > 0 then
                    state.words[#state.words + 1] = {
                        word = word, pos = senses[1].pos, definition = senses[1].definition,
                        example = senses[1].example, source_track = state.track.id,
                    }
                    in_deck[key] = true -- avoid duplicates across mixed tracks
                end
            end
        end
    end

    local candidates = {}
    while #candidates < limit do
        local total_weight, chosen = 0, nil
        for _, state in ipairs(tracks) do
            if state.words[state.cursor] then
                total_weight = total_weight + state.weight
                state.current_weight = state.current_weight + state.weight
                if not chosen or state.current_weight > chosen.current_weight then
                    chosen = state
                end
            end
        end
        if not chosen then break end
        chosen.current_weight = chosen.current_weight - total_weight
        candidates[#candidates + 1] = chosen.words[chosen.cursor]
        chosen.cursor = chosen.cursor + 1
    end

    -- Fill any gap with unused dictionary entries so a plan can still work
    -- when its curated vocabulary does not overlap the imported data.
    local remaining = limit - #candidates
    if remaining > 0 then
        local placeholders, params = {}, {}
        for _, word in ipairs(track_words) do
            placeholders[#placeholders + 1] = "?"
            params[#params + 1] = word
        end
        local exclude_tracks = ""
        if #placeholders > 0 then
            exclude_tracks = " AND lower(d.word) NOT IN (" .. table.concat(placeholders, ", ") .. ")"
        end
        params[#params + 1] = remaining
        local general = self:query([[
            SELECT d.word, d.pos, d.definition, d.example
            FROM dict d
            WHERE d.id = (
                SELECT MIN(d2.id) FROM dict d2
                WHERE lower(d2.word) = lower(d.word)
                  AND length(trim(coalesce(d2.definition, ''))) > 0
            )
            AND NOT EXISTS (SELECT 1 FROM words w WHERE lower(w.word) = lower(d.word))]] ..
            exclude_tracks .. " ORDER BY lower(d.word), d.id LIMIT ?;", params) or {}
        for _, row in ipairs(general) do
            candidates[#candidates + 1] = {
                word = row.word, pos = row.pos, definition = row.definition,
                example = row.example, source_track = "general",
            }
        end
    end
    return candidates
end

function Database:study_plan_start_today(now, selected_words)
    now = now or os.time()
    local plan = self:study_plan_get()
    if not plan then return nil, "no study plan selected" end
    local today = os.date("%Y-%m-%d", now)

    -- The saved target is a per-session batch size, not a daily quota.
    local candidates, candidate_err = self:study_plan_candidates(plan.track, plan.batch_size)
    if not candidates then return nil, candidate_err end
    if #candidates == 0 then return {}, "no unused words remain in the imported dictionary" end
    if selected_words then
        local selected = {}
        for word, value in pairs(selected_words) do
            if value then selected[tostring(word):lower()] = true end
        end
        local chosen = {}
        for _, candidate in ipairs(candidates) do
            if selected[candidate.word:lower()] then chosen[#chosen + 1] = candidate end
        end
        candidates = chosen
        if #candidates == 0 then return {}, "no words selected" end
    end

    local begun, begin_err = self:begin()
    if not begun then return nil, begin_err end
    local added = {}
    for _, candidate in ipairs(candidates) do
        local id, add_err = self:deck_add({ word = candidate.word }, now)
        if not id then
            self:rollback()
            return nil, add_err
        end
        local ok, map_err = self:run([[
            INSERT INTO study_plan_words (word_id, source_track, plan_date) VALUES (?, ?, ?);]],
            { id, candidate.source_track, today })
        if not ok then
            self:rollback()
            return nil, map_err
        end
        candidate.id = id
        added[#added + 1] = candidate
    end
    local committed, commit_err = self:commit()
    if not committed then
        self:rollback()
        return nil, commit_err
    end
    return added
end

function Database:srs_state(word_id)
    local rows = self:query(
        "SELECT ease, interval_days, due_at, reps, lapses FROM srs WHERE word_id = ?;", { word_id })
    return rows and rows[1] or nil
end

-- Apply an SM-2 grade to a deck word and log the review. Returns the new state.
function Database:srs_apply(word_id, grade, now)
    now = now or os.time()
    local st = self:srs_state(word_id)
    if not st then return nil, "no srs state for word_id " .. tostring(word_id) end
    local ns, err = SM2.schedule(st, grade, now)
    if not ns then return nil, err end
    local ok, uerr = self:run([[
        UPDATE srs SET ease = ?, interval_days = ?, due_at = ?, reps = ?, lapses = ?
        WHERE word_id = ?;]],
        { ns.ease, ns.interval_days, ns.due_at, ns.reps, ns.lapses, word_id })
    if not ok then return nil, uerr end
    self:run("INSERT INTO reviews (word_id, rated_at, grade) VALUES (?, ?, ?);",
        { word_id, now, grade })
    return ns
end

--------------------------------------------------------------------------------
-- 5c. Statistics & word of the day
--------------------------------------------------------------------------------
local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function sparkline(counts)
    local max = 0
    for _, c in ipairs(counts) do if c > max then max = c end end
    if max == 0 then return string.rep("▁", #counts) end
    local out = {}
    for i, c in ipairs(counts) do
        if c == 0 then
            out[i] = "▁"
        else
            local lvl = math.max(1, math.min(8, math.ceil(c / max * 8)))
            out[i] = SPARK[lvl]
        end
    end
    return table.concat(out)
end

function Database:review_day_counts(now, days)
    now = now or os.time()
    days = days or 14
    local counts, dates = {}, {}
    for i = days - 1, 1, -1 do
        dates[#dates + 1] = os.date("%Y-%m-%d", now - i * SECONDS_PER_DAY)
    end
    dates[#dates + 1] = os.date("%Y-%m-%d", now) -- last slot is today (total = days)
    local rows = self:query([[
        SELECT date(rated_at, 'unixepoch', 'localtime') AS d, COUNT(*) AS n
        FROM reviews GROUP BY d;]]) or {}
    local by_day = {}
    for _, r in ipairs(rows) do by_day[r.d] = r.n end
    for _, d in ipairs(dates) do counts[#counts + 1] = by_day[d] or 0 end
    return counts
end

function Database:streak(now)
    now = now or os.time()
    local rows = self:query([[
        SELECT DISTINCT date(rated_at, 'unixepoch', 'localtime') AS d
        FROM reviews ORDER BY d DESC LIMIT 400;]]) or {}
    local seen = {}
    for _, r in ipairs(rows) do seen[r.d] = true end
    local streak = 0
    local today = os.date("%Y-%m-%d", now)
    local cursor = today
    if not seen[cursor] then
        cursor = os.date("%Y-%m-%d", now - SECONDS_PER_DAY)
        if not seen[cursor] then return 0 end
    end
    while seen[cursor] do
        streak = streak + 1
        local y, m, d = cursor:match("^(%d+)-(%d+)-(%d+)$")
        cursor = os.date("%Y-%m-%d", os.time({ year = y, month = m, day = d, hour = 12 }) - SECONDS_PER_DAY)
    end
    return streak
end

function Database:stats(now)
    now = now or os.time()
    local total = self:scalar("SELECT COUNT(*) FROM words;") or 0
    local learned = self:scalar(
        "SELECT COUNT(*) FROM words w JOIN srs s ON s.word_id = w.id WHERE s.interval_days >= 21;") or 0
    local learning = self:scalar([[
        SELECT COUNT(*) FROM words w JOIN srs s ON s.word_id = w.id
        WHERE s.interval_days < 21 AND (s.reps > 0 OR s.lapses > 0);]]) or 0
    local due = self:scalar("SELECT COUNT(*) FROM srs WHERE due_at <= ?;", { now }) or 0
    local n_reviews = self:scalar("SELECT COUNT(*) FROM reviews;") or 0
    local n_correct = self:scalar("SELECT COUNT(*) FROM reviews WHERE grade > 0;") or 0
    local avg_grade = self:scalar("SELECT AVG(grade) FROM reviews;")
    local dict_senses = self:scalar("SELECT COUNT(*) FROM dict;") or 0
    local dict_words = self:scalar("SELECT COUNT(DISTINCT word) FROM dict;") or 0
    return {
        total = total,
        learned = learned,
        learning = learning,
        new = total - learned - learning,
        due = due,
        reviews = n_reviews,
        correct = n_correct,
        retention = n_reviews > 0 and (n_correct / n_reviews * 100) or 0,
        avg_grade = avg_grade or 0,
        streak = self:streak(now),
        day_counts = self:review_day_counts(now, 14),
        dict_senses = dict_senses,
        dict_words = dict_words,
    }
end

-- Deterministic word of the day (same word for the whole UTC day)
function Database:wotd(now)
    now = now or os.time()
    local day = math.floor(now / SECONDS_PER_DAY)
    local n = self:scalar("SELECT COUNT(*) FROM words;") or 0
    if n > 0 then
        local rows = self:query([[
            SELECT w.id, w.word, w.pos, w.definition, w.example, w.mnem, w.syn, w.ant, w.tags,
                   s.ease, s.interval_days, s.due_at, s.reps, s.lapses
            FROM words w JOIN srs s ON s.word_id = w.id
            ORDER BY w.id ASC LIMIT 1 OFFSET ?;]], { day % n })
        return rows and rows[1] or nil, "deck"
    end
    local m = self:scalar("SELECT COUNT(*) FROM dict;") or 0
    if m > 0 then
        local rows = self:query(
            "SELECT word, pos, definition, example, syn, ant FROM dict ORDER BY id LIMIT 1 OFFSET ?;",
            { day % m })
        return rows and rows[1] or nil, "dict"
    end
    return nil
end

--------------------------------------------------------------------------------
-- 6. Dictionary Importers (Wordset / Webster 1913 / CSV)
--------------------------------------------------------------------------------
local Importer = {}

local function join_list(v)
    if type(v) == "table" then return table.concat(v, ", ") end
    return v and tostring(v) or ""
end

local function normalize_meaning(m)
    if type(m) == "string" then
        return { definition = m }
    end
    if type(m) ~= "table" then return nil end
    return {
        pos = m.speech_part or m.pos or "",
        definition = m.def or m.definition or m.text or "",
        example = m.example or "",
        syn = join_list(m.synonyms),
        ant = join_list(m.antonyms),
    }
end

-- Wordset format: { ["word"] = { word=..., meanings = { {def=..., speech_part=..., example=..., synonyms={...}}, ... } } }
function Importer.ingest_wordset(db, obj, defer_fts)
    local words, senses = 0, 0
    for w, entry in pairs(obj) do
        local meanings = type(entry) == "table" and (entry.meanings or entry) or nil
        local list = {}
        if type(meanings) == "table" then
            for _, m in ipairs(meanings) do
                local nm = normalize_meaning(m)
                if nm and nm.definition and #nm.definition > 0 then
                    list[#list + 1] = nm
                end
            end
        end
        if #list > 0 then
            senses = senses + db:dict_replace_word(entry.word or w, list, defer_fts)
            words = words + 1
        end
    end
    return words, senses
end

-- Webster 1913 format: { ["word"] = { "definition 1", "definition 2", ... } }
function Importer.ingest_webster(db, obj, defer_fts)
    local words, senses = 0, 0
    for w, entry in pairs(obj) do
        local list = {}
        if type(entry) == "string" then
            list[1] = { definition = entry }
        elseif type(entry) == "table" then
            for _, m in ipairs(entry) do
                local nm = normalize_meaning(m)
                if nm and nm.definition and #nm.definition > 0 then
                    list[#list + 1] = nm
                end
            end
        end
        if #list > 0 then
            senses = senses + db:dict_replace_word(w, list, defer_fts)
            words = words + 1
        end
    end
    return words, senses
end

-- CSV format: word,pos,definition,example,syn,ant  (header row optional)
function Importer.parse_csv_line(line)
    local fields, cur, in_q = {}, {}, false
    local i = 1
    while i <= #line do
        local c = line:sub(i, i)
        if in_q then
            if c == '"' then
                if line:sub(i + 1, i + 1) == '"' then
                    cur[#cur + 1] = '"'
                    i = i + 1
                else
                    in_q = false
                end
            else
                cur[#cur + 1] = c
            end
        elseif c == '"' then
            in_q = true
        elseif c == "," then
            fields[#fields + 1] = table.concat(cur)
            cur = {}
        else
            cur[#cur + 1] = c
        end
        i = i + 1
    end
    fields[#fields + 1] = table.concat(cur)
    return fields
end

function Importer.ingest_csv(db, text, defer_fts)
    local words, senses = 0, 0
    local by_word = {}
    for line in text:gmatch("[^\r\n]+") do
        local f = Importer.parse_csv_line(line)
        local w = (f[1] or ""):match("^%s*(.-)%s*$")
        if #w > 0 and w:lower() ~= "word" then
            local s = {
                pos = f[2] or "",
                definition = f[3] or "",
                example = f[4] or "",
                syn = f[5] or "",
                ant = f[6] or "",
            }
            if s.definition and #s.definition > 0 then
                by_word[w] = by_word[w] or {}
                table.insert(by_word[w], s)
            end
        end
    end
    for w, list in pairs(by_word) do
        senses = senses + db:dict_replace_word(w, list, defer_fts)
        words = words + 1
    end
    return words, senses
end

local function index_imported_rows(db, after_id)
    return db:run([[
        INSERT INTO dict_fts (rowid, word, definition, example, syn)
        SELECT id, word, definition, example, syn FROM dict WHERE id > ?;
    ]], { after_id })
end

local function collect_files(path, ext, depth, out)
    depth = depth or 0
    out = out or {}
    if is_windows then
        local p = io.popen('dir /b /a-d "' .. path .. '" 2>nul')
        if not p then return out end
        for name in p:lines() do
            if name:lower():match(ext) then
                out[#out + 1] = path .. "\\" .. name
            end
        end
        p:close()
        return out
    end
    local dir = ffi.C.opendir(path)
    if dir == nil then
        out[#out + 1] = path -- not a directory: treat as file
        return out
    end
    local names = {}
    while true do
        local ent = ffi.C.readdir(dir)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    ffi.C.closedir(dir)
    table.sort(names)
    for _, name in ipairs(names) do
        local full = path .. "/" .. name
        if name:lower():match(ext) then
            out[#out + 1] = full
        elseif depth < 2 then
            local sub = ffi.C.opendir(full)
            if sub ~= nil then
                ffi.C.closedir(sub)
                collect_files(full, ext, depth + 1, out)
            end
        end
    end
    return out
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- fmt: "wordset" | "webster" | "csv"; path: file or directory
-- on_progress(event) is optional and receives scan/start/done/skip events.
function Importer.import_path(db, fmt, path, on_progress)
    local ext = (fmt == "csv") and "%.csv$" or "%.json$"
    local files = collect_files(path, ext, 0, {})
    local total_words, total_senses = 0, 0
    local import_started = os.time()

    local function ingest_transaction(ingest, input)
        local begun, begin_err = db:begin()
        if not begun then return nil, nil, "could not begin transaction: " .. tostring(begin_err) end

        local after_id, query_err = db:scalar("SELECT COALESCE(MAX(id), 0) FROM dict;")
        if after_id == nil then
            db:rollback()
            return nil, nil, "could not read existing dictionary ids: " .. tostring(query_err)
        end

        local ok, words, senses = pcall(ingest, db, input, true)
        if not ok then
            db:rollback()
            return nil, nil, "dictionary import error: " .. tostring(words)
        end

        local indexed, index_err = index_imported_rows(db, after_id)
        if not indexed then
            db:rollback()
            return nil, nil, "could not update full-text index: " .. tostring(index_err)
        end

        local committed, commit_err = db:commit()
        if not committed then
            db:rollback()
            return nil, nil, "could not commit transaction: " .. tostring(commit_err)
        end
        return words, senses
    end
    local function report(event)
        if on_progress then on_progress(event) end
    end
    report({ type = "scan", path = path, files = #files })

    for i, file in ipairs(files) do
        local started = os.clock()
        report({ type = "start", file = file, index = i, total = #files })
        local data = read_file(file)
        local file_words, file_senses = 0, 0
        local status, message = "done", nil
        if not data then
            status, message = "skip", "could not read file"
        elseif #data == 0 then
            status, message = "skip", "file is empty"
        elseif fmt == "csv" then
            local w, s, err = ingest_transaction(Importer.ingest_csv, data)
            if err then
                status, message = "skip", err
            else
                file_words, file_senses = w, s
            end
        else
            local decoded, obj = pcall(JSON.decode, data)
            if not decoded then
                status, message = "skip", "JSON error: " .. tostring(obj)
            elseif type(obj) ~= "table" then
                status, message = "skip", "JSON root must be an object or array"
            else
                local ingest = fmt == "webster" and Importer.ingest_webster or Importer.ingest_wordset
                local w, s, err = ingest_transaction(ingest, obj)
                if err then
                    status, message = "skip", err
                else
                    file_words, file_senses = w, s
                end
            end
        end
        total_words = total_words + file_words
        total_senses = total_senses + file_senses
        local elapsed_seconds = os.time() - import_started
        local remaining_files = #files - i
        local eta_seconds = i > 0 and math.ceil(elapsed_seconds / i * remaining_files) or 0
        report({
            type = status, file = file, index = i, total = #files,
            words = file_words, senses = file_senses,
            total_words = total_words, total_senses = total_senses,
            cpu_seconds = os.clock() - started,
            elapsed_seconds = elapsed_seconds, eta_seconds = eta_seconds,
            message = message,
        })
    end
    return total_words, total_senses, #files
end


--------------------------------------------------------------------------------
-- 7. Quiz Builder (pure functions)
--------------------------------------------------------------------------------
local Quiz = {}

local function lower_index_map(text)
    -- case-insensitive plain search helper on a lowered copy
    return text:lower()
end

-- Replace whole-word occurrences of `word` in `text` with "____" (case-insensitive)
function Quiz.mask_example(text, word)
    if not text or not word or #word == 0 then return text, 0 end
    local lw = word:lower()
    local out, count, pos = {}, 0, 1
    local ltext = lower_index_map(text)
    while true do
        local s, e = ltext:find(lw, pos, true)
        if not s then break end
        local before = s > 1 and ltext:sub(s - 1, s - 1) or ""
        local after = ltext:sub(e + 1, e + 1)
        local word_char = "[%w_]"
        if (before == "" or not before:match(word_char)) and (after == "" or not after:match(word_char)) then
            out[#out + 1] = text:sub(pos, s - 1)
            out[#out + 1] = "____"
            count = count + 1
            pos = e + 1
        else
            out[#out + 1] = text:sub(pos, e)
            pos = e + 1
        end
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out), count
end

-- Deterministic RNG (LCG) — same seed always yields the same quiz
function Quiz.lcg_rng(seed)
    local s = (seed or 1) % 2147483648
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        return (s % n) + 1
    end
end

-- entry: { word=, pos=, definition=, example= }; pool: array of other word strings
-- rng(n) -> integer in [1..n]; returns question table or nil, err
function Quiz.build(entry, pool, rng)
    rng = rng or function(n) return math.random(n) end
    if not entry or not entry.word then return nil, "entry required" end
    local candidates = {}
    for _, w in ipairs(pool or {}) do
        if w ~= entry.word then candidates[#candidates + 1] = w end
    end
    if #candidates < 3 then return nil, "not enough distractor words" end

    -- Fisher-Yates pick 3 distinct distractors
    local picked = {}
    for i = 1, 3 do
        local j = rng(#candidates)
        picked[#picked + 1] = table.remove(candidates, j)
    end

    local prompt, kind
    local masked, n = Quiz.mask_example(entry.example, entry.word)
    if entry.example and n > 0 then
        prompt, kind = masked, "cloze"
    elseif entry.definition and #entry.definition > 0 then
        prompt, kind = "Which word means: " .. entry.definition, "meaning"
    else
        prompt, kind = "Which word is defined as: (no definition)", "meaning"
    end

    local choices = { entry.word, picked[1], picked[2], picked[3] }
    -- shuffle the 4 choices
    for i = 4, 2, -1 do
        local j = rng(i)
        choices[i], choices[j] = choices[j], choices[i]
    end
    local answer_idx = 1
    for i, w in ipairs(choices) do
        if w == entry.word then answer_idx = i break end
    end

    return {
        prompt = prompt,
        kind = kind,
        choices = choices,
        answer_idx = answer_idx,
        word = entry.word,
    }
end

function Quiz.check(q, idx)
    return idx == q.answer_idx
end

--------------------------------------------------------------------------------
-- 8. Terminal UI (raw mode, differential frame rendering)
--------------------------------------------------------------------------------
local Term = {}

local function make_theme(plain, ascii)
    local t = {
        plain = plain,
        ascii = ascii or false,
        box = ascii and { "+", "-", "+", "|", "+", "+", "+", "+", "+", "+", "+" }
             or { "┌", "─", "┐", "│", "└", "┘", "├", "┤", "┬", "┴", "┼" },
    }
    function t.c(code, s)
        if plain then return s end
        return "\27[" .. code .. "m" .. s .. "\27[0m"
    end
    return t
end

local function strip_ansi(s)
    return (s:gsub("\27%[[%d;]*[mK]", ""))
end

local function vlen(s)
    local clean = strip_ansi(s)
    local w = 0
    for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        w = w + 1
    end
    return w
end

local function fit(s, width)
    if vlen(s) <= width then return s end
    -- naive truncation by UTF-8 chars (preserve ANSI by cutting trailing codes)
    local out, w = {}, 0
    local i = 1
    while i <= #s do
        local esc = s:match("^\27%[[%d;]*[mK]", i)
        if esc then
            out[#out + 1] = esc
            i = i + #esc
        else
            local c = s:match("^[%z\1-\127\194-\244][\128-\191]*", i)
            if not c then break end
            if w >= width then break end
            out[#out + 1] = c
            w = w + 1
            i = i + #c
        end
    end
    return table.concat(out) .. "\27[0m"
end

local function center(s, width)
    local pad = width - vlen(s)
    if pad <= 0 then return fit(s, width) end
    local left = math.floor(pad / 2)
    return string.rep(" ", left) .. fit(s, width - left)
end

-- Frame buffer with per-row differential updates (AGENTS.md TUI standards)
local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(cols, rows, plain)
    return setmetatable({ cols = cols, rows = rows, cur = {}, prev = {}, plain = plain }, Renderer)
end

function Renderer:begin()
    self.cur = {}
end

function Renderer:set(y, text)
    if y < 1 or y > self.rows then return end
    self.cur[y] = fit(text, self.cols - 1) -- clamp to raw_cols - 1 (prevents wrap shift)
end

function Renderer:force_full()
    self.prev = {}
end

function Renderer:flush()
    local parts = {}
    for y = 1, self.rows do
        local line = self.cur[y] or ""
        if self.prev[y] ~= line then
            parts[#parts + 1] = string.format("\27[%d;1H\27[2K%s", y, line)
        end
    end
    if #parts > 0 then
        -- Atomic synchronized frame emission: single io.write, no piecemeal output
        io.write("\27[?2026h" .. table.concat(parts) .. "\27[?2026l")
        io.flush()
        self.prev = {}
        for y = 1, self.rows do self.prev[y] = self.cur[y] or "" end
    end
end

Term.strip_ansi = strip_ansi
Term.vlen = vlen
Term.fit = fit
Term.center = center
Term.make_theme = make_theme

function Term.size()
    if not is_windows then
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(1, 0x5413, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
    end
    return 80, 24
end

function Term.is_tty()
    if is_windows then return false end
    return ffi.C.isatty(0) == 1 and ffi.C.isatty(1) == 1
end

-- Raw-mode handling: ISIG is disabled so Ctrl-C arrives as byte 3 and follows
-- the graceful quit path; restoration is guaranteed via protected exit paths.
local raw_state = { active = false, orig = nil }

function Term.enable_raw()
    if is_windows then return false end
    if raw_state.active then return true end
    local orig = ffi.new("struct termios")
    if ffi.C.tcgetattr(0, orig) ~= 0 then return false end
    local raw = ffi.new("struct termios")
    ffi.copy(raw, orig, ffi.sizeof("struct termios"))
    -- Disable ICANON (0x0002), ECHO (0x0008), ISIG (0x0001)
    raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(0x0002, 0x0008, 0x0001)))
    if ffi.C.tcsetattr(0, 0, raw) ~= 0 then return false end
    raw_state.orig = orig
    raw_state.active = true
    -- Alternate screen, hide cursor, disable auto-wrap, clear once
    io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
    io.flush()
    return true
end

function Term.disable_raw()
    if not raw_state.active then return end
    io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
    io.flush()
    if raw_state.orig then
        ffi.C.tcsetattr(0, 0, raw_state.orig)
    end
    raw_state.active = false
end

local key_queue = {}

function Term.read_key(timeout_ms)
    if #key_queue > 0 then return table.remove(key_queue, 1) end
    if is_windows then return nil end
    timeout_ms = timeout_ms or 100
    local pfd = ffi.new("struct pollfd", { fd = 0, events = 1, revents = 0 })
    local buf = ffi.new("char[128]")
    local ret = ffi.C.poll(pfd, 1, timeout_ms)
    if ret > 0 and bit.band(pfd.revents, 1) ~= 0 then
        local n = ffi.C.read(0, buf, 128)
        if n > 0 then
            local idx = 0
            while idx < n do
                local c0 = buf[idx]
                if c0 == 27 and idx + 2 < n and buf[idx + 1] == 91 then
                    local c2 = buf[idx + 2]
                    if c2 == 65 then key_queue[#key_queue + 1] = "UP"
                    elseif c2 == 66 then key_queue[#key_queue + 1] = "DOWN"
                    elseif c2 == 67 then key_queue[#key_queue + 1] = "RIGHT"
                    elseif c2 == 68 then key_queue[#key_queue + 1] = "LEFT"
                    elseif c2 == 53 and idx + 3 < n and buf[idx + 3] == 126 then key_queue[#key_queue + 1] = "PAGE_UP"
                    elseif c2 == 54 and idx + 3 < n and buf[idx + 3] == 126 then key_queue[#key_queue + 1] = "PAGE_DOWN"
                    else key_queue[#key_queue + 1] = "ESC" end
                    idx = idx + 3
                elseif c0 == 27 then
                    key_queue[#key_queue + 1] = "ESC"
                    idx = idx + 1
                elseif c0 == 13 or c0 == 10 then
                    key_queue[#key_queue + 1] = "ENTER"
                    idx = idx + 1
                elseif c0 == 3 then
                    key_queue[#key_queue + 1] = "CTRL_C"
                    idx = idx + 1
                elseif c0 == 32 then
                    key_queue[#key_queue + 1] = " "
                    idx = idx + 1
                elseif c0 >= 32 and c0 < 127 then
                    key_queue[#key_queue + 1] = string.char(c0)
                    idx = idx + 1
                else
                    idx = idx + 1
                end
            end
            return table.remove(key_queue, 1)
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- 9. Frame Layouts (shared between TUI and --snapshot)
--------------------------------------------------------------------------------
local UI = {}

local function hline(theme, left, mid, right, w)
    return left .. string.rep(theme.box[2], w) .. right
end

local function framed_row(theme, content, width, color)
    local body = content
    if color then body = theme.c(color, content) end
    return theme.box[4] .. " " .. fit(body, width - 2) .. string.rep(" ", math.max(0, width - 2 - vlen(fit(body, width - 2)))) .. " " .. theme.box[4]
end

local function pad_row(theme, text, width, color)
    local body = color and theme.c(color, text) or text
    local pad = math.max(0, width - vlen(text))
    return theme.box[4] .. body .. string.rep(" ", pad) .. theme.box[4]
end

-- Build the review card frame as an array of plain strings (theme = colors/ascii)
function UI.review_frame(card, session, theme, cols, rows)
    local width = math.max(40, cols - 1)
    local out = {}
    local date = os.date("%Y-%m-%d")
    local dash = theme.box[2]
    out[#out + 1] = theme.c("1;36", theme.box[1] .. dash .. " dict " .. theme.box[4] .. " review " .. dash .. dash .. " " .. date .. " ") ..
                    string.rep(dash, math.max(0, width - 24 - #date)) .. theme.box[3]
    local head = string.format("  card %d/%d   learned %d %s learning %d   streak %d",
        session.idx, #session.queue, session.learned, theme.box[4], session.learning, session.streak)
    out[#out + 1] = pad_row(theme, fit(head, width - 2), width, "1;30;47")
    out[#out + 1] = theme.c("90", hline(theme, theme.box[7], theme.box[2], theme.box[8], width))

    local body_rows = math.max(6, rows - 5)
    for i = 1, body_rows do out[#out + 1] = pad_row(theme, "", width) end

    if not card then
        out[4] = pad_row(theme, center("no cards due — come back later!", width - 2), width, "32")
        out[#out + 1] = theme.c("90", hline(theme, theme.box[5], theme.box[2], theme.box[6], width))
        return out
    end

    if not session.revealed then
        -- FRONT: word + pos
        out[4] = pad_row(theme, "", width)
        out[5] = pad_row(theme, center(theme.c("1;33", card.word), width - 2), width)
        if card.pos and #card.pos > 0 then
            out[6] = pad_row(theme, center(theme.c("90", card.pos), width - 2), width)
        end
        out[#out] = pad_row(theme, center(theme.c("36", "[Space] reveal    [s] skip    [q] quit"), width - 2), width)
    else
        -- BACK: definition + example + syn/ant/mnemonic + grading
        local y = 4
        out[y] = pad_row(theme, center(theme.c("1;33", card.word), width - 2), width)
        y = y + 1
        if card.pos and #card.pos > 0 then
            out[y] = pad_row(theme, center(theme.c("90", card.pos), width - 2), width)
            y = y + 1
        end
        out[y] = pad_row(theme, "", width)
        y = y + 1
        out[y] = pad_row(theme, "  " .. fit(card.definition or "", width - 4), width, "1;37")
        y = y + 1
        if card.example and #card.example > 0 then
            out[y] = pad_row(theme, "  " .. fit('"' .. card.example .. '"', width - 4), width, "90")
            y = y + 1
        end
        if card.syn and #card.syn > 0 then
            out[y] = pad_row(theme, "  " .. fit("syn: " .. card.syn, width - 4), width, "32")
            y = y + 1
        end
        if card.ant and #card.ant > 0 then
            out[y] = pad_row(theme, "  " .. fit("ant: " .. card.ant, width - 4), width, "31")
            y = y + 1
        end
        if card.mnem and #card.mnem > 0 then
            out[y] = pad_row(theme, "  " .. fit("mnemonic: " .. card.mnem, width - 4), width, "35")
            y = y + 1
        end
        out[#out] = pad_row(theme, center(theme.c("1;36", "Again [1]   Hard [2]   Good [3]   Easy [4]   [s] skip   [q] quit"), width - 2), width)
    end

    out[#out + 1] = theme.c("90", hline(theme, theme.box[5], theme.box[2], theme.box[6], width))
    return out
end

-- Build a quiz frame; state: { idx=, total=, score=, q=question|nil, feedback=|nil }
function UI.quiz_frame(state, theme, cols, rows)
    local width = math.max(40, cols - 1)
    local out = {}
    local dash = theme.box[2]
    out[#out + 1] = theme.c("1;35", theme.box[1] .. dash .. " dict " .. theme.box[4] .. " quiz " .. dash .. dash .. " multiple choice ") ..
                    string.rep(dash, math.max(0, width - 34)) .. theme.box[3]
    local head = string.format("  Q%d/%d   score %d/%d", state.idx, state.total, state.score, state.idx - 1)
    out[#out + 1] = pad_row(theme, fit(head, width - 2), width, "1;30;47")
    out[#out + 1] = theme.c("90", hline(theme, theme.box[7], theme.box[2], theme.box[8], width))

    local body_rows = math.max(6, rows - 5)
    for i = 1, body_rows do out[#out + 1] = pad_row(theme, "", width) end

    if not state.q then
        out[4] = pad_row(theme, center("no cards available for quiz — add words first", width - 2), width, "32")
        out[#out + 1] = theme.c("90", hline(theme, theme.box[5], theme.box[2], theme.box[6], width))
        return out
    end

    local y = 4
    out[y] = pad_row(theme, "  " .. fit(state.q.prompt, width - 4), width, "1;37")
    y = y + 1
    out[y] = pad_row(theme, "", width)
    y = y + 1

    if state.feedback then
        local mark = state.feedback.correct and theme.c("1;32", "✔ correct!") or theme.c("1;31", "✘ wrong")
        out[y] = pad_row(theme, center(mark, width - 2), width)
        y = y + 1
        out[y] = pad_row(theme, center("answer: " .. state.q.word, width - 2), width, "1;33")
        y = y + 1
        if state.q.feedback_definition and #state.q.feedback_definition > 0 then
            out[y] = pad_row(theme, "  " .. fit(state.q.feedback_definition, width - 4), width, "90")
            y = y + 1
        end
        out[#out] = pad_row(theme, center(theme.c("36", "any key next    [q] quit"), width - 2), width)
    else
        local c = state.q.choices
        out[y] = pad_row(theme, string.format("   %d. %-24s %d. %s", 1, fit(c[1], 22), 2, fit(c[2], 22)), width)
        y = y + 1
        out[y] = pad_row(theme, string.format("   %d. %-24s %d. %s", 3, fit(c[3], 22), 4, fit(c[4], 22)), width)
        out[#out] = pad_row(theme, center(theme.c("36", "press 1-4    [s] skip    [q] quit"), width - 2), width)
    end

    out[#out + 1] = theme.c("90", hline(theme, theme.box[5], theme.box[2], theme.box[6], width))
    return out
end

function UI.study_plan_frame(state, theme, cols, rows)
    local width = math.max(40, cols - 1)
    local dash = theme.box[2]
    local out = {
        theme.c("1;36", theme.box[1] .. dash .. " dict " .. theme.box[4] .. " study plan " .. dash .. theme.box[3]),
        pad_row(theme, fit(state.heading or "Choose a track and daily goal", width - 2), width, "1;30;47"),
        theme.c("90", hline(theme, theme.box[7], theme.box[2], theme.box[8], width)),
    }
    local body_rows = math.max(12, rows - 5)
    for _ = 1, body_rows do out[#out + 1] = pad_row(theme, "", width) end

    if state.screen == "choose" then
        out[4] = pad_row(theme, "  Select a vocabulary track:", width)
        for i, track in ipairs(STUDY_TRACKS) do
            local marker = state.track_idx == i and ">" or " "
            out[4 + i] = pad_row(theme, string.format("  %s %s", marker, track.name), width,
                state.track_idx == i and "1;33" or nil)
        end
        local mixed_idx = #STUDY_TRACKS + 1
        out[4 + mixed_idx] = pad_row(theme,
            string.format("  %s Mixed / adaptive", state.track_idx == mixed_idx and ">" or " "), width,
            state.track_idx == mixed_idx and "1;33" or nil)
        out[10] = pad_row(theme, string.format("  New words per session: %d   (%d due for review)", state.batch_size, state.due), width)
        out[11] = pad_row(theme, string.format("  New words added today: %d", state.plan_today or 0), width, "32")
        if state.message then out[12] = pad_row(theme, "  " .. state.message, width, "33") end
        out[#out] = pad_row(theme, "↑/↓ track  +/- session batch  Enter preview  [q] quit", width, "36")
    elseif state.screen == "preview" then
        local preview = state.preview or {}
        local first = state.preview_offset or 1
        local visible = math.max(1, #out - 8)
        local selected_count = 0
        for _, entry in ipairs(preview) do if entry.selected then selected_count = selected_count + 1 end end
        out[4] = pad_row(theme, string.format("  Preview: %s (%d/%d selected)",
            state.track_name, selected_count, #preview), width, "1;33")
        for i = 1, visible do
            local idx = first + i - 1
            local entry = preview[idx]
            if not entry then break end
            local marker = entry.selected and "[x] " or "[ ] "
            local def = entry.definition or "(definition unavailable)"
            local source = entry.source_track == "general" and "General dictionary"
                or (STUDY_TRACK_BY_ID[entry.source_track] and STUDY_TRACK_BY_ID[entry.source_track].name or entry.source_track or "")
            local color = idx == state.preview_idx and "1;33" or nil
            out[4 + i] = pad_row(theme, "  " .. marker .. entry.word .. " — " .. def .. " [" .. source .. "]", width, color)
        end
        local footer_row = #out - 1
        if #preview > visible then
            out[footer_row] = pad_row(theme,
                string.format("  Showing %d-%d of %d words", first, math.min(first + visible - 1, #preview), #preview),
                width, "90")
            footer_row = footer_row - 1
        end
        if state.message then out[footer_row] = pad_row(theme, "  " .. state.message, width, "33") end
        out[#out] = pad_row(theme, "↑/↓ move  Space toggle  Enter add selected  [b] back  [q] quit", width, "36")
    else
        out[4] = pad_row(theme, center(state.message or "Today's words are ready.", width - 2), width, "1;32")
        out[5] = pad_row(theme, center(string.format("New words added today: %d", state.plan_today or 0), width - 2), width)
        out[7] = pad_row(theme, center("[n] add another new-word batch", width - 2), width, "36")
        out[8] = pad_row(theme, center("[r] review due cards now", width - 2), width, "36")
        out[#out] = pad_row(theme, "[n] next batch  [r] review  Enter plan settings  [q] quit", width, "36")
    end
    return out
end

--------------------------------------------------------------------------------
-- 10. Interactive Sessions (review & quiz)
--------------------------------------------------------------------------------
local TUI = {}

local function quiz_pool_for(db, entry)
    local pool = {}
    local seen = {}
    local function add(rows)
        for _, r in ipairs(rows or {}) do
            if r.word ~= entry.word and not seen[r.word] then
                seen[r.word] = true
                pool[#pool + 1] = r.word
            end
        end
    end
    -- prefer deck words, then dictionary words with matching part of speech
    add(db:query("SELECT word FROM words WHERE lower(word) != lower(?) LIMIT 50;", { entry.word }))
    if entry.pos and #entry.pos > 0 then
        add(db:query("SELECT DISTINCT word FROM dict WHERE lower(word) != lower(?) AND pos = ? LIMIT 50;",
            { entry.word, entry.pos }))
    end
    add(db:query("SELECT DISTINCT word FROM dict WHERE lower(word) != lower(?) LIMIT 50;", { entry.word }))
    return pool
end

TUI.quiz_pool_for = quiz_pool_for

local function render_lines(lines)
    return table.concat(lines, "\n") .. "\n"
end

local function selected_track_id(index)
    if index == #STUDY_TRACKS + 1 then return "mixed" end
    return STUDY_TRACKS[index].id
end

function TUI.study_plan(db, opts)
    opts = opts or {}
    if not Term.is_tty() then
        io.write("Study plan requires an interactive TTY. Run this command in a terminal.\n")
        return false
    end

    local current = db:study_plan_get()
    local selected = 1
    if current then
        if current.track == "mixed" then
            selected = #STUDY_TRACKS + 1
        else
            for i, track in ipairs(STUDY_TRACKS) do
                if track.id == current.track then selected = i break end
            end
        end
    end
    local state = {
        screen = "choose", track_idx = selected,
        batch_size = current and current.batch_size or 10,
        due = #db:get_due(os.time(), 100000),
        plan_today = db:study_plan_today_count(os.date("%Y-%m-%d")),
    }
    local cols, rows = Term.size()
    local renderer = Renderer.new(cols, rows, false)
    if not Term.enable_raw() then
        io.write("Error: failed to initialize raw terminal mode.\n")
        return false
    end

    local running, start_review = true, false
    local ok, err = xpcall(function()
        while running do
            local c2, r2 = Term.size()
            if c2 ~= cols or r2 ~= rows then
                cols, rows = c2, r2
                renderer = Renderer.new(cols, rows, false)
                io.write("\27[2J")
                renderer:force_full()
            end
            renderer:begin()
            local lines = UI.study_plan_frame(state, make_theme(false, opts.ascii), cols, rows)
            for i, line in ipairs(lines) do renderer:set(i, line) end
            renderer:flush()

            local key = Term.read_key(100)
            if key then
                if key == "q" or key == "ESC" or key == "CTRL_C" then
                    running = false
                elseif state.screen == "choose" then
                    if key == "UP" then
                        state.track_idx = ((state.track_idx - 2) % (#STUDY_TRACKS + 1)) + 1
                    elseif key == "DOWN" then
                        state.track_idx = (state.track_idx % (#STUDY_TRACKS + 1)) + 1
                    elseif key == "+" or key == "=" then
                        state.batch_size = math.min(50, state.batch_size + 1)
                    elseif key == "-" then
                        state.batch_size = math.max(1, state.batch_size - 1)
                    elseif key == "ENTER" then
                        local track_id = selected_track_id(state.track_idx)
                        local candidates, candidate_err = db:study_plan_candidates(track_id, state.batch_size)
                        if candidates then
                            state.preview = candidates
                            for _, candidate in ipairs(candidates) do candidate.selected = true end
                            state.preview_idx = 1
                            state.preview_offset = 1
                            state.track_name = track_id == "mixed" and "Mixed / adaptive" or STUDY_TRACK_BY_ID[track_id].name
                            state.screen = "preview"
                            state.message = #candidates == 0 and "No unused words found; import a dictionary." or nil
                        else
                            state.message = candidate_err
                        end
                    end
                elseif state.screen == "preview" then
                    if key == "UP" and #(state.preview or {}) > 0 then
                        state.preview_idx = math.max(1, state.preview_idx - 1)
                        if state.preview_idx < state.preview_offset then
                            state.preview_offset = state.preview_idx
                        end
                    elseif key == "DOWN" and #(state.preview or {}) > 0 then
                        state.preview_idx = math.min(#state.preview, state.preview_idx + 1)
                        local visible = math.max(1, rows - 13)
                        if state.preview_idx >= state.preview_offset + visible then
                            state.preview_offset = state.preview_idx - visible + 1
                        end
                    elseif key == " " and state.preview[state.preview_idx] then
                        state.preview[state.preview_idx].selected = not state.preview[state.preview_idx].selected
                        state.message = nil
                    elseif key == "b" then
                        state.screen = "choose"
                        state.message = nil
                    elseif key == "ENTER" then
                        local track_id = selected_track_id(state.track_idx)
                        local saved, save_err = db:study_plan_set(track_id, state.batch_size, os.time())
                        if not saved then
                            state.message = save_err
                        else
                            local selection = {}
                            for _, candidate in ipairs(state.preview) do
                                if candidate.selected then selection[candidate.word] = true end
                            end
                            local added, add_err = db:study_plan_start_today(os.time(), selection)
                            if not added then
                                state.message = add_err
                            else
                                state.plan_today = db:study_plan_today_count(os.date("%Y-%m-%d"))
                                state.last_batch_size = #added
                                state.message = #added > 0 and string.format("Added %d new word(s) to your deck.", #added)
                                    or (add_err or "No new words added.")
                                state.screen = "done"
                            end
                        end
                    end
                elseif state.screen == "done" then
                    if key == "r" then
                        running = false
                        start_review = true
                    elseif key == "n" then
                        local track_id = selected_track_id(state.track_idx)
                        local candidates, candidate_err = db:study_plan_candidates(track_id, state.batch_size)
                        if candidates and #candidates > 0 then
                            state.preview = candidates
                            for _, candidate in ipairs(candidates) do candidate.selected = true end
                            state.preview_idx = 1
                            state.preview_offset = 1
                            state.track_name = track_id == "mixed" and "Mixed / adaptive" or STUDY_TRACK_BY_ID[track_id].name
                            state.screen = "preview"
                            state.message = nil
                        else
                            state.message = candidate_err or "No unused words remain in the imported dictionary."
                        end
                    elseif key == "ENTER" then
                        state.screen = "choose"
                        state.message = nil
                        state.due = #db:get_due(os.time(), 100000)
                    end
                end
            end
        end
    end, debug.traceback)

    Term.disable_raw()
    if not ok then
        io.write("Error in study plan: " .. tostring(err) .. "\n")
        return false
    end
    if start_review then return TUI.review(db, { limit = 20 }) end
    return true
end

function TUI.review(db, opts)
    opts = opts or {}
    local now = os.time()
    local limit = opts.limit or 20
    local queue = db:get_due(now, limit)
    local theme = make_theme(opts.snapshot and true or false, opts.ascii)

    if #queue == 0 then
        io.write("No cards due for review. Add words with: ffi_dict.lua add <word>\n")
        return true
    end

    local stats = db:stats(now)
    local session = {
        idx = 1, revealed = false, queue = queue,
        learned = stats.learned, learning = stats.learning, streak = stats.streak,
        grades = { 0, 0, 0, 0 }, reviewed = 0,
    }

    if opts.snapshot then
        local cols, rows = Term.size()
        io.write(render_lines(UI.review_frame(queue[1], session, theme, math.min(cols, 100), 14)))
        return true
    end

    if not Term.is_tty() then
        io.write("Note: interactive review requires a TTY. Use --snapshot for headless output.\n")
        return false
    end

    local cols, rows = Term.size()
    local r = Renderer.new(cols, rows, false)
    local ok_raw = Term.enable_raw()
    if not ok_raw then
        io.write("Error: failed to initialize raw terminal mode.\n")
        return false
    end

    local running = true
    local ok, err = xpcall(function()
        while running do
            local card = queue[session.idx]
            local c2, r2 = Term.size()
            if c2 ~= cols or r2 ~= rows then
                cols, rows = c2, r2
                r = Renderer.new(cols, rows, false)
                io.write("\27[2J") -- full clear only on resize
                r:force_full()
            end
            r:begin()
            local lines = UI.review_frame(card, session, theme, cols, rows)
            for i, line in ipairs(lines) do r:set(i, line) end
            r:flush()

            local key = Term.read_key(100)
            if key then
                if key == "q" or key == "ESC" or key == "CTRL_C" then
                    running = false
                elseif not session.revealed then
                    if key == " " or key == "ENTER" then
                        session.revealed = true
                    elseif key == "s" then
                        session.idx = session.idx + 1
                        session.revealed = false
                    end
                else
                    local grade = tonumber(key)
                    if grade and grade >= 1 and grade <= 4 then
                        local g = grade - 1 -- keys 1..4 map to Again..Easy
                        db:srs_apply(card.id, g, os.time())
                        session.grades[g + 1] = session.grades[g + 1] + 1
                        session.reviewed = session.reviewed + 1
                        session.idx = session.idx + 1
                        session.revealed = false
                    elseif key == "s" then
                        session.idx = session.idx + 1
                        session.revealed = false
                    end
                end
                if session.idx > #queue then running = false end
            end
        end
    end, debug.traceback)

    Term.disable_raw()
    if not ok then
        io.write("Error in review session: " .. tostring(err) .. "\n")
        return false
    end

    io.write(string.format("✔ review session complete — %d cards graded (Again %d · Hard %d · Good %d · Easy %d)\n",
        session.reviewed, session.grades[1], session.grades[2], session.grades[3], session.grades[4]))
    return true
end

function TUI.quiz(db, opts)
    opts = opts or {}
    local now = os.time()
    local limit = opts.limit or 10
    local rng = opts.seed and Quiz.lcg_rng(opts.seed) or function(n) return math.random(n) end
    local queue = opts.any and db:deck_sample(limit) or db:get_due(now, limit)
    local theme = make_theme(opts.snapshot and true or false, opts.ascii)

    if #queue == 0 then
        io.write("No cards available for quiz. Add words with: ffi_dict.lua add <word>\n")
        return true
    end

    -- Pre-build questions deterministically
    local questions = {}
    for _, card in ipairs(queue) do
        local pool = quiz_pool_for(db, card)
        local q = Quiz.build(card, pool, rng)
        if q then
            q.feedback_definition = card.definition
            questions[#questions + 1] = q
        end
    end

    local state = { idx = 1, total = #questions, score = 0, q = questions[1], feedback = nil }

    if opts.snapshot then
        if not state.q then
            io.write("No quiz questions could be built (need at least 4 known words).\n")
            return true
        end
        local cols = Term.size()
        io.write(render_lines(UI.quiz_frame(state, theme, math.min(cols, 100), 14)))
        return true
    end

    if #questions == 0 then
        io.write("No quiz questions could be built (need at least 4 known words).\n")
        return true
    end

    if not Term.is_tty() then
        io.write("Note: interactive quiz requires a TTY. Use --snapshot for headless output.\n")
        return false
    end

    local cols, rows = Term.size()
    local r = Renderer.new(cols, rows, false)
    if not Term.enable_raw() then
        io.write("Error: failed to initialize raw terminal mode.\n")
        return false
    end

    local running = true
    local ok, err = xpcall(function()
        while running do
            local c2, r2 = Term.size()
            if c2 ~= cols or r2 ~= rows then
                cols, rows = c2, r2
                r = Renderer.new(cols, rows, false)
                io.write("\27[2J")
                r:force_full()
            end
            r:begin()
            local lines = UI.quiz_frame(state, theme, cols, rows)
            for i, line in ipairs(lines) do r:set(i, line) end
            r:flush()

            local key = Term.read_key(100)
            if key then
                if key == "q" or key == "CTRL_C" then
                    running = false
                elseif state.feedback then
                    state.feedback = nil
                    state.idx = state.idx + 1
                    state.q = questions[state.idx]
                    if not state.q then running = false end
                else
                    local choice = tonumber(key)
                    if choice and choice >= 1 and choice <= 4 then
                        local correct = Quiz.check(state.q, choice)
                        if correct then
                            state.score = state.score + 1
                        end
                        local card = queue[state.idx]
                        if card then
                            db:srs_apply(card.id, correct and SM2.GRADE_GOOD or SM2.GRADE_AGAIN, os.time())
                        end
                        state.feedback = { correct = correct }
                    elseif key == "s" or key == " " then
                        state.feedback = { correct = false, skipped = true }
                        state.feedback = nil
                        state.idx = state.idx + 1
                        state.q = questions[state.idx]
                        if not state.q then running = false end
                    end
                end
            end
        end
    end, debug.traceback)

    Term.disable_raw()
    if not ok then
        io.write("Error in quiz session: " .. tostring(err) .. "\n")
        return false
    end

    io.write(string.format("✔ quiz complete — score %d/%d\n", state.score, math.max(state.idx - 1, state.score)))
    return true
end

TUI.review_frame = UI.review_frame
TUI.quiz_frame = UI.quiz_frame
TUI.study_plan_frame = UI.study_plan_frame
TUI.render_lines = render_lines

--------------------------------------------------------------------------------
-- 11. CLI
--------------------------------------------------------------------------------
local function print_help()
    print([[
ffi_dict — Offline Vocabulary Trainer & Dictionary (SM-2 spaced repetition)
Powered by LuaJIT FFI & SQLite FTS5 (Zero dependencies)

Usage:
  ffi_dict <command> [arguments]

Commands:
  add <word>             Add a word to your deck (auto-fills from imported dictionary)
  review                 Flashcard review with SM-2 grading (Again/Hard/Good/Easy)
  quiz                   Multiple-choice quiz (cloze from example sentences)
  lookup <query>         Search the dictionary and your deck
  stats                  Learning statistics, streak and review sparkline
  wotd                   Word of the day (deterministic per day)
  plan                   Choose a track and start today's guided study session
  import <paths...>      Import dictionary data into the local database

Options:
  --db <path>            Database file (default: .dict.db)
  --limit <n>            Card/question limit (default: review 20, quiz 10)
  --seed <n>             Deterministic quiz RNG seed
  --any                  Quiz from the whole deck (not only due cards)
  --snapshot             Non-interactive single-frame output (headless validation)
  --ascii                ASCII-only borders
  --def/--example/--pos/--syn/--ant/--mnem/--tags <v>   Fields for `add`
  --wordset|--webster|--csv   Import format (with `import`)
  --test                 Run built-in unit & integration test suite

Download and import the Wordset dictionary (run from the project directory):
  git clone https://github.com/wordset/wordset-dictionary.git
  luajit ffi_dict.lua import --wordset ./wordset-dictionary/data

Examples:
  luajit ffi_dict.lua add ephemeral
  luajit ffi_dict.lua review
  luajit ffi_dict.lua quiz --limit 10
  luajit ffi_dict.lua lookup "short lived"
  luajit ffi_dict.lua stats
  luajit ffi_dict.lua plan

Study plan tracks:
  Common English, Academic, Exam Prep, Mixed / adaptive
  (bundled starter lists; Exam Prep is not an official exam syllabus)

Interactive keys:
  plan:    [↑/↓] select/scroll  [+/-] session batch  [Enter] preview  [Space] toggle  [n] next batch
  review:  [Space] reveal  [1] Again  [2] Hard  [3] Good  [4] Easy  [s] skip  [q] quit
  quiz:    [1-4] answer    [s] skip   [q] quit
]])
end

local function run_self_tests()
    print("================================================================================")
    print("  Running Unit & Integration Tests for ffi_dict.lua")
    print("================================================================================")
    local tmp = "/tmp/_test_ffi_dict_" .. os.time() .. ".db"
    os.remove(tmp); os.remove(tmp .. "-wal"); os.remove(tmp .. "-shm")

    local db = assert(Database.open(tmp))

    io.write("Test 1:  Database & schema initialization... ")
    assert(db.db ~= nil, "db handle")
    assert(db:scalar("SELECT COUNT(*) FROM words;") == 0)
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 2:  JSON decoder (objects, arrays, escapes, numbers)... ")
    local obj = JSON.decode('{"a": [1, 2.5, true, "x\\u0041\\n"], "b": {"c": "d"}, "n": null}')
    assert(obj.a[1] == 1 and obj.a[2] == 2.5 and obj.a[3] == true)
    assert(obj.a[4] == "xA\n" and obj.b.c == "d")
    assert(obj.n == nil, "null decodes to nil")
    assert(pcall(JSON.decode, "{bad") == false)
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 3:  Wordset import & dictionary lookup... ")
    local ws = JSON.decode([[{
        "ephemeral": {"word": "ephemeral", "meanings": [
            {"def": "lasting for a very short time", "speech_part": "adjective",
             "example": "Fame in the world of art is ephemeral.", "synonyms": ["transient", "fleeting"]},
            {"def": "a short-lived insect", "speech_part": "noun"}]},
        "obstinate": {"word": "obstinate", "meanings": [
            {"def": "stubbornly refusing to change one's opinion", "speech_part": "adjective"}]}
    }]])
    local w, s = Importer.ingest_wordset(db, ws)
    assert(w == 2 and s == 3, "expected 2 words / 3 senses")
    local senses = db:dict_lookup("ephemeral")
    assert(#senses == 2, "expected 2 senses")
    assert(senses[1].definition:find("very short time"))
    assert(senses[1].example:find("ephemeral"))
    assert(senses[1].syn:find("transient"))
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 4:  FTS5 search over imported dictionary... ")
    local hits = db:dict_search("stubbornly")
    assert(#hits >= 1 and hits[1].word == "obstinate", "FTS search should find obstinate")
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 5:  Deck add with auto-fill and explicit fields... ")
    local id = assert(db:deck_add({ word = "ephemeral" }, 1000))
    local card = db:deck_get("ephemeral")
    assert(card.definition:find("very short time"), "auto-filled definition")
    assert(card.pos == "adjective", "auto-filled pos")
    assert(card.example:find("Fame"), "auto-filled example")
    local id2 = assert(db:deck_add({ word = "taciturn", definition = "reserved", pos = "adjective" }, 1000))
    assert(id2 ~= id)
    local _, derr = db:deck_add({ word = "ephemeral" }, 1000)
    assert(derr and derr:find("already"), "duplicate must be rejected")
    local _, nferr = db:deck_add({ word = "zzzunknown" }, 1000)
    assert(nferr and nferr:find("not found"), "unknown word without --def must be rejected")
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 6:  SM-2 scheduling math... ")
    local st = SM2.new_state()
    local s1 = assert(SM2.schedule(st, SM2.GRADE_GOOD, 1000))
    assert(s1.interval_days == 1 and s1.reps == 1 and s1.due_at == 1000 + 86400)
    local s2 = assert(SM2.schedule(s1, SM2.GRADE_GOOD, 1000))
    assert(s2.interval_days == 3 and s2.reps == 2)
    local s3 = assert(SM2.schedule(s2, SM2.GRADE_GOOD, 1000))
    assert(math.abs(s3.interval_days - 7.5) < 1e-9)
    local e1 = assert(SM2.schedule(st, SM2.GRADE_EASY, 1000))
    assert(e1.interval_days == 2 and math.abs(e1.ease - 2.65) < 1e-9)
    local h1 = assert(SM2.schedule(st, SM2.GRADE_HARD, 1000))
    assert(h1.interval_days == 0.5 and math.abs(h1.ease - 2.35) < 1e-9)
    local a1 = assert(SM2.schedule(s3, SM2.GRADE_AGAIN, 1000))
    assert(a1.reps == 0 and a1.lapses == 1 and a1.due_at == 1600 and a1.interval_days == 0)
    assert(math.abs(a1.ease - 2.3) < 1e-9)
    local floor_st = { ease = 1.35, interval_days = 5, due_at = 0, reps = 2, lapses = 0 }
    local f1 = assert(SM2.schedule(floor_st, SM2.GRADE_AGAIN, 0))
    assert(f1.ease == 1.3, "ease floor 1.3")
    local bad, err = SM2.schedule(st, 7, 0)
    assert(bad == nil and err, "invalid grade rejected")
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 7:  Due queue ordering and review application... ")
    local due = db:get_due(1000, 10)
    assert(#due == 2, "both new cards due at add-time")
    local graded = assert(db:srs_apply(due[1].id, SM2.GRADE_GOOD, 1000))
    assert(graded.reps == 1 and graded.interval_days == 1)
    local due2 = db:get_due(1000, 10)
    assert(#due2 == 1, "graded card no longer due")
    assert(db:scalar("SELECT COUNT(*) FROM reviews;") == 1)
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 8:  Quiz builder (cloze, distractors, determinism)... ")
    local entry = { word = "ephemeral", pos = "adjective", definition = "lasting for a very short time",
                    example = "Fame in the world of art is ephemeral." }
    local pool = { "obstinate", "taciturn", "magnanimous", "laconic", "ebullient" }
    local q1 = assert(Quiz.build(entry, pool, Quiz.lcg_rng(42)))
    local q2 = assert(Quiz.build(entry, pool, Quiz.lcg_rng(42)))
    assert(q1.prompt == q2.prompt and table.concat(q1.choices) == table.concat(q2.choices), "seeded determinism")
    assert(q1.kind == "cloze" and q1.prompt:find("____"), "example masked")
    assert(#q1.choices == 4, "4 choices")
    local seen = {}
    for _, c in ipairs(q1.choices) do assert(not seen[c], "choices unique"); seen[c] = true end
    assert(seen["ephemeral"], "answer present")
    assert(Quiz.check(q1, q1.answer_idx), "check() validates correct index")
    assert(not Quiz.check(q1, (q1.answer_idx % 4) + 1), "check() rejects wrong index")
    local masked, n = Quiz.mask_example("The Ephemeral mayfly; ephemeral.", "ephemeral")
    assert(n == 2 and masked:find("____"), "case-insensitive whole-word masking")
    local qe, qerr = Quiz.build(entry, { "only-one" }, Quiz.lcg_rng(1))
    assert(qe == nil and qerr, "insufficient distractors rejected")
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 9:  CSV import parsing... ")
    local cw, cs = Importer.ingest_csv(db, 'word,pos,definition,example,syn,ant\nlaconic,adj,"using very few words","a laconic reply",brief,verbose\n')
    assert(cw == 1 and cs == 1, "csv import counts")
    local lc = db:dict_lookup("laconic")
    assert(#lc == 1 and lc[1].definition == "using very few words", "quoted field parsed")
    assert(lc[1].example == "a laconic reply")
    print("\27[32m✔ PASSED\27[0m")

    io.write("Test 10: Statistics, streak and word of the day... ")
    local stats = db:stats(1000)
    assert(stats.total == 2, "deck size")
    assert(stats.reviews == 1 and stats.retention == 100, "retention from 1 review")
    assert(type(stats.streak) == "number" and #stats.day_counts == 14)
    local wotd, src = db:wotd(1000)
    assert(wotd and (src == "deck"), "wotd from deck")
    local wotd2 = db:wotd(1000)
    assert(wotd2.word == wotd.word, "wotd deterministic within a day")
    print("\27[32m✔ PASSED\27[0m")

    db:close()
    os.remove(tmp); os.remove(tmp .. "-wal"); os.remove(tmp .. "-shm")

    print("================================================================================")
    print("\27[1;32mALL DICT TESTS PASSED SUCCESSFULLY! (10/10)\27[0m")
    print("================================================================================")
end

local function parse_args(args)
    local opts = {
        db_path = ".dict.db",
        command = nil,
        positional = {},
        limit = nil,
        seed = nil,
        any = false,
        snapshot = false,
        ascii = false,
        import_fmt = nil,
        fields = {},
    }
    local field_flags = {
        ["--def"] = "definition", ["--definition"] = "definition",
        ["--example"] = "example", ["--pos"] = "pos",
        ["--syn"] = "syn", ["--ant"] = "ant", ["--mnem"] = "mnem", ["--tags"] = "tags",
    }
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--db" and i + 1 <= #args then
            opts.db_path = args[i + 1]; i = i + 1
        elseif a == "--limit" and i + 1 <= #args then
            opts.limit = tonumber(args[i + 1]); i = i + 1
        elseif a == "--seed" and i + 1 <= #args then
            opts.seed = tonumber(args[i + 1]); i = i + 1
        elseif a == "--any" then
            opts.any = true
        elseif a == "--snapshot" then
            opts.snapshot = true
        elseif a == "--ascii" then
            opts.ascii = true
        elseif a == "--wordset" then
            opts.import_fmt = "wordset"
        elseif a == "--webster" then
            opts.import_fmt = "webster"
        elseif a == "--csv" then
            opts.import_fmt = "csv"
        elseif a == "--help" or a == "-h" then
            opts.help = true
        elseif a == "--test" then
            opts.test = true
        elseif field_flags[a] and i + 1 <= #args then
            opts.fields[field_flags[a]] = args[i + 1]; i = i + 1
        elseif not opts.command then
            opts.command = a
        else
            opts.positional[#opts.positional + 1] = a
        end
        i = i + 1
    end
    return opts
end

local function format_date(ts)
    return os.date("%Y-%m-%d", ts)
end

local function format_entry(e, theme_plain)
    local lines = {}
    local head = e.word
    if e.pos and #e.pos > 0 then head = head .. "  (" .. e.pos .. ")" end
    lines[#lines + 1] = "  " .. head
    if e.definition and #e.definition > 0 then lines[#lines + 1] = "    " .. e.definition end
    if e.example and #e.example > 0 then lines[#lines + 1] = '    "' .. e.example .. '"' end
    if e.syn and #e.syn > 0 then lines[#lines + 1] = "    syn: " .. e.syn end
    if e.ant and #e.ant > 0 then lines[#lines + 1] = "    ant: " .. e.ant end
    return table.concat(lines, "\n")
end

local function cmd_lookup(db, opts)
    local q = table.concat(opts.positional, " ")
    if #q == 0 then
        print("Error: lookup requires a query. Example: ffi_dict.lua lookup 'short lived'")
        return false
    end
    local dict_hits = db:dict_search(q, 10)
    local deck_hits = db:query([[
        SELECT w.word, w.pos, w.definition, w.example, w.syn, w.ant,
               s.interval_days, s.due_at, s.reps, s.lapses
        FROM words w JOIN srs s ON s.word_id = w.id
        WHERE lower(w.word) LIKE lower(?) OR lower(w.definition) LIKE lower(?)
        LIMIT 10;]], { "%" .. q .. "%", "%" .. q .. "%" }) or {}

    print(string.format("\27[1;36m🔍 '%s'\27[0m — %d dictionary sense(s), %d in your deck\n",
        q, #dict_hits, #deck_hits))
    for _, e in ipairs(dict_hits) do
        print("\27[90m[dict]\27[0m" .. format_entry(e))
    end
    for _, e in ipairs(deck_hits) do
        local status = e.reps == 0 and "new" or (e.interval_days >= 21 and "learned" or "learning")
        print(string.format("\27[35m[deck · %s · due %s]\27[0m%s",
            status, format_date(e.due_at), format_entry(e)))
    end
    return true
end

local function cmd_stats(db, opts)
    local s = db:stats(os.time())
    local dash = opts.ascii and "-" or "─"
    local pipe = opts.ascii and "|" or "│"
    print()
    print("\27[1;36m  " .. dash .. dash .. " dict ▸ stats " .. string.rep(dash, 40) .. "\27[0m")
    print(string.format("  deck        %d words   (\27[32mlearned %d\27[0m %s \27[33mlearning %d\27[0m %s new %d)",
        s.total, s.learned, pipe, s.learning, pipe, s.new))
    print(string.format("  due today   %d", s.due))
    print(string.format("  reviews     %d total   retention %.1f%%   avg grade %.1f",
        s.reviews, s.retention, s.avg_grade))
    print(string.format("  streak      🔥 %d day(s)", s.streak))
    print(string.format("  last 14 days  %s", (function()
        local counts = s.day_counts
        local maxv = 0
        for _, c in ipairs(counts) do if c > maxv then maxv = c end end
        local SP = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
        local out = {}
        for i, c in ipairs(counts) do
            out[i] = c == 0 and "▁" or SP[math.max(1, math.min(8, math.ceil(c / math.max(1, maxv) * 8)))]
        end
        return table.concat(out)
    end)()))
    print(string.format("  dictionary  %d words (%d senses)", s.dict_words, s.dict_senses))
    print()
    return true
end

local function cmd_wotd(db, opts)
    local e, src = db:wotd(os.time())
    if not e then
        print("Dictionary and deck are both empty — add words first.")
        return true
    end
    print("\n\27[1;33m  ★ word of the day\27[0m  \27[90m(" .. (src or "deck") .. ")\27[0m")
    print(format_entry(e))
    print()
    return true
end

local function format_duration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then return string.format("%02d:%02d:%02d", hours, minutes, secs) end
    return string.format("%02d:%02d", minutes, secs)
end

local function cmd_import(db, opts)
    local fmt = opts.import_fmt
    if not fmt then
        print("Error: import requires --wordset, --webster or --csv")
        return false
    end
    if #opts.positional == 0 then
        print("Error: import requires at least one file or directory path")
        return false
    end
    local t0 = os.time()
    local words, senses, files = 0, 0, 0
    for _, path in ipairs(opts.positional) do
        local w, s, n = Importer.import_path(db, fmt, path, function(event)
            if event.type == "scan" then
                io.write(string.format("Scanning %s... found %d candidate file(s)\n", event.path, event.files))
                if event.files == 0 then
                    io.write("  No matching files found. Check the path and expected extension.\n")
                end
                io.flush()
            elseif event.type == "start" then
                io.write(string.format("[%d/%d] Importing %s...\n", event.index, event.total, event.file))
                io.flush()
            elseif event.type == "done" then
                io.write(string.format("       done: %d words / %d senses | elapsed %s | ETA ~%s (total %d words / %d senses)\n",
                    event.words, event.senses,
                    format_duration(event.elapsed_seconds), format_duration(event.eta_seconds),
                    event.total_words, event.total_senses))
                io.flush()
            elseif event.type == "skip" then
                io.write(string.format("       skipped: %s (%s) | elapsed %s | ETA ~%s\n",
                    event.file, event.message or "unknown reason",
                    format_duration(event.elapsed_seconds), format_duration(event.eta_seconds)))
                io.flush()
            end
        end)
        words = words + w; senses = senses + s; files = files + n
    end
    local elapsed = os.time() - t0
    db:run("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_import', ?);",
        { string.format("%s %d words / %d senses / %d files @ %s", fmt, words, senses, files, os.date("!%Y-%m-%dT%H:%M:%SZ")) })
    print(string.format("✔ imported %d words (%d senses) from %d file(s) in %s",
        words, senses, files, format_duration(elapsed)))
    return true
end

local function cmd_add(db, opts)
    local word = opts.positional[1]
    if not word then
        print("Error: add requires a word. Example: ffi_dict.lua add ephemeral")
        return false
    end
    opts.fields.word = word
    local id, err = db:deck_add(opts.fields, os.time())
    if not id then
        print("\27[31m✘ " .. tostring(err) .. "\27[0m")
        return false
    end
    local card = db:deck_get(word)
    print(string.format("\27[32m✔ added '%s'\27[0m  (deck size: %d)", word, db:scalar("SELECT COUNT(*) FROM words;")))
    if card and card.definition and #card.definition > 0 then
        print("    " .. card.definition:sub(1, 120))
    end
    print("    scheduled for first review.")
    return true
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

    local opts = parse_args(args)
    if opts.help then
        print_help()
        return
    end
    if opts.test then
        run_self_tests()
        return
    end
    if not opts.command then
        print_help()
        return
    end

    local db, err = Database.open(opts.db_path)
    if not db then
        print("\27[31mError: " .. tostring(err) .. "\27[0m")
        os.exit(1)
    end

    local ok = true
    if opts.command == "add" then
        ok = cmd_add(db, opts)
    elseif opts.command == "review" then
        ok = TUI.review(db, { limit = opts.limit or 20, snapshot = opts.snapshot, ascii = opts.ascii })
    elseif opts.command == "quiz" then
        ok = TUI.quiz(db, { limit = opts.limit or 10, seed = opts.seed, any = opts.any,
                            snapshot = opts.snapshot, ascii = opts.ascii })
    elseif opts.command == "lookup" then
        ok = cmd_lookup(db, opts)
    elseif opts.command == "stats" then
        ok = cmd_stats(db, opts)
    elseif opts.command == "wotd" then
        ok = cmd_wotd(db, opts)
    elseif opts.command == "plan" then
        ok = TUI.study_plan(db, { ascii = opts.ascii })
    elseif opts.command == "import" then
        ok = cmd_import(db, opts)
    else
        print("Unknown command: " .. opts.command)
        print_help()
        ok = false
    end

    db:close()
    if not ok then os.exit(1) end
end

--------------------------------------------------------------------------------
-- 12. Module Export / Entry Point
--------------------------------------------------------------------------------
if pcall(debug.getlocal, 4, 1) then
    return {
        Database = Database,
        STUDY_TRACKS = STUDY_TRACKS,
        SM2 = SM2,
        JSON = JSON,
        Quiz = Quiz,
        Importer = Importer,
        TUI = TUI,
        Term = Term,
        main = main,
    }
else
    main(arg)
end
