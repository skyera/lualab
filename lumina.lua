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
      * l / →            : Open directory
      * Enter            : Open directory, edit text, or view images
      * j / ↓            : Move cursor down
      * k / ↑            : Move cursor up
      * H / gh           : Jump to start directory (where Lumina was launched)
      * ~                : Jump to user's home directory ($HOME)
      * /                : Instant fuzzy in-directory filter
      * f / Ctrl+P       : Global recursive fuzzy file finder
      * t / T            : Cycle color theme forward / backward
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
            unsigned int   __pad0;
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
                    while n < 3 do
                        local more = ffi.C.poll(pfd, 1, 15)
                        if more <= 0 or bit.band(pfd.revents, POLLIN) == 0 then break end
                        local got = ffi.C.read(STDIN_FILENO, key_buf + n, 3 - n)
                        if got <= 0 then break end
                        n = n + got
                    end
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
-- 2. Styling Palettes, Theme Engine & String Measurement
-- =========================================================================
local THEMES = {
    tokyo_night = {
        name          = "Tokyo Night",
        border_col    = "\27[38;2;65;72;104m",       -- Slate navy
        border_focus  = "\27[1;38;2;125;207;255m",   -- Bright cyan bold
        header_accent = "\27[1;38;2;125;207;255m",   -- Cyan
        header_path   = "\27[1;38;2;192;202;245m",   -- Soft white
        dir_col       = "\27[1;38;2;122;162;247m",   -- Tokyo blue bold
        exec_col      = "\27[1;38;2;158;206;106m",   -- Emerald green
        image_col     = "\27[1;38;2;247;118;142m",   -- Coral red
        archive_col   = "\27[1;38;2;224;175;104m",   -- Warm amber
        code_col      = "\27[38;2;125;207;255m",     -- Sky cyan
        file_col      = "\27[38;2;192;202;245m",     -- Soft white
        symlink_col   = "\27[38;2;115;218;202m",     -- Teal
        cursor_bg     = "\27[48;2;41;46;66m\27[1;38;2;255;255;255m", -- Night selection
        parent_bg     = "\27[48;2;31;35;53m\27[38;2;169;177;214m",    -- Navy muted
        syn_keyword   = "\27[1;38;2;187;154;247m",   -- Lavender
        syn_string    = "\27[38;2;158;206;106m",     -- Green
        syn_comment   = "\27[38;2;86;95;137m\27[3m", -- Italic slate
        syn_number    = "\27[38;2;255;158;100m",     -- Orange
        syn_header    = "\27[1;38;2;125;207;255m",   -- Cyan
        status_accent = "\27[1;38;2;224;175;104m",   -- Amber
    },
    dracula = {
        name          = "Dracula",
        border_col    = "\27[38;2;98;114;164m",      -- Comment purple
        border_focus  = "\27[1;38;2;189;147;249m",   -- Purple bold
        header_accent = "\27[1;38;2;255;121;198m",   -- Dracula pink
        header_path   = "\27[1;38;2;248;248;242m",   -- Foreground white
        dir_col       = "\27[1;38;2;189;147;249m",   -- Dracula purple bold
        exec_col      = "\27[1;38;2;80;250;123m",    -- Dracula green
        image_col     = "\27[1;38;2;255;121;198m",   -- Dracula pink
        archive_col   = "\27[1;38;2;255;184;108m",   -- Dracula orange
        code_col      = "\27[38;2;139;233;253m",     -- Dracula cyan
        file_col      = "\27[38;2;248;248;242m",     -- Foreground white
        symlink_col   = "\27[38;2;139;233;253m",     -- Cyan
        cursor_bg     = "\27[48;2;68;71;90m\27[1;38;2;255;255;255m", -- Selection
        parent_bg     = "\27[48;2;40;42;54m\27[38;2;189;147;249m",    -- Dark surface purple
        syn_keyword   = "\27[1;38;2;255;121;198m",   -- Pink
        syn_string    = "\27[38;2;241;250;140m",     -- Yellow
        syn_comment   = "\27[38;2;98;114;164m\27[3m", -- Italic comment purple
        syn_number    = "\27[38;2;189;147;249m",     -- Purple
        syn_header    = "\27[1;38;2;139;233;253m",   -- Cyan
        status_accent = "\27[1;38;2;241;250;140m",   -- Yellow
    },
    nord = {
        name          = "Nord",
        border_col    = "\27[38;2;76;86;106m",       -- Polar Night 3
        border_focus  = "\27[1;38;2;136;192;208m",   -- Frost Cyan bold
        header_accent = "\27[1;38;2;136;192;208m",   -- Frost Cyan
        header_path   = "\27[1;38;2;236;239;244m",   -- Snow Storm white
        dir_col       = "\27[1;38;2;129;161;193m",   -- Frost Blue bold
        exec_col      = "\27[1;38;2;163;190;140m",   -- Aurora Green
        image_col     = "\27[1;38;2;180;142;173m",   -- Aurora Purple
        archive_col   = "\27[1;38;2;235;203;139m",   -- Aurora Yellow
        code_col      = "\27[38;2;143;188;187m",     -- Frost Teal
        file_col      = "\27[38;2;229;233;240m",     -- Snow Storm
        symlink_col   = "\27[38;2;136;192;208m",     -- Frost Cyan
        cursor_bg     = "\27[48;2;67;76;94m\27[1;38;2;255;255;255m", -- Polar selection
        parent_bg     = "\27[48;2;46;52;64m\27[38;2;216;222;233m",    -- Polar surface
        syn_keyword   = "\27[1;38;2;129;161;193m",   -- Frost Blue
        syn_string    = "\27[38;2;163;190;140m",     -- Aurora Green
        syn_comment   = "\27[38;2;94;105;127m\27[3m", -- Dim slate blue
        syn_number    = "\27[38;2;208;135;112m",     -- Aurora Orange
        syn_header    = "\27[1;38;2;136;192;208m",   -- Frost Cyan
        status_accent = "\27[1;38;2;235;203;139m",   -- Aurora Yellow
    },
    monokai = {
        name          = "Monokai",
        border_col    = "\27[38;2;117;113;94m",      -- Warm grey
        border_focus  = "\27[1;38;2;230;219;116m",   -- Yellow bold
        header_accent = "\27[1;38;2;249;38;114m",    -- Magenta
        header_path   = "\27[1;38;2;248;248;242m",   -- Cream white
        dir_col       = "\27[1;38;2;102;217;239m",   -- Cyan bold
        exec_col      = "\27[1;38;2;166;226;46m",    -- Lime green
        image_col     = "\27[1;38;2;249;38;114m",    -- Magenta
        archive_col   = "\27[1;38;2;253;151;31m",    -- Orange
        code_col      = "\27[38;2;102;217;239m",     -- Cyan
        file_col      = "\27[38;2;248;248;242m",     -- Cream white
        symlink_col   = "\27[38;2;166;226;46m",     -- Lime green
        cursor_bg     = "\27[48;2;62;61;50m\27[1;38;2;255;255;255m", -- Charcoal selection
        parent_bg     = "\27[48;2;39;40;34m\27[38;2;230;219;116m",    -- Olive surface
        syn_keyword   = "\27[1;38;2;249;38;114m",    -- Magenta
        syn_string    = "\27[38;2;230;219;116m",     -- Yellow
        syn_comment   = "\27[38;2;117;113;94m\27[3m", -- Warm grey
        syn_number    = "\27[38;2;174;129;255m",     -- Purple
        syn_header    = "\27[1;38;2;102;217;239m",   -- Cyan
        status_accent = "\27[1;38;2;253;151;31m",    -- Orange
    },
    cyberpunk = {
        name          = "Cyberpunk",
        border_col    = "\27[38;2;0;100;140m",       -- Dark neon teal
        border_focus  = "\27[1;38;2;0;240;255m",     -- Laser cyan bold
        header_accent = "\27[1;38;2;254;231;21m",    -- Electric yellow
        header_path   = "\27[1;38;2;255;255;255m",   -- Pure white
        dir_col       = "\27[1;38;2;0;240;255m",     -- Laser cyan bold
        exec_col      = "\27[1;38;2;254;231;21m",    -- Electric yellow
        image_col     = "\27[1;38;2;255;0;85m",      -- Neon pink
        archive_col   = "\27[1;38;2;255;110;0m",     -- Neon orange
        code_col      = "\27[38;2;0;240;255m",       -- Laser cyan
        file_col      = "\27[38;2;230;230;230m",     -- Bright grey
        symlink_col   = "\27[38;2;255;0;85m",        -- Neon pink
        cursor_bg     = "\27[48;2;0;60;80m\27[1;38;2;0;240;255m",    -- Dark teal cyan
        parent_bg     = "\27[48;2;20;25;35m\27[38;2;254;231;21m",    -- Dark surface yellow
        syn_keyword   = "\27[1;38;2;255;0;85m",      -- Neon pink
        syn_string    = "\27[38;2;254;231;21m",      -- Electric yellow
        syn_comment   = "\27[38;2;0;140;180m\27[3m", -- Italic neon teal
        syn_number    = "\27[38;2;0;240;255m",       -- Laser cyan
        syn_header    = "\27[1;38;2;254;231;21m",    -- Electric yellow
        status_accent = "\27[1;38;2;255;0;85m",      -- Neon pink
    },
    gruvbox = {
        name          = "Gruvbox",
        border_col    = "\27[38;2;102;92;84m",       -- Gruvbox brown
        border_focus  = "\27[1;38;2;250;189;47m",    -- Yellow/Gold bold
        header_accent = "\27[1;38;2;254;128;25m",    -- Orange
        header_path   = "\27[1;38;2;235;219;178m",   -- Beige
        dir_col       = "\27[1;38;2;131;165;152m",   -- Aqua bold
        exec_col      = "\27[1;38;2;184;187;38m",    -- Green
        image_col     = "\27[1;38;2;211;134;155m",   -- Purple
        archive_col   = "\27[1;38;2;254;128;25m",    -- Orange
        code_col      = "\27[38;2;142;192;124m",     -- Aqua
        file_col      = "\27[38;2;235;219;178m",     -- Beige
        symlink_col   = "\27[38;2;142;192;124m",     -- Aqua
        cursor_bg     = "\27[48;2;60;56;54m\27[1;38;2;253;244;193m", -- Medium brown
        parent_bg     = "\27[48;2;40;40;40m\27[38;2;213;196;161m",    -- Surface beige
        syn_keyword   = "\27[1;38;2;251;73;52m",     -- Red
        syn_string    = "\27[38;2;184;187;38m",      -- Green
        syn_comment   = "\27[38;2;146;131;116m\27[3m", -- Italic warm grey
        syn_number    = "\27[38;2;211;134;155m",     -- Purple
        syn_header    = "\27[1;38;2;250;189;47m",    -- Yellow/Gold
        status_accent = "\27[1;38;2;254;128;25m",    -- Orange
    },
}

