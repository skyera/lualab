#!/usr/bin/env luajit
--[[
    ffi_enigma.lua
    Historical WWII Enigma Cipher Machine (Enigma I / M3) Simulator.
    High-Performance, Cross-Platform Pure LuaJIT FFI Implementation.

    Key Features:
    - Accurate mechanical rotor stepping including the historical "double-stepping" anomaly.
    - Historical Wehrmacht / Luftwaffe Rotors I, II, III, IV, V with authentic wiring and notches.
    - Standard Reflectors UKW-B and UKW-C with reciprocal involutions.
    - Full Ringstellung (Ring Settings) and Grundstellung (Rotor Positions) support.
    - Steckerbrett (Plugboard) with arbitrary bidirectional letter swap pairs.
    - Interactive Flicker-Free Terminal UI with illuminated Lampboard, Rotor Windows,
      and Plugboard Patch display.
    - Non-interactive batch encryption and Unix pipeline support.
    - Full undo / backspace support in interactive mode.
    - Cross-platform Windows (Win32 Console API) and POSIX / Linux (termios / poll).
]]

local ffi = require("ffi")
local bit = require("bit")

-- =========================================================================
-- 1. FFI C Declarations (Cross-Platform: Windows & POSIX / Linux)
-- =========================================================================
local is_windows = (ffi.os == "Windows")

local enable_raw_mode
local disable_raw_mode
local read_key
local get_time_ms
local sleep_ms
local is_stdin_tty
local get_terminal_size

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
        int   __stdcall GetConsoleScreenBufferInfo(void* h, CONSOLE_SCREEN_BUFFER_INFO* csbi);
        int   __stdcall GetConsoleMode(void* h, uint32_t* mode);
        int   __stdcall SetConsoleMode(void* h, uint32_t mode);
        int   __stdcall SetConsoleOutputCP(uint32_t cp);
        void  __stdcall Sleep(uint32_t ms);
        int             _kbhit(void);
        int             _getch(void);
    ]]

    local STD_INPUT_HANDLE  = 0xFFFFFFF6
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5
    local orig_in_mode  = ffi.new("uint32_t[1]")
    local orig_out_mode = ffi.new("uint32_t[1]")
    local in_raw_mode   = false

    is_stdin_tty = function()
        local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        local mode = ffi.new("uint32_t[1]")
        return ffi.C.GetConsoleMode(hIn, mode) ~= 0
    end

    get_terminal_size = function()
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        local csbi = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
        if ffi.C.GetConsoleScreenBufferInfo(hOut, csbi) ~= 0 then
            local cols = csbi.srWindow.Right - csbi.srWindow.Left + 1
            local rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1
            return cols, rows
        end
        return 80, 25
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        local hIn  = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
        local hOut = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)

        ffi.C.GetConsoleMode(hIn, orig_in_mode)
        ffi.C.GetConsoleMode(hOut, orig_out_mode)

        ffi.C.SetConsoleMode(hIn, 0x0200) -- ENABLE_VIRTUAL_TERMINAL_INPUT
        ffi.C.SetConsoleMode(hOut, bit.bor(orig_out_mode[0], 0x0004)) -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
        ffi.C.SetConsoleOutputCP(65001)

        in_raw_mode = true
        io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
            io.flush()
            local hIn = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
            ffi.C.SetConsoleMode(hIn, orig_in_mode[0])
            in_raw_mode = false
        end
    end

    read_key = function(timeout_ms)
        timeout_ms = timeout_ms or 0
        local elapsed = 0
        while timeout_ms <= 0 or elapsed <= timeout_ms do
            if ffi.C._kbhit() ~= 0 then
                local ch = ffi.C._getch()
                if ch == 0 or ch == 224 then
                    local code = ffi.C._getch()
                    if code == 72 then return "UP"
                    elseif code == 80 then return "DOWN"
                    elseif code == 75 then return "LEFT"
                    elseif code == 77 then return "RIGHT"
                    end
                elseif ch == 27 then
                    return "ESC"
                elseif ch == 32 then
                    return "SPACE"
                elseif ch == 13 or ch == 10 then
                    return "ENTER"
                elseif ch == 8 then
                    return "BACKSPACE"
                elseif ch == 3 then
                    return "CTRL_C"
                elseif ch >= 32 and ch <= 126 then
                    return string.char(ch):upper()
                end
            end
            if timeout_ms > 0 then
                ffi.C.Sleep(5)
                elapsed = elapsed + 5
            else
                break
            end
        end
        return nil
    end

    get_time_ms = function()
        return os.clock() * 1000.0
    end

    sleep_ms = function(ms)
        ffi.C.Sleep(ms)
    end
