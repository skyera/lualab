--[[
    lumina.lua
    A fast, modern, Miller-columns terminal file manager written in pure LuaJIT with FFI.
    Inspired by ranger & yazi.

    Architecture & Features:
    - POSIX FFI Native APIs:
      * ioctl(TIOCGWINSZ) for real-time terminal dimensions.
      * termios raw mode + poll() for non-blocking sub-millisecond keyboard input.
      * opendir / readdir / closedir / stat for zero-fork native directory reading.
    - 3-Column Miller Columns Layout:
      * Column 1 (Left, 20% width) : Parent directory list.
      * Column 2 (Middle, 30% width): Current directory list (active cursor).
      * Column 3 (Right, 50% width) : Instant live preview pane:
        - Image files (.png, .jpg, .ppm, etc.): Truecolor half-block graphics preview.
        - Text & source files (.lua, .c, .h, .py, .md, .txt, .json): Syntax-highlighted text preview.
        - Subdirectories: Contents peek with file count and sizes.
        - Binary files: Hex dump preview.
    - Keybindings:
      * h / ← / Backspace: Go to parent directory
      * l / → / Enter    : Open directory / view file
      * j / ↓            : Move cursor down
      * k / ↑            : Move cursor up
      * g / G            : Jump to top / bottom
      * /                : Instant filter / search
      * .                : Toggle hidden files (dotfiles)
      * r                : Refresh current directory
      * q / ESC          : Quit
]]

local ffi = require("ffi")

-- =========================================================================
-- =========================================================================
-- 1. FFI Definitions: Terminal, Polling, Dirent, and Stat
-- =========================================================================
local is_windows = (ffi.os == "Windows")
local posix_stat
local devnull = is_windows and "nul" or "/dev/null"
local popen_rb = is_windows and "rb" or "r"

local enable_raw_mode, disable_raw_mode, get_terminal_size, read_key
local read_dir_entries, resolve_canonical_path, get_parent_dir
local in_raw_mode = false
local kernel32