local THEME_ORDER = { "tokyo_night", "dracula", "nord", "monokai", "cyberpunk", "gruvbox" }
local current_theme_key = "tokyo_night"

local C = {}
local function set_theme(theme_key)
    if not theme_key or not THEMES[theme_key] then
        return false
    end
    current_theme_key = theme_key
    local t = THEMES[theme_key]
    for k, v in pairs(t) do
        C[k] = v
    end
    C.reset  = "\27[0m"
    C.bold   = "\27[1m"
    C.dim    = "\27[2m"
    C.italic = "\27[3m"
    return true
end

local function cycle_theme(step)
    step = step or 1
    local cur_idx = 1
    for idx, key in ipairs(THEME_ORDER) do
        if key == current_theme_key then
            cur_idx = idx
            break
        end
    end
    local new_idx = (cur_idx - 1 + step) % #THEME_ORDER + 1
    local next_key = THEME_ORDER[new_idx]
    set_theme(next_key)
    return next_key
end

-- Initialize default theme
set_theme("tokyo_night")

local function visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[a-zA-Z]", ""):gsub("[\r\n]", "")
    local count = 0
    for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local b = c:byte(1)
        if b and b >= 240 then
            count = count + 2
        elseif b and b >= 228 and b <= 233 then
            count = count + 2
        else
            count = count + 1
        end
    end
    return count