else
    local ok_cdef = pcall(ffi.cdef, [[
        typedef unsigned char  cc_t;
        typedef unsigned int   speed_t;
        typedef unsigned int   tcflag_t;

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
        int isatty(int fd);

        typedef struct { long tv_sec; long tv_nsec; } timespec_t;
        int clock_gettime(int clk_id, timespec_t *tp);
        int usleep(unsigned int usec);
    ]])

    local STDIN_FILENO = 0
    local TCSANOW      = 0
    local ICANON       = 2
    local ECHO         = 8
    local POLLIN       = 1
    local CLOCK_MONOTONIC = 1

    local orig_termios = ffi.new("struct termios")
    local raw_termios  = ffi.new("struct termios")
    local in_raw_mode  = false

    is_stdin_tty = function()
        return ffi.C.isatty(STDIN_FILENO) == 1
    end

    enable_raw_mode = function()
        if not is_stdin_tty() then return false end
        ffi.C.tcgetattr(STDIN_FILENO, orig_termios)
        ffi.C.tcgetattr(STDIN_FILENO, raw_termios)
        raw_termios.c_lflag = bit.band(raw_termios.c_lflag, bit.bnot(bit.bor(ICANON, ECHO)))
        ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, raw_termios)
        in_raw_mode = true

        io.write("\27[?1049h\27[?25l\27[?7l\27[2J\27[H")
        io.flush()
        return true
    end

    disable_raw_mode = function()
        if in_raw_mode then
            io.write("\27[?7h\27[?1049l\27[?25h\27[0m")
            io.flush()
            ffi.C.tcsetattr(STDIN_FILENO, TCSANOW, orig_termios)
            in_raw_mode = false
        end
    end

    local pfd = ffi.new("struct pollfd", { fd = STDIN_FILENO, events = POLLIN, revents = 0 })
    local key_buf = ffi.new("char[64]")
    local key_queue = {}

    read_key = function(timeout_ms)
        if #key_queue > 0 then
            return table.remove(key_queue, 1)
        end
        timeout_ms = timeout_ms or 0
        local ret = ffi.C.poll(pfd, 1, timeout_ms)
        if ret > 0 then
            if bit.band(pfd.revents, POLLIN) ~= 0 then
                local n = ffi.C.read(STDIN_FILENO, key_buf, 64)
                if n > 0 then
                    local i = 0
                    while i < n do
                        local c0 = key_buf[i]
                        if c0 == 27 then
                            if i + 2 < n and key_buf[i+1] == 91 then
                                local c2 = key_buf[i+2]
                                if c2 == 65 then table.insert(key_queue, "UP")
                                elseif c2 == 66 then table.insert(key_queue, "DOWN")
                                elseif c2 == 67 then table.insert(key_queue, "RIGHT")
                                elseif c2 == 68 then table.insert(key_queue, "LEFT")
                                end
                                i = i + 3
                            else
                                table.insert(key_queue, "ESC")
                                i = i + 1
                            end
                        elseif c0 == 32 then
                            table.insert(key_queue, "SPACE")
                            i = i + 1
                        elseif c0 == 10 or c0 == 13 then
                            table.insert(key_queue, "ENTER")
                            i = i + 1
                        elseif c0 == 127 or c0 == 8 then
                            table.insert(key_queue, "BACKSPACE")
                            i = i + 1
                        elseif c0 == 3 then
                            table.insert(key_queue, "CTRL_C")
                            i = i + 1
                        elseif c0 >= 32 and c0 <= 126 then
                            table.insert(key_queue, string.char(c0):upper())
                            i = i + 1
                        else
                            i = i + 1
                        end
                    end
                    if #key_queue > 0 then
                        return table.remove(key_queue, 1)
                    end
                elseif n == 0 then
                    return "q"
                end
            elseif bit.band(pfd.revents, 16) ~= 0 or bit.band(pfd.revents, 8) ~= 0 then
                return "q"
            end
        end
        return nil
    end

    local ts = ffi.new("timespec_t")
    get_time_ms = function()
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) * 1000.0 + tonumber(ts.tv_nsec) / 1e6
    end

    sleep_ms = function(ms)
        ffi.C.usleep(ms * 1000)
    end
end

-- =========================================================================
-- 2. Historical Rotor and Reflector Wiring Tables
-- =========================================================================
local ROTOR_DEFS = {
    I   = { name = "I",   wiring = "EKMFLGDQVZNTOWYHXUSPAIBRCJ", notch = "Q" },
    II  = { name = "II",  wiring = "AJDKSIRUXBLHWTMCQGZNPYFVOE", notch = "E" },
    III = { name = "III", wiring = "BDFHJLCPRTXVZNYEIWGAKMUSQO", notch = "V" },
    IV  = { name = "IV",  wiring = "ESOVPZJAYQUIRHXLNFTGKDCMWB", notch = "J" },
    V   = { name = "V",   wiring = "VZBRGITYUPSDNHLXAWMJQOFECK", notch = "Z" }
}

local REFLECTOR_DEFS = {
    ["UKW-B"] = { name = "UKW-B", wiring = "YRUHQSLDPXNGOKMIEBFZCWVJAT" },
    ["UKW-C"] = { name = "UKW-C", wiring = "FVPJIAOYEDRZXWGCTKUQSBNMHL" }
}

-- =========================================================================
-- 3. Core Cryptographic Components
-- =========================================================================
local EnigmaRotor = {}
EnigmaRotor.__index = EnigmaRotor