if is_windows then
    kernel32 = ffi.load("kernel32")
    local msvcrt = ffi.load("msvcrt")
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
        int GetConsoleMode(HANDLE hConsoleHandle, uint32_t *lpMode);
        int SetConsoleMode(HANDLE hConsoleHandle, uint32_t dwMode);
        int SetConsoleOutputCP(uint32_t wCodePageID);
        void Sleep(uint32_t dwMilliseconds);
        int _kbhit(void);
        int _getch(void);

        typedef struct _FILETIME { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } FILETIME;
        typedef struct _WIN32_FIND_DATAA {
            uint32_t dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            uint32_t nFileSizeHigh;
            uint32_t nFileSizeLow;
            uint32_t dwReserved0;
            uint32_t dwReserved1;
            char     cFileName[260];
            char     cAlternateFileName[14];
        } WIN32_FIND_DATAA;
        void* FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA* lpFindFileData);
        int   FindNextFileA(void* hFindFile, WIN32_FIND_DATAA* lpFindFileData);
        int   FindClose(void* hFindFile);
        char* _fullpath(char *absPath, const char *relPath, size_t maxLength);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5
    local orig_in_mode = ffi.new("uint32_t[1]")
    local orig_out_mode = ffi.new("uint32_t[1]")

    enable_raw_mode = function()
        local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        if kernel32.GetConsoleMode(hIn, orig_in_mode) == 0 then return false end
        kernel32.GetConsoleMode(hOut, orig_out_mode)

        kernel32.SetConsoleOutputCP(65001)
        local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        kernel32.SetConsoleMode(hOut, bit.bor(orig_out_mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING))

        local raw_mode = bit.band(orig_in_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
        kernel32.SetConsoleMode(hIn, raw_mode)

        in_raw_mode = true
        io.write("\27[?1049h\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
            local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
            kernel32.SetConsoleMode(hIn, orig_in_mode[0])
            kernel32.SetConsoleMode(hOut, orig_out_mode[0])
            in_raw_mode = false
        end
    end

    get_terminal_size = function()
        local hOut = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if kernel32.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if w > 0 and h > 0 then return tonumber(w), tonumber(h) end
        end
        return 100, 30
    end

    read_key = function(timeout_ms)
        local hIn = kernel32.GetStdHandle(STD_INPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        if kernel32.GetConsoleMode(hIn, mode) == 0 then
            local ch = io.read(1)
            if not ch then return "q" end
            if ch == "\n" or ch == "\r" then return "ENTER" end
            return ch
        end

        timeout_ms = timeout_ms or 50
        local elapsed = 0
        while elapsed < timeout_ms do
            if msvcrt._kbhit() ~= 0 then
                local c0 = msvcrt._getch()
                if c0 == 0 or c0 == 224 then
                    local c1 = msvcrt._getch()
                    if c1 == 72 then return "UP"
                    elseif c1 == 80 then return "DOWN"
                    elseif c1 == 75 then return "LEFT"
                    elseif c1 == 77 then return "RIGHT"
                    elseif c1 == 73 then return "PAGE_UP"
                    elseif c1 == 81 then return "PAGE_DOWN"
                    elseif c1 == 71 then return "HOME"
                    elseif c1 == 79 then return "END"
                    end
                elseif c0 == 27 then
                    return "ESC"
                elseif c0 == 9 then
                    return "TAB"
                elseif c0 == 13 or c0 == 10 then
                    return "ENTER"
                elseif c0 == 32 then
                    return "SPACE"
                elseif c0 == 8 or c0 == 127 then
                    return "BACKSPACE"
                else
                    return string.char(c0)
                end
            end
            kernel32.Sleep(10)
            elapsed = elapsed + 10
        end
        return nil
    end
else
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
            unsigned long  __pad1;
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
        int __xstat(int ver, const char *pathname, struct stat *statbuf);

        char *realpath(const char *path, char *resolved_path);
    ]]

    if pcall(function() return ffi.C.stat end) then
        posix_stat = function(path, st) return ffi.C.stat(path, st) end
    elseif pcall(function() return ffi.C.__xstat end) then
        posix_stat = function(path, st)
            local res = ffi.C.__xstat(3, path, st)
            if res ~= 0 then res = ffi.C.__xstat(1, path, st) end
            return res
        end
    else
        posix_stat = function(path, st) return -1 end
    end

    local TIOCGWINSZ   = 0x5413
    local STDIN_FILENO = 0
    local TCSANOW      = 0
    local ICANON       = 2
    local ECHO         = 8
    local POLLIN       = 1

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")

    enable_raw_mode = function()
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
        ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        in_raw_mode = true

        -- Switch to alternate screen buffer, hide cursor
        io.write("\27[?1049h\27[?25l")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            in_raw_mode = false
        end
    end

    get_terminal_size = function()
        local ws = ffi.new("struct winsize")
        if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
            return tonumber(ws.ws_col), tonumber(ws.ws_row)
        end
        return 100, 30
    end

    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local key_buf = ffi.new("char[32]")

    read_key = function(timeout_ms)
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then
            local ch = io.read(1)
            if not ch then return "q" end
            if ch == "\n" or ch == "\r" then return "ENTER" end
            return ch
        end

        timeout_ms = timeout_ms or 50
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 32)
            if n > 0 then
                local c0 = key_buf[0]
                if c0 == 27 then
                    if n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 65 then return "UP" end
                        if c2 == 66 then return "DOWN" end
                        if c2 == 67 then return "RIGHT" end
                        if c2 == 68 then return "LEFT" end
                        if c2 == 53 and n >= 4 and key_buf[3] == 126 then return "PAGE_UP" end
                        if c2 == 54 and n >= 4 and key_buf[3] == 126 then return "PAGE_DOWN" end
                        if c2 == 72 then return "HOME" end
                        if c2 == 70 then return "END" end
                    end
                    return "ESC"
                elseif c0 == 10 or c0 == 13 then
                    return "ENTER"
                elseif c0 == 127 or c0 == 8 then
                    return "BACKSPACE"
                elseif c0 == 32 then
                    return "SPACE"
                else
                    return string.char(c0)
                end
            end
        end
        return nil
    end
end

-- =========================================================================
-- 2. Styling Palette & String Measurement
-- =========================================================================
local C = {
    reset        = "\27[0m",
    bold         = "\27[1m",
    dim          = "\27[2m",
    italic       = "\27[3m",

    -- Borders
    border_col   = "\27[38;2;71;85;105m",      -- Slate grey
    border_focus = "\27[1;38;2;56;189;248m",   -- Cyan

    -- Miller Column Item Colors
    dir_col      = "\27[1;38;2;96;165;250m",   -- Light Blue bold
    exec_col     = "\27[1;38;2;52;211;153m",   -- Emerald Green
    image_col    = "\27[1;38;2;244;114;182m",  -- Pink / Magenta
    archive_col  = "\27[1;38;2;251;191;36m",   -- Amber
    code_col     = "\27[38;2;56;189;248m",     -- Sky blue
    file_col     = "\27[38;2;226;232;240m",    -- Neutral soft white
    symlink_col  = "\27[38;2;45;212;191m",     -- Teal

    -- Highlights & Cursors
    cursor_bg    = "\27[48;2;30;58;138m\27[1;38;2;255;255;255m", -- Royal blue highlight
    parent_bg    = "\27[48;2;30;41;59m\27[38;2;203;213;225m",    -- Muted grey-blue highlight

    -- Syntax Colors for Previews
    syn_keyword  = "\27[1;38;2;192;132;252m",  -- Lavender
    syn_string   = "\27[38;2;134;239;172m",    -- Pale green
    syn_comment  = "\27[38;2;100;116;139m\27[3m", -- Dim italic grey
    syn_number   = "\27[38;2;251;191;36m",     -- Amber
    syn_header   = "\27[1;38;2;56;189;248m",   -- Cyan
}

