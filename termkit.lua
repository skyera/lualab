#!/usr/bin/env luajit
--[[
    termkit.lua
    Shared POSIX terminal toolkit for LuaJIT FFI TUI programs (Linux, macOS, BSD).

    Features:
    - Raw-mode lifecycle: enter() switches to raw no-echo input on the alternate screen
      (hidden cursor, line wrap off, optional SGR mouse reporting) and arranges for
      SIGHUP/SIGINT/SIGQUIT/SIGTERM to restore the terminal before exiting; leave()
      undoes it. On Linux the signals are blocked and read from a signalfd inside
      read_key(), because LuaJIT cannot safely run Lua code in an asynchronous signal
      handler (it panics with "bad callback" when the signal lands mid-operation).
      Elsewhere an FFI-callback handler is used as a best-effort fallback.
    - suspend()/resume() hand the terminal to an inline subprocess without leaving the
      alternate screen buffer, flushing pending input around the handoff.
    - read_key() returns one key token at a time and buffers bursts (pasted text,
      mouse floods, piped input) so no key is ever dropped.
    - next_token() is the pure tokenizer behind read_key(), usable in unit tests.
    - size() returns the terminal size with a safe default.

    Key tokens: printable UTF-8 characters, "UP" "DOWN" "LEFT" "RIGHT" "HOME" "END"
    "PAGE_UP" "PAGE_DOWN" "SHIFT_TAB" "F5" "ENTER" "ESC" "SPACE" "TAB" "BACKSPACE",
    and mouse events { type = "mouse", btn, x, y, release }.

    Usage:
        local termkit = require("termkit")
        if termkit.enter({ mouse = true }) then
            local key = termkit.read_key(50)   -- nil on timeout, "EOF" at end of input
            termkit.leave()
        end
]]

local ffi = require("ffi")
local bit = require("bit")

local Termkit = {}

-- =========================================================================
-- 1. Platform constants and C declarations
-- =========================================================================
local IS_BSD_LIKE = (ffi.os == "OSX" or ffi.os == "BSD")

local STDIN_FD, STDOUT_FD = 0, 1
local TCSANOW = 0
local TCIFLUSH = IS_BSD_LIKE and 1 or 0 -- "discard unread input" queue selector
local LFLAG_ICANON = IS_BSD_LIKE and 0x100 or 0x2
local LFLAG_ECHO = 0x8
local TIOCGWINSZ = IS_BSD_LIKE and 0x40087468 or 0x5413
local POLLIN = 1
local RESTORE_SIGNALS = { 1, 2, 3, 15 } -- HUP, INT, QUIT, TERM
local SIG_BLOCK, SIG_UNBLOCK, SIG_SETMASK = 0, 1, 2 -- Linux sigprocmask "how" values
local SFD_NONBLOCK, SFD_CLOEXEC = 0x800, 0x80000
local SIGSET_BYTES = 128 -- glibc sigset_t
local SIGINFO_BYTES = 128 -- struct signalfd_siginfo; ssi_signo is its first uint32

local DEFAULT_COLS, DEFAULT_ROWS = 100, 30
local READ_CHUNK_BYTES = 256

-- macOS/BSD declare tcflag_t/speed_t as 64-bit and set NCCS to 20, while Linux uses
-- 32-bit and NCCS = 32. The wrong layout shifts every field offset and makes
-- tcgetattr overrun the buffer, so the definition is rewritten per platform.
local function platform_termios_cdef(def)
    if IS_BSD_LIKE then
        def = def:gsub("unsigned%s+int(%s+[%w_]*tcflag_t)", "unsigned long%1")
        def = def:gsub("unsigned%s+int(%s+[%w_]*speed_t)", "unsigned long%1")
        def = def:gsub("c_cc%[32%]", "c_cc[20]")
    end
    return def
end