function EnigmaRotor.new(name, ring_char, pos_char)
    local def = ROTOR_DEFS[name] or ROTOR_DEFS["I"]
    local self = setmetatable({}, EnigmaRotor)

    self.name = def.name
    self.wiring = def.wiring
    self.notch_char = def.notch
    self.notch = string.byte(def.notch) - 65

    self.f_map = {}
    self.r_map = {}
    for i = 0, 25 do
        local target = string.byte(def.wiring, i + 1) - 65
        self.f_map[i] = target
        self.r_map[target] = i
    end

    self.ring = (string.byte((ring_char or "A"):upper()) - 65) % 26
    self.pos  = (string.byte((pos_char  or "A"):upper()) - 65) % 26
    return self
end

function EnigmaRotor:step()
    self.pos = (self.pos + 1) % 26
end

function EnigmaRotor:forward(x)
    local shift = (self.pos - self.ring) % 26
    if shift < 0 then shift = shift + 26 end
    local in_pin = (x + shift) % 26
    local out_pin = self.f_map[in_pin]
    local out_contact = (out_pin - shift) % 26
    if out_contact < 0 then out_contact = out_contact + 26 end
    return out_contact
end

function EnigmaRotor:reverse(x)
    local shift = (self.pos - self.ring) % 26
    if shift < 0 then shift = shift + 26 end
    local in_pin = (x + shift) % 26
    local out_pin = self.r_map[in_pin]
    local out_contact = (out_pin - shift) % 26
    if out_contact < 0 then out_contact = out_contact + 26 end
    return out_contact
end

function EnigmaRotor:get_char()
    return string.char(self.pos + 65)
end

function EnigmaRotor:get_ring_char()
    return string.char(self.ring + 65)
end

-- -------------------------------------------------------------------------
-- Reflector (Umkehrwalze / UKW)
-- -------------------------------------------------------------------------
local EnigmaReflector = {}
EnigmaReflector.__index = EnigmaReflector

function EnigmaReflector.new(name)
    local def = REFLECTOR_DEFS[name] or REFLECTOR_DEFS["UKW-B"]
    local self = setmetatable({}, EnigmaReflector)
    self.name = def.name
    self.wiring = def.wiring
    self.map = {}
    for i = 0, 25 do
        self.map[i] = string.byte(def.wiring, i + 1) - 65
    end
    return self
end

function EnigmaReflector:reflect(x)
    return self.map[x]
end

-- -------------------------------------------------------------------------
-- Plugboard (Steckerbrett)
-- -------------------------------------------------------------------------
local EnigmaPlugboard = {}
EnigmaPlugboard.__index = EnigmaPlugboard

function EnigmaPlugboard.new(pairs_str)
    local self = setmetatable({}, EnigmaPlugboard)
    self.plug = {}
    self:clear()
    if pairs_str then
        self:parse_pairs(pairs_str)
    end
    return self
end

function EnigmaPlugboard:clear()
    for i = 0, 25 do
        self.plug[i] = i
    end
end

function EnigmaPlugboard:parse_pairs(pairs_str)
    self:clear()
    for pair in pairs_str:upper():gmatch("%a%a") do
        local a = string.byte(pair, 1) - 65
        local b = string.byte(pair, 2) - 65
        if a >= 0 and a <= 25 and b >= 0 and b <= 25 and a ~= b then
            self.plug[a] = b
            self.plug[b] = a
        end
    end
end

function EnigmaPlugboard:swap(x)
    return self.plug[x]
end

function EnigmaPlugboard:get_pairs_string()
    local seen = {}
    local pairs_list = {}
    for i = 0, 25 do
        local target = self.plug[i]
        if target ~= i and not seen[i] and not seen[target] then
            table.insert(pairs_list, string.char(i + 65) .. string.char(target + 65))
            seen[i] = true
            seen[target] = true
        end
    end
    table.sort(pairs_list)
    if #pairs_list == 0 then
        return "(None - Direct)"
    end
    return table.concat(pairs_list, " ")
end

-- =========================================================================
-- 4. Complete Enigma Machine Engine
-- =========================================================================
local EnigmaMachine = {}
EnigmaMachine.__index = EnigmaMachine

function EnigmaMachine.new(options)
    options = options or {}
    local self = setmetatable({}, EnigmaMachine)

    self.ascii_mode = options.ascii_mode or false
    self.rotor_names = options.rotors or {"I", "II", "III"}
    self.ring_str = options.rings or "AAA"
    self.start_pos_str = options.pos or "AAA"
    self.reflector_name = options.reflector or "UKW-B"
    self.plug_str = options.plugs or ""

    self.reflector = EnigmaReflector.new(self.reflector_name)
    self.plugboard = EnigmaPlugboard.new(self.plug_str)

    self.rotors = {}
    self:reset_rotors()

    self.history = {} -- For undo / backspace
    self.plaintext_buffer = ""
    self.ciphertext_buffer = ""
    self.last_lit_lamp = nil

    return self
end

function EnigmaMachine:reset_rotors()
    self.rotors = {
        EnigmaRotor.new(self.rotor_names[1], self.ring_str:sub(1,1), self.start_pos_str:sub(1,1)),
        EnigmaRotor.new(self.rotor_names[2], self.ring_str:sub(2,2), self.start_pos_str:sub(2,2)),
        EnigmaRotor.new(self.rotor_names[3], self.ring_str:sub(3,3), self.start_pos_str:sub(3,3))
    }
end

function EnigmaMachine:reset()
    self:reset_rotors()
    self.history = {}
    self.plaintext_buffer = ""
    self.ciphertext_buffer = ""
    self.last_lit_lamp = nil
