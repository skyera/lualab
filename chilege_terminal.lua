--[[
    chilege_terminal.lua
    《敕勒歌》 Northern Dynasties Folk Song Terminal Presentation
    Written in LuaJIT using FFI and 24-bit Truecolor terminal rendering.

    Features:
    - POSIX ioctl(TIOCGWINSZ) via FFI for terminal size detection & auto-centering.
    - Full procedural grassland & yurt landscape backdrop matching the poem:
      "敕勒川，阴山下。天似穹庐，笼盖四野。天苍苍，野茫茫。风吹草低见牛羊。"
      (Yin Mountain ridges, boundless steppe, yurt under vast sky, grazing sheep & cattle)
    - Elegant Chinese classical typography card with verse-by-verse Pinyin and English poetic translation.
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. FFI Terminal Window Size & OS Initialization
-- =========================================================================
local is_windows = (ffi.os == "Windows")

ffi.cdef[[
    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;
]]

if is_windows then
    ffi.cdef[[
        typedef struct { short X; short Y; } COORD;
        typedef struct { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
        typedef struct {
            COORD      dwSize;
            COORD      dwCursorPosition;
            uint16_t   wAttributes;
            SMALL_RECT srWindow;
            COORD      dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;

        void* __stdcall GetStdHandle(uint32_t nStdHandle);
        int   __stdcall GetConsoleScreenBufferInfo(void* hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo);
        int   __stdcall GetConsoleMode(void* hConsoleHandle, uint32_t* lpMode);
        int   __stdcall SetConsoleMode(void* hConsoleHandle, uint32_t dwMode);
        int   __stdcall SetConsoleOutputCP(uint32_t wCodePageID);
    ]]

    -- Initialize Windows console for UTF-8 and ANSI Virtual Terminal Processing
    pcall(function()
        local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- ((uint32_t)-11)
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        ffi.C.SetConsoleOutputCP(65001) -- UTF-8

        local mode = ffi.new("uint32_t[1]")
        if ffi.C.GetConsoleMode(hOut, mode) ~= 0 then
            local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            local bit = require("bit")
            ffi.C.SetConsoleMode(hOut, bit.bor(mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        end
    end)
else
    ffi.cdef[[
        struct winsize {
            unsigned short ws_row;
            unsigned short ws_col;
            unsigned short ws_xpixel;
            unsigned short ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, void *argp);
    ]]
end

local TIOCGWINSZ = 0x5413

local function get_terminal_size()
    if is_windows then
        local STD_OUTPUT_HANDLE = 0xFFFFFFF5
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if ffi.C.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if w > 0 and h > 0 then
                return tonumber(w), tonumber(h)
            end
        end
    else
        local ws = ffi.new("struct winsize")
        if pcall(function() return ffi.C.ioctl(1, TIOCGWINSZ, ws) end) and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
    end
    return 80, 24
end

-- Math utilities
local function clamp(v, min_v, max_v)
    if v < min_v then return min_v end
    if v > max_v then return max_v end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerp_rgb(c1, c2, t)
    t = clamp(t, 0.0, 1.0)
    return {
        r = math.floor(lerp(c1.r, c2.r, t)),
        g = math.floor(lerp(c1.g, c2.g, t)),
        b = math.floor(lerp(c1.b, c2.b, t)),
    }
end

-- =========================================================================
-- 2. Procedural Landscape: 敕勒川 (Chile Steppe, Yin Mountains, Yurt, Sheep)
-- =========================================================================
local function draw_chile_landscape(width, height, pad_str)
    pad_str = pad_str or ""
    local buf = ffi.new("PixelRGB[?]", width * height)

    -- Sky palette: "天似穹庐，笼盖四野" (Vast dome sky)
    local sky_zenith  = { r = 20,  g = 70,  b = 150 } -- Deep vast steppe blue
    local sky_mid     = { r = 100, g = 170, b = 230 } -- Clear azure
    local sky_horizon = { r = 240, g = 225, b = 195 } -- Hazy steppe horizon

    -- Yin Mountain Ridge (阴山)
    local function mountain_y(x)
        local nx = x / width
        local m1 = math.sin(nx * 5.5) * (height * 0.08)
        local m2 = math.cos(nx * 11.2) * (height * 0.04)
        local m3 = math.sin(nx * 22.0) * (height * 0.02)
        return height * 0.36 + m1 + m2 + m3
    end

    -- Rolling Steppe Grassland (敕勒川，天苍苍，野茫茫)
    local function hill1_y(x)
        local nx = x / width
        return height * 0.54 + math.sin(nx * 6.28) * (height * 0.05)
    end
    local function hill2_y(x)
        local nx = x / width
        return height * 0.70 + math.sin(nx * 5.0 + 2.1) * (height * 0.05)
    end

    -- Yurt (穹庐) position
    local yurt_cx = math.floor(width * 0.74)
    local yurt_cy = math.floor(hill1_y(yurt_cx))
    local yurt_rad = math.max(2, math.floor(height * 0.08))

    -- Sheep & cattle positions (见牛羊)
    local animals = {
        { x = math.floor(width * 0.22), y = math.floor(hill2_y(math.floor(width * 0.22))), type = "cow" },
        { x = math.floor(width * 0.27), y = math.floor(hill2_y(math.floor(width * 0.27)) + 1), type = "calf" },
        { x = math.floor(width * 0.40), y = math.floor(hill2_y(math.floor(width * 0.40))), type = "sheep" },
        { x = math.floor(width * 0.44), y = math.floor(hill2_y(math.floor(width * 0.44)) + 1), type = "sheep" },
        { x = math.floor(width * 0.48), y = math.floor(hill2_y(math.floor(width * 0.48))), type = "sheep" },
        { x = math.floor(width * 0.84), y = math.floor(hill1_y(math.floor(width * 0.84))), type = "sheep" },
    }

    for y = 0, height - 1 do
        local ny = y / height
        for x = 0, width - 1 do
            local idx = y * width + x
            local pixel

            -- 1. Vast Sky
            if ny < 0.25 then
                pixel = lerp_rgb(sky_zenith, sky_mid, ny / 0.25)
            else
                pixel = lerp_rgb(sky_mid, sky_horizon, clamp((ny - 0.25) / 0.25, 0.0, 1.0))
            end

            -- Subtle steppe clouds
            local cloud_dist = math.abs(y - height * 0.18)
            local cloud_density = math.sin((x / width) * 8.0) * math.cos(ny * 12.0)
            if cloud_dist < height * 0.08 and cloud_density > 0.3 then
                pixel = lerp_rgb(pixel, { r = 250, g = 252, b = 255 }, 0.55)
            end

            -- 2. Yin Mountain Ridge (阴山)
            local ym = mountain_y(x)
            local h1 = hill1_y(x)
            local h2 = hill2_y(x)

            if y >= ym and y < h1 then
                local mt = (y - ym) / math.max(0.01, (h1 - ym))
                local mountain_crest = { r = 95,  g = 120, b = 155 } -- Slate blue haze
                local mountain_base  = { r = 70,  g = 105, b = 125 }
                pixel = lerp_rgb(mountain_crest, mountain_base, mt)
                -- Crest sunlight rim
                if y <= ym + 1.1 then
                    pixel = lerp_rgb(pixel, { r = 180, g = 205, b = 230 }, 0.5)
                end
            elseif y >= h1 and y < h2 then
                -- 3. Middle Steppe (敕勒川远景)
                local t = (y - h1) / math.max(0.01, (h2 - h1))
                local grass_far = { r = 110, g = 160, b = 80 }
                local grass_mid = { r = 75,  g = 135, b = 55 }
                pixel = lerp_rgb(grass_far, grass_mid, t)
            elseif y >= h2 then
                -- 4. Foreground Steppe (天苍苍，野茫茫，风吹草低)
                local t = (y - h2) / math.max(0.01, (height - h2))
                local grass_near = { r = 90, g = 180, b = 50 }
                local grass_deep = { r = 35, g = 115, b = 30 }
                pixel = lerp_rgb(grass_near, grass_deep, t)
                -- Wind-blown grass wave highlight (风吹草低)
                local wave = math.sin(x * 0.22 + y * 0.15) * 0.1
                pixel = lerp_rgb(pixel, { r = 140, g = 215, b = 65 }, wave + 0.1)
            end

            -- 5. Mongolian Yurt (穹庐)
            local ydx = (x - yurt_cx) * 0.8
            local ydy = (y - yurt_cy)
            local ydist = math.sqrt(ydx * ydx + ydy * ydy)
            if ydist < yurt_rad and y <= yurt_cy + yurt_rad * 0.6 then
                -- White felt dome
                pixel = { r = 245, g = 240, b = 230 }
                -- Red decorative trim on yurt
                if y == math.floor(yurt_cy) or math.abs(ydist - yurt_rad) < 0.8 then
                    pixel = { r = 210, g = 50, b = 50 }
                end
            end

            buf[idx].r = pixel.r
            buf[idx].g = pixel.g
            buf[idx].b = pixel.b
        end
    end

    -- 6. Stamp Grazing Cattle & Sheep (风吹草低见牛羊)
    for _, a in ipairs(animals) do
        local ay = math.min(height - 2, math.max(0, a.y))
        local ax = math.min(width - 3, math.max(0, a.x))
        if a.type == "sheep" then
            -- White fluffy sheep
            buf[ay * width + ax]     = { r = 255, g = 255, b = 255 }
            buf[ay * width + ax + 1] = { r = 250, g = 250, b = 245 }
            if ay + 1 < height then
                buf[(ay + 1) * width + ax] = { r = 40, g = 30, b = 25 } -- Dark legs
            end
        elseif a.type == "cow" then
            -- Brown prairie cattle
            buf[ay * width + ax]     = { r = 160, g = 95,  b = 45  }
            buf[ay * width + ax + 1] = { r = 145, g = 80,  b = 35  }
            if ax + 2 < width then
                buf[ay * width + ax + 2] = { r = 115, g = 60,  b = 25  }
            end
            if ay + 1 < height and ax + 1 < width then
                buf[(ay + 1) * width + ax + 1] = { r = 30, g = 25, b = 20 }
            end
        end
    end

    -- Return 24-bit Truecolor half-block ANSI string
    local out = {}
    for y = 0, height - 1, 2 do
        local line = { pad_str }
        for x = 0, width - 1 do
            local top = buf[y * width + x]
            local bot_y = math.min(height - 1, y + 1)
            local bot = buf[bot_y * width + x]
            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                top.r, top.g, top.b,
                bot.r, bot.g, bot.b
            ))
        end
        table.insert(line, "\27[0m\n")
        table.insert(out, table.concat(line))
    end
    return table.concat(out)
end

-- =========================================================================
-- 3. Display Poem & Landscape
-- =========================================================================
local function display_chilege(opt_w, opt_h)
    local term_w, term_h = get_terminal_size()
    local out = {}

    table.insert(out, "\27[H\27[2J") -- Clear screen & home

    -- Classical Poem Card
    local card_w = math.min(term_w - 4, 76)
    local pad_l = math.max(0, math.floor((term_w - card_w) / 2))
    local p_str = string.rep(" ", pad_l)

    -- Sizing the landscape image to be a compact vignette centered above the card
    local landscape_w = opt_w or math.min(card_w - 6, 56)
    if landscape_w < 24 then landscape_w = 24 end
    if landscape_w > term_w then landscape_w = term_w end

    local landscape_h = opt_h or 10 -- 10 pixels = 5 terminal rows
    if landscape_h % 2 ~= 0 then landscape_h = landscape_h + 1 end

    local img_pad = string.rep(" ", math.max(0, math.floor((term_w - landscape_w) / 2)))

    table.insert(out, "\n")
    table.insert(out, draw_chile_landscape(landscape_w, landscape_h, img_pad))

    table.insert(out, p_str .. "\27[38;2;212;175;55m╭" .. string.rep("─", card_w - 2) .. "╮\27[0m\n")

    -- Helper function to calculate exact visual character cell width
    -- (Chinese/CJK characters & full-width punctuation = 2 columns, ASCII = 1 column)
    local function visual_width(str)
        local w = 0
        for c in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if #c == 1 then
                w = w + 1
            else
                w = w + 2
            end
        end
        return w
    end

    local function make_card_row(text, text_color)
        local content_w = visual_width(text)
        local inner_w = card_w - 2
        local pad_left = math.max(0, math.floor((inner_w - content_w) / 2))
        local pad_right = math.max(0, inner_w - pad_left - content_w)

        return p_str .. "\27[38;2;212;175;55m│\27[0m" ..
            string.rep(" ", pad_left) ..
            text_color .. text .. "\27[0m" ..
            string.rep(" ", pad_right) ..
            "\27[38;2;212;175;55m│\27[0m\n"
    end

    -- Title
    local title = "【 北朝民歌 】《 敕 勒 歌 》"
    table.insert(out, make_card_row(title, "\27[1;38;2;255;225;120m"))

    table.insert(out, p_str .. "\27[38;2;212;175;55m├" .. string.rep("─", card_w - 2) .. "┤\27[0m\n")
    table.insert(out, p_str .. "\27[38;2;212;175;55m│\27[0m" .. string.rep(" ", card_w - 2) .. "\27[38;2;212;175;55m│\27[0m\n")

    local verses = {
        "敕 勒 川 ， 阴 山 下 。",
        "天 似 穹 庐 ， 笼 盖 四 野 。",
        "天 苍 苍 ， 野 茫 茫 。",
        "风 吹 草 低 见 牛 羊 。",
    }

    for _, v in ipairs(verses) do
        table.insert(out, make_card_row(v, "\27[1;38;2;255;255;245m"))
    end

    table.insert(out, p_str .. "\27[38;2;212;175;55m│\27[0m" .. string.rep(" ", card_w - 2) .. "\27[38;2;212;175;55m│\27[0m\n")
    table.insert(out, p_str .. "\27[38;2;212;175;55m├" .. string.rep("─", card_w - 2) .. "┤\27[0m\n")

    local eng_lines = {
        "\"By the Chile Plain, beneath the Yin Mountain range,",
        " The sky arches like a yurt, blanketing the vast wilderness.",
        " The boundless sky is blue, the steppe stretches far and wide,",
        " When the wind bends the grass low, cattle and sheep appear.\"",
    }

    for _, eng in ipairs(eng_lines) do
        table.insert(out, make_card_row(eng, "\27[38;2;180;195;210m"))
    end

    table.insert(out, p_str .. "\27[38;2;212;175;55m╰" .. string.rep("─", card_w - 2) .. "╯\27[0m\n\n")

    io.write(table.concat(out))
    io.flush()
end

display_chilege(tonumber(arg and arg[1]), tonumber(arg and arg[2]))
