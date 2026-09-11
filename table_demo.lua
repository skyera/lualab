#!/usr/bin/env luajit
--[[
    table_demo.lua
    A beautiful, modern terminal table renderer written in LuaJIT using FFI.

    Features:
    - Automatically varies table style and color theme randomly on every run.
    - 9 Unicode & ASCII box-drawing border styles (Rounded, Sharp, Double, Heavy, Hybrid, etc.).
    - 12 Handcrafted Truecolor (24-bit RGB) palettes with custom badges and row shading.
    - POSIX ioctl(TIOCGWINSZ) via LuaJIT FFI for auto terminal width detection.
    - True visual display width computation (handles multibyte UTF-8 and ANSI stripping).
    - Status pill badges with theme-coordinated foreground and background colors.
    - CLI options to view styles (--list), inspect all styles (--showcase), or lock specific styles (--box, --theme).
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
-- 2. True Random Seeder & Color Themes (24-bit Truecolor)
-- =========================================================================
local function seed_random()
    -- Read from /dev/urandom for high-entropy random seeding
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(4)
        f:close()
        if bytes and #bytes == 4 then
            local b1, b2, b3, b4 = bytes:byte(1, 4)
            local seed = (b1 + b2 * 256 + b3 * 65536 + b4 * 16777216) % 2147483647
            math.randomseed(seed)
            for _ = 1, 5 do math.random() end
            return
        end
    end
    -- High-resolution fallback mixing time, clock, and memory address
    local seed = os.time() + math.floor(os.clock() * 1e6)
    local dummy = {}
    local addr = tonumber(tostring(dummy):match("0x(%x+)"), 16)
    if addr then
        seed = (seed + addr) % 2147483647
    end
    math.randomseed(seed)
    for _ = 1, 5 do math.random() end
end

local THEMES = {
    tokyo_night = {
        id          = "tokyo_night",
        name        = "Tokyo Night",
        icon        = "✦",
        title_fg    = "\27[38;2;129;140;248m",
        border      = "\27[38;2;90;105;120m",
        row_bg_1    = "\27[48;2;22;27;34m",
        row_bg_2    = "\27[48;2;13;17;23m",
        hdr_bg      = "\27[48;2;30;41;59m",
        hdr_fg      = "\27[38;2;241;245;249m\27[1m",
        fg_text     = "\27[38;2;226;232;240m",
        fg_dim      = "\27[38;2;148;163;184m",
        fg_accent   = "\27[38;2;56;189;248m",
        fg_number   = "\27[38;2;251;191;36m",
        badge_green = "\27[48;2;22;101;52m\27[38;2;187;247;208m\27[1m",
        badge_blue  = "\27[48;2;30;64;175m\27[38;2;191;219;254m\27[1m",
        badge_amber = "\27[48;2;146;64;14m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;153;27;27m\27[38;2;254;202;202m\27[1m",
        badge_purple= "\27[48;2;88;28;135m\27[38;2;233;213;255m\27[1m",
    },
    cyberpunk = {
        id          = "cyberpunk",
        name        = "Cyberpunk Neon",
        icon        = "⚡",
        title_fg    = "\27[38;2;244;63;94m",
        border      = "\27[38;2;6;182;212m",
        row_bg_1    = "\27[48;2;20;14;38m",
        row_bg_2    = "\27[48;2;12;8;24m",
        hdr_bg      = "\27[48;2;59;7;100m",
        hdr_fg      = "\27[38;2;255;255;255m\27[1m",
        fg_text     = "\27[38;2;243;244;246m",
        fg_dim      = "\27[38;2;130;110;160m",
        fg_accent   = "\27[38;2;34;211;238m",
        fg_number   = "\27[38;2;250;204;21m",
        badge_green = "\27[48;2;6;95;70m\27[38;2;110;231;183m\27[1m",
        badge_blue  = "\27[48;2;14;116;144m\27[38;2;165;243;252m\27[1m",
        badge_amber = "\27[48;2;161;98;7m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;190;18;60m\27[38;2;254;205;211m\27[1m",
        badge_purple= "\27[48;2;126;34;206m\27[38;2;243;232;255m\27[1m",
    },
    emerald_matrix = {
        id          = "emerald_matrix",
        name        = "Emerald Matrix",
        icon        = "❖",
        title_fg    = "\27[38;2;74;222;128m",
        border      = "\27[38;2;34;197;94m",
        row_bg_1    = "\27[48;2;6;26;16m",
        row_bg_2    = "\27[48;2;3;18;11m",
        hdr_bg      = "\27[48;2;6;78;59m",
        hdr_fg      = "\27[38;2;240;253;244m\27[1m",
        fg_text     = "\27[38;2;209;250;229m",
        fg_dim      = "\27[38;2;74;115;95m",
        fg_accent   = "\27[38;2;52;211;153m",
        fg_number   = "\27[38;2;163;230;53m",
        badge_green = "\27[48;2;20;83;45m\27[38;2;187;247;208m\27[1m",
        badge_blue  = "\27[48;2;15;76;92m\27[38;2;165;243;252m\27[1m",
        badge_amber = "\27[48;2;133;77;14m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;153;27;27m\27[38;2;254;202;202m\27[1m",
        badge_purple= "\27[48;2;76;29;149m\27[38;2;233;213;255m\27[1m",
    },
    dracula = {
        id          = "dracula",
        name        = "Dracula Synth",
        icon        = "🔮",
        title_fg    = "\27[38;2;192;132;252m",
        border      = "\27[38;2;139;92;246m",
        row_bg_1    = "\27[48;2;30;20;44m",
        row_bg_2    = "\27[48;2;19;13;29m",
        hdr_bg      = "\27[48;2;59;23;92m",
        hdr_fg      = "\27[38;2;250;245;255m\27[1m",
        fg_text     = "\27[38;2;243;232;255m",
        fg_dim      = "\27[38;2;147;125;170m",
        fg_accent   = "\27[38;2;232;121;249m",
        fg_number   = "\27[38;2;251;146;60m",
        badge_green = "\27[48;2;22;101;52m\27[38;2;187;247;208m\27[1m",
        badge_blue  = "\27[48;2;49;46;129m\27[38;2;199;210;254m\27[1m",
        badge_amber = "\27[48;2;124;45;18m\27[38;2;254;215;170m\27[1m",
        badge_red   = "\27[48;2;153;27;27m\27[38;2;254;202;202m\27[1m",
        badge_purple= "\27[48;2;88;28;135m\27[38;2;233;213;255m\27[1m",
    },
    nordic_frost = {
        id          = "nordic_frost",
        name        = "Nordic Frost",
        icon        = "❄",
        title_fg    = "\27[38;2;147;197;253m",
        border      = "\27[38;2;96;125;155m",
        row_bg_1    = "\27[48;2;24;33;47m",
        row_bg_2    = "\27[48;2;15;23;34m",
        hdr_bg      = "\27[48;2;44;62;80m",
        hdr_fg      = "\27[38;2;240;249;255m\27[1m",
        fg_text     = "\27[38;2;224;242;254m",
        fg_dim      = "\27[38;2;125;149;173m",
        fg_accent   = "\27[38;2;125;211;252m",
        fg_number   = "\27[38;2;253;186;116m",
        badge_green = "\27[48;2;19;78;74m\27[38;2;153;246;228m\27[1m",
        badge_blue  = "\27[48;2;30;58;138m\27[38;2;191;219;254m\27[1m",
        badge_amber = "\27[48;2;146;64;14m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;153;27;27m\27[38;2;254;202;202m\27[1m",
        badge_purple= "\27[48;2;88;28;135m\27[38;2;233;213;255m\27[1m",
    },
    solarized_amber = {
        id          = "solarized_amber",
        name        = "Solarized Amber",
        icon        = "🔥",
        title_fg    = "\27[38;2;251;191;36m",
        border      = "\27[38;2;180;110;45m",
        row_bg_1    = "\27[48;2;35;23;14m",
        row_bg_2    = "\27[48;2;24;15;8m",
        hdr_bg      = "\27[48;2;69;35;10m",
        hdr_fg      = "\27[38;2;254;243;199m\27[1m",
        fg_text     = "\27[38;2;254;242;218m",
        fg_dim      = "\27[38;2;168;134;105m",
        fg_accent   = "\27[38;2;245;158;11m",
        fg_number   = "\27[38;2;253;224;71m",
        badge_green = "\27[48;2;32;90;40m\27[38;2;187;247;208m\27[1m",
        badge_blue  = "\27[48;2;30;64;175m\27[38;2;191;219;254m\27[1m",
        badge_amber = "\27[48;2;154;80;10m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;153;27;27m\27[38;2;254;202;202m\27[1m",
        badge_purple= "\27[48;2;107;33;168m\27[38;2;243;232;255m\27[1m",
    },
    crimson_shadow = {
        id          = "crimson_shadow",
        name        = "Crimson Shadow",
        icon        = "◆",
        title_fg    = "\27[38;2;251;113;133m",
        border      = "\27[38;2;159;30;54m",
        row_bg_1    = "\27[48;2;33;12;18m",
        row_bg_2    = "\27[48;2;22;7;11m",
        hdr_bg      = "\27[48;2;69;10;25m",
        hdr_fg      = "\27[38;2;255;228;230m\27[1m",
        fg_text     = "\27[38;2;254;226;226m",
        fg_dim      = "\27[38;2;158;110;120m",
        fg_accent   = "\27[38;2;244;63;94m",
        fg_number   = "\27[38;2;251;146;60m",
        badge_green = "\27[48;2;22;101;52m\27[38;2;187;247;208m\27[1m",
        badge_blue  = "\27[48;2;30;64;175m\27[38;2;191;219;254m\27[1m",
        badge_amber = "\27[48;2;146;64;14m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;153;27;27m\27[38;2;254;202;202m\27[1m",
        badge_purple= "\27[48;2;100;20;80m\27[38;2;244;210;240m\27[1m",
    },
    carbon_monochrome = {
        id          = "carbon_monochrome",
        name        = "Carbon Monochrome",
        icon        = "⌘",
        title_fg    = "\27[38;2;245;245;245m",
        border      = "\27[38;2;110;110;110m",
        row_bg_1    = "\27[48;2;26;26;26m",
        row_bg_2    = "\27[48;2;16;16;16m",
        hdr_bg      = "\27[48;2;48;48;48m",
        hdr_fg      = "\27[38;2;255;255;255m\27[1m",
        fg_text     = "\27[38;2;220;220;220m",
        fg_dim      = "\27[38;2;120;120;120m",
        fg_accent   = "\27[38;2;255;255;255m\27[1m",
        fg_number   = "\27[38;2;200;200;200m",
        badge_green = "\27[48;2;35;50;35m\27[38;2;210;245;210m\27[1m",
        badge_blue  = "\27[48;2;35;45;65m\27[38;2;210;230;255m\27[1m",
        badge_amber = "\27[48;2;60;50;25m\27[38;2;255;245;190m\27[1m",
        badge_red   = "\27[48;2;65;30;30m\27[38;2;255;210;210m\27[1m",
        badge_purple= "\27[48;2;50;35;65m\27[38;2;240;210;255m\27[1m",
    },
    ocean_deep = {
        id          = "ocean_deep",
        name        = "Oceanic Deep",
        icon        = "🌊",
        title_fg    = "\27[38;2;45;212;191m",
        border      = "\27[38;2;20;140;150m",
        row_bg_1    = "\27[48;2;12;32;42m",
        row_bg_2    = "\27[48;2;7;20;28m",
        hdr_bg      = "\27[48;2;15;55;70m",
        hdr_fg      = "\27[38;2;230;255;255m\27[1m",
        fg_text     = "\27[38;2;204;251;241m",
        fg_dim      = "\27[38;2;94;148;155m",
        fg_accent   = "\27[38;2;45;212;191m",
        fg_number   = "\27[38;2;251;146;60m",
        badge_green = "\27[48;2;13;100;80m\27[38;2;167;243;208m\27[1m",
        badge_blue  = "\27[48;2;14;116;144m\27[38;2;186;230;253m\27[1m",
        badge_amber = "\27[48;2;180;83;9m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;190;24;45m\27[38;2;254;205;211m\27[1m",
        badge_purple= "\27[48;2;109;40;217m\27[38;2;237;233;254m\27[1m",
    },
    synthwave_80s = {
        id          = "synthwave_80s",
        name        = "Synthwave 80s",
        icon        = "▲",
        title_fg    = "\27[38;2;244;114;182m",
        border      = "\27[38;2;168;85;247m",
        row_bg_1    = "\27[48;2;28;16;38m",
        row_bg_2    = "\27[48;2;18;10;26m",
        hdr_bg      = "\27[48;2;58;12;80m",
        hdr_fg      = "\27[38;2;255;255;255m\27[1m",
        fg_text     = "\27[38;2;245;235;255m",
        fg_dim      = "\27[38;2;150;120;175m",
        fg_accent   = "\27[38;2;56;189;248m",
        fg_number   = "\27[38;2;250;204;21m",
        badge_green = "\27[48;2;5;150;105m\27[38;2;209;250;229m\27[1m",
        badge_blue  = "\27[48;2;30;64;175m\27[38;2;191;219;254m\27[1m",
        badge_amber = "\27[48;2;180;83;9m\27[38;2;254;240;138m\27[1m",
        badge_red   = "\27[48;2;225;29;72m\27[38;2;255;228;230m\27[1m",
        badge_purple= "\27[48;2;124;58;237m\27[38;2;245;243;255m\27[1m",
    },
    autumn_ember = {
        id          = "autumn_ember",
        name        = "Autumn Ember",
        icon        = "🍁",
        title_fg    = "\27[38;2;249;115;22m",
        border      = "\27[38;2;154;74;20m",
        row_bg_1    = "\27[48;2;36;20;14m",
        row_bg_2    = "\27[48;2;24;13;8m",
        hdr_bg      = "\27[48;2;76;29;15m",
        hdr_fg      = "\27[38;2;254;243;199m\27[1m",
        fg_text     = "\27[38;2;254;240;222m",
        fg_dim      = "\27[38;2;160;118;90m",
        fg_accent   = "\27[38;2;251;146;60m",
        fg_number   = "\27[38;2;234;179;8m",
        badge_green = "\27[48;2;40;80;30m\27[38;2;190;240;180m\27[1m",
        badge_blue  = "\27[48;2;30;60;120m\27[38;2;190;220;255m\27[1m",
        badge_amber = "\27[48;2;150;75;15m\27[38;2;254;240;150m\27[1m",
        badge_red   = "\27[48;2;160;25;25m\27[38;2;255;210;210m\27[1m",
        badge_purple= "\27[48;2;90;30;110m\27[38;2;240;210;255m\27[1m",
    },
    amethyst_haze = {
        id          = "amethyst_haze",
        name        = "Amethyst Haze",
        icon        = "💎",
        title_fg    = "\27[38;2;168;85;247m",
        border      = "\27[38;2;124;58;237m",
        row_bg_1    = "\27[48;2;26;18;42m",
        row_bg_2    = "\27[48;2;17;11;28m",
        hdr_bg      = "\27[48;2;55;25;85m",
        hdr_fg      = "\27[38;2;245;243;255m\27[1m",
        fg_text     = "\27[38;2;237;233;254m",
        fg_dim      = "\27[38;2;140;120;170m",
        fg_accent   = "\27[38;2;192;132;252m",
        fg_number   = "\27[38;2;244;114;182m",
        badge_green = "\27[48;2;20;85;50m\27[38;2;180;245;210m\27[1m",
        badge_blue  = "\27[48;2;40;50;130m\27[38;2;200;215;255m\27[1m",
        badge_amber = "\27[48;2;130;70;20m\27[38;2;254;230;160m\27[1m",
        badge_red   = "\27[48;2;150;25;40m\27[38;2;255;205;215m\27[1m",
        badge_purple= "\27[48;2;95;35;140m\27[38;2;235;215;255m\27[1m",
    },
}

local THEME_KEYS = {
    "tokyo_night",
    "cyberpunk",
    "emerald_matrix",
    "dracula",
    "nordic_frost",
    "solarized_amber",
    "crimson_shadow",
    "carbon_monochrome",
    "ocean_deep",
    "synthwave_80s",
    "autumn_ember",
    "amethyst_haze",
}

-- Inject standard ANSI typography tokens into each theme
for _, t in pairs(THEMES) do
    t.reset  = "\27[0m"
    t.bold   = "\27[1m"
    t.dim    = "\27[2m"
    t.italic = "\27[3m"
end

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
-- 3. Box Drawing Styles (9 Border Styles)
-- =========================================================================
local BOX_STYLES = {
    rounded = {
        id           = "rounded",
        name         = "Rounded Modern",
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
    },
    sharp = {
        id           = "sharp",
        name         = "Crisp Sharp",
        top_left     = "┌",
        top_right    = "┐",
        bottom_left  = "└",
        bottom_right = "┘",
        horiz        = "─",
        vert         = "│",
        top_tee      = "┬",
        bottom_tee   = "┴",
        left_tee     = "├",
        right_tee    = "┤",
        cross        = "┼",
    },
    double = {
        id           = "double",
        name         = "Classic Double",
        top_left     = "╔",
        top_right    = "╗",
        bottom_left  = "╚",
        bottom_right = "╝",
        horiz        = "═",
        vert         = "║",
        top_tee      = "╦",
        bottom_tee   = "╩",
        left_tee     = "╠",
        right_tee    = "╣",
        cross        = "╬",
    },
    heavy = {
        id           = "heavy",
        name         = "Heavy Bold",
        top_left     = "┏",
        top_right    = "┓",
        bottom_left  = "┗",
        bottom_right = "┛",
        horiz        = "━",
        vert         = "┃",
        top_tee      = "┳",
        bottom_tee   = "┻",
        left_tee     = "┣",
        right_tee    = "┫",
        cross        = "╋",
    },
    hybrid = {
        id           = "hybrid",
        name         = "Double-Horizontal Hybrid",
        top_left     = "╒",
        top_right    = "╕",
        bottom_left  = "╘",
        bottom_right = "╛",
        horiz        = "═",
        vert         = "│",
        top_tee      = "╤",
        bottom_tee   = "╧",
        left_tee     = "╞",
        right_tee    = "╡",
        cross        = "╪",
    },
    vertical_double = {
        id           = "vertical_double",
        name         = "Double-Vertical Columnar",
        top_left     = "╓",
        top_right    = "╖",
        bottom_left  = "╙",
        bottom_right = "╜",
        horiz        = "─",
        vert         = "║",
        top_tee      = "╥",
        bottom_tee   = "╨",
        left_tee     = "╟",
        right_tee    = "╢",
        cross        = "╫",
    },
    dashed = {
        id           = "dashed",
        name         = "Dashed Technical",
        top_left     = "┌",
        top_right    = "┐",
        bottom_left  = "└",
        bottom_right = "┘",
        horiz        = "┄",
        vert         = "┆",
        top_tee      = "┬",
        bottom_tee   = "┴",
        left_tee     = "├",
        right_tee    = "┤",
        cross        = "┼",
    },
    dotted = {
        id           = "dotted",
        name         = "Dotted Technical",
        top_left     = "┌",
        top_right    = "┐",
        bottom_left  = "└",
        bottom_right = "┘",
        horiz        = "┈",
        vert         = "┊",
        top_tee      = "┬",
        bottom_tee   = "┴",
        left_tee     = "├",
        right_tee    = "┤",
        cross        = "┼",
    },
    ascii = {
        id           = "ascii",
        name         = "Vintage ASCII",
        top_left     = "+",
        top_right    = "+",
        bottom_left  = "+",
        bottom_right = "+",
        horiz        = "-",
        vert         = "|",
        top_tee      = "+",
        bottom_tee   = "+",
        left_tee     = "+",
        right_tee    = "+",
        cross        = "+",
    },
}

local BOX_KEYS = {
    "rounded",
    "sharp",
    "double",
    "heavy",
    "hybrid",
    "vertical_double",
    "dashed",
    "dotted",
    "ascii",
}

-- Resolvers for style and theme options
local function resolve_box_style(style_opt)
    if type(style_opt) == "table" and style_opt.top_left then
        return style_opt
    elseif type(style_opt) == "string" and BOX_STYLES[style_opt:lower()] then
        return BOX_STYLES[style_opt:lower()]
    end
    -- Pick random
    return BOX_STYLES[BOX_KEYS[math.random(#BOX_KEYS)]]
end

local function resolve_theme(theme_opt)
    if type(theme_opt) == "table" and theme_opt.border then
        return theme_opt
    elseif type(theme_opt) == "string" and THEMES[theme_opt:lower()] then
        return THEMES[theme_opt:lower()]
    end
    -- Pick random
    return THEMES[THEME_KEYS[math.random(#THEME_KEYS)]]
end

-- =========================================================================
-- 4. Table Renderer Engine
-- =========================================================================
local function render_table(options)
    local title     = options.title
    local subtitle  = options.subtitle
    local columns   = options.columns
    local rows      = options.rows
    local term_w    = get_terminal_width()
    local BOX       = resolve_box_style(options.box_style)
    local C         = resolve_theme(options.theme)

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
        local icon = C.icon or "✦"
        table.insert(out, "\n  " .. C.bold .. C.title_fg .. icon .. " " .. title .. C.reset)
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
        local safe_hdr = cell_text:gsub("\27%[0?m", "%1" .. C.hdr_bg .. C.hdr_fg)
        table.insert(hdr_parts, C.hdr_bg .. " " .. C.hdr_fg .. safe_hdr .. C.reset .. " " .. C.border .. BOX.vert)
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
            -- Reapply background and text color after any embedded ANSI reset
            local safe_content = padded:gsub("\27%[0?m", "%1" .. row_bg .. C.fg_text)
            table.insert(row_parts, row_bg .. " " .. C.fg_text .. safe_content .. C.reset .. " " .. C.border .. BOX.vert)
        end

        table.insert(row_parts, C.reset .. "\n")
        table.insert(out, table.concat(row_parts))
    end

    -- Bottom border
    table.insert(out, "  " .. btm_border)

    -- Footer summary with active style telemetry
    table.insert(out, string.format("  %s%d records listed | Terminal width: %d cols | Style: %s • Theme: %s%s\n\n",
        C.dim, #rows, term_w, BOX.name, C.name, C.reset))

    io.write(table.concat(out))
    io.flush()
end

-- =========================================================================
-- 5. Demonstration Data Builder
-- =========================================================================
local function build_demo_rows(C)
    return {
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
end

-- =========================================================================
-- 6. CLI Argument Parser & Showcase
-- =========================================================================
local function parse_args(args)
    local opts = {}
    if not args then return opts end
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-b" or a == "--box" or a == "--style" then
            i = i + 1
            opts.box = args[i]
        elseif a:match("^%-%-box=(.+)$") then
            opts.box = a:match("^%-%-box=(.+)$")
        elseif a:match("^%-%-style=(.+)$") then
            opts.box = a:match("^%-%-style=(.+)$")
        elseif a == "-t" or a == "--theme" or a == "--color" then
            i = i + 1
            opts.theme = args[i]
        elseif a:match("^%-%-theme=(.+)$") then
            opts.theme = a:match("^%-%-theme=(.+)$")
        elseif a:match("^%-%-color=(.+)$") then
            opts.theme = a:match("^%-%-color=(.+)$")
        elseif a == "-l" or a == "--list" then
            opts.list = true
        elseif a == "-s" or a == "--showcase" or a == "--all" then
            opts.showcase = true
        elseif a == "-h" or a == "--help" then
            opts.help = true
        end
        i = i + 1
    end
    return opts
end

local function print_help()
    print([[
table_demo.lua - Modern Terminal Table Renderer

Usage:
  luajit table_demo.lua [options]

Options:
  (no args)             Vary table style and theme randomly every run
  -b, --box <style>     Select a specific box-drawing style
  -t, --theme <name>    Select a specific color theme
  -l, --list            List all available box styles and themes
  -s, --showcase        Demonstrate all box styles and themes
  -h, --help            Show this help message
]])
end

local function print_list()
    print("\n\27[1;38;2;129;140;248m✦ AVAILABLE BOX STYLES (9):\27[0m")
    for _, key in ipairs(BOX_KEYS) do
        local b = BOX_STYLES[key]
        local sample = string.format("%s%s%s%s%s %s %s%s%s%s%s",
            b.top_left, b.horiz, b.top_tee, b.horiz, b.top_right,
            b.vert,
            b.bottom_left, b.horiz, b.bottom_tee, b.horiz, b.bottom_right)
        print(string.format("  %-18s \27[38;2;148;163;184m%-28s\27[0m %s", key, "(" .. b.name .. ")", sample))
    end

    print("\n\27[1;38;2;129;140;248m✦ AVAILABLE COLOR THEMES (12):\27[0m")
    for _, key in ipairs(THEME_KEYS) do
        local t = THEMES[key]
        local preview = string.format("%s%s %-20s\27[0m %s[border]\27[0m %s[header]\27[0m %s[accent]\27[0m",
            t.title_fg, t.icon or "✦", t.name, t.border, t.hdr_bg .. t.hdr_fg, t.fg_accent)
        print(string.format("  %-18s %s", key, preview))
    end
    print("")
end

local function run_showcase()
    local columns = {
        { header = "STYLE ID", align = "center" },
        { header = "STYLE NAME", align = "left" },
        { header = "SAMPLE THEME", align = "left" },
        { header = "STATUS", align = "center" },
    }

    for idx, box_key in ipairs(BOX_KEYS) do
        local theme_key = THEME_KEYS[((idx - 1) % #THEME_KEYS) + 1]
        local box = BOX_STYLES[box_key]
        local theme = THEMES[theme_key]
        local rows = {
            {
                theme.fg_dim .. "#" .. idx .. theme.reset,
                theme.bold .. theme.fg_accent .. box.name .. theme.reset,
                theme.title_fg .. (theme.icon or "✦") .. " " .. theme.name .. theme.reset,
                theme.badge_green .. " ACTIVE " .. theme.reset,
            },
        }

        render_table({
            title     = "SHOWCASE: " .. box.name:upper(),
            subtitle  = "Paired with theme: " .. theme.name,
            columns   = columns,
            rows      = rows,
            box_style = box,
            theme     = theme,
        })
    end
end

-- =========================================================================
-- 7. Main Execution
-- =========================================================================
local function main(args)
    seed_random()
    local opts = parse_args(args)

    if opts.help then
        print_help()
        return
    end

    if opts.list then
        print_list()
        return
    end

    if opts.showcase then
        run_showcase()
        return
    end

    -- Randomly select box style and theme, unless specifically overridden via CLI
    local selected_box   = resolve_box_style(opts.box)
    local selected_theme = resolve_theme(opts.theme)

    local columns = {
        { header = "ID",        align = "center" },
        { header = "SERVICE",   align = "left"   },
        { header = "VERSION",   align = "center" },
        { header = "STATUS",    align = "center" },
        { header = "LATENCY",   align = "right"  },
        { header = "MEMORY",    align = "right"  },
        { header = "UPTIME",    align = "left"   },
    }

    local rows = build_demo_rows(selected_theme)

    render_table({
        title     = "MICROSERVICE CLUSTER DASHBOARD",
        subtitle  = "Production Nodes • Health & Telemetry Metrics",
        columns   = columns,
        rows      = rows,
        box_style = selected_box,
        theme     = selected_theme,
    })
end

-- Export module API
local M = {
    render_table       = render_table,
    BOX_STYLES         = BOX_STYLES,
    BOX_KEYS           = BOX_KEYS,
    THEMES             = THEMES,
    THEME_KEYS         = THEME_KEYS,
    resolve_box_style  = resolve_box_style,
    resolve_theme      = resolve_theme,
    seed_random        = seed_random,
    get_terminal_width = get_terminal_width,
    visual_length      = visual_length,
    pad_string         = pad_string,
    build_demo_rows    = build_demo_rows,
    main               = main,
    -- Backward compatibility aliases
    C                  = THEMES.tokyo_night,
    BOX                = BOX_STYLES.rounded,
}

-- Execute main when run directly
local is_main = false
if arg and arg[0] and arg[0]:match("table_demo%.lua$") then
    is_main = true
elseif not pcall(debug.getlocal, 4, 1) then
    is_main = true
end

if is_main then
    main(arg)
end

return M