ffi.cdef(platform_termios_cdef[[
    typedef unsigned char tk_cc_t;
    typedef unsigned int tk_speed_t;
    typedef unsigned int tk_tcflag_t;

    struct tk_termios {
        tk_tcflag_t c_iflag;
        tk_tcflag_t c_oflag;
        tk_tcflag_t c_cflag;
        tk_tcflag_t c_lflag;
        tk_cc_t     c_line;
        tk_cc_t     c_cc[32];
        tk_speed_t  c_ispeed;
        tk_speed_t  c_ospeed;
    };

    struct tk_winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };

    struct tk_pollfd {
        int   fd;
        short events;
        short revents;
    };

    int isatty(int fd);
    int ioctl(int fd, unsigned long request, void *argp);
    int tcgetattr(int fd, struct tk_termios *termios_p);
    int tcsetattr(int fd, int optional_actions, const struct tk_termios *termios_p);
    int tcflush(int fd, int queue_selector);
    int poll(struct tk_pollfd *fds, unsigned long nfds, int timeout);
    long read(int fd, void *buf, size_t count);

    int close(int fd);

    typedef void (*tk_sighandler_t)(int);
    tk_sighandler_t signal(int signum, tk_sighandler_t handler);

    int sigemptyset(void *set);
    int sigaddset(void *set, int signum);
    int sigprocmask(int how, const void *set, void *oldset);
    int signalfd(int fd, const void *mask, int flags);
]])

-- Alternate screen + hidden cursor + no auto-wrap.
local SCREEN_ENTER = "\27[?1049h\27[?25l\27[?7l"
local MOUSE_ENTER = "\27[?1000h\27[?1006h"
local MOUSE_LEAVE = "\27[?1006l\27[?1000l"
-- Restore wrap, leave the alternate screen, show the cursor, reset attributes.
local SCREEN_LEAVE = "\27[?7h\27[?1049l\27[?25h\27[0m"
local SUSPEND_SEQUENCE = "\27[?25h\27[?7h"
local RESUME_SEQUENCE = "\27[?25l\27[?7l"

-- =========================================================================
-- 2. Key tokenizer (pure)
-- =========================================================================
-- Escape sequences (CSI) that map to named keys.
local KEY_SEQUENCES = {
    ["\27[A"] = "UP", ["\27[B"] = "DOWN", ["\27[C"] = "RIGHT", ["\27[D"] = "LEFT",
    ["\27[H"] = "HOME", ["\27[F"] = "END", ["\27[Z"] = "SHIFT_TAB",
    ["\27[1~"] = "HOME", ["\27[4~"] = "END", ["\27[5~"] = "PAGE_UP", ["\27[6~"] = "PAGE_DOWN",
    ["\27[15~"] = "F5",
}

-- Single control bytes that map to named keys.
local CONTROL_KEYS = {
    [9] = "TAB", [10] = "ENTER", [13] = "ENTER", [32] = "SPACE", [8] = "BACKSPACE",
    [127] = "BACKSPACE",
}

--- Number of bytes in the UTF-8 character that starts with byte `lead`.
local function utf8_char_length(lead)
    if lead >= 240 then
        return 4
    elseif lead >= 224 then
        return 3
    elseif lead >= 192 then
        return 2
    end
    return 1
end

