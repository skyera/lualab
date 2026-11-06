#!/usr/bin/env terra
-- ============================================================================
-- Battery Monitor: Hardware Telemetry, SQLite History & Terminal Plotter
-- Written in Terra (low-level LLVM C interop + Lua high-level coordination)
-- ============================================================================

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
local ffi = require("ffi")

-- ============================================================================
-- Section 1: Terra Native C Bindings (SQLite3 and System Headers)
-- ============================================================================
local c = terralib.includec("stdio.h")
terralib.linklibrary("libsqlite3.so")

-- SQLite opaque types
struct sqlite3 {}
struct sqlite3_stmt {}

-- SQLite C function declarations
local sqlite3_open = terralib.externfunction("sqlite3_open", {&int8, &&sqlite3} -> int)
local sqlite3_close = terralib.externfunction("sqlite3_close", {&sqlite3} -> int)
local sqlite3_exec = terralib.externfunction("sqlite3_exec", {&sqlite3, &int8, &opaque, &opaque, &&int8} -> int)
local sqlite3_prepare_v2 = terralib.externfunction("sqlite3_prepare_v2", {&sqlite3, &int8, int, &&sqlite3_stmt, &&int8} -> int)
local sqlite3_step = terralib.externfunction("sqlite3_step", {&sqlite3_stmt} -> int)
local sqlite3_column_int64 = terralib.externfunction("sqlite3_column_int64", {&sqlite3_stmt, int} -> int64)
local sqlite3_column_int = terralib.externfunction("sqlite3_column_int", {&sqlite3_stmt, int} -> int)
local sqlite3_column_double = terralib.externfunction("sqlite3_column_double", {&sqlite3_stmt, int} -> double)
local sqlite3_column_text = terralib.externfunction("sqlite3_column_text", {&sqlite3_stmt, int} -> &int8)
local sqlite3_finalize = terralib.externfunction("sqlite3_finalize", {&sqlite3_stmt} -> int)
local sqlite3_errmsg = terralib.externfunction("sqlite3_errmsg", {&sqlite3} -> &int8)

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101

-- ============================================================================
-- Section 2: Hardware Battery Reader (Linux /sys/class/power_supply)
-- ============================================================================
local BatteryReader = {}
BatteryReader.__index = BatteryReader

function BatteryReader.find_battery_path()
    -- Look for BAT0, BAT1, or any battery device in /sys/class/power_supply
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

    -- Conversions from micro-units (uV, uW, uWh) to standard units
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
-- Section 3: SQLite3 Storage Engine via Native Terra Functions
-- ============================================================================
local BatteryDB = {}
BatteryDB.__index = BatteryDB

function BatteryDB:open(db_path)
    local db_file = db_path or (os.getenv("BATTERY_DB") or ".battery_history.db")
    local db_ptr = terralib.new((&sqlite3)[1])

    local rc = sqlite3_open(db_file, db_ptr)
    if rc ~= SQLITE_OK then
        return nil, string.format("Failed to open SQLite DB '%s' (code: %d)", db_file, rc)
    end

    local self_inst = setmetatable({
        db = db_ptr[0],
        db_file = db_file
    }, BatteryDB)

    self_inst:init_schema()
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
    local rc = sqlite3_exec(self.db, sql, nil, nil, nil)
    if rc ~= SQLITE_OK then
        local err_msg = self:errmsg()
        return false, "Failed to initialize schema: " .. err_msg
    end
    return true
end