end

function EnigmaMachine:step_rotors()
    local r1 = self.rotors[1] -- Left (Slow)
    local r2 = self.rotors[2] -- Middle
    local r3 = self.rotors[3] -- Right (Fast)

    local right_at_notch = (r3.pos == r3.notch)
    local mid_at_notch   = (r2.pos == r2.notch)

    -- Historical Double-Stepping Anomaly:
    if mid_at_notch then
        r2:step()
        r1:step()
    elseif right_at_notch then
        r2:step()
    end

    r3:step()
end

function EnigmaMachine:encode_char(ch)
    local b = string.byte(ch:upper())
    if b < 65 or b > 90 then
        if ch == " " then
            self.plaintext_buffer = self.plaintext_buffer .. " "
            self.ciphertext_buffer = self.ciphertext_buffer .. " "
            table.insert(self.history, {
                is_space = true,
                p1 = self.rotors[1].pos,
                p2 = self.rotors[2].pos,
                p3 = self.rotors[3].pos
            })
        end
        return ch
    end

    -- Save state snapshot for undo
    table.insert(self.history, {
        p1 = self.rotors[1].pos,
        p2 = self.rotors[2].pos,
        p3 = self.rotors[3].pos,
        plain = ch:upper(),
        last_lamp = self.last_lit_lamp
    })

    -- 1. Step Rotors BEFORE electrical contact
    self:step_rotors()

    -- 2. Steckerbrett (Plugboard input)
    local x = b - 65
    x = self.plugboard:swap(x)

    -- 3. Rotors Right to Left (Forward)
    x = self.rotors[3]:forward(x)
    x = self.rotors[2]:forward(x)
    x = self.rotors[1]:forward(x)

    -- 4. Reflector (UKW)
    x = self.reflector:reflect(x)

    -- 5. Rotors Left to Right (Reverse)
    x = self.rotors[1]:reverse(x)
    x = self.rotors[2]:reverse(x)
    x = self.rotors[3]:reverse(x)

    -- 6. Steckerbrett (Plugboard output)
    x = self.plugboard:swap(x)

    local out_char = string.char(x + 65)
    self.last_lit_lamp = out_char
    self.plaintext_buffer = self.plaintext_buffer .. ch:upper()
    self.ciphertext_buffer = self.ciphertext_buffer .. out_char

    return out_char
end

function EnigmaMachine:undo()
    if #self.history == 0 then return false end
    local last = table.remove(self.history)
    self.rotors[1].pos = last.p1
    self.rotors[2].pos = last.p2
    self.rotors[3].pos = last.p3
    self.plaintext_buffer = self.plaintext_buffer:sub(1, -2)
    self.ciphertext_buffer = self.ciphertext_buffer:sub(1, -2)
    self.last_lit_lamp = last.last_lamp
    return true
end

function EnigmaMachine:encode_text(text)
    local out = {}
    for i = 1, #text do
        local c = text:sub(i, i)
        table.insert(out, self:encode_char(c))
    end
    return table.concat(out)
end

-- =========================================================================
-- 5. Terminal User Interface (TUI) & Layout Helpers
-- =========================================================================
local function utf8_visible_width(s)
    local clean = s:gsub("\27%[[0-9;?]*[a-zA-Z]", "")
    local w = 0
    local i = 1
    local len = #clean
    while i <= len do
        local b1 = string.byte(clean, i)
        if b1 < 0x80 then
            w = w + 1
            i = i + 1
        elseif b1 < 0xE0 then
            w = w + 1
            i = i + 2
        elseif b1 < 0xF0 then
            local b2 = string.byte(clean, i + 1)
            local b3 = string.byte(clean, i + 2)
            local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
            if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0xFF01 and cp <= 0xFF60) then
                w = w + 2
            else
                w = w + 1
            end
            i = i + 3
        elseif b1 < 0xF8 then
            w = w + 2
            i = i + 4
        else
            w = w + 1
            i = i + 1
        end
    end
    return w
end

local function pad_right(s, target_w)
    local cur_w = utf8_visible_width(s)
    if cur_w < target_w then
        return s .. string.rep(" ", target_w - cur_w)
    end
    return s
end

local function pad_center(s, target_w)
    local cur_w = utf8_visible_width(s)
    if cur_w >= target_w then return s end
    local left = math.floor((target_w - cur_w) / 2)
    local right = target_w - cur_w - left
    return string.rep(" ", left) .. s .. string.rep(" ", right)
end

local UI_CHARS = {
    unicode = {
        h_line   = "═",
        v_line   = "║",
        tl       = "╔",
        tr       = "╗",
        bl       = "╚",
        br       = "╝",
        t_left   = "╠",
        t_right  = "╣",
        b_box_h  = "─",
        b_box_v  = "│",
        b_tl     = "┌",
        b_tr     = "┐",
        b_bl     = "└",
        b_br     = "┘",
        b_t_left = "╟",
        b_t_r    = "╢"
    },
    ascii = {
        h_line   = "=",
        v_line   = "|",
        tl       = "+",
        tr       = "+",
        bl       = "+",
        br       = "+",
        t_left   = "+",
        t_right  = "+",
        b_box_h  = "-",
        b_box_v  = "|",
        b_tl     = "+",
        b_tr     = "+",
        b_bl     = "+",
        b_br     = "+",
        b_t_left = "+",
        b_t_r    = "+"
    }
}