local function visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function truncate(str, max_w)
    local len = visual_len(str)
    if len <= max_w then return str end
    if max_w <= 3 then return string.rep(".", max_w) end

    local out = {}
    local curr = 0
    for c in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if curr + 1 > max_w - 3 then break end
        table.insert(out, c)
        curr = curr + 1
    end
    return table.concat(out) .. "..."
end

local function format_bytes(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f K", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f M", bytes / (1024 * 1024))
    else
        return string.format("%.1f G", bytes / (1024 * 1024 * 1024))
    end
end

-- =========================================================================
-- 3. File System & Directory Inspection via FFI
-- =========================================================================
local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, ppm = true }
local ARCHIVE_EXTS = { zip = true, tar = true, gz = true, bz2 = true, xz = true, ["7z"] = true, rar = true }
local CODE_EXTS = {
    lua = true, c = true, h = true, cpp = true, py = true, js = true, ts = true,
    rs = true, go = true, sh = true, json = true, yaml = true, yml = true, toml = true,
    md = true, html = true, css = true, sql = true
}

local function get_file_type_info(entry)
    if entry.is_dir then
        return "📁", C.dir_col
    elseif entry.is_symlink then
        return "🔗", C.symlink_col
    elseif IMAGE_EXTS[entry.ext] then
        return "🖼 ", C.image_col
    elseif ARCHIVE_EXTS[entry.ext] then
        return "📦", C.archive_col
    elseif CODE_EXTS[entry.ext] then
        return "📜", C.code_col
    elseif entry.is_exec then
        return "⚡", C.exec_col
    else
        return "📄", C.file_col
    end
end

if is_windows then
    read_dir_entries = function(dir_path, show_hidden)
        dir_path = dir_path or "."
        local pattern = dir_path
        if not pattern:match("[/\\]$") then
            pattern = pattern .. "\\*"
        else
            pattern = pattern .. "*"
        end

        local fd = ffi.new("WIN32_FIND_DATAA")
        local hFind = kernel32.FindFirstFileA(pattern, fd)
        if hFind == ffi.cast("void*", -1) or hFind == nil then return {} end

        local entries = {}
        repeat
            local name = ffi.string(fd.cFileName)
            if name ~= "." and name ~= ".." and (show_hidden or name:sub(1, 1) ~= ".") then
                local full_path
                if dir_path:match("[/\\]$") then
                    full_path = dir_path .. name
                else
                    full_path = dir_path .. "\\" .. name
                end

                local is_dir = (bit.band(fd.dwFileAttributes, 0x10) ~= 0)
                local is_symlink = (bit.band(fd.dwFileAttributes, 0x400) ~= 0)
                local size = tonumber(fd.nFileSizeHigh) * 4294967296 + tonumber(fd.nFileSizeLow)

                local ext = name:match("%.([^.]+)$")
                ext = ext and ext:lower() or ""
                local is_exec = (ext == "exe" or ext == "bat" or ext == "cmd" or ext == "ps1")

                table.insert(entries, {
                    name = name,
                    path = full_path,
                    ext = ext,
                    size = size,
                    size_str = format_bytes(size),
                    is_dir = is_dir,
                    is_exec = is_exec,
                    is_symlink = is_symlink,
                })
            end
        until kernel32.FindNextFileA(hFind, fd) == 0
        kernel32.FindClose(hFind)

        table.sort(entries, function(a, b)
            if a.is_dir ~= b.is_dir then
                return a.is_dir
            end
            return a.name:lower() < b.name:lower()
        end)

        return entries
    end

    resolve_canonical_path = function(path)
        local buf = ffi.new("char[4096]")
        if ffi.C._fullpath(buf, path, 4096) ~= nil then
            return ffi.string(buf)
        end
        return path
    end

    get_parent_dir = function(path)
        path = resolve_canonical_path(path)
        if path:match("^[a-zA-Z]:[/\\]?$") or path == "/" or path == "\\" then
            return path
        end
        local parent = path:match("^(.*)[/\\][^/\\]+$")
        if not parent or parent == "" then
            if path:match("^[a-zA-Z]:") then
                return path:sub(1, 2) .. "\\"
            end
            return "\\"
        end
        if parent:match("^[a-zA-Z]:$") then
            return parent .. "\\"
        end
        return parent
    end