end

local function truncate(str, max_w)
    str = tostring(str):gsub("[\r\n]", "")
    local vlen = visual_len(str)
    if vlen <= max_w then return str end
    if max_w <= 3 then return string.rep(".", max_w) end

    local esc_pattern = "^\27%[[%d;]*[a-zA-Z]"
    local utf8_pattern = "^[%z\1-\127\194-\244][\128-\191]*"

    local out = {}
    local curr_w = 0
    local i = 1
    local len = #str

    while i <= len do
        local sub = str:sub(i)
        local esc = sub:match(esc_pattern)
        if esc then
            table.insert(out, esc)
            i = i + #esc
        else
            local char = sub:match(utf8_pattern) or sub:sub(1, 1)
            local b = char:byte(1)
            local w = (b and ((b >= 240) or (b >= 228 and b <= 233))) and 2 or 1
            if curr_w + w > max_w - 3 then
                table.insert(out, "\27[0m...")
                return table.concat(out)
            end
            table.insert(out, char)
            curr_w = curr_w + w
            i = i + #char
        end
    end
    return table.concat(out)
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
-- Fuzzy Search Algorithm
-- Computes case-insensitive fuzzy matching with word-boundary, acronym, and
-- consecutive-character bonus scoring.
-- =========================================================================
local function fuzzy_score(pattern, str)
    if not pattern or #pattern == 0 then return true, 0 end
    if not str or #str == 0 then return false, 0 end

    local pat_l = pattern:lower()
    local str_l = str:lower()
    local pat_len = #pat_l
    local str_len = #str_l

    if pat_len > str_len then return false, 0 end

    -- Quick exact substring check
    local sub_pos = str_l:find(pat_l, 1, true)
    local is_exact_prefix = (sub_pos == 1)

    local score = 0
    local p_idx = 1
    local prev_match_idx = -1
    local consecutive = 0

    for s_idx = 1, str_len do
        local p_char = pat_l:byte(p_idx)
        local s_char = str_l:byte(s_idx)

        if p_char == s_char then
            local char_score = 10

            -- Consecutive match bonus
            if prev_match_idx == s_idx - 1 then
                consecutive = consecutive + 1
                char_score = char_score + (consecutive * 12)
            else
                consecutive = 0
            end

            -- Word boundary bonuses (start of string or preceded by _, -, ., /, or space)
            if s_idx == 1 then
                char_score = char_score + 35
            else
                local prev_byte = str_l:byte(s_idx - 1)
                if prev_byte == 95 or prev_byte == 45 or prev_byte == 46 or prev_byte == 47 or prev_byte == 32 then
                    char_score = char_score + 30
                end
            end

            -- Exact case match bonus
            if pattern:byte(p_idx) == str:byte(s_idx) then
                char_score = char_score + 3
            end

            score = score + char_score
            prev_match_idx = s_idx
            p_idx = p_idx + 1

            if p_idx > pat_len then
                -- Match completed!
                if is_exact_prefix then
                    score = score + 50
                elseif sub_pos then
                    score = score + 25
                end
                -- Penalty for extra length (shorter matching names score higher)
                score = score - math.floor((str_len - pat_len) * 0.5)
                return true, score
            end
        end
    end

    return false, 0
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

