--[[
    luatop.lua
    A fast, beautiful, and real-time Linux & Windows System, Hardware, & Process Monitor
    written in LuaJIT with FFI.
    Inspired by btop, htop, and bottom.

    Features:
    - Zero-Fork Telemetry Engine via direct POSIX C I/O and LuaJIT FFI:
      * CPU: Per-core & overall usage, frequency scaling (GHz), thermal sensors (°C).
      * Memory & Swap: RAM used/free/cached/available breakdown + Swap meter + rolling sparklines.
      * Storage & Disk I/O: Filesystem capacity (statvfs) + real-time Read/Write disk throughput.
      * Network I/O: Real-time Download/Upload bandwidth + cumulative counters + sparklines.
      * Process Table: Zero-fork /proc parser with greedy comm matching, threads, and UID caching.
      * Disk I/O per process: Real-time delta rates via /proc/[pid]/io.
    - Professional TUI Architecture:
      * Responsive 4-Pane Grid Layout: CPU | Memory & Storage | Network I/O | Processes.
      * Process Tree Mode (t / F5): Subtree folding/unfolding [Space/Tab] & aggregate metric rollups.
      * Smart Search & Filter (/): Multi-tag filtering (u:<user>, s:<state>, cpu>X, m>XM, text).
      * Process Inspector Modal (Enter / i): Deep inspection of memory, cmdline, state, I/O rates.
      * Safe Signal Dispatcher Modal (k): Interactive signal picker (SIGTERM, SIGKILL, SIGHUP, etc.).
      * Process Renice Modal (R): Interactive priority adjustment (-20 to 19) via POSIX setpriority.
      * Full SGR Mouse Support: Header click-to-sort, row click-to-select, wheel scroll.
      * Multiple Color Themes (T): Tokyo Night, Dracula, Nord, Monokai, Cyberpunk.
    - Dual-Mode Executable & Library:
      * Run directly as CLI tool: luajit luatop.lua [--test] [--theme <name>] [--interval <ms>] [--tree]
      * Reusable module: local luatop = require("luatop")
]]

local ffi = require("ffi")
local bit = require("bit")

local is_windows = (ffi.os == "Windows")