--- Parse an SGR mouse report ("ESC [ < button ; x ; y M|m") at the start of `s`.
--- Returns the event table and the remaining bytes, or nil when `s` is not one.
local function parse_mouse(s)
    local sequence, button, x, y, final = s:match("^(\27%[<(%d+);(%d+);(%d+)([Mm]))")
    if not sequence then
        return nil
    end
    local event = {
        type = "mouse",
        btn = tonumber(button),
        x = tonumber(x),
        y = tonumber(y),
        release = (final == "m"),
    }
    return event, s:sub(#sequence + 1)
end

--- Split the first key token off a non-empty byte string. Returns token, remainder.
--- A lone or unrecognised escape sequence yields "ESC" and is consumed.
function Termkit.next_token(s)
    local first = s:byte(1)
    if first == 27 then
        local mouse, rest = parse_mouse(s)
        if mouse then
            return mouse, rest
        end
        local sequence = s:match("^\27%[[%d;]*[%a~]")
        if sequence then
            return KEY_SEQUENCES[sequence] or "ESC", s:sub(#sequence + 1)
        end
        return "ESC", s:sub(2)
    end
    if CONTROL_KEYS[first] then
        return CONTROL_KEYS[first], s:sub(2)
    end
    local length = utf8_char_length(first)
    return s:sub(1, length), s:sub(length + 1)
end

-- =========================================================================
-- 3. Terminal state
-- =========================================================================
local raw_active = false
local mouse_enabled = false
local original_termios = ffi.new("struct tk_termios")
local raw_termios = ffi.new("struct tk_termios")
local signal_handler -- kept referenced so the FFI callback is not garbage collected

--- True while the terminal is in raw mode on the alternate screen.
function Termkit.is_raw()
    return raw_active
end

--- True when both stdin and stdout are terminals.
function Termkit.is_tty()
    return ffi.C.isatty(STDIN_FD) == 1 and ffi.C.isatty(STDOUT_FD) == 1
end

--- Discard unread terminal input (call before prompting after a subprocess).
function Termkit.flush_input()
    pcall(function()
        ffi.C.tcflush(STDIN_FD, TCIFLUSH)
    end)
end

local close_signal_fd -- defined with the other signal helpers below

--- Leave the alternate screen and restore the original terminal settings.
--- Safe to call more than once.
function Termkit.leave()
    if not raw_active then
        return
    end
    io.write(mouse_enabled and MOUSE_LEAVE or "", SCREEN_LEAVE)
    io.flush()
    ffi.C.tcsetattr(STDIN_FD, TCSANOW, original_termios)
    close_signal_fd()
    raw_active = false
end

--- Fallback: restore the terminal from an FFI-callback signal handler. Only safe when
--- the process is waiting in a C call, so it is used where signalfd is unavailable and
--- while suspended (blocked in a subprocess).
local function install_signal_traps()
    if signal_handler then
        return
    end
    signal_handler = ffi.cast("tk_sighandler_t", function(sig)
        Termkit.leave()
        os.exit(128 + sig)
    end)
    for _, sig in ipairs(RESTORE_SIGNALS) do
        ffi.C.signal(sig, signal_handler)
    end
end

-- Linux signalfd delivery: the restore signals are blocked and queued on a file
-- descriptor that read_key() polls, so all Lua code runs on the normal call stack.
local signal_fd = -1
local signal_set = ffi.new("unsigned char[?]", SIGSET_BYTES)
local saved_signal_mask = ffi.new("unsigned char[?]", SIGSET_BYTES)
local siginfo_buffer = ffi.new("uint8_t[?]", SIGINFO_BYTES)
local signal_poll = ffi.new("struct tk_pollfd", { fd = -1, events = POLLIN, revents = 0 })

--- Block the restore signals and open a signalfd for them. Returns false (leaving the
--- signal mask untouched) when this platform or kernel does not support it.
local function open_signal_fd()
    if ffi.os ~= "Linux" then
        return false
    end
    ffi.C.sigemptyset(signal_set)
    for _, sig in ipairs(RESTORE_SIGNALS) do
        ffi.C.sigaddset(signal_set, sig)
    end
    if ffi.C.sigprocmask(SIG_BLOCK, signal_set, saved_signal_mask) ~= 0 then
        return false
    end
    signal_fd = ffi.C.signalfd(-1, signal_set, SFD_NONBLOCK + SFD_CLOEXEC)
    if signal_fd < 0 then
        ffi.C.sigprocmask(SIG_SETMASK, saved_signal_mask, nil)
        return false
    end
    signal_poll.fd = signal_fd
    return true
end

--- Undo open_signal_fd(): restore the original signal mask and close the descriptor.
close_signal_fd = function()
    if signal_fd < 0 then
        return
    end
    ffi.C.sigprocmask(SIG_SETMASK, saved_signal_mask, nil)
    ffi.C.close(signal_fd)
    signal_fd = -1
    signal_poll.fd = -1
end

--- If a restore signal is pending, restore the terminal and exit with 128 + signal.
local function exit_on_pending_signal()
    if signal_fd < 0 or ffi.C.poll(signal_poll, 1, 0) <= 0 then
        return
    end
    if tonumber(ffi.C.read(signal_fd, siginfo_buffer, SIGINFO_BYTES)) >= 4 then
        local signo = tonumber(ffi.cast("uint32_t *", siginfo_buffer)[0])
        Termkit.leave()
        os.exit(128 + signo)
    end
end

--- Enter raw mode on the alternate screen. `opts.mouse = true` also enables SGR mouse
--- reporting. Returns false (and changes nothing) when stdin/stdout is not a terminal
--- or the terminal attributes cannot be read or set.
function Termkit.enter(opts)
    if raw_active then
        return true
    end
    if not Termkit.is_tty() then
        return false
    end
    if ffi.C.tcgetattr(STDIN_FD, original_termios) ~= 0 then
        return false
    end
    ffi.copy(raw_termios, original_termios, ffi.sizeof(raw_termios))
    raw_termios.c_lflag = bit.band(raw_termios.c_lflag,
        bit.bnot(bit.bor(LFLAG_ICANON, LFLAG_ECHO)))
    if ffi.C.tcsetattr(STDIN_FD, TCSANOW, raw_termios) ~= 0 then
        return false
    end
    raw_active = true
    mouse_enabled = opts ~= nil and opts.mouse == true
    if not open_signal_fd() then
        install_signal_traps()
    end
    io.write(SCREEN_ENTER, mouse_enabled and MOUSE_ENTER or "")
    io.flush()
    return true
end

--- Temporarily restore the normal terminal (canonical mode, echo, cursor, wrap) so an
--- inline subprocess can print and read; the alternate screen stays active.
function Termkit.suspend()
    if not raw_active then
        return
    end
    ffi.C.tcsetattr(STDIN_FD, TCSANOW, original_termios)
    if signal_fd >= 0 then
        -- A subprocess must not inherit blocked signals (Ctrl-C has to reach it); while
        -- we wait for it in a C call the callback handler is safe.
        install_signal_traps()
        ffi.C.sigprocmask(SIG_UNBLOCK, signal_set, nil)
    end
    Termkit.flush_input()
    io.write(SUSPEND_SEQUENCE)
    io.flush()
end

--- Undo suspend(): back to raw mode with the cursor hidden and wrapping off.
function Termkit.resume()
    if not raw_active then
        return
    end
    ffi.C.tcsetattr(STDIN_FD, TCSANOW, raw_termios)
    if signal_fd >= 0 then
        ffi.C.sigprocmask(SIG_BLOCK, signal_set, nil)
    end
    Termkit.flush_input()
    io.write(RESUME_SEQUENCE)
    io.flush()
end

--- Terminal size as cols, rows; falls back to 100x30 when it cannot be determined.
function Termkit.size()
    local ws = ffi.new("struct tk_winsize")
    if ffi.C.ioctl(STDOUT_FD, TIOCGWINSZ, ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 then
        return tonumber(ws.ws_col), tonumber(ws.ws_row)
    end
    return DEFAULT_COLS, DEFAULT_ROWS
end

-- =========================================================================
-- 4. Key input
-- =========================================================================
local stdin_poll = ffi.new("struct tk_pollfd", { fd = STDIN_FD, events = POLLIN, revents = 0 })
local read_buffer = ffi.new("char[?]", READ_CHUNK_BYTES)
local wait_poll = ffi.new("struct tk_pollfd[2]")
local pending_input = "" -- bytes read from stdin but not yet turned into tokens

--- Read one key token, waiting up to `timeout_ms`. Bytes read in one chunk are
--- buffered and returned one token per call. Returns nil on timeout and "EOF" when
--- input has ended (piped stdin closed). Works on terminals and pipes alike.
function Termkit.read_key(timeout_ms)
    exit_on_pending_signal()
    if pending_input == "" then
        if signal_fd >= 0 then
            -- Wait on stdin and the signalfd together so a signal wakes us immediately.
            wait_poll[0].fd, wait_poll[0].events, wait_poll[0].revents = STDIN_FD, POLLIN, 0
            wait_poll[1].fd, wait_poll[1].events, wait_poll[1].revents = signal_fd, POLLIN, 0
            ffi.C.poll(wait_poll, 2, timeout_ms or 50)
            exit_on_pending_signal()
            if wait_poll[0].revents == 0 then
                return nil
            end
        elseif ffi.C.poll(stdin_poll, 1, timeout_ms or 50) <= 0 then
            return nil
        end
        local count = tonumber(ffi.C.read(STDIN_FD, read_buffer, READ_CHUNK_BYTES))
        if count <= 0 then
            return "EOF"
        end
        pending_input = ffi.string(read_buffer, count)
    end
    local token
    token, pending_input = Termkit.next_token(pending_input)
    return token
end

return Termkit