else
    read_dir_entries = function(dir_path, show_hidden)
        dir_path = dir_path or "."
        local d = ffi.C.opendir(dir_path)
        if d == nil then return {} end

        local entries = {}
        local st = ffi.new("struct stat")

        while true do
            local ent = ffi.C.readdir(d)
            if ent == nil then break end
            local name = ffi.string(ent.d_name)

            if name ~= "." and name ~= ".." and (show_hidden or name:sub(1, 1) ~= ".") then
                local full_path = (dir_path == "/" and ("/" .. name) or (dir_path .. "/" .. name))
                local size = 0
                local is_dir = (ent.d_type == 4) -- DT_DIR
                local is_exec = false
                local is_symlink = (ent.d_type == 10) -- DT_LNK

                if posix_stat(full_path, st) == 0 then
                    local mode = tonumber(st.st_mode)
                    is_dir = (bit.band(mode, 0xF000) == 0x4000) -- S_ISDIR
                    is_exec = (bit.band(mode, 0x49) ~= 0)        -- S_IXUSR / S_IXGRP / S_IXOTH
                    size = tonumber(st.st_size)
                end

                local ext = name:match("%.([^.]+)$")
                ext = ext and ext:lower() or ""

                table.insert(entries, {
                    name = name,
                    path = full_path,
                    ext = ext,
                    size = size,
                    size_str = format_bytes(size),
                    is_dir = is_dir,
                    is_exec = is_exec,
                    is_symlink = is_symlink,
                })
            end
        end
        ffi.C.closedir(d)

        table.sort(entries, function(a, b)
            if a.is_dir ~= b.is_dir then
                return a.is_dir
            end
            return a.name:lower() < b.name:lower()
        end)

        return entries
    end

    resolve_canonical_path = function(path)
        local buf = ffi.new("char[4096]")
        if ffi.C.realpath(path, buf) ~= nil then
            return ffi.string(buf)
        end
        return path
    end

    get_parent_dir = function(path)
        path = resolve_canonical_path(path)
        if path == "/" then return "/" end
        local parent = path:match("^(.*)/[^/]+$")
        if not parent or parent == "" then return "/" end
        return parent
    end
end

local function is_root_dir(p)
    if not p then return true end
    if p == "/" or p == "\\" then return true end
    if is_windows and p:match("^[a-zA-Z]:[/\\]?$") then return true end
    return false
end

