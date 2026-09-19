--[[
    btop_lite.lua
    A fast, beautiful, and real-time Linux & Windows System, Hardware, & Process Monitor
    written in LuaJIT with FFI.
    Inspired by btop, htop, and bottom.

    Features:
    - Zero-Fork Telemetry Engine via direct POSIX C I/O and LuaJIT FFI:
      * CPU: Per-core & overall usage, frequency scaling (GHz), thermal sensors (°C).
      * Memory & Swap: RAM used/free/cached/available breakdown + Swap meter.
      * Storage & Disk I/O: Filesystem capacity (statvfs) + real-time Read/Write disk throughput (/proc/diskstats).
      * Network I/O: Real-time Download/Upload bandwidth (B/s, KB/s, MB/s) + cumulative counters + sparklines (/proc/net/dev).
      * Process Table: Zero-fork /proc parser with greedy comm matching, thread counts, and real username resolution via getpwuid.
    - Professional TUI Architecture:
      * Responsive 4-Pane Grid Layout: CPU | Memory & Storage | Network I/O | Processes.
      * Process Tree Mode (t / F5): Hierarchical parent-child process tree rendering with branch graphics (├─, └─).
      * In-Place Non-Blocking Search (/): Instant real-time filtering without leaving raw mode or clearing screen.
      * Process Inspector Modal (Enter / i): Deep inspection of process memory, cmdline, state, threads, and UID.
      * Safe Signal Dispatcher Modal (k): Interactive signal picker (SIGTERM, SIGKILL, SIGHUP, SIGINT, SIGSTOP, SIGCONT).
      * Multiple Color Themes (T): Tokyo Night, Dracula, Nord, Monokai, Cyberpunk.
      * Interactive Help Window (? / h).
    - Dual-Mode Executable & Library:
      * Run directly as CLI tool: luajit btop_lite.lua [--test] [--theme <name>] [--interval <ms>] [--tree]
      * Reusable module: local btop = require("btop_lite")
]]

local ffi = require("ffi")
local bit = require("bit")

local is_windows = (ffi.os == "Windows")

local enable_raw_mode, disable_raw_mode, get_terminal_size, read_key
local in_raw_mode = false

-- =========================================================================
-- 1. FFI & OS Terminal Management (POSIX / Win32)
-- =========================================================================
if is_windows then
    local kernel32 = ffi.load("kernel32")
    local psapi = ffi.load("psapi")

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
        int GetSystemTimes(FILETIME *lpIdleTime, FILETIME *lpKernelTime, FILETIME *lpUserTime);

        typedef struct _SYSTEM_INFO {
            union {
                uint32_t dwOemId;
                struct { uint16_t wProcessorArchitecture; uint16_t wReserved; };
            };
            uint32_t dwPageSize;
            void *lpMinimumApplicationAddress;
            void *lpMaximumApplicationAddress;
            uintptr_t dwActiveProcessorMask;
            uint32_t dwNumberOfProcessors;
            uint32_t dwProcessorType;
            uint32_t dwAllocationGranularity;
            uint16_t wProcessorLevel;
            uint16_t wProcessorRevision;
        } SYSTEM_INFO;
        void GetSystemInfo(SYSTEM_INFO *lpSystemInfo);

        typedef struct _MEMORYSTATUSEX {
            uint32_t dwLength;
            uint32_t dwMemoryLoad;
            uint64_t ullTotalPhys;
            uint64_t ullAvailPhys;
            uint64_t ullTotalPageFile;
            uint64_t ullAvailPageFile;
            uint64_t ullTotalVirtual;
            uint64_t ullAvailVirtual;
            uint64_t ullAvailExtendedVirtual;
        } MEMORYSTATUSEX;
        int GlobalMemoryStatusEx(MEMORYSTATUSEX *lpBuffer);

        typedef struct tagPROCESSENTRY32 {
            uint32_t dwSize;
            uint32_t cntUsage;
            uint32_t th32ProcessID;
            uintptr_t th32DefaultHeapID;
            uint32_t th32ModuleID;
            uint32_t cntThreads;
            uint32_t th32ParentProcessID;
            long pcPriClassBase;
            uint32_t dwFlags;
            char szExeFile[260];
        } PROCESSENTRY32;
        HANDLE CreateToolhelp32Snapshot(uint32_t dwFlags, uint32_t th32ProcessID);
        int Process32First(HANDLE hSnapshot, PROCESSENTRY32 *lppe);
        int Process32Next(HANDLE hSnapshot, PROCESSENTRY32 *lppe);
        int CloseHandle(HANDLE hObject);

        HANDLE OpenProcess(uint32_t dwDesiredAccess, int bInheritHandle, uint32_t dwProcessId);
        int TerminateProcess(HANDLE hProcess, uint32_t uExitCode);
        int GetProcessTimes(HANDLE hProcess, FILETIME *lpCreationTime, FILETIME *lpExitTime, FILETIME *lpKernelTime, FILETIME *lpUserTime);

        typedef struct _PROCESS_MEMORY_COUNTERS {
            uint32_t cb;
            uint32_t PageFaultCount;
            size_t PeakWorkingSetSize;
            size_t WorkingSetSize;
            size_t QuotaPeakPagedPoolUsage;
            size_t QuotaPagedPoolUsage;
            size_t QuotaPeakNonPagedPoolUsage;
            size_t QuotaNonPagedPoolUsage;
            size_t PagefileUsage;
            size_t PeakPagefileUsage;
        } PROCESS_MEMORY_COUNTERS;
        int GetProcessMemoryInfo(HANDLE hProcess, PROCESS_MEMORY_COUNTERS *ppmc, uint32_t cb);

        int GetDiskFreeSpaceExA(const char *lpDirectoryName, uint64_t *lpFreeBytesAvailableToCaller, uint64_t *lpTotalNumberOfBytes, uint64_t *lpTotalNumberOfFreeBytes);
    ]]

    local orig_in_mode = ffi.new("uint32_t[1]")
    local orig_out_mode = ffi.new("uint32_t[1]")

    enable_raw_mode = function()
        local hIn = kernel32.GetStdHandle(0xFFFFFFF6)
        local hOut = kernel32.GetStdHandle(0xFFFFFFF5)
        if kernel32.GetConsoleMode(hIn, orig_in_mode) == 0 then
            io.write("\27[?1049h\27[?25l")
            io.flush()
            in_raw_mode = true
            return false
        end
        kernel32.GetConsoleMode(hOut, orig_out_mode)
        kernel32.SetConsoleOutputCP(65001)
        kernel32.SetConsoleMode(hOut, bit.bor(orig_out_mode[0], 0x0004))
        local raw_mode = bit.band(orig_in_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
        raw_mode = bit.bor(raw_mode, 0x0200)
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
            local hIn = kernel32.GetStdHandle(0xFFFFFFF6)
            local hOut = kernel32.GetStdHandle(0xFFFFFFF5)
            if orig_in_mode[0] ~= 0 then kernel32.SetConsoleMode(hIn, orig_in_mode[0]) end
            if orig_out_mode[0] ~= 0 then kernel32.SetConsoleMode(hOut, orig_out_mode[0]) end
            in_raw_mode = false
        end
    end

    get_terminal_size = function()
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        local hOut = kernel32.GetStdHandle(0xFFFFFFF5)
        if kernel32.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local w = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local h = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            if w > 0 and h > 0 then return tonumber(w), tonumber(h) end
        end
        return 100, 30
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 50
        local hIn = kernel32.GetStdHandle(0xFFFFFFF6)
        local mode = ffi.new("uint32_t[1]")
        if kernel32.GetConsoleMode(hIn, mode) == 0 then
            local ch = io.read(1)
            if not ch or ch == "" then return nil end
            if ch == "\27" then return "ESC"
            elseif ch == "\n" or ch == "\r" then return "ENTER"
            elseif ch == " " then return "SPACE"
            else return ch end
        end

        local elapsed = 0
        while elapsed < timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                local ch = ffi.C._getch()
                if ch == 224 or ch == 0 then
                    local ch2 = ffi.C._getch()
                    if ch2 == 72 then return "UP"
                    elseif ch2 == 80 then return "DOWN"
                    elseif ch2 == 75 then return "LEFT"
                    elseif ch2 == 77 then return "RIGHT"
                    elseif ch2 == 73 then return "PAGE_UP"
                    elseif ch2 == 81 then return "PAGE_DOWN"
                    elseif ch2 == 71 then return "HOME"
                    elseif ch2 == 79 then return "END"
                    end
                elseif ch == 27 then return "ESC"
                elseif ch == 13 or ch == 10 then return "ENTER"
                elseif ch == 8 then return "BACKSPACE"
                elseif ch == 32 then return "SPACE"
                else return string.char(ch) end
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

        int kill(int pid, int sig);
        long sysconf(int name);
        unsigned int getuid(void);

        typedef unsigned int uid_t;
        typedef unsigned int gid_t;
        struct passwd {
            char   *pw_name;
            char   *pw_passwd;
            uid_t   pw_uid;
            gid_t   pw_gid;
            char   *pw_gecos;
            char   *pw_dir;
            char   *pw_shell;
        };
        struct passwd *getpwuid(uid_t uid);

        typedef unsigned long fsblkcnt_t;
        typedef unsigned long fsfilcnt_t;
        struct statvfs {
            unsigned long f_bsize;
            unsigned long f_frsize;
            fsblkcnt_t    f_blocks;
            fsblkcnt_t    f_bfree;
            fsblkcnt_t    f_bavail;
            fsfilcnt_t    f_files;
            fsfilcnt_t    f_ffree;
            fsfilcnt_t    f_favail;
            unsigned long f_fsid;
            unsigned long f_flag;
            unsigned long f_namemax;
            int __f_spare[6];
        };
        int statvfs(const char *path, struct statvfs *buf);

        struct timespec { long tv_sec; long tv_nsec; };
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
            struct timespec st_atim;
            struct timespec st_mtim;
            struct timespec st_ctim;
            long           __glibc_reserved[3];
        };
        int stat(const char *pathname, struct stat *statbuf);
        int __xstat(int ver, const char *pathname, struct stat *statbuf);

        typedef void (*sighandler_t)(int);
        sighandler_t signal(int signum, sighandler_t handler);
    ]]

    local TIOCGWINSZ   = 0x5413
    local STDIN_FILENO = 0
    local TCSANOW      = 0
    local ICANON       = 2
    local ECHO         = 8
    local POLLIN       = 1

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")
    local sig_cb_anchor = nil

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1049l\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            in_raw_mode = false
        end
    end

    local function install_signal_cleanup()
        if sig_cb_anchor then return end
        sig_cb_anchor = ffi.cast("sighandler_t", function(sig)
            disable_raw_mode()
            os.exit(128 + sig)
        end)
        pcall(function()
            ffi.C.signal(1, sig_cb_anchor)  -- SIGHUP
            ffi.C.signal(2, sig_cb_anchor)  -- SIGINT
            ffi.C.signal(3, sig_cb_anchor)  -- SIGQUIT
            ffi.C.signal(15, sig_cb_anchor) -- SIGTERM
        end)
    end

    enable_raw_mode = function()
        if ffi.C.isatty(STDIN_FILENO) ~= 1 then return false end
        ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        in_raw_mode = true

        install_signal_cleanup()
        io.write("\27[?1049h\27[?25l")
        io.flush()
        return true
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
                        -- Function keys
                        if c2 == 49 and n >= 4 and key_buf[3] == 53 and key_buf[4] == 126 then return "F5" end
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
-- 2. Theme Engine & Color Palettes
-- =========================================================================
local THEMES = {
    tokyo_night = {
        name         = "Tokyo Night",
        border_col   = "\27[38;2;65;72;104m",       -- Slate Navy
        border_focus = "\27[1;38;2;125;207;255m",   -- Cyan
        title_col    = "\27[1;38;2;192;202;245m",   -- Soft White
        cpu_low      = "\27[38;2;158;206;106m",     -- Emerald Green
        cpu_mid      = "\27[38;2;224;175;104m",     -- Amber
        cpu_high     = "\27[1;38;2;247;118;142m",   -- Coral Red
        mem_used     = "\27[38;2;187;154;247m",     -- Lavender Purple
        mem_swap     = "\27[38;2;255;158;100m",     -- Orange
        net_rx       = "\27[38;2;125;207;255m",     -- Bright Cyan
        net_tx       = "\27[38;2;187;154;247m",     -- Purple
        disk_read    = "\27[38;2;158;206;106m",     -- Green
        disk_write   = "\27[38;2;224;175;104m",     -- Amber
        sel_bg       = "\27[48;2;41;46;66m\27[1;38;2;255;255;255m",
        table_hdr    = "\27[1;38;2;122;162;247m",   -- Blue
        col_pid      = "\27[38;2;125;207;255m",
        col_user     = "\27[38;2;169;177;214m",
        col_pri      = "\27[38;2;224;175;104m",
        tree_branch  = "\27[38;2;86;95;137m",
        modal_bg     = "\27[48;2;26;27;38m",
    },
    dracula = {
        name         = "Dracula",
        border_col   = "\27[38;2;98;114;164m",      -- Comment Purple
        border_focus = "\27[1;38;2;139;233;253m",   -- Cyan
        title_col    = "\27[1;38;2;248;248;242m",   -- Foreground
        cpu_low      = "\27[38;2;80;250;123m",      -- Green
        cpu_mid      = "\27[38;2;241;250;140m",     -- Yellow
        cpu_high     = "\27[1;38;2;255;85;85m",     -- Red
        mem_used     = "\27[38;2;189;147;249m",     -- Purple
        mem_swap     = "\27[38;2;255;121;198m",     -- Pink
        net_rx       = "\27[38;2;139;233;253m",     -- Cyan
        net_tx       = "\27[38;2;255;121;198m",     -- Pink
        disk_read    = "\27[38;2;80;250;123m",
        disk_write   = "\27[38;2;255;184;108m",     -- Orange
        sel_bg       = "\27[48;2;68;71;90m\27[1;38;2;255;255;255m",
        table_hdr    = "\27[1;38;2;189;147;249m",
        col_pid      = "\27[38;2;139;233;253m",
        col_user     = "\27[38;2;248;248;242m",
        col_pri      = "\27[38;2;241;250;140m",
        tree_branch  = "\27[38;2;98;114;164m",
        modal_bg     = "\27[48;2;40;42;54m",
    },
    nord = {
        name         = "Nord",
        border_col   = "\27[38;2;76;86;106m",       -- Polar Night 3
        border_focus = "\27[1;38;2;136;192;208m",   -- Frost Cyan
        title_col    = "\27[1;38;2;236;239;244m",   -- Snow Storm
        cpu_low      = "\27[38;2;163;190;140m",     -- Aurora Green
        cpu_mid      = "\27[38;2;235;203;139m",     -- Aurora Yellow
        cpu_high     = "\27[1;38;2;191;97;106m",    -- Aurora Red
        mem_used     = "\27[38;2;180;142;173m",     -- Aurora Purple
        mem_swap     = "\27[38;2;208;135;112m",     -- Aurora Orange
        net_rx       = "\27[38;2;143;188;187m",     -- Frost Teal
        net_tx       = "\27[38;2;129;161;193m",     -- Frost Blue
        disk_read    = "\27[38;2;163;190;140m",
        disk_write   = "\27[38;2;235;203;139m",
        sel_bg       = "\27[48;2;67;76;94m\27[1;38;2;255;255;255m",
        table_hdr    = "\27[1;38;2;136;192;208m",
        col_pid      = "\27[38;2;129;161;193m",
        col_user     = "\27[38;2;229;233;240m",
        col_pri      = "\27[38;2;235;203;139m",
        tree_branch  = "\27[38;2;76;86;106m",
        modal_bg     = "\27[48;2;46;52;64m",
    },
    cyberpunk = {
        name         = "Cyberpunk",
        border_col   = "\27[38;2;0;100;140m",
        border_focus = "\27[1;38;2;0;240;255m",     -- Neon Cyan
        title_col    = "\27[1;38;2;254;231;21m",    -- Neon Yellow
        cpu_low      = "\27[38;2;0;240;255m",       -- Cyan
        cpu_mid      = "\27[38;2;254;231;21m",      -- Yellow
        cpu_high     = "\27[1;38;2;255;0;85m",      -- Neon Pink
        mem_used     = "\27[38;2;255;0;85m",
        mem_swap     = "\27[38;2;254;231;21m",
        net_rx       = "\27[38;2;0;240;255m",
        net_tx       = "\27[38;2;255;0;85m",
        disk_read    = "\27[38;2;0;240;255m",
        disk_write   = "\27[38;2;254;231;21m",
        sel_bg       = "\27[48;2;0;60;80m\27[1;38;2;0;240;255m",
        table_hdr    = "\27[1;38;2;254;231;21m",
        col_pid      = "\27[38;2;0;240;255m",
        col_user     = "\27[38;2;230;230;230m",
        col_pri      = "\27[38;2;254;231;21m",
        tree_branch  = "\27[38;2;0;140;180m",
        modal_bg     = "\27[48;2;10;15;25m",
    },
    monokai = {
        name         = "Monokai",
        border_col   = "\27[38;2;117;113;94m",
        border_focus = "\27[1;38;2;230;219;116m",   -- Yellow
        title_col    = "\27[1;38;2;248;248;242m",
        cpu_low      = "\27[38;2;166;226;46m",      -- Green
        cpu_mid      = "\27[38;2;253;151;31m",      -- Orange
        cpu_high     = "\27[1;38;2;249;38;114m",    -- Magenta
        mem_used     = "\27[38;2;174;129;255m",     -- Purple
        mem_swap     = "\27[38;2;249;38;114m",
        net_rx       = "\27[38;2;102;217;239m",     -- Cyan
        net_tx       = "\27[38;2;166;226;46m",
        disk_read    = "\27[38;2;102;217;239m",
        disk_write   = "\27[38;2;253;151;31m",
        sel_bg       = "\27[48;2;62;61;50m\27[1;38;2;255;255;255m",
        table_hdr    = "\27[1;38;2;230;219;116m",
        col_pid      = "\27[38;2;102;217;239m",
        col_user     = "\27[38;2;248;248;242m",
        col_pri      = "\27[38;2;253;151;31m",
        tree_branch  = "\27[38;2;117;113;94m",
        modal_bg     = "\27[48;2;39;40;34m",
    }
}