local TEXT_EXTS = {
    txt = true, log = true, conf = true, cfg = true, ini = true, env = true,
    csv = true, tsv = true, xml = true, diff = true, patch = true,
    vim = true, zsh = true, bash = true, fish = true, make = true, cmake = true
}

local function shell_quote(path)
    if is_windows then
        return '"' .. path:gsub('"', '\\"') .. '"'
    end
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function is_command_available(cmd)
    local test_cmd = is_windows
        and ('where ' .. shell_quote(cmd) .. ' >nul 2>&1')
        or ('command -v ' .. shell_quote(cmd) .. ' >/dev/null 2>&1')
    return os.execute(test_cmd) == 0
end

local function resolve_text_editor()
    if is_command_available("nvim") then
        return "nvim"
    end
    local env_editor = os.getenv("EDITOR") or os.getenv("VISUAL")
    if env_editor and #env_editor > 0 then
        return env_editor
    end
    return is_windows and "notepad" or (is_command_available("vim") and "vim" or "vi")
end

local function is_text_file(entry)
    if not entry or entry.is_dir then return false end
    if IMAGE_EXTS[entry.ext] or ARCHIVE_EXTS[entry.ext] then return false end
    if CODE_EXTS[entry.ext] or TEXT_EXTS[entry.ext] then return true end
    if entry.size == 0 then return true end
    if entry.size > 0 and entry.size < 1024 * 1024 * 10 then
        local f = io.open(entry.path, "rb")
        if f then
            local bytes = f:read(512) or ""
            f:close()
            for i = 1, #bytes do
                local b = bytes:byte(i)
                if b < 9 or (b > 13 and b < 32) then return false end
            end
            return true
        end
    end
    return false
end

local function edit_text_file(path)
    local editor = resolve_text_editor()
    disable_raw_mode()
    local ok = os.execute(editor .. " " .. shell_quote(path))
    enable_raw_mode()
    io.write("\27[H\27[2J")
    io.flush()
    return ok
end

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

