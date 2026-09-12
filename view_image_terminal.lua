--[[
    view_image_terminal.lua
    A terminal image viewer written in LuaJIT FFI.

    Features:
    1. Built-in native Netpbm PPM decoder (P6 binary and P3 ASCII).
    2. Automatic fallback pipeline for PNG, JPG/JPEG, WEBP, GIF, BMP via ImageMagick / ffmpeg.
    3. Auto-detects terminal width & height via POSIX ioctl(TIOCGWINSZ) syscall.
    4. Aspect-ratio preserving downsampling to fit the terminal window.
    5. High-resolution truecolor rendering: uses 24-bit ANSI colors with UTF-8
       half-block '▄' (2 vertical pixels per text character row).
]]

local ffi = require("ffi")
local is_windows = (ffi.os == "Windows")
local kernel32

-- 1. C Declarations for Terminal Dimensions & Buffer
ffi.cdef[[
    typedef struct { uint8_t r, g, b; } ImgPixelRGB;
]]

if is_windows then
    kernel32 = ffi.load("kernel32")
    ffi.cdef[[
        typedef void *HANDLE;
        typedef struct _COORD { short X; short Y; } COORD;
        typedef struct _SMALL_RECT { short Left; short Top; short Right; short Bottom; } SMALL_RECT;
        typedef struct _CONSOLE_SCREEN_BUFFER_INFO {
            COORD      dwSize;
            COORD      dwCursorPosition;
            uint16_t   wAttributes;
            SMALL_RECT srWindow;
            COORD      dwMaximumWindowSize;
        } CONSOLE_SCREEN_BUFFER_INFO;
        HANDLE GetStdHandle(uint32_t nStdHandle);
        int GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, CONSOLE_SCREEN_BUFFER_INFO *lpConsoleScreenBufferInfo);
    ]]
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

local function get_terminal_size()
    if is_windows then
        local hOut = kernel32.GetStdHandle(0xFFFFFFF5) -- STD_OUTPUT_HANDLE = -11
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if kernel32.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if w > 0 and h > 0 then return tonumber(w), tonumber(h) end
        end
        return 80, 24
    else
        local ws = ffi.new("struct winsize")
        local TIOCGWINSZ = 0x5413
        -- fd 1 is stdout
        if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 80, 24 -- standard fallback
    end
end

-- 2. Parsing PPM Data from a File Handle or Pipe
local function parse_ppm_stream(f)
    local last_ws = nil
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
                    if not c or c:match("%s") then
                        last_ws = c
                        break
                    end
                    table.insert(token, c)
                end
                return table.concat(token)
            end
        end
    end

    local magic = next_token()
    if magic ~= "P6" and magic ~= "P3" then
        return nil, "Unsupported PPM magic header: " .. tostring(magic) .. " (expected P6 or P3)"
    end

    local width = tonumber(next_token())
    local height = tonumber(next_token())
    local max_val = tonumber(next_token())

    if not width or not height or not max_val then
        return nil, "Corrupted PPM header"
    end

    local pixels = ffi.new("ImgPixelRGB[?]", width * height)

    if magic == "P6" then
        -- Binary PPM: single whitespace separates max_val from binary data
        -- (next_token already consumed the whitespace character into last_ws)
        if last_ws == "\r" then
            local lf = f:read(1)
            if lf and lf ~= "\n" then
                -- if not \n, rare single carriage return
            end
        end
        local total_bytes = width * height * 3
        local raw_bytes = f:read(total_bytes)
        if not raw_bytes or #raw_bytes < total_bytes then
            return nil, "Incomplete binary PPM pixel stream"
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
    end

    return {
        width = width,
        height = height,
        pixels = pixels
    }
end

-- 3. Universal Image Loader (PPM, PNG, JPG, JPEG, WEBP, GIF, BMP)
local function load_image(filepath)
    -- Check if file exists
    local test_file = io.open(filepath, "rb")
    if not test_file then
        return nil, "Cannot open file: " .. filepath
    end

    -- Check first two bytes (Magic bytes)
    local header = test_file:read(2)
    test_file:close()

    -- If native PPM format (P6 or P3)
    if header == "P6" or header == "P3" then
        local f = io.open(filepath, "rb")
        local img, err = parse_ppm_stream(f)
        f:close()
        return img, err
    end

    -- For PNG, JPG, WEBP, GIF, BMP: Stream decode via ImageMagick (magick/convert) or ffmpeg
    local devnull = is_windows and "nul" or "/dev/null"
    local popen_rb = is_windows and "rb" or "r"
    local cmd
    if is_windows then
        cmd = string.format('magick %q ppm:- 2>%s', filepath, devnull)
    else
        cmd = string.format('magick %q ppm:- 2>%s || convert %q ppm:- 2>%s', filepath, devnull, filepath, devnull)
    end
    local pipe = io.popen(cmd, popen_rb)
    if pipe then
        local img = parse_ppm_stream(pipe)
        pipe:close()
        if img then return img end
    end

    -- Fallback to ffmpeg if ImageMagick is not found
    local ffmpeg_cmd = string.format('ffmpeg -v error -i %q -f image2pipe -vcodec ppm - 2>%s', filepath, devnull)
    local ffmpeg_pipe = io.popen(ffmpeg_cmd, popen_rb)
    if ffmpeg_pipe then
        local img = parse_ppm_stream(ffmpeg_pipe)
        ffmpeg_pipe:close()
        if img then return img end
    end

    return nil, "Failed to decode image format. Ensure the file is a valid image (PNG, JPG, PPM, BMP, WEBP)."
end

-- 4. Terminal Renderer with Bilinear Resampling
local function render_image_to_terminal(img, max_w, max_h)
    local term_w, term_h = get_terminal_size()
    local target_w = max_w or (term_w - 2)
    local target_h = max_h or ((term_h - 4) * 2)

    -- Maintain aspect ratio
    local scale_x = target_w / img.width
    local scale_y = target_h / img.height
    local scale = math.min(scale_x, scale_y)

    local out_w = math.max(1, math.floor(img.width * scale))
    local out_h = math.max(1, math.floor(img.height * scale))
    if out_h % 2 ~= 0 then out_h = out_h + 1 end

    local out = {}
    local px = img.pixels
    local iw = img.width

    for y = 0, out_h - 1, 2 do
        local line = {}
        for x = 0, out_w - 1 do
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
    print("\27[1;36mUniversal Terminal Image Viewer (LuaJIT FFI)\27[0m")
    print("Usage:")
    print("  ./LuaJIT/src/luajit view_image_terminal.lua <image_path> [max_width] [max_height]")
    print("\nSupported formats:")
    print("  - PNG, JPG/JPEG, WEBP, GIF, BMP, PPM")
    os.exit(0)
end

local img, err = load_image(filepath)
if not img then
    io.stderr:write("\27[1;31mError loading image:\27[0m " .. tostring(err) .. "\n")
    os.exit(1)
end

local max_w = tonumber(arg[2])
local max_h = tonumber(arg[3])

local disp_w, disp_h = render_image_to_terminal(img, max_w, max_h)
print(string.format("\27[90mDisplayed %s (Original: %dx%d, Rescaled: %dx%d pixels)\27[0m",
    filepath, img.width, img.height, disp_w, disp_h))