-- Render an illuminated Lampboard letter
local function format_lamp(ch, lit_ch, is_ascii)
    if ch == lit_ch then
        if is_ascii then
            return string.format("\27[1;30;43m<%s>\27[0m", ch)
        else
            return string.format("\27[1;30;103m(%s)\27[0m", ch)
        end
    else
        return string.format("\27[90m(%s)\27[0m", ch)
    end
end

-- Render complete 67-column TUI frame
function EnigmaMachine:render_frame()
    local U = self.ascii_mode and UI_CHARS.ascii or UI_CHARS.unicode
    local inner_w = 64
    local out = { "\27[H" }

    -- Header Banner (width: 67)
    table.insert(out, " \27[1;33m" .. U.tl .. string.rep(U.h_line, inner_w) .. U.tr .. "\27[0m\n")
    local title_raw = self.ascii_mode
        and "ENIGMA CIPHER MACHINE (ENIGMA I / M3) - LUAJIT"
        or  "🔒  ENIGMA CIPHER MACHINE (ENIGMA I / M3) - LUAJIT  🔒"
    local title_str = pad_center(title_raw, inner_w)
    table.insert(out, string.format(" \27[1;33m%s\27[1;36m%s\27[1;33m%s\27[0m\n", U.v_line, title_str, U.v_line))
    table.insert(out, " \27[1;33m" .. U.t_left .. string.rep(U.h_line, inner_w) .. U.t_right .. "\27[0m\n")

    -- Rotor Configuration Summary
    local cfg_line1 = string.format("  Rotors: [%-3s] [%-3s] [%-3s]   |  Reflector: [%-5s]",
        self.rotors[1].name, self.rotors[2].name, self.rotors[3].name, self.reflector.name)
    local cfg_line2 = string.format("  Rings:  [%s]   [%s]   [%s]     |  Turnover:  [%s]   [%s]   [%s]",
        self.rotors[1]:get_ring_char(), self.rotors[2]:get_ring_char(), self.rotors[3]:get_ring_char(),
        self.rotors[1].notch_char, self.rotors[2].notch_char, self.rotors[3].notch_char)

    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_right(cfg_line1, inner_w), U.v_line))
    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_right(cfg_line2, inner_w), U.v_line))
    table.insert(out, " \27[1;33m" .. U.b_t_left .. string.rep(U.b_box_h, inner_w) .. U.b_t_r .. "\27[0m\n")

    -- Big Rotor Windows (Visual Groundstellung Display)
    local p1 = self.rotors[1]:get_char()
    local p2 = self.rotors[2]:get_char()
    local p3 = self.rotors[3]:get_char()
    local win_title = "ROTOR WINDOWS (Left / Middle / Right):"
    local win_boxes = string.format("       [  \27[1;32m%s\27[0m  ]             [  \27[1;32m%s\27[0m  ]             [  \27[1;32m%s\27[0m  ]       ", p1, p2, p3)
    local win_labels = "       (Slow)                 (Mid)                 (Fast)      "

    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_right("  " .. win_title, inner_w), U.v_line))
    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_center(win_boxes, inner_w), U.v_line))
    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_center(win_labels, inner_w), U.v_line))
    table.insert(out, " \27[1;33m" .. U.b_t_left .. string.rep(U.b_box_h, inner_w) .. U.b_t_r .. "\27[0m\n")

    -- Lampboard Section (QWERTZ Layout)
    local lit = self.last_lit_lamp
    local lamp_header = lit
        and string.format("  LAMPBOARD: (Active Lamp: \27[1;30;103m %s \27[0m)", lit)
        or  "  LAMPBOARD: (No active contact)"

    local l_row1 = string.format("   %s   %s   %s   %s   %s   %s   %s   %s   %s",
        format_lamp("Q", lit, self.ascii_mode), format_lamp("W", lit, self.ascii_mode),
        format_lamp("E", lit, self.ascii_mode), format_lamp("R", lit, self.ascii_mode),
        format_lamp("T", lit, self.ascii_mode), format_lamp("Z", lit, self.ascii_mode),
        format_lamp("U", lit, self.ascii_mode), format_lamp("I", lit, self.ascii_mode),
        format_lamp("O", lit, self.ascii_mode))

    local l_row2 = string.format("     %s   %s   %s   %s   %s   %s   %s   %s",
        format_lamp("A", lit, self.ascii_mode), format_lamp("S", lit, self.ascii_mode),
        format_lamp("D", lit, self.ascii_mode), format_lamp("F", lit, self.ascii_mode),
        format_lamp("G", lit, self.ascii_mode), format_lamp("H", lit, self.ascii_mode),
        format_lamp("J", lit, self.ascii_mode), format_lamp("K", lit, self.ascii_mode))

    local l_row3 = string.format("   %s   %s   %s   %s   %s   %s   %s   %s   %s",
        format_lamp("P", lit, self.ascii_mode), format_lamp("Y", lit, self.ascii_mode),
        format_lamp("X", lit, self.ascii_mode), format_lamp("C", lit, self.ascii_mode),
        format_lamp("V", lit, self.ascii_mode), format_lamp("B", lit, self.ascii_mode),
        format_lamp("N", lit, self.ascii_mode), format_lamp("M", lit, self.ascii_mode),
        format_lamp("L", lit, self.ascii_mode))

    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_right(lamp_header, inner_w), U.v_line))
    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_center(l_row1, inner_w), U.v_line))
    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_center(l_row2, inner_w), U.v_line))
    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_center(l_row3, inner_w), U.v_line))
    table.insert(out, " \27[1;33m" .. U.b_t_left .. string.rep(U.b_box_h, inner_w) .. U.b_t_r .. "\27[0m\n")

    -- Steckerbrett (Plugboard) Display
    local plugs_str = self.plugboard:get_pairs_string()
    local plug_line = "  PLUGBOARD (STECKER): " .. plugs_str
    table.insert(out, string.format(" \27[1;33m%s\27[0m\27[35m%s\27[0m\27[1;33m%s\27[0m\n",
        U.v_line, pad_right(plug_line, inner_w), U.v_line))
    table.insert(out, " \27[1;33m" .. U.b_t_left .. string.rep(U.b_box_h, inner_w) .. U.b_t_r .. "\27[0m\n")

    -- Plaintext and Ciphertext Message Streams (Last 45 chars visible)
    local tail_plain  = self.plaintext_buffer:sub(-45)
    local tail_cipher = self.ciphertext_buffer:sub(-45)
    local p_str = string.format("  Plaintext : \27[1;37m%-45s\27[0m", tail_plain)
    local c_str = string.format("  Ciphertext: \27[1;32m%-45s\27[0m", tail_cipher)

    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_right(p_str, inner_w), U.v_line))
    table.insert(out, string.format(" \27[1;33m%s\27[0m%s\27[1;33m%s\27[0m\n", U.v_line, pad_right(c_str, inner_w), U.v_line))
    table.insert(out, " \27[1;33m" .. U.b_t_left .. string.rep(U.b_box_h, inner_w) .. U.b_t_r .. "\27[0m\n")

    -- Controls Legend
    local legend = " [A-Z] Type | [Bksp] Undo | [Space] Space | [R] Reset | [Q] Quit"
    table.insert(out, string.format(" \27[1;33m%s\27[0m\27[90m%s\27[0m\27[1;33m%s\27[0m\n",
        U.v_line, pad_right(legend, inner_w), U.v_line))

    -- Bottom border
    table.insert(out, " \27[1;33m" .. U.bl .. string.rep(U.h_line, inner_w) .. U.br .. "\27[0m\n")

    return table.concat(out)