-- =========================================================================
-- Recursive Directory Scanner for Global Fuzzy Search
-- Traverses subdirectories up to max_depth and max_files to ensure responsiveness.
-- =========================================================================
local function scan_files_recursive(root_dir, max_files, max_depth, show_hidden)
    max_files = max_files or 2000
    max_depth = max_depth or 5
    local results = {}

    local function walk(dir, depth)
        if depth > max_depth or #results >= max_files then return end
        local entries = read_dir_entries(dir, show_hidden)
        for _, e in ipairs(entries) do
            if #results >= max_files then break end
            -- Compute relative path from root_dir for cleaner display and matching
            local rel_path = e.path
            if rel_path:sub(1, #root_dir) == root_dir then
                rel_path = rel_path:sub(#root_dir + 1):gsub("^[/\\]+", "")
            end
            e.rel_path = (#rel_path > 0) and rel_path or e.name
            table.insert(results, e)

            if e.is_dir and not e.is_symlink then
                -- Avoid recursive descent into version control or node_modules
                if e.name ~= ".git" and e.name ~= "node_modules" and e.name ~= ".hg" and e.name ~= ".svn" then
                    walk(e.path, depth + 1)
                end
            end
        end
    end

    walk(root_dir, 1)
    return results
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
        line = line:gsub("\r$", "")
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
        cmd = string.format('magick %q -resize %dx%d ppm:- 2>%s', filepath, max_w, max_h * 2, devnull)
    else
        cmd = string.format('magick %q -resize %dx%d ppm:- 2>%s || convert %q -resize %dx%d ppm:- 2>%s',
            filepath, max_w, max_h * 2, devnull, filepath, max_w, max_h * 2, devnull)
    end
    local pipe = io.popen(cmd, popen_rb)
    local img_data = nil
    if pipe then
        img_data = pipe:read("*a")
        pipe:close()
    end

    if not img_data or #img_data == 0 then
        local ffmpeg_cmd = string.format('ffmpeg -v error -i %q -vf scale=%d:%d:force_original_aspect_ratio=decrease -f image2pipe -vcodec ppm - 2>%s',
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
    for y = 0, h - 1, 2 do
        local line = {}
        for x = 0, w - 1 do
            local top_idx = (y * w + x) * 3 + 1
            local tr, tg, tb = raw:byte(top_idx, top_idx + 2)
            local br, bg, bb = tr, tg, tb
            if y + 1 < h then
                local bot_idx = ((y + 1) * w + x) * 3 + 1
                br, bg, bb = raw:byte(bot_idx, bot_idx + 2)
            end
            table.insert(line, string.format("\27[48;2;%d;%d;%dm\27[38;2;%d;%d;%dm▄",
                tr or 0, tg or 0, tb or 0, br or 0, bg or 0, bb or 0))
        end
        table.insert(line, C.reset)
        table.insert(lines, table.concat(line))
    end
    return lines
end

local function show_image_fullscreen(images, selected_idx)
    local image_indices = {}
    for idx, entry in ipairs(images) do
        if IMAGE_EXTS[entry.ext] then
            table.insert(image_indices, idx)
        end
    end

    local image_pos = 1
    for pos, idx in ipairs(image_indices) do
        if idx == selected_idx then
            image_pos = pos
            break
        end
    end

    local function render()
        local entry = images[image_indices[image_pos]]
        local term_w, term_h = get_terminal_size()
        local header = string.format("  %s%s%s  %s[%d/%d]%s",
            C.bold, entry.name, C.reset,
            C.dim, image_pos, #image_indices, C.reset)
        local footer = "  " .. C.dim .. "[←/→] Previous/Next  [q/Esc/Enter] Return to Lumina" .. C.reset
        local image_lines = generate_image_preview(entry.path, math.max(1, term_w - 2), math.max(1, term_h - 4))

        io.write("\27[H\27[2J\27[?25l")
        io.write(header .. "\n")
        for _, line in ipairs(image_lines) do
            io.write(line .. "\n")
        end
        io.write(string.format("\27[%d;1H\27[2K%s", term_h, footer))
        io.flush()
    end

    render()
    while true do
        local k = read_key()
        if k == "q" or k == "Q" or k == "ESC" or k == "ENTER" then
            io.write("\27[H\27[2J")
            io.flush()
            return image_indices[image_pos]
        elseif k == "LEFT" and #image_indices > 1 then
            image_pos = (image_pos - 2 + #image_indices) % #image_indices + 1
            render()
        elseif k == "RIGHT" and #image_indices > 1 then
            image_pos = image_pos % #image_indices + 1
            render()
        end
    end
end

-- =========================================================================
-- Modal Interactive Fuzzy File Finder
-- Recursive fuzzy file search across project tree with live ranking and instant preview
-- =========================================================================
local function show_fuzzy_finder(root_dir, show_hidden)
    local all_files = scan_files_recursive(root_dir, 3000, 6, show_hidden)
    local query = ""
    local sel_idx = 1
    local scroll_offset = 0

    local function get_matches()
        if #query == 0 then
            return all_files
        end
        local scored = {}
        for _, file in ipairs(all_files) do
            local matched, score = fuzzy_score(query, file.rel_path or file.name)
            if matched then
                table.insert(scored, { file = file, score = score })
            end
        end
        table.sort(scored, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return (a.file.rel_path or a.file.name):lower() < (b.file.rel_path or b.file.name):lower()
        end)
        local res = {}
        for _, item in ipairs(scored) do
            table.insert(res, item.file)
        end
        return res
    end

    local function render_modal(matches)
        local term_w, term_h = get_terminal_size()
        local box_w = math.max(40, math.min(term_w - 6, 88))
        local box_h = math.max(12, math.min(term_h - 4, 22))
        local start_x = math.floor((term_w - box_w) / 2)
        local start_y = math.floor((term_h - box_h) / 2)

        local visible_rows = box_h - 5 -- border, prompt, divider, list rows, footer
        if sel_idx <= scroll_offset then
            scroll_offset = sel_idx - 1
        elseif sel_idx > scroll_offset + visible_rows then
            scroll_offset = sel_idx - visible_rows
        end

        local out = {}
        local bcol = C.border_focus

        -- Header
        local title_str = string.format(" FUZZY FILE SEARCH (%d/%d) ", #matches, #all_files)
        local top_fill = string.rep("─", math.max(0, box_w - 2 - visual_len(title_str)))
        table.insert(out, string.format("\27[%d;%dH%s╭%s%s%s%s╮%s",
            start_y, start_x, bcol, C.bold .. C.header_path, title_str, bcol, top_fill, C.reset))

        -- Prompt Input Line
        local prompt_prefix = "  > "
        local cur_cursor = "\27[7m \27[0m"
        local input_display = C.bold .. (C.status_accent or "\27[1;38;2;251;191;36m") .. query .. cur_cursor .. C.reset
        local prompt_w = visual_len(prompt_prefix) + visual_len(query) + 1
        local prompt_pad = string.rep(" ", math.max(0, box_w - 2 - prompt_w))
        table.insert(out, string.format("\27[%d;%dH%s│%s%s%s%s│%s",
            start_y + 1, start_x, bcol, C.reset, prompt_prefix .. input_display, prompt_pad, bcol, C.reset))

        -- Divider
        local div_fill = string.rep("─", math.max(0, box_w - 2))
        table.insert(out, string.format("\27[%d;%dH%s├%s┤%s", start_y + 2, start_x, bcol, div_fill, C.reset))

        -- File List Rows
        local end_idx = math.min(#matches, scroll_offset + visible_rows)
        for r = 1, visible_rows do
            local item_idx = scroll_offset + r
            local file = matches[item_idx]
            local row_y = start_y + 2 + r
            if file then
                local is_sel = (item_idx == sel_idx)
                local icon, col = get_file_type_info(file)
                local prefix = is_sel and " ▶ " or "   "
                local name_display = file.rel_path or file.name
                local avail_w = box_w - 2 - visual_len(prefix) - 4 - visual_len(file.size_str) - 2
                if visual_len(name_display) > avail_w then
                    name_display = "..." .. name_display:sub(-math.max(10, avail_w - 4))
                end

                local text_part = prefix .. icon .. " " .. name_display
                local pad = math.max(1, box_w - 2 - visual_len(text_part) - visual_len(file.size_str))
                local row_content
                if is_sel then
                    row_content = C.cursor_bg .. text_part .. string.rep(" ", pad) .. file.size_str .. C.reset
                else
                    row_content = col .. text_part .. string.rep(" ", pad) .. C.dim .. file.size_str .. C.reset
                end
                table.insert(out, string.format("\27[%d;%dH%s│%s%s│%s", row_y, start_x, bcol, row_content, bcol, C.reset))
            else
                local blank_pad = string.rep(" ", box_w - 2)
                table.insert(out, string.format("\27[%d;%dH%s│%s%s│%s", row_y, start_x, bcol, blank_pad, bcol, C.reset))
            end
        end

        -- Footer / Key Hints
        local hint_text = " [Enter] Jump to File  [↑/↓] Select  [Esc] Cancel "
        local hint_pad = string.rep("─", math.max(0, box_w - 2 - visual_len(hint_text)))
        table.insert(out, string.format("\27[%d;%dH%s╰%s%s%s%s╯%s",
            start_y + box_h - 1, start_x, bcol, C.dim, hint_text, bcol, hint_pad, C.reset))

        io.write(table.concat(out))
        io.flush()
    end

    local matches = get_matches()
    render_modal(matches)

    while true do
        local k = read_key()
        if k then
            if k == "ESC" then
                io.write("\27[H\27[2J")
                io.flush()
                return nil
            elseif k == "ENTER" then
                io.write("\27[H\27[2J")
                io.flush()
                return matches[sel_idx]
            elseif k == "UP" then
                if sel_idx > 1 then
                    sel_idx = sel_idx - 1
                    render_modal(matches)
                end
            elseif k == "DOWN" then
                if sel_idx < #matches then
                    sel_idx = sel_idx + 1
                    render_modal(matches)
                end
            elseif k == "BACKSPACE" then
                if #query > 0 then
                    query = query:sub(1, -2)
                    matches = get_matches()
                    sel_idx = 1
                    scroll_offset = 0
                    render_modal(matches)
                end
            elseif #k == 1 and k:byte(1) >= 32 and k:byte(1) <= 126 then
                query = query .. k
                matches = get_matches()
                sel_idx = 1
                scroll_offset = 0
                render_modal(matches)
            end
        end
    end
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
    local title_str = title and string.format(" %s%s%s ", C.bold .. (C.header_path or "\27[38;2;241;245;249m"), title, bcol) or ""
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
    local sanitized = tostring(content):gsub("[\r\n]", "")
    local clr = truncate(sanitized, w - 2)
    local vlen = visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s%s", y, x + 1, clr, pad, C.reset)
end

-- =========================================================================
-- 6. Main Interactive Application Loop
-- =========================================================================
local function main(args)
    args = args or arg or {}
    local requested_path = "."
    local initial_theme = nil
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--theme" and i + 1 <= #args then
            initial_theme = args[i + 1]
            i = i + 1
        elseif a:match("^%-%-theme=(.+)$") then
            initial_theme = a:match("^%-%-theme=(.+)$")
        elseif not a:match("^%-") then
            requested_path = a
        end
        i = i + 1
    end
    if initial_theme then
        set_theme(initial_theme)
    end

    local current_dir = resolve_canonical_path(requested_path)
    local initial_selection_name

    local is_directory = false
    if is_windows then
        local fd = ffi.new("WIN32_FIND_DATAA")
        local hFind = kernel32.FindFirstFileA(requested_path, fd)
        if hFind ~= ffi.cast("void*", -1) and hFind ~= nil then
            is_directory = (bit.band(fd.dwFileAttributes, 0x10) ~= 0)
            kernel32.FindClose(hFind)
        end
    else
        local st = ffi.new("struct stat")
        if posix_stat(requested_path, st) == 0 then
            is_directory = (bit.band(tonumber(st.st_mode), 0xF000) == 0x4000)
        end
    end

    if not is_directory then
        local requested_file = io.open(requested_path, "rb")
        if requested_file then
            requested_file:close()
            initial_selection_name = requested_path:match("([^/\\]+)$")
            current_dir = get_parent_dir(requested_path)
        end
    end
    local show_hidden = false
    local filter_query = ""
    local start_dir = current_dir

    local sel_index = 1
    local current_entries = read_dir_entries(current_dir, show_hidden)
    if initial_selection_name then
        for idx, entry in ipairs(current_entries) do
            if entry.name == initial_selection_name then
                sel_index = idx
                break
            end
        end
    end
    local parent_dir = get_parent_dir(current_dir)
    local parent_entries = read_dir_entries(parent_dir, show_hidden)

    enable_raw_mode()

    local needs_redraw = true
    local is_searching = false
    local search_query = ""
    local g_prefix = false
    local preview_pending = true
    local last_w, last_h = get_terminal_size()

    -- Initial screen clear
    io.write("\27[H\27[2J")
    io.flush()

    local function reload_current()
        current_entries = read_dir_entries(current_dir, show_hidden)
        -- Filter if query exists using fuzzy scoring
        if #filter_query > 0 then
            local scored = {}
            for _, e in ipairs(current_entries) do
                local matched, score = fuzzy_score(filter_query, e.name)
                if matched then
                    table.insert(scored, { entry = e, score = score })
                end
            end
            table.sort(scored, function(a, b)
                if a.score ~= b.score then
                    return a.score > b.score
                end
                return a.entry.name:lower() < b.entry.name:lower()
            end)
            local filtered = {}
            for _, item in ipairs(scored) do
                table.insert(filtered, item.entry)
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
            local left_info = string.format("  %s⚡ LUMINA%s %s│%s %s%s%s %s(%d items)%s",
                C.bold .. (C.header_accent or C.border_focus), C.reset, C.dim, C.reset,
                C.bold .. (C.header_path or "\27[38;2;241;245;249m"), current_dir, C.reset,
                C.dim, #current_entries, C.reset)
            local badge_text = string.format("🎨 %s ", C.name or "Theme")
            local left_len = visual_len(left_info)
            local badge_len = visual_len(badge_text)

            local header_str
            if term_w > left_len + badge_len + 4 then
                local gap = term_w - left_len - badge_len
                local theme_badge = string.format("%s%s%s", C.syn_header or C.border_focus, badge_text, C.reset)
                header_str = left_info .. string.rep(" ", gap) .. theme_badge .. "\27[K"
            else
                header_str = truncate(left_info, term_w) .. "\27[K"
            end
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
            local help_hint = ""
            if is_searching then
                status_text = string.format("%s/%s\27[7m \27[0m", C.status_accent or "\27[1;38;2;251;191;36m", search_query)
                help_hint = "\27[90m[Enter] Confirm  [Esc] Cancel  [↑/↓] Select\27[0m"
            elseif #filter_query > 0 then
                status_text = string.format("%sFilter: /%s\27[0m", C.status_accent or "\27[1;38;2;251;191;36m", filter_query)
                help_hint = "[h/l] Nav  [H] Start  [j/k] Move  [/] Filter  [f] Find  [Esc] Clear  [q] Quit"
            else
                status_text = string.format("%s%s%s", C.dim, sel_entry and sel_entry.path or current_dir, C.reset)
                help_hint = "[h/l] Nav  [H/gh] Start  [~] Home  [j/k] Move  [/] Filter  [f] Find  [q] Quit"
            end
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
            if is_searching then
                if k == "ENTER" then
                    is_searching = false
                elseif k == "ESC" then
                    is_searching = false
                    search_query = ""
                    filter_query = ""
                    reload_current()
                elseif k == "BACKSPACE" then
                    if #search_query > 0 then
                        search_query = search_query:sub(1, -2)
                        filter_query = search_query
                        sel_index = 1
                        reload_current()
                    else
                        is_searching = false
                        filter_query = ""
                        reload_current()
                    end
                elseif k == "UP" then
                    if sel_index > 1 then
                        sel_index = sel_index - 1
                    end
                elseif k == "DOWN" then
                    if sel_index < #current_entries then
                        sel_index = sel_index + 1
                    end
                elseif #k == 1 and k:byte(1) >= 32 and k:byte(1) <= 126 then
                    search_query = search_query .. k
                    filter_query = search_query
                    sel_index = 1
                    reload_current()
                end
            elseif k == "q" or k == "ESC" then
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
            elseif k == "\4" or k == "CTRL_D" then
                local _, term_h = get_terminal_size()
                sel_index = math.min(#current_entries, sel_index + math.max(4, math.floor((term_h - 6) / 2)))
            elseif k == "\21" or k == "CTRL_U" then
                local _, term_h = get_terminal_size()
                sel_index = math.max(1, sel_index - math.max(4, math.floor((term_h - 6) / 2)))
            elseif k == "\6" or k == "CTRL_F" then
                local _, term_h = get_terminal_size()
                sel_index = math.min(#current_entries, sel_index + math.max(4, term_h - 6))
            elseif k == "\2" or k == "CTRL_B" then
                local _, term_h = get_terminal_size()
                sel_index = math.max(1, sel_index - math.max(4, term_h - 6))
            elseif k == "HOME" then
                sel_index = 1
            elseif k == "END" or k == "G" then
                sel_index = math.max(1, #current_entries)
            elseif k == "g" then
                if g_prefix then
                    -- 'gg': jump to top
                    sel_index = 1
                    g_prefix = false
                else
                    g_prefix = true
                end
            elseif g_prefix and (k == "h" or k == "s") then
                -- 'gh' or 'gs': Jump straight to Start Directory
                g_prefix = false
                current_dir = start_dir
                filter_query = ""
                sel_index = 1
                clear_preview_cache()
                preview_pending = true
                io.write("\27[H\27[2J")
                io.flush()
                reload_current()
            elseif k == "H" then
                -- 'H': Jump straight to Start Directory
                g_prefix = false
                current_dir = start_dir
                filter_query = ""
                sel_index = 1
                clear_preview_cache()
                preview_pending = true
                io.write("\27[H\27[2J")
                io.flush()
                reload_current()
            elseif k == "~" then
                -- '~': Jump straight to User's Home Directory
                g_prefix = false
                local home_dir = os.getenv("HOME") or os.getenv("USERPROFILE") or "/"
                current_dir = resolve_canonical_path(home_dir)
                filter_query = ""
                sel_index = 1
                clear_preview_cache()
                preview_pending = true
                io.write("\27[H\27[2J")
                io.flush()
                reload_current()
            elseif k == "LEFT" or k == "h" or k == "BACKSPACE" then
                g_prefix = false
                -- Move to parent directory
                if not is_root_dir(current_dir) then
                    local prev_dir = current_dir
                    current_dir = get_parent_dir(current_dir)
                    filter_query = ""
                    clear_preview_cache()
                    preview_pending = true
                    io.write("\27[H\27[2J")
                    io.flush()
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
                -- Open selected directory; Enter also edits supported text files.
                local sel = current_entries[sel_index]
                if sel and sel.is_dir then
                    current_dir = sel.path
                    filter_query = ""
                    sel_index = 1
                    clear_preview_cache()
                    preview_pending = true
                    io.write("\27[H\27[2J")
                    io.flush()
                    reload_current()
                elseif k == "ENTER" and IMAGE_EXTS[sel and sel.ext] then
                    sel_index = show_image_fullscreen(current_entries, sel_index) or sel_index
                    needs_redraw = true
                elseif k == "ENTER" and is_text_file(sel) then
                    edit_text_file(sel.path)
                    clear_preview_cache()
                    preview_pending = true
                    reload_current()
                    needs_redraw = true
                end
            elseif k == "t" then
                cycle_theme(1)
                clear_preview_cache()
                preview_pending = true
                needs_redraw = true
            elseif k == "T" then
                cycle_theme(-1)
                clear_preview_cache()
                preview_pending = true
                needs_redraw = true
            elseif k == "." then
                -- Toggle hidden files
                show_hidden = not show_hidden
                reload_current()
            elseif k == "r" then
                -- Refresh
                reload_current()
            elseif k == "/" then
                -- In-TUI Vim-style fuzzy search filter
                is_searching = true
                search_query = ""
                filter_query = ""
                sel_index = 1
                reload_current()
            elseif k == "f" or k == "\16" then
                -- Global recursive fuzzy file finder (f / Ctrl+P)
                local found = show_fuzzy_finder(current_dir, show_hidden)
                if found then
                    if found.is_dir then
                        current_dir = found.path
                        filter_query = ""
                        sel_index = 1
                    else
                        current_dir = get_parent_dir(found.path)
                        filter_query = ""
                        reload_current()
                        sel_index = 1
                        for idx, e in ipairs(current_entries) do
                            if e.path == found.path or e.name == found.name then
                                sel_index = idx
                                break
                            end
                        end
                    end
                    clear_preview_cache()
                    preview_pending = true
                    reload_current()
                    needs_redraw = true
                else
                    needs_redraw = true
                end
            end
            if current_dir ~= previous_dir then
                clear_preview_cache()
                preview_pending = true
                io.write("\27[H\27[2J")
                io.flush()
            elseif sel_index ~= previous_selection then
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

local M = {
    THEMES              = THEMES,
    THEME_ORDER         = THEME_ORDER,
    set_theme           = set_theme,
    cycle_theme         = cycle_theme,
    get_current_theme   = function() return current_theme_key end,
    get_theme_name      = function() return C.name end,
    C                   = C,
    visual_len          = visual_len,
    truncate            = truncate,
    format_bytes        = format_bytes,
    is_text_file        = is_text_file,
    resolve_text_editor = resolve_text_editor,
    read_dir_entries    = read_dir_entries,
    main                = main,
}

local is_entry_point = false
if arg and arg[0] then
    local script_name = arg[0]:match("([^/\\]+)$")
    if script_name and (script_name == "lumina.lua" or script_name == "lumina") then
        is_entry_point = true
    end
end

if is_entry_point then
    local ok, err = xpcall(function() return main(arg) end, debug.traceback)
    if not ok then
        disable_raw_mode()
        io.stderr:write("\27[1;31mLumina error:\27[0m " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

return M
