#!/usr/bin/env luajit
-- ============================================================================
-- Battery Monitor: Hardware Telemetry, SQLite History & Terminal TUI Plotter
-- Written in LuaJIT + FFI (libsqlite3 C bindings + Linux sysfs telemetry + TUI)
-- ============================================================================

local require = require
local ffi = require("ffi")
local bit = require("bit")
local io = io
local os = os
local string = string
local math = math
local table = table
local type = type
local tostring = tostring
local tonumber = tonumber
local pairs = pairs
local ipairs = ipairs
local print = print
local pcall = pcall
local xpcall = xpcall
local assert = assert
local debug = debug
local setmetatable = setmetatable
local arg = arg

local cmd_seed

-- ============================================================================
-- Section 1: SQLite3 & POSIX Terminal FFI C Bindings
-- ============================================================================
ffi.cdef[[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    // SQLite Database lifecycle
    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3 *db);
    const char *sqlite3_errmsg(sqlite3 *db);

    // SQL execution
    int sqlite3_exec(sqlite3 *db, const char *sql,
                     int (*callback)(void*, int, char**, char**),
                     void *arg, char **errmsg);

    // Prepared statements
    int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                           sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt *pStmt);
    int sqlite3_finalize(sqlite3_stmt *pStmt);

    // Column extractors
    int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
    int sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
    const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);

    // POSIX terminal control attributes
    typedef unsigned int tcflag_t;
    typedef unsigned char cc_t;
    typedef unsigned int speed_t;

    struct termios {
        tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
        cc_t c_line;
        cc_t c_cc[32];
        speed_t c_ispeed, c_ospeed;
    };

    struct winsize {
        unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel;
    };

    struct pollfd {
        int fd;
        short events;
        short revents;
    };

    int tcgetattr(int fd, struct termios *termios_p);
    int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
    int ioctl(int fd, unsigned long request, ...);
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, unsigned long count);

    // POSIX signal masks (used to defer SIGINT/SIGTERM/SIGHUP until the terminal is restored)
    typedef struct { unsigned long __val[16]; } sigset_t;
    int sigemptyset(sigset_t *set);
    int sigaddset(sigset_t *set, int signum);
    int sigismember(const sigset_t *set, int signum);
    int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
    int sigpending(sigset_t *set);
]]

local function load_sqlite()
    local candidates = { "libsqlite3.so.0", "libsqlite3.so", "sqlite3", "sqlite3.dll" }
    for _, name in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            return lib
        end
    end
    return nil, "Could not load libsqlite3 shared library (tried: " .. table.concat(candidates, ", ") .. ")"
end

local sqlite, load_err = load_sqlite()
if not sqlite then
    io.stderr:write("[FATAL] " .. tostring(load_err) .. "\n")
    os.exit(1)
end

local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101

local STDIN_FD   = 0
local STDOUT_FD  = 1
local TCSANOW    = 0
local TIOCGWINSZ = 0x5413
local POLLIN     = 1

local BRKINT = 0x0002
local ICRNL  = 0x0100
local INPCK  = 0x0010
local ISTRIP = 0x0020
local IXON   = 0x0400
local OPOST  = 0x0001
local CS8    = 0x0030
local ECHO   = 0x0008
local ICANON = 0x0002
local IEXTEN = 0x8000
local ISIG   = 0x0001

local SIG_BLOCK   = 0
local SIG_UNBLOCK = 1
-- Linux signal numbers: SIGHUP, SIGINT, SIGTERM
local DEFERRED_SIGNALS = { 1, 2, 15 }

-- ============================================================================
-- Section 2: Hardware Battery Reader (Linux /sys/class/power_supply)
-- ============================================================================
local BatteryReader = {}
BatteryReader.__index = BatteryReader

function BatteryReader.find_battery_path()
    local candidates = { "BAT0", "BAT1", "BAT2" }
    for _, name in ipairs(candidates) do
        local path = "/sys/class/power_supply/" .. name
        local f = io.open(path .. "/uevent", "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

function BatteryReader.read_info(custom_path)
    local path = custom_path or BatteryReader.find_battery_path()
    if not path then
        return nil, "No battery detected under /sys/class/power_supply"
    end

    local f = io.open(path .. "/uevent", "r")
    if not f then
        return nil, "Failed to read " .. path .. "/uevent"
    end

    local props = {}
    for line in f:lines() do
        local key, val = line:match("^POWER_SUPPLY_([%w_]+)=(.*)$")
        if key and val then
            props[key] = val
        end
    end
    f:close()

    local capacity = tonumber(props.CAPACITY) or 0
    local status = props.STATUS or "Unknown"
    local voltage_raw = tonumber(props.VOLTAGE_NOW) or 0
    local power_raw = tonumber(props.POWER_NOW) or 0
    local energy_now_raw = tonumber(props.ENERGY_NOW) or tonumber(props.CHARGE_NOW) or 0
    local energy_full_raw = tonumber(props.ENERGY_FULL) or tonumber(props.CHARGE_FULL) or 0
    local energy_design_raw = tonumber(props.ENERGY_FULL_DESIGN) or tonumber(props.CHARGE_FULL_DESIGN) or 0
    local cycle_count = tonumber(props.CYCLE_COUNT) or 0
    local model_name = props.MODEL_NAME or "Generic"
    local manufacturer = props.MANUFACTURER or "Unknown"
    local technology = props.TECHNOLOGY or "Li-ion"

    -- Conversions from micro-units (uV, uW, uWh) to standard engineering units
    local voltage_v = voltage_raw / 1000000.0
    local power_w = power_raw / 1000000.0
    local energy_wh = energy_now_raw / 1000000.0
    local energy_full_wh = energy_full_raw / 1000000.0
    local energy_design_wh = energy_design_raw / 1000000.0

    -- Health percentage
    local health_pct = 100.0
    if energy_design_wh > 0 then
        health_pct = (energy_full_wh / energy_design_wh) * 100.0
    end

    return {
        timestamp = os.time(),
        capacity = capacity,
        status = status,
        voltage_v = voltage_v,
        power_w = power_w,
        energy_wh = energy_wh,
        energy_full_wh = energy_full_wh,
        energy_design_wh = energy_design_wh,
        health_pct = health_pct,
        cycle_count = cycle_count,
        model_name = model_name,
        manufacturer = manufacturer,
        technology = technology,
        path = path,
    }
end

-- ============================================================================
-- Section 3: SQLite3 Storage Engine via LuaJIT FFI
-- ============================================================================
local BatteryDB = {}
BatteryDB.__index = BatteryDB

function BatteryDB:open(db_path)
    local db_file = db_path or (os.getenv("BATTERY_DB") or ".battery_history.db")
    local db_ptr = ffi.new("sqlite3*[1]")

    local rc = sqlite.sqlite3_open(db_file, db_ptr)
    if rc ~= SQLITE_OK then
        local err_text = "Unknown error"
        if db_ptr[0] ~= nil then
            err_text = ffi.string(sqlite.sqlite3_errmsg(db_ptr[0]))
            sqlite.sqlite3_close(db_ptr[0])
        end
        return nil, string.format("Failed to open SQLite DB '%s': %s (code: %d)", db_file, err_text, rc)
    end

    local self_inst = setmetatable({
        db = db_ptr[0],
        db_file = db_file
    }, BatteryDB)

    local ok_schema, schema_err = self_inst:init_schema()
    if not ok_schema then
        self_inst:close()
        return nil, schema_err
    end

    return self_inst
end

function BatteryDB:init_schema()
    local sql = [[
        CREATE TABLE IF NOT EXISTS battery_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp INTEGER NOT NULL,
            capacity INTEGER NOT NULL,
            status TEXT NOT NULL,
            voltage_v REAL NOT NULL,
            power_w REAL NOT NULL,
            energy_wh REAL NOT NULL,
            health_pct REAL NOT NULL,
            cycle_count INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_battery_timestamp ON battery_snapshots(timestamp);
    ]]
    local rc = sqlite.sqlite3_exec(self.db, sql, nil, nil, nil)
    if rc ~= SQLITE_OK then
        return false, "Failed to initialize schema: " .. self:errmsg()
    end
    return true
end

function BatteryDB:errmsg()
    if self.db ~= nil then
        local msg = sqlite.sqlite3_errmsg(self.db)
        if msg ~= nil then
            return ffi.string(msg)
        end
    end
    return "Unknown SQLite error"
end

function BatteryDB:insert_snapshot(info)
    local sql = string.format([[
        INSERT INTO battery_snapshots
        (timestamp, capacity, status, voltage_v, power_w, energy_wh, health_pct, cycle_count)
        VALUES (%d, %d, '%s', %.4f, %.4f, %.4f, %.2f, %d);
    ]], info.timestamp, info.capacity, info.status, info.voltage_v, info.power_w,
        info.energy_wh, info.health_pct, info.cycle_count)

    local rc = sqlite.sqlite3_exec(self.db, sql, nil, nil, nil)
    if rc ~= SQLITE_OK then
        return false, "Failed to insert snapshot: " .. self:errmsg()
    end
    return true
end

function BatteryDB:get_history(since_timestamp, limit)
    local sql
    if since_timestamp and since_timestamp > 0 then
        sql = string.format([[
            SELECT timestamp, capacity, status, voltage_v, power_w, energy_wh, health_pct, cycle_count
            FROM battery_snapshots
            WHERE timestamp >= %d
            ORDER BY timestamp ASC;
        ]], since_timestamp)
    else
        local lim = limit or 100
        sql = string.format([[
            SELECT timestamp, capacity, status, voltage_v, power_w, energy_wh, health_pct, cycle_count
            FROM (
                SELECT timestamp, capacity, status, voltage_v, power_w, energy_wh, health_pct, cycle_count
                FROM battery_snapshots
                ORDER BY timestamp DESC
                LIMIT %d
            ) ORDER BY timestamp ASC;
        ]], lim)
    end

    local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_ptr, nil)
    if rc ~= SQLITE_OK then
        return nil, "Prepare failed: " .. self:errmsg()
    end

    local stmt = stmt_ptr[0]
    local records = {}

    while sqlite.sqlite3_step(stmt) == SQLITE_ROW do
        local ts = tonumber(sqlite.sqlite3_column_int64(stmt, 0))
        local cap = tonumber(sqlite.sqlite3_column_int(stmt, 1))

        local c_status = sqlite.sqlite3_column_text(stmt, 2)
        local status_str = "Unknown"
        if c_status ~= nil then
            status_str = ffi.string(c_status)
        end

        local volt = tonumber(sqlite.sqlite3_column_double(stmt, 3))
        local pwr = tonumber(sqlite.sqlite3_column_double(stmt, 4))
        local eng = tonumber(sqlite.sqlite3_column_double(stmt, 5))
        local hlth = tonumber(sqlite.sqlite3_column_double(stmt, 6))
        local cyc = tonumber(sqlite.sqlite3_column_int(stmt, 7))

        records[#records + 1] = {
            timestamp = ts,
            capacity = cap,
            status = status_str,
            voltage_v = volt,
            power_w = pwr,
            energy_wh = eng,
            health_pct = hlth,
            cycle_count = cyc,
        }
    end

    sqlite.sqlite3_finalize(stmt)
    return records
