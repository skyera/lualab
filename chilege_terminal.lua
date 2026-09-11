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
-- 1. FFI POSIX Terminal Window Size
-- =========================================================================
ffi.cdef[[
    struct winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };
    int ioctl(int fd, unsigned long request, void *argp);

    typedef struct {
        uint8_t r, g, b;
    } PixelRGB;
]]

local TIOCGWINSZ = 0x5413

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
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
local function draw_chile_landscape(width, height)
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
        return height * 0.38 + m1 + m2 + m3
    end

    -- Rolling Steppe Grassland (敕勒川，天苍苍，野茫茫)
    local function hill1_y(x)
        return height * 0.54 + math.sin(x * 0.05) * (height * 0.05)
    end
    local function hill2_y(x)
        return height * 0.70 + math.sin(x * 0.035 + 2.1) * (height * 0.06)
    end

    -- Yurt (穹庐) position
    local yurt_cx = math.floor(width * 0.72)
    local yurt_cy = math.floor(hill1_y(yurt_cx))
    local yurt_rad = math.max(3, math.floor(height * 0.08))

    -- Sheep & cattle positions (见牛羊)
    local animals = {
        { x = math.floor(width * 0.22), y = math.floor(hill2_y(width * 0.22) + 2), type = "cow" },
        { x = math.floor(width * 0.26), y = math.floor(hill2_y(width * 0.26) + 3), type = "calf" },
        { x = math.floor(width * 0.40), y = math.floor(hill2_y(width * 0.40) + 1), type = "sheep" },
        { x = math.floor(width * 0.43), y = math.floor(hill2_y(width * 0.43) + 2), type = "sheep" },
        { x = math.floor(width * 0.47), y = math.floor(hill2_y(width * 0.47) + 1), type = "sheep" },
        { x = math.floor(width * 0.82), y = math.floor(hill1_y(width * 0.82) + 1), type = "sheep" },
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
            local cloud_density = math.sin(x * 0.08) * math.cos(y * 0.15)
            if cloud_dist < height * 0.08 and cloud_density > 0.3 then
                pixel = lerp_rgb(pixel, { r = 250, g = 252, b = 255 }, 0.55)
            end

            -- 2. Yin Mountain Ridge (阴山)
            local ym = mountain_y(x)
            if y >= ym and y < hill1_y(x) then
                local mt = (y - ym) / (hill1_y(x) - ym)
                local mountain_crest = { r = 95,  g = 120, b = 155 } -- Slate blue haze
                local mountain_base  = { r = 70,  g = 105, b = 125 }
                pixel = lerp_rgb(mountain_crest, mountain_base, mt)
                -- Crest sunlight rim
                if y <= ym + 1.2 then
                    pixel = lerp_rgb(pixel, { r = 180, g = 205, b = 230 }, 0.5)
                end
            end

            -- 3. Middle Steppe (敕勒川远景)
            local h1 = hill1_y(x)
            local h2 = hill2_y(x)
            if y >= h1 and y < h2 then
                local t = (y - h1) / (h2 - h1)
                local grass_far = { r = 110, g = 160, b = 80 }
                local grass_mid = { r = 75,  g = 135, b = 55 }
                pixel = lerp_rgb(grass_far, grass_mid, t)
            end

            -- 4. Foreground Steppe (天苍苍，野茫茫，风吹草低)
            if y >= h2 then
                local t = (y - h2) / (height - h2)
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
        if a.x >= 0 and a.x < width - 3 and a.y >= 0 and a.y < height - 2 then
            if a.type == "sheep" then
                -- White fluffy sheep
                buf[a.y * width + a.x]     = { r = 255, g = 255, b = 255 }
                buf[a.y * width + a.x + 1] = { r = 250, g = 250, b = 245 }
                buf[(a.y + 1) * width + a.x] = { r = 40, g = 30, b = 25 } -- Dark legs
            elseif a.type == "cow" then
                -- Brown prairie cattle
                buf[a.y * width + a.x]     = { r = 160, g = 95,  b = 45  }
                buf[a.y * width + a.x + 1] = { r = 145, g = 80,  b = 35  }
                buf[a.y * width + a.x + 2] = { r = 115, g = 60,  b = 25  }
                buf[(a.y + 1) * width + a.x + 1] = { r = 30, g = 25, b = 20 }
            end
        end
    end

    -- Return 24-bit Truecolor half-block ANSI string
    local out = {}
    for y = 0, height - 1, 2 do
        local line = {}
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
local function display_chilege()
    local term_w, term_h = get_terminal_size()
    local out = {}

    table.insert(out, "\27[H\27[2J") -- Clear screen & home

    -- Render Landscape backdrop (top half)
    local landscape_w = math.max(40, term_w)
    local landscape_h = math.max(16, math.floor(term_h * 0.75))
    table.insert(out, draw_chile_landscape(landscape_w, landscape_h))

    -- Classical Poem Card
    local card_w = math.min(term_w - 4, 76)
    local pad_l = math.max(0, math.floor((term_w - card_w) / 2))
    local p_str = string.rep(" ", pad_l)

    table.insert(out, "\n" .. p_str .. "\27[38;2;212;175;55m╭" .. string.rep("─", card_w - 2) .. "╮\27[0m\n")

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

display_chilege()