end

-- =========================================================================
-- 6. Interactive Terminal Game Loop
-- =========================================================================
local function run_interactive_session(options)
    local machine = EnigmaMachine.new(options)
    local raw_ok = enable_raw_mode()
    if not raw_ok then
        print("\27[33mWarning: Standard input is not an interactive TTY.\27[0m")
    end

    local last_render = 0
    local target_fps = 60
    local frame_time_ms = 1000.0 / target_fps
    local dirty = true

    local ok, err = pcall(function()
        while true do
            local key = read_key(25)
            if key == "q" or key == "Q" or key == "CTRL_C" or key == "ESC" then
                break
            elseif key == "BACKSPACE" then
                if machine:undo() then
                    dirty = true
                end
            elseif key == "r" or key == "R" then
                machine:reset()
                dirty = true
            elseif key == "SPACE" then
                machine:encode_char(" ")
                dirty = true
            elseif key and #key == 1 and key:match("%a") then
                machine:encode_char(key:upper())
                dirty = true
            end

            local now = get_time_ms()
            if dirty or (now - last_render >= 200) then
                if now - last_render >= frame_time_ms then
                    io.write("\27[?2026h" .. machine:render_frame() .. "\27[?2026l")
                    io.flush()
                    last_render = now
                    dirty = false
                end
            end
        end
    end)

    disable_raw_mode()
    if not ok then
        io.stderr:write("\n\27[31mError in Enigma session:\27[0m " .. tostring(err) .. "\n")
    else
        if #machine.ciphertext_buffer > 0 then
            print(string.format("\n\27[1;32mEnigma Session Complete.\27[0m\nPlaintext : %s\nCiphertext: %s\n",
                machine.plaintext_buffer, machine.ciphertext_buffer))
        end
    end
end