local current_theme_key = "tokyo_night"
local C = THEMES[current_theme_key]
C.reset = "\27[0m"
C.bold  = "\27[1m"
C.dim   = "\27[2m"

local function set_theme(theme_name)
    if THEMES[theme_name] then
        current_theme_key = theme_name
        local t = THEMES[theme_name]
        for k, v in pairs(t) do C[k] = v end
        C.reset = "\27[0m"
        C.bold  = "\27[1m"
        C.dim   = "\27[2m"
        return true
    end
    return false
end

local theme_order = { "tokyo_night", "dracula", "nord", "cyberpunk", "monokai" }
local function cycle_theme()
    local idx = 1
    for i, k in ipairs(theme_order) do
        if k == current_theme_key then idx = i break end
    end
    local next_idx = (idx % #theme_order) + 1
    set_theme(theme_order[next_idx])
    return theme_order[next_idx]
end

-- =========================================================================
-- 3. Visual Meters, Sparklines, & String Measurement
-- =========================================================================
local SPARK_CHARS = { " ", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function visual_len(str)
    local clean = tostring(str):gsub("\27%[[%d;]*[mK]", "")
    local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
    return count
end

local function truncate(str, max_w)
    local len = visual_len(str)
    if len <= max_w then return str end
    if max_w <= 3 then return string.rep(".", math.max(0, max_w)) end

    local out = {}
    local curr = 0
    -- Preserve ANSI formatting while truncating visible characters
    local pos = 1
    local raw = tostring(str)
    while pos <= #raw and curr < max_w - 3 do
        local ansi = raw:match("^\27%[[%d;]*[mK]", pos)
        if ansi then
            table.insert(out, ansi)
            pos = pos + #ansi
        else
            local c = raw:match("^[%z\1-\127\194-\244][\128-\191]*", pos)
            if c then
                table.insert(out, c)
                curr = curr + 1
                pos = pos + #c
            else
                break
            end
        end
    end
    local has_ansi = (raw:find("\27[", 1, true) ~= nil)
    return table.concat(out) .. "..." .. (has_ansi and C.reset or "")
end

local function format_bytes(kb)
    if not kb or kb <= 0 then return "0 B" end
    if kb < 1024 then
        return string.format("%d K", kb)
    elseif kb < 1024 * 1024 then
        return string.format("%.1f M", kb / 1024)
    elseif kb < 1024 * 1024 * 1024 then
        return string.format("%.2f G", kb / (1024 * 1024))
    else
        return string.format("%.2f T", kb / (1024 * 1024 * 1024))
    end
end

local function format_rate(bytes_sec)
    if not bytes_sec or bytes_sec < 0 then bytes_sec = 0 end
    if bytes_sec < 1024 then
        return string.format("%4.0f B/s", bytes_sec)
    elseif bytes_sec < 1024 * 1024 then
        return string.format("%5.1f KB/s", bytes_sec / 1024)
    elseif bytes_sec < 1024 * 1024 * 1024 then
        return string.format("%5.2f MB/s", bytes_sec / (1024 * 1024))
    else
        return string.format("%5.2f GB/s", bytes_sec / (1024 * 1024 * 1024))
    end
end

local function make_meter_bar(pct, width, col_override)
    width = math.max(4, width or 10)
    pct = math.max(0.0, math.min(100.0, pct or 0.0))
    local filled = math.floor((pct / 100.0) * width)
    filled = math.max(0, math.min(width, filled))
    local empty = width - filled

    local col = col_override
    if not col then
        if pct > 80 then col = C.cpu_high
        elseif pct > 50 then col = C.cpu_mid
        else col = C.cpu_low end
    end

    return string.format("%s%s\27[90m%s%s", col, string.rep("■", filled), string.rep("·", empty), C.reset)
end

local function make_sparkline(history_tbl, max_chars, color_code)
    if not history_tbl or #history_tbl == 0 then return "" end
    max_chars = max_chars or 20
    color_code = color_code or C.cpu_low

    local start_idx = math.max(1, #history_tbl - max_chars + 1)
    local chars = {}

    -- Find maximum in window for relative scaling if all values are small
    local max_val = 1.0
    for i = start_idx, #history_tbl do
        if history_tbl[i] > max_val then max_val = history_tbl[i] end
    end

    for i = start_idx, #history_tbl do
        local val = history_tbl[i] or 0
        local ratio = math.max(0.0, math.min(1.0, val / max_val))
        local idx = math.max(1, math.min(8, math.floor(ratio * 7) + 1))
        table.insert(chars, SPARK_CHARS[idx])
    end
    return string.format("%s%s%s", color_code, table.concat(chars), C.reset)
end

-- =========================================================================
-- 4. Cross-Platform Telemetry Engine (Hardware, /proc, FFI)
-- =========================================================================
local read_cpu_stats, read_cpu_sensors, read_memory_stats
local read_network_stats, read_storage_stats, read_loadavg
local read_process_table, terminate_process, kill_process, send_signal_to_process

local uid_cache = {}
local function resolve_username(uid)
    if not uid then return "unknown" end
    if uid_cache[uid] then return uid_cache[uid] end

    if is_windows then
        uid_cache[uid] = "SYSTEM"
        return "SYSTEM"
    else
        local pw = ffi.C.getpwuid(uid)
        local name = (pw ~= nil and pw.pw_name ~= nil) and ffi.string(pw.pw_name) or tostring(uid)
        uid_cache[uid] = name
        return name
    end
end

if is_windows then
    local kernel32 = ffi.load("kernel32")
    local psapi = ffi.load("psapi")

    local function filetime_to_num(ft)
        return tonumber(ft.dwHighDateTime) * 4294967296 + tonumber(ft.dwLowDateTime)
    end

    local sys_info = ffi.new("SYSTEM_INFO")
    kernel32.GetSystemInfo(sys_info)
    local num_cores = math.max(1, tonumber(sys_info.dwNumberOfProcessors))

    local prev_idle_t = 0
    local prev_kern_t = 0
    local prev_user_t = 0

    read_cpu_stats = function()
        local idle_ft = ffi.new("FILETIME")
        local kern_ft = ffi.new("FILETIME")
        local user_ft = ffi.new("FILETIME")
        if kernel32.GetSystemTimes(idle_ft, kern_ft, user_ft) == 0 then
            return {}, 0
        end
        local idle_t = filetime_to_num(idle_ft)
        local kern_t = filetime_to_num(kern_ft)
        local user_t = filetime_to_num(user_ft)

        local overall_pct = 0
        if prev_kern_t > 0 then
            local d_idle = idle_t - prev_idle_t
            local d_kern = kern_t - prev_kern_t
            local d_user = user_t - prev_user_t
            local total_sys = d_kern + d_user
            local busy = (d_kern - d_idle) + d_user
            if total_sys > 0 then
                overall_pct = math.min(100.0, math.max(0.0, (busy / total_sys) * 100.0))
            end
        end
        prev_idle_t = idle_t
        prev_kern_t = kern_t
        prev_user_t = user_t

        local cores = {}
        for i = 1, num_cores do
            table.insert(cores, { name = "cpu" .. (i - 1), pct = overall_pct })
        end
        return cores, overall_pct
    end

    read_cpu_sensors = function()
        return nil, nil -- Temperature / frequency requires WMI on Win32
    end

    read_memory_stats = function()
        local mem_status = ffi.new("MEMORYSTATUSEX")
        mem_status.dwLength = ffi.sizeof(mem_status)
        if kernel32.GlobalMemoryStatusEx(mem_status) == 0 then
            return {
                total_kb = 1, used_kb = 0, avail_kb = 1, buffers_kb = 0, cached_kb = 0,
                used_pct = 0, swap_total_kb = 0, swap_used_kb = 0, swap_pct = 0
            }
        end
        local total_kb = tonumber(mem_status.ullTotalPhys / 1024)
        local avail_kb = tonumber(mem_status.ullAvailPhys / 1024)
        local used_kb  = math.max(0, total_kb - avail_kb)
        local used_pct = (total_kb > 0) and ((used_kb / total_kb) * 100.0) or 0

        local pagefile_total_kb = tonumber(mem_status.ullTotalPageFile / 1024)
        local pagefile_avail_kb = tonumber(mem_status.ullAvailPageFile / 1024)
        local swap_total_kb = math.max(0, pagefile_total_kb - total_kb)
        local swap_used_kb  = math.max(0, (pagefile_total_kb - pagefile_avail_kb) - used_kb)
        local swap_pct = (swap_total_kb > 0) and ((swap_used_kb / swap_total_kb) * 100.0) or 0

        return {
            total_kb = total_kb,
            used_kb = used_kb,
            avail_kb = avail_kb,
            buffers_kb = 0,
            cached_kb = 0,
            used_pct = used_pct,
            swap_total_kb = swap_total_kb,
            swap_used_kb = swap_used_kb,
            swap_pct = swap_pct,
        }
    end

    read_network_stats = function(now_clock)
        return {
            active_iface = "Ethernet",
            rx_rate = 0,
            tx_rate = 0,
            rx_total = 0,
            tx_total = 0,
            ifaces = {}
        }
    end

    read_storage_stats = function(now_clock)
        local free_caller = ffi.new("uint64_t[1]")
        local total_bytes = ffi.new("uint64_t[1]")
        local total_free   = ffi.new("uint64_t[1]")
        local mounts = {}

        if kernel32.GetDiskFreeSpaceExA("C:\\", free_caller, total_bytes, total_free) ~= 0 then
            local tot = tonumber(total_bytes[0])
            local fre = tonumber(total_free[0])
            local usd = math.max(0, tot - fre)
            local pct = tot > 0 and (usd / tot * 100.0) or 0
            table.insert(mounts, {
                mount = "C:",
                device = "C:",
                total_bytes = tot,
                used_bytes = usd,
                avail_bytes = fre,
                used_pct = pct,
            })
        end
        return {
            mounts = mounts,
            read_speed = 0,
            write_speed = 0
        }
    end

    read_loadavg = function(overall_cpu, num_procs)
        local approx_load = (overall_cpu or 0) / 100 * num_cores
        return string.format("%.2f", approx_load), string.format("%d procs", num_procs or 0)
    end

    local prev_win_proc_times = {}

    read_process_table = function(mem_total_kb, now_clock)
        local snap = kernel32.CreateToolhelp32Snapshot(0x02, 0)
        if snap == ffi.cast("void*", -1) or snap == nil then return {} end

        local pe = ffi.new("PROCESSENTRY32")
        pe.dwSize = ffi.sizeof(pe)
        local pmc = ffi.new("PROCESS_MEMORY_COUNTERS")
        pmc.cb = ffi.sizeof(pmc)
        local c_ft, e_ft, k_ft, u_ft = ffi.new("FILETIME"), ffi.new("FILETIME"), ffi.new("FILETIME"), ffi.new("FILETIME")

        local procs = {}
        local ok = kernel32.Process32First(snap, pe)

        while ok ~= 0 do
            local pid = pe.th32ProcessID
            local ppid = pe.th32ParentProcessID
            local exe = ffi.string(pe.szExeFile)
            local res_kb = 0
            local cpu_pct = 0
            local threads = tonumber(pe.cntThreads) or 1

            if pid ~= 0 then
                local h = kernel32.OpenProcess(0x1000, 0, pid)
                if h ~= nil then
                    if psapi.GetProcessMemoryInfo(h, pmc, pmc.cb) ~= 0 then
                        res_kb = tonumber(pmc.WorkingSetSize / 1024)
                    end
                    if kernel32.GetProcessTimes(h, c_ft, e_ft, k_ft, u_ft) ~= 0 then
                        local total_t = filetime_to_num(k_ft) + filetime_to_num(u_ft)
                        local prev = prev_win_proc_times[pid]
                        if prev and prev.clock > 0 then
                            local d_t = total_t - prev.time
                            local d_clock = now_clock - prev.clock
                            if d_clock > 0 and d_t >= 0 then
                                cpu_pct = math.min(100.0, math.max(0.0, (d_t / 1e7 / d_clock) * 100.0 / num_cores))
                            end
                        end
                        prev_win_proc_times[pid] = { time = total_t, clock = now_clock }
                    end
                    kernel32.CloseHandle(h)
                end
            end

            local mem_pct = (mem_total_kb > 0) and ((res_kb / mem_total_kb) * 100.0) or 0
            table.insert(procs, {
                pid = pid,
                ppid = ppid,
                comm = exe,
                cmdline = exe,
                state = "R",
                nice = 0,
                cpu_pct = cpu_pct,
                mem_pct = mem_pct,
                res_kb = res_kb,
                vsize_kb = res_kb,
                threads = threads,
                uid = 0,
                username = "SYSTEM",
                io_read_bytes = 0,
                io_write_bytes = 0,
                io_read_rate = 0,
                io_write_rate = 0,
                io_total_rate = 0,
            })

            ok = kernel32.Process32Next(snap, pe)
        end
        kernel32.CloseHandle(snap)
        return procs
    end

    terminate_process = function(pid)
        local h = kernel32.OpenProcess(0x0001, 0, pid)
        if h ~= nil then
            kernel32.TerminateProcess(h, 1)
            kernel32.CloseHandle(h)
        end
    end

    kill_process = function(pid)
        local h = kernel32.OpenProcess(0x0001, 0, pid)
        if h ~= nil then
            kernel32.TerminateProcess(h, 9)
            kernel32.CloseHandle(h)
        end
    end

    send_signal_to_process = function(pid, sig)
        if sig == 9 or sig == 15 then
            kill_process(pid)
        end
    end
else
    -- POSIX / Linux Telemetry Implementation
    local posix_stat
    if pcall(function() return ffi.C.__xstat end) then
        posix_stat = function(path, st) return ffi.C.__xstat(1, path, st) end
    else
        posix_stat = function(path, st) return ffi.C.stat(path, st) end
    end

    local SC_CLK_TCK = 2
    local clk_tck = 100
    pcall(function()
        local t = ffi.C.sysconf(SC_CLK_TCK)
        if t > 0 then clk_tck = tonumber(t) end
    end)

    local prev_cpu_totals = {}
    local prev_proc_times = {}
    local prev_proc_io = {}

    read_cpu_stats = function()
        local f = io.open("/proc/stat", "r")
        if not f then return {}, 0 end

        local cores = {}
        local overall_pct = 0

        while true do
            local line = f:read("*l")
            if not line or not line:find("^cpu") then break end

            local name, user, nice, sys, idle, iowait, irq, softirq =
                line:match("^(cpu%w*)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")

            if name then
                user = tonumber(user) or 0
                nice = tonumber(nice) or 0
                sys  = tonumber(sys) or 0
                idle = tonumber(idle) or 0
                iowait = tonumber(iowait) or 0
                irq = tonumber(irq) or 0
                softirq = tonumber(softirq) or 0

                local busy = user + nice + sys + irq + softirq
                local total = busy + idle + iowait

                local prev = prev_cpu_totals[name]
                local pct = 0
                if prev then
                    local d_total = total - prev.total
                    local d_busy  = busy - prev.busy
                    if d_total > 0 then
                        pct = math.min(100.0, math.max(0.0, (d_busy / d_total) * 100.0))
                    end
                end
                prev_cpu_totals[name] = { total = total, busy = busy }

                if name == "cpu" then
                    overall_pct = pct
                else
                    table.insert(cores, { name = name, pct = pct })
                end
            end
        end
        f:close()
        return cores, overall_pct
    end

    read_cpu_sensors = function()
        local temp_c = nil
        -- 1. Check /sys/class/hwmon for dedicated CPU temperature drivers (coretemp, k10temp, zenpower, cpu_thermal)
        for h = 0, 8 do
            local base = "/sys/class/hwmon/hwmon" .. h
            local f_name = io.open(base .. "/name", "r")
            if f_name then
                local dname = (f_name:read("*l") or ""):lower()
                f_name:close()
                if dname:find("coretemp") or dname:find("k10temp") or dname:find("zenpower") or dname:find("cpu") then
                    for t_idx = 1, 5 do
                        local f_t = io.open(string.format("%s/temp%d_input", base, t_idx), "r")
                        if f_t then
                            local raw = f_t:read("*l")
                            f_t:close()
                            local t = tonumber(raw)
                            if t and t > 0 then
                                temp_c = (t > 1000) and (t / 1000.0) or t
                                break
                            end
                        end
                    end
                    if temp_c then break end
                end
            end
        end

        -- 2. Fallback to /sys/class/thermal zones if hwmon yielded no CPU sensor
        if not temp_c then
            for zone = 0, 5 do
                local f = io.open("/sys/class/thermal/thermal_zone" .. zone .. "/temp", "r")
                if f then
                    local raw = f:read("*l")
                    f:close()
                    local t = tonumber(raw)
                    if t and t > 0 then
                        temp_c = (t > 1000) and (t / 1000.0) or t
                        break
                    end
                end
            end
        end

        local freq_ghz = nil
        local f_freq = io.open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "r")
        if f_freq then
            local raw = f_freq:read("*l")
            f_freq:close()
            local f = tonumber(raw)
            if f and f > 0 then
                freq_ghz = f / 1000000.0
            end
        end

        return temp_c, freq_ghz
    end

    read_memory_stats = function()
        local f = io.open("/proc/meminfo", "r")
        if not f then return {} end

        local mem = {}
        while true do
            local line = f:read("*l")
            if not line then break end
            local k, v = line:match("([^:]+):%s+(%d+)")
            if k and v then
                mem[k] = tonumber(v)
            end
        end
        f:close()

        local total = mem["MemTotal"] or 1
        local free = mem["MemFree"] or 0
        local avail = mem["MemAvailable"] or free
        local buffers = mem["Buffers"] or 0
        local cached = mem["Cached"] or 0
        local used = total - avail

        local swap_total = mem["SwapTotal"] or 0
        local swap_free = mem["SwapFree"] or 0
        local swap_used = swap_total - swap_free

        return {
            total_kb = total,
            used_kb = used,
            avail_kb = avail,
            buffers_kb = buffers,
            cached_kb = cached,
            used_pct = (used / total) * 100.0,
            swap_total_kb = swap_total,
            swap_used_kb = swap_used,
            swap_pct = (swap_total > 0) and ((swap_used / swap_total) * 100.0) or 0,
        }
    end

    local prev_net_times = {}
    local prev_net_clock = 0

    read_network_stats = function(now_clock)
        local f = io.open("/proc/net/dev", "r")
        if not f then
            return { active_iface = "lo", rx_rate = 0, tx_rate = 0, rx_total = 0, tx_total = 0, ifaces = {} }
        end

        local ifaces = {}
        local primary = nil
        local max_traffic = -1

        for line in f:lines() do
            local iface, rest = line:match("^%s*([^:]+):%s*(.*)$")
            if iface and iface ~= "lo" then
                local parts = {}
                for num in rest:gmatch("%S+") do
                    table.insert(parts, tonumber(num) or 0)
                    if #parts >= 10 then break end
                end

                local rx_bytes = parts[1] or 0
                local tx_bytes = parts[9] or 0
                local prev = prev_net_times[iface]
                local rx_rate = 0
                local tx_rate = 0

                if prev and prev_net_clock > 0 then
                    local dt = now_clock - prev_net_clock
                    if dt > 0 then
                        local d_rx = rx_bytes - prev.rx
                        local d_tx = tx_bytes - prev.tx
                        if d_rx >= 0 then rx_rate = d_rx / dt end
                        if d_tx >= 0 then tx_rate = d_tx / dt end
                    end
                end
                prev_net_times[iface] = { rx = rx_bytes, tx = tx_bytes }

                local if_data = {
                    name = iface,
                    rx_rate = rx_rate,
                    tx_rate = tx_rate,
                    rx_total = rx_bytes,
                    tx_total = tx_bytes,
                }
                table.insert(ifaces, if_data)

                local sum_traffic = rx_bytes + tx_bytes
                if sum_traffic > max_traffic then
                    max_traffic = sum_traffic
                    primary = if_data
                end
            end
        end
        f:close()
        prev_net_clock = now_clock

        primary = primary or (ifaces[1] or { name = "eth0", rx_rate = 0, tx_rate = 0, rx_total = 0, tx_total = 0 })

        return {
            active_iface = primary.name,
            rx_rate = primary.rx_rate,
            tx_rate = primary.tx_rate,
            rx_total = primary.rx_total,
            tx_total = primary.tx_total,
            ifaces = ifaces
        }
    end

    local prev_disk_times = {}
    local prev_disk_clock = 0

    read_storage_stats = function(now_clock)
        local mounts = {}
        local seen_mounts = {}

        local f_mnt = io.open("/proc/mounts", "r")
        if f_mnt then
            local sv = ffi.new("struct statvfs")
            for line in f_mnt:lines() do
                local dev, mnt, fstype = line:match("^(%S+)%s+(%S+)%s+(%S+)")
                if dev and dev:find("^/dev/") and not dev:find("^/dev/loop") and not seen_mounts[mnt] then
                    seen_mounts[mnt] = true
                    if ffi.C.statvfs(mnt, sv) == 0 then
                        local bsize = tonumber(sv.f_frsize) > 0 and tonumber(sv.f_frsize) or tonumber(sv.f_bsize)
                        local total = tonumber(sv.f_blocks) * bsize
                        local free = tonumber(sv.f_bfree) * bsize
                        local avail = tonumber(sv.f_bavail) * bsize
                        local used = math.max(0, total - free)
                        local pct = (total > 0) and (used / total * 100.0) or 0

                        table.insert(mounts, {
                            mount = mnt,
                            device = dev,
                            fstype = fstype,
                            total_bytes = total,
                            used_bytes = used,
                            avail_bytes = avail,
                            used_pct = pct,
                        })
                    end
                end
            end
            f_mnt:close()
        end

        -- Read Disk Read/Write rates from /proc/diskstats
        local read_speed = 0
        local write_speed = 0
        local f_disk = io.open("/proc/diskstats", "r")
        if f_disk then
            local total_r_bytes = 0
            local total_w_bytes = 0
            for line in f_disk:lines() do
                local major, minor, name, r_c, r_m, r_sec, r_t, w_c, w_m, w_sec =
                    line:match("%s*(%d+)%s+(%d+)%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
                if name and (name:match("^sd[a-z]$") or name:match("^nvme%d+n%d+$") or name:match("^vd[a-z]$")) then
                    total_r_bytes = total_r_bytes + (tonumber(r_sec) or 0) * 512
                    total_w_bytes = total_w_bytes + (tonumber(w_sec) or 0) * 512
                end
            end
            f_disk:close()

            if prev_disk_clock > 0 and prev_disk_times.r ~= nil then
                local dt = now_clock - prev_disk_clock
                if dt > 0 then
                    local d_r = total_r_bytes - prev_disk_times.r
                    local d_w = total_w_bytes - prev_disk_times.w
                    if d_r >= 0 then read_speed = d_r / dt end
                    if d_w >= 0 then write_speed = d_w / dt end
                end
            end
            prev_disk_times = { r = total_r_bytes, w = total_w_bytes }
            prev_disk_clock = now_clock
        end

        return {
            mounts = mounts,
            read_speed = read_speed,
            write_speed = write_speed
        }
    end

    read_loadavg = function(overall_cpu, num_procs)
        local f = io.open("/proc/loadavg", "r")
        if not f then return "0.00 0.00 0.00", "0/0" end
        local content = f:read("*l") or ""
        f:close()
        local l1, l5, l15, tasks = content:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        return string.format("%s %s %s", l1 or "0.00", l5 or "0.00", l15 or "0.00"), tasks or ""
    end

    read_process_table = function(mem_total_kb, now_clock)
        local d = ffi.C.opendir("/proc")
        if d == nil then return {} end

        local procs = {}
        local st_buf = ffi.new("struct stat")

        while true do
            local ent = ffi.C.readdir(d)
            if ent == nil then break end
            local name = ffi.string(ent.d_name)

            if name:match("^%d+$") then
                local pid = tonumber(name)
                local proc_path = "/proc/" .. name

                -- Resolve UID via directory stat
                local uid = 0
                if posix_stat(proc_path, st_buf) == 0 then
                    uid = tonumber(st_buf.st_uid)
                end
                local username = resolve_username(uid)

                local stat_f = io.open(proc_path .. "/stat", "r")
                if stat_f then
                    local stat_line = stat_f:read("*l")
                    stat_f:close()

                    if stat_line then
                        -- Correct greedy parsing of comm and rest to prevent shifts on spaces/parentheses
                        local comm = stat_line:match("%((.*)%)") or ""
                        local rest = stat_line:match(".*%)%s+(.*)$")

                        if rest then
                            local parts = {}
                            for p in rest:gmatch("%S+") do
                                table.insert(parts, p)
                                if #parts >= 22 then break end
                            end

                            local state      = parts[1] or "R"
                            local ppid       = tonumber(parts[2]) or 0
                            local utime      = tonumber(parts[12]) or 0
                            local stime      = tonumber(parts[13]) or 0
                            local nice       = tonumber(parts[17]) or 0
                            local threads    = tonumber(parts[18]) or 1
                            local start_time = tonumber(parts[20]) or 0
                            local vsize      = tonumber(parts[21]) or 0
                            local rss_pages  = tonumber(parts[22]) or 0

                            local total_time = utime + stime
                            local prev = prev_proc_times[pid]
                            local cpu_pct = 0
                            if prev and prev.clock > 0 then
                                local dt = now_clock - prev.clock
                                local d_proc = total_time - prev.time
                                if dt > 0 and d_proc >= 0 then
                                    cpu_pct = math.min(100.0, (d_proc / clk_tck / dt) * 100.0)
                                end
                            end
                            prev_proc_times[pid] = { time = total_time, clock = now_clock }

                            local res_kb = rss_pages * 4
                            local mem_pct = (mem_total_kb > 0) and ((res_kb / mem_total_kb) * 100.0) or 0

                            local cmdline = comm
                            local cmd_f = io.open(proc_path .. "/cmdline", "r")
                            if cmd_f then
                                local raw_cmd = cmd_f:read(512) or ""
                                cmd_f:close()
                                if #raw_cmd > 0 then
                                    cmdline = raw_cmd:gsub("%z", " "):gsub("%s+$", "")
                                end
                            end

                            -- Read per-process Disk I/O (/proc/[pid]/io) safely
                            local io_read_bytes = 0
                            local io_write_bytes = 0
                            local io_read_rate = 0
                            local io_write_rate = 0
                            local io_f = io.open(proc_path .. "/io", "r")
                            if io_f then
                                local ok, content = pcall(function() return io_f:read("*a") end)
                                io_f:close()
                                if ok and content and #content > 0 then
                                    for l in content:gmatch("[^\r\n]+") do
                                        local k, v = l:match("^(%S+):%s*(%d+)")
                                        if k == "read_bytes" then
                                            io_read_bytes = tonumber(v) or 0
                                        elseif k == "write_bytes" then
                                            io_write_bytes = tonumber(v) or 0
                                        end
                                    end

                                    local pio = prev_proc_io[pid]
                                    if pio and pio.clock > 0 then
                                        local dt = now_clock - pio.clock
                                        if dt > 0 then
                                            local dr = io_read_bytes - pio.r
                                            local dw = io_write_bytes - pio.w
                                            if dr >= 0 then io_read_rate = dr / dt end
                                            if dw >= 0 then io_write_rate = dw / dt end
                                        end
                                    end
                                    prev_proc_io[pid] = { r = io_read_bytes, w = io_write_bytes, clock = now_clock }
                                end
                            end

                            table.insert(procs, {
                                pid = pid,
                                ppid = ppid,
                                comm = comm,
                                cmdline = cmdline,
                                state = state,
                                nice = nice,
                                threads = threads,
                                cpu_pct = cpu_pct,
                                mem_pct = mem_pct,
                                res_kb = res_kb,
                                vsize_kb = math.floor(vsize / 1024),
                                uid = uid,
                                username = username,
                                io_read_bytes = io_read_bytes,
                                io_write_bytes = io_write_bytes,
                                io_read_rate = io_read_rate,
                                io_write_rate = io_write_rate,
                                io_total_rate = io_read_rate + io_write_rate,
                            })
                        end
                    end
                end
            end
        end
        ffi.C.closedir(d)
        return procs
    end

    terminate_process = function(pid)
        ffi.C.kill(pid, 15)
    end

    kill_process = function(pid)
        ffi.C.kill(pid, 9)
    end

    send_signal_to_process = function(pid, sig)
        ffi.C.kill(pid, sig)
    end
end

-- =========================================================================
-- 5. Process Tree Construction Engine
-- =========================================================================
local function build_process_tree(procs, sort_mode, sort_reverse, collapsed_pids)
    collapsed_pids = collapsed_pids or {}
    local by_pid = {}
    local children = {}
    local roots = {}

    for _, p in ipairs(procs) do
        by_pid[p.pid] = p
        children[p.pid] = {}
        p.tree_prefix = ""
        p.tree_depth = 0
        p.has_children = false
        p.is_collapsed = false
        p.child_count = 0
        p.total_sub_cpu = p.cpu_pct or 0
        p.total_sub_res = p.res_kb or 0
    end

    for _, p in ipairs(procs) do
        if p.ppid and p.ppid ~= p.pid and by_pid[p.ppid] then
            table.insert(children[p.ppid], p)
            by_pid[p.ppid].has_children = true
        else
            table.insert(roots, p)
        end
    end

    -- Precompute subtree metrics (recursive child counts, CPU, Memory)
    local function compute_subtotals(p)
        local kids = children[p.pid] or {}
        local count = #kids
        local sub_cpu = p.cpu_pct or 0
        local sub_res = p.res_kb or 0
        for _, kid in ipairs(kids) do
            local k_count, k_cpu, k_res = compute_subtotals(kid)
            count = count + k_count
            sub_cpu = sub_cpu + k_cpu
            sub_res = sub_res + k_res
        end
        p.child_count = count
        p.total_sub_cpu = sub_cpu
        p.total_sub_res = sub_res
        return count, sub_cpu, sub_res
    end

    for _, r in ipairs(roots) do
        compute_subtotals(r)
    end

    local comparator = function(a, b)
        local val_a, val_b
        if sort_mode == "cpu" then
            val_a, val_b = a.cpu_pct, b.cpu_pct
        elseif sort_mode == "mem" then
            val_a, val_b = a.res_kb, b.res_kb
        elseif sort_mode == "pid" then
            val_a, val_b = a.pid, b.pid
        elseif sort_mode == "name" then
            val_a, val_b = a.comm:lower(), b.comm:lower()
        elseif sort_mode == "user" then
            val_a, val_b = a.username:lower(), b.username:lower()
        elseif sort_mode == "threads" then
            val_a, val_b = a.threads, b.threads
        elseif sort_mode == "io" or sort_mode == "disk" then
            val_a, val_b = (a.io_total_rate or 0), (b.io_total_rate or 0)
        elseif sort_mode == "ior" then
            val_a, val_b = (a.io_read_rate or 0), (b.io_read_rate or 0)
        elseif sort_mode == "iow" then
            val_a, val_b = (a.io_write_rate or 0), (b.io_write_rate or 0)
        else
            val_a, val_b = a.cpu_pct, b.cpu_pct
        end

        if val_a ~= val_b then
            if sort_reverse then return val_a < val_b else return val_a > val_b end
        end
        return a.pid < b.pid
    end

    table.sort(roots, comparator)

    local ordered = {}
    local visited = {}

    local function traverse(node, depth, prefix)
        if visited[node.pid] then return end
        visited[node.pid] = true

        node.tree_depth = depth
        node.tree_prefix = prefix
        node.is_collapsed = (collapsed_pids[node.pid] == true)
        table.insert(ordered, node)

        -- If node is collapsed, skip traversing its children
        if node.is_collapsed then
            return
        end

        local kids = children[node.pid] or {}
        table.sort(kids, comparator)

        for i, kid in ipairs(kids) do
            local is_last = (i == #kids)
            local branch = is_last and "└─ " or "├─ "
            local next_indent = prefix:gsub("└─ ", "   "):gsub("├─ ", "│  ")
            traverse(kid, depth + 1, next_indent .. branch)
        end
    end

    for _, r in ipairs(roots) do
        traverse(r, 0, "")
    end

    return ordered
end

-- =========================================================================
-- 6. TUI Layout & Drawing Engine
-- =========================================================================
local function draw_box_row(x, y, w, text)
    local clr = truncate(text, w - 2)
    local vlen = visual_len(clr)
    local pad = string.rep(" ", math.max(0, w - 2 - vlen))
    return string.format("\27[%d;%dH%s%s", y, x + 1, clr, pad)
end

local function draw_pane(out, x, y, w, h, title, is_focused, header_right)
    local bcol = is_focused and C.border_focus or C.border_col
    local title_str = title and string.format(" %s%s%s ", C.title_col, title, bcol) or ""
    local r_str = header_right and string.format(" %s%s%s ", C.dim, header_right, bcol) or ""

    local t_len = title and (visual_len(title) + 2) or 0
    local r_len = header_right and (visual_len(header_right) + 2) or 0
    local top_fill = string.rep("─", math.max(0, w - 2 - t_len - r_len))

    table.insert(out, string.format("\27[%d;%dH%s╭%s%s%s%s╮%s", y, x, bcol, title_str, top_fill, r_str, bcol, C.reset))
    for i = 1, h - 2 do
        table.insert(out, string.format("\27[%d;%dH%s│\27[%d;%dH│%s", y + i, x, bcol, y + i, x + w - 1, C.reset))
    end
    local bot_fill = string.rep("─", math.max(0, w - 2))
    table.insert(out, string.format("\27[%d;%dH%s╰%s╯%s", y + h - 1, x, bcol, bot_fill, C.reset))
end

local function draw_modal_box(out, x, y, w, h, title)
    local bcol = C.border_focus
    local bg = C.modal_bg or "\27[48;2;26;27;38m"
    local title_str = string.format(" %s%s%s ", C.title_col, title, bcol)
    local t_len = visual_len(title) + 2
    local top_fill = string.rep("─", math.max(0, w - 2 - t_len))

    table.insert(out, string.format("\27[%d;%dH%s%s╭%s%s╮%s", y, x, bg, bcol, title_str, top_fill, C.reset))
    for i = 1, h - 2 do
        local pad = string.rep(" ", w - 2)
        table.insert(out, string.format("\27[%d;%dH%s%s│%s│%s", y + i, x, bg, bcol, pad, C.reset))
    end
    local bot_fill = string.rep("─", math.max(0, w - 2))
    table.insert(out, string.format("\27[%d;%dH%s%s╰%s╯%s", y + h - 1, x, bg, bcol, bot_fill, C.reset))
end

-- =========================================================================
-- 7. Signals & Modal Subsystems
-- =========================================================================
local SIGNALS = {
    { sig = 15, name = "SIGTERM", desc = "Graceful termination request (Recommended)" },
    { sig = 9,  name = "SIGKILL", desc = "Immediate forced kill (Uncatchable)" },
    { sig = 1,  name = "SIGHUP",  desc = "Hangup / reload configuration" },
    { sig = 2,  name = "SIGINT",  desc = "Terminal interrupt (Equivalent to Ctrl+C)" },
    { sig = 19, name = "SIGSTOP", desc = "Pause / freeze process execution" },
    { sig = 18, name = "SIGCONT", desc = "Resume paused process execution" },
}

-- =========================================================================
-- 8. Main Interactive Application Loop
-- =========================================================================
local function main(args)
    args = args or {}
    local arg_interval = nil
    local arg_theme = nil
    local arg_tree = false

    for i, a in ipairs(args) do
        if a == "--help" or a == "-h" then
            print([[
btop_lite.lua - High-Performance Linux & Windows System Monitor
Usage:
  luajit btop_lite.lua [options]

Options:
  -h, --help            Show this help dialog and exit
  -v, --version         Print version information and exit
  --test                Run headless self-test suite and exit
  --interval <ms>       Update interval in milliseconds (default: 1000)
  --theme <name>        Select color theme: tokyo_night, dracula, nord, monokai, cyberpunk
  --tree                Start in Process Tree mode by default

Keybindings:
  ↑/↓, k/j              Navigate selected process or modal list
  PgUp/PgDn, Home/End   Quick scroll process list
  /                     Instant in-place search / filter
  t, F5                 Toggle Process Tree mode vs Flat list
  Enter, i              Inspect selected process details
  k                     Open safe signal dispatcher modal
  c, m, p, n, u, s      Sort by CPU, Mem, PID, Name, User, Threads
  r                     Toggle sort order (Ascending / Descending)
  T                     Cycle color themes on the fly
  Space                 Pause / resume live monitoring
  +, -                  Adjust update interval
  ?, h                  Display interactive help dialog
  q, Esc                Quit / Close modal
]])
            return 0
        elseif a == "--version" or a == "-v" then
            print("btop_lite.lua v2.1.0 (Professional Edition) - LuaJIT FFI System Monitor")
            return 0
        elseif a == "--interval" and args[i + 1] then
            arg_interval = tonumber(args[i + 1])
        elseif a == "--theme" and args[i + 1] then
            arg_theme = args[i + 1]
        elseif a == "--tree" then
            arg_tree = true
        end
    end

    if arg_theme then set_theme(arg_theme) end

    enable_raw_mode()

    local sort_mode = "cpu" -- "cpu", "mem", "pid", "name", "user", "threads"
    local sort_reverse = false
    local in_tree_mode = arg_tree
    local sel_proc = 1
    local filter_query = ""
    local in_search_mode = false
    local is_paused = false
    local refresh_interval_ms = arg_interval or 1000
    local collapsed_pids = {}
    local sync_updates = not is_windows or os.getenv("WT_SESSION") ~= nil or os.getenv("TERM_PROGRAM") == "vscode"

    -- Modals state
    local show_help = false
    local show_inspector = false
    local show_signal_modal = false
    local sel_signal_idx = 1
    local status_flash_msg = ""
    local status_flash_expiry = 0

    local last_w, last_h = get_terminal_size()
    local cpu_history = {}
    local mem_history = {}
    local rx_history = {}
    local tx_history = {}
    local max_history = 35

    io.write("\27[H\27[2J")
    io.flush()

    local next_refresh_time = 0
    local procs = {}

    while true do
        local now_clock = os.clock()
        local term_w, term_h = get_terminal_size()
        local needs_redraw = false

        if term_w ~= last_w or term_h ~= last_h then
            last_w, last_h = term_w, term_h
            needs_redraw = true
            io.write("\27[H\27[2J")
        end

        -- Poll keyboard input
        local k = read_key(60)

        if k then
            needs_redraw = true

            if show_help then
                if k == "ESC" or k == "ENTER" or k == "q" or k == "?" or k == "h" then
                    show_help = false
                end
            elseif show_inspector then
                if k == "ESC" or k == "ENTER" or k == "q" or k == "i" then
                    show_inspector = false
                elseif k == "k" then
                    show_inspector = false
                    show_signal_modal = true
                    sel_signal_idx = 1
                end
            elseif show_signal_modal then
                if k == "ESC" or k == "q" then
                    show_signal_modal = false
                elseif k == "UP" or k == "k" then
                    sel_signal_idx = math.max(1, sel_signal_idx - 1)
                elseif k == "DOWN" or k == "j" then
                    sel_signal_idx = math.min(#SIGNALS, sel_signal_idx + 1)
                elseif k == "ENTER" then
                    -- Dispatch signal
                    -- Will be executed during frame logic with selected process
                    show_signal_modal = false
                    local sig_info = SIGNALS[sel_signal_idx]
                    status_flash_msg = string.format("Dispatched %s (%d)", sig_info.name, sig_info.sig)
                    status_flash_expiry = os.clock() + 3.0
                    -- Flag to execute kill
                    k = "__SEND_SIGNAL__"
                end
            elseif in_search_mode then
                if k == "ENTER" or k == "ESC" then
                    in_search_mode = false
                elseif k == "BACKSPACE" then
                    filter_query = filter_query:sub(1, -2)
                    sel_proc = 1
                elseif #k == 1 and k:byte() >= 32 and k:byte() <= 126 then
                    filter_query = filter_query .. k
                    sel_proc = 1
                elseif k == "UP" or k == "DOWN" or k == "PAGE_UP" or k == "PAGE_DOWN" then
                    if k == "UP" then sel_proc = math.max(1, sel_proc - 1) end
                    if k == "DOWN" then sel_proc = sel_proc + 1 end
                    if k == "PAGE_UP" then sel_proc = math.max(1, sel_proc - 15) end
                    if k == "PAGE_DOWN" then sel_proc = sel_proc + 15 end
                end
            else
                -- Normal mode keybindings
                if k == "q" then
                    if #filter_query > 0 then
                        filter_query = ""
                    else
                        break
                    end
                elseif k == "ESC" then
                    if #filter_query > 0 then filter_query = "" end
                elseif k == "DOWN" or k == "j" then
                    sel_proc = sel_proc + 1
                elseif k == "UP" or k == "k" then
                    sel_proc = math.max(1, sel_proc - 1)
                elseif k == "PAGE_DOWN" then
                    sel_proc = sel_proc + 15
                elseif k == "PAGE_UP" then
                    sel_proc = math.max(1, sel_proc - 15)
                elseif k == "HOME" or k == "g" then
                    sel_proc = 1
                elseif k == "END" or k == "G" then
                    sel_proc = 999999
                elseif k == "SPACE" or k == "TAB" then
                    if in_tree_mode and procs[sel_proc] and procs[sel_proc].has_children then
                        local p = procs[sel_proc]
                        if collapsed_pids[p.pid] then
                            collapsed_pids[p.pid] = nil
                            status_flash_msg = string.format("Expanded %s (PID %d)", p.comm, p.pid)
                        else
                            collapsed_pids[p.pid] = true
                            status_flash_msg = string.format("Folded %s (%d sub-processes)", p.comm, p.child_count or 0)
                        end
                        status_flash_expiry = os.clock() + 2.0
                    else
                        is_paused = not is_paused
                    end
                elseif k == "/" then
                    in_search_mode = true
                elseif k == "t" or k == "F5" then
                    in_tree_mode = not in_tree_mode
                    sel_proc = 1
                elseif k == "c" then
                    sort_mode = "cpu"
                elseif k == "m" then
                    sort_mode = "mem"
                elseif k == "p" then
                    sort_mode = "pid"
                elseif k == "n" then
                    sort_mode = "name"
                elseif k == "u" then
                    sort_mode = "user"
                elseif k == "s" then
                    sort_mode = "threads"
                elseif k == "d" then
                    sort_mode = "io"
                elseif k == "r" then
                    sort_reverse = not sort_reverse
                elseif k == "T" then
                    cycle_theme()
                elseif k == "?" or k == "h" then
                    show_help = true
                elseif k == "ENTER" or k == "i" then
                    show_inspector = true
                elseif k == "k" then
                    show_signal_modal = true
                    sel_signal_idx = 1
                elseif k == "+" or k == "=" then
                    refresh_interval_ms = math.max(250, refresh_interval_ms - 250)
                elseif k == "-" then
                    refresh_interval_ms = math.min(5000, refresh_interval_ms + 250)
                end
            end
        end

        local curr_clock = os.clock()
        if (curr_clock >= next_refresh_time and not is_paused) or needs_redraw then
            next_refresh_time = curr_clock + (refresh_interval_ms / 1000.0)

            -- 1. Gather Telemetry
            local cores, overall_cpu = read_cpu_stats()
            local temp_c, freq_ghz = read_cpu_sensors()
            local mem = read_memory_stats()
            local net = read_network_stats(curr_clock)
            local storage = read_storage_stats(curr_clock)
            local procs = read_process_table(mem.total_kb or 1, curr_clock)
            local load_str, task_str = read_loadavg(overall_cpu, #procs)

            -- Sparklines history
            table.insert(cpu_history, overall_cpu)
            if #cpu_history > max_history then table.remove(cpu_history, 1) end

            table.insert(mem_history, mem.used_pct)
            if #mem_history > max_history then table.remove(mem_history, 1) end

            table.insert(rx_history, net.rx_rate)
            if #rx_history > max_history then table.remove(rx_history, 1) end

            table.insert(tx_history, net.tx_rate)
            if #tx_history > max_history then table.remove(tx_history, 1) end

            -- Detect zombie processes
            local zombie_count = 0
            for _, pr in ipairs(procs) do
                if pr.state == "Z" then zombie_count = zombie_count + 1 end
            end

            -- Filter processes
            if #filter_query > 0 then
                local fq = filter_query:lower()
                local filtered = {}
                for _, pr in ipairs(procs) do
                    if pr.comm:lower():find(fq, 1, true) or
                       pr.cmdline:lower():find(fq, 1, true) or
                       pr.username:lower():find(fq, 1, true) or
                       tostring(pr.pid):find(fq, 1, true) then
                        table.insert(filtered, pr)
                    end
                end
                procs = filtered
            end

            -- Process Tree or Flat sort
            if in_tree_mode then
                procs = build_process_tree(procs, sort_mode, sort_reverse, collapsed_pids)
            else
                local comparator = function(a, b)
                    local val_a, val_b
                    if sort_mode == "cpu" then val_a, val_b = a.cpu_pct, b.cpu_pct
                    elseif sort_mode == "mem" then val_a, val_b = a.res_kb, b.res_kb
                    elseif sort_mode == "pid" then val_a, val_b = a.pid, b.pid
                    elseif sort_mode == "name" then val_a, val_b = a.comm:lower(), b.comm:lower()
                    elseif sort_mode == "user" then val_a, val_b = a.username:lower(), b.username:lower()
                    elseif sort_mode == "threads" then val_a, val_b = a.threads, b.threads
                    elseif sort_mode == "io" or sort_mode == "disk" then val_a, val_b = (a.io_total_rate or 0), (b.io_total_rate or 0)
                    elseif sort_mode == "ior" then val_a, val_b = (a.io_read_rate or 0), (b.io_read_rate or 0)
                    elseif sort_mode == "iow" then val_a, val_b = (a.io_write_rate or 0), (b.io_write_rate or 0)
                    else val_a, val_b = a.cpu_pct, b.cpu_pct end

                    if val_a ~= val_b then
                        if sort_reverse then return val_a < val_b else return val_a > val_b end
                    end
                    return a.pid < b.pid
                end
                table.sort(procs, comparator)
            end

            sel_proc = math.max(1, math.min(sel_proc, math.max(1, #procs)))

            -- Execute signal if requested
            if k == "__SEND_SIGNAL__" and procs[sel_proc] then
                local target = procs[sel_proc]
                local sig = SIGNALS[sel_signal_idx].sig
                send_signal_to_process(target.pid, sig)
                status_flash_msg = string.format("Sent %s (%d) to PID %d (%s)",
                    SIGNALS[sel_signal_idx].name, sig, target.pid, target.comm)
                status_flash_expiry = os.clock() + 3.0
            end

            -- =================================================================
            -- Render Frame
            -- =================================================================
            local out = {}
            table.insert(out, "\27[H")

            -- Top Banner
            local pause_ind = is_paused and "\27[1;38;2;239;68;68m [PAUSED]\27[0m" or ""
            local freq_str = freq_ghz and string.format(" │ CPU: \27[1;97m%.2f GHz\27[0m", freq_ghz) or ""
            local temp_str = temp_c and string.format(" (\27[1;38;2;251;191;36m%.0f°C\27[0m)", temp_c) or ""
            local theme_ind = string.format(" │ Theme: \27[38;2;125;207;255m%s\27[0m", C.name)
            local zombie_str = zombie_count > 0 and string.format(" │ \27[1;38;2;247;118;142m⚠ %d ZOMBIE%s\27[0m", zombie_count, zombie_count > 1 and "S" or "") or ""

            local header_str = string.format("  \27[1;38;2;56;189;248m⚡ BTOP-PRO v2.1\27[0m \27[90m│\27[0m Load: \27[1;97m%s\27[0m \27[90m│\27[0m Tasks: \27[1;97m%s\27[0m%s%s%s%s \27[90m│\27[0m \27[1;93m%.1fs\27[0m%s\27[K",
                load_str, task_str, zombie_str, freq_str, temp_str, theme_ind, refresh_interval_ms / 1000.0, pause_ind)
            table.insert(out, header_str .. "\n")

            -- Layout calculations
            local top_h = math.min(12, math.max(8, math.floor(term_h * 0.32)))
            local net_h = 3
            local bot_h = term_h - top_h - net_h - 2

            local left_w = math.floor(term_w * 0.50)
            local right_w = term_w - left_w

            -- 1. CPU Pane (Top Left)
            local cpu_title = string.format("CPU: %.1f%%", overall_cpu)
            local cpu_spark = make_sparkline(cpu_history, math.max(10, left_w - 20), C.cpu_low)
            draw_pane(out, 1, 2, left_w, top_h, cpu_title, false, "Usage: " .. cpu_spark)

            -- Dynamic core columns based on left_w and core count
            local avail_rows = top_h - 3
            local num_cols = 2
            if #cores > avail_rows * 2 and left_w >= 60 then
                num_cols = (left_w >= 90 and #cores > avail_rows * 3) and 4 or 3
            end
            local col_sub_w = math.floor((left_w - 4 - num_cols) / num_cols)

            for i = 1, avail_rows do
                local line_parts = {}
                for col = 1, num_cols do
                    local c_idx = (i - 1) * num_cols + col
                    local c = cores[c_idx]
                    if c then
                        local bar_w = math.max(3, col_sub_w - 11)
                        local mbar = make_meter_bar(c.pct, bar_w)
                        local sep = (col > 1) and " " or ""
                        table.insert(line_parts, string.format("%s%s%2d%s %s%4.0f%%%s", sep, C.dim, c_idx - 1, C.reset, mbar, c.pct, C.reset))
                    end
                end
                table.insert(out, draw_box_row(1, 2 + i, left_w, table.concat(line_parts)))
            end

            -- 2. Memory, Swap & Storage Pane (Top Right)
            local mem_spark = make_sparkline(mem_history, math.max(8, right_w - 26), C.mem_used)
            draw_pane(out, left_w + 1, 2, right_w, top_h, "Memory & Storage", false, "Trend: " .. mem_spark)
            local mem_bar = make_meter_bar(mem.used_pct, right_w - 24, C.mem_used)
            local swap_bar = make_meter_bar(mem.swap_pct, right_w - 24, C.mem_swap)

            table.insert(out, draw_box_row(left_w + 1, 3, right_w,
                string.format("%sRAM %s %s%5.1f%%%s %s/%s",
                    C.bold, C.reset, mem_bar, mem.used_pct, C.reset,
                    format_bytes(mem.used_kb), format_bytes(mem.total_kb))))

            table.insert(out, draw_box_row(left_w + 1, 4, right_w,
                string.format("  %sFree: %s%s │ %sCached: %s%s │ %sAvail: %s%s",
                    C.dim, format_bytes(mem.total_kb - mem.used_kb), C.reset,
                    C.dim, format_bytes(mem.cached_kb), C.reset,
                    C.dim, format_bytes(mem.avail_kb), C.reset)))

            table.insert(out, draw_box_row(left_w + 1, 5, right_w,
                string.format("%sSWP %s %s%5.1f%%%s %s/%s",
                    C.bold, C.reset, swap_bar, mem.swap_pct, C.reset,
                    format_bytes(mem.swap_used_kb), format_bytes(mem.swap_total_kb))))

            -- Storage Mounts & Disk I/O
            local row_y = 6
            for _, m in ipairs(storage.mounts) do
                if row_y >= top_h + 1 then break end
                local disk_bar = make_meter_bar(m.used_pct, right_w - 24)
                table.insert(out, draw_box_row(left_w + 1, row_y, right_w,
                    string.format("%s%-3s %s %s%5.1f%%%s %s/%s",
                        C.dim, m.mount, C.reset, disk_bar, m.used_pct, C.reset,
                        format_bytes(math.floor(m.used_bytes / 1024)), format_bytes(math.floor(m.total_bytes / 1024)))))
                row_y = row_y + 1
            end

            if row_y <= top_h then
                local io_str = string.format("  %sDisk I/O: %sRead %s%s │ %sWrite %s%s",
                    C.dim, C.disk_read, format_rate(storage.read_speed), C.reset,
                    C.disk_write, format_rate(storage.write_speed), C.reset)
                table.insert(out, draw_box_row(left_w + 1, row_y, right_w, io_str))
            end

            -- 3. Network I/O Pane (Middle)
            local net_y = top_h + 2
            local net_title = string.format("Network (%s)", net.active_iface)
            draw_pane(out, 1, net_y, term_w, net_h, net_title, false)

            local rx_spark = make_sparkline(rx_history, 15, C.net_rx)
            local tx_spark = make_sparkline(tx_history, 15, C.net_tx)
            local net_line = string.format("  %sRX:%s %s %s %sTotal: %s%s   │   %sTX:%s %s %s %sTotal: %s%s",
                C.bold, C.reset, format_rate(net.rx_rate), rx_spark, C.dim, format_bytes(math.floor(net.rx_total / 1024)), C.reset,
                C.bold, C.reset, format_rate(net.tx_rate), tx_spark, C.dim, format_bytes(math.floor(net.tx_total / 1024)), C.reset)
            table.insert(out, draw_box_row(1, net_y + 1, term_w, net_line))

            -- 4. Processes Table / Tree Pane (Bottom)
            local proc_y = net_y + net_h
            local dir_sym = sort_reverse and "▲" or "▼"
            local sort_tag = string.format("[Sort: %s%s]", sort_mode:upper(), dir_sym)
            local tree_tag = in_tree_mode and "[Tree: ON]" or "[Tree: OFF]"
            local filter_tag = #filter_query > 0 and string.format("[Filter: /%s]", filter_query) or ""
            local proc_title = string.format("Processes: %d %s %s %s", #procs, sort_tag, tree_tag, filter_tag)

            draw_pane(out, 1, proc_y, term_w, bot_h, proc_title, true)

            -- Columns: PID (7), USER (8), %CPU (7), %MEM (7), RES (9), TH (4), STAT (5), COMMAND (rest)
            local table_header_y = proc_y + 1
            local function col_hdr(name, mode_key, width)
                local is_active = (sort_mode == mode_key)
                local text = name
                if is_active then
                    text = text .. (sort_reverse and "▲" or "▼")
                end
                if is_active then
                    return string.format("%s%-" .. width .. "s%s", C.border_focus, text, C.table_hdr)
                else
                    return string.format("%-" .. width .. "s", text)
                end
            end

            local h_pid  = col_hdr("PID", "pid", 7)
            local h_user = col_hdr("USER", "user", 8)
            local h_cpu  = col_hdr("%CPU", "cpu", 7)
            local h_mem  = col_hdr("%MEM", "mem", 7)
            local h_res  = (sort_mode == "mem") and col_hdr("RES", "mem", 9) or string.format("%-9s", "RES")
            local h_th   = col_hdr("TH", "threads", 4)
            local h_stat = string.format("%-5s", "STAT")
            local h_cmd  = in_tree_mode and (C.title_col .. "PROCESS TREE [Space/Tab: Fold]" .. C.table_hdr) or col_hdr("COMMAND", "name", 15)

            local show_io_cols = (term_w >= 115)
            local io_hdr_str = ""
            if show_io_cols then
                local h_ior = col_hdr("DISK R", "ior", 9)
                local h_iow = col_hdr("DISK W", "iow", 9)
                io_hdr_str = string.format(" %s %s", h_ior, h_iow)
            end

            local th_str = string.format("  %s%s %s %s %s %s %s %s%s %s%s",
                C.table_hdr, h_pid, h_user, h_cpu, h_mem, h_res, h_th, h_stat, io_hdr_str, h_cmd, C.reset)
            table.insert(out, draw_box_row(1, table_header_y, term_w, th_str))

            local visible_rows = bot_h - 3
            local page_offset = 1
            if sel_proc > visible_rows then
                page_offset = sel_proc - visible_rows + 1
            end

            for i = 1, visible_rows do
                local p_idx = page_offset + i - 1
                local pr = procs[p_idx]
                if pr then
                    local is_sel = (p_idx == sel_proc)
                    local cpu_val = (in_tree_mode and pr.is_collapsed and pr.total_sub_cpu > pr.cpu_pct) and pr.total_sub_cpu or pr.cpu_pct
                    local res_val = (in_tree_mode and pr.is_collapsed and pr.total_sub_res > pr.res_kb) and pr.total_sub_res or pr.res_kb
                    local cpu_col = cpu_val > 50 and C.cpu_high or (cpu_val > 15 and C.cpu_mid or C.reset)
                    local user_str = truncate(pr.username or "user", 8)

                    local cmd_display
                    if in_tree_mode then
                        local fold_badge = ""
                        if pr.has_children then
                            fold_badge = pr.is_collapsed and string.format("\27[1;33m[+%d]\27[0m ", pr.child_count) or "\27[36m[-]\27[0m "
                        end
                        cmd_display = C.tree_branch .. pr.tree_prefix .. C.reset .. fold_badge .. pr.comm
                    else
                        cmd_display = pr.cmdline
                    end

                    local io_val_str = ""
                    if show_io_cols then
                        io_val_str = string.format(" %-9s %-9s", format_rate(pr.io_read_rate or 0), format_rate(pr.io_write_rate or 0))
                    end

                    local row_content = string.format("%-7d %-8s %s%5.1f%%%s %5.1f%% %-9s %-4d %-5s%s %s",
                        pr.pid, user_str, cpu_col, cpu_val, C.reset, pr.mem_pct, format_bytes(res_val), pr.threads or 1, pr.state, io_val_str, cmd_display)

                    if is_sel then
                        table.insert(out, draw_box_row(1, table_header_y + i, term_w, C.sel_bg .. "▶ " .. row_content .. C.reset))
                    else
                        table.insert(out, draw_box_row(1, table_header_y + i, term_w, "  " .. row_content))
                    end
                else
                    table.insert(out, draw_box_row(1, table_header_y + i, term_w, ""))
                end
            end

            -- 5. Modal Overlays (Inspector, Signal Modal, Help)
            if show_inspector and procs[sel_proc] then
                local pr = procs[sel_proc]
                local mw = math.min(74, term_w - 4)
                local mh = 16
                local mx = math.floor((term_w - mw) / 2)
                local my = math.floor((term_h - mh) / 2)
                draw_modal_box(out, mx, my, mw, mh, string.format("Process Inspector: PID %d", pr.pid))

                table.insert(out, draw_box_row(mx, my + 1, mw, string.format(" %sCommand:%s   %s", C.bold, C.reset, pr.cmdline)))
                table.insert(out, draw_box_row(mx, my + 2, mw, string.format(" %sBinary:%s    %s", C.bold, C.reset, pr.comm)))
                table.insert(out, draw_box_row(mx, my + 3, mw, string.format(" %sUser:%s      %s (UID: %d)", C.bold, C.reset, pr.username, pr.uid or 0)))
                table.insert(out, draw_box_row(mx, my + 4, mw, string.format(" %sState:%s     %s (Status Code)", C.bold, C.reset, pr.state)))
                table.insert(out, draw_box_row(mx, my + 5, mw, string.format(" %sPPID:%s      %-7d   %sThreads:%s  %d", C.bold, C.reset, pr.ppid or 0, C.bold, C.reset, pr.threads or 1)))
                table.insert(out, draw_box_row(mx, my + 6, mw, string.format(" %sCPU%%:%s     %-6.1f%%   %sMemory%%:%s %-6.1f%%", C.bold, C.reset, pr.cpu_pct, C.bold, C.reset, pr.mem_pct)))
                table.insert(out, draw_box_row(mx, my + 7, mw, string.format(" %sMemory:%s    RES: %s │ VIRT: %s", C.bold, C.reset, format_bytes(pr.res_kb), format_bytes(pr.vsize_kb or 0))))
                table.insert(out, draw_box_row(mx, my + 8, mw, string.format(" %sDisk I/O:%s  Read: %s (Tot: %s) │ Write: %s (Tot: %s)",
                    C.bold, C.reset,
                    format_rate(pr.io_read_rate or 0), format_bytes(math.floor((pr.io_read_bytes or 0) / 1024)),
                    format_rate(pr.io_write_rate or 0), format_bytes(math.floor((pr.io_write_bytes or 0) / 1024)))))
                table.insert(out, draw_box_row(mx, my + 9, mw, string.format(" %sNice:%s      %d", C.bold, C.reset, pr.nice or 0)))
                table.insert(out, draw_box_row(mx, my + 11, mw, string.format("  %s[k] Send Signal   [Enter / Esc] Close Inspector%s", C.title_col, C.reset)))
            elseif show_signal_modal and procs[sel_proc] then
                local pr = procs[sel_proc]
                local mw = math.min(68, term_w - 4)
                local mh = #SIGNALS + 6
                local mx = math.floor((term_w - mw) / 2)
                local my = math.floor((term_h - mh) / 2)
                draw_modal_box(out, mx, my, mw, mh, string.format("Dispatch Signal to PID %d (%s)", pr.pid, pr.comm))

                table.insert(out, draw_box_row(mx, my + 1, mw, " Select a POSIX signal to send:"))
                for s_i, s in ipairs(SIGNALS) do
                    local is_sel = (s_i == sel_signal_idx)
                    local line = string.format("   [%2d] %-8s - %s", s.sig, s.name, s.desc)
                    if is_sel then
                        table.insert(out, draw_box_row(mx, my + 2 + s_i, mw, C.sel_bg .. "▶" .. line:sub(2) .. C.reset))
                    else
                        table.insert(out, draw_box_row(mx, my + 2 + s_i, mw, line))
                    end
                end
                table.insert(out, draw_box_row(mx, my + mh - 2, mw, string.format("  %s[↑/↓] Select   [Enter] Send   [Esc] Cancel%s", C.dim, C.reset)))
            elseif show_help then
                local mw = math.min(72, term_w - 4)
                local mh = 16
                local mx = math.floor((term_w - mw) / 2)
                local my = math.floor((term_h - mh) / 2)
                draw_modal_box(out, mx, my, mw, mh, "Help & Keybindings")

                table.insert(out, draw_box_row(mx, my + 1, mw, string.format(" %sNavigation:%s", C.title_col, C.reset)))
                table.insert(out, draw_box_row(mx, my + 2, mw, "   ↑/↓, k/j       Select process / scroll rows"))
                table.insert(out, draw_box_row(mx, my + 3, mw, "   PgUp/PgDn      Jump 15 rows   Home/End Jump to ends"))
                table.insert(out, draw_box_row(mx, my + 4, mw, string.format(" %sProcess Controls:%s", C.title_col, C.reset)))
                table.insert(out, draw_box_row(mx, my + 5, mw, "   /              In-place search / filter"))
                table.insert(out, draw_box_row(mx, my + 6, mw, "   t, F5          Toggle Process Tree view"))
                table.insert(out, draw_box_row(mx, my + 7, mw, "   Enter, i       Inspect process details modal"))
                table.insert(out, draw_box_row(mx, my + 8, mw, "   k              Open signal dispatcher modal"))
                table.insert(out, draw_box_row(mx, my + 9, mw, string.format(" %sDisplay & Sorting:%s", C.title_col, C.reset)))
                table.insert(out, draw_box_row(mx, my + 10, mw, "   c, m, p, n     Sort by CPU, Memory, PID, or Name"))
                table.insert(out, draw_box_row(mx, my + 11, mw, "   u, s, d        Sort by User, Threads, Disk I/O"))
                table.insert(out, draw_box_row(mx, my + 12, mw, "   r              Reverse current sort order"))
                table.insert(out, draw_box_row(mx, my + 13, mw, "   T              Cycle color themes   Space Pause"))
                table.insert(out, draw_box_row(mx, my + 14, mw, string.format("  %s[Esc / Enter / ?] Close Help Dialog%s", C.dim, C.reset)))
            end

            -- 6. Footer Line & Search / Status
            local footer_y = term_h
            local footer_line = ""

            if in_search_mode then
                footer_line = string.format("\27[%d;1H\27[2K  \27[1;38;2;254;231;21mSearch: \27[0m\27[4m%s\27[0m\27[5m_\27[0m  \27[90m(Enter confirm, Esc cancel)\27[0m", filter_query)
            elseif os.clock() < status_flash_expiry and #status_flash_msg > 0 then
                footer_line = string.format("\27[%d;1H\27[2K  \27[1;38;2;34;197;94m✔ %s\27[0m", footer_y, status_flash_msg)
            else
                local f_status = #filter_query > 0 and string.format("\27[1;38;2;251;191;36mFilter: /%s\27[0m  ", filter_query) or ""
                local help_str = in_tree_mode
                    and "[/] Filter  [Space] Fold  [Enter] Inspect  [k] Kill  [c/m/p/n/u/s/d] Sort  [r] Rev  [T] Theme  [?] Help  [q] Quit"
                    or "[/] Filter  [t] Tree  [Enter] Inspect  [k] Kill  [c/m/p/n/u/s/d] Sort  [r] Rev  [T] Theme  [?] Help  [q] Quit"
                footer_line = string.format("\27[%d;1H\27[2K  %s%s%s", footer_y, f_status, C.dim, help_str)
            end
            table.insert(out, footer_line)

            local frame = table.concat(out)
            if sync_updates then
                io.write("\27[?2026h" .. frame .. "\27[?2026l")
            else
                io.write(frame)
            end
            io.flush()
        end
    end

    disable_raw_mode()
    print("\n\27[1;36mExited btop-pro cleanly. Goodbye!\27[0m")
    return 0
end

-- =========================================================================
-- 9. Self-Test Mode (Headless CI / Automated Verification)
-- =========================================================================
local function run_self_test()
    print("=== Running btop_lite.lua Headless Self-Test ===")

    local cores, cpu_pct = read_cpu_stats()
    assert(type(cores) == "table", "CPU cores should be a table")
    assert(cpu_pct >= 0 and cpu_pct <= 100, "CPU percent must be in [0, 100]")
    print(string.format("  ✔ CPU Telemetry: %d cores detected, usage: %.1f%%", #cores, cpu_pct))

    local mem = read_memory_stats()
    assert(mem.total_kb > 0, "Memory total should be > 0")
    assert(mem.used_pct >= 0 and mem.used_pct <= 100, "Memory percent in [0, 100]")
    print(string.format("  ✔ Memory Telemetry: Total=%s, Used=%s (%.1f%%)",
        format_bytes(mem.total_kb), format_bytes(mem.used_kb), mem.used_pct))

    local net = read_network_stats(os.clock())
    assert(type(net) == "table", "Network stats should be a table")
    assert(type(net.active_iface) == "string", "Active interface should be a string")
    print(string.format("  ✔ Network Telemetry: Active=%s, RX Total=%s", net.active_iface, format_bytes(math.floor(net.rx_total / 1024))))

    local storage = read_storage_stats(os.clock())
    assert(type(storage.mounts) == "table", "Mounts should be a table")
    print(string.format("  ✔ Storage Telemetry: %d mounted filesystems inspected", #storage.mounts))

    local procs = read_process_table(mem.total_kb or 1, os.clock())
    assert(#procs > 0, "Process table must contain at least 1 process")
    assert(procs[1].pid > 0, "Process PID must be > 0")
    assert(#procs[1].comm > 0, "Process comm must not be empty")
    assert(type(procs[1].username) == "string" and #procs[1].username > 0, "Username must be resolved")
    assert(type(procs[1].io_read_bytes) == "number", "Process IO read bytes should be a number")
    assert(type(procs[1].io_write_bytes) == "number", "Process IO write bytes should be a number")
    print(string.format("  ✔ Process Engine: %d processes parsed. Sample: PID %d (%s), User: %s, Disk I/O: R=%s W=%s",
        #procs, procs[1].pid, procs[1].comm, procs[1].username,
        format_bytes(math.floor(procs[1].io_read_bytes / 1024)), format_bytes(math.floor(procs[1].io_write_bytes / 1024))))

    local tree = build_process_tree(procs, "cpu", false)
    assert(#tree == #procs, "Tree must contain all processes")
    print(string.format("  ✔ Process Tree Engine: Hierarchical tree built successfully with %d nodes", #tree))

    -- Test tree folding on first process with children
    local parent_with_kids = nil
    for _, p in ipairs(tree) do
        if p.has_children and p.child_count > 0 then
            parent_with_kids = p
            break
        end
    end
    if parent_with_kids then
        local collapsed_tbl = { [parent_with_kids.pid] = true }
        local folded_tree = build_process_tree(procs, "cpu", false, collapsed_tbl)
        assert(#folded_tree < #tree, "Folded tree must have fewer visible nodes than expanded tree")
        local found_folded_node = false
        for _, p in ipairs(folded_tree) do
            if p.pid == parent_with_kids.pid then
                assert(p.is_collapsed == true, "Parent node must be marked is_collapsed")
                assert(p.total_sub_res >= p.res_kb, "Subtree memory rollup must be >= own memory")
                found_folded_node = true
                break
            end
        end
        assert(found_folded_node, "Folded parent node must be present in folded tree")
        print(string.format("  ✔ Tree Folding & Rollups: Folded PID %d (%s) reduced tree from %d to %d nodes",
            parent_with_kids.pid, parent_with_kids.comm, #tree, #folded_tree))
    end

    -- Sensors test
    local temp_c, freq_ghz = read_cpu_sensors()
    if temp_c then
        print(string.format("  ✔ CPU Sensors: Package temp detected: %.1f°C", temp_c))
    end
    if freq_ghz then
        print(string.format("  ✔ CPU Scaling: Current frequency detected: %.2f GHz", freq_ghz))
    end

    -- Theme test
    for _, tname in ipairs(theme_order) do
        assert(set_theme(tname) == true, "Setting theme " .. tname .. " should succeed")
    end
    print(string.format("  ✔ Theme Engine: Verified all %d theme presets", #theme_order))

    -- Formatters test
    assert(visual_len("\27[31mhello\27[0m") == 5, "visual_len should strip ANSI")
    assert(truncate("hello world", 8) == "hello...", "truncate should truncate to max_w")
    print("  ✔ Visual Utilities: visual_len and truncate verified")

    print("\n\27[1;32mALL SELF-TEST CHECKS PASSED SUCCESSFULLY!\27[0m")
    return true
end

-- =========================================================================
-- 10. Module Export & CLI Entry Point
-- =========================================================================
local M = {
    version            = "2.1.0",
    read_cpu_stats     = read_cpu_stats,
    read_cpu_sensors   = read_cpu_sensors,
    read_memory_stats  = read_memory_stats,
    read_network_stats = read_network_stats,
    read_storage_stats = read_storage_stats,
    read_process_table = read_process_table,
    build_process_tree = build_process_tree,
    resolve_username   = resolve_username,
    set_theme          = set_theme,
    cycle_theme        = cycle_theme,
    get_themes         = function() return THEMES end,
    format_bytes       = format_bytes,
    format_rate        = format_rate,
    visual_len         = visual_len,
    truncate           = truncate,
    main               = main,
    run_self_test      = run_self_test,
}

local is_entry_point = false
if arg and arg[0] then
    local script_name = arg[0]:match("([^/\\]+)$")
    if script_name and (script_name == "btop_lite.lua" or script_name == "btop_lite") then
        is_entry_point = true
    end
end

if is_entry_point then
    for _, a in ipairs(arg or {}) do
        if a == "--test" then
            local ok = run_self_test()
            os.exit(ok and 0 or 1)
        end
    end
    local exit_code = main(arg)
    os.exit(exit_code or 0)
end

return M
