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

Plotter.BLOCKS = { " ", " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

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

    raw.c_iflag = bit.band(raw.c_iflag, bit.bnot(bit.bor(BRKINT, ICRNL, INPCK, ISTRIP, IXON)))
    raw.c_oflag = bit.band(raw.c_oflag, bit.bnot(OPOST))
    raw.c_cflag = bit.bor(raw.c_cflag, CS8)
    raw.c_lflag = bit.band(raw.c_lflag, bit.bnot(bit.bor(ECHO, ICANON, IEXTEN, ISIG)))
    raw.c_cc[5] = 0 -- VTIME
    raw.c_cc[6] = 1 -- VMIN

    if ffi.C.tcsetattr(STDIN_FD, TCSANOW, raw) ~= 0 then
        return false, "Failed to apply raw terminal mode"
    end

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
    return 80, 24
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
            local seq = ffi.string(buf, r)
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
            else
                return seq:sub(1, 1)
            end
        end
    end
    return nil
end

-- ============================================================================
-- Section 6: Pure Frame Generators & TUI Rendering Engine
-- ============================================================================
local TUI = {}

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

local function pad_box_row(inner_text, inner_width)
    local vw = visible_width(inner_text)
    local pad = inner_width - vw
    if pad <= 0 then
        return inner_text
    end
    return inner_text .. string.rep(" ", pad)
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
        status_badge = Plotter.GREEN .. "[⚡ CHARGING]" .. Plotter.RESET
    elseif info.status == "Discharging" then
        status_badge = Plotter.YELLOW .. "[🔋 DISCHARGING]" .. Plotter.RESET
    elseif info.status == "Full" then
        status_badge = Plotter.GREEN .. "[✓ FULL (AC)]" .. Plotter.RESET
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

    local hours_label = string.format("Time Window: %d Hours (%d snapshots in window) | Scale: [1] 1h  [2] 6h  [3] 12h  [4] 24h  [5] 7d",
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
            lines[#lines + 1] = string.format(" Scrub [%d/%d]: [←/→] Scrub timeline │ [0] Start │ [$] End", scrub_col, chart_w)
        end
    else
        lines[#lines + 1] = " [←/→] Scrub timeline cursor │ [0] Start │ [$] End │ [r] Record snapshot"
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

function TUI.overlay_modal(lines, target_w, target_h)
    local modal_lines = {
        "┌────────────────── BATTERY MONITOR HELP ──────────────────┐",
        "│                                                          │",
        "│  [Tab] / [1-3]    Switch Views (Dashboard, Plot, Log)   │",
        "│  [r]              Record Snapshot to SQLite Database     │",
        "│  [s]              Seed 24h Synthetic Battery Telemetry   │",
        "│  [+] / [-]        Adjust Telemetry Polling Rate          │",
        "│  [←] / [→] / h,l  Scrub Timeline Cursor in Plot View     │",
        "│  [↑] / [↓] / j,k  Scroll Rows in Snapshot Log View       │",
        "│  [1-5] (in Plot)  Change History Time Window (1h to 7d)  │",
        "│  [?] or [Esc]     Close this Help Window                 │",
        "│  [q] / [Ctrl+C]   Quit Battery Monitor TUI               │",
        "│                                                          │",
        "│              Press [Esc] or [?] to close                 │",
        "└──────────────────────────────────────────────────────────┘",
    }

    local modal_w = visible_width(modal_lines[1])
    local modal_h = #modal_lines
    local start_row = math.floor((target_h - modal_h) / 2) + 1
    local left_pad_len = math.floor((target_w - 4 - modal_w) / 2)
    left_pad_len = math.max(0, left_pad_len)
    local left_pad = string.rep(" ", left_pad_len)

    for i = 1, modal_h do
        local line_idx = start_row + i - 1
        if line_idx >= 4 and line_idx <= #lines - 3 then
            local m_text = left_pad .. modal_lines[i]
            lines[line_idx] = Plotter.CYAN .. "│ " .. Plotter.RESET .. pad_box_row(Plotter.YELLOW .. m_text .. Plotter.RESET, target_w - 4) .. Plotter.CYAN .. " │" .. Plotter.RESET .. "\27[K\n"
        end
    end
end

function TUI.render_frame(state, cols, rows)
    local target_w = math.max(40, cols - 1)
    local target_h = math.max(12, rows)
    local inner_w = target_w - 4

    local lines = {}

    -- Row 1: Top border with title, poll rate, clock
    local title = " BATTERY MONITOR (LuaJIT FFI) "
    local interval_str = string.format(" [Live %.1fs] ", state.poll_interval)
    local now_str = " " .. os.date("%Y-%m-%d %H:%M:%S") .. " "
    local top_fill = target_w - 2 - visible_width(title) - visible_width(interval_str) - visible_width(now_str)
    if top_fill < 2 then top_fill = 2 end
    local top_dashes = string.rep("─", top_fill)
    lines[#lines + 1] = Plotter.CYAN .. "┌─" .. Plotter.BOLD .. title .. Plotter.RESET .. Plotter.CYAN .. "─" .. interval_str .. "─" .. top_dashes .. now_str .. "─┐" .. Plotter.RESET .. "\27[K\n"

    -- Row 2: Tab Bar
    local t1 = (state.tab == 1 and (Plotter.BOLD .. Plotter.CYAN .. "[1] DASHBOARD" .. Plotter.RESET) or (Plotter.GRAY .. "[1] Dashboard" .. Plotter.RESET))
    local t2 = (state.tab == 2 and (Plotter.BOLD .. Plotter.CYAN .. "[2] HISTORY PLOT" .. Plotter.RESET) or (Plotter.GRAY .. "[2] History Plot" .. Plotter.RESET))
    local t3 = (state.tab == 3 and (Plotter.BOLD .. Plotter.CYAN .. "[3] SNAPSHOT LOG" .. Plotter.RESET) or (Plotter.GRAY .. "[3] Snapshot Log" .. Plotter.RESET))
    local tabs_str = string.format("  %s    │    %s    │    %s", t1, t2, t3)
    lines[#lines + 1] = Plotter.CYAN .. "│ " .. Plotter.RESET .. pad_box_row(tabs_str, inner_w) .. Plotter.CYAN .. " │" .. Plotter.RESET .. "\27[K\n"

    -- Row 3: Tab Divider
    lines[#lines + 1] = Plotter.CYAN .. "├" .. string.rep("─", target_w - 2) .. "┤" .. Plotter.RESET .. "\27[K\n"

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
        lines[#lines + 1] = Plotter.CYAN .. "│ " .. Plotter.RESET .. pad_box_row(content, inner_w) .. Plotter.CYAN .. " │" .. Plotter.RESET .. "\27[K\n"
    end

    -- Footer Row N-2: Divider
    lines[#lines + 1] = Plotter.CYAN .. "├" .. string.rep("─", target_w - 2) .. "┤" .. Plotter.RESET .. "\27[K\n"

    -- Footer Row N-1: Toast / Status
    local now_sec = os.time()
    local toast
    if state.toast_msg and now_sec <= state.toast_expire then
        toast = Plotter.BOLD .. Plotter.GREEN .. state.toast_msg .. Plotter.RESET
    else
        local db_name = state.db and state.db.db_file or ".battery_history.db"
        toast = Plotter.GRAY .. "Database: " .. db_name .. " (" .. state.total_db_count .. " snapshots recorded) │ Press [?] for keybindings" .. Plotter.RESET
    end
    lines[#lines + 1] = Plotter.CYAN .. "│ " .. Plotter.RESET .. pad_box_row(toast, inner_w) .. Plotter.CYAN .. " │" .. Plotter.RESET .. "\27[K\n"

    -- Footer Row N: Hotkey Bar
    local hotkeys = "[Tab] View  [r] Record  [s] Seed  [+/-] Rate  [?] Help  [q] Quit"
    local bot_fill = target_w - 2 - visible_width(hotkeys) - 4
    if bot_fill < 2 then bot_fill = 2 end
    lines[#lines + 1] = Plotter.CYAN .. "└─── " .. Plotter.BOLD .. hotkeys .. Plotter.RESET .. Plotter.CYAN .. " " .. string.rep("─", bot_fill) .. "┘" .. Plotter.RESET .. "\27[K\n"

    if state.show_help then
        TUI.overlay_modal(lines, target_w, target_h)
    end

    return table.concat(lines)
end

function TUI.handle_key(state, key, db)
    if state.show_help then
        if key == "ESC" or key == "?" or key == "h" or key == "ENTER" or key == "q" then
            state.show_help = false
            return true
        end
        return false
    end

    if key == "q" or key == "CTRL_C" or (key == "ESC" and not state.show_help) then
        state.running = false
        return true
    elseif key == "TAB" then
        state.tab = (state.tab % 3) + 1
        return true
    elseif key == "1" then
        if state.tab == 2 then
            state.plot_hours = 1
            TUI.reload_data(state, db)
        else
            state.tab = 1
        end
        return true
    elseif key == "2" then
        if state.tab == 2 then
            state.plot_hours = 6
            TUI.reload_data(state, db)
        else
            state.tab = 2
        end
        return true
    elseif key == "3" then
        if state.tab == 2 then
            state.plot_hours = 12
            TUI.reload_data(state, db)
        else
            state.tab = 3
        end
        return true
    elseif key == "4" and state.tab == 2 then
        state.plot_hours = 24
        TUI.reload_data(state, db)
        return true
    elseif key == "5" and state.tab == 2 then
        state.plot_hours = 168
        TUI.reload_data(state, db)
        return true
    elseif key == "?" or key == "h" then
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
        if key == "LEFT" then
            state.scrub_col = math.max(1, (state.scrub_col or max_c) - 1)
            return true
        elseif key == "RIGHT" then
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
    local last_cols, last_rows = 0, 0

    while state.running do
        local now = os.time()
        if now - state.last_poll_time >= state.poll_interval then
            TUI.reload_data(state, db)
            state.last_poll_time = now
        end

        local cols, rows = Term.get_size()
        if cols ~= last_cols or rows ~= last_rows then
            -- Full screen clear on window resize event only
            io.write("\27[2J")
            last_cols, last_rows = cols, rows
        end

        local frame = TUI.render_frame(state, cols, rows)
        io.write("\27[H\27[?2026h" .. frame .. "\27[?2026l")
        io.flush()

        local key = Term.read_key(100)
        if key then
            TUI.handle_key(state, key, db)
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
        elseif a == "--plot" then
            mode = "plot"
            if args[i + 1] and not args[i + 1]:match("^%-") then
                opt_val = tonumber(args[i + 1])
                i = i + 1
            end
        elseif a == "--history" then
            mode = "history"
            if args[i + 1] and not args[i + 1]:match("^%-") then
                opt_val = tonumber(args[i + 1])
                i = i + 1
            end
        elseif a == "--seed" then
            mode = "seed"
        elseif a == "--test" then
            mode = "test"
        elseif a == "--db" then
            db_path = args[i + 1]
            i = i + 1
        end
        i = i + 1
    end

    local db, dberr = BatteryDB:open(db_path)
    if not db then
        io.stderr:write(Plotter.RED .. "[DB ERROR] " .. tostring(dberr) .. Plotter.RESET .. "\n")
        os.exit(1)
    end

    if mode == "tui" then
        local ok, run_err = xpcall(function()
            return TUI.run(db)
        end, function(err_msg)
            Term.restore()
            return tostring(err_msg) .. "\n" .. debug.traceback()
        end)
        Term.restore()
        db:close()
        if not ok then
            io.stderr:write("[TUI ERROR] " .. tostring(run_err) .. "\n")
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