-- =========================================================================
-- 7. Internal Unit & Historical Test Suite (--test)
-- =========================================================================
local function run_self_tests()
    print("=== Running Self-Tests for Enigma (LuaJIT FFI) ===")
    local passed = 0
    local total = 0

    local function check(name, cond)
        total = total + 1
        if cond then
            passed = passed + 1
            print(string.format("  \27[32m✔ PASS\27[0m: %s", name))
        else
            print(string.format("  \27[31m✘ FAIL\27[0m: %s", name))
        end
    end

    -- 1. Canonical Bletchley Park Test Vector
    -- Rotors: I, II, III, Reflector: UKW-B, Rings: AAA, Start: AAA, No Plugs
    -- "AAAAA" -> "BDZGO"
    local m1 = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "AAA", pos = "AAA", reflector = "UKW-B" })
    local c1 = m1:encode_text("AAAAA")
    check("Canonical Bletchley Park vector: AAAAA -> BDZGO", c1 == "BDZGO")

    -- 2. Reciprocal Decryption of Canonical Vector
    local m2 = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "AAA", pos = "AAA", reflector = "UKW-B" })
    local p2 = m2:encode_text(c1)
    check("Reciprocal decryption: BDZGO -> AAAAA", p2 == "AAAAA")

    -- 3. Double-Stepping Mechanical Anomaly Verification
    local m_step = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "AAA", pos = "ADU" })
    m_step:step_rotors()
    check("Step 1 from ADU advances right rotor: ADV",
        m_step.rotors[1]:get_char() == "A" and m_step.rotors[2]:get_char() == "D" and m_step.rotors[3]:get_char() == "V")

    m_step:step_rotors()
    check("Step 2 advances right past notch and turns middle: AEW",
        m_step.rotors[1]:get_char() == "A" and m_step.rotors[2]:get_char() == "E" and m_step.rotors[3]:get_char() == "W")

    m_step:step_rotors()
    check("Step 3 triggers double-step: middle turns again and left advances: BFX",
        m_step.rotors[1]:get_char() == "B" and m_step.rotors[2]:get_char() == "F" and m_step.rotors[3]:get_char() == "X")

    -- 4. Ringstellung Offset Verification
    local m_ring = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "BBB", pos = "AAA", reflector = "UKW-B" })
    local c_ring = m_ring:encode_text("AAAAA")
    check("Ringstellung BBB produces altered ciphertext: EWTYX", c_ring == "EWTYX")

    local m_ring_dec = EnigmaMachine.new({ rotors = {"I", "II", "III"}, rings = "BBB", pos = "AAA", reflector = "UKW-B" })
    local p_ring = m_ring_dec:encode_text(c_ring)
    check("Ringstellung BBB decodes reciprocally back to AAAAA", p_ring == "AAAAA")

    -- 5. Steckerbrett (Plugboard) Bidirectional Swaps
    local pb = EnigmaPlugboard.new("AV BS CG DL FU HZ IN KM OW RX")
    check("Plugboard swaps A <-> V", pb:swap(0) == 21 and pb:swap(21) == 0)
    check("Plugboard swaps B <-> S", pb:swap(1) == 18 and pb:swap(18) == 1)
    check("Plugboard leaves unsteckered letter unchanged", pb:swap(4) == 4) -- E unsteckered

    -- 6. No-Self-Encryption Invariant (E(M)_i ~= M_i)
    local m_comp = EnigmaMachine.new({
        rotors = {"II", "IV", "V"},
        rings = "BUL",
        pos = "WXY",
        reflector = "UKW-C",
        plugs = "AV BS CG DL FU HZ IN KM OW RX"
    })
    local test_msg = "THEENIGMAMACHINEISACIPHERDEVICEUSEDBYGERMANYINTHEWORLDFIRSTWAR"
    local c_comp = m_comp:encode_text(test_msg)
    local self_enc = false
    for i = 1, #test_msg do
        if test_msg:sub(i, i) == c_comp:sub(i, i) then
            self_enc = true
            break
        end
    end
    check("No-self-encryption property holds across full text", not self_enc)

    -- 7. Full Reciprocal Verification with All 5 Rotors and Plugs
    local m_comp_dec = EnigmaMachine.new({
        rotors = {"II", "IV", "V"},
        rings = "BUL",
        pos = "WXY",
        reflector = "UKW-C",
        plugs = "AV BS CG DL FU HZ IN KM OW RX"
    })
    local p_comp = m_comp_dec:encode_text(c_comp)
    check("Full complex machine decodes reciprocally to original plaintext", p_comp == test_msg)

    -- 8. Undo / Backspace History Stack
    local m_undo = EnigmaMachine.new({ rotors = {"I", "II", "III"}, pos = "AAA" })
    m_undo:encode_char("A")
    m_undo:encode_char("B")
    check("History stack has 2 entries", #m_undo.history == 2)
    m_undo:undo()
    check("Undo restores previous rotor positions", m_undo.rotors[3]:get_char() == "B")
    check("Undo removes last character from buffers", m_undo.plaintext_buffer == "A")

    -- 9. TUI Layout Width Verification (Uniform 67 columns)
    local function verify_layout(m)
        local frame = m:render_frame()
        for line in frame:gmatch("([^\r\n]+)") do
            local w = utf8_visible_width(line)
            if w > 0 and w ~= 67 then
                return false, string.format("Mismatch width %d on line: %s", w, line)
            end
        end
        return true
    end
    local ok_uni, err_uni = verify_layout(m1)
    check("TUI layout width is strictly 67 columns in Unicode mode", ok_uni)
    local m_ascii = EnigmaMachine.new({ ascii_mode = true })
    local ok_asc, err_asc = verify_layout(m_ascii)
    check("TUI layout width is strictly 67 columns in ASCII mode", ok_asc)

    print(string.format("\nEnigma Self-Test Summary: %d / %d tests passed.", passed, total))
    if passed == total then
        print("\27[1;32mALL ENIGMA TESTS PASSED SUCCESSFULLY!\27[0m\n")
        return true
    else
        print("\27[1;31mSOME TESTS FAILED!\27[0m\n")
        return false
    end
end

-- =========================================================================
-- 8. CLI Help and Argument Dispatcher
-- =========================================================================
local function print_help()
    print([[
Enigma Cipher Machine (Enigma I / M3) - LuaJIT FFI Simulator

Usage:
    luajit enigma.lua [options] [message]
    echo "MESSAGE" | luajit enigma.lua [options]

Options:
    --help, -h                  Show this help guide and exit
    --test                      Run internal automated cryptographic unit tests
    --snapshot                  Render a single frame TUI snapshot and exit
    --rotors <L,M,R>            Select 3 rotors from I, II, III, IV, V (default: I,II,III)
    --rings <LMR>               Ring settings Ringstellung, e.g. AAA or 01,01,01 (default: AAA)
    --pos <LMR>                 Start positions Grundstellung, e.g. ADV (default: AAA)
    --reflector <UKW-B|UKW-C>   Select reflector (default: UKW-B)
    --plugs <"AB CD EF...">     Plugboard Steckerbrett letter pairs (e.g. "AV BS CG")
    --ascii                     Render in plain ASCII mode (no Unicode box-drawing)

Interactive Mode Controls:
    A - Z                       Type letter to encrypt/decrypt (rotors step & lamp lights)
    Spacebar                    Insert space
    Backspace                   Undo last letter (reverses rotor step)
    R                           Reset rotors to initial start position
    Q / Escape / Ctrl+C         Quit session

Historical Context:
    The Enigma machine is an electro-mechanical rotor cipher machine used extensively
    by the German military during World War II. Its cryptographic security relied on
    polyalphabetic substitution with shifting rotors and the Steckerbrett plugboard.
]])
end

local function parse_cli_args(args)
    local options = {
        rotors = {"I", "II", "III"},
        rings = "AAA",
        pos = "AAA",
        reflector = "UKW-B",
        plugs = "",
        ascii_mode = false
    }
    local message_parts = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--help" or a == "-h" then
            options.help = true
        elseif a == "--test" then
            options.test = true
        elseif a == "--snapshot" then
            options.snapshot = true
        elseif a == "--interactive" or a == "-i" then
            options.interactive = true
        elseif a == "--ascii" then
            options.ascii_mode = true
        elseif a == "--rotors" then
            i = i + 1
            if args[i] then
                local parts = {}
                for r in args[i]:upper():gmatch("[^,]+") do
                    table.insert(parts, r)
                end
                if #parts == 3 then options.rotors = parts end
            end
        elseif a == "--rings" then
            i = i + 1
            if args[i] then
                local s = args[i]:upper():gsub("[^%a]", "")
                if #s == 3 then options.rings = s end
            end
        elseif a == "--pos" then
            i = i + 1
            if args[i] then
                local s = args[i]:upper():gsub("[^%a]", "")
                if #s == 3 then options.pos = s end
            end
        elseif a == "--reflector" then
            i = i + 1
            if args[i] then
                local ref = args[i]:upper()
                if ref == "B" or ref == "UKW-B" then options.reflector = "UKW-B"
                elseif ref == "C" or ref == "UKW-C" then options.reflector = "UKW-C" end
            end
        elseif a == "--plugs" then
            i = i + 1
            if args[i] then options.plugs = args[i] end
        else
            table.insert(message_parts, a)
        end
        i = i + 1
    end
    if #message_parts > 0 then
        options.message = table.concat(message_parts, " ")
    end
    return options
end

-- If executed directly from command line
local base_arg0 = arg and arg[0] and arg[0]:match("([^/]+)$") or ""
local is_main = (base_arg0 == "enigma.lua" or base_arg0 == "ffi_enigma.lua") or (debug.getinfo(3) == nil)

if is_main then
    local options = parse_cli_args(arg or {})

    if options.help then
        print_help()
        os.exit(0)
    elseif options.test then
        local ok = run_self_tests()
        os.exit(ok and 0 or 1)
    elseif options.snapshot then
        local m = EnigmaMachine.new(options)
        print(m:render_frame())
        os.exit(0)
    elseif options.message then
        -- Direct CLI argument encryption
        local m = EnigmaMachine.new(options)
        print(m:encode_text(options.message))
        os.exit(0)
    elseif options.interactive then
        run_interactive_session(options)
    elseif not is_stdin_tty() then
        -- Piped stdin stream
        local m = EnigmaMachine.new(options)
        local input_data = io.read("*a")
        if input_data and #input_data > 0 then
            io.write(m:encode_text(input_data))
            if input_data:sub(-1) ~= "\n" then io.write("\n") end
        end
        os.exit(0)
    else
        -- Interactive TUI mode
        run_interactive_session(options)
    end
end

-- Export module for external testing or embedding
return {
    EnigmaRotor = EnigmaRotor,
    EnigmaReflector = EnigmaReflector,
    EnigmaPlugboard = EnigmaPlugboard,
    EnigmaMachine = EnigmaMachine,
    ROTOR_DEFS = ROTOR_DEFS,
    REFLECTOR_DEFS = REFLECTOR_DEFS,
    utf8_visible_width = utf8_visible_width,
    run_self_tests = run_self_tests
}
