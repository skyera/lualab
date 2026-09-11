--[[
    table_demo.lua
    A beautiful, modern terminal table renderer written in LuaJIT using FFI.

    Features:
    - POSIX ioctl(TIOCGWINSZ) via LuaJIT FFI for auto terminal width detection.
    - Unicode box-drawing characters (rounded corners, clean borders, custom dividers).
    - Truecolor (24-bit RGB) gradient headers and alternating row shading.
    - Status pill badges with custom background colors.
    - Text alignment per column (left, center, right).
    - Clean ANSI escape handling (strips ANSI codes when measuring visual display width).
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. POSIX Terminal Window Size Detection via FFI
-- =========================================================================
ffi.cdef[[
    struct winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };
    int ioctl(int fd, unsigned long request, void *argp);
]]

local TIOCGWINSZ = 0x5413

local function get_terminal_width()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 then
        return tonumber(ws.ws_col)
    end
    return 100
end

-- =========================================================================
-- 2. Color Palette & Styling Helpers (24-bit Truecolor)
-- =========================================================================
local C = {
    reset       = "\27[0m",
    bold        = "\27[1m",
    dim         = "\27[2m",
    italic      = "\27[3m",
    
    -- Border styling (slate grey)
    border      = "\27[38;2;90;105;120m",
    
    -- Alternating row backgrounds
    row_bg_1    = "\27[48;2;22;27;34m",  -- Dark charcoal
    row_bg_2    = "\27[48;2;13;17;23m",  -- Deep night
    
    -- Header gradient colors
    hdr_bg      = "\27[48;2;30;41;59m",  -- Dark navy blue
    hdr_fg      = "\27[38;2;241;245;249m\27[1m", -- Bright crisp white bold
    
    -- Value accent colors
    fg_text     = "\27[38;2;226;232;240m",
    fg_dim      = "\27[38;2;148;163;184m",
    fg_accent   = "\27[38;2;56;189;248m",  -- Cyan / Sky Blue
    fg_number   = "\27[38;2;251;191;36m",  -- Amber gold
    
    -- Status pill generator
    badge_green = "\27[48;2;22;101;52m\27[38;2;187;247;208m\27[1m",  -- Success
    badge_blue  = "\27[48;2;30;64;175m\27[38;2;191;219;254m\27[1m",   -- Running / Info
    badge_amber = "\27[48;2;146;64;14m\27[38;2;254;240;138m\27[1m",   -- Warning / In Progress
    badge_red   = "\27[48;2;153;27;27m\27[38;2;254;202;202m\27[1m",   -- Failed / Error
    badge_purple= "\27[48;2;88;28;135m\27[38;2;233;213;255m\27[1m",   -- Premium / Special
}

-- Strip ANSI escape codes to compute true visual string length
local function visual_length(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    -- Simple UTF-8 length counter
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

-- Pad string with alignment considering visual length
local function pad_string(str, target_width, align)
    local vis_len = visual_length(str)
    local diff = math.max(0, target_width - vis_len)
    align = align or "left"
    
    if align == "right" then
        return string.rep(" ", diff) .. str
    elseif align == "center" then
        local left = math.floor(diff / 2)
        local right = diff - left
        return string.rep(" ", left) .. str .. string.rep(" ", right)
    else
        return str .. string.rep(" ", diff)
    end
end

-- =========================================================================
-- 3. Box Drawing Characters (Rounded style)
-- =========================================================================
local BOX = {
    top_left     = "╭",
    top_right    = "╮",
    bottom_left  = "╰",
    bottom_right = "╯",
    horiz        = "─",
    vert         = "│",
    top_tee      = "┬",
    bottom_tee   = "┴",
    left_tee     = "├",
    right_tee    = "┤",
    cross        = "┼",
}

-- =========================================================================
-- 4. Table Renderer Engine
-- =========================================================================
local function render_table(options)
    local title   = options.title
    local subtitle= options.subtitle
    local columns = options.columns
    local rows    = options.rows
    local term_w  = get_terminal_width()

    -- 1. Compute minimum & maximum width needed per column
    local col_widths = {}
    for i, col in ipairs(columns) do
        local max_w = visual_length(col.header)
        for _, row in ipairs(rows) do
            local val = row[i] or ""
            local len = visual_length(val)
            if len > max_w then max_w = len end
        end
        -- Add padding (minimum 2 chars padding)
        col_widths[i] = max_w + 2
    end

    -- 2. Build border separator lines
    local function make_border(left_ch, mid_ch, right_ch, horiz_ch)
        local parts = { C.border, left_ch }
        for i, w in ipairs(col_widths) do
            table.insert(parts, string.rep(horiz_ch, w + 2))
            if i < #col_widths then
                table.insert(parts, mid_ch)
            end
        end
        table.insert(parts, right_ch .. C.reset .. "\n")
        return table.concat(parts)
    end

    local top_border = make_border(BOX.top_left, BOX.top_tee, BOX.top_right, BOX.horiz)
    local mid_border = make_border(BOX.left_tee, BOX.cross, BOX.right_tee, BOX.horiz)
    local btm_border = make_border(BOX.bottom_left, BOX.bottom_tee, BOX.bottom_right, BOX.horiz)

    local out = {}

    -- Title Banner (if provided)
    if title then
        table.insert(out, "\n  " .. C.bold .. "\27[38;2;129;140;248m✦ " .. title .. C.reset)
        if subtitle then
            table.insert(out, "  " .. C.dim .. "• " .. subtitle .. C.reset)
        end
        table.insert(out, "\n\n")
    end

    -- Top border
    table.insert(out, "  " .. top_border)

    -- Header row
    local hdr_parts = { "  ", C.border, BOX.vert }
    for i, col in ipairs(columns) do
        local cell_text = pad_string(col.header, col_widths[i], col.align or "left")
        table.insert(hdr_parts, C.hdr_bg .. " " .. C.hdr_fg .. cell_text .. C.reset .. " " .. C.border .. BOX.vert)
    end
    table.insert(hdr_parts, C.reset .. "\n")
    table.insert(out, table.concat(hdr_parts))

    -- Header divider
    table.insert(out, "  " .. mid_border)

    -- Data rows
    for r_idx, row in ipairs(rows) do
        local row_bg = (r_idx % 2 == 1) and C.row_bg_1 or C.row_bg_2
        local row_parts = { "  ", C.border, BOX.vert }

        for i, col in ipairs(columns) do
            local raw_val = row[i] or ""
            local padded = pad_string(raw_val, col_widths[i], col.align or "left")
            table.insert(row_parts, row_bg .. " " .. C.fg_text .. padded .. C.reset .. " " .. C.border .. BOX.vert)
        end

        table.insert(row_parts, C.reset .. "\n")
        table.insert(out, table.concat(row_parts))
    end

    -- Bottom border
    table.insert(out, "  " .. btm_border)

    -- Footer summary
    table.insert(out, string.format("  %s%d records listed | Terminal width: %d cols%s\n\n",
        C.dim, #rows, term_w, C.reset))

    io.write(table.concat(out))
    io.flush()
end

-- =========================================================================
-- 5. Demonstration Data & Execution
-- =========================================================================
local function main()
    local columns = {
        { header = "ID",        align = "center" },
        { header = "SERVICE",   align = "left"   },
        { header = "VERSION",   align = "center" },
        { header = "STATUS",    align = "center" },
        { header = "LATENCY",   align = "right"  },
        { header = "MEMORY",    align = "right"  },
        { header = "UPTIME",    align = "left"   },
    }

    local rows = {
        {
            C.fg_dim .. "#01" .. C.reset,
            C.bold .. C.fg_accent .. "API Gateway" .. C.reset,
            "v3.4.1",
            C.badge_green .. " ACTIVE " .. C.reset,
            C.fg_number .. "1.42 ms" .. C.reset,
            "128.4 MB",
            "99.98% (42d)",
        },
        {
            C.fg_dim .. "#02" .. C.reset,
            C.bold .. C.fg_accent .. "LuaJIT Engine" .. C.reset,
            "v2.1-git",
            C.badge_green .. " ACTIVE " .. C.reset,
            C.fg_number .. "0.18 ms" .. C.reset,
            "18.2 MB",
            "100.0% (90d)",
        },
        {
            C.fg_dim .. "#03" .. C.reset,
            C.bold .. C.fg_accent .. "PostgreSQL Cluster" .. C.reset,
            "v16.2",
            C.badge_blue .. " SYNCING " .. C.reset,
            C.fg_number .. "4.85 ms" .. C.reset,
            "1.85 GB",
            "99.95% (18d)",
        },
        {
            C.fg_dim .. "#04" .. C.reset,
            C.bold .. C.fg_accent .. "Redis Cache L2" .. C.reset,
            "v7.2.4",
            C.badge_amber .. " HIGH-LOAD " .. C.reset,
            C.fg_number .. "0.92 ms" .. C.reset,
            "842.0 MB",
            "99.89% (5d)",
        },
        {
            C.fg_dim .. "#05" .. C.reset,
            C.bold .. C.fg_accent .. "Inference Sidecar" .. C.reset,
            "v0.9.8",
            C.badge_purple .. " OPTIMIZING " .. C.reset,
            C.fg_number .. "14.20 ms" .. C.reset,
            "4.12 GB",
            "98.70% (2d)",
        },
        {
            C.fg_dim .. "#06" .. C.reset,
            C.bold .. C.fg_accent .. "Auth Webhook" .. C.reset,
            "v1.2.0",
            C.badge_red .. " DEGRADED " .. C.reset,
            C.fg_number .. "88.60 ms" .. C.reset,
            "64.1 MB",
            "94.20% (6h)",
        },
    }

    render_table({
        title    = "MICROSERVICE CLUSTER DASHBOARD",
        subtitle = "Production Nodes • Health & Telemetry Metrics",
        columns  = columns,
        rows     = rows,
    })
end

main()
