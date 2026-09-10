--[[
    image_gallery_viewer.lua
    Interactive Terminal Directory Image Viewer written in LuaJIT FFI.

    Features:
    1. Directory Scanning:
       - Scans current working directory ('.') by default, or an input directory provided via argument / prompt.
       - Level 1 scanning only (does not search subdirectories).
       - Supports standard image formats: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP.
    2. Interactive File Selector:
       - Displays sorted list of image files with index numbers, filenames, file sizes, and modification dates.
       - Supports arrow keys (↑ / ↓), direct number entry, Enter/Space to view, 'q' to quit.
       - CLI direct selection flag: --select <n> or -s <n>.
       - Non-interactive / pipe friendly fallback.
    3. Terminal Truecolor Image Viewer:
       - High-resolution rendering using 24-bit ANSI colors with UTF-8 half-block '▄' (2 vertical pixels per text row).
       - Auto-detects terminal width & height via POSIX ioctl(TIOCGWINSZ) and scales image to fit cleanly.
       - Displays image dimensions, aspect ratio, and filename info.
       - In view mode: allows browsing previous/next images with ← / → / [P] / [N] or returning to menu with [Enter] / [B].
]]

local ffi = require("ffi")

-- =========================================================================
-- 1. C Declarations for POSIX, Terminal Window, Poll, Dirent, and Stat
-- =========================================================================
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

    typedef long time_t;
    struct stat {
        unsigned long  st_dev;
        unsigned long  st_ino;
        unsigned long  st_nlink;
        unsigned int   st_mode;
        unsigned int   st_uid;
        unsigned int   st_gid;
        unsigned long  st_rdev;
        long           st_size;
        long           st_blksize;
        long           st_blocks;
        time_t         st_atime;
        unsigned long  st_atime_nsec;
        time_t         st_mtime;
        unsigned long  st_mtime_nsec;
        time_t         st_ctime;
        unsigned long  st_ctime_nsec;
        long           __unused[3];
    };
    int stat(const char *pathname, struct stat *statbuf);

    typedef struct { uint8_t r, g, b; } PixelRGB;
]]

local TIOCGWINSZ = 0x5413
local STDIN_FILENO = 0
local TCSANOW = 0
local ICANON = 2
local ECHO = 8
local POLLIN = 1