local enable_raw_mode, disable_raw_mode, suspend_raw_mode, resume_raw_mode, get_terminal_size, read_key
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
        int FlushConsoleInputBuffer(HANDLE hConsoleInput);
        void Sleep(uint32_t dwMilliseconds);
        int _kbhit(void);
        int _getch(void);

        typedef struct _FILETIME { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } FILETIME;
        int GetSystemTimes(FILETIME *lpIdleTime, FILETIME *lpKernelTime, FILETIME *lpUserTime);
        void GetSystemTimeAsFileTime(FILETIME *lpSystemTimeAsFileTime);

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
        int ProcessIdToSessionId(uint32_t dwProcessId, uint32_t *pSessionId);

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
        uint32_t GetLogicalDriveStringsA(uint32_t nBufferLength, char *lpBuffer);
        uint32_t GetDriveTypeA(const char *lpRootPathName);

        typedef struct _OSVERSIONINFOW {
            uint32_t dwOSVersionInfoSize;
            uint32_t dwMajorVersion;
            uint32_t dwMinorVersion;
            uint32_t dwBuildNumber;
            uint32_t dwPlatformId;
            uint16_t szCSDVersion[128];
        } OSVERSIONINFOW;
        void RtlGetVersion(OSVERSIONINFOW *lpVersionInformation);

        typedef void *HKEY;
        typedef unsigned long DWORD;
        typedef unsigned char BYTE;
        long RegOpenKeyExA(HKEY hKey, const char *lpSubKey, DWORD ulOptions, DWORD samDesired, HKEY *phkResult);
        long RegQueryValueExA(HKEY hKey, const char *lpValueName, DWORD *lpReserved, DWORD *lpType, BYTE *lpData, DWORD *lpcbData);
        long RegCloseKey(HKEY hKey);
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
        local raw_out = bit.bor(orig_out_mode[0], 0x0004) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
        raw_out = bit.bor(raw_out, 0x0008)                -- DISABLE_NEWLINE_AUTO_RETURN
        raw_out = bit.band(raw_out, bit.bnot(0x0002))     -- Clear ENABLE_WRAP_AT_EOL_OUTPUT
        kernel32.SetConsoleMode(hOut, raw_out)
        local raw_mode = bit.band(orig_in_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
        raw_mode = bit.bor(raw_mode, 0x0200)
        kernel32.SetConsoleMode(hIn, raw_mode)
        in_raw_mode = true
        io.write("\27[?1049h\27[?25l\27[?7l\27[?1000h\27[?1006h")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?1006l\27[?1000l\27[?7h\27[?1049l\27[?25h\27[0m")
            io.flush()
            local hIn = kernel32.GetStdHandle(0xFFFFFFF6)
            local hOut = kernel32.GetStdHandle(0xFFFFFFF5)
            if orig_in_mode[0] ~= 0 then kernel32.SetConsoleMode(hIn, orig_in_mode[0]) end
            if orig_out_mode[0] ~= 0 then kernel32.SetConsoleMode(hOut, orig_out_mode[0]) end
            in_raw_mode = false
        end
    end

    suspend_raw_mode = function()
        if in_raw_mode then
            local hIn = kernel32.GetStdHandle(0xFFFFFFF6)
            local hOut = kernel32.GetStdHandle(0xFFFFFFF5)
            if orig_in_mode[0] ~= 0 then kernel32.SetConsoleMode(hIn, orig_in_mode[0]) end
            if orig_out_mode[0] ~= 0 then kernel32.SetConsoleMode(hOut, orig_out_mode[0]) end
            pcall(function() kernel32.FlushConsoleInputBuffer(hIn) end)
            io.write("\27[?25h\27[?7h")
            io.flush()
        end
    end

    resume_raw_mode = function()
        if in_raw_mode then
            local hIn = kernel32.GetStdHandle(0xFFFFFFF6)
            local hOut = kernel32.GetStdHandle(0xFFFFFFF5)
            local raw_out = bit.bor(orig_out_mode[0], 0x0004) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
            raw_out = bit.bor(raw_out, 0x0008)                -- DISABLE_NEWLINE_AUTO_RETURN
            raw_out = bit.band(raw_out, bit.bnot(0x0002))     -- Clear ENABLE_WRAP_AT_EOL_OUTPUT
            kernel32.SetConsoleMode(hOut, raw_out)
            local raw_mode = bit.band(orig_in_mode[0], bit.bnot(0x0001 + 0x0002 + 0x0004))
            raw_mode = bit.bor(raw_mode, 0x0200)
            kernel32.SetConsoleMode(hIn, raw_mode)
            pcall(function() kernel32.FlushConsoleInputBuffer(hIn) end)
            io.write("\27[?25l\27[?7l")
            io.flush()
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
            elseif ch == "\t" then return "TAB"
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
                    elseif ch2 == 15 then return "SHIFT_TAB"
                    end
                elseif ch == 27 then return "ESC"
                elseif ch == 13 or ch == 10 then return "ENTER"
                elseif ch == 8 then return "BACKSPACE"
                elseif ch == 32 then return "SPACE"
                elseif ch == 9 then return "TAB"
                else return string.char(ch) end
            end
            kernel32.Sleep(10)
            elapsed = elapsed + 10
        end
        return nil
    end
else
    -- macOS/BSD declare tcflag_t/speed_t as 64-bit and set NCCS to 20, while Linux
-- uses 32-bit and NCCS=32.  Picking the wrong layout shifts every field offset
-- and makes tcgetattr overrun the LuaJIT buffer, so select it at cdef time.
-- On Linux the definition below passes through byte-for-byte unchanged.
local function posix_termios_cdef(def)
    if ffi.os == "OSX" or ffi.os == "BSD" then
        def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
        def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
        def = def:gsub("c_cc%[32%]", "c_cc[20]")
    end
    return def
end

ffi.cdef(posix_termios_cdef[[
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
        int tcflush(int fd, int queue_selector);

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

        struct timespec { long tv_sec; long tv_nsec; };
]])


    if ffi.arch == "arm" then
        ffi.cdef[[
            struct statvfs {
                unsigned long f_bsize;
                unsigned long f_frsize;
                unsigned long f_blocks;
                unsigned long f_bfree;
                unsigned long f_bavail;
                unsigned long f_files;
                unsigned long f_ffree;
                unsigned long f_favail;
                unsigned long f_fsid;
                int           __f_unused;
                unsigned long f_flag;
                unsigned long f_namemax;
                int           __f_spare[6];
            };

            struct stat {
                uint64_t st_dev;
                uint16_t __pad1;
                uint32_t st_ino;
                uint32_t st_mode;
                uint32_t st_nlink;
                uint32_t st_uid;
                uint32_t st_gid;
                uint64_t st_rdev;
                uint16_t __pad2;
                int32_t  st_size;
                int32_t  st_blksize;
                int32_t  st_blocks;
                struct timespec st_atim;
                struct timespec st_mtim;
                struct timespec st_ctim;
                uint32_t __glibc_reserved4;
                uint32_t __glibc_reserved5;
            };
        ]]
    else
        ffi.cdef[[
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
        ]]
    end

    ffi.cdef[[
        int statvfs(const char *path, struct statvfs *buf);
        int stat(const char *pathname, struct stat *statbuf);
        int __xstat(int ver, const char *pathname, struct stat *statbuf);

        typedef void (*sighandler_t)(int);
        sighandler_t signal(int signum, sighandler_t handler);

        int getpriority(int which, int who);
        int setpriority(int which, int who, int prio);
        int usleep(unsigned int usec);
    ]]

    local TIOCGWINSZ   = (ffi.os == "OSX" or ffi.os == "BSD") and 0x40087468 or 0x5413
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
            io.write("\27[?1006l\27[?1000l\27[?7h\27[?1049l\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            in_raw_mode = false
        end
    end

    suspend_raw_mode = function()
        if in_raw_mode then
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            pcall(function() ffi.C.tcflush(STDIN_FILENO, 0) end)
            io.write("\27[?25h\27[?7h")
            io.flush()
        end
    end

    resume_raw_mode = function()
        if in_raw_mode then
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
            pcall(function() ffi.C.tcflush(STDIN_FILENO, 0) end)
            io.write("\27[?25l\27[?7l")
            io.flush()
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
        io.write("\27[?1049h\27[?25l\27[?7l\27[?1000h\27[?1006h")
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
    local key_buf = ffi.new("char[64]")
    local function is_stdin_tty()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    read_key = function(timeout_ms)
        if not is_stdin_tty() then
            local ch = io.read(1)
            if not ch or ch == "" then return "q" end
            if ch == "\27" then return "ESC"
            elseif ch == "\n" or ch == "\r" then return "ENTER"
            elseif ch == " " then return "SPACE"
            elseif ch == "\t" then return "TAB"
            else return ch end
        end

        timeout_ms = timeout_ms or 50
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 and bit.band(pfd.revents, POLLIN) ~= 0 then
            local n = ffi.C.read(STDIN_FILENO, key_buf, 64)
            if n > 0 then
                local c0 = key_buf[0]
                if c0 == 27 then
                    if n >= 3 and key_buf[1] == 91 then
                        local c2 = key_buf[2]
                        if c2 == 60 and n >= 6 then -- SGR mouse sequence \27[<btn;x;yM/m
                            local s = ffi.string(key_buf, n)
                            local b, x, y, act = s:match("^\27%[<(%d+);(%d+);(%d+)([Mm])")
                            if b and x and y and act then
                                return {
                                    type = "mouse",
                                    btn = tonumber(b),
                                    x = tonumber(x),
                                    y = tonumber(y),
                                    release = (act == "m"),
                                }
                            end
                        end
                        if c2 == 65 then return "UP" end
                        if c2 == 66 then return "DOWN" end
                        if c2 == 67 then return "RIGHT" end
                        if c2 == 68 then return "LEFT" end
                        if c2 == 90 then return "SHIFT_TAB" end
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
                elseif c0 == 9 then
                    return "TAB"
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
        local mb = kb / 1024
        return mb >= 100 and string.format("%.0f M", mb) or string.format("%.1f M", mb)
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

local function format_elapsed(sec)
    if not sec or sec <= 0 then return "00:00:00" end
    sec = math.floor(sec)
    local s = sec % 60
    local m = math.floor(sec / 60) % 60
    local h = math.floor(sec / 3600) % 24
    local d = math.floor(sec / 86400)
    if d > 0 then
        if d >= 100 then
            return string.format("%dd %02dh", d, h)
        else
            return string.format("%2dd %02d:%02d", d, h, m)
        end
    else
        return string.format("%02d:%02d:%02d", h, m, s)
    end
end

local function format_cpu_time(sec)
    if not sec or sec <= 0 then return "00:00.00" end
    local total_cs = math.floor(sec * 100 + 0.5)
    local cs = total_cs % 100
    local total_s = math.floor(total_cs / 100)
    local s = total_s % 60
    local m = math.floor(total_s / 60) % 60
    local h = math.floor(total_s / 3600)
    if h > 0 then
        return string.format("%02d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d.%02d", m, s, cs)
    end
end

local function format_time_plus(sec)
    if not sec or sec <= 0 then return "  0:00.00" end
    local total_cs = math.floor(sec * 100 + 0.5)
    local cs = total_cs % 100
    local total_s = math.floor(total_cs / 100)
    local s = total_s % 60
    local total_m = math.floor(total_s / 60)
    local m = total_m % 60
    local h = math.floor(total_m / 60)
    if h > 0 then
        return string.format("%3d:%02d:%02d", h, m, s)
    else
        return string.format("%3d:%02d.%02d", m, s, cs)
    end
end

local function make_meter_bar(pct, width, col_override)
    width = math.max(2, width or 10)
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

-- Process State Badges (● R, ○ S, ■ D, ▲ Z, ❚ T, · I)
local STATE_BADGES = {
    R = { sym = "●", char = "R", name = "Running" },
    S = { sym = "○", char = "S", name = "Sleeping" },
    D = { sym = "■", char = "D", name = "Disk Sleep" },
    Z = { sym = "▲", char = "Z", name = "Zombie" },
    T = { sym = "❚", char = "T", name = "Stopped" },
    t = { sym = "❚", char = "t", name = "Tracing Stop" },
    I = { sym = "·", char = "I", name = "Idle" },
}

local function get_state_badge(state_char, is_sel, theme)
    local t = theme or C
    local st = tostring(state_char or "S"):sub(1, 1)
    local def = STATE_BADGES[st] or { sym = "?", char = st, name = "Unknown" }

    local col = t.dim
    if st == "R" then
        col = t.cpu_low or "\27[38;2;158;206;106m"
    elseif st == "D" then
        col = t.cpu_mid or "\27[38;2;224;175;104m"
    elseif st == "Z" then
        col = t.cpu_high or "\27[1;38;2;247;118;142m"
    elseif st == "T" or st == "t" then
        col = t.net_rx or "\27[38;2;125;207;255m"
    elseif st == "S" or st == "I" then
        col = t.dim or "\27[2m"
    end

    local reset_code = is_sel and (t.sel_bg or "") or (t.reset or "\27[0m")
    -- Format: symbol (1 col) + space (1 col) + char (1 col) + 2 spaces = exactly 5 columns
    local badge_str = string.format("%s%s%s %s  ", col, def.sym, reset_code, def.char)
    return badge_str, def.sym, def.char, def.name, col
end

-- Process Category Tabs / Filter Pills
local PROCESS_CATEGORIES = {
    { id = "all",     label = "All" },
    { id = "user",    label = "User" },
    { id = "system",  label = "System" },
    { id = "active",  label = "Active" },
    { id = "zombies", label = "Zombies" },
}

local function get_current_system_user()
    if is_windows then
        return (os.getenv("USERNAME") or "User"):lower()
    else
        return (os.getenv("USER") or os.getenv("LOGNAME") or "root"):lower()
    end
end

local function matches_process_category(pr, cat_id, current_user)
    if not pr then return false end
    if not cat_id or cat_id == "all" then return true end

    local my_user = (current_user or get_current_system_user()):lower()
    local pr_user = (pr.username or ""):lower()

    if cat_id == "user" then
        if my_user ~= "root" then
            return (pr_user == my_user)
        else
            -- If running as root, user processes are non-kernel threads
            return (pr.uid == 0 or pr_user == "root")
                and (not pr.ppid or pr.ppid ~= 2)
                and ((pr.vsize_kb or 0) > 0)
                and (not pr.comm or pr.comm:sub(1, 1) ~= "[")
        end
    elseif cat_id == "system" then
        if my_user ~= "root" then
            return (pr_user ~= my_user) or (pr.uid and pr.uid < 1000) or (pr_user == "system")
        else
            -- If running as root, system processes are kernel threads or init
            return (pr.ppid and pr.ppid == 2)
                or ((pr.vsize_kb or 0) == 0)
                or (pr.comm and pr.comm:sub(1, 1) == "[")
                or (pr.pid and pr.pid == 1)
        end
    elseif cat_id == "active" then
        local is_running = (pr.state == "R")
        local has_cpu = (pr.cpu_pct and pr.cpu_pct > 0.05)
        local has_io = ((pr.io_total_rate or 0) > 0) or ((pr.io_read_rate or 0) > 0) or ((pr.io_write_rate or 0) > 0)
        return is_running or has_cpu or has_io
    elseif cat_id == "zombies" then
        return (pr.state == "Z" or pr.state == "z")
    end

    return true
end

local function count_process_categories(procs, current_user)
    local my_user = current_user or get_current_system_user()
    local counts = {
        all = #procs,
        user = 0,
        system = 0,
        active = 0,
        zombies = 0,
    }

    for _, pr in ipairs(procs) do
        if matches_process_category(pr, "user", my_user) then
            counts.user = counts.user + 1
        end
        if matches_process_category(pr, "system", my_user) then
            counts.system = counts.system + 1
        end
        if matches_process_category(pr, "active", my_user) then
            counts.active = counts.active + 1
        end
        if matches_process_category(pr, "zombies", my_user) then
            counts.zombies = counts.zombies + 1
        end
    end

    return counts
end

local function render_category_pills(categories, active_cat_idx, counts, max_w, theme)
    local t = theme or C
    local is_compact = max_w and (max_w < 68)
    local out = {}
    table.insert(out, " ")

    for idx, cat in ipairs(categories) do
        local count = counts[cat.id] or 0
        local is_active = (idx == active_cat_idx)
        local label = cat.label
        if is_compact then
            if cat.id == "user" then label = "Usr"
            elseif cat.id == "system" then label = "Sys"
            elseif cat.id == "active" then label = "Act"
            elseif cat.id == "zombies" then label = "Zom" end
        end
        local pill_text = string.format("%s: %d", label, count)

        if is_active then
            local active_style = t.border_focus or "\27[1;36m"
            table.insert(out, string.format(" %s▶[%s]◀%s", active_style, pill_text, t.reset))
        else
            if cat.id == "zombies" and count > 0 then
                local alert_col = t.cpu_high or "\27[1;31m"
                table.insert(out, string.format(" %s[%s]%s", alert_col, pill_text, t.reset))
            else
                local dim_col = t.dim or "\27[2m"
                table.insert(out, string.format(" %s[%s]%s", dim_col, pill_text, t.reset))
            end
        end
    end

    local pills_str = table.concat(out)
    local cur_vlen = visual_len(pills_str)
    local hint = "(Press [ / ] to switch)"
    local hint_len = visual_len(hint)

    if max_w and (cur_vlen + hint_len + 4) <= max_w then
        local pad = string.rep(" ", max_w - cur_vlen - hint_len - 2)
        pills_str = pills_str .. pad .. (t.dim or "\27[2m") .. hint .. (t.reset or "\27[0m")
    elseif max_w and (cur_vlen + 12) <= max_w then
        local short_hint = "([ / ])"
        local pad = string.rep(" ", max_w - cur_vlen - visual_len(short_hint) - 2)
        pills_str = pills_str .. pad .. (t.dim or "\27[2m") .. short_hint .. (t.reset or "\27[0m")
    end

    return pills_str
end

local function get_category_tab_at_x(click_x, categories, counts, active_idx, max_w)
    local is_compact = max_w and (max_w < 68)
    local cur_x = 2
    for idx, cat in ipairs(categories) do
        local count = counts[cat.id] or 0
        local label = cat.label
        if is_compact then
            if cat.id == "user" then label = "Usr"
            elseif cat.id == "system" then label = "Sys"
            elseif cat.id == "active" then label = "Act"
            elseif cat.id == "zombies" then label = "Zom" end
        end
        local pill_w = visual_len(string.format("[%s: %d]", label, count))
        if idx == active_idx then
            pill_w = pill_w + 2 -- account for ▶ and ◀
        end
        local start_x = cur_x + 1
        local end_x = start_x + pill_w
        if click_x >= start_x and click_x <= end_x then
            return idx
        end
        cur_x = end_x + 1
    end
    return nil
end

-- =========================================================================
-- 4. Cross-Platform Telemetry Engine (Hardware, /proc, FFI)
-- =========================================================================
local read_cpu_stats, read_cpu_sensors, read_memory_stats
local read_network_stats, read_storage_stats, read_loadavg, read_gpu_stats
local read_os_info, read_cpu_model
local read_process_table, terminate_process, kill_process, send_signal_to_process, renice_process

local uid_cache = {}
local function resolve_username(uid)
    if not uid then return "unknown" end
    if uid_cache[uid] then return uid_cache[uid] end

    if is_windows then
        uid_cache[uid] = (uid == 0) and "SYSTEM" or (os.getenv("USERNAME") or "User")
        return uid_cache[uid]
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

    local cached_cpu_model = nil
    local cached_cpu_mhz = 0
    local cached_os_info = nil

    local function probe_win_sysinfo()
        if cached_os_info and cached_cpu_model then return end

        -- 1. Windows OS Detection via RtlGetVersion
        pcall(function()
            local ntdll = ffi.load("ntdll")
            local vi = ffi.new("OSVERSIONINFOW")
            vi.dwOSVersionInfoSize = ffi.sizeof(vi)
            ntdll.RtlGetVersion(vi)
            local maj = tonumber(vi.dwMajorVersion)
            local bld = tonumber(vi.dwBuildNumber)
            local name = "Windows"
            if maj == 10 then
                name = (bld >= 22000) and "Windows 11" or "Windows 10"
            elseif maj == 6 then
                local min = tonumber(vi.dwMinorVersion)
                if min == 3 then name = "Windows 8.1"
                elseif min == 2 then name = "Windows 8"
                elseif min == 1 then name = "Windows 7"
                end
            end
            cached_os_info = name
        end)
        if not cached_os_info then
            cached_os_info = os.getenv("OS") or "Windows"
        end

        -- 2. CPU Model and Base Frequency (MHz) via Registry
        pcall(function()
            local advapi32 = ffi.load("advapi32")
            local hk = ffi.new("HKEY[1]")
            local HKEY_LOCAL_MACHINE = ffi.cast("HKEY", 0x80000002)
            if advapi32.RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", 0, 0x20019, hk) == 0 then
                local buf = ffi.new("char[256]")
                local sz = ffi.new("DWORD[1]", 256)
                if advapi32.RegQueryValueExA(hk[0], "ProcessorNameString", nil, nil, ffi.cast("BYTE*", buf), sz) == 0 then
                    local raw = ffi.string(buf)
                    cached_cpu_model = raw:gsub("%(R%)", ""):gsub("%(TM%)", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                end
                local mhz = ffi.new("DWORD[1]")
                local msz = ffi.new("DWORD[1]", 4)
                if advapi32.RegQueryValueExA(hk[0], "~MHz", nil, nil, ffi.cast("BYTE*", mhz), msz) == 0 then
                    cached_cpu_mhz = tonumber(mhz[0])
                end
                advapi32.RegCloseKey(hk[0])
            end
        end)
        if not cached_cpu_model or #cached_cpu_model == 0 then
            cached_cpu_model = os.getenv("PROCESSOR_IDENTIFIER") or "Windows Processor"
        end
    end

    read_os_info = function()
        probe_win_sysinfo()
        return cached_os_info or "Windows"
    end

    read_cpu_model = function()
        probe_win_sysinfo()
        return cached_cpu_model or "Windows Processor"
    end

    read_cpu_sensors = function()
        probe_win_sysinfo()
        local freq_ghz = (cached_cpu_mhz > 0) and (cached_cpu_mhz / 1000.0) or nil
        return nil, freq_ghz
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
        local swap_used_kb  = math.min(swap_total_kb, math.max(0, (pagefile_total_kb - pagefile_avail_kb) - used_kb))
        local swap_pct = (swap_total_kb > 0) and math.min(100.0, math.max(0.0, (swap_used_kb / swap_total_kb) * 100.0)) or 0

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

        local dbuf = ffi.new("char[512]")
        local dlen = kernel32.GetLogicalDriveStringsA(512, dbuf)
        local p = 0
        while p < dlen do
            local drive = ffi.string(dbuf + p)
            local dtype = kernel32.GetDriveTypeA(drive)
            -- Only probe DRIVE_FIXED (3) or DRIVE_REMOTE (4) to avoid blocking on empty removable drives
            if (dtype == 3 or dtype == 4) and kernel32.GetDiskFreeSpaceExA(drive, free_caller, total_bytes, total_free) ~= 0 then
                local tot = tonumber(total_bytes[0])
                local fre = tonumber(total_free[0])
                local usd = math.max(0, tot - fre)
                local pct = tot > 0 and (usd / tot * 100.0) or 0
                local mnt_name = drive:gsub("\\+$", "")
                table.insert(mounts, {
                    mount = mnt_name,
                    device = mnt_name,
                    total_bytes = tot,
                    used_bytes = usd,
                    avail_bytes = fre,
                    used_pct = pct,
                })
            end
            p = p + #drive + 1
        end

        -- Fallback to C: if drive enumeration returned empty
        if #mounts == 0 and kernel32.GetDiskFreeSpaceExA("C:\\", free_caller, total_bytes, total_free) ~= 0 then
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

    -- GPU Telemetry Engine (NVML + DXGI)
    local gpu_initialized = false
    local nvml_handle = nil
    local nvml_device_count = 0
    local dxgi_cached_gpus = nil

    local function init_gpu_probes()
        if gpu_initialized then return end
        gpu_initialized = true

        -- 1. Try NVML (NVIDIA)
        local ok, lib = pcall(ffi.load, "nvml")
        if not ok then
            ok, lib = pcall(ffi.load, "C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvml.dll")
        end
        if ok then
            pcall(function()
                ffi.cdef[[
                    typedef void* nvmlDevice_t;
                    typedef struct {
                        unsigned long long total;
                        unsigned long long free;
                        unsigned long long used;
                    } nvmlMemory_t;
                    typedef struct {
                        unsigned int gpu;
                        unsigned int memory;
                    } nvmlUtilization_t;
                    int nvmlInit_v2(void);
                    int nvmlShutdown(void);
                    int nvmlDeviceGetCount_v2(unsigned int *deviceCount);
                    int nvmlDeviceGetHandleByIndex_v2(unsigned int index, nvmlDevice_t *device);
                    int nvmlDeviceGetName(nvmlDevice_t device, char *name, unsigned int length);
                    int nvmlDeviceGetMemoryInfo(nvmlDevice_t device, nvmlMemory_t *memory);
                    int nvmlDeviceGetUtilizationRates(nvmlDevice_t device, nvmlUtilization_t *utilization);
                    int nvmlDeviceGetTemperature(nvmlDevice_t device, int sensorType, unsigned int *temp);
                ]]
            end)
            local init_ok = false
            pcall(function()
                if lib.nvmlInit_v2() == 0 then init_ok = true end
            end)
            if init_ok then
                local cnt = ffi.new("unsigned int[1]")
                if lib.nvmlDeviceGetCount_v2(cnt) == 0 and cnt[0] > 0 then
                    nvml_handle = lib
                    nvml_device_count = cnt[0]
                    return
                end
            end
        end

        -- 2. Fallback to DXGI for AMD / Intel / generic GPUs on Windows
        local dx_ok, dxgi = pcall(ffi.load, "dxgi")
        if dx_ok then
            pcall(function()
                ffi.cdef[[
                    typedef struct {
                        uint16_t Description[128];
                        uint32_t VendorId;
                        uint32_t DeviceId;
                        uint32_t SubSysId;
                        uint32_t Revision;
                        size_t DedicatedVideoMemory;
                        size_t DedicatedSystemMemory;
                        size_t SharedSystemMemory;
                        struct { uint32_t LowPart; int32_t HighPart; } AdapterLuid;
                    } DXGI_ADAPTER_DESC;

                    typedef struct IDXGIAdapterVtbl {
                        void* QueryInterface;
                        void* AddRef;
                        uint32_t (*Release)(void* this);
                        void* SetPrivateData;
                        void* SetPrivateDataInterface;
                        void* GetPrivateData;
                        void* GetParent;
                        void* EnumOutputs;
                        int (*GetDesc)(void* this, DXGI_ADAPTER_DESC* pDesc);
                    } IDXGIAdapterVtbl;

                    typedef struct IDXGIAdapter {
                        IDXGIAdapterVtbl* lpVtbl;
                    } IDXGIAdapter;

                    typedef struct IDXGIFactoryVtbl {
                        void* QueryInterface;
                        void* AddRef;
                        uint32_t (*Release)(void* this);
                        void* SetPrivateData;
                        void* SetPrivateDataInterface;
                        void* GetPrivateData;
                        void* GetParent;
                        int (*EnumAdapters)(void* this, uint32_t Adapter, IDXGIAdapter** ppAdapter);
                    } IDXGIFactoryVtbl;

                    typedef struct IDXGIFactory {
                        IDXGIFactoryVtbl* lpVtbl;
                    } IDXGIFactory;

                    typedef struct { uint32_t Data1; uint16_t Data2; uint16_t Data3; uint8_t Data4[8]; } GUID;
                    int CreateDXGIFactory(const GUID* riid, void** ppFactory);
                ]]
            end)
            local IID_IDXGIFactory = ffi.new("GUID", {0x7b7166ec, 0x21c7, 0x44ae, {0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69}})
            local ppFactory = ffi.new("void*[1]")
            local ok_f = pcall(function() return dxgi.CreateDXGIFactory(IID_IDXGIFactory, ppFactory) end)
            if ok_f and ppFactory[0] ~= nil then
                local factory = ffi.cast("IDXGIFactory*", ppFactory[0])
                local pAdapter = ffi.new("IDXGIAdapter*[1]")
                local idx = 0
                dxgi_cached_gpus = {}
                while factory.lpVtbl.EnumAdapters(factory, idx, pAdapter) == 0 do
                    local adapter = pAdapter[0]
                    local desc = ffi.new("DXGI_ADAPTER_DESC")
                    if adapter.lpVtbl.GetDesc(adapter, desc) == 0 then
                        local vram_bytes = tonumber(desc.DedicatedVideoMemory)
                        if vram_bytes > 0 then
                            local chars = {}
                            for ci = 0, 127 do
                                local c = desc.Description[ci]
                                if c == 0 then break end
                                table.insert(chars, string.char(bit.band(c, 0xFF)))
                            end
                            local name = table.concat(chars)
                            if not name:find("Basic Render Driver") then
                                table.insert(dxgi_cached_gpus, {
                                    name = name,
                                    mem_total_kb = math.floor(vram_bytes / 1024),
                                    mem_used_kb = 0,
                                    mem_used_pct = 0,
                                    temp_c = nil,
                                    util_pct = nil,
                                })
                            end
                        end
                    end
                    adapter.lpVtbl.Release(adapter)
                    idx = idx + 1
                end
                factory.lpVtbl.Release(factory)
            end
        end
    end

    read_gpu_stats = function()
        init_gpu_probes()
        local gpus = {}
        if nvml_handle and nvml_device_count > 0 then
            for i = 0, nvml_device_count - 1 do
                local dev = ffi.new("nvmlDevice_t[1]")
                if nvml_handle.nvmlDeviceGetHandleByIndex_v2(i, dev) == 0 then
                    local name_buf = ffi.new("char[64]")
                    nvml_handle.nvmlDeviceGetName(dev[0], name_buf, 64)
                    local mem = ffi.new("nvmlMemory_t")
                    nvml_handle.nvmlDeviceGetMemoryInfo(dev[0], mem)
                    local util = ffi.new("nvmlUtilization_t")
                    nvml_handle.nvmlDeviceGetUtilizationRates(dev[0], util)
                    local temp = ffi.new("unsigned int[1]")
                    local has_temp = (nvml_handle.nvmlDeviceGetTemperature(dev[0], 0, temp) == 0)

                    local tot_kb = math.floor(tonumber(mem.total) / 1024)
                    local usd_kb = math.floor(tonumber(mem.used) / 1024)
                    local pct = tot_kb > 0 and (usd_kb / tot_kb * 100.0) or 0
                    table.insert(gpus, {
                        name = ffi.string(name_buf),
                        temp_c = has_temp and tonumber(temp[0]) or nil,
                        util_pct = tonumber(util.gpu),
                        mem_util_pct = tonumber(util.memory),
                        mem_total_kb = tot_kb,
                        mem_used_kb = usd_kb,
                        mem_used_pct = pct,
                    })
                end
            end
        elseif dxgi_cached_gpus and #dxgi_cached_gpus > 0 then
            return dxgi_cached_gpus
        end
        return gpus
    end

    local prev_win_proc_times = {}
    local win_proc_user_cache = {}

    read_process_table = function(mem_total_kb, now_clock)
        local snap = kernel32.CreateToolhelp32Snapshot(0x02, 0)
        if snap == ffi.cast("void*", -1) or snap == nil then return {} end

        local pe = ffi.new("PROCESSENTRY32")
        pe.dwSize = ffi.sizeof(pe)
        local pmc = ffi.new("PROCESS_MEMORY_COUNTERS")
        pmc.cb = ffi.sizeof(pmc)
        local c_ft, e_ft, k_ft, u_ft = ffi.new("FILETIME"), ffi.new("FILETIME"), ffi.new("FILETIME"), ffi.new("FILETIME")
        local now_ft = ffi.new("FILETIME")
        kernel32.GetSystemTimeAsFileTime(now_ft)
        local now_t = filetime_to_num(now_ft)

        local win_current_user = os.getenv("USERNAME") or "User"
        local sess_buf = ffi.new("uint32_t[1]")
        local active_pids = {}

        local procs = {}
        local ok = kernel32.Process32First(snap, pe)

        while ok ~= 0 do
            local pid = pe.th32ProcessID
            local ppid = pe.th32ParentProcessID
            local exe = ffi.string(pe.szExeFile)
            local res_kb = 0
            local cpu_pct = 0
            local threads = tonumber(pe.cntThreads) or 1
            local elapsed_sec = 0
            local cpu_time_sec = 0

            active_pids[pid] = true

            if pid ~= 0 then
                local h = kernel32.OpenProcess(0x1000, 0, pid)
                if h ~= nil then
                    if psapi.GetProcessMemoryInfo(h, pmc, pmc.cb) ~= 0 then
                        res_kb = tonumber(pmc.WorkingSetSize / 1024)
                    end
                    if kernel32.GetProcessTimes(h, c_ft, e_ft, k_ft, u_ft) ~= 0 then
                        local create_t = filetime_to_num(c_ft)
                        if create_t > 0 and now_t >= create_t then
                            elapsed_sec = (now_t - create_t) / 1e7
                        end
                        cpu_time_sec = (filetime_to_num(k_ft) + filetime_to_num(u_ft)) / 1e7
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

            -- Determine user & UID
            local username = win_proc_user_cache[pid]
            local uid = 0
            if not username then
                if pid == 0 or pid == 4 then
                    username = "SYSTEM"
                    uid = 0
                else
                    local sess_ok = kernel32.ProcessIdToSessionId(pid, sess_buf)
                    if sess_ok ~= 0 and sess_buf[0] > 0 then
                        username = win_current_user
                        uid = 1000
                    else
                        username = "SYSTEM"
                        uid = 0
                    end
                end
                win_proc_user_cache[pid] = username
            else
                uid = (username == "SYSTEM") and 0 or 1000
            end

            -- State determination: Z if 0 threads, R if consuming CPU, S if sleeping/waiting
            local proc_state = "S"
            if threads == 0 then
                proc_state = "Z"
            elseif cpu_pct > 0.05 then
                proc_state = "R"
            else
                proc_state = "S"
            end

            local mem_pct = (mem_total_kb > 0) and ((res_kb / mem_total_kb) * 100.0) or 0
            table.insert(procs, {
                pid = pid,
                ppid = ppid,
                elapsed_sec = elapsed_sec,
                cpu_time_sec = cpu_time_sec,
                comm = exe,
                cmdline = exe,
                state = proc_state,
                nice = 0,
                cpu_pct = cpu_pct,
                mem_pct = mem_pct,
                res_kb = res_kb,
                vsize_kb = res_kb,
                threads = threads,
                uid = uid,
                username = username,
                io_read_bytes = 0,
                io_write_bytes = 0,
                io_read_rate = 0,
                io_write_rate = 0,
                io_total_rate = 0,
            })

            ok = kernel32.Process32Next(snap, pe)
        end
        kernel32.CloseHandle(snap)

        -- Clean up dead PIDs from caches
        for p in pairs(win_proc_user_cache) do
            if not active_pids[p] then
                win_proc_user_cache[p] = nil
                prev_win_proc_times[p] = nil
            end
        end

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

    renice_process = function(pid, new_nice)
        return false
    end
else
    -- POSIX / Linux Telemetry Implementation
    local posix_stat
    if pcall(function() return ffi.C.__xstat end) then
        local stat_ver = (ffi.arch == "arm") and 3 or 1
        posix_stat = function(path, st) return ffi.C.__xstat(stat_ver, path, st) end
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
        local candidates = {}
        local seen_devs = {}

        local f_mnt = io.open("/proc/mounts", "r")
        if f_mnt then
            for line in f_mnt:lines() do
                local dev, mnt, fstype = line:match("^(%S+)%s+(%S+)%s+(%S+)")
                if dev and dev:find("^/dev/") and not dev:find("^/dev/loop") then
                    -- Priority: / (1) > /home (2) > /boot (3) > /var (4) > /srv (5) > others
                    local prio = 100
                    if mnt == "/" then prio = 1
                    elseif mnt == "/home" then prio = 2
                    elseif mnt == "/boot" or mnt:find("^/boot/") then prio = 3
                    elseif mnt:find("^/var") then prio = 50
                    elseif mnt:find("^/srv") then prio = 60
                    elseif mnt:find("^/root") then prio = 70
                    end

                    -- For multi-subvolume setups (e.g. Btrfs on CachyOS/Fedora) sharing the exact same device,
                    -- prioritize the main root / or home mount over subvolumes to avoid redundant identical meters.
                    if not seen_devs[dev] or prio < seen_devs[dev].prio then
                        seen_devs[dev] = { dev = dev, mnt = mnt, fstype = fstype, prio = prio }
                    end
                end
            end
            f_mnt:close()

            for _, info in pairs(seen_devs) do
                table.insert(candidates, info)
            end
            table.sort(candidates, function(a, b) return a.prio < b.prio end)

            local sv = ffi.new("struct statvfs")
            for _, c in ipairs(candidates) do
                if ffi.C.statvfs(c.mnt, sv) == 0 then
                    local bsize = tonumber(sv.f_frsize) > 0 and tonumber(sv.f_frsize) or tonumber(sv.f_bsize)
                    local total = tonumber(sv.f_blocks) * bsize
                    local free = tonumber(sv.f_bfree) * bsize
                    local avail = tonumber(sv.f_bavail) * bsize
                    local used = math.max(0, total - free)
                    local pct = (total > 0) and (used / total * 100.0) or 0

                    table.insert(mounts, {
                        mount = c.mnt,
                        device = c.dev,
                        fstype = c.fstype,
                        total_bytes = total,
                        used_bytes = used,
                        avail_bytes = avail,
                        used_pct = pct,
                    })
                end
            end
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
                if name and (name:match("^sd[a-z]$") or name:match("^nvme%d+n%d+$") or name:match("^vd[a-z]$") or name:match("^mmcblk%d+$") or name:match("^hd[a-z]$") or name:match("^xvd[a-z]$")) then
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

    local cached_linux_os = nil
    local cached_linux_cpu = nil

    read_os_info = function()
        if cached_linux_os then return cached_linux_os end
        local f = io.open("/etc/os-release", "r")
        if f then
            for line in f:lines() do
                local p = line:match('^PRETTY_NAME="?([^"\r\n]+)"?')
                if p then cached_linux_os = p; break end
                if not cached_linux_os then
                    local n = line:match('^NAME="?([^"\r\n]+)"?')
                    if n then cached_linux_os = n end
                end
            end
            f:close()
        end
        if not cached_linux_os then
            pcall(function()
                local u = ffi.new("struct utsname")
                if ffi.C.uname(u) == 0 then
                    cached_linux_os = ffi.string(u.sysname) .. " " .. (ffi.string(u.release):match("^%d+%.%d+") or "")
                end
            end)
        end
        cached_linux_os = cached_linux_os or "Linux"
        return cached_linux_os
    end

    read_cpu_model = function()
        if cached_linux_cpu then return cached_linux_cpu end
        local f = io.open("/proc/cpuinfo", "r")
        if f then
            for line in f:lines() do
                local m = line:match("^model name%s*:%s*(.+)")
                    or line:match("^Model%s*:%s*(.+)")
                    or line:match("^Hardware%s*:%s*(.+)")
                    or line:match("^Processor%s*:%s*(.+)")
                if m then
                    cached_linux_cpu = m:gsub("%(R%)", ""):gsub("%(TM%)", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    if #cached_linux_cpu > 0 then break end
                end
            end
            f:close()
        end
        if not cached_linux_cpu or #cached_linux_cpu == 0 or cached_linux_cpu == "BCM2835" then
            local f_dt = io.open("/sys/firmware/devicetree/base/model", "r") or io.open("/proc/device-tree/model", "r")
            if f_dt then
                local m = f_dt:read("*a")
                f_dt:close()
                if m and #m > 0 then
                    local clean_m = m:gsub("%z", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    if #clean_m > 0 then cached_linux_cpu = clean_m end
                end
            end
        end
        if not cached_linux_cpu or #cached_linux_cpu == 0 then
            local f_dmi = io.open("/sys/class/dmi/id/product_name", "r")
            if f_dmi then
                local m = f_dmi:read("*l")
                f_dmi:close()
                if m and #m > 0 then
                    local clean_m = m:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    if #clean_m > 0 then cached_linux_cpu = clean_m end
                end
            end
        end
        cached_linux_cpu = cached_linux_cpu or "Linux CPU"
        return cached_linux_cpu
    end

    -- Linux GPU Telemetry (NVML + DRM Sysfs)
    local linux_gpu_inited = false
    local linux_nvml_lib = nil
    local linux_nvml_cnt = 0

    local function init_linux_gpu()
        if linux_gpu_inited then return end
        linux_gpu_inited = true

        local ok, lib = pcall(ffi.load, "libnvidia-ml.so.1")
        if not ok then ok, lib = pcall(ffi.load, "libnvidia-ml.so") end
        if ok then
            pcall(function()
                ffi.cdef[[
                    typedef void* nvmlDevice_t;
                    typedef struct {
                        unsigned long long total;
                        unsigned long long free;
                        unsigned long long used;
                    } nvmlMemory_t;
                    typedef struct {
                        unsigned int gpu;
                        unsigned int memory;
                    } nvmlUtilization_t;
                    int nvmlInit_v2(void);
                    int nvmlShutdown(void);
                    int nvmlDeviceGetCount_v2(unsigned int *deviceCount);
                    int nvmlDeviceGetHandleByIndex_v2(unsigned int index, nvmlDevice_t *device);
                    int nvmlDeviceGetName(nvmlDevice_t device, char *name, unsigned int length);
                    int nvmlDeviceGetMemoryInfo(nvmlDevice_t device, nvmlMemory_t *memory);
                    int nvmlDeviceGetUtilizationRates(nvmlDevice_t device, nvmlUtilization_t *utilization);
                    int nvmlDeviceGetTemperature(nvmlDevice_t device, int sensorType, unsigned int *temp);
                ]]
            end)
            local init_ok = false
            pcall(function()
                if lib.nvmlInit_v2() == 0 then init_ok = true end
            end)
            if init_ok then
                local cnt = ffi.new("unsigned int[1]")
                if lib.nvmlDeviceGetCount_v2(cnt) == 0 and cnt[0] > 0 then
                    linux_nvml_lib = lib
                    linux_nvml_cnt = cnt[0]
                end
            end
        end
    end

    read_gpu_stats = function()
        init_linux_gpu()
        local gpus = {}
        if linux_nvml_lib and linux_nvml_cnt > 0 then
            for i = 0, linux_nvml_cnt - 1 do
                local dev = ffi.new("nvmlDevice_t[1]")
                if linux_nvml_lib.nvmlDeviceGetHandleByIndex_v2(i, dev) == 0 then
                    local name_buf = ffi.new("char[64]")
                    linux_nvml_lib.nvmlDeviceGetName(dev[0], name_buf, 64)
                    local mem = ffi.new("nvmlMemory_t")
                    linux_nvml_lib.nvmlDeviceGetMemoryInfo(dev[0], mem)
                    local util = ffi.new("nvmlUtilization_t")
                    linux_nvml_lib.nvmlDeviceGetUtilizationRates(dev[0], util)
                    local temp = ffi.new("unsigned int[1]")
                    local has_temp = (linux_nvml_lib.nvmlDeviceGetTemperature(dev[0], 0, temp) == 0)

                    local tot_kb = math.floor(tonumber(mem.total) / 1024)
                    local usd_kb = math.floor(tonumber(mem.used) / 1024)
                    local pct = tot_kb > 0 and (usd_kb / tot_kb * 100.0) or 0
                    table.insert(gpus, {
                        name = ffi.string(name_buf),
                        temp_c = has_temp and tonumber(temp[0]) or nil,
                        util_pct = tonumber(util.gpu),
                        mem_util_pct = tonumber(util.memory),
                        mem_total_kb = tot_kb,
                        mem_used_kb = usd_kb,
                        mem_used_pct = pct,
                    })
                end
            end
            return gpus
        end

        -- Linux sysfs & DRM fallback (Intel iGPU / AMDGPU / Broadcom VideoCore / DRM Cards)
        local cached_drm_names = {}
        for card_idx = 0, 7 do
            local card_base = "/sys/class/drm/card" .. card_idx
            local f_uevent = io.open(card_base .. "/device/uevent", "r")
            if f_uevent then
                local slot = nil
                local driver = nil
                local pci_id = nil
                local of_compat = nil
                for line in f_uevent:lines() do
                    local s = line:match("^PCI_SLOT_NAME=(%S+)")
                    if s then slot = s end
                    local d = line:match("^DRIVER=(%S+)")
                    if d then driver = d end
                    local p = line:match("^PCI_ID=(%x+:%x+)")
                    if p then pci_id = p end
                    local c = line:match("^OF_COMPATIBLE_0=(%S+)")
                    if c then of_compat = c end
                end
                f_uevent:close()

                local gpu_name = cached_drm_names[card_idx]
                if not gpu_name then
                    if slot then
                        local p = io.popen("lspci -s " .. slot .. " 2>/dev/null")
                        if p then
                            local l = p:read("*l")
                            p:close()
                            if l then
                                local desc = l:match(":%s+(.-)%s*%(rev") or l:match(":%s+(.*)")
                                if desc then
                                    local bracket = desc:match("%[(.-)%]")
                                    if bracket and not bracket:find("^%x%x%x%x") then
                                        local brand = desc:find("^Intel") and "Intel " or (desc:find("^AMD") and "AMD " or "")
                                        gpu_name = brand .. bracket
                                    else
                                        gpu_name = desc:gsub("^Corporation%s+", "")
                                    end
                                end
                            end
                        end
                    end
                    if not gpu_name and driver then
                        if driver == "i915" or driver == "xe" then gpu_name = "Intel HD/UHD Graphics"
                        elseif driver == "amdgpu" or driver == "radeon" then gpu_name = "AMD Radeon Graphics"
                        elseif driver == "nouveau" then gpu_name = "NVIDIA Graphics (nouveau)"
                        elseif driver == "v3d" or driver == "vc4" or driver == "vc4-drm" then
                            if of_compat and of_compat:find("2712") then gpu_name = "Broadcom VideoCore VII (RPi 5)"
                            elseif of_compat and of_compat:find("2711") then gpu_name = "Broadcom VideoCore VI (RPi 4)"
                            else gpu_name = "Broadcom VideoCore 3D Graphics"
                            end
                        elseif driver == "panfrost" or driver == "mali" then gpu_name = "ARM Mali Graphics"
                        elseif driver == "msm" or driver == "freedreno" then gpu_name = "Qualcomm Adreno Graphics"
                        end
                    end
                    cached_drm_names[card_idx] = gpu_name
                end

                if gpu_name then
                    -- Check VRAM (discrete AMD / Intel)
                    local f_tot = io.open(card_base .. "/device/mem_info_vram_total", "r")
                    local tot_bytes = nil
                    local usd_bytes = 0
                    if f_tot then
                        tot_bytes = tonumber(f_tot:read("*a"):match("%d+"))
                        f_tot:close()
                        if tot_bytes and tot_bytes > 0 then
                            local f_usd = io.open(card_base .. "/device/mem_info_vram_used", "r")
                            if f_usd then
                                usd_bytes = tonumber(f_usd:read("*a"):match("%d+")) or 0
                                f_usd:close()
                            end
                        end
                    end

                    -- Check utilization
                    local util_pct = nil
                    local f_busy = io.open(card_base .. "/device/gpu_busy_percent", "r")
                    if f_busy then
                        util_pct = tonumber(f_busy:read("*a"):match("%d+"))
                        f_busy:close()
                    end

                    -- Check frequency (e.g. Intel gt_act_freq_mhz or gt_cur_freq_mhz)
                    local freq_ghz = nil
                    local function read_mhz(p)
                        local f = io.open(p, "r")
                        if not f then return nil end
                        local m = tonumber(f:read("*a"):match("%d+"))
                        f:close()
                        return (m and m > 0) and m or nil
                    end
                    local mhz = read_mhz(card_base .. "/gt_act_freq_mhz")
                        or read_mhz(card_base .. "/device/drm/card" .. card_idx .. "/gt_act_freq_mhz")
                        or read_mhz(card_base .. "/gt_cur_freq_mhz")
                        or read_mhz(card_base .. "/gt_max_freq_mhz")
                    if mhz then
                        freq_ghz = mhz / 1000.0
                    end

                    local temp_c = nil

                    -- Raspberry Pi Broadcom VideoCore Fallback Telemetry
                    if (driver == "v3d" or driver == "vc4" or driver == "vc4-drm") then
                        local f_t = io.open("/sys/class/thermal/thermal_zone0/temp", "r")
                        if f_t then
                            local raw_t = tonumber(f_t:read("*a"):match("%d+"))
                            f_t:close()
                            if raw_t then temp_c = math.floor(raw_t / 1000.0 + 0.5) end
                        end
                        if not freq_ghz then
                            local p = io.popen("vcgencmd measure_clock core 2>/dev/null")
                            if p then
                                local out = p:read("*a") or ""
                                p:close()
                                local hz = tonumber(out:match("=(%d+)"))
                                if hz and hz > 0 then freq_ghz = hz / 1e9 end
                            end
                        end
                        if not tot_bytes or tot_bytes == 0 then
                            local p = io.popen("vcgencmd get_mem gpu 2>/dev/null")
                            if p then
                                local out = p:read("*a") or ""
                                p:close()
                                local m = tonumber(out:match("(%d+)M"))
                                if m and m > 0 then
                                    tot_bytes = m * 1024 * 1024
                                    usd_bytes = math.min(4096 * 1024, tot_bytes)
                                end
                            end
                        end
                    end

                    local tot_kb = tot_bytes and math.floor(tot_bytes / 1024) or 0
                    local usd_kb = math.floor(usd_bytes / 1024)
                    local mem_pct = (tot_kb > 0) and (usd_kb / tot_kb * 100.0) or nil

                    table.insert(gpus, {
                        name = gpu_name,
                        temp_c = temp_c,
                        util_pct = util_pct,
                        freq_ghz = freq_ghz,
                        mem_total_kb = tot_kb > 0 and tot_kb or nil,
                        mem_used_kb = tot_kb > 0 and usd_kb or nil,
                        mem_used_pct = mem_pct,
                        is_integrated = (tot_kb == 0),
                    })
                    break -- Display primary display GPU
                end
            end
        end

        -- NVIDIA Jetson / Tegra SoC GPU fallback (Nano, TX1, TX2, Xavier, Orin)
        if #gpus == 0 then
            local tegra_gpu_path = nil
            local f_chk = io.open("/sys/devices/gpu.0/load", "r")
            if f_chk then
                f_chk:close()
                tegra_gpu_path = "/sys/devices/gpu.0"
            else
                for _, p in ipairs({"/sys/devices/57000000.gpu", "/sys/devices/17000000.gp10b", "/sys/devices/17000000.gv11b", "/sys/devices/platform/17000000.ga10b"}) do
                    local f = io.open(p .. "/load", "r")
                    if f then f:close(); tegra_gpu_path = p; break end
                end
            end

            if tegra_gpu_path then
                local util_pct = nil
                local f_load = io.open(tegra_gpu_path .. "/load", "r")
                if f_load then
                    local raw = f_load:read("*a")
                    f_load:close()
                    local n = tonumber(raw and raw:match("%d+"))
                    if n then util_pct = math.min(100, math.floor(n / 10 + 0.5)) end
                end

                local freq_ghz = nil
                local freq_candidates = {
                    tegra_gpu_path .. "/devfreq/57000000.gpu/cur_freq",
                    "/sys/class/devfreq/57000000.gpu/cur_freq",
                    tegra_gpu_path .. "/devfreq/cur_freq"
                }
                for _, fc in ipairs(freq_candidates) do
                    local f_fq = io.open(fc, "r")
                    if f_fq then
                        local raw_fq = f_fq:read("*a")
                        f_fq:close()
                        local hz = tonumber(raw_fq and raw_fq:match("%d+"))
                        if hz and hz > 0 then freq_ghz = hz / 1e9; break end
                    end
                end
                if not freq_ghz then
                    local d_df = ffi.C.opendir("/sys/class/devfreq")
                    if d_df ~= nil then
                        while true do
                            local ent = ffi.C.readdir(d_df)
                            if ent == nil then break end
                            local entry_name = ffi.string(ent.d_name)
                            if entry_name:find("%.gpu$") or entry_name:find("gv11b") or entry_name:find("ga10b") or entry_name:find("gp10b") then
                                local f_fq = io.open("/sys/class/devfreq/" .. entry_name .. "/cur_freq", "r")
                                if f_fq then
                                    local raw_fq = f_fq:read("*a")
                                    f_fq:close()
                                    local hz = tonumber(raw_fq and raw_fq:match("%d+"))
                                    if hz and hz > 0 then freq_ghz = hz / 1e9; break end
                                end
                            end
                        end
                        ffi.C.closedir(d_df)
                    end
                end

                local temp_c = nil
                for z = 0, 9 do
                    local f_t = io.open("/sys/class/thermal/thermal_zone" .. z .. "/type", "r")
                    if f_t then
                        local ztype = f_t:read("*l") or ""
                        f_t:close()
                        if ztype:upper():find("GPU") then
                            local f_v = io.open("/sys/class/thermal/thermal_zone" .. z .. "/temp", "r")
                            if f_v then
                                local raw_t = tonumber(f_v:read("*a"):match("%d+"))
                                f_v:close()
                                if raw_t then temp_c = math.floor(raw_t / 1000 + 0.5); break end
                            end
                        end
                    end
                end

                local gpu_name = "NVIDIA Tegra GPU"
                local f_comp = io.open("/proc/device-tree/gpu/compatible", "r")
                if f_comp then
                    local s = f_comp:read("*a") or ""
                    f_comp:close()
                    if s:find("gm20b") then gpu_name = "NVIDIA Tegra Maxwell GPU"
                    elseif s:find("gp10b") then gpu_name = "NVIDIA Tegra Pascal GPU"
                    elseif s:find("gv11b") then gpu_name = "NVIDIA Tegra Volta GPU"
                    elseif s:find("ga10b") then gpu_name = "NVIDIA Tegra Ampere GPU"
                    end
                end

                table.insert(gpus, {
                    name = gpu_name,
                    temp_c = temp_c,
                    util_pct = util_pct,
                    freq_ghz = freq_ghz,
                    is_integrated = true,
                })
            end
        end

        return gpus
    end

    read_process_table = function(mem_total_kb, now_clock)
        local d = ffi.C.opendir("/proc")
        if d == nil then return {} end

        local sys_uptime = 0
        local f_up = io.open("/proc/uptime", "r")
        if f_up then
            local up_line = f_up:read("*l")
            f_up:close()
            if up_line then
                sys_uptime = tonumber(up_line:match("^(%d+%.?%d*)")) or 0
            end
        end

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

                            local elapsed_sec = 0
                            if sys_uptime > 0 and start_time > 0 then
                                local start_sec = start_time / clk_tck
                                elapsed_sec = math.max(0, sys_uptime - start_sec)
                            end
                            local total_time = utime + stime
                            local cpu_time_sec = total_time / clk_tck
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
                                elapsed_sec = elapsed_sec,
                                cpu_time_sec = cpu_time_sec,
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

    renice_process = function(pid, new_nice)
        local ret = ffi.C.setpriority(0, pid, new_nice)
        return (ret == 0)
    end
end

-- =========================================================================
-- 5. Smart Process Filter Engine
-- =========================================================================
local function parse_bytes_or_num(str)
    local num, unit = str:match("^(%d+%.?%d*)([kKmMgGtT]?)$")
    if not num then return tonumber(str) or 0 end
    local val = tonumber(num) or 0
    unit = unit:upper()
    if unit == "K" then return val * 1024
    elseif unit == "M" then return val * 1024 * 1024
    elseif unit == "G" then return val * 1024 * 1024 * 1024
    else return val end
end

local function parse_time_sec(str)
    local num, unit = str:match("^(%d+%.?%d*)([sSmMhHdD]?)$")
    if not num then return tonumber(str) or 0 end
    local val = tonumber(num) or 0
    unit = unit:lower()
    if unit == "m" then return val * 60
    elseif unit == "h" then return val * 3600
    elseif unit == "d" then return val * 86400
    else return val end
end

local function match_smart_filter(pr, query)
    if not query or #query == 0 then return true end
    for token in query:gmatch("%S+") do
        local matched = false
        local u_val = token:match("^[uU][sS]?[eE]?[rR]?:(.*)$")
        local s_val = token:match("^[sS][tT]?[aA]?[tT]?[eE]?:(.*)$")
        local p_val = token:match("^[pP][iI]?[dD]?:(%d+)$")
        local cpu_gt = token:match("^[cC][pP][uU]>(%d+%.?%d*)$") or token:match("^[cC][pP][uU]>=(%d+%.?%d*)$")
        local cpu_lt = token:match("^[cC][pP][uU]<(%d+%.?%d*)$") or token:match("^[cC][pP][uU]<=(%d+%.?%d*)$")
        local mem_gt = token:match("^[mM][eE]?[mM]?>([%d%.%w]+)$") or token:match("^[mM][eE]?[mM]?>=([%d%.%w]+)$")
        local mem_lt = token:match("^[mM][eE]?[mM]?<([%d%.%w]+)$") or token:match("^[mM][eE]?[mM]?<=([%d%.%w]+)$")
        local io_gt  = token:match("^[iI][oO]>([%d%.%w]+)$")
        local time_gt = token:match("^[tT][iI]?[mM]?[eE]?>([%d%.%w]+)$")
            or token:match("^[tT][iI]?[mM]?[eE]?>=([%d%.%w]+)$")
            or token:match("^[eE][lL]?[aA]?[pP]?[sS]?[eE]?[dD]?>([%d%.%w]+)$")
            or token:match("^[eE][lL]?[aA]?[pP]?[sS]?[eE]?[dD]?>=([%d%.%w]+)$")
        local time_lt = token:match("^[tT][iI]?[mM]?[eE]?<([%d%.%w]+)$")
            or token:match("^[tT][iI]?[mM]?[eE]?<=([%d%.%w]+)$")
            or token:match("^[eE][lL]?[aA]?[pP]?[sS]?[eE]?[dD]?<([%d%.%w]+)$")
            or token:match("^[eE][lL]?[aA]?[pP]?[sS]?[eE]?[dD]?<=([%d%.%w]+)$")

        if u_val then
            if (pr.username or ""):lower():find(u_val:lower(), 1, true) then matched = true end
        elseif s_val then
            if (pr.state or ""):upper():find(s_val:upper(), 1, true) then matched = true end
        elseif p_val then
            if tostring(pr.pid):find(p_val, 1, true) then matched = true end
        elseif cpu_gt then
            if (pr.cpu_pct or 0) >= (tonumber(cpu_gt) or 0) then matched = true end
        elseif cpu_lt then
            if (pr.cpu_pct or 0) <= (tonumber(cpu_lt) or 0) then matched = true end
        elseif mem_gt then
            local thresh_bytes = parse_bytes_or_num(mem_gt)
            if not mem_gt:match("[kKmMgGtT]$") then thresh_bytes = thresh_bytes * 1024 * 1024 end
            if (pr.res_kb or 0) * 1024 >= thresh_bytes then matched = true end
        elseif mem_lt then
            local thresh_bytes = parse_bytes_or_num(mem_lt)
            if not mem_lt:match("[kKmMgGtT]$") then thresh_bytes = thresh_bytes * 1024 * 1024 end
            if (pr.res_kb or 0) * 1024 <= thresh_bytes then matched = true end
        elseif io_gt then
            local thresh_bytes = parse_bytes_or_num(io_gt)
            if not io_gt:match("[kKmMgGtT]$") then thresh_bytes = thresh_bytes * 1024 end
            if (pr.io_total_rate or 0) >= thresh_bytes then matched = true end
        elseif time_gt then
            local thresh_sec = parse_time_sec(time_gt)
            if (pr.elapsed_sec or 0) >= thresh_sec then matched = true end
        elseif time_lt then
            local thresh_sec = parse_time_sec(time_lt)
            if (pr.elapsed_sec or 0) <= thresh_sec then matched = true end
        else
            local t_low = token:lower()
            if pr.comm:lower():find(t_low, 1, true) or
               pr.cmdline:lower():find(t_low, 1, true) or
               (pr.username or ""):lower():find(t_low, 1, true) or
               tostring(pr.pid):find(t_low, 1, true) then
                matched = true
            end
        end

        if not matched then return false end
    end
    return true
end

-- =========================================================================
-- 6. Process Tree Construction Engine
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
        elseif sort_mode == "time" then
            val_a, val_b = (a.cpu_time_sec or 0), (b.cpu_time_sec or 0)
        elseif sort_mode == "elapsed" then
            val_a, val_b = (a.elapsed_sec or 0), (b.elapsed_sec or 0)
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
-- 7.2 Process Diagnostic Command Runner Engine (Proposal 3)
-- =========================================================================
local LINUX_DIAGNOSTIC_PRESETS = {
    { key = "1", name = "Open Files & Sockets",    cmd = "lsof -p %p 2>/dev/null || ls -la /proc/%p/fd", desc = "Inspect open file descriptors, pipes, and network sockets" },
    { key = "2", name = "Live Syscall Trace",      cmd = "strace -f -p %p", desc = "Attach strace to follow all threads and syscalls" },
    { key = "3", name = "Thread Stack Trace",      cmd = "pstack %p 2>/dev/null || gdb -batch -ex \"thread apply all bt\" -p %p", desc = "Dump multi-threaded C/native stack backtraces" },
    { key = "4", name = "Memory Map (pmap)",       cmd = "pmap -x %p", desc = "Detailed virtual memory mappings and RSS allocation" },
    { key = "5", name = "Systemd Service Journal", cmd = "journalctl _PID=%p -n 50 --no-pager", desc = "Inspect recent systemd service logs associated with PID" },
}

local WINDOWS_DIAGNOSTIC_PRESETS = {
    { key = "1", name = "Loaded DLLs & Modules",   cmd = "tasklist /m /fi \"PID eq %p\"", desc = "List all DLL dynamic libraries mapped in process memory" },
    { key = "2", name = "Active Network Sockets",  cmd = "netstat -ano | findstr \"%p\"", desc = "Inspect listening and established TCP/UDP network connections" },
    { key = "3", name = "Thread Breakdown & State", cmd = "powershell -Command \"(Get-Process -Id %p).Threads | Format-Table Id,ThreadState,WaitReason,Priority -AutoSize\"", desc = "Inspect thread count, thread states, and scheduling priorities" },
    { key = "4", name = "Full CLI Command & Paths", cmd = "powershell -Command \"Get-CimInstance Win32_Process -Filter \\\"ProcessId=%p\\\" | Format-List ProcessName,CommandLine,ExecutablePath,ParentProcessId,WorkingSetSize\"", desc = "Query complete command-line invocation, parent PID, and paths via WMI/CIM" },
    { key = "5", name = "Windows Service Hosting", cmd = "tasklist /svc /fi \"PID eq %p\"", desc = "Identify which Windows service is hosted inside process" },
}

local function get_diagnostic_presets()
    return is_windows and WINDOWS_DIAGNOSTIC_PRESETS or LINUX_DIAGNOSTIC_PRESETS
end

local function expand_diagnostic_cmd(template, proc)
    if not template or not proc then return template or "" end
    local pid_str = tostring(proc.pid or "")
    local comm_str = tostring(proc.comm or "")
    local user_str = tostring(proc.username or "")

    local res = template:gsub("%%%%", "\1")
    res = res:gsub("%%p", function() return pid_str end)
    res = res:gsub("%%c", function() return comm_str end)
    res = res:gsub("%%u", function() return user_str end)
    res = res:gsub("\1", "%%")
    return res
end

local function draw_diagnostic_modal(out, pr, custom_cmd, sel_preset_idx, term_w, term_h, theme)
    local tc = theme or C
    local presets = get_diagnostic_presets()
    sel_preset_idx = math.max(1, math.min(#presets, sel_preset_idx or 1))
    local active_template = (custom_cmd and #custom_cmd > 0) and custom_cmd or presets[sel_preset_idx].cmd
    local preview_cmd = expand_diagnostic_cmd(active_template, pr)

    local mw = math.min(84, term_w - 4)
    local compact = (term_h < 17)
    local mh = compact and 12 or 14
    local mx = math.floor((term_w - mw) / 2)
    local my = math.floor((term_h - mh) / 2)

    local modal_title = string.format("Process Diagnostic Runner [PID %d: %s]", pr.pid or 0, pr.comm or "process")
    draw_modal_box(out, mx, my, mw, mh, modal_title)

    -- Row 1: Command Input Box
    local cmd_disp = truncate(active_template, mw - 14)
    table.insert(out, draw_box_row(mx, my + 1, mw, string.format(" %sCommand:%s [%s%s%s%s]",
        tc.bold, tc.reset, tc.title_col, cmd_disp, tc.reset, string.rep(" ", math.max(0, mw - 14 - visual_len(cmd_disp))))))

    -- Row 2: Live Preview
    local prev_disp = truncate(preview_cmd, mw - 14)
    table.insert(out, draw_box_row(mx, my + 2, mw, string.format(" %sPreview:%s %s$ %s%s",
        tc.dim, tc.reset, tc.cpu_low, prev_disp, tc.reset)))

    local cur_row = my + 3
    if not compact then
        table.insert(out, draw_box_row(mx, cur_row, mw, ""))
        cur_row = cur_row + 1
    end

    -- Quick Presets Header
    table.insert(out, draw_box_row(mx, cur_row, mw, string.format(" %sQuick Presets (%s):%s", tc.title_col, is_windows and "Windows" or "Linux", tc.reset)))
    cur_row = cur_row + 1

    -- Presets list
    for i, p in ipairs(presets) do
        local is_sel = (i == sel_preset_idx)
        local key_tag = string.format("[%s]", p.key)
        local line_text = string.format("   %s %-24s (%s)", key_tag, p.name, p.cmd)
        if is_sel then
            local sel_line = string.format(" ▶ %s %-24s (%s)", key_tag, p.name, p.cmd)
            table.insert(out, draw_box_row(mx, cur_row, mw, tc.sel_bg .. truncate(sel_line, mw - 4) .. tc.reset))
        else
            table.insert(out, draw_box_row(mx, cur_row, mw, truncate(line_text, mw - 4)))
        end
        cur_row = cur_row + 1
    end

    if not compact then
        table.insert(out, draw_box_row(mx, cur_row, mw, ""))
        cur_row = cur_row + 1
    end

    -- Macro Tokens Hint
    table.insert(out, draw_box_row(mx, cur_row, mw, string.format(" %sTokens: %%p (PID), %%c (Binary), %%u (User)%s", tc.dim, tc.reset)))
    cur_row = cur_row + 1

    -- Actions Footer
    table.insert(out, draw_box_row(mx, cur_row, mw, string.format("  %s[Enter] Execute   [1-5] Run Preset   [↑/↓] Select   [Esc] Cancel%s", tc.bold, tc.reset)))
end

local function render_diagnostic_modal_frame(proc, custom_cmd, sel_preset_idx, term_w, term_h, theme)
    proc = proc or { pid = 14820, comm = "luatop", username = "zliu" }
    term_w = term_w or 80
    term_h = term_h or 24
    local out = {}
    draw_diagnostic_modal(out, proc, custom_cmd, sel_preset_idx, term_w, term_h, theme or C)
    return table.concat(out)
end

local function execute_diagnostic_command(cmd_template, proc)
    if not cmd_template or not proc then return end
    local expanded = expand_diagnostic_cmd(cmd_template, proc)
    if not expanded or expanded:match("^%s*$") then return end

    suspend_raw_mode()

    io.write("\27[2J\27[1;1H")
    io.write(string.format("\27[1;36m=== luatop Process Diagnostic Runner ===\27[0m\n"))
    io.write(string.format("\27[90mTarget:   PID %d (%s) | User: %s\27[0m\n", proc.pid or 0, proc.comm or "process", proc.username or "unknown"))
    io.write(string.format("\27[1;32mCommand:  %s\27[0m\n\n", expanded))
    io.flush()

    if is_windows then
        os.execute('cmd.exe /c "' .. expanded .. '"')
    else
        os.execute(expanded)
    end

    io.write(string.format("\n\27[1;33m────────────────────────────────────────────────────────\27[0m\n"))
    io.write(string.format("\27[1;33m[Diagnostic completed. Press Enter to return to luatop]\27[0m\n"))
    io.flush()

    -- Flush input before prompt
    if is_windows then
        pcall(function()
            local kernel32 = ffi.load("kernel32")
            local hIn = kernel32.GetStdHandle(0xFFFFFFF6)
            kernel32.FlushConsoleInputBuffer(hIn)
        end)
    else
        pcall(function() ffi.C.tcflush(0, 0) end)
    end

    pcall(function() io.read("*line") end)

    resume_raw_mode()
end

-- =========================================================================
-- 7.5 Maximized Zoom View Engine (Proposal 1)
-- =========================================================================
local function render_zoomed_pane(out, pane_idx, state, term_w, term_h)
    state = state or {}
    local zh = term_h - 2
    local zw = term_w
    if pane_idx == 1 then
        -- 1. Zoomed CPU Pane
        local cores = state.cores or (read_cpu_stats and read_cpu_stats() or {})
        local overall_cpu = state.overall_cpu or 0.0
        local cpu_history = state.cpu_history or { overall_cpu }
        local c_temp, c_freq = state.temp_c, state.freq_ghz
        if c_temp == nil and c_freq == nil and read_cpu_sensors then
            c_temp, c_freq = read_cpu_sensors()
        end
        local sensor_parts = {}
        if c_temp then table.insert(sensor_parts, string.format("%.0f°C", c_temp)) end
        if c_freq then table.insert(sensor_parts, string.format("%.2fGHz", c_freq)) end
        local sensor_str = #sensor_parts > 0 and (" [" .. table.concat(sensor_parts, " ") .. "]") or ""

        local spark_w = math.min(30, math.max(8, math.floor(zw * 0.22)))
        local cpu_spark = make_sparkline(cpu_history, spark_w, C.cpu_low)
        local title = string.format("[1] CPU (MAXIMIZED - Press [z] or [Esc] to Restore): %.1f%%%s", overall_cpu, sensor_str)
        draw_pane(out, 1, 2, zw, zh, title, true, "Usage: " .. cpu_spark)

        -- Row 3: Overall Banner & Hardware Model
        local bar_w = math.max(8, math.min(30, math.floor(zw * 0.25)))
        local ov_bar = make_meter_bar(overall_cpu, bar_w)
        local cpu_mod = state.cpu_model_clean or (read_cpu_model and read_cpu_model() or "CPU")
        table.insert(out, draw_box_row(1, 3, zw, string.format("  %sOverall Usage:%s %s %5.1f%%%s │ %sModel:%s %s%s%s",
            C.bold, C.reset, ov_bar, overall_cpu, C.reset,
            C.bold, C.reset, C.title_col, truncate(cpu_mod, math.max(12, zw - 60)), C.reset)))

        -- Row 4: Core Statistics & Distribution
        local min_pct, max_pct = 100, 0
        local busy_cores = 0
        local total_pct = 0
        for _, c in ipairs(cores) do
            min_pct = math.min(min_pct, c.pct or 0)
            max_pct = math.max(max_pct, c.pct or 0)
            total_pct = total_pct + (c.pct or 0)
            if (c.pct or 0) >= 1 then busy_cores = busy_cores + 1 end
        end
        local avg_pct = #cores > 0 and (total_pct / #cores) or 0
        table.insert(out, draw_box_row(1, 4, zw, string.format("  %sCores:%s %d   %sBusy:%s %d/%d   %sAvg/core:%s %5.1f%%   %sMin:%s %5.1f%%   %sMax:%s %5.1f%%",
            C.dim, C.reset, #cores,
            C.dim, C.reset, busy_cores, #cores,
            C.dim, C.reset, avg_pct,
            C.dim, C.reset, min_pct,
            C.dim, C.reset, max_pct)))

        -- Row 5: Separator
        table.insert(out, draw_box_row(1, 5, zw, C.dim .. string.rep("─", math.max(0, zw - 4)) .. C.reset))

        -- Rows 6 to zh: Per-core Matrix
        local avail_rows = math.max(1, zh - 5)
        local num_cols = 1
        if zw >= 150 and #cores >= 24 then
            num_cols = 6
        elseif zw >= 120 and #cores >= 16 then
            num_cols = 4
        elseif zw >= 80 and #cores >= 6 then
            num_cols = 3
        elseif zw >= 50 and #cores >= 2 then
            num_cols = 2
        end
        while num_cols < 6 and math.ceil(#cores / num_cols) > avail_rows do
            num_cols = num_cols + 1
        end

        local col_sub_w = math.floor((zw - 4 - num_cols) / num_cols)

        for i = 1, avail_rows do
            local line_parts = {}
            local has_content = false
            for col = 1, num_cols do
                local c_idx = (i - 1) * num_cols + col
                local c = cores[c_idx]
                if c then
                    has_content = true
                    local lbl = (col_sub_w >= 14) and string.format("C%-2d", c_idx - 1) or string.format("%2d", c_idx - 1)
                    local fixed_w = visual_len(lbl) + 1 + 5
                    local c_bar_w = math.max(3, col_sub_w - fixed_w)
                    local mbar = make_meter_bar(c.pct or 0, c_bar_w)
                    local sep = (col > 1) and " " or ""
                    table.insert(line_parts, string.format("%s%s%s%s %s%4.0f%%%s", sep, C.dim, lbl, C.reset, mbar, c.pct or 0, C.reset))
                end
            end
            if has_content then
                table.insert(out, draw_box_row(1, 5 + i, zw, table.concat(line_parts)))
            else
                table.insert(out, draw_box_row(1, 5 + i, zw, ""))
            end
        end

    elseif pane_idx == 2 then
        -- 2. Zoomed Memory & Storage Pane
        local mem = state.mem or (read_memory_stats and read_memory_stats() or { used_kb = 0, total_kb = 1, used_pct = 0, free_kb = 0, avail_kb = 0, cached_kb = 0, swap_used_kb = 0, swap_total_kb = 0, swap_pct = 0 })
        local spark_w = math.min(30, math.max(8, math.floor(zw * 0.22)))
        local mem_history = state.mem_history or { mem.used_pct or 0 }
        local mem_spark = make_sparkline(mem_history, spark_w, C.mem_used)
        local title = "[2] Memory & Storage (MAXIMIZED - Press [z] or [Esc] to Restore)"
        draw_pane(out, 1, 2, zw, zh, title, true, "Trend: " .. mem_spark)

        -- Row 3: Physical Memory RAM Bar
        local mem_cap_str = format_bytes(mem.used_kb or 0) .. " / " .. format_bytes(mem.total_kb or 1)
        local mem_pct_str = string.format("%5.1f%%", mem.used_pct or 0)
        local mem_fixed_w = 4 + 1 + visual_len(mem_pct_str) + 2 + visual_len(mem_cap_str)
        local mem_bar_w = math.max(6, (zw - 4) - mem_fixed_w)
        local mem_bar = make_meter_bar(mem.used_pct or 0, mem_bar_w, C.mem_used)
        table.insert(out, draw_box_row(1, 3, zw, string.format("  %sRAM %s%s %s%5.1f%%%s  %s%s%s",
            C.bold, C.reset, mem_bar, C.reset, mem.used_pct or 0, C.reset, C.dim, mem_cap_str, C.reset)))

        -- Row 4: Detailed RAM Breakdown
        local free_str = format_bytes(mem.free_kb or math.max(0, (mem.total_kb or 1) - (mem.used_kb or 0)))
        local avail_str = format_bytes(mem.avail_kb or 0)
        local cached_str = format_bytes(mem.cached_kb or 0)
        local buffers_str = format_bytes(mem.buffers_kb or 0)
        table.insert(out, draw_box_row(1, 4, zw, string.format("    %sFree:%s %s  │  %sAvailable:%s %s  │  %sCached:%s %s  │  %sBuffers:%s %s",
            C.dim, C.reset, free_str, C.dim, C.reset, avail_str, C.dim, C.reset, cached_str, C.dim, C.reset, buffers_str)))

        -- Row 5: Swap Memory SWP Bar
        local swp_cap_str = format_bytes(mem.swap_used_kb or 0) .. " / " .. format_bytes(mem.swap_total_kb or 0)
        local swp_pct_str = string.format("%5.1f%%", mem.swap_pct or 0)
        local swp_fixed_w = 4 + 1 + visual_len(swp_pct_str) + 2 + visual_len(swp_cap_str)
        local swp_bar_w = math.max(6, (zw - 4) - swp_fixed_w)
        local swap_bar = make_meter_bar(mem.swap_pct or 0, swp_bar_w, C.mem_swap)
        table.insert(out, draw_box_row(1, 5, zw, string.format("  %sSWP %s%s %s%5.1f%%%s  %s%s%s",
            C.bold, C.reset, swap_bar, C.reset, mem.swap_pct or 0, C.reset, C.dim, swp_cap_str, C.reset)))

        local row_y = 6
        -- GPU Telemetry (if present)
        local gpus = state.gpus or (read_gpu_stats and read_gpu_stats() or {})
        if #gpus > 0 then
            table.insert(out, draw_box_row(1, row_y, zw, string.format("  %sGPU Accelerators:%s", C.title_col, C.reset)))
            row_y = row_y + 1
            for _, g in ipairs(gpus) do
                if row_y >= zh then break end
                local g_temp = g.temp_c and string.format("  \27[1;38;2;251;191;36m%d°C\27[0m", g.temp_c) or ""
                local g_core = g.util_pct and string.format(" │ Core: \27[1;97m%d%%\27[0m", g.util_pct) or ""
                local g_freq = g.freq_ghz and string.format(" │ Freq: \27[1;97m%.2f GHz\27[0m", g.freq_ghz) or ""
                local g_name = g.name:gsub("^NVIDIA%s+", ""):gsub("^AMD%s+", "")
                table.insert(out, draw_box_row(1, row_y, zw, string.format("    %sGPU %s%s%s%s%s%s",
                    C.bold, C.reset, C.title_col, g_name, C.reset, g_temp, g_core, g_freq)))
                row_y = row_y + 1

                if not g.is_integrated and g.mem_total_kb and g.mem_total_kb > 0 and row_y < zh then
                    local vram_cap_str = format_bytes(g.mem_used_kb) .. " / " .. format_bytes(g.mem_total_kb)
                    local vram_pct = g.mem_used_pct or 0
                    local vram_fixed_w = 7 + 1 + 6 + 2 + visual_len(vram_cap_str)
                    local vram_bar_w = math.max(6, (zw - 6) - vram_fixed_w)
                    local vbar = make_meter_bar(vram_pct, vram_bar_w, C.mem_used)
                    table.insert(out, draw_box_row(1, row_y, zw, string.format("      %sVRAM%s %s %5.1f%%  %s%s%s",
                        C.bold, C.reset, vbar, vram_pct, C.dim, vram_cap_str, C.reset)))
                    row_y = row_y + 1
                end
            end
        end

        -- Storage Section
        if row_y < zh then
            table.insert(out, draw_box_row(1, row_y, zw, string.format("  %sStorage Filesystems & Disks:%s", C.title_col, C.reset)))
            row_y = row_y + 1
        end

        local storage = state.storage or (read_storage_stats and read_storage_stats(os.clock()) or { mounts = {}, read_speed = 0, write_speed = 0 })
        local num_mounts = #(storage.mounts or {})
        local use_dual = (num_mounts >= 2 and zw >= 70)

        if use_dual then
            local col_w = math.floor((zw - 4 - 3) / 2)
            local function format_col(m)
                if not m then return string.rep(" ", col_w) end
                local u_kb = math.floor(m.used_bytes / 1024)
                local t_kb = math.floor(m.total_bytes / 1024)
                local cap_str = format_bytes(u_kb) .. "/" .. format_bytes(t_kb)
                local pct_str = string.format("%3.0f%%", m.used_pct or 0)
                local mnt = truncate(m.mount, 10)
                local mnt_pad = mnt .. string.rep(" ", math.max(0, 10 - visual_len(mnt)))
                local fixed_w = 10 + 1 + 1 + visual_len(pct_str) + 1 + visual_len(cap_str)
                local bar_w = math.max(2, col_w - fixed_w)
                local bar = make_meter_bar(m.used_pct, bar_w)
                local col_txt = string.format("%s%s%s %s %s%s%s %s%s%s",
                    C.bold, mnt_pad, C.reset, bar, C.title_col, pct_str, C.reset, C.dim, cap_str, C.reset)
                local vlen = visual_len(col_txt)
                if vlen < col_w then col_txt = col_txt .. string.rep(" ", col_w - vlen)
                elseif vlen > col_w then col_txt = truncate(col_txt, col_w) end
                return col_txt
            end

            local m_idx = 1
            while m_idx <= num_mounts and row_y < zh do
                local m1 = storage.mounts[m_idx]
                local m2 = storage.mounts[m_idx + 1]
                m_idx = m_idx + 2
                table.insert(out, draw_box_row(1, row_y, zw, "  " .. format_col(m1) .. " " .. C.dim .. "│" .. C.reset .. " " .. format_col(m2)))
                row_y = row_y + 1
            end
        else
            for _, m in ipairs(storage.mounts or {}) do
                if row_y >= zh then break end
                local u_kb = math.floor(m.used_bytes / 1024)
                local t_kb = math.floor(m.total_bytes / 1024)
                local cap_str = format_bytes(u_kb) .. " / " .. format_bytes(t_kb)
                local pct_str = string.format("%5.1f%%", m.used_pct or 0)
                local mnt = truncate(m.mount, 12)
                local mnt_str = mnt .. string.rep(" ", math.max(0, 12 - visual_len(mnt)))
                local fixed_w = 12 + 1 + 1 + visual_len(pct_str) + 2 + visual_len(cap_str)
                local bar_w = math.max(4, (zw - 6) - fixed_w)
                local dbar = make_meter_bar(m.used_pct, bar_w)
                table.insert(out, draw_box_row(1, row_y, zw, string.format("    %s%s%s %s %s%s%s  %s%s%s",
                    C.bold, mnt_str, C.reset, dbar, C.title_col, pct_str, C.reset, C.dim, cap_str, C.reset)))
                row_y = row_y + 1
            end
        end

        if row_y < zh then
            local io_str = string.format("  %sDisk Throughput: %sRead %s%s │ %sWrite %s%s",
                C.dim, C.disk_read, format_rate(storage.read_speed or 0), C.reset,
                C.disk_write, format_rate(storage.write_speed or 0), C.reset)
            table.insert(out, draw_box_row(1, row_y, zw, io_str))
            row_y = row_y + 1
        end

        while row_y < zh do
            table.insert(out, draw_box_row(1, row_y, zw, ""))
            row_y = row_y + 1
        end

    elseif pane_idx == 3 then
        -- 3. Zoomed Network Pane
        local net = state.net or (read_network_stats and read_network_stats(os.clock()) or { active_iface = "lo", rx_rate = 0, tx_rate = 0, rx_total = 0, tx_total = 0, ifaces = {} })
        local title = string.format("[3] Network (MAXIMIZED - Press [z] or [Esc] to Restore) [Active: %s]", net.active_iface or "net")
        draw_pane(out, 1, 2, zw, zh, title, true)

        -- Row 3: Active Interface Banner
        table.insert(out, draw_box_row(1, 3, zw, string.format("  %sActive Interface:%s %s%s%s   │  %sTotal Download:%s %s   │  %sTotal Upload:%s %s",
            C.bold, C.reset, C.title_col, net.active_iface or "net", C.reset,
            C.bold, C.reset, format_bytes(math.floor((net.rx_total or 0) / 1024)),
            C.bold, C.reset, format_bytes(math.floor((net.tx_total or 0) / 1024)))))

        -- Row 4: Download Timeline & Sparkline
        local spark_w = math.max(15, zw - 45)
        local rx_history = state.rx_history or { net.rx_rate or 0 }
        local rx_spark = make_sparkline(rx_history, spark_w, C.net_rx)
        table.insert(out, draw_box_row(1, 4, zw, string.format("  %sRX (Download):%s %-12s %s  %sTotal:%s %s",
            C.bold, C.reset, format_rate(net.rx_rate or 0), rx_spark, C.dim, C.reset, format_bytes(math.floor((net.rx_total or 0) / 1024)))))

        -- Row 5: Upload Timeline & Sparkline
        local tx_history = state.tx_history or { net.tx_rate or 0 }
        local tx_spark = make_sparkline(tx_history, spark_w, C.net_tx)
        table.insert(out, draw_box_row(1, 5, zw, string.format("  %sTX (Upload):  %s %-12s %s  %sTotal:%s %s",
            C.bold, C.reset, format_rate(net.tx_rate or 0), tx_spark, C.dim, C.reset, format_bytes(math.floor((net.tx_total or 0) / 1024)))))

        -- Row 6: All Interfaces Header
        table.insert(out, draw_box_row(1, 6, zw, string.format("  %sAll Detected Network Interfaces:%s", C.title_col, C.reset)))
        table.insert(out, draw_box_row(1, 7, zw, string.format("    %s%-12s %-15s %-15s %-15s %-15s%s",
            C.table_hdr, "INTERFACE", "RX RATE", "RX TOTAL", "TX RATE", "TX TOTAL", C.reset)))

        local row_y = 8
        local ifaces = net.ifaces or {}
        for _, iface in ipairs(ifaces) do
            if row_y >= zh then break end
            local is_act = (iface.name == net.active_iface)
            local prefix = is_act and " ▶" or "  "
            local name_col = is_act and C.title_col or C.reset
            table.insert(out, draw_box_row(1, row_y, zw, string.format("  %s%s%-12s%s %-15s %-15s %-15s %-15s",
                prefix, name_col, iface.name, C.reset,
                format_rate(iface.rx_rate or 0), format_bytes(math.floor((iface.rx_total or 0) / 1024)),
                format_rate(iface.tx_rate or 0), format_bytes(math.floor((iface.tx_total or 0) / 1024)))))
            row_y = row_y + 1
        end

        while row_y < zh do
            table.insert(out, draw_box_row(1, row_y, zw, ""))
            row_y = row_y + 1
        end

    elseif pane_idx == 4 then
        -- 4. Zoomed Process Pane
        local procs = state.procs or (read_process_table and read_process_table(16384000, os.clock()) or {})
        local raw_total_procs = state.raw_total_procs or #procs
        local sel_proc = state.sel_proc or 1
        local sort_mode = state.sort_mode or "cpu"
        local sort_reverse = state.sort_reverse or false
        local in_tree_mode = state.in_tree_mode or false
        local filter_query = state.filter_query or ""
        local selected_category_idx = state.selected_category_idx or 1
        local category_counts = state.category_counts or count_process_categories(procs)

        local dir_sym = sort_reverse and "▲" or "▼"
        local sort_tag = string.format("[Sort: %s%s]", sort_mode:upper(), dir_sym)
        local tree_tag = in_tree_mode and "[Tree: ON]" or "[Tree: OFF]"
        local filter_tag = #filter_query > 0 and string.format("[Filter: /%s]", filter_query) or ""
        local active_cat = PROCESS_CATEGORIES[selected_category_idx] or PROCESS_CATEGORIES[1]
        local count_tag = (active_cat.id ~= "all" or #filter_query > 0)
            and string.format("%d/%d", #procs, raw_total_procs)
            or string.format("%d", raw_total_procs)
        local title = string.format("[4] Processes (MAXIMIZED - Press [z] or [Esc] to Restore): %s %s %s %s", count_tag, sort_tag, tree_tag, filter_tag)

        draw_pane(out, 1, 2, zw, zh, title, true)

        -- Row 3: Category Filter Tabs
        local pills_str = render_category_pills(PROCESS_CATEGORIES, selected_category_idx, category_counts, zw, C)
        table.insert(out, draw_box_row(1, 3, zw, pills_str))

        -- Row 4: Column Headers
        local table_header_y = 4
        local function col_hdr(name, mode_key, width)
            local is_active = (sort_mode == mode_key)
            local text = name
            if is_active then text = text .. (sort_reverse and "▲" or "▼") end
            if is_active then
                return string.format("%s%-" .. width .. "s%s", C.border_focus, text, C.table_hdr)
            else
                return string.format("%-" .. width .. "s", text)
            end
        end

        local show_ext_cols = (zw >= 80)
        local h_virt_str = ""
        local h_nice_str = ""
        if show_ext_cols then
            local h_virt = (sort_mode == "vsize" or sort_mode == "virt") and col_hdr("VIRT", "vsize", 9) or string.format("%-9s", "VIRT")
            local h_nice = (sort_mode == "nice") and col_hdr("NICE", "nice", 5) or string.format("%-5s", "NICE")
            h_virt_str = string.format(" %s", h_virt)
            h_nice_str = string.format(" %s", h_nice)
        end

        local h_pid     = col_hdr("PID", "pid", 7)
        local h_user    = col_hdr("USER", "user", 8)
        local h_cpu     = col_hdr("%CPU", "cpu", 7)
        local h_mem     = col_hdr("%MEM", "mem", 7)
        local h_res     = (sort_mode == "mem") and col_hdr("RES", "mem", 9) or string.format("%-9s", "RES")
        local h_th      = col_hdr("TH", "threads", 4)
        local h_stat    = string.format("%-5s", "STAT")
        local h_time    = col_hdr("TIME+", "time", 9)
        local h_cmd     = in_tree_mode and (C.title_col .. "PROCESS TREE [Space: Fold]" .. C.table_hdr) or col_hdr("COMMAND", "name", 15)

        local show_io_cols = (zw >= 105)
        local io_hdr_str = ""
        if show_io_cols then
            local h_ior = col_hdr("DISK R", "ior", 9)
            local h_iow = col_hdr("DISK W", "iow", 9)
            io_hdr_str = string.format(" %s %s", h_ior, h_iow)
        end

        local th_str = string.format("  %s%s %s %s %s %s%s %s%s %s %s%s %s%s",
            C.table_hdr, h_pid, h_user, h_cpu, h_mem, h_res, h_virt_str, h_th, h_nice_str, h_stat, h_time, io_hdr_str, h_cmd, C.reset)
        table.insert(out, draw_box_row(1, table_header_y, zw, th_str))

        local visible_rows = math.max(1, zh - 4)
        local page_offset = 1
        if sel_proc > visible_rows then
            page_offset = sel_proc - visible_rows + 1
        end

        for i = 1, visible_rows do
            local p_idx = page_offset + i - 1
            local pr = procs[p_idx]
            if pr then
                local is_sel = (p_idx == sel_proc)
                local cpu_val = (in_tree_mode and pr.is_collapsed and pr.total_sub_cpu and pr.total_sub_cpu > pr.cpu_pct) and pr.total_sub_cpu or (pr.cpu_pct or 0)
                local res_val = (in_tree_mode and pr.is_collapsed and pr.total_sub_res and pr.total_sub_res > pr.res_kb) and pr.total_sub_res or (pr.res_kb or 0)
                local cpu_col = cpu_val > 50 and C.cpu_high or (cpu_val > 15 and C.cpu_mid or C.reset)
                local user_str = truncate(pr.username or "user", 8)

                local cmd_display
                if in_tree_mode then
                    local fold_badge = ""
                    if pr.has_children then
                        fold_badge = pr.is_collapsed and string.format("\27[1;33m[+%d]\27[0m ", pr.child_count or 0) or "\27[36m[-]\27[0m "
                    end
                    cmd_display = C.tree_branch .. (pr.tree_prefix or "") .. C.reset .. fold_badge .. (pr.comm or "")
                else
                    cmd_display = pr.cmdline or pr.comm or ""
                end

                local io_val_str = ""
                if show_io_cols then
                    io_val_str = string.format(" %-9s %-9s", format_rate(pr.io_read_rate or 0), format_rate(pr.io_write_rate or 0))
                end

                local time_str = format_time_plus(pr.cpu_time_sec or 0)
                local virt_col_str = ""
                local nice_col_str = ""
                if show_ext_cols then
                    local virt_str = format_bytes(pr.vsize_kb or 0)
                    local nice_val = pr.nice or 0
                    virt_col_str = string.format(" %-9s", virt_str)
                    nice_col_str = string.format(" %-5d", nice_val)
                end
                local badge_str = get_state_badge(pr.state, is_sel, C)
                local row_content = string.format("%-7d %-8s %s%5.1f%%%s %5.1f%% %-9s%s %-4d%s %s %s%s %s",
                    pr.pid or 0, user_str, cpu_col, cpu_val, (is_sel and C.sel_bg or C.reset), pr.mem_pct or 0, format_bytes(res_val), virt_col_str, pr.threads or 1, nice_col_str, badge_str, time_str, io_val_str, cmd_display)

                if is_sel then
                    table.insert(out, draw_box_row(1, table_header_y + i, zw, C.sel_bg .. "▶ " .. row_content .. C.reset))
                else
                    table.insert(out, draw_box_row(1, table_header_y + i, zw, "  " .. row_content))
                end
            else
                table.insert(out, draw_box_row(1, table_header_y + i, zw, ""))
            end
        end
    end
end

local function render_zoomed_pane_frame(pane_idx, state, term_w, term_h)
    local out = {}
    render_zoomed_pane(out, pane_idx, state, term_w, term_h)
    return table.concat(out)
end

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
luatop.lua - High-Performance Linux & Windows System Monitor
Usage:
  luajit luatop.lua [options]

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
  R                     Open process renice modal
  :, !                  Open process diagnostic command runner
  c, m, p, n, u, s, d, e   Sort by CPU, Mem, PID, Name, User, Threads, Disk I/O, TIME+
  r                     Toggle sort order (Ascending / Descending)
  T                     Cycle color themes on the fly
  Space                 Pause / resume live monitoring (or fold/unfold tree)
  +, -                  Adjust update interval
  ?, h                  Display interactive help dialog
  q, Esc                Quit / Close modal
]])
            return 0
        elseif a == "--version" or a == "-v" then
            print("luatop.lua v2.2.0 - High-Performance LuaJIT FFI System Monitor")
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

    local os_name = read_os_info and read_os_info() or "System"
    local raw_cpu_model = read_cpu_model and read_cpu_model() or "CPU"
    local cpu_model_clean = raw_cpu_model:gsub("^Intel%s+", ""):gsub("^AMD%s+", ""):gsub("%s*Processor", ""):gsub("%s*CPU", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local cpu_model_short = cpu_model_clean:gsub("%s*@.*", ""):gsub("^Core%s+", "")

    local sort_mode = "cpu" -- "cpu", "mem", "pid", "name", "user", "threads"
    local sort_reverse = false
    local in_tree_mode = arg_tree
    local cpu_view_mode = "auto" -- "auto", "summary", "detail"
    local sel_proc = 1
    local filter_query = ""
    local in_search_mode = false
    local is_paused = false
    local refresh_interval_ms = arg_interval or 1000
    local collapsed_pids = {}
    local sync_updates = not is_windows or os.getenv("WT_SESSION") ~= nil
        or os.getenv("TERM_PROGRAM") == "vscode"
        or os.getenv("TERM_PROGRAM") == "WezTerm"
        or os.getenv("WEZTERM_PANE") ~= nil

    -- Modals state
    local show_help = false
    local show_inspector = false
    local show_signal_modal = false
    local show_renice_modal = false
    local show_diagnostic_modal = false
    local sel_signal_idx = 1
    local sel_diagnostic_preset = 1
    local diagnostic_custom_cmd = ""
    local diagnostic_is_editing = false
    local renice_val = 0
    local status_flash_msg = ""
    local status_flash_expiry = 0

    local last_w, last_h = get_terminal_size()
    local last_top_h = math.min(12, math.max(8, math.floor(last_h * 0.32)))
    local last_visible_rows = math.max(1, last_h - last_top_h - 3 - 5)
    local last_left_w = math.floor(last_w * 0.50)
    local last_proc_y = last_top_h + 5
    local focused_pane = 4 -- 1: CPU, 2: Memory & Storage, 3: Network, 4: Processes
    local zoomed_pane = nil -- nil: 4-pane grid; 1..4: zoomed pane
    local selected_category_idx = 1
    local category_counts = { all = 0, user = 0, system = 0, active = 0, zombies = 0 }
    local last_pills_y = 0
    local last_has_pills = false
    local raw_total_procs = 0
    local cpu_history = {}
    local mem_history = {}
    local gpu_history = {}
    local rx_history = {}
    local tx_history = {}
    local max_history = 35

    io.write("\27[H\27[2J")
    io.flush()

    local next_refresh_time = 0
    local procs = {}

    -- Warm up telemetry (CPU and processes) so the very first frame renders realistic percentages
    pcall(function()
        read_cpu_stats()
        if is_windows then
            kernel32.Sleep(40)
        else
            ffi.C.usleep(40000)
        end
    end)

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

            if type(k) == "table" and k.type == "mouse" then
                if k.btn == 64 then
                    -- Wheel Up: scroll process list up
                    sel_proc = math.max(1, sel_proc - 3)
                elseif k.btn == 65 then
                    -- Wheel Down: scroll process list down
                    sel_proc = sel_proc + 3
                elseif k.btn == 0 and not k.release then
                    -- Left Click Press
                    if show_diagnostic_modal then
                        local mw = math.min(84, term_w - 4)
                        local compact = (term_h < 17)
                        local mh = compact and 12 or 14
                        local mx = math.floor((term_w - mw) / 2)
                        local my = math.floor((term_h - mh) / 2)
                        local presets = get_diagnostic_presets()
                        local header_offset = compact and 3 or 4
                        local preset_clicked = false

                        for p_i = 1, #presets do
                            local row_y = my + header_offset + p_i
                            if k.y == row_y and k.x >= mx and k.x <= mx + mw then
                                sel_diagnostic_preset = p_i
                                diagnostic_custom_cmd = presets[p_i].cmd
                                diagnostic_is_editing = false
                                preset_clicked = true
                                break
                            end
                        end

                        if not preset_clicked then
                            if k.y == my + 1 and k.x >= mx and k.x <= mx + mw then
                                diagnostic_is_editing = true
                            elseif k.y == my + mh - 2 and k.x >= mx and k.x <= mx + mw then
                                local pr = procs[sel_proc] or { pid = 0, comm = "process", username = "user" }
                                local cmd_to_run = (diagnostic_custom_cmd and #diagnostic_custom_cmd > 0)
                                    and diagnostic_custom_cmd
                                    or presets[sel_diagnostic_preset].cmd
                                show_diagnostic_modal = false
                                execute_diagnostic_command(cmd_to_run, pr)
                                io.write("\27[H\27[2J")
                                next_refresh_time = 0
                            elseif k.x < mx or k.x > mx + mw or k.y < my or k.y > my + mh then
                                show_diagnostic_modal = false
                            end
                        end
                    elseif show_help or show_inspector or show_signal_modal then
                        show_help = false
                        show_inspector = false
                        show_signal_modal = false
                    elseif zoomed_pane then
                        if k.y == 2 then
                            -- Clicked title bar of zoomed pane: unzoom
                            zoomed_pane = nil
                            status_flash_msg = "Restored 4-Pane Grid"
                            status_flash_expiry = os.clock() + 1.5
                        elseif zoomed_pane == 4 then
                            local pills_y = 3
                            local table_header_y = 4
                            local visible_rows = last_visible_rows
                            local show_io = (term_w >= 105)

                            if k.y == pills_y then
                                local clicked_cat = get_category_tab_at_x(k.x, PROCESS_CATEGORIES, category_counts, selected_category_idx)
                                if clicked_cat then
                                    selected_category_idx = clicked_cat
                                    sel_proc = 1
                                    local cat = PROCESS_CATEGORIES[selected_category_idx]
                                    status_flash_msg = string.format("Category: [%s] (%d processes)", cat.label, category_counts[cat.id] or 0)
                                    status_flash_expiry = os.clock() + 1.5
                                end
                            elseif k.y == table_header_y then
                                local new_mode = nil
                                if k.x >= 3 and k.x <= 9 then new_mode = "pid"
                                elseif k.x >= 11 and k.x <= 18 then new_mode = "user"
                                elseif k.x >= 20 and k.x <= 26 then new_mode = "cpu"
                                elseif k.x >= 28 and k.x <= 34 then new_mode = "mem"
                                elseif k.x >= 36 and k.x <= 44 then new_mode = "mem"
                                elseif k.x >= 46 and k.x <= 54 then new_mode = "vsize"
                                elseif k.x >= 56 and k.x <= 59 then new_mode = "threads"
                                elseif k.x >= 61 and k.x <= 65 then new_mode = "nice"
                                elseif k.x >= 73 and k.x <= 81 then new_mode = "time"
                                elseif show_io and k.x >= 83 and k.x <= 91 then new_mode = "ior"
                                elseif show_io and k.x >= 93 and k.x <= 101 then new_mode = "iow"
                                elseif (show_io and k.x >= 103) or (not show_io and k.x >= 83) then
                                    new_mode = "name"
                                end

                                if new_mode then
                                    if sort_mode == new_mode then
                                        sort_reverse = not sort_reverse
                                    else
                                        sort_mode = new_mode
                                        sort_reverse = false
                                    end
                                    status_flash_msg = string.format("Sort: %s (%s)", sort_mode:upper(), sort_reverse and "ASC" or "DESC")
                                    status_flash_expiry = os.clock() + 2.0
                                end
                            elseif k.y > table_header_y and k.y <= table_header_y + visible_rows then
                                local page_offset = 1
                                if sel_proc > visible_rows then
                                    page_offset = sel_proc - visible_rows + 1
                                end
                                local target_idx = page_offset + (k.y - table_header_y - 1)
                                if target_idx >= 1 and target_idx <= #procs then
                                    if target_idx == sel_proc then
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
                                            show_inspector = true
                                        end
                                    else
                                        sel_proc = target_idx
                                    end
                                end
                            end
                        end
                    else
                        local net_h = 3
                        local proc_y = last_proc_y
                        local pills_y = proc_y + 1
                        local table_header_y = last_has_pills and (proc_y + 2) or (proc_y + 1)
                        local visible_rows = last_visible_rows
                        local show_io = (term_w >= 115)

                        -- Determine clicked pane
                        if k.y >= 2 and k.y <= last_top_h + 1 then
                            focused_pane = (k.x <= last_left_w) and 1 or 2
                        elseif k.y >= last_top_h + 2 and k.y <= last_top_h + 1 + net_h then
                            focused_pane = 3
                        elseif k.y >= proc_y and k.y <= term_h - 1 then
                            focused_pane = 4
                        end

                        if last_has_pills and k.y == pills_y then
                            local clicked_cat = get_category_tab_at_x(k.x, PROCESS_CATEGORIES, category_counts, selected_category_idx)
                            if clicked_cat then
                                selected_category_idx = clicked_cat
                                sel_proc = 1
                                local cat = PROCESS_CATEGORIES[selected_category_idx]
                                status_flash_msg = string.format("Category: [%s] (%d processes)", cat.label, category_counts[cat.id] or 0)
                                status_flash_expiry = os.clock() + 1.5
                            end
                        elseif k.y == table_header_y then
                            -- Clicked column header
                            local new_mode = nil
                            if k.x >= 3 and k.x <= 9 then new_mode = "pid"
                            elseif k.x >= 11 and k.x <= 18 then new_mode = "user"
                            elseif k.x >= 20 and k.x <= 26 then new_mode = "cpu"
                            elseif k.x >= 28 and k.x <= 34 then new_mode = "mem"
                            elseif k.x >= 36 and k.x <= 44 then new_mode = "mem"
                            elseif k.x >= 46 and k.x <= 49 then new_mode = "threads"
                            elseif k.x >= 57 and k.x <= 65 then new_mode = "time"
                            elseif show_io and k.x >= 67 and k.x <= 75 then new_mode = "ior"
                            elseif show_io and k.x >= 77 and k.x <= 85 then new_mode = "iow"
                            elseif (show_io and k.x >= 87) or (not show_io and k.x >= 67) then
                                new_mode = "name"
                            end

                            if new_mode then
                                if sort_mode == new_mode then
                                    sort_reverse = not sort_reverse
                                else
                                    sort_mode = new_mode
                                    sort_reverse = false
                                end
                                status_flash_msg = string.format("Sort: %s (%s)", sort_mode:upper(), sort_reverse and "ASC" or "DESC")
                                status_flash_expiry = os.clock() + 2.0
                            end
                        elseif k.y > table_header_y and k.y <= table_header_y + visible_rows then
                            -- Clicked a process row
                            local page_offset = 1
                            if sel_proc > visible_rows then
                                page_offset = sel_proc - visible_rows + 1
                            end
                            local target_idx = page_offset + (k.y - table_header_y - 1)
                            if target_idx >= 1 and target_idx <= #procs then
                                if target_idx == sel_proc then
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
                                        show_inspector = true
                                    end
                                else
                                    sel_proc = target_idx
                                end
                            end
                        end
                    end
                end
            elseif show_help then
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
                elseif k == "R" or k == "r" then
                    show_inspector = false
                    local pr = procs[sel_proc]
                    if pr then
                        renice_val = pr.nice or 0
                        show_renice_modal = true
                    end
                elseif k == ":" or k == "!" or k == "o" or k == "O" then
                    show_inspector = false
                    show_diagnostic_modal = true
                    sel_diagnostic_preset = 1
                    diagnostic_custom_cmd = get_diagnostic_presets()[1].cmd
                    diagnostic_is_editing = false
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
            elseif show_renice_modal then
                if k == "ESC" or k == "q" then
                    show_renice_modal = false
                elseif k == "LEFT" or k == "DOWN" or k == "h" or k == "j" or k == "-" then
                    renice_val = math.max(-20, renice_val - 1)
                elseif k == "RIGHT" or k == "UP" or k == "l" or k == "k" or k == "+" or k == "=" then
                    renice_val = math.min(19, renice_val + 1)
                elseif k == "ENTER" then
                    show_renice_modal = false
                    local pr = procs[sel_proc]
                    if pr then
                        local ok = renice_process(pr.pid, renice_val)
                        if ok then
                            status_flash_msg = string.format("Reniced PID %d (%s) to %d", pr.pid, pr.comm, renice_val)
                            pr.nice = renice_val
                        else
                            status_flash_msg = string.format("Failed to renice PID %d (Permission denied? Root required)", pr.pid)
                        end
                        status_flash_expiry = os.clock() + 3.0
                    end
                end
            elseif show_diagnostic_modal then
                local presets = get_diagnostic_presets()
                if k == "ESC" or (k == "q" and not diagnostic_is_editing) then
                    show_diagnostic_modal = false
                    diagnostic_custom_cmd = ""
                    diagnostic_is_editing = false
                elseif k == "ENTER" then
                    local pr = procs[sel_proc] or { pid = 0, comm = "process", username = "user" }
                    local cmd_to_run = (diagnostic_custom_cmd and #diagnostic_custom_cmd > 0)
                        and diagnostic_custom_cmd
                        or presets[sel_diagnostic_preset].cmd
                    show_diagnostic_modal = false
                    execute_diagnostic_command(cmd_to_run, pr)
                    io.write("\27[H\27[2J")
                    next_refresh_time = 0
                elseif (k == "1" or k == "2" or k == "3" or k == "4" or k == "5") and not diagnostic_is_editing then
                    local p_num = tonumber(k)
                    if p_num and p_num <= #presets then
                        sel_diagnostic_preset = p_num
                        diagnostic_custom_cmd = presets[p_num].cmd
                        local pr = procs[sel_proc] or { pid = 0, comm = "process", username = "user" }
                        show_diagnostic_modal = false
                        execute_diagnostic_command(diagnostic_custom_cmd, pr)
                        io.write("\27[H\27[2J")
                        next_refresh_time = 0
                    end
                elseif k == "UP" or (k == "k" and not diagnostic_is_editing) then
                    sel_diagnostic_preset = (sel_diagnostic_preset == 1) and #presets or (sel_diagnostic_preset - 1)
                    diagnostic_custom_cmd = presets[sel_diagnostic_preset].cmd
                    diagnostic_is_editing = false
                elseif k == "DOWN" or (k == "j" and not diagnostic_is_editing) then
                    sel_diagnostic_preset = (sel_diagnostic_preset % #presets) + 1
                    diagnostic_custom_cmd = presets[sel_diagnostic_preset].cmd
                    diagnostic_is_editing = false
                elseif k == "BACKSPACE" then
                    diagnostic_is_editing = true
                    if #diagnostic_custom_cmd > 0 then
                        diagnostic_custom_cmd = diagnostic_custom_cmd:sub(1, -2)
                    end
                elseif k == "SPACE" then
                    diagnostic_is_editing = true
                    diagnostic_custom_cmd = diagnostic_custom_cmd .. " "
                elseif #k == 1 and k:byte() >= 32 and k:byte() <= 126 then
                    diagnostic_is_editing = true
                    diagnostic_custom_cmd = diagnostic_custom_cmd .. k
                end
            elseif in_search_mode then
                if k == "SPACE" then k = " " end
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
                    if zoomed_pane then
                        zoomed_pane = nil
                        status_flash_msg = "Restored 4-Pane Grid"
                        status_flash_expiry = os.clock() + 1.5
                    elseif #filter_query > 0 then
                        filter_query = ""
                    end
                elseif k == "TAB" or k == "\t" then
                    focused_pane = (focused_pane % 4) + 1
                    if zoomed_pane then
                        zoomed_pane = focused_pane
                    end
                    local pane_names = { "CPU", "Memory & Storage", "Network", "Processes" }
                    status_flash_msg = string.format("Focused [%d] %s", focused_pane, pane_names[focused_pane] or "")
                    status_flash_expiry = os.clock() + 1.5
                elseif k == "SHIFT_TAB" then
                    focused_pane = (focused_pane == 1) and 4 or (focused_pane - 1)
                    if zoomed_pane then
                        zoomed_pane = focused_pane
                    end
                    local pane_names = { "CPU", "Memory & Storage", "Network", "Processes" }
                    status_flash_msg = string.format("Focused [%d] %s", focused_pane, pane_names[focused_pane] or "")
                    status_flash_expiry = os.clock() + 1.5
                elseif k == "1" or k == "2" or k == "3" or k == "4" then
                    local p_num = tonumber(k)
                    focused_pane = p_num
                    if zoomed_pane then
                        zoomed_pane = p_num
                    end
                    local pane_names = { "CPU", "Memory & Storage", "Network", "Processes" }
                    status_flash_msg = string.format("Focused [%d] %s", focused_pane, pane_names[focused_pane] or "")
                    status_flash_expiry = os.clock() + 1.5
                elseif k == "z" or k == "f" then
                    if zoomed_pane then
                        zoomed_pane = nil
                        status_flash_msg = "Restored 4-Pane Grid"
                    else
                        zoomed_pane = focused_pane
                        local pane_names = { "CPU", "Memory & Storage", "Network", "Processes" }
                        status_flash_msg = string.format("Maximized [%d] %s (Press [z] or [Esc] to Restore)", zoomed_pane, pane_names[zoomed_pane] or "")
                    end
                    status_flash_expiry = os.clock() + 2.0
                elseif k == "[" then
                    selected_category_idx = (selected_category_idx == 1) and #PROCESS_CATEGORIES or (selected_category_idx - 1)
                    sel_proc = 1
                    local cat = PROCESS_CATEGORIES[selected_category_idx]
                    status_flash_msg = string.format("Category: [%s] (%d processes)", cat.label, category_counts[cat.id] or 0)
                    status_flash_expiry = os.clock() + 1.5
                elseif k == "]" then
                    selected_category_idx = (selected_category_idx % #PROCESS_CATEGORIES) + 1
                    sel_proc = 1
                    local cat = PROCESS_CATEGORIES[selected_category_idx]
                    status_flash_msg = string.format("Category: [%s] (%d processes)", cat.label, category_counts[cat.id] or 0)
                    status_flash_expiry = os.clock() + 1.5
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
                elseif k == "SPACE" then
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
                elseif k == "C" then
                    if cpu_view_mode == "auto" then
                        cpu_view_mode = "summary"
                    elseif cpu_view_mode == "summary" then
                        cpu_view_mode = "detail"
                    else
                        cpu_view_mode = "auto"
                    end
                    status_flash_msg = string.format("CPU view: %s", cpu_view_mode:upper())
                    status_flash_expiry = os.clock() + 2.0
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
                elseif k == "e" then
                    if sort_mode == "time" then
                        sort_reverse = not sort_reverse
                    else
                        sort_mode = "time"
                        sort_reverse = false
                    end
                    status_flash_msg = string.format("Sort: TIME+ (%s)", sort_reverse and "ASC" or "DESC")
                    status_flash_expiry = os.clock() + 2.0
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
                elseif k == "R" or k == "F7" or k == "F8" then
                    local pr = procs[sel_proc]
                    if pr then
                        renice_val = pr.nice or 0
                        show_renice_modal = true
                    end
                elseif k == ":" or k == "!" or k == "o" or k == "O" then
                    show_diagnostic_modal = true
                    sel_diagnostic_preset = 1
                    diagnostic_custom_cmd = get_diagnostic_presets()[1].cmd
                    diagnostic_is_editing = false
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
            local gpus = read_gpu_stats and read_gpu_stats() or {}
            procs = read_process_table(mem.total_kb or 1, curr_clock)
            local load_str, task_str = read_loadavg(overall_cpu, #procs)

            -- Sparklines history
            table.insert(cpu_history, overall_cpu)
            if #cpu_history > max_history then table.remove(cpu_history, 1) end

            table.insert(mem_history, mem.used_pct)
            if #mem_history > max_history then table.remove(mem_history, 1) end

            if #gpus > 0 and gpus[1].mem_used_pct then
                table.insert(gpu_history, gpus[1].mem_used_pct)
                if #gpu_history > max_history then table.remove(gpu_history, 1) end
            end

            table.insert(rx_history, net.rx_rate)
            if #rx_history > max_history then table.remove(rx_history, 1) end

            table.insert(tx_history, net.tx_rate)
            if #tx_history > max_history then table.remove(tx_history, 1) end

            -- Category metrics & counts across all discovered processes
            raw_total_procs = #procs
            category_counts = count_process_categories(procs)
            local zombie_count = category_counts.zombies

            -- Filter processes by active category tab
            local active_cat = PROCESS_CATEGORIES[selected_category_idx] or PROCESS_CATEGORIES[1]
            if active_cat.id ~= "all" then
                local cat_procs = {}
                for _, pr in ipairs(procs) do
                    if matches_process_category(pr, active_cat.id) then
                        table.insert(cat_procs, pr)
                    end
                end
                procs = cat_procs
            end

            -- Filter processes via smart filter engine
            if #filter_query > 0 then
                local filtered = {}
                for _, pr in ipairs(procs) do
                    if match_smart_filter(pr, filter_query) then
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
                    elseif sort_mode == "time" then val_a, val_b = (a.cpu_time_sec or 0), (b.cpu_time_sec or 0)
                    elseif sort_mode == "elapsed" then val_a, val_b = (a.elapsed_sec or 0), (b.elapsed_sec or 0)
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

            -- Responsive Top Banner
            local pause_ind = is_paused and "\27[1;38;2;239;68;68m [PAUSED]\27[0m" or ""
            local theme_ind = string.format(" │ Theme: \27[38;2;125;207;255m%s\27[0m", C.name)
            local zombie_str = zombie_count > 0 and string.format(" │ \27[1;38;2;247;118;142m⚠ %d ZOMBIE%s\27[0m", zombie_count, zombie_count > 1 and "S" or "") or ""
            local rate_str = string.format(" │ \27[1;93m%.1fs\27[0m%s", refresh_interval_ms / 1000.0, pause_ind)
            local os_badge = string.format(" │ \27[1;38;2;167;139;250m%s\27[0m", os_name)

            local header_content
            if term_w >= 120 then
                local freq_ghz_str = freq_ghz and string.format(" │ CPU: \27[1;97m%.2f GHz\27[0m", freq_ghz) or ""
                local temp_str = temp_c and string.format(" (\27[1;38;2;251;191;36m%.0f°C\27[0m)", temp_c) or ""
                local gpu_hdr = ""
                if #gpus > 0 then
                    local g0 = gpus[1]
                    local g0_short = g0.name:gsub("^NVIDIA%s+", ""):gsub("^AMD%s+", "")
                    g0_short = truncate(g0_short, 16)
                    local g0_temp = g0.temp_c and string.format(" (\27[1;38;2;251;191;36m%d°C\27[0m)", g0.temp_c) or ""
                    gpu_hdr = string.format(" │ GPU: \27[1;97m%s\27[0m%s", g0_short, g0_temp)
                end
                header_content = string.format("  \27[1;38;2;56;189;248m⚡ LUATOP v2.2\27[0m%s │ Load: \27[1;97m%s\27[0m │ Tasks: \27[1;97m%s\27[0m%s%s%s%s%s%s",
                    os_badge, load_str, task_str, zombie_str, freq_ghz_str, temp_str, gpu_hdr, theme_ind, rate_str)
            elseif term_w >= 90 then
                local short_tasks = task_str:match("^[^,]+") or task_str
                header_content = string.format("  \27[1;38;2;56;189;248m⚡ LUATOP v2.2\27[0m%s │ Load: \27[1;97m%s\27[0m │ Tasks: \27[1;97m%s\27[0m%s%s",
                    os_badge, load_str, short_tasks, theme_ind, rate_str)
            else
                local short_load = load_str:match("^[^,]+") or load_str
                local proc_cnt = task_str:match("^(%d+) procs") or tostring(#procs)
                header_content = string.format("  \27[1;38;2;56;189;248m⚡ LUATOP\27[0m │ Load: \27[1;97m%s\27[0m │ %sp%s%s",
                    short_load, proc_cnt, theme_ind, rate_str)
            end
            table.insert(out, string.format("\27[1;1H%s\27[K", truncate(header_content, term_w)))

            if zoomed_pane then
                last_top_h = 0
                last_left_w = term_w
                last_proc_y = 2
                last_visible_rows = (zoomed_pane == 4) and math.max(1, term_h - 6) or 1
                local state = {
                    cores = cores,
                    overall_cpu = overall_cpu,
                    cpu_history = cpu_history,
                    temp_c = temp_c,
                    freq_ghz = freq_ghz,
                    cpu_model_clean = cpu_model_clean,
                    cpu_model_short = cpu_model_short,
                    cpu_view_mode = cpu_view_mode,
                    mem = mem,
                    mem_history = mem_history,
                    storage = storage,
                    gpus = gpus,
                    gpu_history = gpu_history,
                    net = net,
                    rx_history = rx_history,
                    tx_history = tx_history,
                    procs = procs,
                    raw_total_procs = raw_total_procs,
                    selected_category_idx = selected_category_idx,
                    category_counts = category_counts,
                    sel_proc = sel_proc,
                    sort_mode = sort_mode,
                    sort_reverse = sort_reverse,
                    in_tree_mode = in_tree_mode,
                    filter_query = filter_query,
                }
                render_zoomed_pane(out, zoomed_pane, state, term_w, term_h)
            else
                local left_w = math.floor(term_w * 0.50)
                local right_w = term_w - left_w
                last_left_w = left_w

                local num_mounts = #storage.mounts
                local use_dual_col = (num_mounts >= 4 and right_w >= 56)
                local storage_rows = use_dual_col and math.ceil(num_mounts / 2) or num_mounts
                local gpu_rows = 0
                for _, g in ipairs(gpus) do
                    gpu_rows = gpu_rows + 1
                    if not g.is_integrated and g.mem_total_kb and g.mem_total_kb > 0 then
                        gpu_rows = gpu_rows + 1
                    end
                end
                local right_content_bottom = 6 + gpu_rows + storage_rows
                local core_rows = math.max(1, math.ceil(#cores / 2))
                if left_w < 36 then
                    core_rows = #cores
                elseif left_w >= 90 and #cores > 3 * (right_content_bottom - 2) then
                    core_rows = math.ceil(#cores / 4)
                elseif left_w >= 60 and #cores > 2 * (right_content_bottom - 2) then
                    core_rows = math.ceil(#cores / 3)
                end
                local min_process_h = 8
                local max_top_h = math.max(6, term_h - 3 - 2 - min_process_h)
                local detail_fits = (2 + core_rows) <= max_top_h
                local show_cpu_summary = cpu_view_mode == "summary"
                    or (cpu_view_mode == "auto" and not detail_fits)
                local cpu_summary_rows = 4
                local required_top_h = math.max(6, right_content_bottom,
                    show_cpu_summary and (2 + cpu_summary_rows) or (2 + core_rows))
                local top_h = math.min(required_top_h, max_top_h)
                local net_h = 3
                local bot_h = term_h - top_h - net_h - 2
                last_top_h = top_h
                last_proc_y = top_h + 2 + net_h
                last_has_pills = (bot_h >= 7)
                last_pills_y = last_proc_y + 1
                last_visible_rows = last_has_pills and math.max(1, bot_h - 4) or math.max(1, bot_h - 3)

                -- 1. CPU Pane (Top Left)
                local act1 = (focused_pane == 1) and " (Active)" or ""
                local cpu_spark_w = math.min(14, math.max(6, math.floor(left_w * 0.18)))
                local cpu_spark = make_sparkline(cpu_history, cpu_spark_w, C.cpu_low)
                local cpu_title
                local c_temp, c_freq = read_cpu_sensors()
                local sensor_str = ""
                if c_temp or c_freq then
                    local parts = {}
                    if c_temp then table.insert(parts, string.format("%.0f°C", c_temp)) end
                    if c_freq then table.insert(parts, string.format("%.2fGHz", c_freq)) end
                    sensor_str = " [" .. table.concat(parts, " ") .. "]"
                end
                if show_cpu_summary then
                    cpu_title = string.format("[1] CPU Summary%s: %.1f%%%s", act1, overall_cpu, sensor_str)
                elseif left_w >= 54 and #cpu_model_clean > 0 then
                    cpu_title = string.format("[1] CPU%s: %.1f%%%s [%s]", act1, overall_cpu, sensor_str, truncate(cpu_model_clean, left_w - 36))
                elseif left_w >= 40 and #cpu_model_short > 0 then
                    cpu_title = string.format("[1] CPU%s: %.1f%%%s [%s]", act1, overall_cpu, sensor_str, truncate(cpu_model_short, left_w - 30))
                else
                    cpu_title = string.format("[1] CPU%s: %.1f%%%s", act1, overall_cpu, sensor_str)
                end
                local cpu_header_right = "Usage: " .. cpu_spark
                draw_pane(out, 1, 2, left_w, top_h, cpu_title, (focused_pane == 1), cpu_header_right)

            if show_cpu_summary then
                local min_pct, max_pct = 100, 0
                local busy_cores = 0
                local total_pct = 0
                for _, c in ipairs(cores) do
                    min_pct = math.min(min_pct, c.pct)
                    max_pct = math.max(max_pct, c.pct)
                    total_pct = total_pct + c.pct
                    if c.pct >= 1 then busy_cores = busy_cores + 1 end
                end
                local avg_pct = #cores > 0 and total_pct / #cores or 0
                local summary_lines = {
                    string.format("  Overall: %5.1f%%   Avg/core: %5.1f%%", overall_cpu, avg_pct),
                    string.format("  Min/core: %5.1f%%   Max/core: %5.1f%%", min_pct, max_pct),
                    string.format("  Busy cores: %d/%d   View: %s", busy_cores, #cores, cpu_view_mode:upper()),
                    string.format("  Per-core details hidden (%d cores); press C to cycle view", #cores)
                }
                for i, line in ipairs(summary_lines) do
                    table.insert(out, draw_box_row(1, 2 + i, left_w, line))
                end
            else
                -- Dynamic core columns based on left_w and core count.
                local avail_rows = math.max(1, top_h - 2)
                local num_cols = left_w < 36 and 1
                    or (left_w >= 90 and #cores > 3 * avail_rows and 4
                    or (left_w >= 60 and #cores > 2 * avail_rows and 3 or 2))
                local col_sub_w = math.floor((left_w - 4 - num_cols) / num_cols)

                for i = 1, avail_rows do
                    local line_parts = {}
                    for col = 1, num_cols do
                        local c_idx = (i - 1) * num_cols + col
                        local c = cores[c_idx]
                        if c then
                            local lbl = (col_sub_w >= 14) and string.format("C%-2d", c_idx - 1) or string.format("%2d", c_idx - 1)
                            local fixed_w = visual_len(lbl) + 1 + 5
                            local bar_w = math.max(3, col_sub_w - fixed_w)
                            local mbar = make_meter_bar(c.pct, bar_w)
                            local sep = (col > 1) and " " or ""
                            table.insert(line_parts, string.format("%s%s%s%s %s%4.0f%%%s", sep, C.dim, lbl, C.reset, mbar, c.pct, C.reset))
                        end
                    end
                    table.insert(out, draw_box_row(1, 2 + i, left_w, table.concat(line_parts)))
                end
            end

            -- 2. Memory, GPU & Storage Pane (Top Right)
            local act2 = (focused_pane == 2) and " (Active)" or ""
            local pane_title = (#gpus > 0) and ("Memory, GPU & Storage" .. act2) or ("Memory & Storage" .. act2)
            if #gpus > 0 and right_w < 50 then pane_title = "Memory & GPU" .. act2 end
            local spark_w = math.max(4, right_w - (visual_len(pane_title) + 18))
            local mem_spark = make_sparkline(mem_history, spark_w, C.mem_used)
            draw_pane(out, left_w + 1, 2, right_w, top_h, "[2] " .. pane_title, (focused_pane == 2), "Trend: " .. mem_spark)

            local mem_cap_str = format_bytes(mem.used_kb) .. "/" .. format_bytes(mem.total_kb)
            local mem_pct_str = string.format("%5.1f%%", mem.used_pct)
            local mem_fixed_w = 4 + 1 + visual_len(mem_pct_str) + 1 + visual_len(mem_cap_str)
            local mem_bar_w = math.max(4, (right_w - 2) - mem_fixed_w)
            local mem_bar = make_meter_bar(mem.used_pct, mem_bar_w, C.mem_used)

            table.insert(out, draw_box_row(left_w + 1, 3, right_w,
                string.format("%sRAM %s%s %s%5.1f%%%s %s%s%s",
                    C.bold, C.reset, mem_bar, C.reset, mem.used_pct, C.reset,
                    C.dim, mem_cap_str, C.reset)))

            table.insert(out, draw_box_row(left_w + 1, 4, right_w,
                string.format("  %sFree: %s%s │ %sCached: %s%s │ %sAvail: %s%s",
                    C.dim, format_bytes(mem.total_kb - mem.used_kb), C.reset,
                    C.dim, format_bytes(mem.cached_kb), C.reset,
                    C.dim, format_bytes(mem.avail_kb), C.reset)))

            local swp_cap_str = format_bytes(mem.swap_used_kb) .. "/" .. format_bytes(mem.swap_total_kb)
            local swp_pct_str = string.format("%5.1f%%", mem.swap_pct)
            local swp_fixed_w = 4 + 1 + visual_len(swp_pct_str) + 1 + visual_len(swp_cap_str)
            local swp_bar_w = math.max(4, (right_w - 2) - swp_fixed_w)
            local swap_bar = make_meter_bar(mem.swap_pct, swp_bar_w, C.mem_swap)

            table.insert(out, draw_box_row(left_w + 1, 5, right_w,
                string.format("%sSWP %s%s %s%5.1f%%%s %s%s%s",
                    C.bold, C.reset, swap_bar, C.reset, mem.swap_pct, C.reset,
                    C.dim, swp_cap_str, C.reset)))

            -- GPU Telemetry (if detected)
            local row_y = 6
            for _, g in ipairs(gpus) do
                if row_y >= top_h then break end
                local g_temp = g.temp_c and string.format("  \27[1;38;2;251;191;36m%d°C\27[0m", g.temp_c) or ""
                local g_core = g.util_pct and string.format(" │ Core: \27[1;97m%d%%\27[0m", g.util_pct) or ""
                local g_freq = g.freq_ghz and string.format(" │ Freq: \27[1;97m%.2f GHz\27[0m", g.freq_ghz) or ""
                local g_name = g.name:gsub("^NVIDIA%s+", ""):gsub("^AMD%s+", "")
                local avail_name_w = math.max(10, right_w - 24)
                g_name = truncate(g_name, avail_name_w)
                table.insert(out, draw_box_row(left_w + 1, row_y, right_w,
                    string.format("%sGPU %s%s%s%s%s%s", C.bold, C.reset, C.title_col, g_name, C.reset, g_temp, g_core, g_freq)))
                row_y = row_y + 1

                if not g.is_integrated and g.mem_total_kb and g.mem_total_kb > 0 then
                    if row_y >= top_h then break end
                    local vram_cap_str = format_bytes(g.mem_used_kb) .. "/" .. format_bytes(g.mem_total_kb)
                    local vram_pct_str = string.format("%5.1f%%", g.mem_used_pct or 0)
                    local vram_fixed_w = 5 + 1 + visual_len(vram_pct_str) + 1 + visual_len(vram_cap_str)
                    local vram_bar_w = math.max(4, (right_w - 2) - vram_fixed_w)
                    local vram_bar = make_meter_bar(g.mem_used_pct, vram_bar_w, C.mem_used)
                    table.insert(out, draw_box_row(left_w + 1, row_y, right_w,
                        string.format("%sVRAM%s %s %5.1f%%%s %s%s%s",
                            C.bold, C.reset, vram_bar, g.mem_used_pct or 0, C.reset,
                            C.dim, vram_cap_str, C.reset)))
                    row_y = row_y + 1
                end
            end

            -- Storage Mounts & Disk I/O
            if use_dual_col then
                local col_w = math.floor((right_w - 2 - 3) / 2)
                local max_mnt_len = 2
                for _, m in ipairs(storage.mounts) do
                    max_mnt_len = math.max(max_mnt_len, visual_len(m.mount))
                end
                local mnt_w = math.max(2, math.min(6, max_mnt_len))

                local function format_col(m)
                    if not m then return string.rep(" ", col_w) end
                    local u_kb = math.floor(m.used_bytes / 1024)
                    local t_kb = math.floor(m.total_bytes / 1024)
                    local u_str = (u_kb >= 1024 * 1024 * 1024) and string.format("%.1fT", u_kb / (1024 * 1024 * 1024))
                        or (u_kb >= 1024 * 1024 and string.format("%.0fG", u_kb / (1024 * 1024)) or format_bytes(u_kb):gsub("%s+", ""))
                    local t_str = (t_kb >= 1024 * 1024 * 1024) and string.format("%.1fT", t_kb / (1024 * 1024 * 1024))
                        or (t_kb >= 1024 * 1024 and string.format("%.0fG", t_kb / (1024 * 1024)) or format_bytes(t_kb):gsub("%s+", ""))
                    local cap_str = u_str .. "/" .. t_str
                    local pct_str = string.format("%3.0f%%", m.used_pct or 0)
                    local mnt = truncate(m.mount, mnt_w)
                    local mnt_pad = mnt .. string.rep(" ", math.max(0, mnt_w - visual_len(mnt)))
                    local fixed_w = mnt_w + 1 + 1 + visual_len(pct_str) + 1 + visual_len(cap_str)
                    local bar_w = math.max(2, col_w - fixed_w)
                    local bar = make_meter_bar(m.used_pct, bar_w)
                    local col_txt = string.format("%s%s%s %s %s%s%s %s%s%s",
                        C.bold, mnt_pad, C.reset, bar, C.title_col, pct_str, C.reset, C.dim, cap_str, C.reset)
                    local vlen = visual_len(col_txt)
                    if vlen < col_w then
                        col_txt = col_txt .. string.rep(" ", col_w - vlen)
                    elseif vlen > col_w then
                        col_txt = truncate(col_txt, col_w)
                    end
                    return col_txt
                end

                local m_idx = 1
                while m_idx <= #storage.mounts do
                    if row_y >= top_h then break end
                    local m1 = storage.mounts[m_idx]
                    local m2 = storage.mounts[m_idx + 1]
                    m_idx = m_idx + 2
                    local row_content = format_col(m1) .. " " .. C.dim .. "│" .. C.reset .. " " .. format_col(m2)
                    table.insert(out, draw_box_row(left_w + 1, row_y, right_w, row_content))
                    row_y = row_y + 1
                end
            else
                local max_mnt_len = 2
                for _, m in ipairs(storage.mounts) do
                    max_mnt_len = math.max(max_mnt_len, visual_len(m.mount))
                end
                local mnt_w = math.max(2, math.min(10, max_mnt_len))

                for _, m in ipairs(storage.mounts) do
                    if row_y >= top_h then break end
                    local bar_col = (m.used_pct > 90.0) and C.cpu_high or ((m.used_pct > 80.0) and C.cpu_mid or C.cpu_low)
                    local mnt = truncate(m.mount, mnt_w)
                    local mnt_str = mnt .. string.rep(" ", math.max(0, mnt_w - visual_len(mnt)))
                    local u_kb = math.floor(m.used_bytes / 1024)
                    local t_kb = math.floor(m.total_bytes / 1024)
                    local u_str = (u_kb >= 1024 * 1024 * 1024) and string.format("%.1fT", u_kb / (1024 * 1024 * 1024))
                        or (u_kb >= 1024 * 1024 and string.format("%.0fG", u_kb / (1024 * 1024)) or format_bytes(u_kb):gsub("%s+", ""))
                    local t_str = (t_kb >= 1024 * 1024 * 1024) and string.format("%.1fT", t_kb / (1024 * 1024 * 1024))
                        or (t_kb >= 1024 * 1024 and string.format("%.0fG", t_kb / (1024 * 1024)) or format_bytes(t_kb):gsub("%s+", ""))
                    local cap_str = u_str .. "/" .. t_str
                    local pct_str = string.format("%5.1f%%", m.used_pct)
                    local fixed_w = mnt_w + 1 + 1 + visual_len(pct_str) + 1 + visual_len(cap_str)
                    local bar_w = math.max(3, (right_w - 2) - fixed_w)
                    local disk_bar = make_meter_bar(m.used_pct, bar_w, bar_col)

                    table.insert(out, draw_box_row(left_w + 1, row_y, right_w,
                        string.format("%s%s%s %s %s%s%s %s%s%s",
                            C.bold, mnt_str, C.reset, disk_bar, C.title_col, pct_str, C.reset, C.dim, cap_str, C.reset)))
                    row_y = row_y + 1
                end
            end

            if row_y <= top_h then
                local io_str = string.format("  %sDisk I/O: %sRead %s%s │ %sWrite %s%s",
                    C.dim, C.disk_read, format_rate(storage.read_speed), C.reset,
                    C.disk_write, format_rate(storage.write_speed), C.reset)
                table.insert(out, draw_box_row(left_w + 1, row_y, right_w, io_str))
                row_y = row_y + 1
            end

            -- 3. Network I/O Pane (Middle)
            local act3 = (focused_pane == 3) and " (Active)" or ""
            local net_y = top_h + 2
            local net_title = string.format("[3] Network%s (%s)", act3, net.active_iface)
            draw_pane(out, 1, net_y, term_w, net_h, net_title, (focused_pane == 3))

            local rx_spark = make_sparkline(rx_history, 15, C.net_rx)
            local tx_spark = make_sparkline(tx_history, 15, C.net_tx)
            local net_line = string.format("  %sRX:%s %s %s %sTotal: %s%s   │   %sTX:%s %s %s %sTotal: %s%s",
                C.bold, C.reset, format_rate(net.rx_rate), rx_spark, C.dim, format_bytes(math.floor(net.rx_total / 1024)), C.reset,
                C.bold, C.reset, format_rate(net.tx_rate), tx_spark, C.dim, format_bytes(math.floor(net.tx_total / 1024)), C.reset)
            table.insert(out, draw_box_row(1, net_y + 1, term_w, net_line))

            -- 4. Processes Table / Tree Pane (Bottom)
            local act4 = (focused_pane == 4) and " (Active)" or ""
            local proc_y = net_y + net_h
            local dir_sym = sort_reverse and "▲" or "▼"
            local sort_tag = string.format("[Sort: %s%s]", sort_mode:upper(), dir_sym)
            local tree_tag = in_tree_mode and "[Tree: ON]" or "[Tree: OFF]"
            local filter_tag = #filter_query > 0 and string.format("[Filter: /%s]", filter_query) or ""
            local active_cat = PROCESS_CATEGORIES[selected_category_idx] or PROCESS_CATEGORIES[1]
            local count_tag = (active_cat.id ~= "all" or #filter_query > 0)
                and string.format("%d/%d", #procs, raw_total_procs)
                or string.format("%d", raw_total_procs)
            local cat_pill_tag = (not last_has_pills and active_cat.id ~= "all") and string.format("[Cat: %s] ", active_cat.label) or ""
            local proc_title = string.format("[4] Processes%s: %s %s%s %s %s", act4, count_tag, cat_pill_tag, sort_tag, tree_tag, filter_tag)

            draw_pane(out, 1, proc_y, term_w, bot_h, proc_title, (focused_pane == 4))

            local table_header_y = proc_y + 1
            if last_has_pills then
                local pills_str = render_category_pills(PROCESS_CATEGORIES, selected_category_idx, category_counts, term_w, C)
                table.insert(out, draw_box_row(1, proc_y + 1, term_w, pills_str))
                table_header_y = proc_y + 2
            end

            -- Columns: PID (7), USER (8), %CPU (7), %MEM (7), RES (9), TH (4), STAT (5), COMMAND (rest)
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

            local h_pid     = col_hdr("PID", "pid", 7)
            local h_user    = col_hdr("USER", "user", 8)
            local h_cpu     = col_hdr("%CPU", "cpu", 7)
            local h_mem     = col_hdr("%MEM", "mem", 7)
            local h_res     = (sort_mode == "mem") and col_hdr("RES", "mem", 9) or string.format("%-9s", "RES")
            local h_th      = col_hdr("TH", "threads", 4)
            local h_stat    = string.format("%-5s", "STAT")
            local h_time    = col_hdr("TIME+", "time", 9)
            local h_cmd     = in_tree_mode and (C.title_col .. "PROCESS TREE [Space: Fold]" .. C.table_hdr) or col_hdr("COMMAND", "name", 15)

            local show_io_cols = (term_w >= 115)
            local io_hdr_str = ""
            if show_io_cols then
                local h_ior = col_hdr("DISK R", "ior", 9)
                local h_iow = col_hdr("DISK W", "iow", 9)
                io_hdr_str = string.format(" %s %s", h_ior, h_iow)
            end

            local th_str = string.format("  %s%s %s %s %s %s %s %s %s%s %s%s",
                C.table_hdr, h_pid, h_user, h_cpu, h_mem, h_res, h_th, h_stat, h_time, io_hdr_str, h_cmd, C.reset)
            table.insert(out, draw_box_row(1, table_header_y, term_w, th_str))

            local visible_rows = last_visible_rows
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

                    local time_str = format_time_plus(pr.cpu_time_sec or 0)
                    local badge_str = get_state_badge(pr.state, is_sel, C)
                    local row_content = string.format("%-7d %-8s %s%5.1f%%%s %5.1f%% %-9s %-4d %s %s%s %s",
                        pr.pid, user_str, cpu_col, cpu_val, (is_sel and C.sel_bg or C.reset), pr.mem_pct, format_bytes(res_val), pr.threads or 1, badge_str, time_str, io_val_str, cmd_display)

                    if is_sel then
                        table.insert(out, draw_box_row(1, table_header_y + i, term_w, C.sel_bg .. "▶ " .. row_content .. C.reset))
                    else
                        table.insert(out, draw_box_row(1, table_header_y + i, term_w, "  " .. row_content))
                    end
                else
                    table.insert(out, draw_box_row(1, table_header_y + i, term_w, ""))
                end
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
                table.insert(out, draw_box_row(mx, my + 3, mw, string.format(" %sUser:%s      %-8s (UID: %d)", C.bold, C.reset, pr.username, pr.uid or 0)))
                local _, b_sym, b_char, b_name, b_col = get_state_badge(pr.state, false, C)
                local state_desc = string.format("%s%s %s (%s)%s", b_col, b_sym, b_char, b_name, C.reset)
                table.insert(out, draw_box_row(mx, my + 4, mw, string.format(" %sState:%s     %-24s %sThreads:%s  %d", C.bold, C.reset, state_desc, C.bold, C.reset, pr.threads or 1)))
                table.insert(out, draw_box_row(mx, my + 5, mw, string.format(" %sPPID:%s      %-7d   %sNice:%s     %d", C.bold, C.reset, pr.ppid or 0, C.bold, C.reset, pr.nice or 0)))
                table.insert(out, draw_box_row(mx, my + 6, mw, string.format(" %sTIME+ (CPU):%s %-10s %sElapsed:%s   %s", C.bold, C.reset, format_time_plus(pr.cpu_time_sec or 0), C.bold, C.reset, format_elapsed(pr.elapsed_sec or 0))))
                table.insert(out, draw_box_row(mx, my + 7, mw, string.format(" %sCPU%%:%s     %-6.1f%%   %sMemory%%:%s %-6.1f%%", C.bold, C.reset, pr.cpu_pct, C.bold, C.reset, pr.mem_pct)))
                table.insert(out, draw_box_row(mx, my + 8, mw, string.format(" %sMemory:%s    RES: %s │ VIRT: %s", C.bold, C.reset, format_bytes(pr.res_kb), format_bytes(pr.vsize_kb or 0))))
                table.insert(out, draw_box_row(mx, my + 9, mw, string.format(" %sDisk I/O:%s  Read: %s (Tot: %s) │ Write: %s (Tot: %s)",
                    C.bold, C.reset,
                    format_rate(pr.io_read_rate or 0), format_bytes(math.floor((pr.io_read_bytes or 0) / 1024)),
                    format_rate(pr.io_write_rate or 0), format_bytes(math.floor((pr.io_write_bytes or 0) / 1024)))))
                table.insert(out, draw_box_row(mx, my + 11, mw, string.format("  %s[k] Kill   [R] Renice   [o/:] Diag   [Enter / Esc] Close Inspector%s", C.title_col, C.reset)))
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
            elseif show_renice_modal and procs[sel_proc] then
                local pr = procs[sel_proc]
                local mw = math.min(64, term_w - 4)
                local mh = 10
                local mx = math.floor((term_w - mw) / 2)
                local my = math.floor((term_h - mh) / 2)
                draw_modal_box(out, mx, my, mw, mh, string.format("Renice Process: PID %d (%s)", pr.pid, pr.comm))

                table.insert(out, draw_box_row(mx, my + 1, mw, string.format(" Current Priority: %sNice %d%s", C.bold, pr.nice or 0, C.reset)))
                table.insert(out, draw_box_row(mx, my + 2, mw, " Adjust priority (-20 = Highest/Realtime, 19 = Lowest/Idle):"))

                local slider_w = mw - 16
                local ratio = (renice_val + 20) / 39.0
                local pos = math.max(0, math.min(slider_w - 1, math.floor(ratio * (slider_w - 1))))
                local slider_str = string.rep("─", pos) .. "█" .. string.rep("─", slider_w - 1 - pos)
                local prio_col = (renice_val < 0) and C.cpu_high or ((renice_val == 0) and C.reset or C.cpu_low)

                table.insert(out, draw_box_row(mx, my + 4, mw, string.format("  Nice: %s%3d%s  [%s%s%s]",
                    prio_col, renice_val, C.reset, C.title_col, slider_str, C.reset)))

                local label = (renice_val < -5) and "High Priority (Aggressive)"
                    or ((renice_val < 0) and "Above Normal Priority"
                    or ((renice_val == 0) and "Normal Priority (Default)"
                    or ((renice_val < 10) and "Below Normal Priority"
                    or "Idle / Background Priority")))
                table.insert(out, draw_box_row(mx, my + 5, mw, string.format("  Level: %s%s%s", C.bold, label, C.reset)))
                table.insert(out, draw_box_row(mx, my + 7, mw, string.format("  %s[←/→, +/-] Adjust   [Enter] Apply   [Esc] Cancel%s", C.dim, C.reset)))
            elseif show_diagnostic_modal then
                local pr = procs[sel_proc] or { pid = 0, comm = "process", username = "user" }
                draw_diagnostic_modal(out, pr, diagnostic_custom_cmd, sel_diagnostic_preset, term_w, term_h, C)
            elseif show_help then
                local mw = math.min(74, term_w - 4)
                local mh = 21
                local mx = math.floor((term_w - mw) / 2)
                local my = math.floor((term_h - mh) / 2)
                draw_modal_box(out, mx, my, mw, mh, "Help & Keybindings")

                table.insert(out, draw_box_row(mx, my + 1, mw, string.format(" %sPane & Layout Controls:%s", C.title_col, C.reset)))
                table.insert(out, draw_box_row(mx, my + 2, mw, "   Tab, Shift+Tab Cycle active pane focus ([1]-[4])"))
                table.insert(out, draw_box_row(mx, my + 3, mw, "   1, 2, 3, 4     Jump directly to CPU, Mem, Net, Procs"))
                table.insert(out, draw_box_row(mx, my + 4, mw, "   z, f           Toggle zoom / maximize focused pane"))
                table.insert(out, draw_box_row(mx, my + 5, mw, string.format(" %sNavigation & Selection:%s", C.title_col, C.reset)))
                table.insert(out, draw_box_row(mx, my + 6, mw, "   ↑/↓, k/j       Select process / scroll rows"))
                table.insert(out, draw_box_row(mx, my + 7, mw, "   PgUp/PgDn      Jump 15 rows   Home/End Jump to ends"))
                table.insert(out, draw_box_row(mx, my + 8, mw, string.format(" %sProcess Controls:%s", C.title_col, C.reset)))
                table.insert(out, draw_box_row(mx, my + 9, mw, "   /              Filter: text, u:<user>, s:<state>, cpu>X, m>XM"))
                table.insert(out, draw_box_row(mx, my + 10, mw, "   [, ]           Cycle category tabs ([All], [User], [System], ...)"))
                table.insert(out, draw_box_row(mx, my + 11, mw, "   t, F5          Toggle Process Tree view   Space Fold/Pause"))
                table.insert(out, draw_box_row(mx, my + 12, mw, "   Enter, i       Inspect process details modal"))
                table.insert(out, draw_box_row(mx, my + 13, mw, "   k, R           Open signal dispatcher, Renice modal"))
                table.insert(out, draw_box_row(mx, my + 14, mw, "   o, :, !        Open process diagnostic runner (lsof, strace, etc.)"))
                table.insert(out, draw_box_row(mx, my + 15, mw, string.format(" %sDisplay & Sorting:%s", C.title_col, C.reset)))
                table.insert(out, draw_box_row(mx, my + 16, mw, "   c, m, p, n     Sort by CPU, Memory, PID, or Name"))
                table.insert(out, draw_box_row(mx, my + 17, mw, "   u, s, d, e, r  Sort by User, Threads, I/O, TIME+, Reverse"))
                table.insert(out, draw_box_row(mx, my + 18, mw, "   C, T           CPU view mode, Cycle color themes"))
                table.insert(out, draw_box_row(mx, my + 19, mw, string.format("  %s[Esc / Enter / ?] Close Help Dialog%s", C.dim, C.reset)))
            end

            -- 6. Footer Line & Search / Status
            local footer_y = term_h
            local footer_line = ""

            if in_search_mode then
                local raw_footer = string.format("  \27[1;38;2;254;231;21mSearch: \27[0m\27[4m%s\27[0m\27[5m_\27[0m  \27[90m(Enter confirm, Esc cancel)\27[0m", filter_query)
                footer_line = string.format("\27[%d;1H\27[2K%s", footer_y, truncate(raw_footer, term_w - 1))
            elseif os.clock() < status_flash_expiry and #status_flash_msg > 0 then
                local raw_footer = string.format("  \27[1;38;2;34;197;94m✔ %s\27[0m", status_flash_msg)
                footer_line = string.format("\27[%d;1H\27[2K%s", footer_y, truncate(raw_footer, term_w - 1))
            else
                local f_status = #filter_query > 0 and string.format("\27[1;38;2;251;191;36mFilter: /%s\27[0m  ", filter_query) or ""
                local zoom_hint = zoomed_pane and "[z/Esc] Restore Grid" or "[z] Zoom"
                local focus_hint = zoomed_pane and "[Tab] Cycle Pane" or string.format("[Tab] Pane %d", focused_pane)
                local help_str
                if term_w >= 115 then
                    help_str = in_tree_mode
                        and string.format("%s  %s  [/] Filter  [[]/[]] Category  [Space] Fold  [Enter] Inspect  [k] Kill  [R] Renice  [o/:] Diag  [c/m/p/n/u/s/d] Sort  [C] CPU  [T] Theme  [?] Help  [q] Quit", focus_hint, zoom_hint)
                        or string.format("%s  %s  [/] Filter  [[]/[]] Category  [t] Tree  [Enter] Inspect  [k] Kill  [R] Renice  [o/:] Diag  [c/m/p/n/u/s/d] Sort  [C] CPU  [T] Theme  [?] Help  [q] Quit", focus_hint, zoom_hint)
                elseif term_w >= 85 then
                    help_str = string.format("%s  %s  [/] Filter  [[]/[]] Category  [t] Tree  [Enter] Inspect  [o/:] Diag  [c/m/p] Sort  [C] CPU  [T] Theme  [?] Help  [q] Quit", focus_hint, zoom_hint)
                else
                    help_str = string.format("%s  %s  [/] Filter  [?] Help  [q] Quit", focus_hint, zoom_hint)
                end
                local raw_footer = string.format("  %s%s%s", f_status, C.dim, help_str)
                footer_line = string.format("\27[%d;1H\27[2K%s", footer_y, truncate(raw_footer, term_w - 1))
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
    print("\n\27[1;36mExited luatop cleanly. Goodbye!\27[0m")
    return 0
end

-- =========================================================================
-- 8.5 CPU & Disk Diagnostic Test Engines
-- =========================================================================
local function test_cpu_performance(duration_sec)
    duration_sec = duration_sec or 0.05
    local start_t = os.clock()
    local end_target = start_t + duration_sec
    local iterations = 0
    local a, b, c = 1.0001, 1.0002, 0.5
    while os.clock() < end_target do
        for _ = 1, 10000 do
            a = a * b + c
            b = b * c + a
            c = c * a + b
        end
        iterations = iterations + 10000
    end
    local elapsed = math.max(0.000001, os.clock() - start_t)
    local flops = iterations * 6
    local mflops = (flops / elapsed) / 1e6
    return {
        duration_sec = elapsed,
        iterations   = iterations,
        mflops       = mflops
    }
end

local function test_disk_performance(target_dir, test_size_mb)
    target_dir = target_dir or "."
    test_size_mb = test_size_mb or 1
    local tmp_file = string.format("%s/_luatop_disk_test_%d_%d.tmp", target_dir, os.time(), math.random(1000, 9999))
    local block_size = 64 * 1024
    local num_blocks = math.max(1, math.floor((test_size_mb * 1024 * 1024) / block_size))
    local dummy_data = string.rep("X", block_size)

    local w_start = os.clock()
    local f = io.open(tmp_file, "wb")
    if not f then
        return { error = "Failed to open temporary file for disk test", write_mbs = 0, read_mbs = 0 }
    end
    for _ = 1, num_blocks do
        f:write(dummy_data)
    end
    f:flush()
    f:close()
    local w_elapsed = math.max(0.000001, os.clock() - w_start)
    local written_bytes = num_blocks * block_size
    local write_mbs = (written_bytes / (1024 * 1024)) / w_elapsed

    local r_start = os.clock()
    f = io.open(tmp_file, "rb")
    local read_bytes = 0
    if f then
        while true do
            local chunk = f:read(block_size)
            if not chunk then break end
            read_bytes = read_bytes + #chunk
        end
        f:close()
    end
    local r_elapsed = math.max(0.000001, os.clock() - r_start)
    local read_mbs = (read_bytes / (1024 * 1024)) / r_elapsed

    os.remove(tmp_file)

    return {
        write_mbs   = write_mbs,
        read_mbs    = read_mbs,
        bytes_tested= written_bytes,
        test_size_mb= test_size_mb
    }
end

-- =========================================================================
-- 9. Self-Test Mode (Headless CI / Automated Verification)
-- =========================================================================
local function run_self_test()
    print("=== Running luatop.lua Headless Self-Test ===")

    local os_str = read_os_info and read_os_info() or "Unknown OS"
    local cpu_str = read_cpu_model and read_cpu_model() or "Unknown CPU"
    assert(type(os_str) == "string" and #os_str > 0, "OS name must be a non-empty string")
    assert(type(cpu_str) == "string" and #cpu_str > 0, "CPU model must be a non-empty string")
    print(string.format("  ✔ System Telemetry: OS='%s', CPU='%s'", os_str, cpu_str))

    local cores, cpu_pct = read_cpu_stats()
    assert(type(cores) == "table", "CPU cores should be a table")
    assert(cpu_pct >= 0 and cpu_pct <= 100, "CPU percent must be in [0, 100]")
    print(string.format("  ✔ CPU Telemetry: %d cores detected, usage: %.1f%%", #cores, cpu_pct))

    local cpu_bench = test_cpu_performance(0.05)
    assert(type(cpu_bench) == "table" and cpu_bench.mflops > 0, "CPU diagnostic test should return positive MFLOPS")
    print(string.format("  ✔ CPU Diagnostic Test: %.2f MFLOPS (tested over %.3fs)", cpu_bench.mflops, cpu_bench.duration_sec))

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
    assert(#storage.mounts > 0, "At least 1 filesystem mount must be discovered")
    print(string.format("  ✔ Storage Telemetry: %d mounted filesystems inspected", #storage.mounts))

    local disk_bench = test_disk_performance(".", 1)
    assert(type(disk_bench) == "table" and disk_bench.write_mbs > 0 and disk_bench.read_mbs > 0, "Disk diagnostic test should measure read/write throughput")
    print(string.format("  ✔ Disk Diagnostic Test: Write=%.1f MB/s, Read=%.1f MB/s", disk_bench.write_mbs, disk_bench.read_mbs))

    local gpus = read_gpu_stats()
    assert(type(gpus) == "table", "GPUs should be a table")
    if #gpus > 0 then
        local g0 = gpus[1]
        local vram_str = g0.is_integrated and "Integrated (UMA)" or string.format("%s/%s", format_bytes(g0.mem_used_kb), format_bytes(g0.mem_total_kb))
        local temp_str = g0.temp_c and string.format(", Temp: %d°C", g0.temp_c) or ""
        print(string.format("  ✔ GPU Telemetry: %d GPU(s) detected: %s (VRAM: %s, Core: %s%%%s)",
            #gpus, g0.name, vram_str, tostring(g0.util_pct or "N/A"), temp_str))
    else
        print("  ✔ GPU Telemetry: Headless/Integrated system (Zero-fork fallback active)")
    end

    local procs = read_process_table(mem.total_kb or 1, os.clock())
    assert(#procs > 0, "Process table must contain at least 1 process")
    assert(procs[1].pid >= 0, "Process PID must be >= 0")
    assert(#procs[1].comm > 0, "Process comm must not be empty")
    assert(type(procs[1].username) == "string" and #procs[1].username > 0, "Username must be resolved")
    assert(type(procs[1].io_read_bytes) == "number", "Process IO read bytes should be a number")
    assert(type(procs[1].io_write_bytes) == "number", "Process IO write bytes should be a number")
    assert(type(procs[1].elapsed_sec) == "number" and procs[1].elapsed_sec >= 0, "Process elapsed_sec must be non-negative number")
    assert(type(procs[1].cpu_time_sec) == "number" and procs[1].cpu_time_sec >= 0, "Process cpu_time_sec must be non-negative number")
    print(string.format("  ✔ Process Engine: %d processes parsed. Sample: PID %d (%s), User: %s, Elapsed: %s, Disk I/O: R=%s W=%s",
        #procs, procs[1].pid, procs[1].comm, procs[1].username, format_elapsed(procs[1].elapsed_sec),
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
    assert(format_elapsed(0) == "00:00:00", "format_elapsed(0)")
    assert(format_elapsed(125) == "00:02:05", "format_elapsed(125)")
    assert(format_elapsed(3665) == "01:01:05", "format_elapsed(3665)")
    assert(format_elapsed(90060) == " 1d 01:01", "format_elapsed(90060)")
    assert(format_cpu_time(0) == "00:00.00", "format_cpu_time(0)")
    assert(format_cpu_time(12.34) == "00:12.34", "format_cpu_time(12.34)")
    assert(format_time_plus(0) == "  0:00.00", "format_time_plus(0)")
    assert(format_time_plus(8.83) == "  0:08.83", "format_time_plus(8.83)")
    assert(format_time_plus(544.66) == "  9:04.66", "format_time_plus(544.66)")
    assert(format_time_plus(3665) == "  1:01:05", "format_time_plus(3665)")
    print("  ✔ Visual Utilities: visual_len, truncate, format_time_plus (TIME+), format_elapsed, and format_cpu_time verified")

    -- Smart filter test
    local test_proc = { pid = 9999, comm = "testworker", cmdline = "/usr/bin/testworker -d", username = "daemon", state = "S", cpu_pct = 12.5, res_kb = 64000, io_total_rate = 1024, elapsed_sec = 3600 }
    assert(match_smart_filter(test_proc, "u:daemon") == true, "Smart filter user match")
    assert(match_smart_filter(test_proc, "u:root") == false, "Smart filter user mismatch")
    assert(match_smart_filter(test_proc, "s:S") == true, "Smart filter state match")
    assert(match_smart_filter(test_proc, "cpu>10") == true, "Smart filter cpu> match")
    assert(match_smart_filter(test_proc, "cpu>20") == false, "Smart filter cpu> mismatch")
    assert(match_smart_filter(test_proc, "m>50M") == true, "Smart filter mem> match")
    assert(match_smart_filter(test_proc, "time>10m") == true, "Smart filter time> match")
    assert(match_smart_filter(test_proc, "time>2h") == false, "Smart filter time> mismatch")
    assert(match_smart_filter(test_proc, "elapsed<2h") == true, "Smart filter elapsed< match")
    assert(match_smart_filter(test_proc, "testworker") == true, "Smart filter text match")
    print("  ✔ Smart Filter Engine: Verified u:<user>, s:<state>, cpu>X, m>XM, time>X, text queries")

    -- Renice test
    assert(type(renice_process) == "function", "renice_process must be a function")
    if not is_windows then
        local cur_prio = ffi.C.getpriority(0, 0)
        assert(type(cur_prio) == "number", "getpriority must return a number")
        print(string.format("  ✔ Process Renice Engine: Priority subsystem verified (Current PID nice: %d)", cur_prio))
    end

    -- Maximized Zoomed Panes test (Proposal 1)
    for p_idx = 1, 4 do
        local frame_80 = render_zoomed_pane_frame(p_idx, nil, 80, 24)
        assert(type(frame_80) == "string" and #frame_80 > 0, "Zoomed frame must render for pane " .. p_idx)
        assert(frame_80:find("MAXIMIZED", 1, true) ~= nil, "Zoomed frame must include MAXIMIZED banner for pane " .. p_idx)
    end
    print("  ✔ Proposal 1: Verified maximized zoomed pane frame generation for Panes 1-4")

    -- State Badges & Category Engine test (Proposal 4)
    local test_states = { "R", "S", "D", "Z", "T", "t", "I", "?" }
    for _, st in ipairs(test_states) do
        local b_unsel, sym, ch = get_state_badge(st, false)
        local b_sel = get_state_badge(st, true)
        assert(visual_len(b_unsel) == 5, "Unselected state badge must be 5 visual columns for " .. st)
        assert(visual_len(b_sel) == 5, "Selected state badge must be 5 visual columns for " .. st)
        assert(#sym > 0 and #ch > 0, "State badge must have symbol and character for " .. st)
    end

    local mock_procs = {
        { pid = 1, comm = "systemd", username = "root", uid = 0, state = "S", cpu_pct = 0.0, io_total_rate = 0 },
        { pid = 2, comm = "kthreadd", username = "root", uid = 0, ppid = 2, state = "S", cpu_pct = 0.0, io_total_rate = 0 },
        { pid = 500, comm = "my_app", username = "alice", uid = 1000, state = "R", cpu_pct = 15.0, io_total_rate = 0 },
        { pid = 501, comm = "my_io", username = "alice", uid = 1000, state = "S", cpu_pct = 0.0, io_total_rate = 5000 },
        { pid = 999, comm = "defunct", username = "alice", uid = 1000, state = "Z", cpu_pct = 0.0, io_total_rate = 0 },
    }
    local cat_counts = count_process_categories(mock_procs, "alice")
    assert(cat_counts.all == 5, "Category all count")
    assert(cat_counts.user == 3, "Category user count (alice procs)")
    assert(cat_counts.system == 2, "Category system count (root procs)")
    assert(cat_counts.active == 2, "Category active count (my_app running + my_io I/O)")
    assert(cat_counts.zombies == 1, "Category zombies count")

    local pills_rendered = render_category_pills(PROCESS_CATEGORIES, 2, cat_counts, 80)
    assert(pills_rendered:find("▶%[User: 3%]◀") ~= nil, "Active user pill highlighted")
    assert(pills_rendered:find("%[Zombies: 1%]") ~= nil, "Zombies count present")

    local tab_hit_1 = get_category_tab_at_x(5, PROCESS_CATEGORIES, cat_counts, 1)
    assert(tab_hit_1 == 1, "Hit test category 1 (All)")
    print("  ✔ Proposal 4: Verified state badges, category filters, counts, and pill hit-testing")

    -- Process Diagnostic Runner test (Proposal 3)
    local test_pr = { pid = 12345, comm = "my_daemon", username = "alice" }
    local expanded_p = expand_diagnostic_cmd("lsof -p %p | grep %c --user=%u 100%%", test_pr)
    assert(expanded_p == "lsof -p 12345 | grep my_daemon --user=alice 100%", "Macro replacement failed: " .. tostring(expanded_p))

    local diag_presets = get_diagnostic_presets()
    assert(#diag_presets == 5, "Must have exactly 5 diagnostic presets")
    for _, dp in ipairs(diag_presets) do
        assert(dp.key and dp.name and dp.cmd and dp.desc, "Preset metadata missing")
    end

    for _, geom in ipairs({ { w = 80, h = 24 }, { w = 120, h = 40 }, { w = 60, h = 14 } }) do
        local d_frame = render_diagnostic_modal_frame(test_pr, nil, 1, geom.w, geom.h)
        assert(type(d_frame) == "string" and #d_frame > 0, "Diagnostic modal frame must render for " .. geom.w .. "x" .. geom.h)
        assert(d_frame:find("Diagnostic Runner", 1, true) ~= nil, "Modal must contain title banner")
        assert(d_frame:find("Command:", 1, true) ~= nil, "Modal must contain Command field")
        assert(d_frame:find("Preview:", 1, true) ~= nil, "Modal must contain Preview field")
    end
    print("  ✔ Proposal 3: Verified diagnostic macro expansion, presets, and decoupled modal rendering")

    print("\n\27[1;32mALL SELF-TEST CHECKS PASSED SUCCESSFULLY!\27[0m")
    return true
end

-- =========================================================================
-- 10. Module Export & CLI Entry Point
-- =========================================================================
local M = {
    version                       = "2.3.0",
    read_os_info                  = read_os_info,
    read_cpu_model                = read_cpu_model,
    read_cpu_stats                = read_cpu_stats,
    read_cpu_sensors              = read_cpu_sensors,
    test_cpu_performance          = test_cpu_performance,
    test_disk_performance         = test_disk_performance,
    read_memory_stats             = read_memory_stats,
    read_network_stats            = read_network_stats,
    read_storage_stats            = read_storage_stats,
    read_gpu_stats                = read_gpu_stats,
    read_process_table            = read_process_table,
    build_process_tree            = build_process_tree,
    match_smart_filter            = match_smart_filter,
    renice_process                = renice_process,
    resolve_username              = resolve_username,
    set_theme                     = set_theme,
    cycle_theme                   = cycle_theme,
    get_themes                    = function() return THEMES end,
    format_bytes                  = format_bytes,
    format_rate                   = format_rate,
    format_elapsed                = format_elapsed,
    format_cpu_time               = format_cpu_time,
    format_time_plus              = format_time_plus,
    visual_len                    = visual_len,
    truncate                      = truncate,
    make_meter_bar                = make_meter_bar,
    render_zoomed_pane_frame      = render_zoomed_pane_frame,
    get_state_badge               = get_state_badge,
    PROCESS_CATEGORIES            = PROCESS_CATEGORIES,
    matches_process_category      = matches_process_category,
    count_process_categories      = count_process_categories,
    render_category_pills         = render_category_pills,
    get_category_tab_at_x         = get_category_tab_at_x,
    expand_diagnostic_cmd         = expand_diagnostic_cmd,
    get_diagnostic_presets        = get_diagnostic_presets,
    render_diagnostic_modal_frame = render_diagnostic_modal_frame,
    suspend_raw_mode              = suspend_raw_mode,
    resume_raw_mode               = resume_raw_mode,
    main                          = main,
    run_self_test                 = run_self_test,
}

local is_entry_point = false
if arg and arg[0] then
    local script_name = arg[0]:match("([^/\\]+)$")
    if script_name and (script_name == "luatop.lua" or script_name == "luatop" or script_name == "btop_lite.lua" or script_name == "btop_lite") then
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
