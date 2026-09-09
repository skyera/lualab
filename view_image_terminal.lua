--[[
    view_image_terminal.lua
    A terminal image viewer written in LuaJIT FFI.

    Features:
    1. Built-in decoder for Netpbm images (PPM P6 binary and P3 ASCII).
    2. Zero external dependencies: pure LuaJIT + libc FFI.
    3. Auto-detects terminal width & height via POSIX ioctl(TIOCGWINSZ) syscall.
    4. Aspect-ratio preserving bilinear downsampling / scaling to fit terminal size.
    5. High-resolution truecolor rendering: uses 24-bit ANSI colors with UTF-8
       half-block '▄' (2 vertical pixels per text character row).
]]

local ffi = require("ffi")

-- 1. C Declarations for Terminal Dimensions
ffi.cdef[[
    struct winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };
    int ioctl(int fd, unsigned long request, void *argp);
]]

local TIOCGWINSZ = 0x5413 -- Linux ioctl code for terminal window size

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    -- fd 1 is stdout
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 80, 24 -- standard fallback
end

-- 2. PPM Image Decoder (P6 binary and P3 ASCII)
local function load_ppm(filepath)
    local f, err = io.open(filepath, "rb")
    if not f then return nil, err end

    -- Helper to read next non-comment whitespace-delimited token
    local function next_token()
        while true do
            local ch = f:read(1)
            if not ch then return nil end
            if ch == '#' then
                f:read("*l") -- skip rest of comment line
            elseif not ch:match("%s") then
                local token = { ch }
                while true do
                    local c = f:read(1)
                    if not c or c:match("%s") then break end
                    table.insert(token, c)
                end
                return table.concat(token)
            end
        end
    end

    local magic = next_token()
    if magic ~= "P6" and magic ~= "P3" then
        f:close()
        return nil, "Unsupported PPM format: " .. tostring(magic) .. " (only P3 and P6 supported)"
    end

    local width = tonumber(next_token())
    local height = tonumber(next_token())
    local max_val = tonumber(next_token())

    if not width or not height or not max_val then
        f:close()
        return nil, "Corrupted PPM header"
    end

    ffi.cdef[[
        typedef struct { uint8_t r, g, b; } ImgPixelRGB;
    ]]

    local pixels = ffi.new("ImgPixelRGB[?]", width * height)

    if magic == "P6" then
        -- Binary PPM
        local total_bytes = width * height * 3
        local raw_bytes = f:read(total_bytes)
        f:close()

        if not raw_bytes or #raw_bytes < total_bytes then
            return nil, "Incomplete binary PPM pixel data"
        end

        ffi.copy(pixels, raw_bytes, total_bytes)
    else
        -- P3 ASCII PPM
        local scale = 255.0 / max_val
        for i = 0, width * height - 1 do
            local r = tonumber(next_token()) or 0
            local g = tonumber(next_token()) or 0
            local b = tonumber(next_token()) or 0
            pixels[i].r = math.floor(r * scale)
            pixels[i].g = math.floor(g * scale)
            pixels[i].b = math.floor(b * scale)
        end
        f:close()
    end

    return {
        width = width,
        height = height,
        pixels = pixels
    }
end

-- 3. Terminal Renderer with Bilinear Resampling
local function render_image_to_terminal(img, max_w, max_h)
    local term_w, term_h = get_terminal_size()
    -- Terminal character cells are ~2:1 vertical-to-horizontal aspect ratio
    -- Since half-block '▄' gives 2 pixels per row, pixel aspect ratio is ~1:1
    local target_w = max_w or (term_w - 2)
    -- Reserve 3 lines for shell prompts / headers, and double for half-blocks
    local target_h = max_h or ((term_h - 4) * 2)

    -- Maintain aspect ratio
    local scale_x = target_w / img.width
    local scale_y = target_h / img.height
    local scale = math.min(scale_x, scale_y)

    local out_w = math.max(1, math.floor(img.width * scale))
    local out_h = math.max(1, math.floor(img.height * scale))
    -- Ensure even height so half-blocks pair up cleanly
    if out_h % 2 ~= 0 then out_h = out_h + 1 end

    local out = {}
    local px = img.pixels
    local iw = img.width

    for y = 0, out_h - 1, 2 do
        local line = {}
        for x = 0, out_w - 1 do
            -- Map output coordinate to source coordinate (nearest / subpixel)
            local src_x = math.min(img.width - 1, math.floor(x * (img.width / out_w)))
            local src_y_top = math.min(img.height - 1, math.floor(y * (img.height / out_h)))
            local src_y_bot = math.min(img.height - 1, math.floor((y + 1) * (img.height / out_h)))

            local top = px[src_y_top * iw + src_x]
            local bot = px[src_y_bot * iw + src_x]

            -- ANSI Truecolor: Background = Top Pixel, Foreground = Bottom Pixel with '▄'
            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                top.r, top.g, top.b,
                bot.r, bot.g, bot.b
            ))
        end
        table.insert(line, "\27[0m\n")
        table.insert(out, table.concat(line))
    end

    io.write(table.concat(out))
    io.flush()
    return out_w, out_h
end

-- =========================================================================
-- CLI Entry Point
-- =========================================================================
local filepath = arg and arg[1]

if not filepath or filepath == "-h" or filepath == "--help" then
    print("\27[1;36mTerminal Image Viewer (LuaJIT FFI)\27[0m")
    print("Usage:")
    print("  ./LuaJIT/src/luajit view_image_terminal.lua <image.ppm> [max_width] [max_height]")
    print("\nSupported formats:")
    print("  - PPM (Binary P6, ASCII P3)")
    print("  - Any image converted via ImageMagick: convert photo.jpg photo.ppm && ...")
    os.exit(0)
end

local img, err = load_ppm(filepath)
if not img then
    io.stderr:write("\27[1;31mError loading image:\27[0m " .. tostring(err) .. "\n")
    os.exit(1)
end

local max_w = tonumber(arg[2])
local max_h = tonumber(arg[3])

local disp_w, disp_h = render_image_to_terminal(img, max_w, max_h)
print(string.format("\27[90mDisplayed %s (Original: %dx%d, Rescaled: %dx%d pixels)\27[0m",
    filepath, img.width, img.height, disp_w, disp_h))