local function get_dir_display_name(p)
    if not p or is_root_dir(p) then return p or "/" end
    local name = p:match("([^/\\]+)[/\\]?$")
    return (name and #name > 0) and name or p
end

-- =========================================================================
-- 4. Content Preview Generators (Text, Code, Hex, and Image)
-- =========================================================================
local function highlight_code_line(line, ext)
    if ext == "lua" or ext == "py" or ext == "sh" then
        if line:find("^%s*%-%-") or line:find("^%s*#") then
            return C.syn_comment .. line .. C.reset
        end
    elseif ext == "c" or ext == "h" or ext == "cpp" or ext == "js" or ext == "rs" or ext == "go" then
        if line:find("^%s*//") or line:find("^%s*/%*") then
            return C.syn_comment .. line .. C.reset
        end
    end

    -- Highlight strings
    local hl = line:gsub("(\"[^\"]*\")", C.syn_string .. "%1" .. C.reset)
    hl = hl:gsub("('[^']*')", C.syn_string .. "%1" .. C.reset)

    -- Highlight common keywords
    local keywords = { "local", "function", "return", "if", "then", "else", "elseif", "end",
                       "for", "while", "do", "break", "import", "def", "class", "struct" }
    for _, kw in ipairs(keywords) do
        hl = hl:gsub("%f[%a]" .. kw .. "%f[%A]", C.syn_keyword .. kw .. C.reset)
    end

    return hl
end

local function generate_text_preview(filepath, ext, max_lines, max_cols)
    local f = io.open(filepath, "r")
    if not f then return { C.dim .. "(Cannot read file)" .. C.reset } end

    local lines = {}
    local count = 0
    while count < max_lines do
        local line = f:read("*l")
        if not line then break end
        count = count + 1
        -- Replace tabs with 4 spaces
        line = line:gsub("\t", "    ")
        local num_str = string.format("%s%3d%s │ ", C.dim, count, C.reset)
        local code_str = highlight_code_line(line, ext)
        table.insert(lines, num_str .. code_str)
    end
    f:close()

    if #lines == 0 then
        return { C.dim .. "(Empty file)" .. C.reset }
    end
    return lines
end

local function generate_dir_preview(dirpath, max_lines, show_hidden)
    local entries = read_dir_entries(dirpath, show_hidden)
    local lines = {}

    table.insert(lines, string.format("%s📂 Directory: %s (%d items)%s", C.syn_header, get_dir_display_name(dirpath), #entries, C.reset))
    table.insert(lines, C.dim .. string.rep("─", 36) .. C.reset)

    for i = 1, math.min(#entries, max_lines - 2) do
        local e = entries[i]
        local icon, col = get_file_type_info(e)
        table.insert(lines, string.format(" %s %s%-24s%s %s%6s%s",
            icon, col, truncate(e.name, 24), C.reset, C.dim, e.size_str, C.reset))
    end

    if #entries > max_lines - 2 then
        table.insert(lines, string.format(" %s... and %d more items%s", C.dim, #entries - (max_lines - 2), C.reset))
    end
    return lines
end

local function generate_hex_preview(filepath, max_lines)
    local f = io.open(filepath, "rb")
    if not f then return { C.dim .. "(Cannot read binary file)" .. C.reset } end

    local lines = {}
    table.insert(lines, C.syn_header .. "BINARY HEX DUMP" .. C.reset)
    local offset = 0

    while #lines < max_lines do
        local chunk = f:read(16)
        if not chunk or #chunk == 0 then break end

        local hex = {}
        local ascii = {}
        for i = 1, #chunk do
            local b = chunk:byte(i)
            table.insert(hex, string.format("%02X", b))
            if b >= 32 and b <= 126 then
                table.insert(ascii, string.char(b))
            else
                table.insert(ascii, ".")
            end
        end

        local hex_str = table.concat(hex, " ")
        local pad = string.rep("   ", 16 - #chunk)
        table.insert(lines, string.format("%s%06X%s │ %s%s │ %s%s%s",
            C.dim, offset, C.reset, hex_str, pad, C.syn_string, table.concat(ascii), C.reset))
        offset = offset + #chunk
    end
    f:close()
    return lines
end

local function generate_image_preview(filepath, max_w, max_h)
    local cmd
    if is_windows then
        cmd = string.format('magick %q -resize %dx%d! ppm:- 2>%s', filepath, max_w, max_h * 2, devnull)
    else
        cmd = string.format('magick %q -resize %dx%d! ppm:- 2>%s || convert %q -resize %dx%d! ppm:- 2>%s',
            filepath, max_w, max_h * 2, devnull, filepath, max_w, max_h * 2, devnull)
    end
    local pipe = io.popen(cmd, popen_rb)
    local img_data = nil
    if pipe then
        img_data = pipe:read("*a")
        pipe:close()
    end

    if not img_data or #img_data == 0 then
        local ffmpeg_cmd = string.format('ffmpeg -v error -i %q -vf scale=%d:%d -f image2pipe -vcodec ppm - 2>%s',
            filepath, max_w, max_h * 2, devnull)
        local fpipe = io.popen(ffmpeg_cmd, popen_rb)
        if fpipe then
            img_data = fpipe:read("*a")
            fpipe:close()
        end
    end

    if not img_data or #img_data == 0 then
        return { C.dim .. "Image file: " .. (filepath:match("([^/\\]+)$") or filepath) .. C.reset, C.dim .. "(Install ffmpeg or ImageMagick for graphics preview)" .. C.reset }
    end

    local pos = 1
    local function next_token()
        while pos <= #img_data do
            local ch = img_data:sub(pos, pos)
            pos = pos + 1
            if ch == '#' then
                while pos <= #img_data and img_data:sub(pos, pos) ~= '\n' do pos = pos + 1 end
                pos = pos + 1
            elseif not ch:match("%s") then
                local s = pos - 1
                while pos <= #img_data and not img_data:sub(pos, pos):match("%s") do
                    pos = pos + 1
                end
                local tok = img_data:sub(s, pos - 1)
                if pos <= #img_data and img_data:sub(pos, pos):match("%s") then
                    pos = pos + 1
                end
                return tok
            end
        end
        return nil
    end

    local magic = next_token()
    if magic ~= "P6" then
        return { C.dim .. "Image file: " .. (filepath:match("([^/\\]+)$") or filepath) .. C.reset }
    end
    local w = tonumber(next_token())
    local h = tonumber(next_token())
    local maxval = tonumber(next_token())
    if not w or not h or w <= 0 or h <= 0 then return {} end

    local raw = img_data:sub(pos, pos + w * h * 3 - 1)
    if #raw < w * h * 3 then return {} end

    local lines = {}
    for y = 0, h - 2, 2 do
        local line = {}
        for x = 0, w - 1 do
            local top_idx = (y * w + x) * 3 + 1
            local bot_idx = ((y + 1) * w + x) * 3 + 1
            local tr, tg, tb = raw:byte(top_idx, top_idx + 2)
            local br, bg, bb = raw:byte(bot_idx, bot_idx + 2)
            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                tr or 0, tg or 0, tb or 0, br or 0, bg or 0, bb or 0))
        end
        table.insert(line, C.reset)
        table.insert(lines, table.concat(line))
    end
    return lines
end

local PREVIEW_CACHE_LIMIT = 64
local preview_cache = {}
local preview_cache_order = {}

local function clear_preview_cache()
    preview_cache = {}
    preview_cache_order = {}
end

local function preview_cache_get(key)
    return preview_cache[key]
end

local function preview_cache_put(key, lines)
    if preview_cache[key] then return end
    preview_cache[key] = lines
    table.insert(preview_cache_order, key)
    if #preview_cache_order > PREVIEW_CACHE_LIMIT then
        local evicted = table.remove(preview_cache_order, 1)
        preview_cache[evicted] = nil
    end
end

local function generate_preview(entry, max_lines, max_cols, show_hidden)
    local key = table.concat({
        entry.path,
        entry.ext,
        tostring(entry.size),
        tostring(max_lines),
        tostring(max_cols),
        show_hidden and "hidden" or "visible",
    }, "\31")
    local cached = preview_cache_get(key)
    if cached then return cached end

    local lines
    if entry.is_dir then
        lines = generate_dir_preview(entry.path, max_lines, show_hidden)
    elseif IMAGE_EXTS[entry.ext] then
        lines = generate_image_preview(entry.path, max_cols, max_lines)
    elseif CODE_EXTS[entry.ext] or entry.ext == "txt" then
        lines = generate_text_preview(entry.path, entry.ext, max_lines, max_cols)
    elseif entry.size > 0 and entry.size < 1024 * 1024 * 5 then
        local test_f = io.open(entry.path, "rb")
        local first_bytes = test_f and test_f:read(512) or ""
        if test_f then test_f:close() end

        local is_binary = false
        for i = 1, #first_bytes do
            local byte_val = first_bytes:byte(i)
            if byte_val < 9 or (byte_val > 13 and byte_val < 32) then
                is_binary = true
                break
            end
        end
        if is_binary then
            lines = generate_hex_preview(entry.path, max_lines)
        else
            lines = generate_text_preview(entry.path, entry.ext, max_lines, max_cols)
        end
    else
        lines = { C.dim .. "Large / Binary File (" .. entry.size_str .. ")" .. C.reset }
    end

    preview_cache_put(key, lines)
    return lines
end

-- =========================================================================
-- 5. Screen Layout & Rendering Engine (Miller Columns)
-- =========================================================================
local function draw_pane(out, x, y, w, h, title, is_focused)
    local bcol = is_focused and C.border_focus or C.border_col
    local title_str = title and string.format(" %s%s%s ", C.bold .. "\27[38;2;241;245;249m", title, bcol) or ""
    local t_len = title and (visual_len(title) + 2) or 0
    local top_fill = string.rep("─", math.max(0, w - 2 - t_len))

    table.insert(out, string.format("\27[%d;%dH%s╭%s%s╮%s", y, x, bcol, title_str, top_fill, C.reset))
    for i = 1, h - 2 do
        table.insert(out, string.format("\27[%d;%dH%s│\27[%d;%dH│%s", y + i, x, bcol, y + i, x + w - 1, C.reset))
    end
    local bot_fill = string.rep("─", math.max(0, w - 2))
    table.insert(out, string.format("\27[%d;%dH%s╰%s╯%s", y + h - 1, x, bcol, bot_fill, C.reset))
end

local function draw_row(x, y, w, content)
    local clr = truncate(content, w - 2)
    local vlen = visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s", y, x + 1, clr, pad)
end

-- =========================================================================
-- 6. Main Interactive Application Loop
-- =========================================================================
local function main()
    local current_dir = resolve_canonical_path(arg[1] or ".")
    local show_hidden = false
    local filter_query = ""

    local sel_index = 1
    local current_entries = read_dir_entries(current_dir, show_hidden)
    local parent_dir = get_parent_dir(current_dir)
    local parent_entries = read_dir_entries(parent_dir, show_hidden)

    enable_raw_mode()

    local needs_redraw = true
    local preview_pending = true
    local last_w, last_h = get_terminal_size()

    -- Initial screen clear
    io.write("\27[H\27[2J")
    io.flush()

    local function reload_current()
        current_entries = read_dir_entries(current_dir, show_hidden)
        -- Filter if query exists
        if #filter_query > 0 then
            local filtered = {}
            for _, e in ipairs(current_entries) do
                if e.name:lower():find(filter_query:lower(), 1, true) then
                    table.insert(filtered, e)
                end
            end
            current_entries = filtered
        end
        parent_dir = get_parent_dir(current_dir)
        parent_entries = is_root_dir(current_dir) and {} or read_dir_entries(parent_dir, show_hidden)
        sel_index = math.max(1, math.min(sel_index, math.max(1, #current_entries)))
        needs_redraw = true
    end

    while true do
        local term_w, term_h = get_terminal_size()
        if term_w ~= last_w or term_h ~= last_h then
            last_w, last_h = term_w, term_h
            needs_redraw = true
            io.write("\27[H\27[2J")
        end

        if needs_redraw then
            local out = {}
            table.insert(out, "\27[H") -- Home cursor without flash

            -- 1. Top Header Bar
            local header_str = string.format("  %s⚡ LUMINA%s %s│%s %s%s%s %s(%d items)%s\27[K",
                C.bold .. "\27[38;2;56;189;248m", C.reset, C.dim, C.reset,
                C.bold .. "\27[38;2;241;245;249m", current_dir, C.reset,
                C.dim, #current_entries, C.reset)
            table.insert(out, header_str .. "\n")

            -- 2. Miller Columns Geometry
            local usable_h = math.max(10, term_h - 3)
            local col1_w = math.max(16, math.floor(term_w * 0.22))
            local col2_w = math.max(22, math.floor(term_w * 0.32))
            local col3_w = math.max(24, term_w - col1_w - col2_w)

            local col1_x = 1
            local col2_x = col1_x + col1_w
            local col3_x = col2_x + col2_w
            local start_y = 2

            -- Column 1: Parent Directory
            local parent_title = is_root_dir(current_dir) and "" or get_dir_display_name(parent_dir)
            draw_pane(out, col1_x, start_y, col1_w, usable_h, parent_title, false)
            local visible_rows = usable_h - 2
            for i = 1, visible_rows do
                local pe = parent_entries[i]
                if pe then
                    local is_cur_folder = (pe.path == current_dir)
                    local icon, col = get_file_type_info(pe)
                    local line_content = string.format(" %s %s", icon, pe.name)
                    if is_cur_folder then
                        table.insert(out, draw_row(col1_x, start_y + i, col1_w, C.parent_bg .. line_content .. C.reset))
                    else
                        table.insert(out, draw_row(col1_x, start_y + i, col1_w, col .. line_content .. C.reset))
                    end
                else
                    table.insert(out, draw_row(col1_x, start_y + i, col1_w, ""))
                end
            end

            -- Column 2: Current Directory (Active Cursor)
            local cur_title = get_dir_display_name(current_dir)
            draw_pane(out, col2_x, start_y, col2_w, usable_h, cur_title, true)

            -- Scroll offset for current directory
            local page_offset = 1
            if sel_index > visible_rows then
                page_offset = sel_index - visible_rows + 1
            end

            for i = 1, visible_rows do
                local idx = page_offset + i - 1
                local e = current_entries[idx]
                if e then
                    local is_sel = (idx == sel_index)
                    local icon, col = get_file_type_info(e)
                    local line_content = string.format(" %s %-20s %s", icon, e.name, e.size_str)
                    if is_sel then
                        table.insert(out, draw_row(col2_x, start_y + i, col2_w, C.cursor_bg .. "▶" .. line_content .. C.reset))
                    else
                        table.insert(out, draw_row(col2_x, start_y + i, col2_w, col .. " " .. line_content .. C.reset))
                    end
                else
                    table.insert(out, draw_row(col2_x, start_y + i, col2_w, ""))
                end
            end

            -- Column 3: Live Preview Pane
            local sel_entry = current_entries[sel_index]
            local preview_title = sel_entry and sel_entry.name or "Preview"
            draw_pane(out, col3_x, start_y, col3_w, usable_h, preview_title, false)

            local preview_lines
            if preview_pending then
                preview_lines = {
                    C.dim .. "Loading preview..." .. C.reset,
                    C.dim .. "Pause briefly to render the selected item." .. C.reset,
                }
            elseif sel_entry then
                preview_lines = generate_preview(sel_entry, visible_rows, col3_w - 4, show_hidden)
            else
                preview_lines = { C.dim .. "(Empty Directory)" .. C.reset }
            end

            for i = 1, visible_rows do
                local pline = preview_lines[i] or ""
                table.insert(out, draw_row(col3_x, start_y + i, col3_w, pline))
            end

            -- 3. Bottom Status & Keybinding Bar
            local footer_y = term_h - 1
            local status_text = ""
            if #filter_query > 0 then
                status_text = string.format("\27[1;38;2;251;191;36mFilter: /%s\27[0m", filter_query)
            else
                status_text = string.format("%s%s%s", C.dim, sel_entry and sel_entry.path or current_dir, C.reset)
            end

            local help_hint = "[h/l/←/→] Navigate  [j/k] Up/Down  [/] Filter  [.] Hidden  [q] Quit"
            local footer_line = string.format("\27[%d;1H\27[2K  %s \27[90m│\27[0m \27[90m%s\27[0m",
                footer_y, status_text, help_hint)
            table.insert(out, footer_line)

            io.write(table.concat(out))
            io.flush()
            needs_redraw = false
        end

        -- 4. Key Event Handling (Event-driven without busy spinning)
        local k = read_key(150)
        if k then
            local previous_dir = current_dir
            local previous_selection = sel_index
            needs_redraw = true
            if k == "q" or k == "ESC" then
                if #filter_query > 0 then
                    filter_query = ""
                    reload_current()
                else
                    break
                end
            elseif k == "DOWN" or k == "j" then
                if sel_index < #current_entries then
                    sel_index = sel_index + 1
                end
            elseif k == "UP" or k == "k" then
                if sel_index > 1 then
                    sel_index = sel_index - 1
                end
            elseif k == "PAGE_DOWN" then
                local _, term_h = get_terminal_size()
                sel_index = math.min(#current_entries, sel_index + math.max(4, term_h - 6))
            elseif k == "PAGE_UP" then
                local _, term_h = get_terminal_size()
                sel_index = math.max(1, sel_index - math.max(4, term_h - 6))
            elseif k == "HOME" or k == "g" then
                sel_index = 1
            elseif k == "END" or k == "G" then
                sel_index = math.max(1, #current_entries)
            elseif k == "LEFT" or k == "h" or k == "BACKSPACE" then
                -- Move to parent directory
                if not is_root_dir(current_dir) then
                    local prev_dir = current_dir
                    current_dir = get_parent_dir(current_dir)
                    filter_query = ""
                    clear_preview_cache()
                    preview_pending = true
                    current_entries = read_dir_entries(current_dir, show_hidden)
                    parent_dir = get_parent_dir(current_dir)
                    parent_entries = is_root_dir(current_dir) and {} or read_dir_entries(parent_dir, show_hidden)

                    -- Retain cursor on the directory we just left
                    sel_index = 1
                    for idx, e in ipairs(current_entries) do
                        if e.path == prev_dir then
                            sel_index = idx
                            break
                        end
                    end
                end
            elseif k == "RIGHT" or k == "l" or k == "ENTER" then
                -- Open selected directory
                local sel = current_entries[sel_index]
                if sel and sel.is_dir then
                    current_dir = sel.path
                    filter_query = ""
                    sel_index = 1
                    reload_current()
                end
            elseif k == "." then
                -- Toggle hidden files
                show_hidden = not show_hidden
                reload_current()
            elseif k == "r" then
                -- Refresh
                reload_current()
            elseif k == "/" then
                -- Filter prompt
                disable_raw_mode()
                io.write("\n\27[1;38;2;56;189;248mSearch / Filter (press Enter): \27[0m")
                io.flush()
                local q = io.read("*l")
                enable_raw_mode()
                if q then
                    filter_query = q:gsub("^%s+", ""):gsub("%s+$", "")
                    sel_index = 1
                    reload_current()
                end
            end
            if current_dir ~= previous_dir or sel_index ~= previous_selection then
                preview_pending = true
            end
        elseif preview_pending then
            -- Wait for one quiet input interval before doing potentially expensive preview work.
            preview_pending = false
            needs_redraw = true
        end
    end

    disable_raw_mode()
    print("\n\27[1;36mExited Lumina. Goodbye!\27[0m")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    disable_raw_mode()
    io.stderr:write("\27[1;31mLumina error:\27[0m " .. tostring(err) .. "\n")
    os.exit(1)
end