function BatteryDB:errmsg()
    local msg = sqlite3_errmsg(self.db)
    if msg ~= nil then
        return ffi.string(msg)
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

    local rc = sqlite3_exec(self.db, sql, nil, nil, nil)
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

    local stmt_ptr = terralib.new((&sqlite3_stmt)[1])
    local rc = sqlite3_prepare_v2(self.db, sql, #sql, stmt_ptr, nil)
    if rc ~= SQLITE_OK then
        return nil, "Prepare failed: " .. self:errmsg()
    end

    local stmt = stmt_ptr[0]
    local records = {}

    while sqlite3_step(stmt) == SQLITE_ROW do
        local ts = tonumber(sqlite3_column_int64(stmt, 0))
        local cap = tonumber(sqlite3_column_int(stmt, 1))

        -- Extract text for status
        local c_status = sqlite3_column_text(stmt, 2)
        local status_str = "Unknown"
        if c_status ~= nil then
            status_str = ffi.string(c_status)
        end

        local volt = tonumber(sqlite3_column_double(stmt, 3))
        local pwr = tonumber(sqlite3_column_double(stmt, 4))
        local eng = tonumber(sqlite3_column_double(stmt, 5))
        local hlth = tonumber(sqlite3_column_double(stmt, 6))
        local cyc = tonumber(sqlite3_column_int(stmt, 7))

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

    sqlite3_finalize(stmt)
    return records
end

function BatteryDB:count_records()
    local sql = "SELECT COUNT(*) FROM battery_snapshots;"
    local stmt_ptr = terralib.new((&sqlite3_stmt)[1])
    local rc = sqlite3_prepare_v2(self.db, sql, #sql, stmt_ptr, nil)
    if rc ~= SQLITE_OK then
        return 0
    end
    local stmt = stmt_ptr[0]
    local count = 0
    if sqlite3_step(stmt) == SQLITE_ROW then
        count = tonumber(sqlite3_column_int64(stmt, 0))
    end
    sqlite3_finalize(stmt)
    return count
end

function BatteryDB:close()
    if self.db ~= nil then
        sqlite3_close(self.db)
        self.db = nil
    end
end

-- ============================================================================
-- Section 4: Terminal Unicode Plotter (Sparklines & Braille/Block Charts)
-- ============================================================================
local Plotter = {}

-- Unicode vertical fill levels: 0/8 to 8/8
Plotter.BLOCKS = { " ", " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- ANSI colors
Plotter.RESET   = "\27[0m"
Plotter.BOLD    = "\27[1m"
Plotter.RED     = "\27[31m"
Plotter.GREEN   = "\27[32m"
Plotter.YELLOW  = "\27[33m"
Plotter.BLUE    = "\27[34m"
Plotter.CYAN    = "\27[36m"
Plotter.GRAY    = "\27[90m"

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

--- Generates a compact inline sparkline string from a series of numbers
function Plotter.sparkline(values, min_val, max_val)
    if not values or #values == 0 then return "" end
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
    if range <= 0 then range = 1 end

    local chars = {}
    for _, v in ipairs(values) do
        local normalized = math.max(0, math.min(1, (v - min_v) / range))
        local idx = math.floor(normalized * 8) + 1
        idx = math.max(1, math.min(9, idx))
        chars[#chars + 1] = Plotter.BLOCKS[idx]
    end
    return table.concat(chars)
end

--- Renders an ASCII/Unicode 2D time-series grid for battery history
function Plotter.render_chart(records, width, height)
    width = width or 64
    height = height or 8

    if not records or #records < 2 then
        return "  " .. Plotter.colorize("(Need at least 2 snapshots to plot history)", Plotter.GRAY)
    end

    local min_ts = records[1].timestamp
    local max_ts = records[#records].timestamp
    local time_span = max_ts - min_ts
    if time_span <= 0 then time_span = 1 end

    -- Resample into 'width' discrete buckets
    local buckets = {}
    local bucket_weights = {}
    for i = 1, width do
        buckets[i] = 0
        bucket_weights[i] = 0
    end

    local min_cap = 100
    local max_cap = 0

    for _, r in ipairs(records) do
        local progress = (r.timestamp - min_ts) / time_span
        local col = math.floor(progress * (width - 1)) + 1
        col = math.max(1, math.min(width, col))

        buckets[col] = buckets[col] + r.capacity
        bucket_weights[col] = bucket_weights[col] + 1

        if r.capacity < min_cap then min_cap = r.capacity end
        if r.capacity > max_cap then max_cap = r.capacity end
    end

    -- Compute average per bucket or forward-fill missing buckets
    local last_valid = records[1].capacity
    for i = 1, width do
        if bucket_weights[i] > 0 then
            buckets[i] = buckets[i] / bucket_weights[i]
            last_valid = buckets[i]
        else
            buckets[i] = last_valid
        end
    end

    -- Render rows from top (100%) to bottom (0%)
    local lines = {}
    local cap_range = 100.0 -- Fixed 0-100% scale for intuitive battery visualization

    for row = height, 1, -1 do
        local row_pct_high = (row / height) * 100.0
        local row_pct_low = ((row - 1) / height) * 100.0
        local row_pct_mid = (row_pct_high + row_pct_low) / 2.0

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

            if val >= row_pct_high then
                char = "█"
            elseif val <= row_pct_low then
                char = " "
            else
                -- Sub-cell fractional block
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
    for _ = 1, width do axis_dashes[#axis_dashes + 1] = "─" end
    lines[#lines + 1] = Plotter.GRAY .. "     └" .. table.concat(axis_dashes) .. "►" .. Plotter.RESET

    -- Time labels across X-axis
    local t_start = os.date("%H:%M", min_ts)
    local t_mid = os.date("%H:%M", math.floor(min_ts + time_span / 2))
    local t_end = os.date("%H:%M", max_ts)

    local spacing_half = math.floor((width - #t_start - #t_end - #t_mid) / 2)
    spacing_half = math.max(1, spacing_half)

    local time_line = "      " .. t_start .. string.rep(" ", spacing_half) .. t_mid .. string.rep(" ", spacing_half) .. t_end
    lines[#lines + 1] = Plotter.GRAY .. time_line .. Plotter.RESET

    return table.concat(lines, "\n")
end

-- ============================================================================
-- Section 5: CLI Dashboard & Views
-- ============================================================================
local function print_banner()
    local now_str = os.date("%Y-%m-%d %H:%M:%S")
    print(Plotter.BOLD .. Plotter.CYAN .. "================================================================================" .. Plotter.RESET)
    print(string.format("%s BATTERY MONITOR (Terra + SQLite3)%s  %s[%s]%s",
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

    -- 40-character progress bar
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

local function cmd_seed(db)
    print("Generating 24-hour synthetic charge/discharge curve (144 samples, every 10 mins)...")
    local now = os.time()
    local start = now - (24 * 3600)
    local sample_count = 144

    for i = 1, sample_count do
        local t = start + (i * 600)
        -- Simulate sine discharge/charge cycle between 20% and 100%
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
    print("Successfully seeded synthetic data!")
end

local function show_help()
    print([[
Usage: terra battery_monitor.t [options]

Options:
  (no args)           Snapshot current telemetry, record to SQLite, and display chart
  --record            Record a snapshot quietly to SQLite (ideal for cron or systemd timer)
  --status            Display current hardware telemetry only
  --plot [hours]      Render ASCII/Unicode capacity history plot (default: 24h)
  --history [N]       Show tabular log of the last N snapshots (default: 20)
  --seed              Generate 24 hours of synthetic battery telemetry for testing
  --db <path>         Specify custom SQLite database file (default: .battery_history.db)
  --help, -h          Show this help text
]])
end

-- ============================================================================
-- Section 6: CLI Argument Dispatcher
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

    if mode == "record" then
        local info, err = BatteryReader.read_info()
        if not info then
            io.stderr:write(Plotter.RED .. "[ERROR] " .. tostring(err) .. Plotter.RESET .. "\n")
            db:close()
            os.exit(1)
        end
        local ok = cmd_record(db, info)
        db:close()
        if not ok then os.exit(1) end
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
        if not ok then os.exit(1) end
    elseif mode == "plot" then
        local info = BatteryReader.read_info()
        print_banner()
        if info then
            render_status(info)
        end
        local ok = cmd_plot(db, opt_val or 24)
        db:close()
        if not ok then os.exit(1) end
    elseif mode == "seed" then
        cmd_seed(db)
        local ok = cmd_plot(db, 24)
        db:close()
        if not ok then os.exit(1) end
    else -- default
        local info, err = BatteryReader.read_info()
        if not info then
            io.stderr:write(Plotter.RED .. "[ERROR] " .. tostring(err) .. Plotter.RESET .. "\n")
            db:close()
            os.exit(1)
        end
        -- 1. Record snapshot
        local ok_ins, err_ins = db:insert_snapshot(info)
        if not ok_ins then
            io.stderr:write(Plotter.RED .. "[ERROR] " .. tostring(err_ins) .. Plotter.RESET .. "\n")
            db:close()
            os.exit(1)
        end
        -- 2. Display banner & status
        print_banner()
        render_status(info)
        -- 3. Display plot
        local ok_plot = cmd_plot(db, 24)
        db:close()
        if not ok_plot then os.exit(1) end
    end
end

main(arg or {})