local function get_terminal_size()
    local ws = ffi.new("struct winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return 80, 24
end

-- =========================================================================
-- 2. Raw Mode Input Management
-- =========================================================================
local orig_termios = ffi.new("struct termios")
local raw_termios = ffi.new("struct termios")
local raw_mode_enabled = false

local function enable_raw_mode()
    if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
    ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
    ffi.C.tcgetattr(STDIN_FILENO, raw_termios)

    raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
    ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
    raw_mode_enabled = true

    io.write("\27[?25l") -- Hide cursor
    io.flush()
    return true
end

local function disable_raw_mode()
    if raw_mode_enabled then
        io.write("\27[?25h\27[0m\n") -- Restore cursor and reset color
        io.flush()
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
        raw_mode_enabled = false
    end
end

local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
local key_buf = ffi.new("char[16]")

local function read_key(timeout_ms)
    timeout_ms = timeout_ms or -1
    local ret = ffi.C.poll(pfd, 1, timeout_ms)
    if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
        local n = ffi.C.read(STDIN_FILENO, key_buf, 16)
        if n > 0 then
            local c0 = key_buf[0]
            if c0 == 27 then -- ESC sequence
                if n >= 3 and key_buf[1] == 91 then
                    local c2 = key_buf[2]
                    if c2 == 65 then return "UP" end
                    if c2 == 66 then return "DOWN" end
                    if c2 == 67 then return "RIGHT" end
                    if c2 == 68 then return "LEFT" end
                end
                return "ESC"
            elseif c0 == 10 or c0 == 13 then
                return "ENTER"
            elseif c0 == 32 then
                return "SPACE"
            elseif c0 == 127 or c0 == 8 then
                return "BACKSPACE"
            else
                return string.char(c0):lower()
            end
        end
    end
    return nil
end

-- =========================================================================
-- 3. Directory Scanner (Level 1 only, no recursion)
-- =========================================================================
local SUPPORTED_EXTENSIONS = {
    png  = true,
    jpg  = true,
    jpeg = true,
    ppm  = true,
    webp = true,
    gif  = true,
    bmp  = true,
}

local function format_file_size(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.2f MB", bytes / (1024 * 1024))
    end
end

local function scan_directory_images(dir_path)
    dir_path = dir_path or "."
    -- Strip trailing slash if present (except root)
    if #dir_path > 1 and dir_path:sub(-1) == "/" then
        dir_path = dir_path:sub(1, -2)
    end

    local d = ffi.C.opendir(dir_path)
    if d == nil then
        return nil, "Could not open directory: " .. dir_path
    end

    local images = {}
    local st = ffi.new("struct stat")

    while true do
        local ent = ffi.C.readdir(d)
        if ent == nil then break end
        local fname = ffi.string(ent.d_name)

        -- Skip . and .. and hidden files
        if fname ~= "." and fname ~= ".." and not fname:match("^%.") then
            local ext = fname:match("%.([^.]+)$")
            if ext and SUPPORTED_EXTENSIONS[ext:lower()] then
                local full_path = (dir_path == ".") and fname or (dir_path .. "/" .. fname)
                local size = 0
                local mtime = 0
                if ffi.C.stat(full_path, st) == 0 then
                    -- Check if it is a regular file (S_ISREG)
                    local mode = tonumber(st.st_mode)
                    local is_reg = (bit.band(mode, 0xF000) == 0x8000)
                    if is_reg then
                        size = tonumber(st.st_size)
                        mtime = tonumber(st.st_mtime)
                        table.insert(images, {
                            filename = fname,
                            filepath = full_path,
                            extension = ext:upper(),
                            size = size,
                            size_str = format_file_size(size),
                            mtime = mtime,
                        })
                    end
                end
            end
        end
    end
    ffi.C.closedir(d)

    -- Sort alphabetically by filename
    table.sort(images, function(a, b)
        return a.filename:lower() < b.filename:lower()
    end)

    return images
end

-- =========================================================================
-- 4. Netpbm PPM & Streaming Image Decoder
-- =========================================================================
local function parse_ppm_stream(f)
    local function next_token()
        while true do
            local ch = f:read(1)
            if not ch then return nil end
            if ch == '#' then
                f:read("*l")
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
        return nil, "Unsupported PPM magic header: " .. tostring(magic)
    end

    local width = tonumber(next_token())
    local height = tonumber(next_token())
    local max_val = tonumber(next_token())

    if not width or not height or not max_val or width <= 0 or height <= 0 then
        return nil, "Corrupted PPM header"
    end

    local pixels = ffi.new("PixelRGB[?]", width * height)

    if magic == "P6" then
        local total_bytes = width * height * 3
        local raw_bytes = f:read(total_bytes)
        if not raw_bytes or #raw_bytes < total_bytes then
            return nil, "Incomplete binary PPM pixel stream"
        end
        ffi.copy(pixels, raw_bytes, total_bytes)
    else
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

local function load_image(filepath)
    local test_f = io.open(filepath, "rb")
    if not test_f then
        return nil, "Cannot open file: " .. filepath
    end
    local header = test_f:read(2)
    test_f:close()

    if header == "P6" or header == "P3" then
        local f = io.open(filepath, "rb")
        local img, err = parse_ppm_stream(f)
        f:close()
        return img, err
    end

    -- ImageMagick conversion pipeline
    local cmd = string.format("magick %q ppm:- 2>/dev/null || convert %q ppm:- 2>/dev/null", filepath, filepath)
    local pipe = io.popen(cmd, "r")
    if pipe then
        local img = parse_ppm_stream(pipe)
        pipe:close()
        if img then return img end
    end

    -- ffmpeg conversion fallback
    local ffmpeg_cmd = string.format("ffmpeg -v error -i %q -f image2pipe -vcodec ppm - 2>/dev/null", filepath)
    local ffmpeg_pipe = io.popen(ffmpeg_cmd, "r")
    if ffmpeg_pipe then
        local img = parse_ppm_stream(ffmpeg_pipe)
        ffmpeg_pipe:close()
        if img then return img end
    end

    return nil, "Failed to decode image. Ensure ImageMagick ('magick'/'convert') or 'ffmpeg' is installed."
end

-- =========================================================================
-- 5. Terminal Truecolor Image Display
-- =========================================================================
local function render_image_screen(img_entry, current_idx, total_count)
    local term_w, term_h = get_terminal_size()
    local img, err = load_image(img_entry.filepath)
    if not img then
        return false, err
    end

    local out = {}
    table.insert(out, "\27[H\27[2J") -- Clear screen & home cursor

    -- Top header bar
    local bar_len = math.min(term_w - 2, 80)
    table.insert(out, "\27[1;36m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mIMAGE VIEWER [%d/%d]: \27[1;93m%s\27[0m\n",
        current_idx, total_count, img_entry.filename))
    table.insert(out, string.format("  \27[90mSize: %s | Original: %dx%d pixels | Path: %s\27[0m\n",
        img_entry.size_str, img.width, img.height, img_entry.filepath))
    table.insert(out, string.format("  \27[93m[←/P]\27[0m Prev   \27[93m[→/N]\27[0m Next   \27[1;92m[Enter/B]\27[0m Back to File List   \27[91m[Q]\27[0m Quit\n"))
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n\n")

    -- Calculate render scale to fit remaining terminal height
    local reserved_header_rows = 7
    local max_char_h = math.max(6, term_h - reserved_header_rows)
    local target_w = math.max(10, term_w - 4)
    local target_h = max_char_h * 2 -- Each character row holds 2 vertical pixels

    local scale_x = target_w / img.width
    local scale_y = target_h / img.height
    local scale = math.min(scale_x, scale_y)

    local out_w = math.max(1, math.floor(img.width * scale))
    local out_h = math.max(1, math.floor(img.height * scale))
    if out_h % 2 ~= 0 then out_h = out_h + 1 end

    local margin_left = math.max(0, math.floor((term_w - out_w) / 2))
    local pad = string.rep(" ", margin_left)

    local px = img.pixels
    local iw = img.width

    for y = 0, out_h - 1, 2 do
        local line = { pad }
        for x = 0, out_w - 1 do
            local src_x = math.min(img.width - 1, math.floor(x * (img.width / out_w)))
            local src_y_top = math.min(img.height - 1, math.floor(y * (img.height / out_h)))
            local src_y_bot = math.min(img.height - 1, math.floor((y + 1) * (img.height / out_h)))

            local top = px[src_y_top * iw + src_x]
            local bot = px[src_y_bot * iw + src_x]

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
    return true
end

-- =========================================================================
-- 6. File List Selector Screen
-- =========================================================================
local function render_file_list(dir_path, images, selected_idx, page_offset, msg)
    local term_w, term_h = get_terminal_size()
    local out = {}
    table.insert(out, "\27[H\27[2J") -- Clear screen & home

    local bar_len = math.min(term_w - 2, 80)
    table.insert(out, "\27[1;34m" .. string.rep("═", bar_len) .. "\27[0m\n")
    table.insert(out, string.format("  \27[1;37mTERMINAL DIRECTORY IMAGE VIEWER\27[0m \27[90m(LuaJIT FFI Truecolor)\27[0m\n"))
    table.insert(out, string.format("  \27[90mDirectory:\27[0m \27[1;33m%s\27[0m \27[90m(Found %d image files, Level 1)\27[0m\n", dir_path, #images))
    table.insert(out, string.format("  \27[93m[↑/↓/K/J]\27[0m Move Selection   \27[1;92m[Enter/Space]\27[0m View Image   \27[93m[1-9]\27[0m Direct Pick   \27[91m[Q]\27[0m Quit\n"))
    table.insert(out, "\27[90m" .. string.rep("─", bar_len) .. "\27[0m\n")

    if msg and #msg > 0 then
        table.insert(out, string.format("  \27[1;93mℹ %s\27[0m\n\n", msg))
    else
        table.insert(out, "\n")
    end

    if #images == 0 then
        table.insert(out, string.format("  \27[1;31mNo supported image files found in %s\27[0m\n", dir_path))
        table.insert(out, "  Supported formats: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP\n\n")
        io.write(table.concat(out))
        io.flush()
        return
    end

    -- Pagination
    local header_rows = 8
    local max_items_per_page = math.max(4, term_h - header_rows - 3)
    local page_start = page_offset or 1
    local page_end = math.min(#images, page_start + max_items_per_page - 1)

    -- Table Header
    local col1_w = 6  -- Index
    local col2_w = math.max(20, math.min(36, term_w - 38)) -- Filename
    local col3_w = 8  -- Format
    local col4_w = 12 -- Size

    table.insert(out, string.format("  \27[1;37m%-6s %-" .. col2_w .. "s %-8s %-12s\27[0m\n", "INDEX", "FILENAME", "FORMAT", "SIZE"))
    table.insert(out, "  \27[90m" .. string.rep("─", 6 + col2_w + 8 + 12 + 3) .. "\27[0m\n")

    for i = page_start, page_end do
        local img = images[i]
        local is_sel = (i == selected_idx)
        local fn = img.filename
        if #fn > col2_w then
            fn = fn:sub(1, col2_w - 3) .. "..."
        end

        local line_str = string.format("%-6s %-" .. col2_w .. "s %-8s %-12s",
            string.format("[%d]", i),
            fn,
            img.extension,
            img.size_str
        )

        if is_sel then
            table.insert(out, string.format(" \27[1;93m▶ \27[1;97;44m %s \27[0m\n", line_str))
        else
            table.insert(out, string.format("   \27[37m%s\27[0m\n", line_str))
        end
    end

    table.insert(out, "\n")
    if #images > max_items_per_page then
        table.insert(out, string.format("  \27[90mShowing %d-%d of %d images. Use ↑ / ↓ to scroll.\27[0m\n",
            page_start, page_end, #images))
    end

    io.write(table.concat(out))
    io.flush()
end

-- =========================================================================
-- 7. Main Interactive Loop & CLI Controller
-- =========================================================================
local function main()
    local args = {}
    local positional = {}
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--select" or a == "-s" then
            i = i + 1
            args["--select"] = arg[i]
        elseif a:sub(1, 2) == "--" or a:sub(1, 1) == "-" then
            args[a] = true
        else
            table.insert(positional, a)
        end
        i = i + 1
    end

    if args["-h"] or args["--help"] then
        print("\27[1;36mTerminal Directory Image Viewer (LuaJIT FFI Truecolor)\27[0m")
        print("Usage:")
        print("  ./LuaJIT/src/luajit image_gallery_viewer.lua [directory] [options]")
        print("\nOptions:")
        print("  [directory]           Directory to scan (default: current directory '.')")
        print("  --select, -s <id>     Directly select and display image #id")
        print("  --no-interactive      Non-interactive script/batch mode")
        print("  -h, --help            Show this help information")
        print("\nSupported formats:")
        print("  - PNG, JPG/JPEG, PPM, WEBP, GIF, BMP")
        os.exit(0)
    end

    -- 1. Determine target directory: positional arg or default '.'
    local target_dir = positional[1] or "."
    local cli_select = tonumber(args["--select"])
    local non_interactive = args["--no-interactive"] or (ffi.C.isatty(STDIN_FILENO) ~= 1)

    -- 2. Scan Directory for Images
    local images, err = scan_directory_images(target_dir)
    if not images then
        io.stderr:write(string.format("\27[1;31mError: %s\27[0m\n", tostring(err)))
        os.exit(1)
    end

    if #images == 0 then
        print(string.format("\27[1;33m[!] No supported images found in '%s' (Level 1 scan).\27[0m", target_dir))
        print("Supported formats: PNG, JPG/JPEG, PPM, WEBP, GIF, BMP")
        os.exit(0)
    end

    -- 3. If direct CLI selection is specified
    if cli_select and cli_select >= 1 and cli_select <= #images then
        render_image_screen(images[cli_select], cli_select, #images)
        return
    end

    -- 4. Non-interactive fallback (e.g., pipes or redirect)
    if non_interactive then
        render_file_list(target_dir, images, 1, 1)
        io.write(string.format("\n\27[1;32mEnter image number [1-%d] to view, or 'q' to quit: \27[0m", #images))
        io.flush()
        local line = io.read("*l")
        if line and line ~= "q" and line ~= "Q" then
            local sel = tonumber(line:match("%d+"))
            if sel and sel >= 1 and sel <= #images then
                render_image_screen(images[sel], sel, #images)
            end
        end
        return
    end

    -- 5. Interactive Mode (POSIX raw mode with arrow keys)
    enable_raw_mode()

    local selected_idx = 1
    local page_offset = 1
    local in_viewer = false
    local current_msg = nil

    local function update_page_window()
        local _, term_h = get_terminal_size()
        local max_items = math.max(4, term_h - 11)
        if selected_idx < page_offset then
            page_offset = selected_idx
        elseif selected_idx > page_offset + max_items - 1 then
            page_offset = selected_idx - max_items + 1
        end
    end

    while true do
        if in_viewer then
            local ok, view_err = render_image_screen(images[selected_idx], selected_idx, #images)
            if not ok then
                in_viewer = false
                current_msg = "Failed to load image: " .. tostring(view_err)
            else
                local k = read_key()
                if k == "q" or k == "ESC" then
                    break
                elseif k == "ENTER" or k == "b" or k == "BACKSPACE" then
                    in_viewer = false
                elseif k == "RIGHT" or k == "n" or k == "SPACE" then
                    selected_idx = (selected_idx % #images) + 1
                    update_page_window()
                elseif k == "LEFT" or k == "p" then
                    selected_idx = (selected_idx - 2 + #images) % #images + 1
                    update_page_window()
                end
            end
        else
            update_page_window()
            render_file_list(target_dir, images, selected_idx, page_offset, current_msg)
            current_msg = nil

            local k = read_key()
            if not k or k == "q" or k == "ESC" then
                break
            elseif k == "UP" or k == "k" then
                if selected_idx > 1 then selected_idx = selected_idx - 1 end
            elseif k == "DOWN" or k == "j" then
                if selected_idx < #images then selected_idx = selected_idx + 1 end
            elseif k == "ENTER" or k == "SPACE" then
                in_viewer = true
            elseif tonumber(k) and tonumber(k) >= 1 and tonumber(k) <= math.min(9, #images) then
                selected_idx = tonumber(k)
                in_viewer = true
            end
        end
    end

    disable_raw_mode()
    print("\n\27[1;36mExited Terminal Image Viewer. Goodbye!\27[0m")
end

main()