end

function BatteryDB:count_records()
    local sql = "SELECT COUNT(*) FROM battery_snapshots;"
    local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite.sqlite3_prepare_v2(self.db, sql, #sql, stmt_ptr, nil)
    if rc ~= SQLITE_OK then
        return 0
    end
    local stmt = stmt_ptr[0]
    local count = 0
    if sqlite.sqlite3_step(stmt) == SQLITE_ROW then
        count = tonumber(sqlite.sqlite3_column_int64(stmt, 0))
    end
    sqlite.sqlite3_finalize(stmt)
    return count
end

function BatteryDB:close()
    if self.db ~= nil then
        sqlite.sqlite3_close(self.db)
        self.db = nil
    end
end

-- ============================================================================
-- Section 4: Terminal Unicode Plotter (Sparklines & Braille/Block Charts)
-- ============================================================================
local Plotter = {}

Plotter.BLOCKS = { " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

Plotter.RESET   = "\27[0m"
Plotter.BOLD    = "\27[1m"
Plotter.RED     = "\27[31m"
Plotter.GREEN   = "\27[32m"
Plotter.YELLOW  = "\27[33m"
Plotter.BLUE    = "\27[34m"
Plotter.CYAN    = "\27[36m"
Plotter.GRAY    = "\27[90m"
Plotter.REVERSE = "\27[7m"

function Plotter.colorize(text, color)
    return color .. text .. Plotter.RESET
end

function Plotter.capacity_color(pct)
    if pct >= 70 then
        return Plotter.GREEN
    elseif pct >= 30 then
        return Plotter.YELLOW
    else
        return Plotter.RED
    end
end

function Plotter.sparkline(values, min_val, max_val)
    if not values or #values == 0 then
        return ""
    end
    local min_v = min_val
    local max_v = max_val
    if not min_v or not max_v then
        min_v = values[1]
        max_v = values[1]
        for _, v in ipairs(values) do
            if v < min_v then min_v = v end
            if v > max_v then max_v = v end
        end
    end
    local range = max_v - min_v
    if range <= 0 then
        range = 1
    end

    local chars = {}
    for _, v in ipairs(values) do
        local normalized = math.max(0, math.min(1, (v - min_v) / range))
        local idx = math.floor(normalized * 8) + 1
        idx = math.max(1, math.min(9, idx))
        chars[#chars + 1] = Plotter.BLOCKS[idx]
    end
    return table.concat(chars)
end

function Plotter.build_chart_matrix(records, width, height)
    width = math.max(10, width)
    height = math.max(3, height)

    if not records or #records < 2 then
        return nil, "Need at least 2 snapshots to plot history"
    end

    local min_ts = records[1].timestamp
    local max_ts = records[#records].timestamp
    local time_span = max_ts - min_ts
    if time_span <= 0 then
        time_span = 1
    end

    local buckets = {}
    local bucket_weights = {}
    local bucket_records = {}
    for i = 1, width do
        buckets[i] = 0
        bucket_weights[i] = 0
        bucket_records[i] = nil
    end

    for _, r in ipairs(records) do
        local progress = (r.timestamp - min_ts) / time_span
        local col = math.floor(progress * (width - 1)) + 1
        col = math.max(1, math.min(width, col))

        buckets[col] = buckets[col] + r.capacity
        bucket_weights[col] = bucket_weights[col] + 1
        bucket_records[col] = r
    end

    local last_valid = records[1].capacity
    local last_rec = records[1]
    for i = 1, width do
        if bucket_weights[i] > 0 then
            buckets[i] = buckets[i] / bucket_weights[i]
            last_valid = buckets[i]
            last_rec = bucket_records[i]
        else
            buckets[i] = last_valid
            bucket_records[i] = last_rec
        end
    end

    return {
        buckets = buckets,
        records = bucket_records,
        min_ts = min_ts,
        max_ts = max_ts,
        time_span = time_span,
        width = width,
        height = height
    }
end

function Plotter.render_chart(records, width, height, scrub_col)
    width = width or 64
    height = height or 8

    local matrix, err = Plotter.build_chart_matrix(records, width, height)
    if not matrix then
        return "  " .. Plotter.colorize("(" .. err .. ")", Plotter.GRAY)
    end

    local lines = {}
    local buckets = matrix.buckets

    for row = height, 1, -1 do
        local row_pct_high = (row / height) * 100.0
        local row_pct_low = ((row - 1) / height) * 100.0

        local label
        if row == height then
            label = "100% "
        elseif row == math.floor(height * 0.75) then
            label = " 75% "
        elseif row == math.floor(height * 0.5) then
            label = " 50% "
        elseif row == math.floor(height * 0.25) then
            label = " 25% "
        elseif row == 1 then
            label = "  0% "
        else
            label = "     "
        end

        local line_chars = {}
        for col = 1, width do
            local val = buckets[col]
            local char
            local color = Plotter.capacity_color(val)

            if scrub_col and scrub_col == col then
                color = Plotter.BOLD .. Plotter.CYAN
            end

            if val >= row_pct_high then
                char = "█"
            elseif val <= row_pct_low then
                char = " "
            else
                local frac = (val - row_pct_low) / (row_pct_high - row_pct_low)
                local b_idx = math.floor(frac * 8) + 1
                b_idx = math.max(1, math.min(9, b_idx))
                char = Plotter.BLOCKS[b_idx]
            end

            line_chars[#line_chars + 1] = color .. char .. Plotter.RESET
        end

        lines[#lines + 1] = Plotter.GRAY .. label .. "│" .. Plotter.RESET .. table.concat(line_chars)
    end

    -- X-Axis border
    local axis_dashes = {}
    for col = 1, width do
        if scrub_col and scrub_col == col then
            axis_dashes[#axis_dashes + 1] = "┬"
        else
            axis_dashes[#axis_dashes + 1] = "─"
        end
    end
    lines[#lines + 1] = Plotter.GRAY .. "     └" .. table.concat(axis_dashes) .. "►" .. Plotter.RESET

    -- Time labels across X-axis
    local t_start = os.date("%H:%M", matrix.min_ts)
    local t_mid = os.date("%H:%M", math.floor(matrix.min_ts + matrix.time_span / 2))
    local t_end = os.date("%H:%M", matrix.max_ts)

    local spacing_half = math.floor((width - #t_start - #t_end - #t_mid) / 2)
    spacing_half = math.max(1, spacing_half)

    local time_line = "      " .. t_start .. string.rep(" ", spacing_half) .. t_mid .. string.rep(" ", spacing_half) .. t_end
    lines[#lines + 1] = Plotter.GRAY .. time_line .. Plotter.RESET

    return table.concat(lines, "\n")
end

-- ============================================================================
-- Section 5: Terminal Manager (POSIX Raw Mode, Sizing & Input Decoding)
-- ============================================================================
local Term = {
    orig_termios = nil,
    in_raw_mode = false,
}

-- Block SIGHUP/SIGINT/SIGTERM while the TUI owns the terminal. They stay pending and are polled
-- by Term.termination_requested(), so the main loop can exit and restore the screen first.
-- (Running Lua code inside an async signal handler is unsafe, so we never install one.)
function Term.block_signals()
    local set = ffi.new("sigset_t[1]")
    ffi.C.sigemptyset(set)
    for _, sig in ipairs(DEFERRED_SIGNALS) do
        ffi.C.sigaddset(set, sig)
    end
    Term.sigset = set
    ffi.C.sigprocmask(SIG_BLOCK, set, nil)
end

function Term.termination_requested()
    if not Term.sigset then
        return false
    end
    local pending = ffi.new("sigset_t[1]")
    if ffi.C.sigpending(pending) ~= 0 then
        return false
    end
    for _, sig in ipairs(DEFERRED_SIGNALS) do
        if ffi.C.sigismember(pending, sig) == 1 then
            return true
        end
    end
    return false
end

-- Unblock the deferred signals. A signal that arrived while blocked is delivered here and
-- terminates the process with its default action, which is the correct exit status for
-- `kill`. Call this only after the terminal is restored and the database is closed.
function Term.release_signals()
    if Term.sigset then
        local set = Term.sigset
        Term.sigset = nil
        ffi.C.sigprocmask(SIG_UNBLOCK, set, nil)
    end
end

function Term.enable_raw_mode()
    if Term.in_raw_mode then
        return true
    end

    local orig = ffi.new("struct termios")
    if ffi.C.tcgetattr(STDIN_FD, orig) ~= 0 then
        return false, "Failed to retrieve terminal termios attributes"
    end
    Term.orig_termios = orig

    local raw = ffi.new("struct termios")
    ffi.copy(raw, orig, ffi.sizeof("struct termios"))

    -- Disable canonical mode, echo and ISIG (so Ctrl+C arrives as "\3" and is handled by the
    -- key dispatcher, letting us restore the terminal); preserve OPOST so \n expands to \r\n.
    raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG)))
    raw.c_cc[5] = 0 -- VTIME
    raw.c_cc[6] = 1 -- VMIN

    if ffi.C.tcsetattr(STDIN_FD, TCSANOW, raw) ~= 0 then
        return false, "Failed to apply raw terminal mode"
    end

    Term.block_signals()
    Term.in_raw_mode = true
    -- Switch to alternate screen, hide cursor, disable auto-wrap
    io.write("\27[?1049h\27[?25l\27[?7l")
    io.flush()
    return true
end

function Term.restore()
    if not Term.in_raw_mode then
        return
    end

    -- Restore wrap, restore cursor, exit alternate screen
    io.write("\27[?7h\27[?25h\27[?1049l")
    io.flush()

    if Term.orig_termios ~= nil then
        ffi.C.tcsetattr(STDIN_FD, TCSANOW, Term.orig_termios)
        Term.orig_termios = nil
    end

    Term.in_raw_mode = false
end

function Term.get_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(STDOUT_FD, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    if ffi.C.ioctl(STDIN_FD, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 80, 24
end

-- Pure decoder: raw byte sequence from the terminal -> symbolic key token.
-- Unrecognised escape sequences return nil so they are ignored instead of being
-- misread as a lone ESC (which quits the app).
function Term.decode_sequence(seq)
    if seq == "\27[A" or seq == "\27OA" then
        return "UP"
    elseif seq == "\27[B" or seq == "\27OB" then
        return "DOWN"
    elseif seq == "\27[C" or seq == "\27OC" then
        return "RIGHT"
    elseif seq == "\27[D" or seq == "\27OD" then
        return "LEFT"
    elseif seq == "\27[H" or seq == "\27[1~" then
        return "HOME"
    elseif seq == "\27[F" or seq == "\27[4~" then
        return "END"
    elseif seq == "\27[5~" then
        return "PAGEUP"
    elseif seq == "\27[6~" then
        return "PAGEDOWN"
    elseif seq == "\t" then
        return "TAB"
    elseif seq == "\r" or seq == "\n" then
        return "ENTER"
    elseif seq == "\27" then
        return "ESC"
    elseif seq == "\127" or seq == "\8" then
        return "BACKSPACE"
    elseif seq == " " then
        return "SPACE"
    elseif seq == "\3" then
        return "CTRL_C"
    elseif seq:sub(1, 1) == "\27" then
        return nil
    end
    return seq:sub(1, 1)
end

function Term.read_key(timeout_ms)
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = STDIN_FD
    pfd[0].events = POLLIN
    pfd[0].revents = 0

    local n = ffi.C.poll(pfd, 1, timeout_ms or 0)
    if n > 0 and bit.band(pfd[0].revents, POLLIN) ~= 0 then
        local buf = ffi.new("char[32]")
        local r = ffi.C.read(STDIN_FD, buf, 32)
        if r > 0 then
            return Term.decode_sequence(ffi.string(buf, r))
        end
    end
    return nil
end

-- ============================================================================
-- Section 6: Pure Frame Generators & TUI Rendering Engine
-- ============================================================================
local TUI = {}

TUI.MIN_COLS = 40
TUI.MIN_ROWS = 12
TUI.PLOT_WINDOWS = { 1, 6, 12, 24, 168 }

local function visible_width(str)
    local clean = str:gsub("\27%[[%d;]*%a", "")
    local count = 0
    for i = 1, #clean do
        local b = clean:byte(i)
        if b < 0x80 or b >= 0xC0 then
            count = count + 1
        end
    end
    return count
end

-- Truncate text to at most max_cols visible columns, keeping ANSI escapes intact and never
-- splitting a multi-byte UTF-8 character. Appends a reset if anything was cut off.
local function truncate_visible(text, max_cols)
    if visible_width(text) <= max_cols then
        return text
    end

    local out = {}
    local cols = 0
    local pos = 1
    local len = #text
    local kept_escape = false
    while pos <= len and cols < max_cols do
        local esc = text:match("^\27%[[%d;]*%a", pos)
        if esc then
            out[#out + 1] = esc
            kept_escape = true
            pos = pos + #esc
        else
            local b = text:byte(pos)
            local char_len = 1
            if b >= 0xF0 then
                char_len = 4
            elseif b >= 0xE0 then
                char_len = 3
            elseif b >= 0xC0 then
                char_len = 2
            end
            out[#out + 1] = text:sub(pos, pos + char_len - 1)
            pos = pos + char_len
            cols = cols + 1
        end
    end
    if kept_escape then
        out[#out + 1] = "\27[0m"
    end
    return table.concat(out)
end

-- Fit text to exactly inner_width visible columns (truncating or right-padding).
local function pad_box_row(inner_text, inner_width)
    local fitted = truncate_visible(inner_text, math.max(0, inner_width))
    local pad = inner_width - visible_width(fitted)
    if pad <= 0 then
        return fitted
    end
    return fitted .. string.rep(" ", pad)
end

function TUI.reload_data(state, db)
    state.info = BatteryReader.read_info()
    state.total_db_count = db:count_records()

    local hours = state.plot_hours or 24
    local since = os.time() - (hours * 3600)
    local records, err = db:get_history(since)
    if not err and records then
        state.records = records
    else
        state.records = {}
    end
end

function TUI.render_dashboard(state, inner_w, inner_h)
    local lines = {}
    local info = state.info

    if not info then
        lines[#lines + 1] = ""
        lines[#lines + 1] = Plotter.YELLOW .. "  [!] No hardware battery detected in /sys/class/power_supply" .. Plotter.RESET
        lines[#lines + 1] = Plotter.GRAY .. "      Press [s] to seed 24 hours of synthetic telemetry." .. Plotter.RESET
        lines[#lines + 1] = ""
        return lines
    end

    -- Status header line
    local status_badge = Plotter.CYAN .. "[" .. info.status .. "]" .. Plotter.RESET
    if info.status == "Charging" then
        status_badge = Plotter.GREEN .. "[+ CHARGING]" .. Plotter.RESET
    elseif info.status == "Discharging" then
        status_badge = Plotter.YELLOW .. "[- DISCHARGING]" .. Plotter.RESET
    elseif info.status == "Full" then
        status_badge = Plotter.GREEN .. "[* FULL (AC)]" .. Plotter.RESET
    end

    local model_str = string.format("%s %s (%s)", info.manufacturer, info.model_name, info.technology)
    lines[#lines + 1] = string.format(" Status: %s    Hardware: %s", status_badge, model_str)

    -- Large Capacity Bar
    local bar_w = math.max(16, math.min(inner_w - 24, 50))
    local filled = math.floor((info.capacity / 100.0) * bar_w)
    local bar_str = string.rep("█", filled) .. string.rep("░", bar_w - filled)
    local colored_bar = Plotter.capacity_color(info.capacity) .. bar_str .. Plotter.RESET

    lines[#lines + 1] = string.format(" Capacity: %s%3d%%%s [%s]",
        Plotter.capacity_color(info.capacity), info.capacity, Plotter.RESET, colored_bar)
    lines[#lines + 1] = ""

    -- Two-Column Telemetry Box
    local col_w = math.floor((inner_w - 4) / 2)
    local p_title_1 = "┌─ HARDWARE TELEMETRY " .. string.rep("─", math.max(0, col_w - 23)) .. "┐"
    local p_title_2 = "┌─ LIFETIME & HEALTH " .. string.rep("─", math.max(0, col_w - 22)) .. "┐"
    lines[#lines + 1] = Plotter.GRAY .. pad_box_row(p_title_1, col_w) .. "  " .. pad_box_row(p_title_2, col_w) .. Plotter.RESET

    local rows_l = {
        string.format("│ Power Rate:   %s%.2f W%s",
            info.power_w > 0 and Plotter.YELLOW or Plotter.GREEN, info.power_w, Plotter.RESET),
        string.format("│ Voltage:      %.2f V", info.voltage_v),
        string.format("│ Energy Now:   %.2f Wh", info.energy_wh),
        string.format("│ Energy Full:  %.2f Wh", info.energy_full_wh),
        string.format("│ Path:         %s", info.path or "N/A"),
    }

    local rows_r = {
        string.format("│ Health:       %s%.1f%%%s",
            info.health_pct >= 80 and Plotter.GREEN or Plotter.YELLOW, info.health_pct, Plotter.RESET),
        string.format("│ Design Full:  %.2f Wh", info.energy_design_wh),
        string.format("│ Cycle Count:  %d cycles", info.cycle_count),
        string.format("│ DB Snapshots: %d recorded", state.total_db_count),
        string.format("│ Polling:      Every %.1fs", state.poll_interval),
    }

    for i = 1, #rows_l do
        local l_str = rows_l[i]
        local r_str = rows_r[i]
        local l_padded = pad_box_row(l_str, col_w - 1) .. Plotter.GRAY .. "│" .. Plotter.RESET
        local r_padded = pad_box_row(r_str, col_w - 1) .. Plotter.GRAY .. "│" .. Plotter.RESET
        lines[#lines + 1] = l_padded .. "  " .. r_padded
    end

    local p_bot_1 = "└" .. string.rep("─", col_w - 2) .. "┘"
    local p_bot_2 = "└" .. string.rep("─", col_w - 2) .. "┘"
    lines[#lines + 1] = Plotter.GRAY .. pad_box_row(p_bot_1, col_w) .. "  " .. pad_box_row(p_bot_2, col_w) .. Plotter.RESET
    lines[#lines + 1] = ""

    -- Recent 24h Inline Sparkline
    if state.records and #state.records >= 2 then
        local spark_vals = {}
        for _, r in ipairs(state.records) do
            spark_vals[#spark_vals + 1] = r.capacity
        end
        local spark_str = Plotter.sparkline(spark_vals, 0, 100)
        lines[#lines + 1] = Plotter.BOLD .. " Recent 24h Capacity Trend:" .. Plotter.RESET
        lines[#lines + 1] = " [" .. spark_str .. "]"
    end

    return lines
end

function TUI.render_plot(state, inner_w, inner_h)
    local lines = {}
    local chart_w = math.max(20, inner_w - 8)
    local chart_h = math.max(4, inner_h - 7)

    state.chart_cols = chart_w

    local hours_label = string.format(
        "Time Window: %d Hours (%d snapshots in window) | [ / ] change window: 1h 6h 12h 24h 7d",
        state.plot_hours, #state.records)
    lines[#lines + 1] = Plotter.BOLD .. hours_label .. Plotter.RESET

    if not state.records or #state.records < 2 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = Plotter.GRAY .. "  (Need at least 2 snapshots in window to render 2D plot. Press [s] to seed data or [r] to record)" .. Plotter.RESET
        return lines
    end

    local matrix = Plotter.build_chart_matrix(state.records, chart_w, chart_h)
    if not matrix then
        lines[#lines + 1] = Plotter.GRAY .. "  (Failed to compute chart matrix)" .. Plotter.RESET
        return lines
    end

    local scrub_col = state.scrub_col
    if scrub_col and scrub_col >= 1 and scrub_col <= chart_w then
        local r = matrix.records[scrub_col]
        if r then
            local t_str = os.date("%Y-%m-%d %H:%M:%S", r.timestamp)
            local cap_color = Plotter.capacity_color(r.capacity)
            lines[#lines + 1] = string.format(" Scrub [%d/%d]: %s │ Cap: %s%3d%%%s │ Volt: %.2fV │ Power: %.2fW │ Status: %s",
                scrub_col, chart_w, t_str, cap_color, r.capacity, Plotter.RESET, r.voltage_v, r.power_w, r.status)
        else
            lines[#lines + 1] = string.format(" Scrub [%d/%d]: [←/→ h/l] Scrub timeline │ [0] Start │ [$] End", scrub_col, chart_w)
        end
    else
        lines[#lines + 1] = " [←/→ h/l] Scrub timeline cursor │ [0] Start │ [$] End │ [r] Record snapshot"
    end

    lines[#lines + 1] = ""
    local chart_str = Plotter.render_chart(state.records, chart_w, chart_h, scrub_col)
    for line in chart_str:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end

    return lines
end

function TUI.render_history(state, inner_w, inner_h)
    local lines = {}
    local total = #state.records

    local header_info = string.format(" Snapshot Log: %d snapshots in view (%d total in DB) ── [↑/↓] Navigate  [PgUp/PgDn] Page",
        total, state.total_db_count)
    lines[#lines + 1] = Plotter.BOLD .. header_info .. Plotter.RESET

    local table_header = string.format("   %-19s │ %-8s │ %-12s │ %-8s │ %-8s │ %-6s",
        "Timestamp", "Capacity", "Status", "Voltage", "Power", "Health")
    lines[#lines + 1] = Plotter.CYAN .. table_header .. Plotter.RESET
    lines[#lines + 1] = Plotter.GRAY .. string.rep("─", math.min(inner_w, visible_width(table_header) + 2)) .. Plotter.RESET

    if total == 0 then
        lines[#lines + 1] = "   (No historical snapshots found in database. Press [r] to record or [s] to seed)"
        return lines
    end

    local max_visible = math.max(3, inner_h - 4)
    state.log_scroll = math.max(1, math.min(total, state.log_scroll or total))

    local start_idx = math.max(1, state.log_scroll - math.floor(max_visible / 2))
    local end_idx = math.min(total, start_idx + max_visible - 1)
    if end_idx - start_idx + 1 < max_visible then
        start_idx = math.max(1, end_idx - max_visible + 1)
    end

    for idx = start_idx, end_idx do
        local r = state.records[idx]
        local is_sel = (idx == state.log_scroll)
        local marker = is_sel and "▶ " or "  "
        local cap_color = Plotter.capacity_color(r.capacity)

        local row_str = string.format("%s%-19s │ %s%7d%%%s │ %-12s │ %6.2f V │ %6.2f W │ %5.1f%%",
            marker,
            os.date("%Y-%m-%d %H:%M:%S", r.timestamp),
            cap_color, r.capacity, Plotter.RESET,
            r.status, r.voltage_v, r.power_w, r.health_pct)

        if is_sel then
            lines[#lines + 1] = Plotter.REVERSE .. Plotter.BOLD .. row_str .. Plotter.RESET
        else
            lines[#lines + 1] = row_str
        end
    end

    return lines
end

TUI.HELP_ENTRIES = {
    { "[Tab] / [1-3]", "Switch views (Dashboard, Plot, Log)" },
    { "[r]", "Record snapshot to SQLite database" },
    { "[s]", "Seed 24h synthetic telemetry (press twice)" },
    { "[+] / [-]", "Adjust telemetry polling rate" },
    { "[←] [→] / h l", "Scrub timeline cursor (Plot view)" },
    { "[ and ]", "Change history time window (Plot view)" },
    { "[↑] [↓] / j k", "Scroll rows (Snapshot Log view)" },
    { "[?] / [Esc]", "Close this help window" },
    { "[q] / [Ctrl+C]", "Quit Battery Monitor" },
}

-- Pure generator: returns the help box as an array of strings, each exactly box_w visible
-- columns wide. Degrades gracefully (drops spacer rows, then truncates the list) when the
-- available height is small.
function TUI.build_help_lines(box_w, avail_h)
    local inner = box_w - 2
    local entries = TUI.HELP_ENTRIES
    if inner < 1 or avail_h < 3 then
        return {}
    end

    local title = " BATTERY MONITOR HELP "
    local fill = math.max(0, inner - visible_width(title))
    local left_fill = math.floor(fill / 2)
    local top = "┌" .. string.rep("─", left_fill) .. title .. string.rep("─", fill - left_fill) .. "┐"
    local bottom = "└" .. string.rep("─", inner) .. "┘"

    local function body_row(text)
        return "│" .. pad_box_row(text, inner) .. "│"
    end

    local with_extras = avail_h >= #entries + 5
    local shown = #entries
    local truncated = false
    if not with_extras and shown > avail_h - 2 then
        shown = math.max(0, avail_h - 3)
        truncated = true
    end

    local lines = { pad_box_row(top, box_w) }
    if with_extras then
        lines[#lines + 1] = body_row("")
    end
    for i = 1, shown do
        local key_text = entries[i][1]
        local gap = string.rep(" ", math.max(1, 16 - visible_width(key_text)))
        lines[#lines + 1] = body_row("  " .. key_text .. gap .. entries[i][2])
    end
    if truncated then
        lines[#lines + 1] = body_row("  ... (enlarge terminal for full help)")
    end
    if with_extras then
        lines[#lines + 1] = body_row("")
        lines[#lines + 1] = body_row("   Press [Esc] or [?] to close")
    end
    lines[#lines + 1] = bottom
    return lines
end

function TUI.overlay_modal(lines, target_w, target_h)
    -- Rows 2 .. target_h-1 are available (top and bottom frame borders stay visible)
    local avail_h = target_h - 2
    local box_w = math.min(60, target_w - 4)
    local modal_lines = TUI.build_help_lines(box_w, avail_h)
    if #modal_lines == 0 then
        return
    end

    local start_row = math.max(2, math.floor((target_h - #modal_lines) / 2) + 1)
    local left_pad = string.rep(" ", math.max(0, math.floor((target_w - 4 - box_w) / 2)))

    for i = 1, #modal_lines do
        local line_idx = start_row + i - 1
        if line_idx <= target_h - 1 then
            local m_text = Plotter.YELLOW .. left_pad .. modal_lines[i] .. Plotter.RESET
            lines[line_idx] = string.format("\27[%d;1H%s│ %s │%s\27[K",
                line_idx, Plotter.CYAN, pad_box_row(m_text, target_w - 4), Plotter.RESET)
        end
    end
end

-- Pure generator for terminals below the minimum supported size. Overwrites every row so
-- no stale content from a previous (larger) layout remains.
function TUI.render_too_small_frame(cols, rows)
    local messages = {
        "Terminal too small",
        string.format("Need %dx%d, have %dx%d", TUI.MIN_COLS, TUI.MIN_ROWS, cols, rows),
        "Resize, or press [q] to quit",
    }
    local width = math.max(1, cols - 1)
    local out = {}
    for row = 1, math.max(1, rows) do
        local text = messages[row]
        if text then
            out[#out + 1] = string.format("\27[%d;1H%s%s%s\27[K",
                row, Plotter.BOLD .. Plotter.YELLOW, text:sub(1, width), Plotter.RESET)
        else
            out[#out + 1] = string.format("\27[%d;1H\27[K", row)
        end
    end
    return table.concat(out)
end

function TUI.render_frame(state, cols, rows)
    if cols < TUI.MIN_COLS or rows < TUI.MIN_ROWS then
        return TUI.render_too_small_frame(cols, rows)
    end

    local target_w = math.max(40, cols - 1)
    local target_h = math.max(12, rows)
    local inner_w = target_w - 4

    local lines = {}
    local cur_row = 1

    local function add_row(content)
        if cur_row <= target_h then
            -- Safety net: no row may ever exceed the frame width (auto-wrap is disabled)
            content = truncate_visible(content, target_w)
            lines[#lines + 1] = string.format("\27[%d;1H%s\27[K", cur_row, content)
            cur_row = cur_row + 1
        end
    end

    -- Row 1: Top border with title, poll rate, clock
    local title = " BATTERY MONITOR (LuaJIT FFI) "
    local interval_str = string.format(" [Live %.1fs] ", state.poll_interval)
    local now_str = " " .. os.date("%Y-%m-%d %H:%M:%S") .. " "
    local function top_fixed_width()
        return 6 + visible_width(title) + visible_width(interval_str) + visible_width(now_str)
    end
    -- Narrow terminals: drop the clock, then the poll rate, then shorten the title
    if top_fixed_width() > target_w then
        now_str = ""
    end
    if top_fixed_width() > target_w then
        interval_str = ""
    end
    if top_fixed_width() > target_w then
        title = " BATTERY MONITOR "
    end
    local top_fill = math.max(0, target_w - top_fixed_width())
    local top_dashes = string.rep("─", top_fill)
    add_row(Plotter.CYAN .. "┌─" .. Plotter.BOLD .. title .. Plotter.RESET .. Plotter.CYAN .. "─" .. interval_str .. "─" .. top_dashes .. now_str .. "─┐" .. Plotter.RESET)

    -- Row 2: Tab Bar
    local t1 = (state.tab == 1 and (Plotter.BOLD .. Plotter.CYAN .. "[1] DASHBOARD" .. Plotter.RESET) or (Plotter.GRAY .. "[1] Dashboard" .. Plotter.RESET))
    local t2 = (state.tab == 2 and (Plotter.BOLD .. Plotter.CYAN .. "[2] HISTORY PLOT" .. Plotter.RESET) or (Plotter.GRAY .. "[2] History Plot" .. Plotter.RESET))
    local t3 = (state.tab == 3 and (Plotter.BOLD .. Plotter.CYAN .. "[3] SNAPSHOT LOG" .. Plotter.RESET) or (Plotter.GRAY .. "[3] Snapshot Log" .. Plotter.RESET))
    local tabs_str = string.format("  %s    │    %s    │    %s", t1, t2, t3)
    add_row(Plotter.CYAN .. "│ " .. Plotter.RESET .. pad_box_row(tabs_str, inner_w) .. Plotter.CYAN .. " │" .. Plotter.RESET)

    -- Row 3: Tab Divider
    add_row(Plotter.CYAN .. "├" .. string.rep("─", target_w - 2) .. "┤" .. Plotter.RESET)

    -- Body Rows
    local body_h = target_h - 6
    local body_lines = {}
    if state.tab == 1 then
        body_lines = TUI.render_dashboard(state, inner_w, body_h)
    elseif state.tab == 2 then
        body_lines = TUI.render_plot(state, inner_w, body_h)
    else
        body_lines = TUI.render_history(state, inner_w, body_h)
    end

    for i = 1, body_h do
        local content = body_lines[i] or ""
        add_row(Plotter.CYAN .. "│ " .. Plotter.RESET .. pad_box_row(content, inner_w) .. Plotter.CYAN .. " │" .. Plotter.RESET)
    end

    -- Footer Row N-2: Divider
    add_row(Plotter.CYAN .. "├" .. string.rep("─", target_w - 2) .. "┤" .. Plotter.RESET)

    -- Footer Row N-1: Toast / Status
    local now_sec = os.time()
    local toast
    if state.toast_msg and now_sec <= state.toast_expire then
        toast = Plotter.BOLD .. Plotter.GREEN .. state.toast_msg .. Plotter.RESET
    else
        local db_name = state.db and state.db.db_file or ".battery_history.db"
        toast = Plotter.GRAY .. "Database: " .. db_name .. " (" .. state.total_db_count .. " snapshots recorded) │ Press [?] for keybindings" .. Plotter.RESET
    end
    add_row(Plotter.CYAN .. "│ " .. Plotter.RESET .. pad_box_row(toast, inner_w) .. Plotter.CYAN .. " │" .. Plotter.RESET)

    -- Footer Row N: Hotkey Bar
    local hotkeys = "[Tab] View  [r] Record  [s] Seed  [+/-] Rate  [?] Help  [q] Quit"
    if 7 + visible_width(hotkeys) > target_w then
        hotkeys = "[Tab] [r] [s] [+/-] [?] [q]"
    end
    local fixed_bot = 7 + visible_width(hotkeys)
    local bot_fill = target_w - fixed_bot
    if bot_fill < 0 then bot_fill = 0 end
    add_row(Plotter.CYAN .. "└─── " .. Plotter.BOLD .. hotkeys .. Plotter.RESET .. Plotter.CYAN .. " " .. string.rep("─", bot_fill) .. "┘" .. Plotter.RESET)

    if state.show_help then
        TUI.overlay_modal(lines, target_w, target_h)
    end

    return table.concat(lines)
end

function TUI.handle_key(state, key, db)
    if key == "CTRL_C" then
        state.running = false
        return true
    end

    if state.show_help then
        if key == "ESC" or key == "?" or key == "ENTER" or key == "q" then
            state.show_help = false
            return true
        end
        return false
    end

    if key == "q" or key == "ESC" then
        state.running = false
        return true
    elseif key == "TAB" then
        state.tab = (state.tab % 3) + 1
        return true
    elseif key == "1" or key == "2" or key == "3" then
        state.tab = tonumber(key)
        return true
    elseif (key == "[" or key == "]") and state.tab == 2 then
        local idx = 4
        for i, hours in ipairs(TUI.PLOT_WINDOWS) do
            if hours == state.plot_hours then
                idx = i
            end
        end
        if key == "[" then
            idx = math.max(1, idx - 1)
        else
            idx = math.min(#TUI.PLOT_WINDOWS, idx + 1)
        end
        state.plot_hours = TUI.PLOT_WINDOWS[idx]
        TUI.reload_data(state, db)
        return true
    elseif key == "?" then
        state.show_help = true
        return true
    elseif key == "r" or key == "R" then
        local info = BatteryReader.read_info()
        if info then
            db:insert_snapshot(info)
            state.toast_msg = string.format("[Recorded snapshot at %s: %d%% (%s)]",
                os.date("%H:%M:%S", info.timestamp), info.capacity, info.status)
            state.toast_expire = os.time() + 3
            TUI.reload_data(state, db)
        else
            state.toast_msg = "[Failed to query hardware battery info]"
            state.toast_expire = os.time() + 3
        end
        return true
    elseif key == "s" or key == "S" then
        cmd_seed(db)
        state.toast_msg = "[Successfully seeded 144 synthetic snapshots]"
        state.toast_expire = os.time() + 3
        TUI.reload_data(state, db)
        return true
    elseif key == "+" or key == "=" then
        if state.poll_interval > 0.5 then
            state.poll_interval = state.poll_interval / 2
        end
        state.toast_msg = string.format("[Polling rate set to %.1fs]", state.poll_interval)
        state.toast_expire = os.time() + 2
        return true
    elseif key == "-" or key == "_" then
        if state.poll_interval < 5.0 then
            state.poll_interval = state.poll_interval * 2
        end
        state.toast_msg = string.format("[Polling rate set to %.1fs]", state.poll_interval)
        state.toast_expire = os.time() + 2
        return true
    elseif state.tab == 2 then
        local max_c = state.chart_cols or 60
        if key == "LEFT" or key == "h" then
            state.scrub_col = math.max(1, (state.scrub_col or max_c) - 1)
            return true
        elseif key == "RIGHT" or key == "l" then
            state.scrub_col = math.min(max_c, (state.scrub_col or max_c) + 1)
            return true
        elseif key == "0" or key == "HOME" then
            state.scrub_col = 1
            return true
        elseif key == "$" or key == "END" then
            state.scrub_col = max_c
            return true
        end
    elseif state.tab == 3 then
        local total = #state.records
        if key == "UP" or key == "k" then
            state.log_scroll = math.max(1, state.log_scroll - 1)
            return true
        elseif key == "DOWN" or key == "j" then
            state.log_scroll = math.min(total, state.log_scroll + 1)
            return true
        elseif key == "PAGEUP" then
            state.log_scroll = math.max(1, state.log_scroll - 10)
            return true
        elseif key == "PAGEDOWN" then
            state.log_scroll = math.min(total, state.log_scroll + 10)
            return true
        elseif key == "HOME" then
            state.log_scroll = 1
            return true
        elseif key == "END" then
            state.log_scroll = total
            return true
        end
    end

    return false
end

function TUI.run(db)
    local ok_raw, err_raw = Term.enable_raw_mode()
    if not ok_raw then
        io.stderr:write("[ERROR] " .. tostring(err_raw) .. "\n")
        return false
    end

    local state = {
        db = db,
        tab = 1,
        show_help = false,
        info = nil,
        plot_hours = 24,
        records = {},
        total_db_count = 0,
        poll_interval = 1.0,
        last_poll_time = 0,
        toast_msg = nil,
        toast_expire = 0,
        scrub_col = nil,
        log_scroll = 1,
        running = true,
        chart_cols = 60,
    }

    TUI.reload_data(state, db)

    -- Initial screen render
    io.write("\27[2J") -- Cleared once on initial startup per standards
    local last_cols, last_rows = Term.get_size()
    local initial_frame = TUI.render_frame(state, last_cols, last_rows)
    io.write("\27[1;1H" .. initial_frame)
    io.flush()

    local needs_redraw = false

    while state.running do
        if Term.termination_requested() then
            state.running = false
            break
        end

        local now = os.time()
        if now - state.last_poll_time >= state.poll_interval then
            TUI.reload_data(state, db)
            state.last_poll_time = now
            needs_redraw = true
        end

        local cols, rows = Term.get_size()
        if cols ~= last_cols or rows ~= last_rows then
            -- Full screen clear on window resize event only
            io.write("\27[2J")
            last_cols, last_rows = cols, rows
            needs_redraw = true
        end

        if needs_redraw then
            local frame = TUI.render_frame(state, cols, rows)
            io.write("\27[1;1H" .. frame .. "\27[1;1H")
            io.flush()
            needs_redraw = false
        end

        local key = Term.read_key(50)
        if key then
            local handled = TUI.handle_key(state, key, db)
            if handled then
                needs_redraw = true
            end
        end
    end

    Term.restore()
    return true
end

-- ============================================================================
-- Section 7: CLI Dashboard & Views
-- ============================================================================
local function print_banner()
    local now_str = os.date("%Y-%m-%d %H:%M:%S")
    print(Plotter.BOLD .. Plotter.CYAN .. "================================================================================" .. Plotter.RESET)
    print(string.format("%s BATTERY MONITOR (LuaJIT FFI + SQLite3)%s  %s[%s]%s",
        Plotter.BOLD, Plotter.RESET, Plotter.GRAY, now_str, Plotter.RESET))
    print(Plotter.BOLD .. Plotter.CYAN .. "================================================================================" .. Plotter.RESET)
end

local function render_status(info)
    local status_color = Plotter.CYAN
    if info.status == "Charging" then
        status_color = Plotter.GREEN
    elseif info.status == "Discharging" then
        status_color = Plotter.YELLOW
    end

    local bar_width = 36
    local filled = math.floor((info.capacity / 100.0) * bar_width)
    local bar_str = string.rep("█", filled) .. string.rep("░", bar_width - filled)
    local colored_bar = Plotter.capacity_color(info.capacity) .. bar_str .. Plotter.RESET

    print(string.format(" Status:       [%s%s%s]", status_color, info.status, Plotter.RESET))
    print(string.format(" Capacity:     %s%3d%%%s [%s]",
        Plotter.capacity_color(info.capacity), info.capacity, Plotter.RESET, colored_bar))
    print(string.format(" Power Rate:   %s%.2f W%s%s           Voltage:   %.2f V",
        info.power_w > 0 and Plotter.YELLOW or Plotter.GREEN, info.power_w, Plotter.RESET,
        info.power_w == 0 and " (AC Connected)" or "", info.voltage_v))
    print(string.format(" Energy:       %.2f Wh / %.2f Wh   Health:    %s%.1f%%%s (Design: %.2f Wh)",
        info.energy_wh, info.energy_full_wh,
        info.health_pct >= 80 and Plotter.GREEN or Plotter.YELLOW,
        info.health_pct, Plotter.RESET, info.energy_design_wh))
    print(string.format(" Cycle Count:  %d cycles               Hardware:  %s %s (%s)",
        info.cycle_count, info.manufacturer, info.model_name, info.technology))
end

local function cmd_record(db, info)
    local ok, err = db:insert_snapshot(info)
    if not ok then
        io.stderr:write(Plotter.RED .. "[ERROR] " .. err .. Plotter.RESET .. "\n")
        return false
    end
    print(string.format("[%s] Recorded snapshot: %d%% (%s, %.2fV, %.2fW) -> %s",
        os.date("%H:%M:%S", info.timestamp), info.capacity, info.status,
        info.voltage_v, info.power_w, db.db_file))
    return true
end

local function cmd_history(db, limit)
    limit = limit or 20
    local records, err = db:get_history(nil, limit)
    if not err and records then
        print(Plotter.BOLD .. string.format("\nRecent %d Battery Snapshots (from %s):", #records, db.db_file) .. Plotter.RESET)
        print("--------------------------------------------------------------------------------")
        print(string.format(" %-19s | %-8s | %-12s | %-8s | %-8s | %-6s",
            "Timestamp", "Capacity", "Status", "Voltage", "Power", "Health"))
        print("--------------------------------------------------------------------------------")
        for _, r in ipairs(records) do
            local color = Plotter.capacity_color(r.capacity)
            print(string.format(" %-19s | %s%7d%%%s | %-12s | %6.2f V | %6.2f W | %5.1f%%",
                os.date("%Y-%m-%d %H:%M:%S", r.timestamp),
                color, r.capacity, Plotter.RESET,
                r.status, r.voltage_v, r.power_w, r.health_pct))
        end
        print("--------------------------------------------------------------------------------")
        return true
    else
        io.stderr:write(Plotter.RED .. "Failed to read history: " .. tostring(err) .. Plotter.RESET .. "\n")
        return false
    end
end

local function cmd_plot(db, hours)
    hours = hours or 24
    local since = os.time() - (hours * 3600)
    local records, err = db:get_history(since)
    if not err and records then
        local total_in_db = db:count_records()
        print(string.format("\nBattery Capacity History (Past %d Hours, %d samples in window):", hours, #records))
        print(Plotter.render_chart(records, 66, 8))
        print(string.format("\nDatabase: %s | Total Historical Records: %d", db.db_file, total_in_db))
        return true
    else
        io.stderr:write(Plotter.RED .. "Plot error: " .. tostring(err) .. Plotter.RESET .. "\n")
        return false
    end
end

cmd_seed = function(db)
    local now = os.time()
    local start = now - (24 * 3600)
    local sample_count = 144

    for i = 1, sample_count do
        local t = start + (i * 600)
        local progress = (i / sample_count) * (math.pi * 2.5)
        local cap = math.floor(55 + 40 * math.sin(progress))
        cap = math.max(5, math.min(100, cap))
        local status = (cap > 80 and "Full") or (math.sin(progress) > 0 and "Charging" or "Discharging")
        local power = (status == "Charging" and 25.5) or (status == "Discharging" and 12.0) or 0.0

        db:insert_snapshot({
            timestamp = t,
            capacity = cap,
            status = status,
            voltage_v = 11.5 + (cap / 100.0) * 1.5,
            power_w = power,
            energy_wh = 41.35 * (cap / 100.0),
            health_pct = 72.5,
            cycle_count = 195
        })
    end
end

local function run_self_tests(db)
    print("=== Running Self-Tests for battery_monitor.lua ===")

    -- Test 1: Hardware reader
    local info = BatteryReader.read_info()
    if info then
        assert(info.capacity >= 0 and info.capacity <= 100, "Invalid capacity")
        print("  [✓] Test 1 passed: Hardware reader query successful.")
    else
        print("  [!] Notice: Hardware battery not present (virtual or desktop env).")
    end

    -- Test 2: Database operations
    local count = db:count_records()
    assert(type(count) == "number", "count_records must return a number")
    print(string.format("  [✓] Test 2 passed: Database records query (%d records).", count))

    -- Test 3: Sparkline generation
    local spark = Plotter.sparkline({ 10, 20, 50, 75, 100, 40, 20 }, 0, 100)
    assert(#spark > 0, "Sparkline must not be empty")
    print("  [✓] Test 3 passed: Sparkline generation verified: [" .. spark .. "]")

    -- Test 4: Chart rendering across dimensions
    local dummy_records = {
        { timestamp = 1000, capacity = 50, status = "Full", voltage_v = 12.0, power_w = 0, health_pct = 80 },
        { timestamp = 2000, capacity = 80, status = "Charging", voltage_v = 12.5, power_w = 15, health_pct = 80 },
        { timestamp = 3000, capacity = 100, status = "Full", voltage_v = 12.8, power_w = 0, health_pct = 80 },
    }
    local chart_text = Plotter.render_chart(dummy_records, 40, 6)
    assert(#chart_text > 0, "Chart text must not be empty")
    print("  [✓] Test 4 passed: Unicode block chart rendering verified.")

    -- Test 5: TUI Frame generator boundary checks
    local state = {
        db = db,
        tab = 1,
        show_help = false,
        info = info or { capacity = 100, status = "Full", voltage_v = 12.7, power_w = 0, energy_wh = 40, energy_full_wh = 40, energy_design_wh = 50, health_pct = 80, cycle_count = 100, manufacturer = "Test", model_name = "Model", technology = "Li-ion", path = "/sys" },
        plot_hours = 24,
        records = dummy_records,
        total_db_count = count,
        poll_interval = 1.0,
        scrub_col = 15,
        log_scroll = 1,
        running = true,
        chart_cols = 40,
    }

    local f1 = TUI.render_frame(state, 80, 24)
    assert(#f1 > 0, "Frame 1 must render")
    state.tab = 2
    local f2 = TUI.render_frame(state, 60, 18)
    assert(#f2 > 0, "Frame 2 must render")
    state.tab = 3
    local f3 = TUI.render_frame(state, 100, 30)
    assert(#f3 > 0, "Frame 3 must render")
    state.show_help = true
    local f4 = TUI.render_frame(state, 80, 24)
    assert(#f4 > 0, "Frame 4 with modal must render")
    print("  [✓] Test 5 passed: TUI Frame generators validated across all tabs and boundaries.")

    -- Test 6: Key event dispatcher
    state.show_help = false
    TUI.handle_key(state, "TAB", db)
    assert(state.tab == 1, "TAB key should cycle to tab 1")
    TUI.handle_key(state, "2", db)
    assert(state.tab == 2, "2 key should switch to tab 2")
    TUI.handle_key(state, "+", db)
    assert(state.poll_interval == 0.5, "+ key should decrease poll interval")
    TUI.handle_key(state, "?", db)
    assert(state.show_help == true, "? key should open help modal")
    TUI.handle_key(state, "ESC", db)
    assert(state.show_help == false, "ESC key should close help modal")
    TUI.handle_key(state, "q", db)
    assert(state.running == false, "q key should signal quit")
    print("  [✓] Test 6 passed: Interactive key event state machine validated.")


    -- ------------------------------------------------------------------------
    -- Helpers for headless frame assertions
    -- ------------------------------------------------------------------------
    local function new_state(overrides)
        local st = {
            db = db,
            tab = 1,
            show_help = false,
            info = state.info,
            plot_hours = 24,
            records = dummy_records,
            total_db_count = count,
            poll_interval = 1.0,
            scrub_col = nil,
            log_scroll = 1,
            running = true,
            chart_cols = 40,
            toast_expire = 0,
        }
        for k, v in pairs(overrides or {}) do
            st[k] = v
        end
        return st
    end

    -- Split a frame into { [row] = content } and assert the TUI invariants:
    --   every row is cursor-addressed, ends with \27[K, and fits the terminal width.
    local function assert_frame_invariants(frame, cols, rows, label)
        local starts = {}
        for pos, row in frame:gmatch("()\27%[(%d+);1H") do
            starts[#starts + 1] = { pos = pos, row = tonumber(row) }
        end
        assert(#starts == rows, string.format("%s: expected %d rows, got %d", label, rows, #starts))
        assert(not frame:find("\27%[2J"), label .. ": frame must never clear the screen")
        for i, st in ipairs(starts) do
            local stop = starts[i + 1] and (starts[i + 1].pos - 1) or #frame
            local seg = frame:sub(st.pos, stop):gsub("^\27%[%d+;1H", "")
            assert(st.row == i, string.format("%s: row %d out of order", label, i))
            assert(seg:sub(-3) == "\27[K", string.format("%s: row %d lacks trailing \\27[K", label, i))
            local width = visible_width(seg:sub(1, -4))
            assert(width <= cols, string.format("%s: row %d is %d cols wide (> %d)", label, i, width, cols))
        end
    end

    -- Test 7: Key decoding and symbolic-token dispatch
    assert(Term.decode_sequence("\27[A") == "UP", "ESC [ A must decode to UP")
    assert(Term.decode_sequence(" ") == "SPACE", "space must decode to SPACE")
    assert(Term.decode_sequence("\3") == "CTRL_C", "0x03 must decode to CTRL_C")
    assert(Term.decode_sequence("\27") == "ESC", "lone ESC must decode to ESC")
    assert(Term.decode_sequence("\27[3~") == nil, "unknown escape sequences must be ignored")
    assert(Term.decode_sequence("abc") == "a", "multi-byte bursts decode their first key")

    local ks = new_state({ tab = 2, scrub_col = 10 })
    TUI.handle_key(ks, "h", db)
    assert(ks.show_help == false and ks.scrub_col == 9, "h must scrub left on the Plot tab")
    TUI.handle_key(ks, "l", db)
    assert(ks.scrub_col == 10, "l must scrub right on the Plot tab")
    TUI.handle_key(ks, "LEFT", db)
    assert(ks.scrub_col == 9, "LEFT must scrub left")
    TUI.handle_key(ks, "3", db)
    assert(ks.tab == 3, "3 must switch to the Log tab even from the Plot tab")
    TUI.handle_key(ks, "1", db)
    assert(ks.tab == 1, "1 must switch to the Dashboard tab")
    ks.tab = 2
    ks.plot_hours = 24
    TUI.handle_key(ks, "]", db)
    assert(ks.plot_hours == 168, "] must widen the window to 7d")
    TUI.handle_key(ks, "]", db)
    assert(ks.plot_hours == 168, "] must clamp at the widest window")
    TUI.handle_key(ks, "[", db)
    TUI.handle_key(ks, "[", db)
    TUI.handle_key(ks, "[", db)
    TUI.handle_key(ks, "[", db)
    TUI.handle_key(ks, "[", db)
    assert(ks.plot_hours == 1, "[ must clamp at the narrowest window")
    ks.tab = 1
    assert(TUI.handle_key(ks, "h", db) == false and ks.show_help == false, "h must not open help")
    TUI.handle_key(ks, "?", db)
    assert(ks.show_help == true, "? must open help")
    TUI.handle_key(ks, "ESC", db)
    assert(ks.show_help == false and ks.running == true, "ESC closes help without quitting")
    TUI.handle_key(ks, "?", db)
    TUI.handle_key(ks, "CTRL_C", db)
    assert(ks.running == false, "Ctrl+C must quit even while help is open")
    print("  [✓] Test 7 passed: key decoding, h/l scrub, tab/window keys, Ctrl+C in help.")

    -- Test 8: Frame invariants across sizes, tabs, help and degenerate data
    local long = string.rep("W", 300)
    local long_info = {
        capacity = 55, status = "Discharging", voltage_v = 11.1, power_w = 9.9, energy_wh = 20,
        energy_full_wh = 40, energy_design_wh = 50, health_pct = 80, cycle_count = 7,
        manufacturer = long, model_name = long, technology = long, path = "/sys/" .. long,
    }
    local long_records = {
        { timestamp = 1000, capacity = 50, status = long, voltage_v = 12, power_w = 1, health_pct = 80 },
        { timestamp = 2000, capacity = 60, status = long, voltage_v = 12, power_w = 1, health_pct = 80 },
    }
    local sizes = { { 40, 12 }, { 41, 13 }, { 80, 24 }, { 120, 40 }, { 200, 60 } }
    local variants = {
        { name = "normal", over = {} },
        { name = "empty", over = { records = {}, total_db_count = 0 } },
        { name = "no-battery", over = { info = false } },
        { name = "long-strings", over = { info = long_info, records = long_records } },
    }
    local frames_checked = 0
    for _, size in ipairs(sizes) do
        for _, variant in ipairs(variants) do
            for tab = 1, 3 do
                for _, help in ipairs({ false, true }) do
                    local over = {}
                    for k, v in pairs(variant.over) do
                        over[k] = v
                    end
                    over.tab = tab
                    over.show_help = help
                    local st = new_state(over)
                    if st.info == false then
                        st.info = nil
                    end
                    local label = string.format("%dx%d %s tab%d help=%s",
                        size[1], size[2], variant.name, tab, tostring(help))
                    local frame = TUI.render_frame(st, size[1], size[2])
                    assert_frame_invariants(frame, size[1], size[2], label)
                    frames_checked = frames_checked + 1
                end
            end
        end
    end
    print(string.format("  [✓] Test 8 passed: %d frames satisfy row/width/clear invariants.", frames_checked))

    -- Test 9: Terminals below the minimum size show a message and overwrite every row
    local tiny = { { 39, 12 }, { 40, 11 }, { 30, 8 }, { 1, 1 }, { 80, 3 }, { 20, 40 } }
    for _, size in ipairs(tiny) do
        local frame = TUI.render_frame(new_state(), size[1], size[2])
        assert_frame_invariants(frame, size[1], size[2], string.format("tiny %dx%d", size[1], size[2]))
        if size[2] >= 1 and size[1] >= 20 then
            assert(frame:find("Terminal too small", 1, true), "tiny terminal must explain itself")
        end
    end
    print("  [✓] Test 9 passed: undersized terminals render a full-overwrite size warning.")

    -- Test 10: Width helpers truncate by display columns, never splitting UTF-8
    local fitted = pad_box_row(Plotter.RED .. "ábcdéfghij" .. Plotter.RESET, 5)
    assert(visible_width(fitted) == 5, "pad_box_row must fit exactly 5 columns")
    assert(fitted:find("^\27%[31má"), "pad_box_row must keep leading ANSI and multibyte chars intact")
    assert(visible_width(pad_box_row("ab", 6)) == 6, "pad_box_row must right-pad short text")
    assert(visible_width(pad_box_row("█████", 3)) == 3, "pad_box_row must cut block glyphs on a boundary")
    assert(pad_box_row("abc", 0) == "", "zero width must yield empty text")
    assert(Plotter.sparkline({ 15 }, 0, 100) == "▁", "15% must map to the lowest visible block glyph")
    print("  [✓] Test 10 passed: truncation/padding preserves ANSI + UTF-8 and glyph set is complete.")

    -- Test 11: Help modal degrades gracefully by available height
    for avail = 3, 20 do
        local help_lines = TUI.build_help_lines(60, avail)
        assert(#help_lines <= avail, string.format("help overflowed %d rows with %d lines", avail, #help_lines))
        for _, hl in ipairs(help_lines) do
            assert(visible_width(hl) == 60, "every help row must be exactly box width")
        end
    end
    assert(#TUI.build_help_lines(60, 2) == 0, "no room for help must yield no rows")
    print("  [✓] Test 11 passed: help modal fits any viewport height with aligned borders.")

    print("=== All battery_monitor.lua self-tests passed successfully! ===")
    return true
end

local function show_help()
    print([[
Usage: luajit battery_monitor.lua [options]

Options:
  (no args)           Snapshot current telemetry, record to SQLite, and display chart
  --tui, -t           Launch the interactive, real-time Terminal User Interface (TUI)
  --record            Record a snapshot quietly to SQLite (ideal for cron or systemd timer)
  --status            Display current hardware telemetry only
  --plot [hours]      Render ASCII/Unicode capacity history plot (default: 24h)
  --history [N]       Show tabular log of the last N snapshots (default: 20)
  --seed              Generate 24 hours of synthetic battery telemetry for testing
  --db <path>         Specify custom SQLite database file (default: .battery_history.db)
  --test              Run internal verification and test suite
  --help, -h          Show this help text
]])
end

-- ============================================================================
-- Section 8: CLI Argument Dispatcher & Main Entry Point
-- ============================================================================
local function main(args)
    local db_path = nil
    local mode = "default"
    local opt_val = nil

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            show_help()
            return
        elseif a == "--tui" or a == "-t" then
            mode = "tui"
        elseif a == "--record" then
            mode = "record"
        elseif a == "--status" then
            mode = "status"
        elseif a == "--plot" or a == "--history" then
            mode = (a == "--plot") and "plot" or "history"
            local next_arg = args[i + 1]
            if next_arg and not next_arg:match("^%-") then
                opt_val = tonumber(next_arg)
                if not opt_val or opt_val <= 0 then
                    io.stderr:write(string.format(
                        "[ERROR] %s expects a positive number, got '%s'\n", a, next_arg))
                    os.exit(2)
                end
                i = i + 1
            end
        elseif a == "--seed" then
            mode = "seed"
        elseif a == "--test" then
            mode = "test"
        elseif a == "--db" then
            local next_arg = args[i + 1]
            if not next_arg or next_arg:match("^%-%-") then
                io.stderr:write("[ERROR] --db requires a database file path\n")
                os.exit(2)
            end
            db_path = next_arg
            i = i + 1
        else
            io.stderr:write(string.format(
                "[ERROR] Unknown option '%s' (run with --help for usage)\n", a))
            os.exit(2)
        end
        i = i + 1
    end

    if mode == "test" then
        -- Self-tests must never read or modify the user's real database
        db_path = ":memory:"
    end

    local db, dberr = BatteryDB:open(db_path)
    if not db then
        io.stderr:write(Plotter.RED .. "[DB ERROR] " .. tostring(dberr) .. Plotter.RESET .. "\n")
        os.exit(1)
    end

    if mode == "tui" then
        -- xpcall's first result only reports whether TUI.run raised an error; TUI.run itself
        -- returns false for handled fatal failures (e.g. stdin is not a terminal).
        local ok, run_result = xpcall(function()
            return TUI.run(db)
        end, function(err_msg)
            Term.restore()
            return tostring(err_msg) .. "\n" .. debug.traceback()
        end)
        Term.restore()
        db:close()
        -- Terminal restored and DB closed: now let any deferred SIGINT/SIGTERM/SIGHUP take effect
        Term.release_signals()
        if not ok then
            io.stderr:write("[TUI ERROR] " .. tostring(run_result) .. "\n")
            os.exit(1)
        elseif run_result == false then
            io.stderr:write("[TUI ERROR] Could not start the interactive UI "
                .. "(stdin/stdout must be a terminal; use --status or --plot instead)\n")
            os.exit(1)
        end
    elseif mode == "record" then
        local info, err = BatteryReader.read_info()
        if not info then
            io.stderr:write(Plotter.RED .. "[ERROR] " .. tostring(err) .. Plotter.RESET .. "\n")
            db:close()
            os.exit(1)
        end
        local ok = cmd_record(db, info)
        db:close()
        if not ok then
            os.exit(1)
        end
    elseif mode == "status" then
        local info, err = BatteryReader.read_info()
        if not info then
            io.stderr:write(Plotter.RED .. "[ERROR] " .. tostring(err) .. Plotter.RESET .. "\n")
            db:close()
            os.exit(1)
        end
        print_banner()
        render_status(info)
        db:close()
    elseif mode == "history" then
        local ok = cmd_history(db, opt_val)
        db:close()
        if not ok then
            os.exit(1)
        end
    elseif mode == "plot" then
        local info = BatteryReader.read_info()
        print_banner()
        if info then
            render_status(info)
        end
        local ok = cmd_plot(db, opt_val or 24)
        db:close()
        if not ok then
            os.exit(1)
        end
    elseif mode == "seed" then
        print("Generating 24-hour synthetic charge/discharge curve (144 samples, every 10 mins)...")
        cmd_seed(db)
        print("Successfully seeded synthetic data!")
        local ok = cmd_plot(db, 24)
        db:close()
        if not ok then
            os.exit(1)
        end
    elseif mode == "test" then
        local ok = run_self_tests(db)
        db:close()
        if not ok then
            os.exit(1)
        end
    else -- default
        local info, err = BatteryReader.read_info()
        if not info then
            io.stderr:write(Plotter.RED .. "[ERROR] " .. tostring(err) .. Plotter.RESET .. "\n")
            db:close()
            os.exit(1)
        end
        local ok_ins, err_ins = db:insert_snapshot(info)
        if not ok_ins then
            io.stderr:write(Plotter.RED .. "[ERROR] " .. tostring(err_ins) .. Plotter.RESET .. "\n")
            db:close()
            os.exit(1)
        end
        print_banner()
        render_status(info)
        local ok_plot = cmd_plot(db, 24)
        db:close()
        if not ok_plot then
            os.exit(1)
        end
    end
end

main(arg or {})
